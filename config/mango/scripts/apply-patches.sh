#!/usr/bin/env bash
#
# =============================================================================
#  apply-patches.sh  --  DankMango patch dispatcher
# =============================================================================
#  ONE command that re-applies whichever of DankMango's package-owned-file
#  patches have gone stale. You don't have to know their names, or which of them
#  your last system update happened to wipe:
#
#      ~/.config/mango/scripts/apply-patches.sh
#
#  WHAT A "PATCH" MEANS HERE
#    A handful of DankMango's features aren't files DankMango owns. They're small
#    edits to files belonging to somebody else's PACKAGE (a DMS core QML file,
#    say). Those files get replaced wholesale every time that package updates,
#    which silently reverts the edit. So each patch ships as an idempotent apply
#    script, and each leaves a MARKER string in the file it patches so you can
#    test for it later.
#
#  WHAT THIS SCRIPT ADDS
#    The marker test, the "has this user opted in?" test and the re-apply used to
#    be spread across post-update-health.sh, install.sh and the patch script
#    itself. This is now the one place that knows the set of patches; the health
#    check ASKS this script (status --porcelain) instead of carrying its own copy
#    of a target path and a marker string.
#
#  OPT-IN IS RESPECTED, ALWAYS
#    These patches are opt-in at install time, so "the marker is missing" does
#    NOT mean "repair it". It means either "you took it and an update wiped it"
#    (stale -> we re-apply) or "you never wanted it" (not-applied -> we leave it
#    alone and say so). A bare run of this script will never apply a patch you
#    declined. Naming one explicitly is how you opt in later.
#
#  Usage:
#     apply-patches.sh                 re-apply every STALE patch; touch nothing else
#     apply-patches.sh status          say what state each patch is in; change nothing
#     apply-patches.sh status --porcelain
#                                      the same, tab-separated, for other scripts
#     apply-patches.sh <id>            apply ONE patch by id, even if not opted in
#     apply-patches.sh --all           apply every patch (opts you in to all of them)
#     apply-patches.sh --force         re-apply even where the marker is already there
#     apply-patches.sh --help          this text
#
#  Exit codes:  0 = nothing needed doing, or everything needed was done
#               1 = something needs a human (see the message; usually a package
#                   moved the file a patch targets, so the patch has nowhere to go)
#
#  ADDING A NEW PATCH  (the whole procedure)
#     1. Ship its apply script in config/mango/scripts/ — idempotent, writes a
#        MARKER into the target, backs the target up first, calls sudo itself.
#     2. Add its id to PATCH_IDS below and fill in the p_* fields for it.
#     3. There's no step 3. post-update-health.sh, this dispatcher and the GUIDE
#        all read the registry; none of them names a patch individually.
# =============================================================================
set -uo pipefail

# CMD lines are what docs-hub.sh's command list shows: a real, runnable command
# and a short description, separated by " :: ". They live here, next to the code
# that implements them, so the hub stores no copy of its own. Add a line when you
# add a flag worth showing; the fuller explanation stays in the Usage block above.
# CMD: ~/.config/mango/scripts/apply-patches.sh :: re-apply DankMango patches that a package update wiped
# CMD: ~/.config/mango/scripts/apply-patches.sh status :: show what state each patch is in; changes nothing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable for the same reason as DANKMANGO_PATCH_ROOT below: the "has this
# machine ever opted in?" test reads this directory, so it has to be steerable to
# test the not-applied path without deleting anybody's real backups.
BACKUP_DIR="${DANKMANGO_BACKUP_DIR:-$HOME/.config/mango/backups}"
MANIFEST="${XDG_STATE_HOME:-$HOME/.local/state}/dankmango/manifest.json"
# Testing hook: prefixes every target path so the detection logic can be exercised
# against a fake tree instead of the real root-owned files. Same spirit as
# DANKMANGO_SDDM_THEME_DIR in lib/common.sh. Empty in normal use.
ROOT="${DANKMANGO_PATCH_ROOT:-}"

c_grn=$'\033[32m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

# =============================================================================
#  THE REGISTRY  --  the only place the set of patches is written down
# =============================================================================
#  Per patch:
#    title    short human name, used in headings and by the health check
#    blurb    what it DOES, lowercase, completes "DankMango ..." — shown to users
#    target   the package-owned file it edits (ROOT is prefixed at read time)
#    marker   literal string the patch leaves behind; presence == patch is applied
#    package  which package owns the target, so a user can be told what wiped it
#    script   the idempotent apply script, relative to this script's directory
#    backup   glob of the backups that script makes; used as the opt-in fallback
#             for installs made before the manifest recorded patch-applied
#    verify   how the user confirms it worked, after the restart
#    restart  the command that makes the patched file take effect
# =============================================================================
PATCH_IDS=(combined-audio-osd)

