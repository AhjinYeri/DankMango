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

last="$(stat -c %Y "$COLORS_FILE" 2>/dev/null)"
while sleep "$POLL_SECONDS"; do
    now="$(stat -c %Y "$COLORS_FILE" 2>/dev/null)" || continue
    if [ "$now" != "$last" ]; then
        last="$now"
        mango_reload_config
    fi
done
