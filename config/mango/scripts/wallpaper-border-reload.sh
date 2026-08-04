#!/usr/bin/env bash
#
# wallpaper-border-reload.sh
# ==========================
# Carries the wallpaper's palette to the three places DMS does NOT push it:
# mango's window borders, the SDDM login screen, and the cava visualiser accents.
#
# WHAT IT DOES (plain English):
#   DMS/matugen regenerates the palette into ~/.cache/DankMaterialShell/dms-colors.json
#   every time you change your wallpaper. This watcher notices that file change and
#   then does three things nothing else does:
#     1. writes ~/.config/mango/dms/colors.conf     (border colors -- see SELF-HEAL)
#     2. runs wallpaper-accent-extract.sh           (cava visualiser accent pair)
#     3. runs sddm-palette-sync.sh                  (login screen palette + wallpaper)
#   ...and then tells mango to re-read its config so the borders actually recolor.
#
# WHY THIS SCRIPT STILL EXISTS  (re-verified 2026-08-05 on mango 0.15.5)
#   Read this before "simplifying" or deleting it -- its ORIGINAL reason is gone,
#   but it is still load-bearing for three OTHER reasons.
#
#   The original reason (NO LONGER TRUE, kept only so nobody re-derives it):
#   DMS's reload hook used to run the pre-0.14 `mmsg -d reload_config`, which mango
#   0.14 removed, so nothing reloaded mango on a wallpaper change and borders only
#   updated on a manual SUPER+r. THAT IS FIXED UPSTREAM. matugen/configs/mangowc.toml
#   now runs `mmsg dispatch reload_config`, and DMS separately watches colors.conf
#   itself (Services/MangoService.qml) and reloads on any change. So the reload call
#   below is now the third of three redundant reloads. It is deliberately KEPT -- it
#   is one cheap command and the only reload we control -- but it is no longer why
#   this file is here.
#
#   The three reasons it IS still load-bearing:
#     a) colors.conf SELF-HEAL. matugen's mangowc template STILL silently fails to
#        write colors.conf. Verified by stopping this watcher and changing the
#        wallpaper: dms-colors.json regenerated correctly, colors.conf never moved.
#        Without the regen below, borders keep the PREVIOUS wallpaper's colors.
#     b) It is the ONLY caller of sddm-palette-sync.sh. Stop this script and the
#        login screen silently keeps the old palette and old background.
#     c) It is the ONLY caller of wallpaper-accent-extract.sh, so the cava
#        visualiser silently keeps the old accent pair.
#   Even if (a) were fixed upstream tomorrow, deleting this script would still break
#   (b) and (c) with no error anywhere. Re-check all three before retiring it.
#
# RESTARTING IT DOES NOT FIX ALREADY-STALE COLORS.
#   It baselines both mtimes at startup and only reacts to the NEXT change, so
#   anything it missed while it was down stays missed. To force a resync:
#       touch ~/.cache/DankMaterialShell/dms-colors.json
#   (border-color-healthcheck.sh will NOT catch this -- it checks that the chain is
#   wired up, not that the colors are current, and reports OK on stale values.)
#
# ===========================================================================
# EDIT HERE AFTER A MANGO / DMS UPDATE  (the only version-sensitive bits)
# ===========================================================================
# 1) Where DMS/matugen writes the border colors (matugen output_path,
#    CONFIG_DIR/mango/dms/colors.conf):
COLORS_FILE="$HOME/.config/mango/dms/colors.conf"
#
# 2) The command that tells the RUNNING mango to re-read its config.
#    Now redundant (see the header -- upstream reloads too), kept deliberately.
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
# STILL BROKEN as of 2026-08-05 (mango 0.15.5). Re-tested directly: with this
# watcher stopped, a wallpaper change regenerated dms-colors.json but left
# COLORS_FILE untouched at its old values. Re-run that test before assuming an
# update has fixed it -- upstream fixed the matugen POST-HOOK, not the template.
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
