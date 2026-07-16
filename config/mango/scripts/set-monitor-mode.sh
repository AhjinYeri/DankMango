#!/usr/bin/env bash
#
# =============================================================================
#  set-monitor-mode.sh  --  set a monitor to TILE or FLOAT mode (and save it)
# =============================================================================
#
#  >>> IF SOMETHING STOPPED WORKING AFTER A SYSTEM UPDATE, START HERE <<<
#
#  Everything that can break when MangoWM updates lives in ONE place: the box
#  below marked "########## EDIT HERE AFTER A MANGO UPDATE ##########". Read its
#  plain-English comments and fix the commands to match the new version.
#
#  >>> MOST LIKELY CULPRIT: the config-RELOAD command. <<<
#  This has silently broken TWICE across MangoWM updates. If you change a mode
#  (with a button or this script) and ALREADY-OPEN windows update but NEWLY-opened
#  windows keep the OLD mode, the reload command is almost certainly wrong --
#  it's mango_reload_config() in the box below. (It returns success even when it
#  fails, which is why the breakage is silent.)
#
#  Plain-English guide: ~/.config/DankMaterialShell/plugins/monitorMode/README.md
#
# -----------------------------------------------------------------------------
#  WHAT THIS SCRIPT DOES (plain English)
# -----------------------------------------------------------------------------
#  A monitor's mode (tile or float) is stored as the presence or absence of the
#  word "open_as_floating" on that monitor's tag rules. Those rules live in the
#  AUTO-GENERATED  dms/tagrules.conf  (written by scripts/generate-tagrules.sh and
#  sourced by config.conf). This is the ONE script that edits those rules and
#  reloads the config. The Monitor Mode bar plugin / keybinds just call it.
#
#  USAGE:
#    set-monitor-mode.sh <MON> <tile|float>             # one monitor
#    set-monitor-mode.sh <MON>:<mode> [<MON>:<mode>...] # several at once, one reload
#  EXAMPLES:
#    set-monitor-mode.sh MONITOR-1 float
#    set-monitor-mode.sh MONITOR-1:tile MONITOR-2:float
#
set -euo pipefail

# #############################################################################
# ########## EDIT HERE AFTER A MANGO UPDATE ###################################
# #############################################################################
# Everything in this box is "version-specific": file paths, MangoWM config
# syntax, and the commands MangoWM understands. Fix things HERE after an update.

# --- 1. FILE PATHS ----------------------------------------------------------
# CONFIG is the file whose tagrule lines this script edits. Per-monitor tagrules now
# live in the auto-generated dms/tagrules.conf (sourced by config.conf), so we edit
# THAT -- not config.conf. (mango validates a tagrule-only file fine via `mango -c -p`.)
CONFIG="$HOME/.config/mango/dms/tagrules.conf"                # per-monitor tagrules (this script edits it)
SWEEP="$HOME/.config/mango/scripts/dp2-floatsize.sh"          # helper that re-applies the mode to already-open windows

# --- 2. THE "FLOAT MODE" KEYWORD IN THE CONFIG ------------------------------
# A monitor is FLOATING when its tag rules contain this word (written
# "open_as_floating:1"); TILING when the word is absent. This script adds/removes
# exactly this word. If a future MangoWM renames it, change this one word.
MANGO_FLOAT_TOKEN="open_as_floating"

# --- 3. COMMANDS THAT TALK TO MANGOWM ---------------------------------------
# Reload the config so a mode change takes effect on NEWLY-opened windows.
# !!! THIS IS THE LINE THAT BROKE TWICE ACROSS UPDATES !!!
#   mango 0.13 (DEAD): mmsg -s -d reload_config   <- silently does nothing on 0.14
#   mango 0.14 (now) : mmsg dispatch reload_config
# To test by hand:  mmsg dispatch reload_config   (should print {"success":true})
mango_reload_config() { mmsg dispatch reload_config >/dev/null 2>&1 || true; }

# Check that an edited config file ($1) is valid BEFORE we overwrite the live one,
# so a bad edit can never break your running setup.
#   mango -c <file> -p   exits 0 if the file is valid.
mango_validate_config() { mango -c "$1" -p >/dev/null 2>&1; }

