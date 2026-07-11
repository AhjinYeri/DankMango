#!/usr/bin/env bash
#
# =============================================================================
#  dp2-floatsize.sh  --  per-monitor window placement helper for MangoWM
# =============================================================================
#
#  >>> IF SOMETHING STOPPED WORKING AFTER A SYSTEM UPDATE, START HERE <<<
#
#  Almost everything that can break when MangoWM (the window manager) or DMS
#  (the desktop shell) updates lives in ONE place: the box further down marked
#       "########## EDIT HERE AFTER A MANGO / DMS UPDATE ##########".
#  You do NOT need to read or understand the rest of this file. Open that box,
#  read the plain-English comments, and adjust the commands so they match the
#  new version. Everything below the box is just logic that uses those commands
#  and should not need changing.
#
#  A friendly plain-English guide is in the plugin folder:
#       ~/.config/DankMaterialShell/plugins/monitorMode/README.md
#
# -----------------------------------------------------------------------------
#  WHAT THIS SCRIPT DOES (plain English)
# -----------------------------------------------------------------------------
#  Each monitor is either in TILING mode or FLOATING mode. Which one is decided
#  by your MangoWM config file (a monitor is "floating" if its tag rules contain
#  the word open_as_floating). This script just enforces that choice whenever a
#  window appears on a monitor:
#    * Floating monitor -> make the window float and CENTER it at a size
#      proportional to that monitor (~85% of its resolution -- a big,
#      "Windows-11 style" window). Computed live per monitor, so it works on
#      any resolution (1080p, 1440p, 4K, ultrawide) with no manual setup.
#    * Tiling monitor   -> if a window was dragged in still floating, un-float it
#      so the tiling layout takes over.
#  It runs continuously in the background (started once when you log in, via the
#  "exec-once" line in config.conf).
#
#  Why a script is needed at all: MangoWM can open windows floating, but it
#  cannot set a proportional per-monitor SIZE/POSITION for them, and it cannot
#  auto-tile a window you drag onto a tiling monitor. This script fills those
#  two gaps -- the float size/position is derived from each monitor's live
#  resolution, so there is NOTHING to configure or capture per machine.
#
set -uo pipefail

# #############################################################################
# ########## EDIT HERE AFTER A MANGO / DMS UPDATE #############################
# #############################################################################
# Everything in this box is "version-specific": the exact commands and words
# that MangoWM / DMS understand. If an update renames a command or changes how
# the config is written, fix it HERE and the rest of the script keeps working.

# --- 1. FILE PATHS ----------------------------------------------------------
# Where things live on disk. Change these only if you move your config around.
CONFIG="$HOME/.config/mango/config.conf"          # MangoWM main config (read to learn each monitor's mode)
OUTPUTS="$HOME/.config/mango/dms/outputs.conf"    # DMS-generated monitor sizes (FALLBACK only; mango is queried live first)
DMS_SETTINGS="$HOME/.config/DankMaterialShell/settings.json"  # DMS config (read to learn which screen edge the DankBar is docked to)
# Lock file (stops two copies of the watcher running) and debug log file.
LOCK="${XDG_RUNTIME_DIR:-/tmp}/mango-dp2-floatsize.lock"
LOG="/tmp/dp2-floatsize.log"

# --- 2. COMMANDS THAT TALK TO MANGOWM ---------------------------------------
# These five wrappers are the ONLY places this script calls MangoWM's "mmsg"
# tool. MangoWM 0.14 rewrote mmsg into "mmsg dispatch / get / watch" (the older
# 0.13 form "mmsg -s -d ..." is dead and silently does nothing). If a future
# update changes mmsg again, edit the command inside these five functions only.
#
#   OLD (mango 0.13, dead)      NEW (mango 0.14, what we use now)
#   mmsg -s -d <action>,args -> mmsg dispatch <action>,args
#   mmsg -o <mon> -g ...     -> mmsg get focusing-client   (JSON)
#   mmsg -g -o               -> mmsg get all-monitors      (JSON)
#   (no list existed)        -> mmsg get monitor <name>    (JSON)
#   mmsg -w -t               -> mmsg watch all-monitors    (JSON stream)

