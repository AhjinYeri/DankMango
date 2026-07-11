#!/usr/bin/env bash
#
# border-color-healthcheck.sh
# ===========================
# Run this AFTER A SYSTEM UPDATE if your window borders stop following the
# wallpaper. It checks every link in the "color chain" and tells you, in plain
# English, which link is broken and what to do about it. It changes nothing
# (except link 3 issues one harmless mango config-reload to test the command).
#
#   Usage:  ~/.config/mango/scripts/border-color-healthcheck.sh
#
# The chain (see the COLOR CHAIN box in config.conf):
#   1 GENERATE  DMS/matugen writes colors to dms/colors.conf on wallpaper change
#   2 SOURCE    config.conf sources that file, and must NOT set the colors inline
#   3 RELOAD    a watcher reloads mango (mmsg dispatch reload_config) on change
#
# --- the version-sensitive bits this checks (keep in sync with the watcher) ---
CONFIG="$HOME/.config/mango/config.conf"
COLORS_FILE="$HOME/.config/mango/dms/colors.conf"
WATCHER="$HOME/.config/mango/scripts/wallpaper-border-reload.sh"
WATCHER_LOCK="/tmp/mango-wallpaper-border-reload.lock"
RELOAD_TEST=(mmsg dispatch reload_config)        # 0.14 form; 0.13 was `mmsg -d ...`
# -----------------------------------------------------------------------------

fails=0
ok()   { printf '  \033[32m[ OK ]\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31m[FAIL]\033[0m  %s\n' "$1"; printf '          -> %s\n' "$2"; fails=$((fails+1)); }
warn() { printf '  \033[33m[WARN]\033[0m  %s\n' "$1"; printf '          -> %s\n' "$2"; }

echo "Border color-chain health check"
echo "==============================="

# --- LINK 1: GENERATE ---------------------------------------------------------
echo "LINK 1  GENERATE (DMS/matugen -> dms/colors.conf)"
if [ ! -f "$COLORS_FILE" ]; then
    bad "colors.conf is missing ($COLORS_FILE)" \
        "DMS isn't writing it. In DMS check matugen/dynamic theming is on, then change the wallpaper once."
elif ! grep -qE '^[[:space:]]*(bordercolor|focuscolor)[[:space:]]*=' "$COLORS_FILE"; then
    bad "colors.conf exists but has no bordercolor/focuscolor lines" \
        "DMS template changed or wrote junk. Look at: cat $COLORS_FILE ; check /usr/share/quickshell/dms/matugen/templates/mango-colors.conf"
else
    vals="$(grep -E '^[[:space:]]*(bordercolor|focuscolor)' "$COLORS_FILE" | tr -s ' ' | paste -sd'  ')"
    ok "colors.conf present with colors ($vals)"
    age=$(( ($(date +%s) - $(stat -c %Y "$COLORS_FILE")) / 60 ))
    echo "          (last regenerated ${age} min ago; it should update right after a wallpaper change)"
fi

# --- LINK 2: SOURCE -----------------------------------------------------------
echo "LINK 2  SOURCE (config.conf reads it, no inline override)"
if grep -qE '^[[:space:]]*source[[:space:]]*=.*colors\.conf' "$CONFIG"; then
    ok "config.conf sources dms/colors.conf"
else
    bad "config.conf does NOT source dms/colors.conf" \
        "Add this line to $CONFIG : source=~/.config/mango/dms/colors.conf"
fi
inline="$(grep -nE '^[[:space:]]*(bordercolor|focuscolor|urgentcolor)[[:space:]]*=' "$CONFIG" || true)"
if [ -n "$inline" ]; then
    bad "config.conf sets border colors INLINE (these override the wallpaper on 0.14):" \
        "Comment out these line(s) -- 0.14 is first-definition-wins:
$(echo "$inline" | sed 's/^/             /')"
else
    ok "no inline bordercolor/focuscolor/urgentcolor overriding the sourced colors"
fi

# --- LINK 3: RELOAD -----------------------------------------------------------
echo "LINK 3  RELOAD (watcher -> mmsg dispatch reload_config)"
reload_out="$("${RELOAD_TEST[@]}" 2>&1)"
if printf '%s' "$reload_out" | grep -q '"success"'; then
    ok "reload command works: ${RELOAD_TEST[*]} -> $reload_out"
else
    bad "reload command failed: ${RELOAD_TEST[*]} -> $reload_out" \
        "mango's mmsg CLI changed again. Find the new reload verb with 'mmsg --help' and update RELOAD_CMD in:
             $WATCHER  (and RELOAD_TEST in this script)"
fi
if [ -x "$WATCHER" ]; then ok "watcher script present & executable"
else bad "watcher script missing/not executable ($WATCHER)" "Restore it, then: chmod +x $WATCHER"; fi
if command -v fuser >/dev/null && [ -n "$(fuser "$WATCHER_LOCK" 2>/dev/null)" ]; then
    ok "watcher is running"
else
    warn "watcher is NOT running right now" \
         "Start it:  setsid $WATCHER >/dev/null 2>&1 & disown   (it also autostarts on next login)"
fi
if grep -qE '^[[:space:]]*exec-once[[:space:]]*=.*wallpaper-border-reload' "$CONFIG"; then
    ok "watcher is wired to autostart (exec-once in config.conf)"
else
    bad "watcher is NOT in exec-once (won't start on login)" \
        "Add to $CONFIG : exec-once = ~/.config/mango/scripts/wallpaper-border-reload.sh"
fi

echo "==============================="
if [ "$fails" -eq 0 ]; then
    printf '\033[32mAll links OK.\033[0m Borders should follow the wallpaper. If they still don'\''t,\n'
    echo "change the wallpaper and watch 'cat $COLORS_FILE' update, then borders should recolor within ~0.5s."
else
    printf '\033[31m%d problem(s) found above\033[0m -- fix the FAIL line(s), most-upstream (LINK 1) first.\n' "$fails"
fi
exit 0
