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
#    tells you what's broken and gives you numbered, copy-paste fix steps that
#    need no AI tooling at all. If you happen to have Claude Code, a ready-made
#    paste block is offered underneath as an optional shortcut.
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
#    Each fail() call carries a 5th argument: the plain-English manual fix steps
#    shown to the user. Keep those lines under ~72 chars so they wrap cleanly.
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
US=$'\037'                      # unit separator to pack 5 fields per failure
FAILS=()                        # each entry: component US symptom US where US fix US manual
OFFERS=()                       # each entry: label US command-string (safe re-applies)

section() { printf '\n%s— %s —%s\n' "$c_dim" "$1" "$c_off"; }
pass()    { printf '  %s[PASS]%s %s\n' "$c_grn" "$c_off" "$1"; }
warn()    { printf '  %s[WARN]%s %s\n         %s\n' "$c_yel" "$c_off" "$1" "$2"; }
# fail COMPONENT SYMPTOM WHERE-TO-LOOK KNOWN-FIX MANUAL-STEPS
#   MANUAL-STEPS is the plain-English, numbered, no-AI-needed fix shown to the
#   user as the PRIMARY output. Keep it literal: exact commands, one line of
#   "why" per step. It's optional only so a future 4-arg call can't crash the run.
fail() {
    printf '  %s[FAIL]%s %s\n         %s\n' "$c_red" "$c_off" "$1" "$2"
    local manual="${5:-No step-by-step fix recorded for this one yet. See
\"Where to look\" in the Claude Code block below, and check the DankMango
Issues page: https://github.com/AhjinYeri/DankMango/issues}"
    FAILS+=("$1${US}$2${US}$3${US}$4${US}$manual")
}
# offer LABEL COMMAND  (queued; asked at the very end, only on a TTY)
offer() { OFFERS+=("$1${US}$2"); }

# indent a possibly-multi-line block by 4 spaces, for the report body
indent4() { printf '%s\n' "$1" | sed 's/^./    &/'; }   # blank lines stay truly blank

# tiny predicates
have()   { command -v "$1" >/dev/null 2>&1; }
execu()  { [ -x "$1" ]; }        # exists AND executable
# plugin_enabled ID -> true if plugin_settings.json has it with "enabled": true
plugin_enabled() { grep -Pzo "\"$1\"\s*:\s*\{[^}]*\"enabled\"\s*:\s*true" "$PLUGIN_SETTINGS" >/dev/null 2>&1; }