# Run a MangoWM ACTION (we don't read any output). The script uses these action
# names through this wrapper: togglefloating, resizewin, movewin, focusmon,
# focusstack. If an update RENAMES an action, search this file for that word.
mango_dispatch()            { mmsg dispatch "$1" >/dev/null 2>&1; }

# Ask MangoWM for information as JSON. The `jq` lines further down read these
# JSON FIELD names from the output; if an update renames a field, update the
# matching jq line (the field names are listed here so you know what to look for):
#   focusing-client : monitor, x, y, width, height, is_floating, is_maximized,
#                     is_fullscreen, appid
#   all-monitors    : monitors[].name, monitors[].active
#   monitor <name>  : x, y, width, height (the monitor's live resolution/position,
#                     used to compute the centered proportional float box),
#                     tags[].is_active, tags[].client_count
mango_focused_client_json() { mmsg get focusing-client 2>/dev/null; }
mango_all_monitors_json()   { mmsg get all-monitors 2>/dev/null; }
mango_one_monitor_json()    { mmsg get monitor "$1" 2>/dev/null; }
mango_watch_monitors_json() { mmsg watch all-monitors 2>/dev/null; }

# --- 3. THE "FLOAT MODE" KEYWORD IN THE CONFIG ------------------------------
# A monitor counts as FLOATING when its tag rules in config.conf contain this
# word (written there as "open_as_floating:1"). This is MangoWM config syntax;
# if a future MangoWM renames it, change this one word to match.
MANGO_FLOAT_TOKEN="open_as_floating"

# --- 4. TUNING (safe to tweak any time; NOT tied to a MangoWM version) -------
# The float box is computed PROPORTIONALLY from each monitor's live resolution:
#   width  = FLOAT_PCT% of the monitor width
#   height = FLOAT_PCT% of the monitor height MINUS the bar strip
#   position = centered in the area NOT covered by the bar
# So it scales to any resolution (1080p / 1440p / 4K / ultrawide) automatically.
FLOAT_PCT=95          # window size as a percentage of the monitor (try 80-90)
BAR_SIZE=44           # pixels reserved for the DankBar strip (its thickness)
# Which screen edge the DankBar is docked to. Leave EMPTY to auto-detect from
# DMS settings (barConfigs[].position: 0=top, 1=bottom). Set to "top" or
# "bottom" to FORCE a value if auto-detect is wrong or DMS_SETTINGS is missing.
# (Anything other than top/bottom -- e.g. a vertical bar -- reserves nothing
# vertically; adjust here if you dock the bar left/right.)
BAR_EDGE=""           # "", "top", or "bottom"
# How close (in pixels) a window must already be to the target before we leave
# it alone (prevents pointless re-positioning / flicker).
TOL=60
# Apps that manage their own size/fullscreen (real games): NEVER touch these.
# Add an appid here if some game keeps getting resized. NOTE: the Steam CLIENT
# itself (appid "steam") is deliberately NOT in this list, so it follows the
# monitor's mode like any normal app; only actual GAMES launched from Steam
# (appid steam_app_NNN) and other launchers below are skipped.
GAME_APPID_RE='steam_app_[0-9]+|gamescope|\.exe$|lutris|heroic|com\.heroicgameslauncher|bottles|com\.usebottles|^cs2$|hl2_linux|RetroArch|org\.libretro|dolphin-emu|pcsx2|rpcs2|ppsspp|yuzu|ryujinx'
# Set DP2_DEBUG=1 (env) to write a debug log to $LOG: tail -f /tmp/dp2-floatsize.log
DP2_DEBUG="${DP2_DEBUG:-0}"

# #############################################################################
# ########## END OF EDIT-HERE BOX -- logic below should stay stable ###########
# #############################################################################

log() { [ "$DP2_DEBUG" = 1 ] && printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >>"$LOG"; }

