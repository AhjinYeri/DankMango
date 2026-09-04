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
#     13. The control hub (SUPER+d), the front door the fix advice routes through
#    ...plus it records the mango / dms-shell / quickshell versions and tells you
#    which changed since the last run (a changed version = prime suspect for a break).
#
#  THE SCAN NEVER CHANGES ANYTHING
#    Every section above is read-only, and that is not negotiable: a health check
#    you cannot run because you are not sure what it will do is not a health check.
#    New-version breakage can't be predicted, so the scan only DETECTS and REPORTS.
#
#  ...AND THEN OFFERS TO FIX WHAT IT SAFELY CAN
#    Some findings have a repair that is entirely mechanical -- re-applying a patch
#    the dispatcher already owns, putting a shipped file back from your clone,
#    starting a watcher that should be running. Those are tagged [FIX!] in the scan
#    (one line, like every other finding) and collected at the END of the report,
#    where they are walked through ONE AT A TIME. Each one shows what broke, what
#    the fix will do, the command to type instead, and a Claude Code prompt, and
#    then asks y/N. There is no "fix everything" shortcut, on purpose.
#
#    The default is always no. Run this piped, redirected or from cron and the
#    walkthrough prints as a plain report: nothing is asked, and nothing is changed.
#    Anything that overwrites a file backs it up into ~/.config/mango/backups first,
#    and every repair verifies the machine actually changed before saying "fixed."
#
#    A finding whose repair needs a judgement call, a package install, a password
#    for something other than an existing patch, or a reboot is NOT tagged [FIX!].
#    It reports exactly as it always did, with step-by-step manual instructions.
#
#  USAGE
#    ~/.config/mango/scripts/post-update-health.sh
#
#  TWO MACHINE-READABLE MODES (for the control hub's Health & Repair section)
#    --json            print the whole scan as JSON on stdout and exit, printing
#                      none of the report above. Every finding is in there, and
#                      every [FIX!] finding carries its full walkthrough text
#                      plus a STABLE ID.
#    --apply-fix <id>  re-run the scan, then apply the one [FIX!] remedy with
#                      that id -- the same function, with the same
#                      did-it-actually-change guard, that pressing y in the
#                      walkthrough calls. Exit 0 applied, 1 the remedy failed,
#                      4 no finding with that id (most often: already fixed).
#
#    Both exist so the GUI can be a WRAPPER. No check and no repair is
#    reimplemented in QML; this file stays the only thing that knows what is
#    broken and how to put it right. Neither mode changes a byte of the report
#    the no-flag run prints.
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

# ---- which mode are we in? --------------------------------------------------
# report   the only mode that existed before, and still the default. Unchanged.
# json     emit the scan as JSON, print no report.
# applyfix apply exactly one remedy by id, print only what that remedy prints.
#
# An UNKNOWN argument is now an error rather than being ignored. That is a
# deliberate consequence of there being flags at all: a mistyped "--jsno" used to
# fall through and silently run the interactive walkthrough, which is the last
# thing a caller that meant to ask for JSON should get.
HEALTH_MODE=report
HEALTH_FIX_ID=""
case "${1:-}" in
    "")   : ;;
    --json) HEALTH_MODE=json ;;
    --apply-fix)
        HEALTH_MODE=applyfix
        HEALTH_FIX_ID="${2:-}"
        [ -n "$HEALTH_FIX_ID" ] || { printf '%s: --apply-fix needs the id of a [FIX!] finding (see --json).\n' "${0##*/}" >&2; exit 2; }
        ;;
    *)    printf '%s: unknown option "%s". Try --help.\n' "${0##*/}" "$1" >&2; exit 2 ;;
esac

# THE SCAN IS MUTED, NOT SKIPPED, in both machine modes. Every check still runs --
# the registries below are what --json reads and what --apply-fix looks an id up
# in, and they only exist as a side effect of running the scan. Real stdout is
# parked on fd 3 and restored at the dispatch point near the end of this file, so
# a caller's stdout carries the JSON (or the remedy's own output) and nothing else.
# stderr is left exactly where it was: a diagnostic has somewhere to go, and it
# cannot pollute the JSON, which goes to stdout.
if [ "$HEALTH_MODE" != report ]; then
    exec 3>&1 1>/dev/null
fi

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
GTK3_USER_CSS="$HOME/.config/gtk-3.0/gtk.css"             # layer 2: user overrides only
GTK3_PALETTE="$HOME/.config/gtk-3.0/dank-colors.css"     # layer 1: matugen palette (DMS writes it)
GTK3_SHADOW_MARK="DankMango GTK3 live-theme shadow"      # marker inside our generated themes
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
c_cyn=$'\033[36m'               # reserved for [FIX!] -- nothing else uses it
US=$'\037'                      # unit separator to pack 5 fields per failure
FAILS=()                        # each entry: component US symptom US where US fix US manual
# FIXES -- findings that have a genuine, mechanical, reversible remedy. These are
# NOT a severity: a fixable finding is still a warning or still a failure, and the
# sev field below is what preserves that. What makes an entry belong here is only
# that pressing "y" can put it right without asking the user to decide anything.
FIXES=()                        # each entry: 10 US-separated fields (see fixable())
PASS_N=0                        # how many checks passed, for the walkthrough header

# FINDINGS -- every row the scan prints, in the order it printed them, kept for
# --json alone. Nothing in the terminal path reads it, and adding to it is why
# the five functions below each grew one line and no other behaviour.
#
# Each entry: tag US section US id US message US detail US manual US where
#   tag   PASS | WARN | NOTE | FAIL | FIX   (NOTE is the "[ -- ]" row)
#   id    a FIX row carries the STABLE id its author gave it -- that is the id
#         --apply-fix takes. Every other row gets a positional "auto:N", which is
#         honest about what it is: those rows are display-only, there is nothing
#         to act on, and inventing stable ids for the ~90 pass() calls would be a
#         maintenance burden bought with nothing.
FINDINGS=()
CUR_SECTION=""                  # set by section(), stamped onto each finding
FINDING_N=0                     # ordinal behind the "auto:N" ids

# add_finding TAG ID MESSAGE DETAIL MANUAL WHERE
add_finding() { FINDINGS+=("$1${US}$CUR_SECTION${US}$2${US}$3${US}${4:-}${US}${5:-}${US}${6:-}"); }
# auto_id -> the next positional id, for a row nobody can act on
auto_id() { FINDING_N=$((FINDING_N+1)); printf 'auto:%d' "$FINDING_N"; }

section() { CUR_SECTION="$1"; printf '\n%s— %s —%s\n' "$c_dim" "$1" "$c_off"; }
pass()    { PASS_N=$((PASS_N+1)); add_finding PASS "$(auto_id)" "$1"; printf '  %s[PASS]%s %s\n' "$c_grn" "$c_off" "$1"; }
warn()    { add_finding WARN "$(auto_id)" "$1" "$2"; printf '  %s[WARN]%s %s\n         %s\n' "$c_yel" "$c_off" "$1" "$2"; }
# wrap WIDTH INDENT TEXT -- fold a string that came from a registry into the
# hand-wrapped prose around it. Everything else in this script is wrapped to ~72
# columns by hand; a patch's blurb/verify text arrives as one long line and would
# otherwise run off the terminal. Continuation lines get INDENT spaces so they sit
# under the start of the sentence rather than under a step number.
wrap() { printf '%s' "$3" | fold -s -w "$1" | awk -v i="$2" 'NR==1{print;next}{printf "%*s%s\n", i, "", $0}'; }
# note -- neither pass nor fail: a thing that is deliberately switched off. Used for
# opt-in patches the user declined, which are NOT problems and must not be counted
# as failures (the old code reported one as FAIL on every single run).
note()    { add_finding NOTE "$(auto_id)" "$1"; printf '  %s[ -- ]%s %s\n' "$c_dim" "$c_off" "$1"; }
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
    add_finding FAIL "$(auto_id)" "$1" "$2" "$manual" "$3"
}
# =============================================================================
#  fixable -- the [FIX!] tag, and the registry behind it
# =============================================================================
#  fixable ID SEVERITY HEADLINE BROKE DOES MANUAL PROMPT REMEDY [CLASS] [NEEDSPW]
#
#    ID        a STABLE identifier for this finding, chosen by whoever wrote the
#              check. It is what `--apply-fix <id>` takes, so it must survive the
#              headline being reworded -- that is the whole reason it is written
#              out here rather than derived from the text. Findings raised inside
#              a loop take the loop variable ("script-stale:scripts/foo.sh",
#              "patch:combined-audio-osd"), so one file drifting does not renumber
#              the others. It is never shown to anyone.
#    SEVERITY  "warn" or "fail": what this finding WOULD have been reported as
#              before it was fixable. It does NOT change the printed tag; it
#              decides the exit code, so a fixable FAIL that the user skips still
#              exits non-zero exactly as it did when it was a plain fail().
#    HEADLINE  the one-line scan text. Same discipline as pass/note: ONE line,
#              no explanation, no wrapped second line. The explanation is the
#              walkthrough's job, and repeating it inline would print it twice.
#    BROKE     plain English -- what has actually gone wrong, no jargon
#    DOES      plain English -- what pressing y does to this machine, including
#              anything it will ask for (a password) or anything left to do after
#    MANUAL    the exact command(s) to type instead, for doing it by hand
#    PROMPT    a request to paste into Claude Code. Write it as a REQUEST, not as
#              the manual command restated -- the point of this third option is
#              that it can look at the file and explain the difference first.
#    REMEDY    shell evaluated when the user says y. It MUST verify the machine
#              actually changed and return non-zero if it did not: this project
#              has been bitten before by a deploy layer that reported success it
#              never checked, and a "fixed." that fixed nothing is worse than a
#              warning, because the next run's report is the only thing that
#              would have caught it.
#    CLASS     "routine" (the default) or "userconfig". Only one finding in this
#              file is "userconfig" -- the one whose remedy edits config.conf,
#              the user's OWN file -- and it is marked so a front-end can give it
#              its own treatment WITHOUT keeping a list of ids. The terminal path
#              does not read this: it already says so in the headline and spends
#              its first paragraph on it.
#    NEEDSPW   1 if the remedy will ask for a sudo password, 0 (the default)
#              otherwise. Also for front-ends: a GUI has no terminal to type a
#              password into, so it must offer the manual command instead of a
#              button that would hang on an invisible prompt. It does not change
#              what the remedy does, and the terminal path ignores it.
#
#  A finding only belongs here if the repair is fully mechanical and reversible.
#  Anything needing a judgement call ("is this drift yours, or an update's?" is
#  a judgement call the WALKTHROUGH puts to the user, which is fine; "which of
#  your two audio profiles is the headphones one?" is not), a reboot, or a
#  decision about which of several right answers you want, stays a plain warn().
fixable() {
    printf '  %s[FIX!]%s %s\n' "$c_cyn" "$c_off" "$3"
    FIXES+=("$1${US}$2${US}$3${US}$4${US}$5${US}$6${US}$7${US}$8${US}${9:-routine}${US}${10:-0}")
    add_finding FIX "$1" "$3"
}

