#!/usr/bin/env bash
#
# =============================================================================
#  post-update-health.sh  --  one-shot health check to run AFTER a MangoWM or
#                             DankMaterialShell (DMS) update
# =============================================================================
#
#  WHAT IT DOES
#    Runs every health check for this machine's mango + DMS customisations in one
#    go, prints a plain-English PASS/FAIL report, and -- for anything broken --
#    tells you what's broken, where to look, and the known fix-notes, formatted so
#    you can paste it straight into Claude Code.
#
#    It covers four areas:
#      1. Per-monitor tiling + the Window Mode bar plugin (monitorMode)
#      2. The audio output-switcher plugin (audioToggle) + the combined-audio-OSD
#         patch on DMS's VolumeOSD.qml
#      3. The visual Alt+Tab switcher plugin (altSwitcher)
#      4. Dynamic window-border / theme colouring (the "colour chain")
#    ...plus it records the mango / dms-shell / quickshell versions and tells you
#    which changed since the last run (a changed version = prime suspect for a break).
#
#  WHAT IT DOES NOT DO
#    It NEVER edits your configs. New-version breakage can't be predicted, so this
#    only DETECTS and REPORTS. The one exception: at the very end it may OFFER to
#    re-apply a fix you've used before that recurs identically (restart a background
#    watcher, or `dms restart`) -- and only after asking y/N. Those restart processes
#    only; they touch no config files.
#
#  USAGE
#    ~/.config/mango/scripts/post-update-health.sh
#
#  MAINTENANCE
#    Every version-sensitive command / path lives in the "EDIT HERE" block just
#    below. If a check itself goes stale after an update, fix it there.
# =============================================================================

# NOTE: intentionally NOT `set -e` -- we want every check to run even if earlier
# ones fail. `-u` catches typos, pipefail surfaces failures inside pipes.
set -uo pipefail

# ------ ########## EDIT HERE AFTER A MANGO / DMS UPDATE ########## ------------
MANGO_CFG="$HOME/.config/mango/config.conf"
DMS_DIR="$HOME/.config/DankMaterialShell"
PLUGIN_SETTINGS="$DMS_DIR/plugin_settings.json"
BAR_SETTINGS="$DMS_DIR/settings.json"
SCRIPTS="$HOME/.config/mango/scripts"

# Per-monitor tagrules now live in an auto-generated, sourced file (not inline in
# config.conf). generate-tagrules.sh writes it; set-monitor-mode.sh edits it.
TAGRULES_FILE="$HOME/.config/mango/dms/tagrules.conf"
TAGRULES_GEN="$SCRIPTS/generate-tagrules.sh"

COLORS_FILE="$HOME/.config/mango/dms/colors.conf"
BORDER_CHECK="$SCRIPTS/border-color-healthcheck.sh"       # delegated colour-chain check
BORDER_WATCHER="$SCRIPTS/wallpaper-border-reload.sh"
BORDER_LOCK="/tmp/mango-wallpaper-border-reload.lock"

MONITOR_SETTER="$SCRIPTS/set-monitor-mode.sh"
DP2_HELPER="$SCRIPTS/dp2-floatsize.sh"
DP2_LOCK="${XDG_RUNTIME_DIR:-/tmp}/mango-dp2-floatsize.lock"

ALTTAB_SCRIPT="$SCRIPTS/alt-switcher.sh"

# Combined-audio-OSD patch: a local patch to DMS's package-owned VolumeOSD.qml that
# adds a device-name line (so an output switch shows ONE popup: icon+name+slider).
# Every dms-shell update OVERWRITES that file, wiping the patch -- so we check for the
# marker and, if gone, point at the idempotent re-apply script.
VOLUME_OSD="/usr/share/quickshell/dms/Modules/OSD/VolumeOSD.qml"
OSD_PATCH_MARKER='DankMango patch: combined OSD device name'
OSD_APPLY="$SCRIPTS/apply-combined-osd-patch.sh"

