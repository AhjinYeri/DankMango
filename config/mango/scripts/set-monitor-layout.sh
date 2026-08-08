#!/usr/bin/env bash
#
# =============================================================================
#  set-monitor-layout.sh  --  set a monitor's tiling LAYOUT (and save it)
# =============================================================================
#
#  >>> IF SOMETHING STOPPED WORKING AFTER A SYSTEM UPDATE, START HERE <<<
#
#  Everything that can break when MangoWM updates lives in ONE place: the box
#  below marked "########## EDIT HERE AFTER A MANGO UPDATE ##########". Read its
#  plain-English comments and fix the commands to match the new version.
#
#  This is the LAYOUT sibling of set-monitor-mode.sh (which does tile/float).
#  Layout is INDEPENDENT of float mode: this script only rewrites the
#  "layout_name:" field and never touches "open_as_floating".
#
#  >>> MOST LIKELY CULPRIT: the config-RELOAD command. <<<
#  If you pick a layout and ALREADY-OPEN windows don't rearrange, the reload
#  command (mango_reload_config below) is almost certainly wrong for the new
#  MangoWM version. (It returns success even when it fails -- silent breakage.)
#
#  Plain-English guide: ~/.config/DankMaterialShell/plugins/monitorMode/README.md
#
# -----------------------------------------------------------------------------
#  WHAT THIS SCRIPT DOES (plain English)
# -----------------------------------------------------------------------------
#  A monitor's layout is stored as "layout_name:<name>" on each of that
#  monitor's tag rules. Those rules live in the AUTO-GENERATED
#  dms/tagrules.conf (written by scripts/generate-tagrules.sh, sourced by
#  config.conf). This is the ONE script that edits the layout field and reloads
#  the config. The Monitor Mode bar plugin / keybinds just call it.
#
#  USAGE:
#    set-monitor-layout.sh <MON> <layout>                 # one monitor
#    set-monitor-layout.sh <MON>:<layout> [<MON>:<layout>...]  # several, one reload
#  EXAMPLES:
#    set-monitor-layout.sh DP-1 monocle
#    set-monitor-layout.sh DP-1:tile DP-2:scroller
#
#  Valid layouts (the 6 curated Monitor-Mode layouts, see mango-layout-names):
#    tile  monocle  scroller  grid  deck  center_tile
#
set -euo pipefail

# CMD lines are what docs-hub.sh's command list shows: a real, runnable command
# and a short description, separated by " :: ". They live here, next to the code
# that implements them, so the hub stores no copy of its own. Add a line when you
# add a flag worth showing; the fuller explanation stays in the Usage block above.
# CMD: ~/.config/mango/scripts/set-monitor-layout.sh DP-1 monocle :: set one monitor's layout (tile monocle scroller grid deck center_tile)
# CMD: ~/.config/mango/scripts/set-monitor-layout.sh DP-1:tile DP-2:scroller :: set several at once, with a single reload

# #############################################################################
# ########## EDIT HERE AFTER A MANGO UPDATE ###################################
# #############################################################################
# Everything in this box is "version-specific": file paths, MangoWM config
# syntax, and the commands MangoWM understands. Fix things HERE after an update.

# --- 1. FILE PATHS ----------------------------------------------------------
# CONFIG is the file whose tagrule lines this script edits (same file that
# set-monitor-mode.sh edits). Per-monitor tagrules live in the auto-generated
# dms/tagrules.conf (sourced by config.conf), so we edit THAT -- not config.conf.
CONFIG="$HOME/.config/mango/dms/tagrules.conf"                # per-monitor tagrules (this script edits it)

# Every layout change funnels through THIS script (the Monitor Mode plugin and the
# hotplug watcher both shell out to it), so this is where the persistent
# monitor->layout memory gets updated. That memory is what lets an UNPLUGGED
# monitor come back on its own layout instead of tile -- while it is unplugged it
# has no tagrules at all, so CONFIG above cannot remember anything about it.
# Best-effort by design: if the watcher script is missing, layouts still work, you
# just lose the across-a-replug memory.
MEMORY_HOOK="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/monitor-watcher.sh"

# --- 2. THE "LAYOUT" FIELD IN THE CONFIG ------------------------------------
# A monitor's layout is written "layout_name:<name>" on its tag rules. This
# script rewrites exactly this field. If a future MangoWM renames it, change
# this one keyword.
MANGO_LAYOUT_KEY="layout_name"

# --- 3. THE VALID LAYOUT NAMES ----------------------------------------------
# The 6 curated layouts and their exact mango layout_name strings (verified
# empirically; see the mango-layout-names note). Use the PLAIN names, NOT the
# vertical_* variants. An unrecognized name is SILENTLY ignored by mango (keeps
# the previous layout, and `mango -c -p` still returns 0), so this whitelist --
# not mango's validator -- is what guards against typos.
VALID_LAYOUTS="tile monocle scroller grid deck center_tile"