# Where every remedy that overwrites a file puts the old copy first. Same folder
# the patch scripts already back up into, so there is one place to look.
FIX_BACKUP_DIR="$HOME/.config/mango/backups"

# fix_backup FILE -> 0 and prints the backup path; 1 if it could not be made.
# A remedy that cannot back up must not proceed: "reversible" is the whole basis
# on which these are allowed to run at all.
fix_backup() {
    local f="$1" bk
    mkdir -p "$FIX_BACKUP_DIR" 2>/dev/null || { printf '    cannot create %s — nothing changed.\n' "$FIX_BACKUP_DIR"; return 1; }
    bk="$FIX_BACKUP_DIR/$(basename "$f").$(date +%Y%m%d-%H%M%S)"
    cp -a "$f" "$bk" 2>/dev/null || { printf '    could not back up %s — nothing changed.\n' "$f"; return 1; }
    printf '    your copy is saved at %s\n' "$bk"
}

# ---- remedies ---------------------------------------------------------------
# remedy_recopy SRC DST -- the "installed file is not the shipped file" repair.
# Backs DST up, then copies with -a so the executable bit comes from the repo
# copy rather than being invented here, then proves it with cmp.
remedy_recopy() {
    local src="$1" dst="$2"
    [ -f "$src" ] || { printf '    the repo copy has gone: %s\n' "$src"; return 1; }
    [ -e "$dst" ] && { fix_backup "$dst" || return 1; }
    mkdir -p "$(dirname "$dst")" 2>/dev/null || { printf '    cannot create %s\n' "$(dirname "$dst")"; return 1; }
    cp -a "$src" "$dst" 2>/dev/null || { printf '    the copy failed — %s is unchanged.\n' "$dst"; return 1; }
    cmp -s "$src" "$dst" || { printf '    the copy did not take — %s still differs.\n' "$dst"; return 1; }
    printf '    installed the shipped copy at %s\n' "$dst"
}

# remedy_recopy_dir SRCDIR DSTDIR -- install a whole DMS plugin directory from the
# clone, the way install.sh stage 14 deploys one (`cp -a "$pdir." "$tgt/"`). A
# plugin is deployed as a DIRECTORY, not as a list of named files, so this walks
# what the repo actually ships rather than carrying its own idea of the contents.
#
# Every file still goes through remedy_recopy, so each one is backed up if it is
# already there and each one is verified with cmp -- this adds the walk, nothing
# else. One file failing fails the WHOLE remedy: a part-copied plugin directory is
# precisely the state sections 7 and 13 exist to catch, and reporting it as "fixed"
# would hand the user a plugin that loads and comes up empty.
remedy_recopy_dir() {
    local src="$1" dst="$2" f rc=0 n=0
    [ -d "$src" ] || { printf '    the repo copy has gone: %s\n' "$src"; return 1; }
    mkdir -p "$dst" 2>/dev/null || { printf '    cannot create %s\n' "$dst"; return 1; }
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        remedy_recopy "$src/$f" "$dst/$f" || rc=1
        n=$((n+1))
    done < <(cd "$src" && find . -type f -printf '%P\n' 2>/dev/null | sort)
    if [ "$n" -eq 0 ] || [ "$rc" != 0 ]; then
        [ "$n" -eq 0 ] && printf '    %s holds no files to install.\n' "$src" \
                       || printf '    not every file arrived — the plugin is only part-installed.\n'
        # Take the directory back out if we made it and nothing landed in it. rmdir
        # refuses a non-empty directory, so this can only ever remove the empty shell
        # this function created -- never a plugin that was already there, and never a
        # partial copy, which the user needs to be able to see. Without it a failed
        # remedy leaves an empty plugins/<id>/ behind, and "nothing was changed" is
        # then not quite true.
        rmdir "$dst" 2>/dev/null
        return 1
    fi
    printf '    installed %d file(s) into %s\n' "$n" "$dst"
}