# Commands mango/DMS updates have renamed before. Test-forms used by the checks:
RELOAD_CMD=(mmsg dispatch reload_config)   # 0.13 was `mmsg -d reload_config` (now dead)
FOCUSSTACK_CMD=(mmsg dispatch focusstack,next)
CLIENTS_CMD=(mmsg get all-clients)         # must return {"clients":[{title,appid,is_focused,monitor}]}

# Where we remember last run's versions (state, not config -- keep out of dotfiles).
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mango-health"
STATE_FILE="$STATE_DIR/last-versions.env"
# -----------------------------------------------------------------------------

# ---- output + failure-collection helpers ------------------------------------
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
US=$'\037'                      # unit separator to pack 4 fields per failure
FAILS=()                        # each entry: component US symptom US where US fix
OFFERS=()                       # each entry: label US command-string (safe re-applies)

section() { printf '\n%s— %s —%s\n' "$c_dim" "$1" "$c_off"; }
pass()    { printf '  %s[PASS]%s %s\n' "$c_grn" "$c_off" "$1"; }
warn()    { printf '  %s[WARN]%s %s\n         %s\n' "$c_yel" "$c_off" "$1" "$2"; }
# fail COMPONENT SYMPTOM WHERE-TO-LOOK KNOWN-FIX
fail() {
    printf '  %s[FAIL]%s %s\n         %s\n' "$c_red" "$c_off" "$1" "$2"
    FAILS+=("$1${US}$2${US}$3${US}$4")
}
# offer LABEL COMMAND  (queued; asked at the very end, only on a TTY)
offer() { OFFERS+=("$1${US}$2"); }

# tiny predicates
have()   { command -v "$1" >/dev/null 2>&1; }
execu()  { [ -x "$1" ]; }        # exists AND executable
# plugin_enabled ID -> true if plugin_settings.json has it with "enabled": true
plugin_enabled() { grep -Pzo "\"$1\"\s*:\s*\{[^}]*\"enabled\"\s*:\s*true" "$PLUGIN_SETTINGS" >/dev/null 2>&1; }

echo "==================================================================="
echo " MangoWM + DMS post-update health check   ($(date '+%Y-%m-%d %H:%M'))"
echo "==================================================================="

# =============================================================================
# 0. VERSIONS  --  record + diff against last run
# =============================================================================
section "Versions (changed since last run?)"
mango_ver="$(mango -v 2>&1 | head -1 | tr -d '\n')"; [ -n "$mango_ver" ] || mango_ver="unknown"
dms_ver="$(pacman -Q dms-shell 2>/dev/null | awk '{print $2}')"; [ -n "$dms_ver" ] || dms_ver="unknown"
qs_ver="$(pacman -Q quickshell 2>/dev/null | awk '{print $2}')"; [ -n "$qs_ver" ] || qs_ver="unknown"

declare -A OLD=()
if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    while IFS='=' read -r k v; do [ -n "$k" ] && OLD["$k"]="$v"; done < "$STATE_FILE"
fi
VERSION_CHANGED=0
report_ver() { # name currentval key
    local name="$1" cur="$2" key="$3" old="${OLD[$3]:-}"
    if [ -z "$old" ]; then
        printf '  %-11s %s   %s(no baseline yet — recording)%s\n' "$name" "$cur" "$c_dim" "$c_off"
    elif [ "$old" = "$cur" ]; then
        printf '  %-11s %s   %s(unchanged)%s\n' "$name" "$cur" "$c_dim" "$c_off"
    else
        printf '  %-11s %s%s -> %s%s   %sCHANGED%s\n' "$name" "$c_yel" "$old" "$cur" "$c_off" "$c_yel" "$c_off"
        VERSION_CHANGED=1
    fi
}
report_ver "mango:"      "$mango_ver" mango
report_ver "dms-shell:"  "$dms_ver"   dms
report_ver "quickshell:" "$qs_ver"    qs
[ "$VERSION_CHANGED" = 1 ] && echo "  ${c_yel}A version changed — if anything below FAILs, the update is the likely cause.${c_off}"
# persist current versions for next time
mkdir -p "$STATE_DIR" 2>/dev/null
printf 'mango=%s\ndms=%s\nqs=%s\n' "$mango_ver" "$dms_ver" "$qs_ver" > "$STATE_FILE" 2>/dev/null

