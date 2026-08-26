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
#    It covers:
#      1. Per-monitor tiling + the Window Mode bar plugin (monitorMode), and the
#         generated game-display rules that send Steam games to one screen
#      2. The audio output-switcher plugin (audioToggle) + the combined-audio-OSD
#         patch on DMS's VolumeOSD.qml
#      3. The visual Alt+Tab switcher plugin (altSwitcher)
#      4. Dynamic window-border / theme colouring (the "colour chain")
#      5. The in-session help hub (SUPER+SHIFT+/)
#      6. Screenshot annotation (Print / Shift+Print / Ctrl+Print)
#      7. The first-run welcome panel (firstRunPanel)
#      8. That update.sh's pre-update snapper snapshot actually landed
#      9. That the DankMango scripts you're actually running are the shipped
#         ones -- update.sh only re-copies what changed in its commit range, so
#         a file it ever misses stays stale until install.sh is run again
#     10. Desktop presets (the sourced preset symlink mango reads in silence)
#     11. The DMS keybind-injection guard
#     12. Ripe Chroma, the wallpaper colour engine -- that the binary runs, that
#         everything calling it still agrees where it is, that the LIVE watcher
#         isn't running pre-rename code, and that the palette DMS is actually
#         displaying is intact and still matches the current wallpaper
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

# CMD lines are what docs-hub.sh's command list shows: a real, runnable command
# and a short description, separated by " :: ". They live here, next to the code
# that implements them, so the hub stores no copy of its own. Add a line when you
# add a flag worth showing; the fuller explanation stays in the Usage block above.
# CMD: ~/.config/mango/scripts/post-update-health.sh :: check everything a mango or DMS update can quietly break

# --help prints the header block above. This script takes no options, but it
# needs a real --help arm all the same: docs-hub.sh's command menu shells out
# to `<script> --help`, and without this it would RUN the whole health check
# instead of describing it.
self_help() { awk 'NR>2 && !/^#/{exit} NR>2 && sub(/^#[ ]?/,"")' "$0"; }
case "${1:-}" in -h|--help) self_help; exit 0 ;; esac

# ------ ########## EDIT HERE AFTER A MANGO / DMS UPDATE ########## ------------
MANGO_CFG="$HOME/.config/mango/config.conf"
DMS_DIR="$HOME/.config/DankMaterialShell"
PLUGIN_SETTINGS="$DMS_DIR/plugin_settings.json"
BAR_SETTINGS="$DMS_DIR/settings.json"
SCRIPTS="$HOME/.config/mango/scripts"

# Per-monitor tagrules now live in an auto-generated, sourced file (not inline in
# config.conf). generate-tagrules.sh writes it.
TAGRULES_FILE="$HOME/.config/mango/dms/tagrules.conf"
TAGRULES_GEN="$SCRIPTS/generate-tagrules.sh"

# The hotplug watcher that re-runs the generator (and re-applies your layouts)
# whenever a monitor is plugged in or unplugged. Started from config.conf's
# exec-once; single-instance via this lock, so the lock is how we detect it.
MONITOR_WATCHER="$SCRIPTS/monitor-watcher.sh"
MONITOR_WATCHER_LOCK="/tmp/mango-monitor-watcher.lock"

# The watcher's OUTPUT: generated windowrules that send Steam games to the chosen
# game display. Which display that is comes from .userPrefs.mainDisplay in the
# install manifest (the stored key keeps its original name; only the wording
# shown to people is "game display"). Both are checked together because they have to agree: a stored
# display with no rules file means games open on the wrong monitor, and a rules
# file with nothing stored means stale rules nobody asked for.
MAINRULES_FILE="$HOME/.config/mango/dms/mainmonitor.conf"
DANKMANGO_MANIFEST="${XDG_STATE_HOME:-$HOME/.local/state}/dankmango/manifest.json"

COLORS_FILE="$HOME/.config/mango/dms/colors.conf"
BORDER_CHECK="$SCRIPTS/border-color-healthcheck.sh"       # delegated colour-chain check
BORDER_WATCHER="$SCRIPTS/wallpaper-border-reload.sh"
BORDER_LOCK="/tmp/mango-wallpaper-border-reload.lock"

ALTTAB_SCRIPT="$SCRIPTS/alt-switcher.sh"

# Desktop presets. config.conf includes ONE fixed path -- a symlink into a preset
# folder -- and the include is source-OPTIONAL, which is exactly why this needs
# checking: mango reads a DANGLING link in complete silence (measured on 0.16.0:
# no error, no warning, exit 0). So the failure this catches -- an update removed
# a preset folder the link still points at -- has no symptom other than "my preset
# quietly stopped applying". Nothing else in the system will ever mention it.
PRESETS_DIR="$HOME/.config/mango/presets"
PRESET_LINK="$HOME/.config/mango/active/preset.conf"
PRESET_SETTER="$SCRIPTS/set-preset.sh"
PRESET_ID="presetSwitcher"                          # the DMS plugin id
PRESET_PLUGIN_DIR="$DMS_DIR/plugins/$PRESET_ID"

# The first-run welcome panel. Unlike the other three plugins this one is a `daemon`
# plugin with no bar presence and no IPC handler, so there is NOTHING to poke at
# runtime -- see section 7 for what can and can't be established about it.
FRP_ID="firstRunPanel"
FRP_DIR="$DMS_DIR/plugins/$FRP_ID"
FRP_FILES=(FirstRunPanel.qml plugin.json)          # what install.sh deploys (README.md too, but it isn't load-bearing)
FRP_REPO_SUBDIR="plugins/first-run-panel"          # where those come from in the clone

# In-session help hub (SUPER+SHIFT+/). The hub reads its shortcut DESCRIPTIONS
# live from config.conf and stores none itself, so the thing that can rot is
# keys.tsv listing a key config.conf no longer has. `docs-hub.sh check` is what
# detects that, and it exits non-zero when it does.
# NOTE: the guide is DESKTOP-GUIDE.md, not GUIDE.md -- the repo already has a
# docs/GUIDE.md (the GitHub-facing project guide) and they are different files.
DOCSHUB_SCRIPT="$SCRIPTS/docs-hub.sh"
DOCSHUB_DOCS="$HOME/.config/mango/docs"
DOCSHUB_KEYS="$DOCSHUB_DOCS/keys.tsv"
DOCSHUB_GUIDE="$DOCSHUB_DOCS/DESKTOP-GUIDE.md"

# Package-owned-file patches (the combined audio OSD one, and any added later).
# This script deliberately knows NOTHING about individual patches any more -- no
# target paths, no marker strings, no per-patch re-apply script names. It asks the
# dispatcher, which owns the registry, and renders whatever comes back:
#     apply-patches.sh status --porcelain
#       -> id \t state \t title \t target \t package \t blurb \t verify \t restart
# So a patch added to the registry is checked here automatically, and the one
# command below is what users are told to run regardless of which patch went stale.
PATCH_DISPATCH="$SCRIPTS/apply-patches.sh"

# Commands mango/DMS updates have renamed before. Test-forms used by the checks:
RELOAD_CMD=(mmsg dispatch reload_config)   # 0.13 was `mmsg -d reload_config` (now dead)
FOCUSSTACK_CMD=(mmsg dispatch focusstack,next)

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
# wrap WIDTH INDENT TEXT -- fold a string that came from a registry into the
# hand-wrapped prose around it. Everything else in this script is wrapped to ~72
# columns by hand; a patch's blurb/verify text arrives as one long line and would
# otherwise run off the terminal. Continuation lines get INDENT spaces so they sit
# under the start of the sentence rather than under a step number.
wrap() { printf '%s' "$3" | fold -s -w "$1" | awk -v i="$2" 'NR==1{print;next}{printf "%*s%s\n", i, "", $0}'; }
# note -- neither pass nor fail: a thing that is deliberately switched off. Used for
# opt-in patches the user declined, which are NOT problems and must not be counted
# as failures (the old code reported one as FAIL on every single run).
note()    { printf '  %s[ -- ]%s %s\n' "$c_dim" "$c_off" "$1"; }
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

If this feels like too much, that's fair - it's a code change, not a
setting. Open an issue at https://github.com/AhjinYeri/DankMango/issues
and wait for a repo update instead.
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
         "$BORDER_WATCHER (RELOAD_CMD) and RELOAD_CMD in this script" \
         "mango renamed the reload verb before (0.13 'mmsg -d reload_config' -> 0.14 'mmsg dispatch reload_config'). Run 'mmsg --help', find the new reload verb, update it in those files. It returns exit 0 even when wrong, so it fails SILENTLY." \
"WORKAROUND FIRST (works right now, no editing):
  Press Super+r whenever a setting doesn't seem to apply. That's the
  keyboard shortcut for \"reload settings\", and it goes straight to
  MangoWM without touching the broken command. ("Super" is the key with
  the Windows logo.) Everything keeps working - it just needs that
  keypress instead of happening on its own.

PROPER FIX (a MangoWM update renamed the command, so 2 files need the
new name). Do the workaround above first, then when you've got 10 minutes:

1. See what the reload command is called now:
     mmsg --help
   (\"mmsg\" is the small program that sends instructions to MangoWM.
   Its --help output lists every instruction this version accepts.)

2. Find the line that mentions reloading the config. Note the exact
   wording, e.g. it might now be \"mmsg dispatch reloadconfig\".

3. Open the first file:
     nano $BORDER_WATCHER
   (\"nano\" is a plain text editor inside the terminal; arrow keys move
   the cursor, the mouse does nothing.) Press Ctrl+W, type
   RELOAD_CMD and press Enter to jump to the right line.
   Replace the old command with the new wording.
   Save with Ctrl+O then Enter, and quit with Ctrl+X.

4. And the second, so this health check stops reporting it:
     nano $SCRIPTS/post-update-health.sh
   searching for RELOAD_CMD.

5. Check it worked:
     $SCRIPTS/post-update-health.sh

If you'd rather not edit files at all, keep using Super+r and open an issue
at https://github.com/AhjinYeri/DankMango/issues - this needs a repo fix."
fi

# 1b. tagrules (per-monitor mode storage) present. They now live in the auto-
#     generated dms/tagrules.conf (sourced by config.conf); we accept either that
#     file OR inline config.conf rules (the manual-fallback path) as valid.
if { [ -f "$TAGRULES_FILE" ] && grep -qE '^[[:space:]]*tagrule[[:space:]]*=' "$TAGRULES_FILE"; } \
   || grep -qE '^[[:space:]]*tagrule[[:space:]]*=' "$MANGO_CFG"; then
    pass "per-monitor tagrules present (dms/tagrules.conf or config.conf)"
else
    fail "Per-monitor tagrules" "no tagrules in dms/tagrules.conf — per-monitor layout is not active" \
         "$TAGRULES_FILE (auto-generated; sourced by config.conf)" \
         "Re-generate them: $TAGRULES_GEN  (detects your monitors via 'mmsg get all-monitors' and writes the file, then Super+r). Fresh installs run this automatically; if it's empty, mango probably wasn't running when it ran — re-run it now." \
"This one is a single command. MangoWM has to be told the names of your
actual monitors before per-monitor layout can work, and that list is
missing or empty.

1. Make sure you're logged in to the MangoWM desktop right now (not a
   different desktop, not a text-only console). The next command asks
   MangoWM which screens are plugged in, so MangoWM has to be running.

2. Open a terminal (press Super+Return - \"Super\" is the Windows-logo
   key) and type:
     $TAGRULES_GEN
   (That script asks MangoWM what monitors you have and writes one rule
   block per monitor into a settings file. A \"rule\" here just records
   how that screen arranges its windows (its layout).)