# --- queries built on the version-specific commands above --------------------
# Geometry "x y w h" of the SELECTED client on monitor $1. Callers always pass
# the focused monitor, so we read the globally-focused client and confirm it's
# on $1.
mon_geom() {
  mango_focused_client_json \
    | jq -r --arg m "$1" 'select(.monitor==$m) | "\(.x) \(.y) \(.width) \(.height)"'
}
# Name of the focused (active) monitor.
focused_mon() {
  mango_all_monitors_json \
    | jq -r 'first(.monitors[] | select(.active) | .name) // empty'
}
abs()         { local n=$1; echo "${n#-}"; }

# Which edge the DankBar is docked to: "top" or "bottom" (anything else = no
# vertical reservation). Honors the BAR_EDGE override first; otherwise reads it
# live from DMS settings.json -> first enabled barConfigs entry's `position`
# (DMS enum: 0=top, 1=bottom). If DMS renames that field/enum, fix the jq here.
# Falls back to "top" (the DMS default) only if nothing is readable.
bar_edge() {
  case "${BAR_EDGE:-}" in top|bottom|none) printf '%s' "$BAR_EDGE"; return 0 ;; esac
  local pos
  pos="$(jq -r '(.barConfigs // []) | map(select(.enabled != false)) | (.[0].position // empty)' \
          "$DMS_SETTINGS" 2>/dev/null)"
  case "$pos" in
    0) printf 'top' ;;
    1) printf 'bottom' ;;
    *) printf 'top' ;;            # unknown/unreadable -> DMS default; set BAR_EDGE to override
  esac
}

# A monitor is FLOATING-mode iff its tagrules in config.conf carry the float
# keyword. Read live each time so a config swap + reload takes effect without
# restarting this script.
mon_is_floating() {
  grep -E "^[[:space:]]*tagrule[^#]*monitor_name:[[:space:]]*$1([,[:space:]]|$)" "$CONFIG" 2>/dev/null \
    | grep -qE "$MANGO_FLOAT_TOKEN:[[:space:]]*1"
}

# Monitor's own screen rectangle (x y w h). Queried LIVE from MangoWM first
# (resolution-independent, no captured or machine-specific files), so it reflects
# the actual monitor even after a resolution change. Falls back to parsing the
# DMS-generated outputs.conf only if the live query returns nothing.
# (If a MangoWM update renames the JSON geometry fields, fix the jq line here;
#  if a DMS update changes outputs.conf's format, adjust the fallback awk.)
mon_screen_geom() {
  local live
  live="$(mango_one_monitor_json "$1" \
    | jq -r 'select(.width and .height) | "\(.x) \(.y) \(.width) \(.height)"' 2>/dev/null)"
  if [ -n "$live" ]; then printf '%s\n' "$live"; return 0; fi
  awk -v m="$1" '
    $0 ~ ("name:" m ",") {
      x=y=w=h=""
      n=split($0, a, /[,=]/)
      for (i=1;i<=n;i++) { split(a[i], kv, ":");
        if (kv[1]=="x") x=kv[2]; else if (kv[1]=="y") y=kv[2];
        else if (kv[1]=="width") w=kv[2]; else if (kv[1]=="height") h=kv[2] }
      print x, y, w, h; exit
    }' "$OUTPUTS" 2>/dev/null
}

# Compute the float target for a SPECIFIC monitor into globals X/Y/W/H:
# a box FLOAT_PCT% of the monitor's live resolution, CENTERED in the area the
# DankBar does NOT cover (its strip is reserved on whichever edge the bar is
# docked to -- top or bottom). Fully resolution-independent -- no captured
# coordinates, nothing per-machine. Falls back to a small centered box only if
# the resolution is somehow unknown.
load_target() {
  local mon=$1 mx my mw mh avail edge top_off
  read -r mx my mw mh <<<"$(mon_screen_geom "$mon")"
  if [ -n "${mw:-}" ] && [ "${mw:-0}" -gt 0 ] && [ "${mh:-0}" -gt 0 ]; then
    edge="$(bar_edge)"
    case "$edge" in
      top|bottom) avail=$(( mh - BAR_SIZE )) ;;  # bar eats a strip on one edge
      *)          avail=$mh ;;                    # no top/bottom bar -> full height
    esac
    # Offset of the usable area from the monitor top: BAR_SIZE for a top bar, 0
    # otherwise (a bottom bar reserves its strip BELOW the window, so the box
    # starts at the monitor top).
    [ "$edge" = top ] && top_off=$BAR_SIZE || top_off=0
    W=$(( mw * FLOAT_PCT / 100 ))
    H=$(( avail * FLOAT_PCT / 100 ))
    X=$(( mx + (mw - W) / 2 ))                     # centered horizontally
    Y=$(( my + top_off + (avail - H) / 2 ))        # centered in the un-barred area
  else
    X=100 ; Y=100 ; W=1280 ; H=720
  fi
}