# live quickshell log (needed by a couple of checks); empty if qs isn't running
QS_PID="$(pgrep -x qs | head -1)"
QS_LOG=""
[ -n "$QS_PID" ] && QS_LOG="$(ls -l /proc/"$QS_PID"/fd 2>/dev/null | grep -oE '/run/user/[0-9]+/quickshell/by-id/[^ ]+/log.log' | head -1)"

# =============================================================================
# 1. PER-MONITOR TILING + WINDOW MODE PLUGIN (monitorMode)
# =============================================================================
section "1. Per-monitor tiling + Window Mode plugin"

# 1a. the reload command — THE recurring break (silently no-ops -> new windows keep old mode)
reload_out="$("${RELOAD_CMD[@]}" 2>&1)"
if printf '%s' "$reload_out" | grep -q '"success"'; then
    pass "config reload works: ${RELOAD_CMD[*]} -> $reload_out"
else
    fail "MangoWM config reload command" \
         "'${RELOAD_CMD[*]}' returned: $reload_out (mode changes won't apply to NEW windows)" \
         "$MONITOR_SETTER (mango_reload_config), $BORDER_WATCHER (RELOAD_CMD), and RELOAD_CMD in this script" \
         "mango renamed the reload verb before (0.13 'mmsg -d reload_config' -> 0.14 'mmsg dispatch reload_config'). Run 'mmsg --help', find the new reload verb, update it in those files. It returns exit 0 even when wrong, so it fails SILENTLY."
fi

# 1b. tagrules (per-monitor mode storage) present. They now live in the auto-
#     generated dms/tagrules.conf (sourced by config.conf); we accept either that
#     file OR inline config.conf rules (the manual-fallback path) as valid.
if { [ -f "$TAGRULES_FILE" ] && grep -qE '^[[:space:]]*tagrule[[:space:]]*=' "$TAGRULES_FILE"; } \
   || grep -qE '^[[:space:]]*tagrule[[:space:]]*=' "$MANGO_CFG"; then
    pass "per-monitor tagrules present (dms/tagrules.conf or config.conf)"
else
    fail "Per-monitor tagrules" "no tagrules in dms/tagrules.conf — per-monitor tile/float is not active" \
         "$TAGRULES_FILE (auto-generated; sourced by config.conf)" \
         "Re-generate them: $TAGRULES_GEN  (detects your monitors via 'mmsg get all-monitors' and writes the file, then Super+r). Fresh installs run this automatically; if it's empty, mango probably wasn't running when it ran — re-run it now. (A monitor FLOATS once its rules gain open_as_floating:1, set via the Monitor Mode plugin.)"
fi

# 1c. helper scripts present + executable
execu "$MONITOR_SETTER" && pass "set-monitor-mode.sh present & executable" \
    || fail "set-monitor-mode.sh" "missing or not executable" "$MONITOR_SETTER" "Restore it, then: chmod +x '$MONITOR_SETTER'"
execu "$DP2_HELPER" && pass "dp2-floatsize.sh present & executable" \
    || fail "dp2-floatsize.sh" "missing or not executable" "$DP2_HELPER" "Restore it, then: chmod +x '$DP2_HELPER'"

# 1d. float-size helper actually running (needs the focus/clients IPC below too)
if have fuser && [ -n "$(fuser "$DP2_LOCK" 2>/dev/null)" ]; then
    pass "float-size helper (dp2-floatsize.sh) is running"
elif grep -qE '^[[:space:]]*exec-once[[:space:]]*=.*dp2-floatsize' "$MANGO_CFG"; then
    warn "float-size helper is NOT running (but is wired to autostart on login)" \
         "Start it now:  setsid '$DP2_HELPER' >/dev/null 2>&1 & disown"
    offer "start the float-size helper (dp2-floatsize.sh)" "setsid '$DP2_HELPER' >/dev/null 2>&1 &"