# #############################################################################
# ########## END OF EDIT-HERE BOX -- logic below should stay stable ###########
# #############################################################################

# --- notification (kept in ONE place so it's easy to remove later) -------------
# Default OFF: the Monitor Mode plugin popout is the visual feedback now.
# Set MODE_NOTIFY=1 (env) to re-enable, or delete this function + its one call site.
notify_mode() {
  [ "${MODE_NOTIFY:-0}" = "1" ] || return 0
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send -a "MangoWM" -t 2500 "Window mode" "$1"
}
# ------------------------------------------------------------------------------

die() { echo "set-monitor-mode: $*" >&2; exit 1; }

# Parse args into a "MON mode" list (accepts "MON mode" pair or "MON:mode" tokens).
declare -a PAIRS=()
if [ "$#" -eq 2 ] && [[ "$1" != *:* ]]; then
  PAIRS=("$1 $2")
elif [ "$#" -ge 1 ]; then
  for tok in "$@"; do
    [[ "$tok" == *:* ]] || die "bad arg '$tok' (want MON:mode, e.g. MONITOR-1:float)"
    PAIRS+=("${tok%%:*} ${tok##*:}")
  done
else
  die "usage: $0 <MON> <tile|float> | <MON>:<mode> [<MON>:<mode>...]"
fi

# Normalize/validate modes, build the map string awk consumes (MON=float|tile ...).
MAP=""
SUMMARY=""
for p in "${PAIRS[@]}"; do
  mon="${p%% *}"; mode="${p##* }"
  case "$mode" in
    tile|tiling|tiled)   mode="tile" ;;
    float|floating|float*) mode="float" ;;
    *) die "bad mode '$mode' for $mon (want tile|float)" ;;
  esac
  grep -qE "^[[:space:]]*tagrule[^#]*monitor_name:[[:space:]]*$mon([,[:space:]]|$)" "$CONFIG" \
    || die "no tagrules for monitor '$mon' in $CONFIG"
  MAP+="$mon=$mode "
  label=$([ "$mode" = "float" ] && echo "Floating" || echo "Tiling")
  SUMMARY+="${SUMMARY:+, }$mon → $label"
done

# Rewrite the matching tagrules: strip any existing float keyword, then re-add it
# for FLOATING monitors. Idempotent regardless of start state. The float keyword
# itself comes from MANGO_FLOAT_TOKEN above (passed to awk as `tok`).
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
awk -v map="$MAP" -v tok="$MANGO_FLOAT_TOKEN" '
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
          # drop any existing "<float keyword>:N" (with its leading comma/space)
          gsub("[[:space:]]*,[[:space:]]*" tok ":[0-9]+", "", line)
          if (want[mon] == "float")
            line = line ", " tok ":1"
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

# Reload live (SUPER+r equivalent; works without a fresh login).
mango_reload_config

# printf %b to render the → arrow in the summary.
notify_mode "$(printf '%b' "$SUMMARY")"
echo "set-monitor-mode: $(printf '%b' "$SUMMARY")"

# Retroactively apply the new mode to ALREADY-OPEN windows on the monitors we just
# changed -- otherwise the mode only affects newly-opened windows. This is a ONE-SHOT
# sweep (a single pass, then it exits; NOT a continuous watcher), implemented as the
# `sweep` subcommand of dp2-floatsize.sh so it reuses the exact float/tile logic.
# Scoped to exactly the monitors in MAP. Backgrounded (setsid) so this setter -- and
# thus the plugin button / keybind that called it -- returns immediately.
# Disable with MODE_SWEEP=0 (env).
if [ "${MODE_SWEEP:-1}" = "1" ] && [ -x "$SWEEP" ]; then
  declare -a SWEEP_ARGS=()
  for kv in $MAP; do            # MAP is "MON=mode MON=mode "
    [ -n "$kv" ] && SWEEP_ARGS+=("${kv/=/:}")
  done
  [ "${#SWEEP_ARGS[@]}" -gt 0 ] && setsid "$SWEEP" sweep "${SWEEP_ARGS[@]}" >/dev/null 2>&1 &
fi