# repo_plugin_dir REPO ID -> the directory in the clone whose plugin.json declares
# ID, or nothing. Resolved rather than hardcoded because that is how install.sh
# stage 14 finds it too: it walks plugins/*/ and reads the id, so the folder name
# and the plugin id are deliberately allowed to differ (preset-switcher ->
# presetSwitcher). A hardcoded path here would be a second, drifting answer.
repo_plugin_dir() {
    local d
    for d in "$1"/plugins/*/; do
        [ -f "$d/plugin.json" ] || continue
        grep -q "\"id\"[[:space:]]*:[[:space:]]*\"$2\"" "$d/plugin.json" 2>/dev/null || continue
        printf '%s\n' "${d%/}"; return 0
    done
    return 1
}

# remedy_start_watcher SCRIPT LOCK -- start a background watcher the way
# config.conf's exec-once does. The lock test is the verification: without it
# this would report success for a watcher that started and immediately died.
remedy_start_watcher() {
    local sh="$1" lock="$2" i
    execu "$sh" || { printf '    %s is missing or not executable.\n' "$sh"; return 1; }
    setsid "$sh" >/dev/null 2>&1 &
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.5
        if have fuser && [ -n "$(fuser "$lock" 2>/dev/null)" ]; then
            printf '    started — it is holding %s\n' "$lock"
            return 0
        fi
    done
    printf '    it was started, but nothing holds %s five seconds later, so it\n' "$lock"
    printf '    did not stay up. Run it in a terminal to see why.\n'
    return 1
}

# remedy_restart_watcher PID SCRIPT LOCK -- replace a running watcher with the
# installed copy. Killed BY PID, never by name: killing on a name match has taken
# unrelated windows down on this machine before, and a watcher's name is generic.
remedy_restart_watcher() {
    local pid="$1" sh="$2" lock="$3"
    kill "$pid" 2>/dev/null
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        printf '    pid %s did not exit, so it was left alone and nothing changed.\n' "$pid"
        return 1
    fi
    printf '    stopped the old process (pid %s)\n' "$pid"
    remedy_start_watcher "$sh" "$lock"
}

# remedy_restore_binary BACKUP DST -- put a COMPILED binary back from a backup
# sitting beside it. Deliberately NOT remedy_recopy: that one repairs an installed
# file by copying the repo's copy over it, and the repo has no copy of this to
# give -- tools/ripe-chroma ships Rust source, and the binary only exists once
# something has built it. There is nothing to cmp against either, for the same
# reason.
#
# The last guard is the one that earns this a place in the registry. A backup can
# exist, copy cleanly and still be a binary built against libraries that have
# since moved underneath it -- exactly what section 12's own "won't run" check
# below exists to catch. Copying it back and calling that "fixed" would hand the
# user a file that satisfies every cheap test and still does nothing, which is the
# false success this file's remedies are written to refuse. So it is actually run.
#
# The backup is COPIED, not moved: if the restore turns out to be the wrong call
# the original is still sitting there to go back to.
remedy_restore_binary() {
    local bk="$1" dst="$2"
    [ -e "$bk" ] || { printf '    the backup has gone: %s\n' "$bk"; return 1; }
    [ -e "$dst" ] && { fix_backup "$dst" || return 1; }
    mkdir -p "$(dirname "$dst")" 2>/dev/null || { printf '    cannot create %s\n' "$(dirname "$dst")"; return 1; }
    cp -a "$bk" "$dst" 2>/dev/null || { printf '    the copy failed — %s is unchanged.\n' "$dst"; return 1; }
    chmod +x "$dst" 2>/dev/null
    execu "$dst" || { printf '    %s is in place but not executable — not fixed.\n' "$dst"; return 1; }
    "$dst" --help >/dev/null 2>&1 || {
        printf '    the backup copied into place but will not run — it was built against\n'
        printf '    system libraries that have since moved. NOT fixed, and reported as\n'
        printf '    failed rather than repaired.\n'
        printf '    The restored copy is left at %s on purpose: the next run of this\n' "$dst"
        printf '    check will now say "Ripe Chroma will not run" instead of "gone", which\n'
        printf '    is the truer finding and carries the rebuild steps you actually need.\n'
        return 1
    }
    printf '    restored %s from %s, and it runs.\n' "$dst" "$bk"
}

# remedy_patch ID RESTART -- hand the repair to apply-patches.sh, which owns every
# patch's backup, its sudo write and its marker. Nothing about HOW a patch is
# applied is duplicated here; naming the id is the documented way to apply one,
# and afterwards we ask the dispatcher again rather than assuming it worked.
remedy_patch() {
    local id="$1" st
    "$PATCH_DISPATCH" "$id" || { printf '    the patch script reported a failure — see its output above.\n'; return 1; }
    st="$("$PATCH_DISPATCH" status --porcelain 2>/dev/null | awk -F'\t' -v i="$id" '$1==i{print $2}')"
    [ "$st" = ok ] || { printf '    the dispatcher still calls this patch "%s" — not fixed.\n' "${st:-unknown}"; return 1; }
    printf '    the dispatcher now reports this patch as applied and current.\n'
    printf '    Restart the shell to start using it:  %s\n' "$2"
}

# remedy_drop_binds_source FILE -- delete the source line(s) for DMS's managed
# binds.conf. The line is re-matched HERE rather than trusting the line number
# the scan found: this edits the user's own config.conf, and a file that changed
# between the scan and this prompt must not have the wrong line cut out of it.
BINDS_SRC_RE='^[[:space:]]*source(-optional)?[[:space:]]*=[[:space:]]*[^#]*binds\.conf'
remedy_drop_binds_source() {
    local f="$1" bk n
    n="$(grep -cE "$BINDS_SRC_RE" "$f" 2>/dev/null)" || n=0
    [ "${n:-0}" -gt 0 ] || { printf '    that line is no longer in %s — nothing to do.\n' "$f"; return 1; }
    bk="$FIX_BACKUP_DIR/$(basename "$f").$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$FIX_BACKUP_DIR" 2>/dev/null || { printf '    cannot create %s — nothing changed.\n' "$FIX_BACKUP_DIR"; return 1; }
    cp -a "$f" "$bk" 2>/dev/null || { printf '    could not back up %s — nothing changed.\n' "$f"; return 1; }
    printf '    your copy is saved at %s\n' "$bk"
    sed -i -E "/$BINDS_SRC_RE/d" "$f" 2>/dev/null || {
        printf '    the edit failed. Put your copy back with:  cp %s %s\n' "$bk" "$f"; return 1; }
    if grep -qE "$BINDS_SRC_RE" "$f" 2>/dev/null; then
        printf '    the line is still there. Put your copy back with:  cp %s %s\n' "$bk" "$f"
        return 1
    fi
    printf '    removed %s line(s) from %s\n' "$n" "$f"
    printf '    Press SUPER+SHIFT+r to reload MangoWM so the change takes effect.\n'
}

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
# Persist current versions for next time -- BUT ONLY ON A REPORT RUN. "Which
# version changed since you last looked?" is a question about the last time a
# PERSON looked. The hub re-scans every time its section is opened, and if those
# runs moved the baseline they would quietly eat the answer: you would update
# mango, open the hub, close it, and the next terminal run would tell you nothing
# had changed. --json and --apply-fix therefore read this file and never write it.
if [ "$HEALTH_MODE" = report ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null
    printf 'mango=%s\ndms=%s\nqs=%s\n' "$mango_ver" "$dms_ver" "$qs_ver" > "$STATE_FILE" 2>/dev/null
fi

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
        fixable monitor-watcher-not-running warn \
            "monitor hotplug watcher is NOT running (autostarts on next login)" \
"The small background helper that notices monitors being plugged in and
unplugged is not running. Nothing is broken while your monitors stay as
they are. But plug one in now and it gets no per-monitor layout rules --
windows land on it under plain tiling, and re-running the rule generator
by hand to fix that resets every OTHER monitor to tile as well." \
"Start that same helper in the background, exactly the way config.conf
starts it for you at login. It writes nothing to disk and changes no
settings, so it undoes itself: kill it, or just log out and back in." \
"setsid '$MONITOR_WATCHER' >/dev/null 2>&1 & disown" \
"The monitor hotplug watcher isn't running. Start
$MONITOR_WATCHER in the background the way
config.conf's exec-once line does, then confirm it is actually holding
$MONITOR_WATCHER_LOCK rather than having exited." \
"remedy_start_watcher '$MONITOR_WATCHER' '$MONITOR_WATCHER_LOCK'"
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
            # The one state this section can put right on the spot. It stays
            # fail-severity: a wiped patch is a real regression, and skipping the
            # offer must leave the exit code exactly where a plain fail() left it.
            # The repair is handed straight to the dispatcher by id -- naming a
            # patch IS the documented opt-in, and it already owns the backup, the
            # sudo write, the marker and the re-check.
            fixable "patch:$p_id" fail \
                "$p_title — the $p_pkg package overwrote the file this patches, so the change is gone" \
"$(wrap 72 0 "DankMango $p_blurb. It does that by editing a file the $p_pkg package itself owns, so every $p_pkg update replaces the file wholesale and takes the change with it.")

This is the expected consequence of a $p_pkg update, not damage. Nothing
else on your system is affected -- you have simply lost what this patch
added back until it is re-applied.

The file:  $p_target" \
"$(wrap 72 0 "Run the patch dispatcher for this one patch. It copies $p_target to a dated backup first, re-applies the edit, and then checks the marker it leaves behind is really in the file before calling it done.")

It will ask for your password. That is because the file belongs to $p_pkg
rather than to you; nothing appears on screen while you type. Afterwards
you still need to restart the shell yourself with '$p_restart' -- the
running shell keeps the old file open until then." \
"$PATCH_DISPATCH $p_id
$p_restart" \
"$(wrap 72 0 "A $p_pkg update wiped DankMango's \"$p_title\". Re-apply it with ~/.config/mango/scripts/apply-patches.sh $p_id, show me what the patch actually changes in $p_target before you run it, and tell me afterwards how to check it worked.")" \
"remedy_patch '$p_id' '$p_restart'" \
                routine 1
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
        fixable border-watcher-not-running warn \
            "wallpaper-border watcher is NOT running (autostarts on next login)" \
"The helper that watches for wallpaper changes is not running, so your
window borders and app colours have stopped following your wallpaper.
They are not wrong -- they are just frozen on whatever they were when the
watcher stopped, and they will stay there until it is running again." \
"Start that same helper in the background, exactly the way config.conf
starts it for you at login. It writes nothing to disk and changes no
settings. Note that it starts by taking a reading of where things are NOW
and then waits for the NEXT wallpaper change, so it will not backfill the
colours on its own -- change your wallpaper once afterwards." \
"setsid '$BORDER_WATCHER' >/dev/null 2>&1 & disown" \
"The wallpaper-border reload watcher isn't running. Start
$BORDER_WATCHER in the background the way
config.conf's exec-once line does, confirm it is holding
$BORDER_LOCK, and remind me that it only reacts to the
next wallpaper change." \
"remedy_start_watcher '$BORDER_WATCHER' '$BORDER_LOCK'"
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
# 4b. GTK3 LIVE THEME REFRESH (Nemo & friends recolouring without a restart)
# =============================================================================
# GTK3 reads ~/.config/gtk-3.0/gtk.css once per process and never re-reads it,
# so colours imported THERE go stale until the app is restarted. A named theme
# IS re-read whenever gtk-theme changes -- which DMS does on every wallpaper
# change -- so DankMango puts the palette in generated shadow themes under
# ~/.local/share/themes/adw-gtk3{,-dark}/ instead.
#
# Two things break this, both silently, and both are things DMS itself does:
#   1. "Apply GTK Colors" in DMS Settings -> Theme runs DMS's gtk.sh, which
#      re-symlinks ~/.config/gtk-3.0/gtk.css -> dank-colors.css. The user
#      stylesheet outranks the theme, so that stale copy shadows the fresh
#      theme colours and the live refresh stops working.
#   2. DMS only calls refreshGTK() at all when isDMSGTKActive() is true, and
#      that function tests for the string "dank-colors.css" inside
#      ~/.config/gtk-4.0/gtk.css. Lose that GTK4 import and the theme flip
#      never fires, so nothing reloads.
section "4b. GTK apps following the wallpaper live"

gtk3_shadow_n=0
for _t in adw-gtk3 adw-gtk3-dark; do
    for _l in gtk.css gtk-dark.css; do
        _f="$HOME/.local/share/themes/$_t/gtk-3.0/$_l"
        [ -f "$_f" ] && grep -q "$GTK3_SHADOW_MARK" "$_f" && gtk3_shadow_n=$((gtk3_shadow_n+1))
    done
done
if [ "$gtk3_shadow_n" -eq 4 ]; then
    pass "GTK3 live-theme shadows present (4/4)"
elif [ "$gtk3_shadow_n" -gt 0 ]; then
    warn "only $gtk3_shadow_n of 4 GTK3 live-theme shadow files present" \
         "Re-run install.sh from your DankMango clone to regenerate them."
else
    fail "GTK3 live-theme shadows missing" \
         "GTK3 apps (Nemo) will keep their old colours until you restart them" \
         "$HOME/.local/share/themes/adw-gtk3{,-dark}/gtk-3.0/" \
         "Re-run install.sh (stage 9b regenerates them from config/gtk-3.0/live-theme/)" \
"Nemo and other GTK apps no longer change colour when you change your
wallpaper - they only catch up when you close and reopen them.
Nothing is damaged; this is only how they look.

1. Open the folder you cloned DankMango into (the one with install.sh in
   it) in a terminal (Super+Return), then type:
     ./install.sh
   (install.sh re-creates the four small theme files that make this work.
   Re-running it is safe - it backs up anything it replaces.)

2. Change your wallpaper once from the DankMaterialShell settings (the
   gear icon on the bar) and watch a Nemo window. It should recolour
   within about a second.

3. Any Nemo window that was ALREADY open before step 1 needs closing and
   reopening once. After that one restart it follows the wallpaper live."
fi

# The user stylesheet must NOT carry the palette, or it shadows the theme.
if [ -L "$GTK3_USER_CSS" ]; then
    fail "~/.config/gtk-3.0/gtk.css is a symlink (DMS gtk.sh reset it)" \
         "the stale palette now outranks the live theme -- GTK3 colours are frozen until restart" \
         "$GTK3_USER_CSS -> $(readlink "$GTK3_USER_CSS")" \
         "Re-run install.sh; it removes the symlink and restores the layer file" \
"Something (usually the \"Apply GTK Colors\" button in the DankMaterialShell
theme settings) replaced one of DankMango's files with a shortcut to
another file. That undoes the live wallpaper colouring for GTK apps, and
it also drops the see-through Nemo window effect.

1. Re-run the installer. In the folder you cloned DankMango into:
     ./install.sh

2. Avoid pressing \"Apply GTK Colors\" in the DankMaterialShell theme
   settings from now on - DankMango already applies those colours, and
   that button overwrites the file every time."
elif [ -f "$GTK3_USER_CSS" ] && grep -qE '^[[:space:]]*@import[^;]*dank-colors\.css' "$GTK3_USER_CSS"; then
    fail "~/.config/gtk-3.0/gtk.css imports dank-colors.css" \
         "the user stylesheet outranks the theme, so GTK3 colours freeze until each app restarts" \
         "$GTK3_USER_CSS" \
         "Remove that @import line (install.sh ships the correct version)" \
"GTK apps have stopped following your wallpaper colours live.

1. Re-run the installer from the folder you cloned DankMango into:
     ./install.sh
   (It ships the correct version of this file.)

2. If you edited that file yourself, open it:
     nano $GTK3_USER_CSS
   and delete the line that reads:
     @import url(\"dank-colors.css\");
   Save with Ctrl+O then Enter, quit with Ctrl+X. Leave the
   nemo-transparency.css line alone - that one belongs there."
elif [ -f "$GTK3_USER_CSS" ]; then
    pass "user stylesheet is clean (no palette import shadowing the theme)"
fi

# DMS only fires its theme flip when it sees this import.
if [ -f "$HOME/.config/gtk-4.0/gtk.css" ] && grep -qE '^[[:space:]]*@import[^;]*dank-colors\.css' "$HOME/.config/gtk-4.0/gtk.css"; then
    pass "DMS refreshGTK() trigger intact (gtk-4.0/gtk.css imports dank-colors.css)"
else
    fail "gtk-4.0/gtk.css no longer imports dank-colors.css" \
         "DMS's isDMSGTKActive() check fails, so it never flips gtk-theme -- nothing reloads" \
         "$HOME/.config/gtk-4.0/gtk.css" \
         "Re-run install.sh (stage 9 ships this file)" \
"The part of DankMaterialShell that tells apps \"the colours changed\" has
stopped running, because it looks for one specific line in a file and
that line is gone.

1. Re-run the installer from the folder you cloned DankMango into:
     ./install.sh

2. Then change your wallpaper once and check that a Nemo window
   recolours. If it does, this is fixed."
fi

# The palette itself.
if [ -f "$GTK3_PALETTE" ] && grep -q '@define-color' "$GTK3_PALETTE"; then
    pass "matugen GTK palette present ($(basename "$GTK3_PALETTE"))"
else
    warn "$GTK3_PALETTE missing or has no colours" \
         "Set your wallpaper once from the DMS settings — DMS regenerates it."
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
                # ONE FINDING PER DRIFTED FILE, for the reason section 9 spells out:
                # "you edited it" and "an update missed it" look identical from here,
                # and only you can tell them apart -- per file, not per plugin.
                #
                # Both sides are known to exist at this point: the branch above
                # established every FRP_FILES entry is present, and the clone's
                # plugin folder is present. If the repo has since stopped shipping
                # one of them, remedy_recopy refuses and says so rather than
                # inventing a source.
                for frp_f in $frp_drift; do
                    fixable "firstrun-drift:$frp_f" warn \
                        "welcome panel: $frp_f differs from the shipped copy — stale, unless you edited it yourself" \
"The installed copy of this file is not the one the repo ships:
    installed  $FRP_DIR/$frp_f
    shipped    $frp_repo/$FRP_REPO_SUBDIR/$frp_f

That is either an edit you made, or an update that went missing. Only the
welcome panel is affected either way -- it is the small panel a brand new
install shows once, so a stale copy costs you nothing until the next
fresh install." \
"Save your copy under a dated name in:
    $FIX_BACKUP_DIR
then put the repo's version in its place. Your copy is never deleted, so
this is undoable with a single 'cp' back.

Unlike the plain scripts in section 9, this is a file DankMaterialShell
loads at startup, so run 'dms restart' afterwards for the shell to pick
it up.

If you know you edited this file on purpose, say no." \
"cp -a '$FRP_DIR/$frp_f' '$FIX_BACKUP_DIR/'
cp -a '$frp_repo/$FRP_REPO_SUBDIR/$frp_f' '$FRP_DIR/$frp_f'
dms restart" \
"Diff these two files and show me what actually differs:
    mine  $FRP_DIR/$frp_f
    repo  $frp_repo/$FRP_REPO_SUBDIR/$frp_f
This is DankMango's first-run welcome panel. I want to tell whether it is
an edit I made or an update that went missing. If it looks like the
latter, back my copy up, replace it with the repo's, and remind me to
restart the shell." \
"remedy_recopy '$frp_repo/$FRP_REPO_SUBDIR/$frp_f' '$FRP_DIR/$frp_f'"
                done
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
        # ONE FINDING PER FILE, deliberately, where the old code printed one
        # warning listing them all. These are not one decision: the stale ones in
        # particular may include a file you edited on purpose, and the only person
        # who can tell that apart from an update that went missing is you. A single
        # yes/no over the whole list would force you to answer for the whole list.
        for rel in "${dm_missing[@]}"; do
            fixable "file-missing:$rel" warn \
                "$rel is not installed at all — the repo ships it, this machine doesn't have it" \
"This file is missing:
    $HOME/.config/mango/$rel
The DankMango repo on this machine ships it, so either something removed
it or an install never put it there.

Whatever that file does is simply not happening. If it is a script that
something else calls -- a keybind, a watcher, another script -- that
caller fails silently, because nothing on the system announces a missing
script." \
"Copy it in from your DankMango clone, creating any folder it needs:
    from  $dm_repo/config/mango/$rel
    to    $HOME/.config/mango/$rel
It is copied with 'cp -a', so it arrives with the runnable flag the repo
gives it rather than one invented here. Nothing is overwritten -- there
is nothing there to overwrite." \
"cp -a '$dm_repo/config/mango/$rel' '$HOME/.config/mango/$rel'" \
"This file is missing:
    $HOME/.config/mango/$rel
but my DankMango clone ships it at:
    $dm_repo/config/mango/$rel
Show me what that file does, then copy it into place with its executable
bit intact, and tell me whether anything needs restarting to pick it up." \
"remedy_recopy '$dm_repo/config/mango/$rel' '$HOME/.config/mango/$rel'"
        done
        for rel in "${dm_stale[@]}"; do
            fixable "file-stale:$rel" warn \
                "$rel differs from the shipped copy — stale, unless you edited it yourself" \
"The installed copy of this file is not the one the repo ships:
    installed  $HOME/.config/mango/$rel
    shipped    $dm_repo/config/mango/$rel

There are exactly two reasons for that, and this check cannot tell them
apart. Either you edited it yourself -- in which case nothing is wrong and
you should skip this -- or an update missed it. A missed file never heals
on its own: update.sh only re-copies what changed between your last
recorded commit and the newest one, so once a file drops out of that
window, no later update ever looks at it again." \
"Save your copy under a dated name in:
    $FIX_BACKUP_DIR
then put the repo's version in its place. Your copy is never deleted, so
this is undoable with a single 'cp' back.

If you know you edited this file on purpose, say no." \
"cp -a '$HOME/.config/mango/$rel' '$FIX_BACKUP_DIR/'
cp -a '$dm_repo/config/mango/$rel' '$HOME/.config/mango/$rel'" \
"Diff these two files and show me what actually differs:
    mine  $HOME/.config/mango/$rel
    repo  $dm_repo/config/mango/$rel
I want to tell whether it is an edit I made or an update that went
missing. If it looks like the latter, back my copy up and replace it
with the repo's." \
"remedy_recopy '$dm_repo/config/mango/$rel' '$HOME/.config/mango/$rel'"
        done
    fi
fi

# =============================================================================
# 9b. Leftovers from earlier DankMango versions
# =============================================================================
# Section 9 answers "is what's installed the same as what the repo ships?" for the
# files that ARE still shipped. This is the other half: files DankMango installed and
# then STOPPED shipping, which nothing on the machine will ever remove on its own.
#
# WHY THEY SURVIVE. Only update.sh can retire a file, and only for a deletion inside
# its LAST..HEAD range. install.sh has no deletion path at all, but it does advance
# lastAppliedCommit -- so an install.sh re-run eats the window in which the deletion
# lived, and after that the file is invisible to every future run. The dev box has two
# of these (dp2-floatsize.sh, set-monitor-mode.sh) from exactly that sequence.
#
# REPORT ONLY, ALWAYS. This is a health check; it does not remove anything, and the
# note is a [ -- ] rather than a warning, because a leftover is usually inert. Removal
# lives in install.sh's stage 17b, which asks first and backs up what it takes.
#
# THE CHECK ITSELF LIVES IN lib/common.sh, and is sourced in a SUBSHELL rather than
# copied down here. Normally this script hardcodes its own copies (it ships standalone
# and must run with no clone present), but route_dest is a 90-line routing table --
# a second copy of it would drift, and a drifted routing table would report files as
# orphans that are simply installed somewhere else. The subshell is what makes sourcing
# safe: common.sh defines its own have/warn/ok, and they must not replace this script's.
section "9b. Leftovers from earlier DankMango versions"
if [ -z "$dm_repo" ] || [ ! -d "$dm_repo/.git" ]; then
    note "no DankMango clone with its git history here — can't tell shipped files from leftovers"
elif ! have git || ! have jq; then
    note "needs git and jq to check for leftover files — skipping"
elif [ ! -f "$dm_repo/lib/common.sh" ]; then
    note "$dm_repo/lib/common.sh is missing — can't check for leftover files"
else
    # THE RETURN CODE IS THE ANSWER, NOT THE EMPTY OUTPUT. Empty output has three
    # different meanings — nothing left over, the check refused to run, or this clone
    # predates manifest_orphans entirely (127, command not found) — and treating them
    # all as "clean" would print a green PASS for a check that never ran. That is the
    # exact shape of the bug this whole section exists because of, so: 0 = orphans
    # listed, 1 = genuinely clean, anything else = could not answer.
    dm_orph_rc=0
    dm_orphans="$( ( REPO_DIR="$dm_repo"; . "$dm_repo/lib/common.sh"; manifest_orphans ) 2>/dev/null )" \
        || dm_orph_rc=$?
    if [ "$dm_orph_rc" = 1 ]; then
        pass "nothing left over — every DankMango file here is still part of DankMango"
    elif [ "$dm_orph_rc" != 0 ] || [ -z "$dm_orphans" ]; then
        note "couldn't check for leftover files (clone too old, or no git history) — nothing is wrong here"
    else
        dm_orph_n="$(printf '%s\n' "$dm_orphans" | grep -c .)"
        note "$dm_orph_n leftover file(s)/folder(s) from an earlier version:"
        printf '%s\n' "$dm_orphans" | while IFS=$'\t' read -r dm_o_path dm_o_scope dm_o_what; do
            [ -n "$dm_o_path" ] || continue
            printf '         %s%s\n' "$dm_o_path" \
                "$( [ "$dm_o_what" = tree ] && printf ' (whole folder)' )"
        done
        printf '         %s\n' "Harmless in themselves. To clear them, run the installer and answer" \
                               "the \"leftovers\" question near the end (it backs up what it removes):" \
                               "    cd $dm_repo && ./install.sh"
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
        # NOT the same shape as section 9's per-file recopy, despite looking like it.
        # A DMS plugin is deployed as a whole DIRECTORY (install.sh stage 14 does
        # `cp -a "$pdir." "$tgt/"`), and the folder it comes from is found by reading
        # the id out of each plugins/*/plugin.json -- the folder name and the plugin
        # id differ on purpose here (preset-switcher -> presetSwitcher). So this is
        # one finding covering one directory, resolved the way install.sh resolves it.
        #
        # Gated on a reachable clone, like every other "put the shipped copy back"
        # finding: with no clone there is nothing to copy from, and the original
        # advice (re-run install.sh) is still the right answer.
        preset_repo_dir=""
        [ -n "${dm_repo:-}" ] && preset_repo_dir="$(repo_plugin_dir "$dm_repo" "$PRESET_ID")"
        if [ -n "$preset_repo_dir" ]; then
            fixable preset-plugin-missing warn \
                "the Presets launcher plugin isn't installed at $PRESET_PLUGIN_DIR" \
"The plugin that lets you switch desktop presets from the launcher is not
installed:
    expected  $PRESET_PLUGIN_DIR
    shipped   $preset_repo_dir

Nothing is damaged and you have not lost any presets. They still work
from the terminal:
    $PRESET_SETTER --list
What is missing is the way in from the launcher -- typing 'preset' there
finds nothing, because DMS has no such plugin to offer." \
"Copy in every file the repo ships in that folder, the same way install.sh
stage 14 deploys a plugin:
    from  $preset_repo_dir
    to    $PRESET_PLUGIN_DIR
Anything already there is backed up under a dated name in
$FIX_BACKUP_DIR first, and every file is checked after it lands -- a
partly-copied plugin is reported as a failure, not as a fix.

Then restart the shell with 'dms restart' so DMS loads it.

One thing this does NOT do: register the plugin with DMS. If section 10
of the scan above also says the Presets plugin is missing from
plugin_settings.json, that is a separate step and this will not settle
it." \
"cp -a '$preset_repo_dir/.' '$PRESET_PLUGIN_DIR/'
dms restart" \
"The Presets launcher plugin isn't installed. My DankMango clone ships it
at:
    $preset_repo_dir
Copy it into $PRESET_PLUGIN_DIR the way
install.sh stage 14 deploys a plugin, check it is registered and enabled
in ~/.config/DankMaterialShell/plugin_settings.json, and tell me what to
restart." \
"remedy_recopy_dir '$preset_repo_dir' '$PRESET_PLUGIN_DIR'"
        else
            warn "the Presets launcher plugin isn't installed at $PRESET_PLUGIN_DIR" \
                 "Presets still work from the terminal ($PRESET_SETTER --list). To get them in the launcher, re-run ./install.sh from your DankMango folder, then 'dms restart'."
        fi
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
# One regex, defined next to remedy_drop_binds_source: the line this FINDS and the
# line that remedy DELETES must never be able to drift apart.
hb_src_line="$(grep -nE "$BINDS_SRC_RE" "$hb_conf" 2>/dev/null | head -1)"

if [ -z "$hb_src_line" ]; then
    pass "config.conf does not source DMS's binds.conf"
else
    # Fixable, and fail-severity: the repair is one line deleted from one file,
    # matched by the same regex that found it and backed up before the edit, so
    # it is as mechanical and as undoable as a repair gets. Severity does not
    # move -- skip it and this still exits non-zero, exactly as it did as a fail().
    # This is the only remedy in this script that writes to config.conf, which is
    # the user's own file; that is why the walkthrough spells out what the line is
    # and what deleting it costs (nothing) before it asks.
    # THE ONE REMEDY IN THIS SCRIPT THAT EDITS config.conf. Every other fix works on
    # a file DankMango owns outright -- a script recopied from the clone, a plugin
    # directory, a patch on a package file, a watcher process. config.conf is the
    # opposite: the guide actively tells people to edit it (bar position, gaps,
    # binds), and section 9 deliberately refuses to compare it for that reason.
    #
    # So the finding is marked in the SCAN LINE ITSELF, not only in the walkthrough.
    # Someone skimming a report full of [FIX!] lines has to be able to see that this
    # one is a different kind of thing without reading any further. The marker is in
    # the headline text; the tag stays [FIX!] like every other fixable finding.
    #
    # What is NOT added here is a second confirmation. One clear yes/no is the rule
    # for this whole feature, and a fix nobody understands is not made safer by
    # asking twice -- it is made safer by saying what it does, which is what the
    # walkthrough below spends its first paragraph on.
    fixable binds-source-line fail \
        "${c_yel}⚠ EDITS YOUR config.conf${c_off} — a source line for DMS's binds.conf is back (line ${hb_src_line%%:*}): DMS can inject ~90 stock binds" \
"READ THIS ONE FIRST. Of every fix this report offers, this is the only
one that changes config.conf — MangoWM's own settings file, the file
DankMango's guide tells you to edit by hand. Everything else on this list
works on files DankMango owns and rewrites freely. This one does not, so
it is worth a moment even though the change itself is a single deleted
line.

A line has come back into that file that lets DankMaterialShell add its
own keyboard shortcuts to yours:

    ${hb_src_line#*:}

That is almost certainly not something you typed. Running \"dms setup
binds\" puts this line back automatically, and the dms binary carries the
literal text for it.

Nothing is wrong this second. The risk is the NEXT time the desktop
reloads: DMS's own set of shortcuts, about ninety of them, gets pulled in
alongside yours. Where you and DMS both use a key, yours still wins.
Where you DON'T use a key, DMS's version simply appears -- so keys start
doing things you never set up." \
"Delete just the line(s) that source binds.conf, and nothing else.

Two things guard that, both already in place:

  * Your whole config.conf is copied to $FIX_BACKUP_DIR
    under a dated name BEFORE the edit. If any of this turns out wrong,
    one 'cp' back and you have your file exactly as it is now.
  * The line is searched for again at the moment you say yes, not taken
    from the line number printed above. If you edit config.conf between
    reading this and answering, the wrong line cannot be cut out — and
    if the line has gone by then, nothing is changed at all.

Everything else in the file is left untouched, including every comment
and every bind you have added.

You lose nothing by deleting it: every shortcut DankMango gives you is
written in this same file, further up. That line only ever added DMS's
extras on top.

Afterwards, press SUPER+SHIFT+r to reload MangoWM." \
"cp -a '$hb_conf' '$FIX_BACKUP_DIR/'
sed -i -E '/$BINDS_SRC_RE/d' '$hb_conf'
# then press SUPER+SHIFT+r" \
"Something has re-added a 'source = ./dms/binds.conf' line to
$hb_conf, which lets DMS inject its own keybinds
into mine. Show me the line, back the file up, and remove just that line
-- leave everything else alone." \
"remedy_drop_binds_source '$hb_conf'" \
        userconfig 0
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
        # Fixable only when the clone is reachable -- the repair IS the shipped
        # file, and there is nothing to copy from without it. No clone: the
        # original warning, unchanged. ($dm_repo is set by section 9 above.)
        if [ -n "$dm_repo" ] && [ -f "$dm_repo/config/dms/binds.conf" ]; then
            fixable binds-regenerated warn \
                "DMS regenerated dms/binds.conf ($hb_n bind lines) — inert today, because nothing sources it" \
"DankMaterialShell has rewritten $hb_binds with $hb_n of its own keybinds
in it. It does that whenever you run 'dms keybinds set', 'dms keybinds
remove' or 'dms setup binds' -- those commands regenerate the whole file
from DMS's defaults rather than editing a line.

Right now this costs you nothing: config.conf does not source that file,
so nothing reads it. It matters because the OTHER half of this guard --
a source line coming back into config.conf -- would turn these $hb_n
lines live at the next reload. The shipped version of this file is empty
precisely so that there is nothing to go live." \
"Save your copy into $FIX_BACKUP_DIR under a dated name, then put the
shipped file back from $dm_repo/config/dms/binds.conf. The shipped file
declares no binds at all -- it is comments explaining why it is empty.

This does NOT add a source line to config.conf, and you should not add
one either: that is the thing this guard exists to catch." \
"cp -a '$hb_binds' '$FIX_BACKUP_DIR/'
cp -a '$dm_repo/config/dms/binds.conf' '$hb_binds'" \
"DMS has regenerated $hb_binds with $hb_n of its
own keybinds. Back it up and restore the deliberately-empty version
DankMango ships at $dm_repo/config/dms/binds.conf,
and confirm nothing in config.conf sources that path." \
"remedy_recopy '$dm_repo/config/dms/binds.conf' '$hb_binds'"
        else
            warn "DMS regenerated dms/binds.conf ($hb_n bind lines) — nothing sources it, so it is inert, but the file has drifted" \
                 "Put the empty shipped copy back: run ./install.sh from your DankMango folder. Do NOT re-add a source line for it in config.conf."
        fi
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

# DID THIS MACHINE EVER HAVE IT? A missing binary means two opposite things and
# the file system cannot tell them apart: someone declined an opt-in (healthy), or
# someone accepted it and the binary has since gone (a fault). The manifest is the
# only thing that knows. install.sh stage 13b records a user-file-installed change
# keyed on this exact path once the copy has succeeded, and nothing else ever
# writes that key -- so its presence is the whole test.
#
# Absent manifest, or no jq: RC_RECORDED stays 0 and the old benign note is what
# gets printed. Guessing "fault" from missing evidence would nag every machine
# that legitimately said no.
RC_RECORDED=0
if [ -r "$DANKMANGO_MANIFEST" ] && have jq; then
    jq -e --arg p "$RC_BIN" \
       '[.systemChanges[]? | select(.type == "user-file-installed" and .key == $p)] | length > 0' \
       "$DANKMANGO_MANIFEST" >/dev/null 2>&1 && RC_RECORDED=1
fi

# The newest DankMango-shaped backup beside the binary, if there is one. The glob
# is the strict .bak-YYYYmmdd-HHMMSS form that lib/common.sh's prune_file_backups
# matches, for the same reason it is strict there: a hand-labelled file next door
# (.bak-old, .bak-mine) is somebody's own and must not be restored over anything
# on their behalf. Sorted, so the last one is the most recent stamp.
RC_BAK=""
for _b in "$RC_BIN".bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]; do
    [ -e "$_b" ] && RC_BAK="$_b"
done
unset _b

if [ ! -e "$RC_BIN" ] && [ "$RC_RECORDED" = 0 ]; then
    # OPT-OUT IS NOT A PROBLEM. The engine is an opt-in extra (install.sh stage
    # 13b) and everything downstream is guarded on the binary existing, so a
    # machine without it is fully healthy. Say so as a note and move on rather
    # than nagging someone about a feature they deliberately declined.
    note "Ripe Chroma not installed — optional, and nothing depends on it (install.sh stage 13b offers it)"
elif [ ! -e "$RC_BIN" ] && [ -n "$RC_BAK" ]; then
    # Installed once, gone now, and a backup of it is lying beside the hole. This
    # is the shape the Sep 2026 investigation actually found on a live machine.
    fixable ripe-chroma-binary-lost fail \
        "Ripe Chroma was installed but the binary has gone — a backup of it is sitting beside it" \
"Ripe Chroma is recorded as installed on this machine:
    $DANKMANGO_MANIFEST says install.sh stage 13b put it at
    $RC_BIN
but there is nothing at that path now. A backup of it is still there:
    $RC_BAK

Nothing removed it on DankMango's behalf -- no install or update path in
the repo writes to that folder except the one line that installs it -- so
it was moved aside from outside, by hand or by something else.

The effect is silent. Every caller of the engine (the wallpaper fan-out,
the control hub's Ripe Chroma section) is guarded on the binary existing,
so they all just quietly stop doing anything. Your DMS theme keeps
reporting a custom palette the whole time, because that palette is a JSON
file that outlives the thing that wrote it -- so nothing anywhere tells
you the colour engine stopped running." \
"Copy the backup back over the missing binary, put its execute bit back,
then RUN it. That last step is the point: a copy that lands cleanly can
still be a binary whose system libraries moved under it, and this check
would rather tell you the restore failed than call it fixed. Your existing
copy, if there somehow is one, is saved first. The backup is copied, not
moved, so it stays where it is either way." \
"cp -a '$RC_BAK' '$RC_BIN' && chmod +x '$RC_BIN' && '$RC_BIN' --help" \
"Ripe Chroma is recorded as installed in my DankMango manifest at:
    $RC_BIN
but the binary is missing and there is a backup of it at:
    $RC_BAK
Check whether that backup is a working build, restore it if it is, and
tell me what would have moved the original aside." \
"remedy_restore_binary '$RC_BAK' '$RC_BIN'"
elif [ ! -e "$RC_BIN" ]; then
    # Installed once, gone now, and nothing to restore from. Rebuilding needs the
    # clone, the Rust toolchain and a few minutes that can fail -- nothing like
    # the mechanical, reversible repair the [FIX!] registry is for, so this stays
    # a plain fail with the commands to run.
    fail "Ripe Chroma was installed but the binary has gone" \
         "$DANKMANGO_MANIFEST records it at $RC_BIN; nothing is there now, and there is no .bak-* beside it to restore" \
         "$RC_BIN" \
         "Nothing in the repo removes this path, so it went from outside. Rebuilding is the only way back without a backup." \
"Ripe Chroma is recorded as installed on this machine, but its binary is gone
and there is no backup beside it to put back.

Everything that uses it is guarded on the file existing, so it has been
failing silently -- and DMS keeps reporting your custom palette either way,
because that palette file outlives the engine that wrote it.

Rebuilding it is the fix:

1. Go to the folder you cloned DankMango into (the one with install.sh in it):
     cd ~/DankMango

2. Re-run the installer and say yes when it asks:
     ./install.sh
   at the question 'Build Ripe Chroma and make it your active theme?'

   Or build it by hand, which does the same thing:
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
            fixable border-watcher-stale-code warn \
                "the RUNNING wallpaper watcher (pid $rc_pid) is executing OLD code — $rc_why" \
"$(wrap 72 0 "The wallpaper watcher is running, but the copy of it living in memory is not the copy on disk: $rc_why.")

A running script does not notice edits to its own file, so an update that
rewrote this one left the old version still going. The file on disk is
correct, which is why every other check here passes -- the only symptom is
that changing your wallpaper quietly stops changing your colours." \
"Stop that process by its process id (pid $rc_pid) and start the current
$(basename "$BORDER_WATCHER") in its place. Nothing on disk is touched.
Afterwards you still need to open the control hub (SUPER+d) and press
Generate in the Ripe Chroma section: a freshly started watcher takes its
reading and then waits for the NEXT wallpaper change, so it will not
catch up the palette by itself." \
"kill $rc_pid; sleep 1; setsid '$BORDER_WATCHER' >/dev/null 2>&1 & disown" \
"The wallpaper watcher running as pid $rc_pid is executing an out-of-date
copy of $BORDER_WATCHER. Check what
/proc/$rc_pid/fd/255 points at to confirm, then stop that pid and start
the installed copy in its place -- kill it by pid, not by name." \
"remedy_restart_watcher '$rc_pid' '$BORDER_WATCHER' '$BORDER_LOCK'"
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
        # DMS is not displaying the palette. Two VERY different situations land
        # here and they used to be reported as the same one.
        #
        # THIS IS THE GAP THAT LET A GENUINELY BROKEN INSTALL REPORT CLEAN. The
        # note below claims "the palette is generated but not displayed" -- and
        # until this check existed, nothing had established the "generated" half.
        # Every test of the palette file (does it exist, does it parse, is it
        # current) lives further down this if/elif chain, PAST this arm, and is
        # reached only when DMS is ALREADY pointed at it. So the one state that is
        # both broken and common right after opting in -- binary built, palette
        # never written, customThemeFile still "" -- matched this arm, printed
        # "a choice, not a fault", and the whole section came back green.
        #
        # That is exactly what happened on a real laptop: section 12 said
        # "installed and runnable", 12b said both call sites agree, and this line
        # called the dead feature a preference. Nothing in the run was wrong except
        # that the last step (point DMS at the output) is manual and was never done.
        #
        # The two cases are trivially distinguishable, so distinguish them:
        #   palette EXISTS  -> genuinely a choice. Someone generated colours and
        #                      stayed on matugen's dynamic theme. Stay quiet.
        #   palette ABSENT  -> the engine has never produced anything. It is
        #                      installed, it is running on every wallpaper change,
        #                      and it is doing nothing observable. That is worth
        #                      one line, because no other symptom exists.
        #
        # WARN, not FAIL, for the same reason 12c is a WARN: nothing is damaged,
        # and one action clears it. Note the wording -- it never accuses the user
        # of a mistake, because opting in and not finishing the manual step is the
        # single most likely way to arrive here.
        if [ -f "$RC_THEME" ]; then
            note "DMS is on the '${rc_cur:-dynamic}' theme, so the palette is generated but not displayed — a choice, not a fault (Settings -> Theme & Colors -> Custom turns it on)"
        else
            warn "Ripe Chroma is installed but has never produced a palette — $RC_THEME does not exist, so the engine is doing nothing" \
                 "Open the control hub (SUPER+d) -> Ripe Chroma -> Generate. That writes the
         palette AND points DMS at it in one go. No control hub? Change your
         wallpaper once (gear icon -> Wallpaper) to write the palette, then turn it
         on in Settings -> Theme & Colors -> Custom.
         If you meant to build it and leave it off, nothing here needs doing."
        fi
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
# 13. THE CONTROL HUB (SUPER+d)
# =============================================================================
# WHY THIS SECTION EXISTS: it is the second half of the same incident that added
# the palette check to 12d. A laptop finished an update with SUPER+d doing
# nothing, and this script reported no problems -- because until now the control
# hub was checked NOWHERE. Section 12b names one file inside it, and even that
# treats the file being absent as a note ("nothing to cross-check there"), which
# is exactly backwards when the plugin is supposed to be installed.
#
# The hub matters more than a normal plugin because it is now the FRONT DOOR to
# other features: 12d above, and the fix text in several other sections, all tell
# people "open the control hub and press Generate". Advice that routes through a
# door nobody has checked is advice that can quietly go nowhere.
#
# WHAT CAN AND CANNOT BE ESTABLISHED HERE. The keybind spawns an IPC call, so the
# chain is: config.conf has the bind -> the plugin's files are on disk -> it is
# registered and enabled in plugin_settings.json -> the RUNNING shell has loaded
# it. The first three are files and are settled below. The fourth is deliberately
# NOT probed: the only way to ask is to call the toggle, and unlike section 3b's
# canary (which cycles focus and leaves nothing on screen) that would pop a panel
# open in the user's face during a health check. So a loaded-but-not-restarted
# shell is reported as the "restart DMS" advice attached to the file findings,
# which is the same fix either way.
section "13. Control hub (SUPER+d)"

CH_ID="controlHub"
CH_DIR="$DMS_DIR/plugins/$CH_ID"
CH_BIND_CMD="dms ipc call controlhub toggle"

ch_bound=0
grep -qF "$CH_BIND_CMD" "$MANGO_CFG" 2>/dev/null && ch_bound=1

if [ ! -d "$CH_DIR" ] && [ "$ch_bound" = 0 ]; then
    # Neither half is present: this install predates the control hub entirely.
    # Not a fault -- an old install that has never been updated is consistent.
    note "no control hub on this install (it predates the feature) — 'git pull && ./update.sh' adds it"
else
    # ---- 13a. are the plugin's files actually there? ------------------------
    if [ ! -d "$CH_DIR" ]; then
        fail "the control hub keybind is wired to a plugin that isn't installed" \
             "$MANGO_CFG binds SUPER+d to '$CH_BIND_CMD', but $CH_DIR does not exist" \
             "$CH_DIR, and the SUPER+d line in $MANGO_CFG" \
             "config.conf is copied by a file sync; the plugin is deployed by install.sh stage 14 and by update.sh's plugin arm. An update that placed the config but not the plugin (interrupted, or a delta that carried one and not the other) leaves exactly this: a key that spawns an IPC call to a plugin the shell has never heard of, which fails silently." \
"Pressing SUPER+d does nothing, because the panel it opens was never
installed.

1. Go to the folder you cloned DankMango into (the one with install.sh in
   it). Open a terminal with Super+Return, then:
     cd ~/DankMango
     ./install.sh
   (Answer the questions as you did before. Nothing is deleted — install.sh
   re-copies everything, which is what fills the gap.)

2. Restart the shell so it loads the panel:
     dms restart

3. Press SUPER+d. The control hub should open.

4. Re-run this check:
     $SCRIPTS/post-update-health.sh"
    else
        ch_missing=""
        for ch_f in plugin.json ControlHubPanel.qml RipeChromaSection.qml; do
            [ -f "$CH_DIR/$ch_f" ] || ch_missing="$ch_missing $ch_f"
        done
        if [ -n "$ch_missing" ]; then
            fail "the control hub is installed but incomplete" \
                 "$CH_DIR exists but is missing:$ch_missing" \
                 "$CH_DIR" \
                 "A partial plugin directory — an interrupted copy, or a restore that took some files and not others. DMS loads what it finds and the panel either fails to construct or comes up empty; either way the keybind appears to do nothing." \
"The control hub (SUPER+d) is only half installed, so it can't open.

1. Open a terminal (Super+Return) and re-install from your DankMango
   folder — it re-copies every file:
     cd ~/DankMango
     ./install.sh

2. Restart the shell:
     dms restart

3. Re-run this check:
     $SCRIPTS/post-update-health.sh"
        else
            pass "control hub plugin files are installed ($CH_DIR)"
        fi

        # ---- 13b. is it registered AND switched on in DMS? ------------------
        # Deployed-but-unregistered is the exact hole update.sh's
        # register-shipped-plugins migration was written to close, so a machine
        # that ran an older updater (or an interrupted one) can still be in it.
        # DMS only loads plugins it has an enabled entry for, so this state has
        # the same single symptom as a missing plugin: the key does nothing.
        if have jq && [ -f "$PLUGIN_SETTINGS" ]; then
            ch_reg="$(jq -r --arg id "$CH_ID" 'if (has($id)|not) then "absent" elif (.[$id].enabled // false) then "on" else "off" end' "$PLUGIN_SETTINGS" 2>/dev/null)"
            case "$ch_reg" in
                on)  pass "control hub is registered and enabled in plugin_settings.json" ;;
                off) warn "the control hub is installed but switched OFF in DMS — SUPER+d will do nothing" \
                          "Turn it back on: gear icon on the bar -> Plugins -> Control Hub -> on.
         (If you switched it off deliberately, ignore this — nothing else uses it.)" ;;
                *)   fail "the control hub is installed but not registered with DMS" \
                          "$PLUGIN_SETTINGS has no '$CH_ID' entry, so the shell never loads the plugin" \
                          "$PLUGIN_SETTINGS, and $CH_DIR" \
                          "plugin_settings.json is LIVE DMS STATE and is deliberately never overwritten by a file copy, so a plugin that started shipping after this machine was installed has to be registered by update.sh's register-shipped-plugins migration. An update that did not reach that migration leaves the files on disk and the shell unaware of them." \