# A new/arrived window grabs focus on its monitor; only act if that monitor is the
# focused one, so we never touch the wrong monitor's selected client. Returns the
# floating/fullscreen/appid state via globals isf/ism/appid, or non-zero to bail.
inspect_arrival() {
  local mon=$1
  [ "$(focused_mon)" = "$mon" ] || { log "  skip: $mon not focused"; return 1; }
  sleep 0.12
  [ "$(focused_mon)" = "$mon" ] || { log "  skip: $mon lost focus after settle"; return 1; }
  # One JSON fetch -> floating flag, maximized/fullscreen flag, appid.
  IFS='|' read -r isf ism appid < <(
    mango_focused_client_json | jq -r --arg m "$mon" '
      select(.monitor==$m)
      | "\(if .is_floating then 1 else 0 end)|\(if (.is_maximized or .is_fullscreen) then 1 else 0 end)|\(.appid // "")"'
  )
  [ "$ism" = 1 ] && { log "  skip: maximized/fullscreen"; return 1; }
  printf '%s' "$appid" | grep -qiE "$GAME_APPID_RE" && { log "  skip: game/self-managing"; return 1; }
  return 0
}

# FLOATING monitor: ensure the window floats, then size+position it.
size_window() {
  local mon=$1 cx cy cw ch tries=0
  inspect_arrival "$mon" || return 0
  load_target "$mon"
  read -r cx cy cw ch <<<"$(mon_geom "$mon")"
  log "  float-mon state: floating=$isf appid=$appid cur=${cw}x${ch}@${cx},${cy}"
  # Already floating AND already at target -> nothing to do (and nothing to flicker).
  if [ "$isf" = 1 ] && [ -n "${cw:-}" ] && [ -n "${cx:-}" ] \
     && [ "$(abs $((cw-W)))" -le "$TOL" ] && [ "$(abs $((ch-H)))" -le "$TOL" ] \
     && [ "$(abs $((cx-X)))" -le "$TOL" ] && [ "$(abs $((cy-Y)))" -le "$TOL" ]; then
    log "  skip: already at target ${cw}x${ch}@${cx},${cy}"; return 0
  fi
  # A window dragged in from a tiling monitor arrives TILED (stacked below the floats,
  # full-monitor in the tile layout). Float it -- but do NOT pause afterward: a
  # tiled->float toggle RESTORES the window's previous float geometry, i.e. its old
  # spot on the SOURCE monitor. Any dwell here paints a visible jump back to that
  # monitor (the inconsistent "bounce" -- it only showed when the restored geom wasn't
  # already on target). Reposition in the same breath below so it never paints there.
  if [ "$isf" != 1 ]; then
    log "  arrived tiled on float-mon -> floating it + repositioning immediately"
    mango_dispatch togglefloating
  fi
  # Size + position with NO settle before the move. movewin takes absolute global coords,
  # so a single move lands it on this monitor in one step. Position is issued LAST so it
  # wins over the resize.
  log "  apply: resizewin,$W,$H -> movewin,$X,$Y"
  mango_dispatch resizewin,"$W","$H"
  mango_dispatch movewin,"$X","$Y"
  # Verify + re-assert until it sticks. Covers the float-restore above, a terminal
  # re-centering after its char-cell size snap, and any monitor-frame settle after a
  # drag -- without a fixed pre-move dwell that would show the bounce.
  while :; do
    sleep 0.12
    read -r cx cy cw ch <<<"$(mon_geom "$mon")"
    if [ -n "${cx:-}" ] \
       && [ "$(abs $((cx-X)))" -le "$TOL" ] && [ "$(abs $((cy-Y)))" -le "$TOL" ] \
       && [ "$(abs $((cw-W)))" -le "$TOL" ] && [ "$(abs $((ch-H)))" -le "$TOL" ]; then
      log "  landed: ${cw}x${ch}@${cx},${cy}"; return 0
    fi
    tries=$((tries+1))
    if [ "$tries" -ge 5 ]; then
      log "  gave up re-asserting after $tries tries (at ${cx:-?},${cy:-?})"; return 0
    fi
    log "  re-asserting ($tries): now ${cw:-?}x${ch:-?}@${cx:-?},${cy:-?}"
    mango_dispatch resizewin,"$W","$H"
    mango_dispatch movewin,"$X","$Y"
  done
}