else
    fail "float-size helper autostart" "dp2-floatsize.sh isn't running and isn't in exec-once" \
         "$MANGO_CFG (exec-once lines)" \
         "Add:  exec-once = ~/.config/mango/scripts/dp2-floatsize.sh   then reload (SUPER+r)."
fi

# 1e. the mango IPC the helper depends on (focus + client list w/ fields it reads)
if "${CLIENTS_CMD[@]}" 2>/dev/null | grep -q '"is_floating"'; then
    pass "window-list IPC OK (${CLIENTS_CMD[*]} exposes is_floating/appid)"
else
    fail "Window-list IPC for float helper" "'${CLIENTS_CMD[*]}' missing or lost the is_floating field" \
         "$DP2_HELPER (its mango_* command wrappers)" \
         "mango renamed the command or a JSON field. Run '${CLIENTS_CMD[*]}' and 'mmsg --help'; update the wrappers in dp2-floatsize.sh (it reads is_floating, appid, monitor)."
fi

# 1f. plugin enabled
plugin_enabled monitorMode && pass "monitorMode plugin enabled" \
    || fail "monitorMode plugin" "not enabled in plugin_settings.json" "$PLUGIN_SETTINGS" \
            "Re-enable: DMS Settings -> Plugins -> Monitor Mode on; confirm it's in the bar layout too. Then 'dms restart'."

# =============================================================================
# 2. AUDIO OUTPUT-SWITCHER PLUGIN (audioToggle)
# =============================================================================
section "2. Audio output-switcher plugin"
plugin_enabled audioToggle && pass "audioToggle plugin enabled" \
    || fail "audioToggle plugin" "not enabled in plugin_settings.json" "$PLUGIN_SETTINGS" \
            "Re-enable via DMS Settings -> Plugins, confirm it's in the bar, then 'dms restart'."

have wpctl || have pactl && pass "audio backend present (wpctl/pactl)" \
    || fail "audio backend" "neither wpctl nor pactl found" "PATH / packages" "Install wireplumber (wpctl) or libpulse (pactl)."

# 2b. combined-audio-OSD patch on DMS's package-owned VolumeOSD.qml (dms updates wipe it)
if [ ! -f "$VOLUME_OSD" ]; then
    fail "combined audio OSD patch" "VolumeOSD.qml not found where expected -- DMS may have moved/renamed it" \
         "expected $VOLUME_OSD; find it: pacman -Ql dms-shell | grep VolumeOSD.qml" \
         "Update VOLUME_OSD in this script's EDIT HERE block to the new path, then re-run $OSD_APPLY (edit its TARGET to match too)."
elif grep -qF "$OSD_PATCH_MARKER" "$VOLUME_OSD"; then
    pass "combined audio OSD patch present (output switch shows one popup: icon + device name + slider)"
else
    fail "combined audio OSD patch" \
         "VolumeOSD.qml lost the DankMango patch -- an output switch shows the volume OSD with NO device name (and may stack a 2nd popup)" \
         "$VOLUME_OSD (marker '$OSD_PATCH_MARKER'); re-applied by $OSD_APPLY" \
         "A dms-shell update overwrote this package-owned file. Re-apply the patch (idempotent, backs up first, needs sudo):  $OSD_APPLY   then 'dms restart'."
fi

# =============================================================================
# 3. ALT-TAB SWITCHER PLUGIN (altSwitcher)   -- includes the crash canary
# =============================================================================
section "3. Alt-Tab switcher plugin"
plugin_enabled altSwitcher && pass "altSwitcher plugin enabled" \
    || fail "altSwitcher plugin" "not enabled in plugin_settings.json" "$PLUGIN_SETTINGS" \
            "Re-enable via DMS Settings -> Plugins, confirm it's in the bar, then 'dms restart'."

execu "$ALTTAB_SCRIPT" && pass "alt-switcher.sh present & executable" \
    || fail "alt-switcher.sh" "missing or not executable" "$ALTTAB_SCRIPT" "Restore it, then: chmod +x '$ALTTAB_SCRIPT'"