"The control hub is on disk but DankMaterialShell doesn't know about it,
so SUPER+d does nothing.

1. Open a terminal (Super+Return) and update from your DankMango folder —
   the update registers plugins that shipped after your install:
     cd ~/DankMango
     git pull
     ./update.sh

2. Restart the shell:
     dms restart

3. Press SUPER+d. If it still does nothing, turn it on by hand: gear icon
   on the bar -> Plugins -> Control Hub -> on.

4. Re-run this check:
     $SCRIPTS/post-update-health.sh" ;;
            esac
        fi

        # ---- 13c. is the key actually bound? --------------------------------
        # The mirror image of 13a: the plugin is present and nothing can open it.
        # This one is worse than it looks -- the hub is a `daemon` plugin with no
        # bar widget, so the keybind is its ONLY way in. Without the bind there is
        # no fallback to click, and every other section's "open the control hub"
        # advice becomes unfollowable.
        if [ "$ch_bound" = 0 ]; then
            warn "the control hub is installed but SUPER+d is not bound to it in config.conf — nothing can open it" \
                 "The hub has no bar button (it is keybind-only), so this is its only way in.
         Restore the shipped keybinds: run ./install.sh from your DankMango folder,
         then press SUPER+SHIFT+r to reload the config."
        else
            pass "SUPER+d is bound to the control hub in config.conf"
        fi
    fi