# ---- reusable manual-fix snippets (same failure shape in several places) -----
# A script file that's missing or has lost its "runnable" flag.
manual_restore_script() { # $1 = full path to the script
cat <<EOF
1. First find out which of the two problems you have. Type:
     ls -l $1
   ("ls -l" lists a file along with its permissions. If it says
   "No such file or directory", the file is MISSING - go to step 3.)

2. If the file DID show up, it just lost permission to run. Type:
     chmod +x $1
   ("chmod +x" marks a file as runnable. Without it the desktop
   silently refuses to start the script.) That's the fix - you're done.

3. If the file is missing, get it back from the DankMango repo. Open the
   folder you cloned DankMango into (the one containing install.sh), then:
     ./install.sh
   (install.sh re-copies every DankMango file into place. Use install.sh
   rather than update.sh here: update.sh only re-copies files that changed
   in the repo, so it won't notice one YOU are missing locally.)

4. Log out and back in so everything picks the restored file up.
EOF
}

# A DMS bar plugin that's switched off in plugin_settings.json.
manual_reenable_plugin() { # $1 = human name shown in DMS settings
cat <<EOF
1. Look at the bar across the top of your screen and click the settings
   (gear) icon to open DankMaterialShell's settings window.

2. Go to the "Plugins" section and switch "$1" back on.
   (A "plugin" here is one of the small custom buttons DankMango adds to
   that bar. Off in settings = the button is gone and its features stop.)

3. Still in settings, check the bar layout/widgets list actually contains
   "$1". Enabling a plugin does not re-add it to the bar if it
   was removed from the layout separately.

4. Restart the shell so the change takes effect. Open a terminal and type:
     dms restart
   ("the shell" = the bar, launcher and popups. Restarting it does not log
   you out or close your other windows.)

5. If "$1" is not listed in Plugins at all, its files are gone.
   Go to the folder you cloned DankMango into and run:
     ./install.sh
   then "dms restart" again. That re-installs and re-registers the plugins.
EOF
}

# mango renamed an mmsg verb/field; a script's wrapper has to be updated to match.
manual_mmsg_renamed() { # $1 = script to edit, $2 = function/var, $3 = what to look for
cat <<EOF
1. A MangoWM update renamed one of its own commands, so DankMango is now
   calling a name that no longer exists. First see the new list of names:
     mmsg --help
   ("mmsg" is the small program that sends instructions to MangoWM. Its
   --help output lists every instruction the installed version accepts.)

2. In that output, find the entry that replaced $3.
   Write the new name down exactly, spelling and punctuation included.

3. Open the script that still uses the old name:
     nano $1
   ("nano" is a simple text editor that runs inside the terminal. Move with
   the arrow keys - the mouse does nothing here.)

4. Press Ctrl+W to search, type $2 and press Enter. That
   jumps you to the line holding the old command. Replace the old name
   with the new one, leaving the rest of the line exactly as it is.

5. Press Ctrl+O then Enter to save, then Ctrl+X to quit nano.

6. Re-run this health check to confirm it now passes:
     $SCRIPTS/post-update-health.sh

If this feels like too much, it is genuinely a code change rather than a
setting - it is reasonable to open an issue at
https://github.com/AhjinYeri/DankMango/issues and wait for a repo update.
EOF
}

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
         "mango renamed the reload verb before (0.13 'mmsg -d reload_config' -> 0.14 'mmsg dispatch reload_config'). Run 'mmsg --help', find the new reload verb, update it in those files. It returns exit 0 even when wrong, so it fails SILENTLY." \
"WORKAROUND FIRST (works right now, no editing):
  Press Super+r whenever a setting doesn't seem to apply. That is the
  keyboard shortcut for \"reload settings\", and it goes straight to
  MangoWM without using the broken command. ("Super" is the key with
  the Windows logo.) Everything keeps working - it just needs that
  keypress instead of happening on its own.

PROPER FIX (a MangoWM update renamed the command, so 3 files need the
new name). Do the workaround above first, then when you have 10 minutes:

1. See what the reload command is called now:
     mmsg --help
   (\"mmsg\" is the small program that sends instructions to MangoWM.
   Its --help output lists every instruction this version accepts.)

2. Find the line that mentions reloading the config. Note the exact
   wording, e.g. it might now be \"mmsg dispatch reloadconfig\".

3. Open the first file:
     nano $MONITOR_SETTER
   (\"nano\" is a plain text editor inside the terminal; arrow keys move
   the cursor, the mouse does nothing.) Press Ctrl+W, type
   mango_reload_config and press Enter to jump to the right line.
   Replace the old command with the new wording.
   Save with Ctrl+O then Enter, and quit with Ctrl+X.

4. Do exactly the same in the second file:
     nano $BORDER_WATCHER
   searching (Ctrl+W) for RELOAD_CMD this time.

5. And the third, so this health check stops reporting it:
     nano $SCRIPTS/post-update-health.sh
   searching for RELOAD_CMD.

6. Check it worked:
     $SCRIPTS/post-update-health.sh

If you'd rather not edit files, keep using Super+r and open an issue at
https://github.com/AhjinYeri/DankMango/issues - this needs a repo fix."
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
         "Re-generate them: $TAGRULES_GEN  (detects your monitors via 'mmsg get all-monitors' and writes the file, then Super+r). Fresh installs run this automatically; if it's empty, mango probably wasn't running when it ran — re-run it now. (A monitor FLOATS once its rules gain open_as_floating:1, set via the Monitor Mode plugin.)" \
"This one is a single command. MangoWM needs to be told the names of your
actual monitors before per-monitor tile/float can work, and that list is
missing or empty.

1. Make sure you are logged in to the MangoWM desktop right now (not a
   different desktop, not a text-only console). The next command asks
   MangoWM which screens are plugged in, so MangoWM has to be running.

2. Open a terminal (press Super+Return - \"Super\" is the Windows-logo
   key) and type:
     $TAGRULES_GEN
   (That script asks MangoWM what monitors you have and writes one rule
   block per monitor into a settings file. A \"rule\" here just records
   whether that screen tiles windows or floats them.)

3. Press Super+r to make MangoWM re-read its settings.

4. Confirm it actually wrote something:
     cat $TAGRULES_FILE
   (\"cat\" prints a file's contents to the screen.) You should see one
   or more lines beginning with \"tagrule =\". If the file is empty or
   still missing, MangoWM wasn't running in step 1 - log in properly and
   redo step 2.

5. Your monitors all start in tile mode. Use the Monitor Mode button on
   the bar to flip one to floating - you never need to edit this file
   by hand.

Note: re-run this same command any time you plug in or unplug a monitor."
fi

# 1c. helper scripts present + executable
execu "$MONITOR_SETTER" && pass "set-monitor-mode.sh present & executable" \
    || fail "set-monitor-mode.sh" "missing or not executable" "$MONITOR_SETTER" "Restore it, then: chmod +x '$MONITOR_SETTER'" \
            "$(manual_restore_script "$MONITOR_SETTER")

What breaks meanwhile: the Monitor Mode button on the bar can't switch a
screen between tiling and floating. Nothing else is affected."
execu "$DP2_HELPER" && pass "dp2-floatsize.sh present & executable" \
    || fail "dp2-floatsize.sh" "missing or not executable" "$DP2_HELPER" "Restore it, then: chmod +x '$DP2_HELPER'" \
            "$(manual_restore_script "$DP2_HELPER")

What breaks meanwhile: windows on a floating monitor open at the wrong
size. You can still drag/resize them by hand, so this is cosmetic."

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
         "Add:  exec-once = ~/.config/mango/scripts/dp2-floatsize.sh   then reload (SUPER+r)." \
"A small background program that sizes floating windows sensibly isn't
running, and isn't set to start when you log in either. Two steps: start
it now, then make it start automatically from then on.

1. Start it for this session. Open a terminal (Super+Return) and type:
     setsid $DP2_HELPER >/dev/null 2>&1 &
   (\"setsid ... &\" starts the program in the background and detaches it,
   so it keeps running after you close the terminal. The \">/dev/null 2>&1\"
   part just stops it printing chatter at you.)

2. Now make it automatic. Open MangoWM's main settings file:
     nano $MANGO_CFG
   (\"nano\" is a text editor inside the terminal. Arrow keys move the
   cursor; the mouse won't work.)

3. Press Ctrl+W, type exec-once and press Enter. That jumps you to the
   list of programs MangoWM starts at login. (\"exec-once\" literally means
   \"run this one thing when the desktop starts\".)

4. Move to the end of that group of lines and add a new line, exactly:
     exec-once = ~/.config/mango/scripts/dp2-floatsize.sh

5. Save with Ctrl+O then Enter. Quit with Ctrl+X.

6. Press Super+r to reload MangoWM's settings.

7. Re-run this health check - it should now report the helper as running:
     $SCRIPTS/post-update-health.sh"
fi

# 1e. the mango IPC the helper depends on (focus + client list w/ fields it reads)
if "${CLIENTS_CMD[@]}" 2>/dev/null | grep -q '"is_floating"'; then
    pass "window-list IPC OK (${CLIENTS_CMD[*]} exposes is_floating/appid)"
else
    fail "Window-list IPC for float helper" "'${CLIENTS_CMD[*]}' missing or lost the is_floating field" \
         "$DP2_HELPER (its mango_* command wrappers)" \
         "mango renamed the command or a JSON field. Run '${CLIENTS_CMD[*]}' and 'mmsg --help'; update the wrappers in dp2-floatsize.sh (it reads is_floating, appid, monitor)." \
"A MangoWM update changed how it reports your open windows, so the
float-sizing helper can no longer understand the answer it gets back.

Impact first, so you can judge whether to bother: floating windows open
at the wrong size. Tiling, theming, Alt+Tab and audio are unaffected. If
that doesn't annoy you, it is completely safe to ignore this.

1. See what MangoWM reports now. Type:
     ${CLIENTS_CMD[*]}
   (That prints a list of your open windows as JSON - a machine-readable
   format full of \"name\": value pairs. It will look dense; that's fine.)

2. Look through that output for a field describing whether a window is
   floating. It used to be called is_floating. It may now be spelled
   differently, e.g. \"floating\" or \"isFloating\". Note the exact spelling.
   If there is no such field at all, stop here and report it at
   https://github.com/AhjinYeri/DankMango/issues - nothing you can type
   will fix that, it needs a repo update.

3. If you did find a renamed field, open the helper:
     nano $DP2_HELPER
   (\"nano\" is a terminal text editor; arrow keys move, mouse does not.)

4. Press Ctrl+W, type is_floating and press Enter to jump to it. Replace
   each occurrence with the new spelling from step 2. Press Ctrl+W then
   Enter again to find the next one, until there are no more.
   (It also reads fields named appid and monitor - check in step 1's
   output that those two still exist and rename them the same way if not.)

5. Save with Ctrl+O then Enter, quit with Ctrl+X.

6. Restart the helper so it picks up your edit:
     pkill -f dp2-floatsize.sh
     setsid $DP2_HELPER >/dev/null 2>&1 &
   (\"pkill -f\" stops a running program by name; the second line starts
   it again in the background.)"
fi

# 1f. plugin enabled
plugin_enabled monitorMode && pass "monitorMode plugin enabled" \
    || fail "monitorMode plugin" "not enabled in plugin_settings.json" "$PLUGIN_SETTINGS" \
            "Re-enable: DMS Settings -> Plugins -> Monitor Mode on; confirm it's in the bar layout too. Then 'dms restart'." \
            "$(manual_reenable_plugin "Monitor Mode")

What breaks meanwhile: you lose the bar button that flips a screen
between tiling and floating. Your monitors keep whatever mode they were
last set to."

# =============================================================================
# 2. AUDIO OUTPUT-SWITCHER PLUGIN (audioToggle)
# =============================================================================
section "2. Audio output-switcher plugin"
plugin_enabled audioToggle && pass "audioToggle plugin enabled" \
    || fail "audioToggle plugin" "not enabled in plugin_settings.json" "$PLUGIN_SETTINGS" \
            "Re-enable via DMS Settings -> Plugins, confirm it's in the bar, then 'dms restart'." \
            "$(manual_reenable_plugin "Audio Toggle")

What breaks meanwhile: you lose the bar button that swaps between
speakers and headphones. Sound still works - you can switch outputs the
long way round through your normal audio settings."

have wpctl || have pactl && pass "audio backend present (wpctl/pactl)" \
    || fail "audio backend" "neither wpctl nor pactl found" "PATH / packages" "Install wireplumber (wpctl) or libpulse (pactl)." \
"The system tool DankMango uses to change audio devices isn't installed.
This is unusual - it normally means an update removed an audio package.

1. Install it. Open a terminal (Super+Return) and type:
     sudo pacman -S wireplumber
   (\"pacman\" is the program that installs software on CachyOS/Arch - each
   piece of software is called a \"package\". \"sudo\" means run this as
   administrator, so it will ask for your password. Nothing appears on
   screen while you type the password - that is normal, just type it and
   press Enter.)

2. When it asks to confirm, press Enter to accept.

3. Check it's working:
     wpctl status
   (That prints your sound devices. Seeing a list means it's fixed.)

4. If sound itself is also broken, reinstall the whole audio stack:
     sudo pacman -S pipewire pipewire-pulse wireplumber
   then reboot with:
     reboot"

# 2b. combined-audio-OSD patch on DMS's package-owned VolumeOSD.qml (dms updates wipe it)
if [ ! -f "$VOLUME_OSD" ]; then
    fail "combined audio OSD patch" "VolumeOSD.qml not found where expected -- DMS may have moved/renamed it" \
         "expected $VOLUME_OSD; find it: pacman -Ql dms-shell | grep VolumeOSD.qml" \
         "Update VOLUME_OSD in this script's EDIT HERE block to the new path, then re-run $OSD_APPLY (edit its TARGET to match too)." \
"A DMS update moved the file DankMango patches to show the device name in
the volume popup. Nothing is broken as such - volume control and audio
switching both work fine. You just won't see the device name in the popup.

1. Find out where the file went. Type:
     pacman -Ql dms-shell | grep VolumeOSD.qml
   (\"pacman -Ql\" lists every file that a package put on your system, and
   \"grep\" filters that long list down to lines containing the text you
   asked for. The \"|\" pipes the first command's output into the second.)

2. If that printed a path, DMS just moved the file. Note the path, then:
     nano $SCRIPTS/post-update-health.sh
   Press Ctrl+W, type VOLUME_OSD, press Enter, and change the path on that
   line to the one you found. Ctrl+O then Enter to save, Ctrl+X to quit.

3. Do the same in the patch script:
     nano $OSD_APPLY
   searching (Ctrl+W) for TARGET and updating that path too.

4. Now apply the patch at its new home:
     $OSD_APPLY
   then:
     dms restart

5. If step 1 printed NOTHING, DMS removed this file entirely and the patch
   no longer has anywhere to go. There is no fix to type - the feature is
   gone until DankMango is updated for the new DMS. Please report it at
   https://github.com/AhjinYeri/DankMango/issues so it can be updated.
   Everything else on your system is unaffected."
elif grep -qF "$OSD_PATCH_MARKER" "$VOLUME_OSD"; then
    pass "combined audio OSD patch present (output switch shows one popup: icon + device name + slider)"
else
    fail "combined audio OSD patch" \
         "VolumeOSD.qml lost the DankMango patch -- an output switch shows the volume OSD with NO device name (and may stack a 2nd popup)" \
         "$VOLUME_OSD (marker '$OSD_PATCH_MARKER'); re-applied by $OSD_APPLY" \
         "A dms-shell update overwrote this package-owned file. Re-apply the patch (idempotent, backs up first, needs sudo):  $OSD_APPLY   then 'dms restart'." \
"This is expected after a DMS update and is a one-command fix. DankMango
adds the device name to the volume popup by editing a file that DMS itself
owns - so every DMS update overwrites it and wipes the change.

1. Re-apply the patch. Open a terminal (Super+Return) and type:
     $OSD_APPLY
   (It makes a backup copy first, and it is safe to run as many times as
   you like - running it twice does not apply the change twice.)

2. It will ask for your password, because the file it edits belongs to the
   system rather than to you. Type your password and press Enter - nothing
   appears on screen as you type it, which is normal.

3. Restart the shell so the new popup is used:
     dms restart
   (\"the shell\" means the bar, launcher and popups. This does not log you
   out or close your open windows.)

4. Test it: switch between speakers and headphones using the audio button
   on the bar. You should get ONE popup showing the device name, its icon
   and the volume slider together.

If you would rather not have this patch at all, it is entirely optional -
just ignore this warning. You'll get the plain volume popup with no device
name, and nothing else changes."
fi

# =============================================================================
# 3. ALT-TAB SWITCHER PLUGIN (altSwitcher)   -- includes the crash canary
# =============================================================================
section "3. Alt-Tab switcher plugin"
plugin_enabled altSwitcher && pass "altSwitcher plugin enabled" \
    || fail "altSwitcher plugin" "not enabled in plugin_settings.json" "$PLUGIN_SETTINGS" \
            "Re-enable via DMS Settings -> Plugins, confirm it's in the bar, then 'dms restart'." \
            "$(manual_reenable_plugin "Alt Switcher")

What breaks meanwhile: Alt+Tab won't show the visual window picker. It may
still cycle windows without showing anything."

execu "$ALTTAB_SCRIPT" && pass "alt-switcher.sh present & executable" \
    || fail "alt-switcher.sh" "missing or not executable" "$ALTTAB_SCRIPT" "Restore it, then: chmod +x '$ALTTAB_SCRIPT'" \
            "$(manual_restore_script "$ALTTAB_SCRIPT")

What breaks meanwhile: pressing Alt+Tab does nothing at all. You can still
switch windows by clicking them, or with Super and the number keys."

grep -q 'alt-switcher.sh' "$MANGO_CFG" \
    && pass "Alt+Tab binds point at alt-switcher.sh" \
    || fail "Alt+Tab keybinds" "config.conf has no bind calling alt-switcher.sh" "$MANGO_CFG" \
            "Re-add:  bind = ALT, Tab, spawn, $ALTTAB_SCRIPT next   and  bind = ALT+SHIFT, Tab, spawn, $ALTTAB_SCRIPT prev   then SUPER+r." \
"MangoWM has no instruction telling it what Alt+Tab should do, so the key
combination currently does nothing. You need to add two lines to its
settings file. (A \"keybind\" is just a saved rule that says \"when I press
these keys, run this\".)

1. Open MangoWM's settings file in a terminal editor:
     nano $MANGO_CFG
   (\"nano\" runs inside the terminal. Arrow keys move the cursor - the
   mouse does nothing in here.)

2. Press Ctrl+W, type bind = and press Enter. That jumps you to the block
   where all the other keyboard shortcuts live, so your new ones sit with
   the rest rather than in a random spot.

3. Add these two lines, exactly as written (each is one single line):
     bind = ALT, Tab, spawn, $ALTTAB_SCRIPT next
     bind = ALT+SHIFT, Tab, spawn, $ALTTAB_SCRIPT prev
   (The first steps forward through your windows, the second steps back.)

4. Save with Ctrl+O then press Enter. Quit with Ctrl+X.

5. Press Super+r to make MangoWM re-read the file. (\"Super\" is the key
   with the Windows logo on it.)

6. Test it by holding Alt and tapping Tab. If nothing happens, re-open the
   file and check for typos - the paths must match exactly, including the
   word \"next\" or \"prev\" at the end."

# 3a. duplicate-handler check — the exact signature of the quickshell-0.3.0-2 crash
if [ -n "$QS_LOG" ] && grep -q 'another handler is registered for target altswitcher' "$QS_LOG" 2>/dev/null; then
    fail "altSwitcher duplicate IPC handler (CRASH RISK)" \
         "two 'altswitcher' handlers registered — newer quickshell SEGFAULTS the whole shell when Alt+Tab invokes it" \
         "AltSwitcherBar.qml (the isPrimaryInstance Loader) + README 'crashes the whole shell'" \
         "The IpcHandler+DankModal must live inside the 'engine' Loader gated by isPrimaryInstance (one handler only). Never put IpcHandler at the plugin root. Then 'dms restart'." \
"IMPORTANT: while this is unfixed, pressing Alt+Tab can crash your whole
bar and launcher. Avoid Alt+Tab until it's sorted - click windows or use
Super plus a number key to switch instead.

Be honest with yourself about this one: it is a bug in the plugin's own
code, not a setting you got wrong. There is nothing sensible to hand-edit.
Your two real options:

OPTION A - get the fixed version from the repo (try this first).
1. Open the folder you cloned DankMango into (the one with install.sh in
   it) in a terminal, then download the latest version:
     git pull
   (\"git pull\" fetches the newest DankMango files from GitHub.)
2. Apply it:
     ./update.sh
3. Restart the shell:
     dms restart
4. Re-run this health check to see whether it's gone:
     $SCRIPTS/post-update-health.sh

OPTION B - if it still fails, switch the plugin off so you can't trigger
the crash by accident.
1. Click the gear icon on the bar to open DankMaterialShell settings.
2. Go to Plugins and turn \"Alt Switcher\" off.
3. In a terminal, type:
     dms restart
4. Report it at https://github.com/AhjinYeri/DankMango/issues - mention
   your quickshell version, shown at the top of this health check."
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
             "Same class as the duplicate-handler crash. Verify the isPrimaryInstance Loader gate; read the newest crash report.txt stacktrace." \
"This check pressed Alt+Tab for you, and it crashed your bar and launcher.
They will have restarted themselves, so your desktop is usable - but
Alt+Tab will crash them again every time until this is fixed.

DO THIS FIRST: don't use Alt+Tab. Switch windows by clicking them, or by
holding Super and pressing a number key.

Like the duplicate-handler problem, this is a fault in the plugin's code
rather than a setting, so there is no config to correct by hand.

1. Get the newest DankMango files. In the folder you cloned DankMango into
   (the one containing install.sh), type:
     git pull
     ./update.sh
   (\"git pull\" downloads the latest version; update.sh installs it.)

2. Restart the shell:
     dms restart

3. Re-run this health check to see whether the crash is gone:
     $SCRIPTS/post-update-health.sh

4. If it still crashes, turn the plugin off so you stop hitting it: click
   the gear icon on the bar, go to Plugins, switch \"Alt Switcher\" off,
   then run \"dms restart\" in a terminal.

5. Please report it, since this one needs fixing in the repo. Attach the
   crash log - find the newest one with:
     ls -t ~/.cache/quickshell/crashes/
   (\"ls -t\" lists files newest-first, so the top entry is your crash.)
   Then read it with:
     cat ~/.cache/quickshell/crashes/PASTE_TOP_NAME_HERE/report.txt
   replacing PASTE_TOP_NAME_HERE with that top entry. Copy the output into
   an issue at https://github.com/AhjinYeri/DankMango/issues"
    fi
else
    fail "quickshell not running" "qs process not found — the DMS shell is down" "run 'dms run' output / journal" \
         "Start it: 'dms run &' (or relog). If it won't stay up, check the newest ~/.cache/quickshell/crashes/*/report.txt." \
"Your bar, launcher and popups aren't running at all. (Collectively they
are called \"the shell\" - the program that draws them is quickshell.) Your
windows and keyboard shortcuts still work, which is why you can read this.

1. Try starting it. Open a terminal (Super+Return) and type:
     dms run &
   (The \"&\" at the end means \"keep running in the background\", so you get
   your terminal prompt back instead of it being tied up.)

2. Watch for a few seconds. If the bar appears and stays, you're done.

3. If nothing appears, or it vanishes again, log out and back in - a lot
   of update-related breakage clears on a fresh login.

4. If it still won't start, a full restart is the next thing to try:
     reboot

5. If it is still down after that, look at why it crashed:
     ls -t ~/.cache/quickshell/crashes/
   (\"ls -t\" lists files newest-first, so the first entry is the most
   recent crash.) Then read that report:
     cat ~/.cache/quickshell/crashes/PASTE_TOP_NAME_HERE/report.txt
   replacing PASTE_TOP_NAME_HERE with the first entry from the list.

6. A shell that won't start after an update usually needs the packages
   reinstalled. Type:
     sudo pacman -S dms-shell quickshell
   (\"pacman\" installs software; \"sudo\" runs it as administrator and will
   ask for your password - nothing shows as you type it, that's normal.)
   Then log out and back in. If that fails too, copy the report.txt text
   into an issue at https://github.com/AhjinYeri/DankMango/issues"
fi

# 3c. focus-cycle command the wiring script relies on
"${FOCUSSTACK_CMD[@]}" 2>/dev/null | grep -q '"success"' \
    && pass "focus-cycle IPC works (${FOCUSSTACK_CMD[*]})" \
    || fail "focus-cycle IPC" "'${FOCUSSTACK_CMD[*]}' failed — Alt+Tab won't change focus" "$ALTTAB_SCRIPT (mango_cycle_focus)" \
            "mango renamed focusstack. Run 'mmsg --help', update mango_cycle_focus in alt-switcher.sh." \
            "$(manual_mmsg_renamed "$ALTTAB_SCRIPT" "mango_cycle_focus" "focusstack")

What breaks meanwhile: the Alt+Tab picker may appear but releasing Alt
won't actually switch to the window you chose. Click the window instead."

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
$bc_detail" \
"Your window borders have stopped following your wallpaper's colours.
Everything still works normally - this is purely how it looks.

1. Get the detail. A second script checks this in three separate stages
   and will tell you which stage broke. Open a terminal (Super+Return):
     $BORDER_CHECK
   Read which line says FAIL, then follow the matching step below.

2. IF IT SAYS THE COLOURS FILE IS MISSING OR EMPTY - the colours are
   generated from your wallpaper, so re-generate them by simply setting
   your wallpaper again from the DankMaterialShell settings (gear icon on
   the bar). Then press Super+r. Check something was written with:
     cat $COLORS_FILE
   (\"cat\" prints a file's contents. You want to see lines mentioning
   bordercolor / focuscolor and a colour code like #a1b2c3.)

3. IF IT SAYS CONFIG.CONF IS OVERRIDING THE COLOURS - this is the most
   common cause. MangoWM 0.14 obeys the FIRST setting it reads and ignores
   later ones, so a colour written directly in your main config file wins
   over the wallpaper-generated one. Open the file:
     nano $MANGO_CFG
   Press Ctrl+W, type bordercolor and press Enter. If you find a line like
   \"bordercolor = 0xff...\" sitting outside the COLOR CHAIN section, put a
   # character at the very start of that line, like this:
     # bordercolor = 0xff444444
   (A line beginning with # is a \"comment\" - MangoWM skips it entirely.)
   Do the same for any focuscolor line. Save with Ctrl+O then Enter, quit
   with Ctrl+X, then press Super+r.

4. IF IT SAYS THE RELOAD COMMAND FAILED - that is the same underlying
   problem as the \"MangoWM config reload command\" entry in this report.
   Fix that one first, then re-run this check; this will usually clear.

5. If all three stages pass but the colours still look wrong, restart the
   watcher that applies them:
     pkill -f wallpaper-border-reload.sh
     setsid $BORDER_WATCHER >/dev/null 2>&1 &
   (\"pkill -f\" stops a running program by name; the second line starts it
   again in the background, detached from your terminal.)"
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
         "Restore it, then: chmod +x '$BORDER_CHECK'" \
         "$(manual_restore_script "$BORDER_CHECK")

What breaks meanwhile: nothing visible. This file is only a checker - its
absence means this health check can't test your border colours, not that
the colours themselves are broken."
fi

# =============================================================================
# SUMMARY  --  manual fix steps first, optional Claude Code block second
# =============================================================================
n=${#FAILS[@]}
echo
echo "==================================================================="
if [ "$n" -eq 0 ]; then
    printf ' %sALL CHECKS PASSED.%s Nothing to do.\n' "$c_grn" "$c_off"
    echo "==================================================================="
else
    printf ' %s%d PROBLEM(S) FOUND.%s Step-by-step fixes below.\n' "$c_red" "$n" "$c_off"
    echo "==================================================================="

    # ---- orientation, printed once rather than repeated in every entry ------
    printf '\n%sBEFORE YOU START%s\n' "$c_yel" "$c_off"
    cat <<'EOF'
  * To open a terminal (the window where you type commands), press
    Super+Return. "Super" is the key with the Windows logo on it.
  * Type each command exactly as shown, then press Enter. Commands are
    case-sensitive: Nano and nano are not the same thing.
  * A command starting with "sudo" runs as administrator and will ask for
    your password. Nothing appears on screen while you type it - that is
    normal, just type it and press Enter.
  * Nothing below deletes anything. If a step doesn't work, you can stop
    and nothing will be worse than it is now.
  * You do NOT need Claude Code or any AI tool. These steps are complete
    on their own.
EOF

    i=1
    for entry in "${FAILS[@]}"; do
        # -d '' so multi-line fields (manual steps, sub-check detail) survive intact
        IFS="$US" read -r -d '' comp sym look fix manual <<< "$entry"
        manual="${manual%$'\n'}"
        printf '\n%s───────────────────────────────────────────────────────────────%s\n' "$c_dim" "$c_off"
        printf ' %sPROBLEM %d of %d — %s%s\n' "$c_red" "$i" "$n" "$comp" "$c_off"
        printf '%s───────────────────────────────────────────────────────────────%s\n' "$c_dim" "$c_off"
        printf '\n  %sWhat is wrong%s\n' "$c_yel" "$c_off"
        indent4 "$sym"
        printf '\n  %sHow to fix it yourself%s\n' "$c_grn" "$c_off"
        indent4 "$manual"
        i=$((i+1))
    done

    # ---- optional: the old paste-to-Claude path, clearly secondary ---------
    echo
    printf '%s═══════════════════════════════════════════════════════════════%s\n' "$c_dim" "$c_off"
    printf ' %sPrefer to use Claude Code instead?%s\n' "$c_dim" "$c_off"
    printf '%s═══════════════════════════════════════════════════════════════%s\n' "$c_dim" "$c_off"
    echo " This part is only useful if you already have Claude Code installed."
    echo " If you don't, ignore everything below — the steps above are the"
    echo " complete fix and need no AI tooling. Otherwise, paste this block in."
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
        IFS="$US" read -r -d '' comp sym look fix manual <<< "$entry"
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