declare -A p_title p_blurb p_target p_marker p_package p_script p_backup p_verify p_restart

p_title[combined-audio-osd]="combined audio OSD patch"
p_blurb[combined-audio-osd]="adds the device name to the volume popup, so switching audio output shows ONE popup (icon + device name + slider) instead of two stacked ones"
p_target[combined-audio-osd]="/usr/share/quickshell/dms/Modules/OSD/VolumeOSD.qml"
p_marker[combined-audio-osd]="DankMango patch: combined OSD device name"
p_package[combined-audio-osd]="dms-shell"
p_script[combined-audio-osd]="apply-combined-osd-patch.sh"
p_backup[combined-audio-osd]="VolumeOSD.qml.*"
p_verify[combined-audio-osd]="switch between speakers and headphones using the audio button on the bar — you should get ONE popup showing the device name, its icon and the volume slider together"
p_restart[combined-audio-osd]="dms restart"

# =============================================================================
#  State detection
# =============================================================================
# target_of ID -> the target path, with the testing prefix applied
target_of() { printf '%s%s\n' "$ROOT" "${p_target[$1]}"; }

# script_of ID -> absolute path of the patch's own apply script
script_of() { printf '%s/%s\n' "$SCRIPT_DIR" "${p_script[$1]}"; }

# opted_in ID -> 0 if this machine ever had this patch applied.
#
# Two sources, because one of them is younger than some installs. install.sh
# records a 'patch-applied' systemChange when you say yes at the prompt — that's
# the authoritative answer. Installs made before that record existed have no such
# entry, so fall back to physical evidence: the patch script backs the target up
# every time it writes, so a backup matching its glob means it's run here.
# Neither is a guess; both mean "this machine said yes at some point".
opted_in() {
    local id="$1"
    if [ -r "$MANIFEST" ] && command -v jq >/dev/null 2>&1; then
        if jq -e --arg t "${p_target[$id]}" \
            '[ .systemChanges[]? | select(.type=="patch-applied" and ((.detail.target // .key)==$t)) ] | length > 0' \
            "$MANIFEST" >/dev/null 2>&1; then
            return 0
        fi
    fi
    compgen -G "$BACKUP_DIR/${p_backup[$id]}" >/dev/null 2>&1
}

# state_of ID -> one of: ok | stale | not-applied | target-missing | script-missing
#
# This is the logic post-update-health.sh used to carry inline; it now lives here
# and the health check asks for the answer instead of recomputing it.
state_of() {
    local id="$1" t; t="$(target_of "$id")"
    [ -f "$(script_of "$id")" ] || { echo script-missing; return; }
    [ -f "$t" ]                 || { echo target-missing; return; }
    if grep -qF "${p_marker[$id]}" "$t" 2>/dev/null; then echo ok; return; fi
    if opted_in "$id"; then echo stale; else echo not-applied; fi
}

# =============================================================================
#  Reporting
# =============================================================================
# One tab-separated line per patch, for other scripts. Fields, in order:
#   id  state  title  target  package  blurb  verify  restart
# Consumers must split on TAB only; every field is free of tabs by construction.
porcelain() {
    local id
    for id in "${PATCH_IDS[@]}"; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$id" "$(state_of "$id")" "${p_title[$id]}" "$(target_of "$id")" \
            "${p_package[$id]}" "${p_blurb[$id]}" "${p_verify[$id]}" "${p_restart[$id]}"
    done
}

describe() {  # describe ID STATE -> one human line
    local id="$1" st="$2"
    case "$st" in
        ok)             printf '  %s[ ok ]%s %s — applied and current\n' "$c_grn" "$c_off" "${p_title[$id]}" ;;
        stale)          printf '  %s[STALE]%s %s — you have this, but a %s update wiped it\n' "$c_yel" "$c_off" "${p_title[$id]}" "${p_package[$id]}" ;;
        not-applied)    printf '  %s[ -- ]%s %s — not applied here (optional; take it with: %s %s)\n' "$c_dim" "$c_off" "${p_title[$id]}" "$(basename "$0")" "$id" ;;
        target-missing) printf '  %s[BROKEN]%s %s — %s no longer ships %s\n' "$c_red" "$c_off" "${p_title[$id]}" "${p_package[$id]}" "$(target_of "$id")" ;;
        script-missing) printf '  %s[BROKEN]%s %s — its apply script is missing (%s)\n' "$c_red" "$c_off" "${p_title[$id]}" "$(script_of "$id")" ;;
    esac
}