fi

# =============================================================================
# SUMMARY  --  manual fix steps first, optional Claude Code block second
# =============================================================================
n=${#FAILS[@]}
nfix=${#FIXES[@]}
echo
echo "==================================================================="
if [ "$n" -eq 0 ] && [ "$nfix" -eq 0 ]; then
    printf ' %sALL CHECKS PASSED.%s Nothing to do.\n' "$c_grn" "$c_off"
    echo "==================================================================="
elif [ "$n" -eq 0 ]; then
    # Everything found is repairable from here, so there is no manual-fix report
    # to print -- but "ALL CHECKS PASSED" would be a lie, and it is the line people
    # read instead of the scan. Say what is actually true and point at the section
    # that handles it.
    printf ' %sNOTHING IS BROKEN BEYOND REPAIR.%s %d issue(s) can be fixed from here — see below.\n' \
        "$c_grn" "$c_off" "$nfix"
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
# MACHINE-READABLE MODES  --  --json and --apply-fix
# =============================================================================
#  Reached only when a flag asked for them, and reached AFTER the full scan, so
#  both work from the registries the scan filled rather than deriving anything of
#  their own. That is the whole design: the control hub's Health & Repair section
#  is a wrapper, this file is the single source of truth for what is broken and
#  how to repair it, and neither statement stays true if the GUI is allowed its
#  own copy of either.
#
#  Real stdout comes back here (it was parked on fd 3 before the scan so the
#  report went to /dev/null), and both arms exit before the walkthrough below --
#  which is why nothing about the terminal experience changes.

# json_str TEXT -- TEXT as a JSON string literal.
#
# PURE BASH, no jq, and that is not an accident: this is the script you run when
# the machine is ALREADY broken. Its job is to say so. Acquiring a runtime
# dependency in order to report a failure is how a health check ends up being the
# thing that cannot run.
#
# Colour codes are stripped before escaping. Every field below is prose a GUI
# renders in its own type: an escape sequence reaching it is terminal formatting
# that leaked, never content. (One headline really does carry one -- the
# config.conf finding highlights its warning in yellow for the terminal.) The tr
# then drops any other control character, since a raw one is invalid inside a
# JSON string and no field has a legitimate use for one.
json_str() {
    local s
    s="$(printf '%s' "$1" | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\000-\010\013\014\016-\037')"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    printf '"%s"' "$s"
}

if [ "$HEALTH_MODE" = applyfix ]; then
    exec 1>&3 3>&-
    if [ "$nfix" -gt 0 ]; then
        for entry in "${FIXES[@]}"; do
            IFS="$US" read -r -d '' f_id f_sev f_head f_broke f_does f_manual f_prompt f_remedy f_class f_needspw <<< "$entry"
            [ "$f_id" = "$HEALTH_FIX_ID" ] || continue
            # The SAME function the walkthrough's "y" calls, with the same
            # verify-it-actually-changed guard inside it. There is deliberately no
            # separate GUI path: a remedy that reports success it did not check is
            # the exact failure this project has been bitten by before, and a
            # second code path is how one of the two ends up without the guard.
            if eval "$f_remedy"; then exit 0; fi
            exit 1
        done
    fi
    # Not an error in the shouting sense -- the commonest way to get here is that
    # the finding was already put right (by a terminal run, by install.sh, or by
    # an earlier click) between the scan the caller is looking at and this one. A
    # distinct exit code lets a front-end say "already resolved" rather than
    # "the fix failed", which are not the same news.
    printf 'no [FIX!] finding with id "%s" in this scan — it may already be fixed.\n' "$HEALTH_FIX_ID" >&2
    exit 4
fi

if [ "$HEALTH_MODE" = json ]; then
    exec 1>&3 3>&-
    printf '{'
    printf '"schema":1,'

    # Versions, and whether one moved. Same three facts the report opens with, and
    # for the same reason: a version that changed is the prime suspect for
    # everything below it.
    printf '"versions":{"mango":%s,"dms":%s,"quickshell":%s,"changed":%s},' \
        "$(json_str "$mango_ver")" "$(json_str "$dms_ver")" "$(json_str "$qs_ver")" \
        "$([ "$VERSION_CHANGED" = 1 ] && printf true || printf false)"

    # The summary line, computed HERE from the same two numbers the terminal
    # prints, so the two can't drift: "N checks passed. M issue(s) found — F
    # fixable now." A warn or a note is not an issue in that line and is not one
    # here either.
    printf '"summary":{"passed":%d,"issues":%d,"fixable":%d},' \
        "$PASS_N" "$(( n + nfix ))" "$nfix"

    # Every row the scan printed, in scan order. FIX rows appear here too (tagged
    # FIX, carrying their stable id) so a front-end can show the scan as it really
    # ran; their full walkthrough content is in "fixes" below rather than
    # duplicated into both.
    printf '"checks":['
    j_first=1
    if [ "${#FINDINGS[@]}" -gt 0 ]; then
        for entry in "${FINDINGS[@]}"; do
            IFS="$US" read -r -d '' k_tag k_sec k_id k_msg k_detail k_manual k_where <<< "$entry"
            [ "$j_first" = 1 ] || printf ','
            j_first=0
            printf '{"tag":%s,"section":%s,"id":%s,"message":%s,"detail":%s,"manual":%s,"where":%s}' \
                "$(json_str "$k_tag")" "$(json_str "$k_sec")" "$(json_str "$k_id")" \
                "$(json_str "$k_msg")" "$(json_str "$k_detail")" \
                "$(json_str "$k_manual")" "$(json_str "$k_where")"
        done
    fi
    printf '],'

    # The [FIX!] findings, with the whole walkthrough each one would have printed:
    # what broke, what the fix does, the by-hand command, the Claude Code prompt.
    # The REMEDY ITSELF IS NOT IN HERE, on purpose. It is a shell string, and a
    # front-end that received it could run it -- at which point the guards live on
    # one side of the wire and the execution on the other. The id is the whole
    # interface: ask --apply-fix for it and this file does the work.
    printf '"fixes":['
    j_first=1
    if [ "$nfix" -gt 0 ]; then
        for entry in "${FIXES[@]}"; do
            IFS="$US" read -r -d '' f_id f_sev f_head f_broke f_does f_manual f_prompt f_remedy f_class f_needspw <<< "$entry"
            [ "$j_first" = 1 ] || printf ','
            j_first=0
            printf '{"id":%s,"severity":%s,"class":%s,"needsPassword":%s,"headline":%s,"broke":%s,"does":%s,"manual":%s,"prompt":%s}' \
                "$(json_str "$f_id")" "$(json_str "$f_sev")" "$(json_str "$f_class")" \
                "$([ "${f_needspw:0:1}" = 1 ] && printf true || printf false)" \
                "$(json_str "$f_head")" "$(json_str "$f_broke")" "$(json_str "$f_does")" \
                "$(json_str "$f_manual")" "$(json_str "$f_prompt")"
        done
    fi
    printf ']'
    printf '}\n'
    exit 0
fi

# =============================================================================
# FIXABLE NOW  --  one finding at a time, one y/N each
# =============================================================================
#  This replaces the old "safe re-applies" block, which asked the same kind of
#  y/N question about the same kind of mechanical repair. Two prompt loops after
#  one report was never going to read as one flow, and the offers carried no
#  explanation of what they were about to do -- just a label.
#
#  THE RULES THIS SECTION KEEPS, in the order they matter:
#    * The scan above is unchanged and still read-only. Nothing here runs until
#      the report is finished and the user has said y to this specific finding.
#    * ONE finding on screen at a time. Printing every breakdown at once and then
#      asking is how people end up saying y to something they scrolled past.
#    * ONE yes/no each. There is deliberately no "fix everything" shortcut.
#    * The default is no. An empty answer, an unreadable terminal, a closed pipe:
#      all of them mean no.
#    * A remedy that cannot prove it worked reports failure, not success.
fix_interactive() {
    # STRICTER than update.sh's ask_tty(), which tests /dev/tty alone. That is the
    # right test there, where the script is always run by hand; here the report is
    # routinely piped into a pager or a log, and a readable /dev/tty survives both
    # of those. So stdout must be a terminal AS WELL, which is what makes
    # `post-update-health.sh | tee log` a report and nothing more.
    [ -t 1 ] && [ -r /dev/tty ]
}
# fix_ask PROMPT -> 0 only for an explicit yes. Reads /dev/tty, never stdin, for
# the reason ask_tty() documents: a loop over a pipe must never eat the answer.
fix_ask() {
    local ans
    fix_interactive || return 1
    printf '\n  %s%s%s ' "$c_cyn" "$1" "$c_off" > /dev/tty
    read -r ans < /dev/tty || return 1
    # Same acceptance as update.sh's ask_tty(): anything starting with y is yes,
    # everything else -- including an empty line -- is no.
    case "$ans" in [yY]*) return 0 ;; *) return 1 ;; esac
}