# TILING monitor: a window was dragged in still floating -> un-float so it tiles.
tile_window() {
  local mon=$1
  inspect_arrival "$mon" || return 0
  log "  tile-mon state: floating=$isf appid=$appid"
  [ "$isf" = 1 ] || { log "  skip: already tiled"; return 0; }
  log "  arrived floating on tile-mon -> un-floating to tile"
  mango_dispatch togglefloating
}

# Route an arrival to the right enforcer based on the monitor's live mode.
# kind = move (dragged between monitors) | fresh (newly spawned).
handle_arrival() {
  local mon=$1 kind=$2
  if mon_is_floating "$mon"; then
    size_window "$mon"                       # float+size on both fresh open and drag-in
  else
    # Tiling monitor: only RE-tile windows that were dragged in (a move). A freshly
    # spawned float-by-type dialog also raises this monitor's count, but as a fresh
    # open (global total +1), so it is left floating as the app intended.
    [ "$kind" = move ] && tile_window "$mon"
  fi
}

# ===== one-shot retroactive sweep (subcommand) ================================
# Triggered by set-monitor-mode.sh AFTER a mode change, to apply the new mode to
# windows that were ALREADY open (mode otherwise only affects newly-opened windows).
# It does a SINGLE bounded pass over each named monitor's current windows, then exits
# -- it is NOT a watcher. It reuses the exact same per-window logic as live arrivals:
#   * float-mode monitor -> size_window (float-if-tiled + centered proportional box)
#   * tile-mode  monitor -> tile_window (un-float so it re-tiles)
# Game/Steam/fullscreen windows are skipped by inspect_arrival, same as everywhere.
# Because both functions are idempotent (skip already-correct windows), revisiting a
# window during focus-cycling is harmless.

# Count visible clients on a monitor (sum of client_count over its active tags).
clients_on() {
  mango_one_monitor_json "$1" \
    | jq -r '[.tags[] | select(.is_active) | .client_count] | add // 0'
}

# Focus a monitor BY NAME (mango's focusmon only takes a direction): step toward the
# target by comparing screen-rect x, bounded so we never spin. Monitor-agnostic.
focus_monitor() {
  local target=$1 cur tx cx tries=0
  read -r tx _ _ _ <<<"$(mon_screen_geom "$target")"
  while [ "$tries" -lt 6 ]; do
    cur="$(focused_mon)"; [ "$cur" = "$target" ] && return 0
    read -r cx _ _ _ <<<"$(mon_screen_geom "$cur")"
    if [ -n "${cx:-}" ] && [ -n "${tx:-}" ] && [ "$cx" -gt "$tx" ] 2>/dev/null; then
      mango_dispatch focusmon,left
    else
      mango_dispatch focusmon,right
    fi
    sleep 0.08; tries=$((tries+1))
  done
  [ "$(focused_mon)" = "$target" ]
}

# One pass over a monitor's open windows, applying mode (float|tile) to each.
sweep_monitor() {
  local mon=$1 mode=$2 n i
  focus_monitor "$mon" || { log "sweep: could not focus $mon -- skipping"; return 0; }
  n="$(clients_on "$mon")"
  log "sweep $mon mode=$mode clients=$n"
  [ "${n:-0}" -ge 1 ] || return 0
  for ((i=0; i<n; i++)); do
    if [ "$mode" = float ]; then size_window "$mon"; else tile_window "$mon"; fi
    [ "$n" -gt 1 ] && { mango_dispatch focusstack,next; sleep 0.06; }
  done
}