3. Press Super+r to make MangoWM re-read its settings.

4. Confirm it actually wrote something:
     cat $TAGRULES_FILE
   (\"cat\" prints a file's contents to the screen.) You should see one
   or more lines beginning with \"tagrule =\". If the file's empty or
   still missing, MangoWM wasn't running in step 1 - log in properly and
   redo step 2.

5. Your monitors all start on the tile layout. Use the Monitor Mode button
   on the bar to pick a different one per monitor - you never need to edit
   this file by hand.

Note: the monitor watcher normally re-runs this for you whenever you plug
in or unplug a monitor - see the next check."
fi

# 1c. the monitor hotplug watcher. Without it, plugging in a monitor leaves that
#     monitor with NO tagrules until you re-run the generator by hand -- and
#     re-running the generator by hand resets every monitor to tile, which the
#     watcher avoids by re-applying your layouts afterwards.
if execu "$MONITOR_WATCHER"; then
    if have fuser && [ -n "$(fuser "$MONITOR_WATCHER_LOCK" 2>/dev/null)" ]; then
        pass "monitor hotplug watcher is running"
    else
        warn "monitor hotplug watcher is NOT running (autostarts on next login)" \
             "Start now:  setsid '$MONITOR_WATCHER' >/dev/null 2>&1 & disown"
        offer "start the monitor hotplug watcher" "setsid '$MONITOR_WATCHER' >/dev/null 2>&1 &"
    fi
    # Is it actually wired to autostart? A running-but-unwired watcher passes the
    # check above today and silently vanishes at the next login.
    grep -qE '^[[:space:]]*exec-once[[:space:]]*=.*monitor-watcher\.sh' "$MANGO_CFG" \
        || warn "monitor-watcher.sh is not in config.conf's exec-once (won't start at login)" \
                "Add:  exec-once = ~/.config/mango/scripts/monitor-watcher.sh"
else
    fail "Monitor hotplug watcher" \
         "missing or not executable — monitors you plug in get no tagrules until you re-run the generator by hand" \
         "$MONITOR_WATCHER (autostarted from $MANGO_CFG exec-once)" \
         "Restore it from the repo (config/mango/scripts/monitor-watcher.sh), then: chmod +x '$MONITOR_WATCHER'. Check it with '$MONITOR_WATCHER --status'; its log is /tmp/mango-monitor-watcher.log." \
"What this does: when you plug in or unplug a monitor, it rewrites the
per-monitor rules automatically and puts back the layout each screen had.
Without it, a newly plugged-in monitor has no rules until you re-run the
generator yourself - and doing that by hand resets every screen to tile.

1. Check whether the file is there at all:
     ls -l $MONITOR_WATCHER
   (\"ls -l\" lists a file and its permissions.) If it says \"No such file
   or directory\", copy it back from the folder you cloned DankMango into
   (the one with install.sh in it):
     cp config/mango/scripts/monitor-watcher.sh $SCRIPTS/

2. Mark it runnable (files copied around sometimes lose this):
     chmod +x $MONITOR_WATCHER

3. Start it now, without logging out:
     setsid $MONITOR_WATCHER >/dev/null 2>&1 & disown
   (\"setsid\" lets it keep running after you close the terminal.)

4. Confirm it's up:
     $MONITOR_WATCHER --status
   The last line should say \"watcher : RUNNING\".

Nothing is lost in the meantime - after plugging in a monitor just run
$TAGRULES_GEN and press Super+r, then set that screen's layout from the
Monitor Mode button on the bar."
fi

# 1d. the watcher's OUTPUT file. The watcher can be alive and wired and STILL have
#     produced nothing usable (interrupted write, hand-edit, a mango syntax change).
#     Nothing announces that: the only symptom is a game opening on the wrong
#     screen, which reads as a Steam quirk rather than a broken file. Two states
#     have to agree, so both directions are checked.
MAIN_STORED=""
if [ -f "$DANKMANGO_MANIFEST" ] && have jq; then
    MAIN_STORED="$(jq -r '.userPrefs.mainDisplay // empty' "$DANKMANGO_MANIFEST" 2>/dev/null)"
fi

if [ -n "$MAIN_STORED" ]; then
    # A game display is chosen, so the rules file must exist AND parse.
    if [ ! -f "$MAINRULES_FILE" ]; then
        fail "Game-display rules (file missing)" \
             "you chose $MAIN_STORED as your game display, but the rules file that sends Steam games there does not exist — games will open on whichever screen the mouse is on" \
             "$MAINRULES_FILE (generated by $MONITOR_WATCHER, sourced by $MANGO_CFG)" \
             "Regenerate it: '$MONITOR_WATCHER --once'. If it stays missing, check write permissions on ~/.config/mango/dms/ and the watcher's log at /tmp/mango-monitor-watcher.log." \
"What's missing: you picked a game display ($MAIN_STORED), and DankMango is
supposed to keep a small settings file that tells MangoWM to open Steam
games on that screen. That file isn't there right now, so games open
wherever your mouse pointer happens to be instead.

Nothing is broken or lost - the file is generated, so it can just be made
again.

1. Open a terminal (press Super+Return - \"Super\" is the key with the
   Windows logo on it).

2. Rebuild the file:
     $MONITOR_WATCHER --once
   (This is the same program that normally does it for you when you plug
   a monitor in. \"--once\" tells it to do its job a single time now and
   then stop, instead of running in the background.)

3. Check the file's there now:
     cat $MAINRULES_FILE
   (\"cat\" prints a file's contents to the screen.) You should see a
   couple of lines starting with \"windowrule\". A \"windowrule\" is just
   MangoWM's way of saying \"when this kind of window opens, put it
   here\" - in this case, \"put Steam games on $MAIN_STORED\".

4. Load the change:
     Press Super+r
   (That tells MangoWM to re-read its settings. Nothing restarts and no
   windows close.)

5. Confirm it took:
     $MONITOR_WATCHER --status
   \"stored game display\" and \"effective game display\" should both say
   $MAIN_STORED.

If step 2 prints a permission error, your settings folder isn't writable.
Fix it with:
     chmod u+rwx ~/.config/mango/dms
then redo step 2."
    elif ! mango -c "$MAINRULES_FILE" -p >/dev/null 2>&1; then
        fail "Game-display rules (file invalid)" \
             "$MAINRULES_FILE exists but MangoWM rejects it as invalid — every rule in it is being ignored, so Steam games open on the wrong screen" \
             "$MAINRULES_FILE (generated by $MONITOR_WATCHER; validate by hand with 'mango -c $MAINRULES_FILE -p')" \
             "Almost always a hand-edit or a mango syntax change. Regenerate: '$MONITOR_WATCHER --once'. If the fresh file also fails validation, mango has renamed a windowrule option — compare against 'mmsg --help' and fix STEAM_GAME_MATCHERS in $MONITOR_WATCHER." \
"What's wrong: the settings file that sends Steam games to your game
display ($MAIN_STORED) exists, but MangoWM can't understand it, so it
ignores the whole thing. Games open on whichever screen your mouse is on.

This file is generated automatically and isn't meant to be hand-edited,
so the safe fix is to throw it away and let it be made again.

1. Open a terminal (press Super+Return - \"Super\" is the key with the
   Windows logo on it).

2. Look at what's in there now, so you can see it change:
     cat $MAINRULES_FILE
   (\"cat\" prints a file's contents to the screen.)

3. Rebuild it from scratch:
     rm $MAINRULES_FILE
     $MONITOR_WATCHER --once
   (\"rm\" removes the file. That's safe here: it's generated, not
   something you wrote. The second command makes a fresh, correct one.)

4. Check the new file is valid. Type this exactly:
     mango -c $MAINRULES_FILE -p
   (\"mango -c <file> -p\" means \"read this settings file and just check
   it for mistakes\".) If it prints nothing, the file's fine - no news is
   good news here.

5. Load it:
     Press Super+r

If step 4 still complains after a fresh file, that's not something you can
fix by editing - a MangoWM update has renamed something DankMango uses.
Open an issue at https://github.com/AhjinYeri/DankMango/issues and paste
what step 4 printed. Your games keep working in the meantime, they'll just
open on the wrong screen."
    else
        pass "game-display rules present & valid (Steam games -> $MAIN_STORED)"
    fi
elif [ -f "$MAINRULES_FILE" ] && grep -qE '^[[:space:]]*windowrule[[:space:]]*=' "$MAINRULES_FILE"; then
    # No game display chosen, but live rules are still sitting there. The watcher
    # clears this file when the preference goes away, so real rules here mean that
    # clearing did not happen — and they point at whatever monitor was chosen
    # BEFORE, which may not even be plugged in now.
    fail "Game-display rules (stale)" \
         "no game display is chosen any more, but $MAINRULES_FILE still contains active rules from a previous choice — Steam games are being sent to a screen you did not pick" \
         "$MAINRULES_FILE (should be header-only when .userPrefs.mainDisplay is unset in $DANKMANGO_MANIFEST)" \
         "Clear it: '$MONITOR_WATCHER --once' rewrites it header-only when nothing is stored. To choose a display instead, run './install.sh --reselect-main-display' from your DankMango folder." \
"What's wrong: DankMango can send Steam games to a screen you nominate as
your \"game display\". You don't currently have one chosen - but the
settings file that does the sending still has old instructions in it from
a previous choice. So games are being pushed to a screen you didn't pick,
and possibly one that isn't even plugged in.

Two ways out. Pick whichever you actually want.

OPTION A - you don't want this feature. Clear the leftovers:

1. Open a terminal (press Super+Return - \"Super\" is the key with the
   Windows logo on it).

2. Run:
     $MONITOR_WATCHER --once
   (This is DankMango's monitor helper. With nothing chosen, it empties
   that file out for you.)

3. Press Super+r to load the change.

4. Confirm the old rules are gone:
     cat $MAINRULES_FILE
   (\"cat\" prints a file's contents.) You should see only lines starting
   with \"#\", which are comments and do nothing.

Games will then open on whichever screen your mouse is on, which is the
normal behaviour.

OPTION B - you DO want games on a particular screen. Choose one:

1. Go to your DankMango folder. If you cloned it into your home folder:
     cd ~/DankMango
   (\"cd\" means \"change directory\".) If you put it somewhere else, use
   that path instead.

2. Run:
     ./install.sh --reselect-main-display
   (This opens a small picker. It does NOT re-run the installer and
   changes nothing else.)

3. Use the arrow keys - or Ctrl-P and Ctrl-N if your keyboard has no
   arrow keys - to highlight a screen, press Space to select it, then
   Enter to confirm. Pressing Enter without Space first just keeps
   whatever was already highlighted."
else
    pass "game-display rules consistent (none stored, none left behind)"
fi

# 1f. plugin enabled
plugin_enabled monitorMode && pass "monitorMode plugin enabled" \
    || fail "monitorMode plugin" "not enabled in plugin_settings.json" "$PLUGIN_SETTINGS" \
            "Re-enable: DMS Settings -> Plugins -> Monitor Mode on; confirm it's in the bar layout too. Then 'dms restart'." \
            "$(manual_reenable_plugin "Monitor Mode")

What breaks meanwhile: you lose the bar button that sets a screen's
layout. Your monitors keep whatever layout they were last set to."

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
That's unusual - it normally means an update removed an audio package.

1. Install it. Open a terminal (Super+Return) and type:
     sudo pacman -S wireplumber
   (\"pacman\" is the program that installs software on CachyOS/Arch - each
   piece of software is called a \"package\". \"sudo\" means run this as
   administrator, so it'll ask for your password. Nothing appears on
   screen while you type the password - that's normal, just type it and
   press Enter.)

2. When it asks to confirm, press Enter to accept.

3. Check it's working:
     wpctl status
   (That prints your sound devices. Seeing a list means it's fixed.)

4. If sound itself is also broken, reinstall the whole audio stack:
     sudo pacman -S pipewire pipewire-pulse wireplumber
   then reboot with:
     reboot"

# 2a. has the button got anything to switch TO?
# "Enabled + backend installed" passes happily on a switcher that silently does
# nothing, which is how a real breakage once sat here reporting PASS. There is no
# way to ask DMS whether a plugin is *working* -- but every input the plugin reads
# is readable from here, and both of its silent-no-op cases show up in them:
#   * NAMED TARGETS (outputTargets in plugin_settings.json): a configured card or
#     profile can stop existing -- renamed by a PipeWire update, hardware gone, or
#     the key lost because something rewrote plugin_settings.json.
#   * ZERO-CONFIG SINK CYCLING (no outputTargets): right on a machine with two real
#     sinks, a no-op on a machine with one. A card that exposes speakers and
#     headphones as two PROFILES of ONE card looks exactly like that from here --
#     one sink, nothing to cycle -- and is the reason outputTargets exists.
# Missing target = FAIL (something that worked has stopped). Only one sink and no
# targets = WARN, not FAIL: on a genuinely single-output machine that's just true.
if ! have jq; then
    note "audio switcher targets not checked (needs jq)"
elif ! have pactl; then
    note "audio switcher targets not checked (needs pactl)"
else
    audio_targets="$(jq -r '(.audioToggle.outputTargets // [])[] | [.label, .card, .profile] | @tsv' \
                        "$PLUGIN_SETTINGS" 2>/dev/null)"
    if [ -n "$audio_targets" ]; then
        cards_dump="$(pactl list cards 2>/dev/null)"
        audio_gone=""
        while IFS=$'\t' read -r t_label t_card t_profile; do
            [ -n "${t_card:-}" ] && [ -n "${t_profile:-}" ] || continue
            # Scope the profile lookup to that card's own block, so a profile name
            # that exists on some OTHER card can't mask a missing one here.
            if printf '%s\n' "$cards_dump" \
               | awk -v c="$t_card" -v p="$t_profile" '
                     $1 == "Name:" { inblock = ($2 == c) }
                     inblock && index($0, "\t\t" p ": ") == 1 { found = 1 }
                     END { exit !found }'; then
                continue
            fi
            audio_gone="${audio_gone}${audio_gone:+, }$t_label ($t_card / $t_profile)"
        done <<< "$audio_targets"
        if [ -z "$audio_gone" ]; then
            pass "audio switcher targets all still exist ($(printf '%s\n' "$audio_targets" | wc -l) configured)"
        else
            fail "audio switcher targets" "configured output(s) no longer exist: $audio_gone" \
                 "$PLUGIN_SETTINGS (audioToggle.outputTargets) vs 'pactl list cards'" \
                 "Re-read the card/profile names from 'pactl list cards' and update outputTargets to match." \
"The speakers/headphones button is still there, but one of the outputs it was
told about has gone. Clicking it will either do nothing or only ever reach the
output that IS still there.

1. See what your machine actually offers now. Open a terminal (Super+Return):
     pactl list cards
   (That lists your sound cards. Under each one, \"Profiles:\" is the list of
   ways it can be used - e.g. speakers via digital, or the headphone jack.
   \"Active Profile:\" is the one in use right now.)

2. Open the settings file that holds the button's list:
     nano ~/.config/DankMaterialShell/plugin_settings.json
   Find the \"audioToggle\" section. Each entry under \"outputTargets\" has a
   \"card\" and a \"profile\" - those must match the names step 1 printed,
   exactly. Fix the one named above, save with Ctrl+O, Enter, exit Ctrl+X.

3. Restart the shell so it re-reads the file:
     dms restart

4. If the hardware is genuinely gone for good (a DAC you sold, say), just
   delete that entry from the list instead."
        fi
    elif ! have wpctl; then
        # The backend check above passes on pactl alone, but sink-cycling mode reads
        # 'wpctl status' -- without it we'd count zero sinks and cry wolf.
        note "audio switcher outputs not counted (needs wpctl)"
    else
        # No targets configured -> sink-cycling mode. Count the sinks the plugin
        # would actually offer, from the same 'wpctl status' text it parses, with
        # the same virtual-sink skip list AudioToggleBar.qml uses (keep in step).
        real_sinks=$(wpctl status 2>/dev/null | awk '
                         /^[^[:space:]]/          { top = $0; insinks = 0 }
                         top !~ /^Audio/          { next }
                         /Sinks:/                 { insinks = 1; next }
                         /(Devices|Sources|Filters|Streams|Clients):/ { insinks = 0; next }
                         insinks && match($0, /[0-9]+\. /) {
                             s = substr($0, RSTART + RLENGTH)
                             sub(/[[:space:]]*(\[[^]]*\][[:space:]]*)+$/, "", s)
                             if (s != "") print s
                         }' \
                     | grep -icvE 'easy ?effects|monitor|microphone|loopback|null|dummy')
        if [ "${real_sinks:-0}" -ge 2 ]; then
            pass "audio switcher has $real_sinks outputs to cycle between"
        else
            warn "audio switcher has nothing to switch to" \
"only $real_sinks usable output found and no outputTargets configured — the button will do nothing.
         If your speakers and headphones are two PROFILES of one card (check 'pactl list cards'),
         add them as audioToggle.outputTargets in $PLUGIN_SETTINGS — see plugins/output-switcher/README.md."
        fi
    fi
fi

# 2b. package-owned-file patches -- driven entirely by apply-patches.sh's registry.
# Nothing below names a patch: the id, title, target, owning package, what it does
# and how to test it all arrive on the porcelain line, so adding a patch to the
# registry makes it checked (and explained) here with no edit to this script.
if [ ! -x "$PATCH_DISPATCH" ] && [ ! -f "$PATCH_DISPATCH" ]; then
    fail "patch dispatcher" "apply-patches.sh is missing -- can't check the patches DankMango applies to other packages' files" \
         "$PATCH_DISPATCH (shipped in config/mango/scripts/)" \
         "Re-run install.sh (or update.sh) from the DankMango folder to install it." \
"DankMango makes a couple of small edits to files that belong to OTHER programs,
and the script that checks and repairs them isn't installed here. So that check
just isn't running - it doesn't mean anything is broken.

1. Go to the folder you cloned DankMango into (the one containing install.sh)
   and bring it up to date:
     git pull
     ./update.sh
   (\"git pull\" downloads the newest DankMango; update.sh installs what changed.)

2. Re-run this health check:
     $SCRIPTS/post-update-health.sh"
else
    while IFS=$'\t' read -r p_id p_state p_title p_target p_pkg p_blurb p_verify p_restart; do
        [ -n "${p_id:-}" ] || continue
        case "$p_state" in
        ok)
            pass "$p_title applied and current"
            ;;
        not-applied)
            # An opt-in patch the user said no to at install. NOT a failure -- the old
            # code reported this as one on every run, then told you to ignore it.
            note "$p_title not applied here (optional; take it with: $PATCH_DISPATCH $p_id)"
            ;;
        stale)
            fail "$p_title" \
                 "the $p_pkg package overwrote the file this patches, so the change is gone" \
                 "$p_target; state from: $PATCH_DISPATCH status" \
                 "One command, idempotent, backs up first, needs sudo:  $PATCH_DISPATCH   then '$p_restart'." \
"This is expected after a $p_pkg update and is a one-command fix.
$(wrap 72 0 "DankMango $p_blurb. It does that by editing a file $p_pkg itself owns, so every $p_pkg update overwrites the file and wipes the change.")

1. Re-apply it. Open a terminal (Super+Return) and type:
     $PATCH_DISPATCH
   (That one command checks every patch DankMango applies and re-applies only
   the ones that have been wiped - you don't need to know their names. It backs
   each file up first and is safe to run as many times as you like.)

2. It'll ask for your password, because the file it edits belongs to the system
   rather than to you. Type your password and press Enter - nothing appears on
   screen as you type it, which is normal.

3. Restart the shell so the repaired file gets used:
     $p_restart
   (\"the shell\" means the bar, launcher and popups. This doesn't log you out
   or close your open windows.)

4. Test it: $(wrap 60 12 "$p_verify").

If you'd rather not have this patch at all, it's entirely optional - ignore this
warning and nothing else changes."
            ;;
        target-missing)
            fail "$p_title" \
                 "the file it patches is gone -- $p_pkg may have moved or removed it" \
                 "expected $p_target; find it: pacman -Ql $p_pkg | grep $(basename "$p_target")" \
                 "Update p_target[$p_id] in $PATCH_DISPATCH (and TARGET in the patch's own apply script) to the new path, then run $PATCH_DISPATCH." \
"$(wrap 72 0 "A $p_pkg update moved or deleted the file DankMango patches. Nothing is broken as such - that program works fine, you just lose what the patch added: $p_blurb.")

1. Find out where the file went. Type:
     pacman -Ql $p_pkg | grep $(basename "$p_target")
   (\"pacman -Ql\" lists every file a package put on your system, and \"grep\"
   filters that long list down to lines containing the text you asked for.)

2. If that printed a path, the file just moved. Point the patch at its new home:
     nano $PATCH_DISPATCH
   Press Ctrl+W, type p_target, press Enter, and change the path on the line
   for $p_id to the one you found. Ctrl+O then Enter to save, Ctrl+X to quit.
   Do the same for TARGET inside the patch's own apply script in $SCRIPTS.

3. Apply it at its new home:
     $PATCH_DISPATCH
   then:
     $p_restart

4. If step 1 printed NOTHING, $p_pkg removed the file entirely and the patch has
   nowhere left to go. There's no fix to type here - the feature is gone until
   DankMango is updated for the new $p_pkg. Report it at
   https://github.com/AhjinYeri/DankMango/issues so it can be. Everything else
   on your system is unaffected."
            ;;
        script-missing)
            fail "$p_title" \
                 "the script that applies this patch isn't installed" \
                 "$SCRIPTS (expected the apply script named in $PATCH_DISPATCH)" \
                 "Re-run install.sh from the DankMango folder to restore the scripts directory." \
"The file that knows how to apply this patch is missing from your scripts folder,
so the patch can't be repaired until that file is back.

1. Go to the folder you cloned DankMango into (the one with install.sh in it):
     ./install.sh
   (install.sh re-copies every DankMango file into place. It backs up anything
   it overwrites and it's safe to re-run.)

2. Then re-apply the patches:
     $PATCH_DISPATCH

3. Re-run this health check to confirm:
     $SCRIPTS/post-update-health.sh"
            ;;
        esac
    done < <("$PATCH_DISPATCH" status --porcelain 2>/dev/null)
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

Straight up: this one's a bug in the plugin's own code, not a setting you
got wrong. There's nothing sensible to hand-edit. Two real options:

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
They'll have restarted themselves, so your desktop is usable - but Alt+Tab
will crash them again every time until this is fixed.

DO THIS FIRST: don't use Alt+Tab. Switch windows by clicking them, or by
holding Super and pressing a number key.

Like the duplicate-handler problem, this is a fault in the plugin's code
rather than a setting, so there's no config to correct by hand.

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
"Your bar, launcher and popups aren't running at all. (Collectively they're
called \"the shell\" - the program that draws them is quickshell.) Your
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

5. If it's still down after that, look at why it crashed:
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
   generated from your wallpaper, so regenerate them by setting your
   wallpaper again from the DankMaterialShell settings (gear icon on the
   bar). Then press Super+r. Check something was written with:
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

4. IF IT SAYS THE RELOAD COMMAND FAILED - that's the same underlying
   problem as the \"MangoWM config reload command\" entry in this report.
   Fix that one first, then re-run this check; this usually clears with it.

5. If all three stages pass but the colours still look wrong, then nothing
   is broken - the wiring is fine and the colours are simply out of date.
   Give the watcher a change to react to:
     touch ~/.cache/DankMaterialShell/dms-colors.json
   (That file is the palette everything else is generated from. The watcher
   checks its timestamp twice a second and redoes its work whenever that
   timestamp moves; \"touch\" updates the timestamp without altering a byte
   of the contents. Your borders, the login screen and the visualiser
   accents should all catch up within about a second.)

   Do not restart the watcher for this - it will not help, and it is the
   obvious thing to try. It records the current timestamps the moment it
   starts and then waits for the NEXT change, so restarting it just
   re-reads the same stale state and does nothing. The \"touch\" above is
   the thing that actually makes it act."
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
# 5. IN-SESSION HELP HUB (SUPER+SHIFT+/)
# =============================================================================
# The hub shows a curated key table whose DESCRIPTIONS are read live out of
# config.conf at display time -- it stores none of its own. keys.tsv lists only
# which keys to show. So the failure mode worth checking is DRIFT: a key gets
# renamed or removed in config.conf and keys.tsv still asks for it. `docs-hub.sh
# check` resolves every curated key and exits non-zero if any no longer resolve.
section "5. In-session help hub"

if execu "$DOCSHUB_SCRIPT"; then
    pass "docs-hub.sh present & executable"

    if [ -r "$DOCSHUB_KEYS" ]; then
        pass "curated key table present ($(basename "$DOCSHUB_KEYS"))"
    else
        fail "help hub key table" "missing: $(basename "$DOCSHUB_KEYS")" "$DOCSHUB_KEYS" \
             "Restore it from the DankMango repo (config/mango/docs/), then re-run this check." \
             "The help hub has lost the list of which shortcuts to show, so
SUPER+SHIFT+/ will open but the shortcut list will be empty.

1. Open the folder you cloned DankMango into (the one with install.sh), then:
     ./install.sh
   (install.sh re-copies every DankMango file into place, including this one.)

2. Check it worked:
     $DOCSHUB_SCRIPT check
   It should say OK and a number of keys.

What breaks meanwhile: only the shortcut list inside the hub. Every keyboard
shortcut itself still works, and SUPER+/ still shows the full list."
    fi

    if [ -r "$DOCSHUB_GUIDE" ]; then
        pass "written guide present ($(basename "$DOCSHUB_GUIDE"))"
    else
        warn "help hub guide is missing ($(basename "$DOCSHUB_GUIDE"))" \
             "Restore with ./install.sh from the DankMango repo. The rest of the hub still works."
    fi

    # The drift check itself. Capture output so we can quote the offending keys.
    if DOCSHUB_OUT="$("$DOCSHUB_SCRIPT" check 2>&1)"; then
        pass "curated keys all resolve against config.conf — ${DOCSHUB_OUT#*-- }"
    else
        fail "help hub key table (out of date)" \
             "keys.tsv asks for shortcuts that no longer exist in config.conf" \
             "$DOCSHUB_KEYS  and  $MANGO_CFG" \
             "Run '$DOCSHUB_SCRIPT check' to list them, then fix keys.tsv or re-add the bind." \
             "Your list of keyboard shortcuts has drifted out of date. The help hub
(SUPER+SHIFT+/) is asking to display shortcuts that are no longer in
MangoWM's settings file, so they show up in red as MISSING.

Nothing is broken -- this is a bookkeeping mismatch between two files.

1. See exactly which shortcuts are affected. Type:
     $DOCSHUB_SCRIPT check
   It prints one line per shortcut it couldn't find.

2. Decide which of the two files is wrong:

   * If you MEANT to remove or rename that shortcut, the hub's list is just
     stale. Open it:
       nano $DOCSHUB_KEYS
     Delete the line for that shortcut (or correct it to the new keys), then
     save with Ctrl+O, Enter, and exit with Ctrl+X.

   * If the shortcut disappeared by ACCIDENT -- most likely a MangoWM update
     overwrote your settings file -- put the bind back instead:
       nano $MANGO_CFG
     Add it in the keybinds block, remembering the plain-English comment on
     the line directly ABOVE it (never on the end of the line). Then press
     SUPER+r to reload.

3. Confirm it's clean:
     $DOCSHUB_SCRIPT check
   You want it to say OK.

What breaks meanwhile: nothing except that one row in the help hub, which
shows as MISSING in red. Every other shortcut still works normally."
    fi
else
    fail "docs-hub.sh" "missing or not executable — SUPER+SHIFT+/ will do nothing" "$DOCSHUB_SCRIPT" \
         "Restore it, then: chmod +x '$DOCSHUB_SCRIPT'" \
         "$(manual_restore_script "$DOCSHUB_SCRIPT")

What breaks meanwhile: pressing SUPER+SHIFT+/ opens a terminal that closes
again immediately. SUPER+/ still shows the full searchable shortcut list,
which covers most of what the hub is for."
fi

# =============================================================================
# 6. SCREENSHOT ANNOTATION (Print / Shift+Print / Ctrl+Print)
# =============================================================================
section "6. Screenshot annotation"

# Two things can rot independently here, so they're checked separately:
#   a) the satty package (an official-repo dependency, so normally an explicit
#      removal rather than an update casualty). screenshot.sh degrades to a
#      plain capture without it, so this is a WARN, not a FAIL -- you still get
#      your screenshot, just no editor.
#   b) the Print bind in config.conf. This one IS a real break: an update that
#      restores a stock config.conf silently takes the whole Windows-convention
#      keybind set with it, and the only symptom is "Print does nothing".
if have satty; then
    pass "satty installed ($(satty --version 2>/dev/null | head -1))"
else
    warn "satty not installed — Print still captures, but opens no annotation editor" \
         "Install it: sudo pacman -S satty"
fi

if grep -qE '^[[:space:]]*bind[[:space:]]*=[[:space:]]*NONE,[[:space:]]*Print,' "$MANGO_CFG" 2>/dev/null; then
    pass "Print bound to the region-capture + annotate flow"
else
    fail "screenshot keybind" \
         "no 'Print' bind in config.conf — the Print key does nothing" \
         "$MANGO_CFG" \
         "Re-add the Screenshots bind block (or re-run install.sh to restore config.conf)." \
"1. Open your mango config in a text editor. Type:
     nano $MANGO_CFG

2. Find the line that starts with '# Screenshots'. Underneath it you should
   have four 'bind =' lines. If they're missing, add these:

     bind = NONE, Print, spawn, ~/.config/mango/scripts/screenshot.sh region
     bind = SHIFT, Print, spawn, ~/.config/mango/scripts/screenshot.sh fullscreen
     bind = CTRL, Print, spawn, ~/.config/mango/scripts/screenshot.sh quick
     bind = SUPER, p, spawn, ~/.config/mango/scripts/screenshot.sh region

3. Save and close (Ctrl+O, Enter, then Ctrl+X).

4. Tell mango to re-read the config so the keys work now rather than at your
   next login. Type:
     mmsg dispatch reload_config
   (Expect it to print {\"success\":true}.)

5. Press Print. You should get a crosshair to drag a region with.

What breaks meanwhile: the Print key does nothing. Super+P still takes a
screenshot, so you're not locked out of screenshots entirely."
fi

if execu "$SCRIPTS/screenshot.sh"; then
    pass "screenshot.sh present and runnable"
else
    fail "screenshot.sh" "missing or not executable — every screenshot key does nothing" \
         "$SCRIPTS/screenshot.sh" \
         "Restore it, then: chmod +x '$SCRIPTS/screenshot.sh'" \
         "$(manual_restore_script "$SCRIPTS/screenshot.sh")

What breaks meanwhile: Print, Shift+Print, Ctrl+Print and Super+P all do
nothing. Nothing else is affected."
fi

# =============================================================================
# 7. FIRST-RUN WELCOME PANEL (firstRunPanel)
# =============================================================================
# WHAT THIS CAN AND CANNOT ESTABLISH -- read before adding to it.
#
# There is no way to ask DMS "is this plugin loaded and running right now". The
# other plugins are checked indirectly through something they own: altSwitcher has
# an IPC handler you can call, audioToggle and monitorMode put a button on the bar
# and have scripts behind them. This one is a `daemon` plugin with no bar presence,
# no IPC handler and no script -- it draws a modal once and goes quiet. Nothing it
# does is observable from outside the shell.
#
# So this section checks the two things that ARE facts on disk:
#   a) the deployed files are there, and match the clone if the clone is reachable
#   b) DMS is told to load it (plugin_settings.json)
#
# The three states of (b) are distinguishable, which is what lets the tone be right:
#   key present + enabled true   -> PASS
#   key present + enabled false  -> the user turned it off. A NOTE, not a warning:
#                                   it's a one-time welcome, switching it off is a
#                                   perfectly sensible thing to have done.
#   key absent entirely          -> install.sh ships it REGISTERED, so an absent key
#                                   means registration didn't land (or something
#                                   rewrote the file). That's a WARN.
# That's as far as "never enabled vs. was enabled, now broken" can be taken here:
# nothing records that it ever loaded successfully, and a plugin that loads and one
# that throws on load look identical from out here. A QML load error goes to the
# session log, so that's where this points rather than pretending to detect it.
#
# DELIBERATELY NOT CHECKED: whether ~/.local/state/dankmango/first-run-complete
# exists. That file only records whether you've dismissed the panel yet. Both
# answers are correct, so it's reported as context below and can never fail.
section "7. First-run welcome panel"

if [ ! -d "$FRP_DIR" ]; then
    fail "welcome panel (not installed)" \
         "the firstRunPanel plugin folder isn't there, so DMS has nothing to load — a fresh install would get no welcome" \
         "$FRP_DIR (deployed from $FRP_REPO_SUBDIR by install.sh stage 14)" \
         "Re-run install.sh from the DankMango folder; it re-copies every plugin. Then 'dms restart'." \
"DankMango shows a small welcome panel the first time a new install starts. The
files that draw it aren't on this machine, so it can't appear. Nothing else is
affected - this is the welcome only.

1. Go to the folder you cloned DankMango into (the one with install.sh in it)
   and re-run the installer:
     ./install.sh
   (It re-copies every DankMango file into place, backs up anything it
   overwrites, and is safe to run as many times as you like.)

2. Restart the shell so DMS picks the plugin up:
     dms restart
   (\"the shell\" is the bar, launcher and popups. This doesn't log you out and
   won't close your windows.)

3. Re-run this health check to confirm:
     $SCRIPTS/post-update-health.sh"
else
    frp_missing=""
    for f in "${FRP_FILES[@]}"; do
        [ -f "$FRP_DIR/$f" ] || frp_missing="$frp_missing $f"
    done
    if [ -n "$frp_missing" ]; then
        fail "welcome panel (incomplete)" \
             "$FRP_DIR exists but is missing:$frp_missing — DMS will fail to load the plugin" \
             "$FRP_DIR (should hold ${FRP_FILES[*]}); load errors land in ~/.local/share/sddm/wayland-session.log" \
             "Re-run install.sh to re-copy the plugin, then 'dms restart'." \
"Part of the welcome panel is missing from your plugins folder, so DMS can't
load it. Only the welcome is affected.

1. In the folder you cloned DankMango into (the one with install.sh in it):
     ./install.sh

2. Restart the shell:
     dms restart

3. Re-run this health check:
     $SCRIPTS/post-update-health.sh"
    else
        pass "welcome panel files present ($FRP_DIR)"

        # Do the deployed files still match the clone? Only answerable when the clone
        # is reachable, and NOT having it is normal (people delete it, or install from
        # a copy that has since moved), so an unreachable repo is a note and never a
        # failure -- the same rule docs-hub.sh uses for its repo: entries.
        frp_repo=""
        if [ -r "$DANKMANGO_MANIFEST" ] && have jq; then
            frp_repo="$(jq -r '.dankmango.repoDir // empty' "$DANKMANGO_MANIFEST" 2>/dev/null)"
        fi
        if [ -n "$frp_repo" ] && [ -d "$frp_repo/$FRP_REPO_SUBDIR" ]; then
            frp_drift=""
            for f in "${FRP_FILES[@]}"; do
                cmp -s "$FRP_DIR/$f" "$frp_repo/$FRP_REPO_SUBDIR/$f" || frp_drift="$frp_drift $f"
            done
            if [ -z "$frp_drift" ]; then
                pass "welcome panel matches the repo copy"
            else
                warn "welcome panel differs from the repo copy:$frp_drift" \
                     "Expected if you're editing it. Otherwise take the repo's version: ./update.sh from $frp_repo, then 'dms restart'."
            fi
        else
            note "can't compare the welcome panel against the repo (no DankMango clone found) — normal if you deleted or moved it"
        fi
    fi
fi

# Registration. Three states, three tones -- see the header above.
if plugin_enabled "$FRP_ID"; then
    pass "welcome panel enabled in plugin_settings.json"
elif grep -q "\"$FRP_ID\"" "$PLUGIN_SETTINGS" 2>/dev/null; then
    note "welcome panel is switched off in DMS Settings -> Plugins. Nothing wrong with that — it's a one-time welcome. Turn it back on there if you want it."
else
    warn "welcome panel isn't registered in plugin_settings.json — DMS won't load it" \
         "install.sh ships it registered, so something replaced that file. Re-run ./install.sh (or add it in DMS Settings -> Plugins), then 'dms restart'."
fi

# Context only, never a verdict: this is the file that records whether you've
# dismissed the panel yet, and BOTH answers are correct. It's printed because
# "why don't I see the welcome?" is answered by this line more often than by
# anything above it.
if [ -e "${XDG_STATE_HOME:-$HOME/.local/state}/dankmango/first-run-complete" ]; then
    note "you've dismissed the welcome already, so it won't show again (that's normal). To see it once more: rm ~/.local/state/dankmango/first-run-complete && dms restart"
else
    note "the welcome hasn't been dismissed yet — it'll appear at your next shell start"
fi

# =============================================================================
# 8. Pre-update safety snapshot  (informational only -- never a FAIL)
# =============================================================================
# update.sh takes a named snapper snapshot before it changes anything, so a bad
# update can be rolled back from the boot menu. This just confirms one actually
# landed. It is INFORMATIONAL throughout: it uses pass/note only, never fail() or
# warn(), so it can't add to the problem count. A missing snapshot is not a broken
# machine -- most often it just means you haven't updated today.
#
# Same two gates as update.sh, and failing either skips the whole section silently
# (no header, no line): on ext4, or on Btrfs with no snapper, there is nothing here
# to be right or wrong about, and printing about it would only puzzle people.
snap_cfg=""
if [ "$(findmnt -no FSTYPE / 2>/dev/null)" = btrfs ] && have snapper; then
    # Config name is detected, never assumed: "root" if it exists, else the first
    # listed. Matches update.sh's snapper_config().
    snap_cfgs="$(snapper --csvout list-configs 2>/dev/null | awk -F, 'NR>1 && $1 != "" {print $1}')"
    if [ -n "$snap_cfgs" ]; then
        if printf '%s\n' "$snap_cfgs" | grep -qx root; then snap_cfg=root
        else snap_cfg="$(printf '%s\n' "$snap_cfgs" | head -1)"; fi
    fi
fi

if [ -n "$snap_cfg" ]; then
    section "8. Pre-update safety snapshot"

    # Listing snapshots needs root (unlike list-configs). `sudo -n` means "don't
    # ask" -- this whole script is read-only and never prompts for a password, so
    # if admin rights aren't already cached we say so and move on rather than
    # interrupting the report for something purely informational.
    # snapper prints "No permissions." and still EXITS 0, so trust the output, not $?.
    snap_list="$(sudo -n snapper --csvout -c "$snap_cfg" list --columns date,description 2>/dev/null)"
    case "$snap_list" in *"No permissions"*) snap_list="" ;; esac

    if [ -z "$snap_list" ]; then
        note "couldn't read the snapshot list without an admin password — skipped. To look yourself: sudo snapper -c $snap_cfg list"
    else
        # Anything described "DankMango pre-update:" in the last 24h. The window keeps
        # this about the update you just did, rather than one from six months ago.
        snap_found=""
        snap_cutoff=$(( $(date +%s) - 86400 ))
        while IFS= read -r line; do
            snap_when="${line%%,*}"; snap_desc="${line#*,}"
            snap_desc="${snap_desc%\"}"; snap_desc="${snap_desc#\"}"
            # Hardcoded copy of update.sh's $SNAPSHOT_DESC_PREFIX (this script ships standalone, so it can't source it) — keep the two in sync.
            case "$snap_desc" in "DankMango pre-update:"*) ;; *) continue ;; esac
            snap_ts="$(date -d "$snap_when" +%s 2>/dev/null)" || continue
            [ -n "$snap_ts" ] && [ "$snap_ts" -ge "$snap_cutoff" ] && snap_found="$snap_desc"
        done <<<"$snap_list"

        if [ -n "$snap_found" ]; then
            pass "pre-update snapshot taken in the last 24h — \"$snap_found\""
        else
            note "no DankMango pre-update snapshot in the last 24 hours. Expected if you haven't updated today; update.sh takes one automatically each time it runs."
        fi
    fi
fi

# =============================================================================
# 9. Are the installed DankMango scripts the shipped ones?  (informational)
# =============================================================================
# update.sh applies a DELTA: it only re-copies files that changed between your
# last recorded commit and the repo's HEAD. That makes it fast, but it also means
# it can never heal a file that went stale earlier -- once a copy is missed, no
# later update looks at that file again, because it isn't in any later delta.
# (install.sh is the repair: it re-copies the whole tree unconditionally.)
#
# So this compares what's actually deployed under ~/.config/mango against the
# clone update.sh reads from. It is the only check that can catch "you are running
# a months-old copy of a shipped script and everything LOOKS fine".
#
# SCOPE -- DankMango-owned files only:
#   scripts/  and docs/   are ours; you're not meant to edit them, so a difference
#                         is worth telling you about
#   config.conf           is YOURS. The guide actively tells you to edit it (bar
#                         position, gaps, binds), so it is deliberately NOT
#                         compared -- it would warn on every well-used install
#   dms/*.conf            not compared either: colors.conf is rewritten by matugen,
#                         outputs.conf by DMS, tagrules.conf by the generator. They
#                         live in the repo under config/dms/, not config/mango/, so
#                         walking config/mango/ skips them for free
#
# WARN, never FAIL, and the same rule the welcome-panel check uses: no reachable
# clone is normal (people move or delete it), so that's a note, not a problem.
section "9. Installed scripts vs the DankMango clone"
dm_repo=""
if [ -r "$DANKMANGO_MANIFEST" ] && have jq; then
    dm_repo="$(jq -r '.dankmango.repoDir // empty' "$DANKMANGO_MANIFEST" 2>/dev/null)"
fi
if [ -z "$dm_repo" ] || [ ! -d "$dm_repo/config/mango" ]; then
    note "can't compare your installed files against the repo (no DankMango clone found) — normal if you deleted or moved it"
else
    dm_stale=(); dm_missing=()
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        dm_dst="$HOME/.config/mango/$rel"
        if [ ! -e "$dm_dst" ]; then dm_missing+=("$rel")
        elif ! cmp -s "$dm_repo/config/mango/$rel" "$dm_dst"; then dm_stale+=("$rel")
        fi
    done < <(cd "$dm_repo/config/mango" && find scripts docs -type f 2>/dev/null | sort)

    if [ "${#dm_stale[@]}" -eq 0 ] && [ "${#dm_missing[@]}" -eq 0 ]; then
        pass "every installed script + doc matches the repo copy"
    else
        [ "${#dm_missing[@]}" -gt 0 ] && warn "not installed at all: ${dm_missing[*]}" \
            "Run install.sh from $dm_repo — it copies every file, where update.sh only copies what changed in its commit range."
        [ "${#dm_stale[@]}" -gt 0 ] && warn "differs from the repo copy: ${dm_stale[*]}" \
            "Expected if you edit these yourself. Otherwise they're STALE — an update missed them, and no later update will revisit them. Take the shipped versions: cd $dm_repo && ./install.sh"
    fi
fi

# =============================================================================
# 10. Desktop presets
# =============================================================================
# The chain is short: a preset FOLDER, a SYMLINK pointing into it, and one
# source-optional= line in config.conf pointing at the symlink. Only the middle
# link can rot silently, and it is the reason this section exists -- see the
# PRESET_LINK note in the EDIT-HERE box at the top.
section "10. Desktop presets"

if [ ! -d "$PRESETS_DIR" ]; then
    note "desktop presets aren't installed on this machine — normal if you haven't updated since they were added. Nothing is wrong; the desktop uses its baseline settings."
else
    # ---- the setter -----------------------------------------------------------
    if ! execu "$PRESET_SETTER"; then
        fail "preset switcher (setter missing)" \
             "$PRESET_SETTER isn't there or isn't runnable — the Presets bar button can't switch anything" \
             "$PRESET_SETTER (deployed from config/mango/scripts/ by install.sh stage 7a)" \
             "Re-run install.sh from the DankMango folder, or chmod +x the script." \
"$(manual_restore_script "$PRESET_SETTER")"
    else
        pass "preset setter present ($PRESET_SETTER)"
    fi

    # ---- is config.conf actually reading a preset? -----------------------------
    # WARN, not FAIL: nothing is broken, the feature is just inert. Most likely
    # cause is keeping your own config.conf when update.sh offered to replace it.
    if grep -qF 'active/preset.conf' "$MANGO_CFG" 2>/dev/null; then
        pass "config.conf includes the active preset"
    else
        warn "config.conf has no preset include line — presets are switched but never applied" \
             "Add this as the LAST source line in $MANGO_CFG, then press Super+r:  source-optional=~/.config/mango/active/preset.conf   (re-running ./install.sh restores it too)"
    fi

    # ---- THE SYMLINK ----------------------------------------------------------
    # Four states, and they are genuinely different things:
    #   nothing there      -> not in use. Fine, and the pre-presets behaviour.
    #   a regular file     -> works, but set-preset.sh will replace it on the next
    #                         switch, so say so before that surprises anyone.
    #   dangling symlink   -> THE failure this section exists for. Silent in mango.
    #   resolves to a file -> good; name the preset.
    if [ ! -e "$PRESET_LINK" ] && [ ! -L "$PRESET_LINK" ]; then
        note "no preset is active — that's a valid state and matches how DankMango behaved before presets existed. Pick one from the Presets bar button, or: $PRESET_SETTER default"
    elif [ -L "$PRESET_LINK" ] && [ ! -e "$PRESET_LINK" ]; then
        preset_broken_target="$(readlink "$PRESET_LINK" 2>/dev/null)"
        fail "desktop preset (broken link)" \
             "$PRESET_LINK points at '${preset_broken_target:-?}', which doesn't exist — your chosen preset silently stopped applying" \
             "$PRESET_LINK -> $preset_broken_target ; the folders that DO exist are under $PRESETS_DIR" \
             "Point it at a preset that exists: $PRESET_SETTER default   (mango ignores a dangling optional include without any error, which is why nothing else reports this)" \
"Your desktop has a \"preset\" chosen - a named bundle of settings like
Minimal. The shortcut that points at it has gone stale, most likely because
an update removed the preset it was pointing to. MangoWM ignores it silently,
so the only symptom is that your preset stopped having any effect.

Nothing is damaged and nothing was lost. You just need to pick a preset again.

1. See which presets you actually have:
     $PRESET_SETTER --list
   (Each one is a folder under $PRESETS_DIR.)

2. Pick one from that list. \"default\" is always safe - it applies no
   overrides at all, which is how the desktop behaves with no preset:
     $PRESET_SETTER default
   (Or click any card in the Presets button in your top bar - same thing.)

3. Re-run this health check to confirm:
     $SCRIPTS/post-update-health.sh"
    elif [ ! -L "$PRESET_LINK" ]; then
        warn "$PRESET_LINK is a normal file, not a shortcut to a preset" \
             "It still works, but the next preset switch replaces it. If it holds settings you wrote by hand, copy them into a preset folder first — see $PRESETS_DIR/README.md."
    else
        preset_target="$(readlink -f "$PRESET_LINK" 2>/dev/null)"
        preset_now="$(basename "$(dirname "$preset_target")" 2>/dev/null)"
        pass "active preset: ${preset_now:-?}  (link resolves to a real file)"

        # A link pointing OUTSIDE the presets folder is legal and works, so it is
        # only ever a note -- but it's worth naming, because such a preset isn't
        # offered by --list and won't be highlighted by the bar plugin.
        case "$preset_target" in
            "$PRESETS_DIR"/*) : ;;
            *) note "that preset lives outside $PRESETS_DIR, so the bar button won't list or highlight it. Works fine; just be aware." ;;
        esac

        # The manifest is a RECORD, not the authority -- the symlink is what mango
        # obeys. A disagreement means something repointed the link without going
        # through set-preset.sh, which is harmless but worth seeing.
        if [ -r "$DANKMANGO_MANIFEST" ] && have jq; then
            preset_recorded="$(jq -r '.userPrefs.activePreset // empty' "$DANKMANGO_MANIFEST" 2>/dev/null)"
            if [ -n "$preset_recorded" ] && [ -n "$preset_now" ] && [ "$preset_recorded" != "$preset_now" ]; then
                note "the install record still says '$preset_recorded' — the shortcut says '$preset_now', and the shortcut is what counts. Switching once with $PRESET_SETTER puts them back in step."
            fi
        fi
    fi

    # ---- BAR CLEARANCE --------------------------------------------------------
    # The bar can COVER more pixels than it RESERVES, and a preset that sets a
    # small vertical outer gap then has its windows drawn underneath it. Measured
    # in DMS 1.5.3, Modules/DankBar/DankBarWindow.qml:
    #     exclusiveZone = barThickness + spacing + bottomGap     (line 764)
    #     visual height = barThickness + spacing                 (line 663)
    # so a NEGATIVE bar "Gap" (bottomGap) overhangs by exactly that much, and
    # gappov is the only thing that can cover it:
    #     gappov >= -bottomGap
    #
    # Deliberately computed from the USER's own settings.json rather than checking
    # for a hardcoded number: bottomGap is a personal taste setting (DMS ships 0),
    # so the required clearance differs per machine.
    #
    # It does NOT depend on any display or font setting. barThickness is a function
    # of the bar's innerPadding and spacing only (Theme.barHeight is a hardcoded 48;
    # font/icon scale do not enter into it), and both terms appear on BOTH lines
    # above, so they cancel -- the overhang is exactly (-bottomGap) at every bar
    # size. Measured at bar heights 47px and 59px: overhang 15px in both.
    #
    # The gappov it compares against is the EFFECTIVE one: the active preset's if it
    # sets gappov (the preset is sourced last, so it wins), otherwise the value DMS
    # wrote to layout.conf. Both are worth checking -- a too-small DMS slider clips
    # windows exactly the same way a too-small preset does.
    #
    # WARN, never FAIL: the desktop still works, windows just look wrong at the
    # bottom edge.
    preset_bottom_gap=""
    if have jq && [ -r "$BAR_SETTINGS" ]; then
        preset_bottom_gap="$(jq -r '.barConfigs[0].bottomGap // 0' "$BAR_SETTINGS" 2>/dev/null)"
    fi
    case "$preset_bottom_gap" in
        ''|*[!0-9-]*) preset_bottom_gap="" ;;          # unreadable -> skip quietly
    esac
    if [ -n "$preset_bottom_gap" ] && [ "$preset_bottom_gap" -lt 0 ] 2>/dev/null; then
        preset_need=$(( -preset_bottom_gap ))
        # The EFFECTIVE gappov: the active preset's, if it sets one (it is sourced
        # last, so it wins); otherwise whatever DMS wrote to layout.conf.
        preset_gappov=""
        if [ -n "${preset_target:-}" ] && [ -f "${preset_target:-}" ]; then
            preset_gappov="$(sed -n 's/^[[:space:]]*gappov[[:space:]]*=[[:space:]]*\([0-9]\{1,\}\).*/\1/p' "$preset_target" | tail -1)"
        fi
        preset_gappov_src="the active preset"
        if [ -z "$preset_gappov" ]; then
            preset_gappov="$(sed -n 's/^[[:space:]]*gappov[[:space:]]*=[[:space:]]*\([0-9]\{1,\}\).*/\1/p' "$HOME/.config/mango/dms/layout.conf" 2>/dev/null | tail -1)"
            preset_gappov_src="DMS Settings -> Compositor Layout"
        fi
        if [ -z "$preset_gappov" ]; then
            note "couldn't work out the vertical window gap, so the bar-clearance check was skipped. Harmless."
        elif [ "$preset_gappov" -ge "$preset_need" ]; then
            pass "windows clear the bar (gap $preset_gappov >= $preset_need needed for your bar's Gap of $preset_bottom_gap)"
        else
            warn "windows are drawn UNDER the bar: the vertical gap is ${preset_gappov}px but your bar needs ${preset_need}px" \
                 "Your bar's Gap setting is $preset_bottom_gap, so it covers ${preset_need}px more than it reserves and the bottom edge of every tiled window is hidden. Raise gappov to at least $preset_need in $preset_gappov_src (see ~/.config/mango/presets/README.md), or set the bar's Gap back to 0 in DMS Settings -> Appearance."
        fi
    fi

    # ---- the launcher plugin --------------------------------------------------
    # Same three-state registration pattern (and the same tones) as the welcome
    # panel in section 7: enabled, deliberately off, or not registered at all.
    # NOTE: there is no bar widget to check for any more -- presets moved to the
    # launcher surface on purpose, so "not in your DankBar layout" is correct now,
    # not a fault.
    if [ -f "$PRESET_PLUGIN_DIR/PresetSwitcherLauncher.qml" ]; then
        pass "preset switcher plugin files present ($PRESET_PLUGIN_DIR)"
    elif [ -f "$PRESET_PLUGIN_DIR/PresetSwitcherBar.qml" ]; then
        warn "the OLD bar-widget version of the Presets plugin is still installed" \
             "It became a launcher plugin. Re-run ./install.sh from your DankMango folder, then 'dms restart' — after that, open the launcher and type 'preset'."
    else
        warn "the Presets launcher plugin isn't installed at $PRESET_PLUGIN_DIR" \
             "Presets still work from the terminal ($PRESET_SETTER --list). To get them in the launcher, re-run ./install.sh from your DankMango folder, then 'dms restart'."
    fi
    if plugin_enabled "$PRESET_ID"; then
        pass "preset switcher enabled in plugin_settings.json (launcher trigger: type it in the launcher)"
    elif grep -q "\"$PRESET_ID\"" "$PLUGIN_SETTINGS" 2>/dev/null; then
        note "the Presets plugin is switched off in DMS Settings -> Plugins. Nothing wrong with that — presets still work from the terminal."
    else
        warn "the Presets plugin isn't registered in plugin_settings.json — DMS won't load it" \
             "Run ./update.sh from your DankMango folder (its 'register-shipped-plugins' step adds it), or turn it on in DMS Settings -> Plugins, then 'dms restart'."
    fi
fi

# =============================================================================
# 11. DMS KEYBIND INJECTION GUARD
# =============================================================================
# config.conf used to end with "source = ./dms/binds.conf". That file is DMS-MANAGED:
# `dms keybinds set`, `dms keybinds remove` and `dms setup binds` REGENERATE it from
# DMS's stock defaults (~90 binds) rather than editing it line-by-line. Sourcing it
# meant any of those commands silently queued a pile of foreign binds into the live
# keymap at the next reload. Confirmed live: `dms keybinds remove` turned an 85-byte
# file into 4310 bytes of defaults.
#
# The source line is now gone (see the comment block where it used to be, near the
# bottom of config.conf) and the shipped dms/binds.conf is empty. But NEITHER of
# those is self-defending: `dms setup binds` can re-add the source line -- the dms
# binary carries the literal string "source=./dms/binds.conf" for exactly that -- and
# any `dms keybinds` write refills the file. So check both halves, every run.
#
# Why this is a FAIL and not a warn: the damage is silent and arrives one reload
# later, which is the same shape as the install.sh backup-then-overwrite bug. You
# would find out by pressing a key and getting someone else's idea of what it does.
#
# Section 9 deliberately skips dms/*.conf when it compares deployed files against the
# clone (they're runtime-regenerated, so a diff there is normal). That is precisely
# the blind spot this section covers.
section "11. DMS keybind injection guard"

hb_conf="$MANGO_CFG"
hb_binds="$HOME/.config/mango/dms/binds.conf"

# ---- half 1: has a source line for binds.conf come back? --------------------
# Matches both spellings mango accepts (source= and source-optional=) and both the
# ./dms/ and ~/.config/mango/dms/ forms, with or without spaces around the '='.
hb_src_line="$(grep -nE '^[[:space:]]*source(-optional)?[[:space:]]*=[[:space:]]*[^#]*binds\.conf' "$hb_conf" 2>/dev/null | head -1)"

if [ -z "$hb_src_line" ]; then
    pass "config.conf does not source DMS's binds.conf"
else
    fail "DMS keybind injection (config.conf sources binds.conf again)" \
         "config.conf line ${hb_src_line%%:*} sources DMS's managed binds.conf — a 'dms keybinds' or 'dms setup binds' run can now inject ~90 stock binds into your keymap" \
         "$hb_conf line ${hb_src_line%%:*}: ${hb_src_line#*:}" \
         "Delete that source line from config.conf, then reload with SUPER+SHIFT+r. DankMango declares all of its binds in config.conf itself." \
"A line has come back into MangoWM's settings file that lets DankMaterialShell
add its own keyboard shortcuts to yours. That is almost certainly not something
you did by hand - running \"dms setup binds\" puts this line back automatically.

Nothing is broken this second. The risk is the NEXT time the desktop reloads:
DMS's own set of shortcuts (about 90 of them) can be pulled in alongside yours.
Where you and DMS both use a key, yours still wins. Where you DON'T use a key,
DMS's version simply appears - so keys start doing things you never set up.

1. Open MangoWM's settings file:
     nano $hb_conf

2. Press Ctrl+W, type binds.conf and press Enter. That jumps to the line:
     ${hb_src_line#*:}

3. Delete the whole line. In nano, put the cursor on it and press Ctrl+K.

4. Save and exit: Ctrl+O, then Enter, then Ctrl+X.

5. Reload the desktop so the change takes effect:
     Press SUPER+SHIFT+r

6. Re-run this check to confirm:
     $SCRIPTS/post-update-health.sh

You lose nothing by deleting it. Every shortcut DankMango gives you is written
in this same file, further up - that line only ever added DMS's extras on top."
fi

# ---- half 2: has the managed file been regenerated? -------------------------
# Any real bind line at all means DMS rewrote it; the shipped copy is comment-only.
if [ ! -f "$hb_binds" ]; then
    note "no ~/.config/mango/dms/binds.conf on this machine — fine, nothing sources it"
else
    hb_n="$(grep -cE '^[[:space:]]*(bind|gesturebind|mousebind|axisbind)[[:space:]]*=' "$hb_binds" 2>/dev/null || true)"
    [ -n "$hb_n" ] || hb_n=0
    if [ "$hb_n" -eq 0 ]; then
        pass "dms/binds.conf is empty (declares no binds)"
    elif [ -n "$hb_src_line" ]; then
        # Both halves broken: the FAIL above already covers it, and its fix (delete
        # the source line) defuses this too. Say so rather than raising a second
        # PROBLEM entry for one situation.
        note "dms/binds.conf also holds $hb_n regenerated bind(s) — deleting the source line above defuses them; ./install.sh then restores the empty file"
    else
        warn "DMS regenerated dms/binds.conf ($hb_n bind lines) — nothing sources it, so it is inert, but the file has drifted" \
             "Put the empty shipped copy back: run ./install.sh from your DankMango folder. Do NOT re-add a source line for it in config.conf."
    fi
fi

section "12. Ripe Chroma, the wallpaper colour engine (optional)"

# Path is HARDCODED, not sourced. This script ships standalone (it is copied to
# ~/.config/mango/scripts and must run on a machine with no clone reachable), so
# it cannot read lib/common.sh. Keep this in sync with RIPE_CHROMA_BIN there --
# same arrangement as the SNAPSHOT_DESC_PREFIX copy in section 8.
RC_BIN="$HOME/.local/bin/dankmango-ripe-chroma"
# The palette the fan-out tells the engine to write, and DMS's own session state
# (where the current wallpaper lives). Both are only ever READ here.
RC_THEME="$DMS_DIR/dankmango-theme.json"
RC_SESSION="$HOME/.local/state/DankMaterialShell/session.json"
# Guards 12b-12d below: only set once the binary is known present and runnable.
RC_OK=0

if [ ! -e "$RC_BIN" ]; then
    # OPT-OUT IS NOT A PROBLEM. The engine is an opt-in extra (install.sh stage
    # 13b) and everything downstream is guarded on the binary existing, so a
    # machine without it is fully healthy. Say so as a note and move on rather
    # than nagging someone about a feature they deliberately declined.
    note "Ripe Chroma not installed — optional, and nothing depends on it (install.sh stage 13b offers it)"
elif [ ! -x "$RC_BIN" ]; then
    fail "Ripe Chroma is not executable" \
         "$RC_BIN exists but has lost its execute bit" \
         "$RC_BIN" \
         "Most likely a restore-from-backup or a copy that dropped the mode bits." \
"Ripe Chroma is installed but can't be run.

1. Open a terminal (Super+Return) and put the execute bit back:
     chmod +x $RC_BIN

2. Confirm it runs:
     $RC_BIN --help

3. Re-run this check:
     $SCRIPTS/post-update-health.sh"
elif ! "$RC_BIN" --help >/dev/null 2>&1; then
    # Exists and is executable but won't actually run -- the classic cause is a
    # system library moving under a compiled binary (a glibc/gcc upgrade), which
    # a mode-bit check alone would report as healthy.
    fail "Ripe Chroma won't run" \
         "$RC_BIN is executable but exits non-zero on --help" \
         "$RC_BIN" \
         "Usually a compiled binary left behind by a system library upgrade; rebuilding fixes it. Detail: $("$RC_BIN" --help 2>&1 | head -3)" \
"Ripe Chroma is installed but won't start.

This normally means the system libraries it was built against have been
updated. Rebuilding it against the current ones fixes it.

1. Go to the folder you cloned DankMango into (the one with install.sh in it):
     cd ~/DankMango

2. Rebuild and reinstall it:
     cd tools/ripe-chroma
     cargo build --release
     install -m 755 target/release/dankmango-ripe-chroma $RC_BIN
     cargo clean

   If that says 'cargo: command not found', install the toolchain first:
     sudo pacman -S rust

3. Confirm it runs:
     $RC_BIN --help

4. Re-run this check:
     $SCRIPTS/post-update-health.sh"
else
    RC_OK=1
    pass "Ripe Chroma installed and runnable ($RC_BIN)"
fi

# Everything below only makes sense once the binary above is known good, so it
# hangs off RC_OK (set in the `else` arm) rather than re-testing three times.
if [ "$RC_OK" = 1 ]; then

# ---- 12b. do the installed pieces still AGREE on where the engine is? -------
# THE HARDCODED PATH IS THIS FEATURE'S SINGLE POINT OF FAILURE. Nothing
# discovers the binary: the wallpaper fan-out, the control hub's Ripe Chroma
# section and RC_BIN above each name it independently (they have to -- this
# script ships standalone and cannot source lib/common.sh, and a QML plugin
# cannot source anything at all). Every one of those call sites is guarded on
# `[ -x ]` or an equivalent, so a file still holding a PRE-RENAME name does not
# error: it silently does nothing. That is not a hypothetical failure mode --
# it is exactly what a rename of this binary did, and it was only caught by
# hand. Same reasoning for the output path: two files decide where the palette
# is written, and if they ever disagree the hub's Generate button and the
# automatic wallpaper run quietly write to two different files, so one of them
# is always the file DMS isn't reading.
RC_HUB_QML="$DMS_DIR/plugins/controlHub/RipeChromaSection.qml"
# Match on the "$HOME/..."-spelled form the shipped files use, and on the fully
# expanded form as well, so a hand-edited absolute path still counts as agreeing.
rc_tok_bin="\$HOME/${RC_BIN#"$HOME"/}"
rc_tok_theme="\$HOME/${RC_THEME#"$HOME"/}"
rc_names() { # rc_names FILE LITERAL TOKEN -> is this path named in this file?
    grep -qF -- "$2" "$1" 2>/dev/null || grep -qF -- "$3" "$1" 2>/dev/null
}
rc_drift=""
for rc_f in "$BORDER_WATCHER" "$RC_HUB_QML"; do
    if [ ! -f "$rc_f" ]; then
        # Not a Ripe Chroma fault and not this section's business: a missing
        # watcher is section 4's, and a machine without the control hub simply
        # has no Generate button. Say so and check the ones that are here.
        note "not installed, so nothing to cross-check there: $rc_f"
        continue
    fi
    rc_names "$rc_f" "$RC_BIN"   "$rc_tok_bin"   || rc_drift="$rc_drift
    $rc_f
      never names the engine binary $RC_BIN"
    rc_names "$rc_f" "$RC_THEME" "$rc_tok_theme" || rc_drift="$rc_drift
    $rc_f
      never names the palette file $RC_THEME"
done
if [ -n "$rc_drift" ]; then
    fail "Ripe Chroma path drift (an installed file points somewhere else)" \
         "the engine is fine, but something that calls it disagrees about where it is:$rc_drift" \
         "$BORDER_WATCHER, $RC_HUB_QML, RC_BIN/RC_THEME at the top of section 12 here, and RIPE_CHROMA_BIN in the clone's lib/common.sh" \
         "The path is deliberately hardcoded in several places (this script ships standalone; QML can't source shell). A rename or a half-finished update that misses one of them FAILS SILENTLY, because every call site is guarded on the file existing. Re-running ./install.sh recopies both the watcher and the plugin from the clone, which is the fix unless the CLONE is the thing that's out of date." \
"Your wallpaper colour engine still works, but one of the two things that
call it is looking for it in the wrong place, so that half quietly does
nothing.

1. Go to the folder you cloned DankMango into (the one with install.sh
   in it) and make sure it's up to date. Open a terminal (Super+Return):
     cd ~/DankMango
     git pull

2. Re-install from it. This recopies the wallpaper watcher and the
   control-hub plugin over the out-of-date ones:
     ./install.sh
   (Answer the questions as you did before. Nothing is deleted.)

3. Restart the shell so the recopied plugin is loaded:
     dms restart

4. Re-run this check:
     $SCRIPTS/post-update-health.sh
   If it still reports drift, the CLONE itself is the out-of-date copy -
   report it at https://github.com/AhjinYeri/DankMango/issues"
else
    pass "the wallpaper fan-out and the control hub both point at the current $RC_BIN"
fi

# ---- 12c. is the RUNNING watcher running the CURRENT code? ------------------
# A LONG-LIVED BASH SCRIPT DOES NOT PICK UP EDITS TO ITSELF. This watcher is
# started once from config.conf's exec-once and then runs for the whole session,
# so an update that rewrites it leaves the LIVE process executing the code it
# was started with -- including the pre-rename path to a binary that no longer
# exists. Nothing else in this system will ever mention that: the fan-out's
# guard just goes quiet, and 12b above happily passes, because the file on disk
# IS correct. The only observable difference is the one nobody watches for --
# changing your wallpaper stops changing the palette.
#
# This was found once by hand, after a rename, on a live session. It is the
# reason this check exists.
#
# HOW THE STALENESS IS ESTABLISHED, in order of certainty:
#   1. fd 255 is the script file bash is executing (bash keeps the script open
#      there). If that link reads "... (deleted)", the file it is running was
#      replaced or renamed out from under it -- conclusive.
#   2. If fd 255 names a DIFFERENT path, the running copy isn't the installed
#      one at all (started straight out of a clone, say).
#   3. Otherwise compare mtimes: /proc/PID's own mtime is the process start
#      time, so an installed script NEWER than that has been rewritten since the
#      process read it. install.sh/update.sh copy with `cp` (same inode, no
#      "deleted" marker), so for a normal update this is the test that fires.
#      This one is a "may", not a "did", and the wording says so: update.sh
#      only re-copies files whose CONTENT changed, so there a bumped mtime does
#      mean different code -- but install.sh re-copies its whole tree
#      unconditionally, so a plain re-run bumps the mtime with identical
#      content. Restarting the watcher is the right answer after either, so the
#      advice holds; it just isn't proof that the code differs.
if have fuser; then
    rc_pid="$(fuser "$BORDER_LOCK" 2>/dev/null | tr -s ' ' '\n' | grep -m1 -E '^[0-9]+$')"
    if [ -z "${rc_pid:-}" ]; then
        # Section 4 already reports (and offers to start) a watcher that isn't
        # running. Nothing to add here beyond what it means for the engine.
        note "wallpaper watcher isn't running — see section 4; until it is, the palette only changes when you press Generate"
    else
        rc_exec="$(readlink "/proc/$rc_pid/fd/255" 2>/dev/null)"
        rc_started="$(stat -c %Y "/proc/$rc_pid" 2>/dev/null)"
        rc_ondisk="$(stat -c %Y "$BORDER_WATCHER" 2>/dev/null)"
        rc_why=""
        case "$rc_exec" in
            *" (deleted)") rc_why="the file it is running was replaced or renamed while it was running (${rc_exec})" ;;
            "")            : ;;   # not bash, or /proc unreadable -> fall through to mtimes
            "$BORDER_WATCHER") : ;;
            *)             rc_why="it is running $rc_exec, not the installed $BORDER_WATCHER" ;;
        esac
        if [ -z "$rc_why" ] && [ -n "${rc_started:-}" ] && [ -n "${rc_ondisk:-}" ] \
           && [ "$rc_ondisk" -gt "$rc_started" ]; then
            rc_why="$BORDER_WATCHER was rewritten $(( (rc_ondisk - rc_started) / 60 )) minute(s) after this process started, so the live copy may still be running the previous version"
        fi
        if [ -n "$rc_why" ]; then
            # WARN, not FAIL, and deliberately: this is the same shape as "the
            # watcher isn't running" in section 4 (strictly the worse problem,
            # also a WARN), and it clears with one offered command. Being louder
            # than the worse case would be inconsistent.
            warn "the RUNNING wallpaper watcher (pid $rc_pid) is executing OLD code — $rc_why" \
                 "Restart it:  kill $rc_pid; sleep 1; setsid '$BORDER_WATCHER' >/dev/null 2>&1 & disown
         Then press Generate in the control hub's Ripe Chroma section — a restart
         re-baselines and waits for the NEXT wallpaper change, so it will not
         backfill the palette on its own."
            offer "restart the wallpaper watcher (it is running out-of-date code)" \
                  "kill $rc_pid; sleep 1; setsid '$BORDER_WATCHER' >/dev/null 2>&1 &"
        else
            pass "the running wallpaper watcher (pid $rc_pid) is the current $BORDER_WATCHER"
        fi
    fi
fi

# ---- 12d. if the palette IS the live theme, is it intact and current? -------
# Only asked when DMS is actually reading Ripe Chroma's file. Pointing DMS at
# the palette is a separate, manual choice (Settings -> Theme & Colors ->
# Custom), so on a machine that generates it without displaying it there is
# nothing here that can be wrong -- and saying so as a note keeps this section
# quiet for someone who deliberately stayed on matugen's dynamic theme.
if have jq && [ -f "$BAR_SETTINGS" ]; then
    rc_cur="$(jq -r '.currentThemeName // empty' "$BAR_SETTINGS" 2>/dev/null)"
    rc_live="$(jq -r '.customThemeFile // empty' "$BAR_SETTINGS" 2>/dev/null)"
    case "$rc_live" in "~/"*) rc_live="$HOME/${rc_live#\~/}" ;; esac
    if [ "$rc_cur" != custom ] || [ -z "$rc_live" ]; then
        note "DMS is on the '${rc_cur:-dynamic}' theme, so the palette is generated but not displayed — a choice, not a fault (Settings -> Theme & Colors -> Custom turns it on)"
    elif [ "$rc_live" != "$RC_THEME" ]; then
        # Somebody else's theme file. The engine deliberately never writes to a
        # file it wasn't told to (the fan-out passes --output explicitly for
        # exactly this reason), so this is a working setup, just not ours.
        note "DMS's custom theme is $rc_live, which isn't Ripe Chroma's palette — left alone"
    elif [ ! -f "$rc_live" ]; then
        # DMS is pointed at a file that isn't there. Visible and confusing:
        # the shell falls back to defaults with no explanation of why.
        fail "Ripe Chroma's palette is missing" \
             "DMS's custom theme is set to $rc_live, but that file does not exist" \
             "$rc_live, customThemeFile in $BAR_SETTINGS" \
             "The palette is a generated file, not a shipped one, so nothing restores it on install — it is (re)created by pressing Generate in the control hub or by changing the wallpaper with the fan-out running. A deleted ~/.config/DankMaterialShell or a restore-from-backup is the usual cause." \
"DankMaterialShell is set to use a colour palette file that isn't there,
so your colours have fallen back to the defaults.

1. Open the control hub (the DankMango panel on your bar) and find the
   Ripe Chroma section.

2. Press Generate. That writes the palette file again from your current
   wallpaper, and the colours should change immediately.

3. Re-run this check:
     $SCRIPTS/post-update-health.sh

   If there is no Ripe Chroma section in the hub, set your wallpaper
   again instead (gear icon on the bar -> Wallpaper) - the wallpaper
   watcher regenerates the palette on any wallpaper change."
    elif ! jq -e '(.dark|type=="object") and (.light|type=="object")
                  and (.dark.primary|type=="string")' "$rc_live" >/dev/null 2>&1; then
        # DMS re-reads this file on every change (Theme.qml's customThemeFileView
        # is a watching FileView), so a truncated or half-written one is a parse
        # error and a toast in the user's face. The engine writes temp+rename
        # precisely so it can't cause this -- which means if it IS malformed,
        # something else did it, and no amount of re-running the engine explains
        # the problem to the user.
        fail "Ripe Chroma's palette is not a usable theme file" \
             "$rc_live is DMS's live custom theme but doesn't parse as one (expected JSON with 'dark' and 'light' colour objects)" \
             "$rc_live" \
             "The engine writes this file atomically (temp + rename), so it does not produce half-written output — suspect a hand edit, a full disk, or a restore-from-backup. Regenerating overwrites it wholesale." \
"The colour palette file DankMaterialShell is reading is damaged, so the
shell can't load your colours from it.

1. Open the control hub (the DankMango panel on your bar), find the
   Ripe Chroma section, and press Generate. That rewrites the file
   completely from your current wallpaper.

2. Re-run this check:
     $SCRIPTS/post-update-health.sh

3. If it is still reported as damaged, your disk may be full. Check with:
     df -h $HOME
   If the 'Use%' column says 100%, free some space and try step 1 again."
    else
        pass "Ripe Chroma's palette is DMS's live theme and parses cleanly ($rc_live)"

        # --- and does it still match the wallpaper it is supposed to follow? ---
        # THE POINT OF THE ENGINE IS THAT THE PALETTE FOLLOWS THE WALLPAPER, and
        # every way that stops happening (a stale watcher, a watcher that was
        # down when the wallpaper changed, a regeneration that failed) is
        # silent. The palette is deterministic -- extract.rs uses a FIXED k-means
        # seed exactly so one wallpaper always gives one palette -- so this can
        # be settled rather than guessed: regenerate to stdout with the same
        # preferences the fan-out would use and compare. Nothing is written.
        rc_prefs="$(jq -c '.controlHub.colorEngine // empty' "$PLUGIN_SETTINGS" 2>/dev/null)"
        rc_seeded="$(printf '%s' "$rc_prefs" | jq -r '.useSeed // false' 2>/dev/null)"
        if [ "$rc_seeded" = true ]; then
            # Static mode is the documented opt-out from following the
            # wallpaper, so a palette that doesn't match it is CORRECT here.
            note "palette is pinned to a fixed seed colour (static mode) — it is meant to ignore the wallpaper, so there is nothing to compare"
        else
            rc_mode="$(printf '%s' "$rc_prefs" | jq -r '.mode  // empty' 2>/dev/null)"
            rc_count="$(printf '%s' "$rc_prefs" | jq -r '.count // empty' 2>/dev/null)"
            # Same validation the fan-out applies, so a comparison can never
            # fail over a preference the fan-out would have ignored anyway.
            case "$rc_mode"  in accurate|vibrant|muted) ;; *) rc_mode=accurate ;; esac
            case "$rc_count" in 3|4|5|6|7|8)            ;; *) rc_count=5       ;; esac
            rc_wp="$(jq -r '.wallpaperPath // empty' "$RC_SESSION" 2>/dev/null)"
            if [ -z "$rc_wp" ] || [ ! -f "$rc_wp" ]; then
                note "no readable wallpaper in DMS's session state — can't compare the palette against it"
            else
                rc_tmp="$(mktemp 2>/dev/null)" || rc_tmp=""
                if [ -n "$rc_tmp" ] \
                   && "$RC_BIN" --wallpaper "$rc_wp" --count "$rc_count" --mode "$rc_mode" \
                                --output - >"$rc_tmp" 2>/dev/null && [ -s "$rc_tmp" ]; then
                    if cmp -s "$rc_tmp" "$rc_live"; then
                        pass "palette is current for the wallpaper ($rc_mode, $rc_count colours — regenerated and compared, byte for byte)"
                    else
                        # A MISMATCH ON ITS OWN DOES NOT MEAN THE PALETTE IS STALE,
                        # and reporting it as if it did would nag people for using
                        # the feature correctly. The hub's mode buttons and colour
                        # slider persist the moment you touch them, but the palette
                        # is only written when you press Generate -- that split is
                        # deliberate (it's what makes the live PREVIEW a preview),
                        # so "looked at a setting, didn't apply it" leaves saved
                        # prefs that don't describe the file, with nothing wrong.
                        #
                        # The two cases are distinguishable, so distinguish them
                        # rather than warning about both. Every setting is a
                        # 3-mode x 6-count grid and the engine is deterministic, so
                        # sweep it against THIS wallpaper: a hit means the palette
                        # did come from the current wallpaper (just at other
                        # settings) and only the settings are ahead of it; no hit
                        # at all means it came from a different image, which is the
                        # real failure -- a wallpaper change that never reached the
                        # engine. The sweep is ~1s and only ever runs on a
                        # mismatch, so the healthy path stays one run.
                        rc_hit=""
                        for rc_m in accurate vibrant muted; do
                            for rc_c in 3 4 5 6 7 8; do
                                "$RC_BIN" --wallpaper "$rc_wp" --count "$rc_c" --mode "$rc_m" \
                                          --output - >"$rc_tmp" 2>/dev/null || continue
                                if cmp -s "$rc_tmp" "$rc_live"; then rc_hit="$rc_m, $rc_c colours"; break 2; fi
                            done
                        done
                        if [ -n "$rc_hit" ]; then
                            note "palette matches your wallpaper but was made at $rc_hit, not the saved $rc_mode/$rc_count — you changed a setting without pressing Generate. Nothing is broken; Generate applies it (so does your next wallpaper change)"
                        else
                            warn "the live palette was NOT generated from your current wallpaper — a wallpaper change never reached the engine" \
                                 "Press Generate in the control hub's Ripe Chroma section to bring it up to date.
         Then check 12c above: a watcher running old code is what stops wallpaper
         changes from reaching the engine in the first place. (If you hand-edited
         the palette yourself, ignore this — Generate would overwrite your edits.)"
                        fi
                    fi
                else
                    note "couldn't regenerate the palette to compare against (wallpaper unreadable by the engine?) — the file itself is fine"
                fi
                [ -n "$rc_tmp" ] && rm -f "$rc_tmp"
            fi
        fi
    fi
fi

fi   # RC_OK

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
    your password. Nothing appears on screen while you type it - that's
    normal, just type it and press Enter.
  * Nothing below deletes anything. If a step doesn't work you can stop
    there, and nothing will be worse than it is now.
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
        printf '\n  %sWhat'"'"'s wrong%s\n' "$c_yel" "$c_off"
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