# --- 4. COMMANDS THAT TALK TO MANGOWM ---------------------------------------
# Reload the config so the layout change takes effect. Unlike tile/float, a
# layout reload RE-ARRANGES already-open tiled windows immediately -- so there
# is NO retroactive "sweep" step here (set-monitor-mode.sh needs one; this
# doesn't).
#   mango 0.13 (DEAD): mmsg -s -d reload_config
#   mango 0.14+ (now): mmsg dispatch reload_config
# To test by hand:  mmsg dispatch reload_config   (should print {"success":true})
mango_reload_config() { mmsg dispatch reload_config >/dev/null 2>&1 || true; }

# Check that an edited config file ($1) is valid BEFORE we overwrite the live
# one, so a bad edit can never break your running setup.
#   mango -c <file> -p   exits 0 if the file is valid.
mango_validate_config() { mango -c "$1" -p >/dev/null 2>&1; }

# #############################################################################
# ########## END OF EDIT-HERE BOX -- logic below should stay stable ###########
# #############################################################################

die() { echo "set-monitor-layout: $*" >&2; exit 1; }

is_valid_layout() {
  local l
  for l in $VALID_LAYOUTS; do [ "$l" = "$1" ] && return 0; done
  return 1
}

# Parse args into a "MON layout" list (accepts "MON layout" pair or "MON:layout" tokens).
declare -a PAIRS=()
# --help prints this script's own header block (the only copy of its usage).
# Same one-line idiom as install.sh/update.sh/uninstall.sh, so docs-hub.sh's
# command menu can shell out to it instead of storing a second description.
self_help() { awk 'NR>2 && !/^#/{exit} NR>2 && sub(/^#[ ]?/,"")' "$0"; }
case "${1:-}" in -h|--help) self_help; exit 0 ;; esac

if [ "$#" -eq 2 ] && [[ "$1" != *:* ]]; then
  PAIRS=("$1 $2")
elif [ "$#" -ge 1 ]; then
  for tok in "$@"; do
    [[ "$tok" == *:* ]] || die "bad arg '$tok' (want MON:layout, e.g. DP-1:monocle)"
    PAIRS+=("${tok%%:*} ${tok##*:}")
  done
else
  die "usage: $0 <MON> <layout> | <MON>:<layout> [<MON>:<layout>...]"
fi

# Validate monitor + layout, build the map string awk consumes (MON=layout ...).
MAP=""
SUMMARY=""
for p in "${PAIRS[@]}"; do
  mon="${p%% *}"; lay="${p##* }"
  is_valid_layout "$lay" || die "bad layout '$lay' for $mon (want: $VALID_LAYOUTS)"
  grep -qE "^[[:space:]]*tagrule[^#]*monitor_name:[[:space:]]*$mon([,[:space:]]|$)" "$CONFIG" \
    || die "no tagrules for monitor '$mon' in $CONFIG"
  MAP+="$mon=$lay "
  SUMMARY+="${SUMMARY:+, }$mon → $lay"
done

# Rewrite the layout field on every matching tagrule line. Replaces an existing
# "layout_name:<old>" in place; if a line somehow lacks the field it is left
# alone (all generated lines carry it). The field name comes from
# MANGO_LAYOUT_KEY above (passed to awk as `key`). Idempotent.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
awk -v map="$MAP" -v key="$MANGO_LAYOUT_KEY" '
  BEGIN {
    n = split(map, kv, " ")
    for (i = 1; i <= n; i++) {
      if (kv[i] == "") continue
      eq = index(kv[i], "=")
      want[substr(kv[i], 1, eq-1)] = substr(kv[i], eq+1)
    }
  }
  {
    line = $0
    if (line ~ /^[[:space:]]*tagrule/) {
      for (mon in want) {
        if (line ~ ("monitor_name:[ \t]*" mon "([,\t ]|$)")) {
          # replace existing "layout_name:<old>" with the wanted layout
          gsub(key ":[A-Za-z_]+", key ":" want[mon], line)
          break
        }
      }
    }
    print line
  }
' "$CONFIG" > "$TMP"

# Validate the candidate before touching the live config.
mango_validate_config "$TMP" || die "edited config failed validation; aborting (config unchanged)"

cat "$TMP" > "$CONFIG"

# Reload live (SUPER+r equivalent; works without a fresh login). This alone
# re-arranges already-open tiled windows -- no sweep needed.
mango_reload_config

# Record what was just applied, so a replug of any of these monitors restores it.
# `|| true` twice over: this script runs under `set -e` on the user's click path,
# and a memory failure must never turn a successful layout change into an error.
if [ -x "$MEMORY_HOOK" ]; then
  for p in "${PAIRS[@]}"; do
    "$MEMORY_HOOK" --remember "${p%% *}" "${p##* }" >/dev/null 2>&1 || true
  done
fi

echo "set-monitor-layout: $(printf '%b' "$SUMMARY")"