if [ "${1:-}" = sweep ]; then
  shift
  # Don't let two sweeps overlap (e.g. rapid re-presses) and fight over focus.
  SWEEP_LOCK="${XDG_RUNTIME_DIR:-/tmp}/mango-mode-sweep.lock"
  exec 8>"$SWEEP_LOCK"; flock -n 8 || { echo "mode-sweep: already running" >&2; exit 0; }
  start_mon="$(focused_mon)"               # restore focus afterward
  for tok in "$@"; do
    smon="${tok%%:*}"; smode="${tok#*:}"
    # "MON" with no ":mode" -> read the monitor's live mode from config.
    [ "$smode" = "$tok" ] && { mon_is_floating "$smon" && smode=float || smode=tile; }
    case "$smode" in
      tile|tiling|tiled)    smode=tile ;;
      float|floating|float*) smode=float ;;
      *) log "sweep: bad mode '$smode' for $smon -- skipping"; continue ;;
    esac
    sweep_monitor "$smon" "$smode"
  done
  [ -n "${start_mon:-}" ] && focus_monitor "$start_mon" >/dev/null 2>&1
  exit 0
fi

# Acquire the WATCHER single-instance lock now -- LATER than the path was defined,
# so the `sweep` subcommand above (which runs while the persistent watcher already
# holds this lock) doesn't fail the flock and bail. Survives reloads.
exec 9>"$LOCK"; flock -n 9 || { echo "dp2-floatsize: already running" >&2; exit 0; }

# --- event stream ------------------------------------------------------------
# `mmsg watch all-monitors` emits a full JSON snapshot of every monitor on each
# change. jq reshapes each snapshot into one "<mon> <count>" line per monitor
# (count = visible clients = sum of client_count over the monitor's active tags),
# reproducing the simple text stream this loop was built on. Events for one user
# action arrive as a quick burst, so we drain each burst, then compare the net
# per-monitor delta to classify move vs fresh.
declare -A cnt base
snapshot() { local m s=""; for m in "${!cnt[@]}"; do s+="$m=${cnt[$m]} "; done; echo "$s"; }

exec 3< <(mango_watch_monitors_json \
  | jq -rc --unbuffered '.monitors[] | "\(.name) \([.tags[]|select(.is_active)|.client_count]|add // 0)"')

# Prime baseline from the initial full-state dump (no actions).
IFS=' ' read -r -u 3 mon val _ || exit 0
[ -n "$mon" ] && cnt[$mon]=$val
while IFS=' ' read -t 0.6 -r -u 3 mon val _; do
  [ -n "$mon" ] && cnt[$mon]=$val
done
for m in "${!cnt[@]}"; do base[$m]=${cnt[$m]}; done
log "=== started; floating-mons from config; baseline $(snapshot)==="

evaluate_batch() {
  local m d total=0 risers=()
  for m in "${!cnt[@]}"; do
    d=$(( ${cnt[$m]} - ${base[$m]:-0} ))
    total=$(( total + d ))
    [ "$d" -gt 0 ] && risers+=("$m")
  done
  if [ ${#risers[@]} -gt 0 ]; then
    local kind=move
    [ "$total" -gt 0 ] && kind=fresh        # net +1 window in the system -> fresh open
    for m in "${risers[@]}"; do
      log "arrival on $m: kind=$kind (${base[$m]:-0} -> ${cnt[$m]}, totalΔ=$total)"
      handle_arrival "$m" "$kind"
    done
  fi
  for m in "${!cnt[@]}"; do base[$m]=${cnt[$m]}; done
}

# Main loop: block for the first line of a batch, drain the rest of the burst,
# then evaluate once.
while IFS=' ' read -r -u 3 mon val _; do
  [ -n "$mon" ] && cnt[$mon]=$val
  while IFS=' ' read -t 0.25 -r -u 3 mon val _; do
    [ -n "$mon" ] && cnt[$mon]=$val
  done
  evaluate_batch
done