grep -q 'alt-switcher.sh' "$MANGO_CFG" \
    && pass "Alt+Tab binds point at alt-switcher.sh" \
    || fail "Alt+Tab keybinds" "config.conf has no bind calling alt-switcher.sh" "$MANGO_CFG" \
            "Re-add:  bind = ALT, Tab, spawn, $ALTTAB_SCRIPT next   and  bind = ALT+SHIFT, Tab, spawn, $ALTTAB_SCRIPT prev   then SUPER+r."

# 3a. duplicate-handler check — the exact signature of the quickshell-0.3.0-2 crash
if [ -n "$QS_LOG" ] && grep -q 'another handler is registered for target altswitcher' "$QS_LOG" 2>/dev/null; then
    fail "altSwitcher duplicate IPC handler (CRASH RISK)" \
         "two 'altswitcher' handlers registered — newer quickshell SEGFAULTS the whole shell when Alt+Tab invokes it" \
         "AltSwitcherBar.qml (the isPrimaryInstance Loader) + README 'crashes the whole shell'" \
         "The IpcHandler+DankModal must live inside the 'engine' Loader gated by isPrimaryInstance (one handler only). Never put IpcHandler at the plugin root. Then 'dms restart'."
else
    pass "single altSwitcher IPC handler (no duplicate-handler crash risk)"
fi

# 3b. crash canary: drive the IPC path that crashed, confirm the shell survives
if [ -n "$QS_PID" ]; then
    ipc_out="$(dms ipc call altswitcher next 2>&1)"
    sleep 0.4
    QS_PID2="$(pgrep -x qs | head -1)"
    if [ -n "$QS_PID2" ] && [ "$QS_PID" = "$QS_PID2" ]; then
        pass "altSwitcher IPC survives invocation (dms ipc call altswitcher next -> ${ipc_out:-ok})"
    else
        fail "altSwitcher IPC crashed the shell" "invoking 'dms ipc call altswitcher next' restarted/killed quickshell (pid $QS_PID -> ${QS_PID2:-gone})" \
             "AltSwitcherBar.qml + ~/.cache/quickshell/crashes/ (newest report.txt)" \
             "Same class as the duplicate-handler crash. Verify the isPrimaryInstance Loader gate; read the newest crash report.txt stacktrace. Paste this whole report to Claude Code."
    fi
else
    fail "quickshell not running" "qs process not found — the DMS shell is down" "run 'dms run' output / journal" \
         "Start it: 'dms run &' (or relog). If it won't stay up, check the newest ~/.cache/quickshell/crashes/*/report.txt."
fi

# 3c. focus-cycle command the wiring script relies on
"${FOCUSSTACK_CMD[@]}" 2>/dev/null | grep -q '"success"' \
    && pass "focus-cycle IPC works (${FOCUSSTACK_CMD[*]})" \
    || fail "focus-cycle IPC" "'${FOCUSSTACK_CMD[*]}' failed — Alt+Tab won't change focus" "$ALTTAB_SCRIPT (mango_cycle_focus)" \
            "mango renamed focusstack. Run 'mmsg --help', update mango_cycle_focus in alt-switcher.sh."

# =============================================================================
# 4. DYNAMIC BORDER / THEME COLOURING  (delegate to the dedicated checker)
# =============================================================================
section "4. Dynamic border/theme colouring (colour chain)"
if execu "$BORDER_CHECK"; then
    bc_out="$(bash "$BORDER_CHECK" 2>&1)"
    bc_fails="$(printf '%s' "$bc_out" | grep -c '\[FAIL\]')"
    if [ "$bc_fails" -eq 0 ]; then
        pass "colour chain OK (border-color-healthcheck.sh: all 3 links pass)"
    else
        # surface the sub-check's own FAIL lines into our unified paste block
        bc_detail="$(printf '%s' "$bc_out" | grep -A1 '\[FAIL\]' | sed 's/^/    /')"
        fail "Border/theme colour chain ($bc_fails link(s) broken)" \
             "border-color-healthcheck.sh reported failures (borders won't follow the wallpaper)" \
             "$MANGO_CFG (COLOR CHAIN box), $COLORS_FILE, $BORDER_WATCHER — full detail: run '$BORDER_CHECK'" \
             "Known culprits: (a) inline bordercolor/focuscolor in config.conf overriding sourced colors (0.14 is first-wins — comment them out); (b) the reload watcher using a dead verb (see area 1's reload fix). Sub-check FAILs:
$bc_detail"
    fi
    # is the colour watcher running?
    if have fuser && [ -n "$(fuser "$BORDER_LOCK" 2>/dev/null)" ]; then
        pass "wallpaper-border reload watcher is running"
    elif execu "$BORDER_WATCHER"; then
        warn "wallpaper-border watcher is NOT running (autostarts on next login)" \
             "Start now:  setsid '$BORDER_WATCHER' >/dev/null 2>&1 & disown"
        offer "start the wallpaper-border reload watcher" "setsid '$BORDER_WATCHER' >/dev/null 2>&1 &"
    fi
else
    fail "border-color-healthcheck.sh" "missing or not executable — can't check colour chain" "$BORDER_CHECK" \
         "Restore it, then: chmod +x '$BORDER_CHECK'"
fi

# =============================================================================
# SUMMARY + PASTE-TO-CLAUDE BLOCK
# =============================================================================
n=${#FAILS[@]}
echo
echo "==================================================================="
if [ "$n" -eq 0 ]; then
    printf ' %sALL CHECKS PASSED.%s Nothing to do.\n' "$c_grn" "$c_off"
    echo "==================================================================="
else
    printf ' %s%d PROBLEM(S) FOUND.%s Paste the block below into Claude Code:\n' "$c_red" "$n" "$c_off"
    echo "==================================================================="
    echo
    echo "============ COPY EVERYTHING BELOW TO CLAUDE CODE ============="
    echo "MangoWM/DMS post-update health check found $n problem(s) on $(date '+%Y-%m-%d %H:%M')."
    echo
    echo "Versions:"
    printf '  mango:      %s%s\n' "$mango_ver"  "$([ -n "${OLD[mango]:-}" ] && [ "${OLD[mango]}" != "$mango_ver" ] && echo "   (was ${OLD[mango]})")"
    printf '  dms-shell:  %s%s\n' "$dms_ver"    "$([ -n "${OLD[dms]:-}" ]   && [ "${OLD[dms]}"   != "$dms_ver" ]   && echo "   (was ${OLD[dms]})")"
    printf '  quickshell: %s%s\n' "$qs_ver"     "$([ -n "${OLD[qs]:-}" ]    && [ "${OLD[qs]}"    != "$qs_ver" ]    && echo "   (was ${OLD[qs]})")"
    echo
    i=1
    for entry in "${FAILS[@]}"; do
        IFS="$US" read -r comp sym look fix <<< "$entry"
        echo "Problem $i — $comp"
        echo "  What broke:     $sym"
        echo "  Where to look:  $look"
        echo "  Known fix-notes: $fix"
        echo
        i=$((i+1))
    done
    echo "Please help me fix these without auto-editing anything until I confirm."
    echo "=============================================================="
fi

# =============================================================================
# OPTIONAL SAFE RE-APPLIES  (ask first; only restarts processes, never edits config)
# =============================================================================
if [ "${#OFFERS[@]}" -gt 0 ] && [ -t 0 ]; then
    echo
    echo "— Known safe re-applies available (each restarts a process only; no config changes) —"
    for entry in "${OFFERS[@]}"; do
        IFS="$US" read -r label cmd <<< "$entry"
        read -r -p "  Re-apply: $label ? [y/N] " ans
        case "$ans" in
            [yY]*) eval "$cmd" && echo "    done." || echo "    failed — do it by hand." ;;
            *)     echo "    skipped." ;;
        esac
    done
elif [ "${#OFFERS[@]}" -gt 0 ]; then
    echo
    echo "(${#OFFERS[@]} safe re-apply(s) available — re-run in a terminal to be prompted.)"
fi

# exit non-zero if anything failed, so it's scriptable in a pipeline
exit $(( n > 0 ? 1 : 0 ))
