#!/usr/bin/env bash
#
# wallpaper-border-reload.sh
# ==========================
# Makes mango window-border colors follow the wallpaper AUTOMATICALLY.
#
# WHAT IT DOES (plain English):
#   When you change your wallpaper, DMS/matugen regenerates the border colors
#   into  ~/.config/mango/dms/colors.conf . mango does NOT notice that file
#   change on its own, so this tiny watcher notices it and tells mango to
#   reload, which re-reads colors.conf and recolors the borders.
#
# WHY THIS SCRIPT EXISTS (the bug it works around):
#   DMS's own "reload mango after a color change" hook
#   (/usr/share/quickshell/dms/matugen/configs/mangowc.toml post_hook, and
#    /usr/share/quickshell/dms/Services/DwlService.qml) runs
#       mmsg -d reload_config
#   That was valid on mango 0.13.x but mango 0.14 REWROTE the mmsg CLI, so now
#       mmsg -d reload_config   -> {"error":"unknown command"} (and exits 0, so
#                                  DMS's "|| true" swallows it silently)
#       mmsg dispatch reload_config  -> {"success":true}   <-- the new form
#   Result after the 0.13->0.14 update: borders only update on a manual SUPER+r,
#   not when the wallpaper changes. We can't fix the DMS files update-proof
#   (they're package-owned, overwritten on every DMS upgrade), so instead we
#   watch the colors file ourselves and issue the CORRECT reload command.
#
# ===========================================================================
# EDIT HERE AFTER A MANGO / DMS UPDATE  (the only version-sensitive bits)
# ===========================================================================
# 1) Where DMS/matugen writes the border colors (matugen output_path,
#    CONFIG_DIR/mango/dms/colors.conf):
COLORS_FILE="$HOME/.config/mango/dms/colors.conf"
#
# 2) The command that tells the RUNNING mango to re-read its config.
#    If borders stop auto-updating after a mango update, TEST this by hand:
#        mmsg dispatch reload_config      # expect {"success":true}
#    If that prints {"error":"unknown command"}, the CLI changed again --
#    find the new form with `mmsg --help` and update the line below.
mango_reload_config() { mmsg dispatch reload_config >/dev/null 2>&1; }
#
# 3) Poll interval in seconds (no inotify-tools installed, so we poll mtime).
#    stat-ing one file twice a second is negligible CPU; lower = snappier borders.
POLL_SECONDS=0.5
# ===========================================================================

LOCK="/tmp/mango-wallpaper-border-reload.lock"

# Single instance (same flock idiom as the other mango helpers).
exec 9>"$LOCK"
flock -n 9 || exit 0

# If the colors file isn't there yet (e.g. first boot before DMS writes it),
# wait for it rather than dying.
while [ ! -f "$COLORS_FILE" ]; do sleep "$POLL_SECONDS"; done

# --- SELF-HEAL for the broken generate link --------------------------------
# DMS is supposed to write COLORS_FILE via its mangowc matugen template. As of
# 2026-07-19 that template silently stopped running on wallpaper change: the
# theming pass still rewrites dms-colors.json AND the GTK template, but skips
# mangowc, so COLORS_FILE froze and window borders stuck on an old colour while
# the bar (which reads DMS Theme directly) kept updating correctly.
#
# dms-colors.json DOES update reliably on every wallpaper change, so derive
# COLORS_FILE from it ourselves rather than depending on the template. The role
# mapping below is exactly what the template produces (verified against a known
# good `dms matugen generate` run: bordercolor=outline, focuscolor=primary,
# urgentcolor=error).
DMS_COLORS_JSON="$HOME/.cache/DankMaterialShell/dms-colors.json"
ACCENT_EXTRACT="$HOME/.config/mango/scripts/wallpaper-accent-extract.sh"
# Pushes the same palette to the SDDM login screen. The greeter runs as the
# `sddm` system user and cannot read $HOME (0700), so it can't follow the
# wallpaper the way everything else does; this script writes the colors into a
# user-owned theme.conf.user that the greeter CAN read. No elevation involved --
# see the script's header for why. Exits quietly if the theme isn't installed.
SDDM_PALETTE_SYNC="$HOME/.config/mango/scripts/sddm-palette-sync.sh"

regen_colors_conf() {
    [ -f "$DMS_COLORS_JSON" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local border focus urgent
    border="$(jq -r '.colors.dark.outline // empty' "$DMS_COLORS_JSON" 2>/dev/null)"
    focus="$(jq -r '.colors.dark.primary // empty' "$DMS_COLORS_JSON" 2>/dev/null)"
    urgent="$(jq -r '.colors.dark.error // empty' "$DMS_COLORS_JSON" 2>/dev/null)"
    [ -n "$border" ] && [ -n "$focus" ] && [ -n "$urgent" ] || return 1
    # #rrggbb -> 0xrrggbbff (mango's format)
    border="0x${border#\#}ff"; focus="0x${focus#\#}ff"; urgent="0x${urgent#\#}ff"
    # Only rewrite when something actually changed, so we don't churn the file
    # (and thereby retrigger our own reload) every poll.
    grep -q "$focus" "$COLORS_FILE" 2>/dev/null && grep -q "$border" "$COLORS_FILE" 2>/dev/null && return 1
    cat > "$COLORS_FILE" <<EOF
# ! Auto-generated file. Do not edit directly.
# Remove source = ./dms/colors.conf from your config to override.

bordercolor = $border
focuscolor  = $focus
urgentcolor = $urgent
EOF
    return 0
}

last="$(stat -c %Y "$COLORS_FILE" 2>/dev/null)"
last_json="$(stat -c %Y "$DMS_COLORS_JSON" 2>/dev/null)"
while sleep "$POLL_SECONDS"; do
    # 1. DMS regenerated its palette -> rebuild COLORS_FILE if the template didn't.
    now_json="$(stat -c %Y "$DMS_COLORS_JSON" 2>/dev/null)"
    if [ -n "$now_json" ] && [ "$now_json" != "$last_json" ]; then
        last_json="$now_json"
        regen_colors_conf
        # Also re-extract the wallpaper's real accent pair for the cava
        # visualiser. Backgrounded: it costs up to 5 matugen runs (~1.7s) and
        # must not delay the border reload below.
        [ -x "$ACCENT_EXTRACT" ] && "$ACCENT_EXTRACT" >/dev/null 2>&1 &
        # Re-tint the login screen too. Cheap (one jq pass, writes only on an
        # actual change) but backgrounded anyway so it can never delay the
        # border reload below.
        [ -x "$SDDM_PALETTE_SYNC" ] && "$SDDM_PALETTE_SYNC" >/dev/null 2>&1 &
    fi

    # 2. COLORS_FILE changed (by us, or by the template if it ever works again)
    #    -> tell mango to re-read it.
    now="$(stat -c %Y "$COLORS_FILE" 2>/dev/null)" || continue
    if [ "$now" != "$last" ]; then
        last="$now"
        mango_reload_config
    fi
done