do_status() {
    local id st rc=0
    echo
    echo "DankMango patches — files DankMango edits that belong to other packages"
    echo
    for id in "${PATCH_IDS[@]}"; do
        st="$(state_of "$id")"
        describe "$id" "$st"
        case "$st" in target-missing|script-missing) rc=1 ;; esac
    done
    echo
    return $rc
}

# =============================================================================
#  Applying
# =============================================================================
# apply_one ID [--force] -> 0 on success. Delegates to the patch's own script,
# which owns the backup, the sudo write and the post-write verify. Nothing about
# how a given patch is applied lives in this dispatcher.
apply_one() {
    local id="$1" force="${2:-}" s; s="$(script_of "$id")"
    printf '\n%s── %s ──%s\n' "$c_dim" "${p_title[$id]}" "$c_off"
    if [ ! -f "$s" ]; then
        printf '  %s[FAIL]%s apply script missing: %s\n' "$c_red" "$c_off" "$s" >&2
        printf '        Re-run install.sh from your DankMango folder to put it back.\n' >&2
        return 1
    fi
    if [ -n "$force" ]; then bash "$s" --force; else bash "$s"; fi
}

main_apply() {  # main_apply FORCE ID...
    local force="$1"; shift
    local id st rc=0 did=0 restarts=()
    for id in "$@"; do
        st="$(state_of "$id")"
        if [ "$st" = target-missing ]; then
            describe "$id" "$st"
            printf '        Nothing to apply — find where it went:  pacman -Ql %s | grep %s\n' \
                   "${p_package[$id]}" "$(basename "${p_target[$id]}")" >&2
            rc=1; continue
        fi
        if apply_one "$id" "$force"; then
            did=$((did+1)); restarts+=("${p_restart[$id]}")
        else
            rc=1
        fi
    done
    if [ "$did" -gt 0 ]; then
        echo
        printf '%sApplied %d patch(es). Now restart the shell so they take effect:%s\n' "$c_grn" "$did" "$c_off"
        printf '%s\n' "${restarts[@]}" | sort -u | sed 's/^/    /'
    fi
    return $rc
}

self_help() { awk 'NR>2 && !/^#/{exit} NR>2 && sub(/^#[ ]?/,"")' "$0"; }

# =============================================================================
#  Entry point
# =============================================================================
FORCE=""
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)   self_help; exit 0 ;;
        --force)     FORCE="--force"; shift ;;
        --all)       ARGS=("${PATCH_IDS[@]}"); shift ;;
        # Only meaningful as `status --porcelain` (handled in that arm). On its own
        # it must NOT fall through to the apply path -- a caller that meant to ask a
        # question would instead have started writing to root-owned files.
        --porcelain) printf 'apply-patches.sh: --porcelain only applies to "status" (try: %s status --porcelain)\n' "$(basename "$0")" >&2; exit 1 ;;
        status)      shift
                     [ "${1:-}" = "--porcelain" ] && { porcelain; exit 0; }
                     do_status; exit $? ;;
        -*)          printf 'apply-patches.sh: unknown option: %s  (try --help)\n' "$1" >&2; exit 1 ;;
        *)           # a patch id, named explicitly = opting in to it
                     if [ -z "${p_title[$1]:-}" ]; then
                         printf 'apply-patches.sh: unknown patch: %s\n' "$1" >&2
                         printf 'known patches: %s\n' "${PATCH_IDS[*]}" >&2
                         exit 1
                     fi
                     ARGS+=("$1"); shift ;;
    esac
done

# Explicitly named patches (or --all): apply them whatever their state — naming a
# patch IS the opt-in. Nothing named: repair only what's genuinely stale, and
# report the rest without touching it.
if [ "${#ARGS[@]}" -gt 0 ]; then
    main_apply "$FORCE" "${ARGS[@]}"
    exit $?
fi

stale=(); broken=0
for id in "${PATCH_IDS[@]}"; do
    st="$(state_of "$id")"
    case "$st" in
        stale)                        stale+=("$id") ;;
        target-missing|script-missing) describe "$id" "$st"; broken=1 ;;
    esac
done

if [ "${#stale[@]}" -eq 0 ]; then
    if [ "$broken" -eq 1 ]; then
        echo
        echo "Nothing to re-apply, but see the broken patch(es) above." >&2
        exit 1
    fi
    echo "All DankMango patches are current — nothing to re-apply."
    echo "(Full state: $(basename "$0") status)"
    exit 0
fi

printf 'Re-applying %d stale patch(es): %s\n' "${#stale[@]}" "${stale[*]}"
main_apply "$FORCE" "${stale[@]}"
rc=$?
[ "$broken" -eq 1 ] && rc=1
exit $rc