fix_left_fail=0                 # fail-severity findings still unfixed -> exit code
if [ "$nfix" -gt 0 ]; then
    fix_done=0; fix_skipped=0; fix_failed=0
    echo
    printf '%s═══════════════════════════════════════════════════════════════%s\n' "$c_cyn" "$c_off"
    printf ' %sFIXABLE NOW%s\n' "$c_cyn" "$c_off"
    printf '%s═══════════════════════════════════════════════════════════════%s\n' "$c_cyn" "$c_off"
    printf ' %d checks passed. %d issue(s) found — %d fixable now.\n' \
        "$PASS_N" "$(( n + nfix ))" "$nfix"
    if fix_interactive; then
        cat <<'EOF'
 Each one is shown on its own, with what it will do, before you are asked.
 The default is no: press Enter to skip. Nothing is changed until you
 type y, and everything overwritten is backed up first.
EOF
    else
        cat <<'EOF'
 This is not running in a terminal, so nothing below will be applied and
 nothing will be asked — what follows is a report. Run it in a terminal
 to be offered the fixes.
EOF
    fi

    fix_i=1
    for entry in "${FIXES[@]}"; do
        # -d '' so the multi-line prose fields survive the round trip intact.
        # f_id, f_class and f_needspw exist for --json and --apply-fix and are
        # deliberately unread here -- but they still have to be NAMED, or the
        # trailing fields would be swept into f_remedy and eval'd.
        IFS="$US" read -r -d '' f_id f_sev f_head f_broke f_does f_manual f_prompt f_remedy f_class f_needspw <<< "$entry"
        printf '\n%s───────────────────────────────────────────────────────────────%s\n' "$c_dim" "$c_off"
        printf ' %s[%d/%d]%s %s\n' "$c_cyn" "$fix_i" "$nfix" "$c_off" "$f_head"
        printf '%s───────────────────────────────────────────────────────────────%s\n' "$c_dim" "$c_off"
        printf '\n  %sWhat broke%s\n' "$c_yel" "$c_off"
        indent4 "$f_broke"
        printf '\n  %sWhat this fix will do%s\n' "$c_grn" "$c_off"
        indent4 "$f_does"
        printf '\n  %sOr do it yourself, by hand%s\n' "$c_dim" "$c_off"
        indent4 "$f_manual"
        printf '\n  %sOr paste this to Claude Code%s\n' "$c_dim" "$c_off"
        indent4 "$f_prompt"

        if ! fix_interactive; then
            printf '\n  %s(report only — not applied)%s\n' "$c_dim" "$c_off"
            fix_skipped=$((fix_skipped+1))
            [ "$f_sev" = fail ] && fix_left_fail=$((fix_left_fail+1))
        elif fix_ask "Apply this fix now? [y/N]"; then
            if eval "$f_remedy"; then
                printf '  %sfixed.%s\n' "$c_grn" "$c_off"
                fix_done=$((fix_done+1))
            else
                # NOT "nothing was changed": remedy_recopy_dir can legitimately get
                # part way through a plugin before a later file fails, and it says so
                # itself. A remedy that really did change nothing has already printed
                # that line; this one must not claim it on their behalf.
                printf '  %snot fixed — see above. The manual steps still stand.%s\n' "$c_red" "$c_off"
                fix_failed=$((fix_failed+1))
                [ "$f_sev" = fail ] && fix_left_fail=$((fix_left_fail+1))
            fi
        else
            printf '  %sskipped.%s\n' "$c_dim" "$c_off"
            fix_skipped=$((fix_skipped+1))
            [ "$f_sev" = fail ] && fix_left_fail=$((fix_left_fail+1))
        fi
        fix_i=$((fix_i+1))
    done

    echo
    if fix_interactive; then
        printf ' %d fixed, %d skipped' "$fix_done" "$fix_skipped"
        [ "$fix_failed" -gt 0 ] && printf ', %d tried and failed' "$fix_failed"
        printf '.\n'
    else
        printf ' %d fixable issue(s) listed; none applied (not a terminal).\n' "$nfix"
    fi
    echo "==================================================================="
fi

# exit non-zero if anything failed, so it's scriptable in a pipeline. A fixable
# finding counts here exactly as its old severity did: a skipped fixable FAIL is
# still a failure, a fixable WARN never was one, and a fix that verified its own
# success drops out of the count.
exit $(( (n > 0 || fix_left_fail > 0) ? 1 : 0 ))
