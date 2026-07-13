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
LAYOUT="$HOME/.config/mango/dms/layout.conf"      # DMS-generated gaps/border (read for the effective outer gap)
OUTPUTS="$HOME/.config/mango/dms/outputs.conf"    # DMS-generated monitor sizes (FALLBACK only; mango is queried live first)
DMS_SETTINGS="$HOME/.config/DankMaterialShell/settings.json"  # DMS config (read to learn which screen edge the DankBar is docked to)
# Lock file (stops two copies of the watcher running) and debug log file.
LOCK="${XDG_RUNTIME_DIR:-/tmp}/mango-dp2-floatsize.lock"
LOG="/tmp/dp2-floatsize.log"
# Remembers the last real tiled-window insets we measured ("L R T B"), so a float
# window can still match tiling even when NO monitor is tiling at that moment (e.g.
# you set every monitor to float). Insets are absolute px (outer gap + bar strip),
# identical on every monitor and resolution-independent, so this is safe to reuse.
INSETS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/mango-dp2-floatsize-insets"

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
#                     used to compute the float box), tags[].is_active,
#                     tags[].client_count
#   all-clients     : clients[].monitor, clients[].x/y/width/height,
#                     clients[].is_floating, clients[].is_fullscreen,
#                     clients[].is_namedscratchpad -- used to MEASURE the geometry
#                     a single tiled window gets (so a float window can match it)
mango_focused_client_json() { mmsg get focusing-client 2>/dev/null; }
mango_all_monitors_json()   { mmsg get all-monitors 2>/dev/null; }
mango_one_monitor_json()    { mmsg get monitor "$1" 2>/dev/null; }
mango_all_clients_json()    { mmsg get all-clients 2>/dev/null; }
mango_watch_monitors_json() { mmsg watch all-monitors 2>/dev/null; }

# --- 3. THE "FLOAT MODE" KEYWORD IN THE CONFIG ------------------------------
# A monitor counts as FLOATING when its tag rules in config.conf contain this
# word (written there as "open_as_floating:1"). This is MangoWM config syntax;
# if a future MangoWM renames it, change this one word to match.
MANGO_FLOAT_TOKEN="open_as_floating"

# --- 4. TUNING (safe to tweak any time; NOT tied to a MangoWM version) -------
# The float box is sized to match what a SINGLE TILED window gets on the same
# resolution, so floating and tiling look identical for one window. It is derived
# in two ways, best first:
#   1. MEASURED (preferred): read the geometry a real tiled window currently has
#      on any monitor that is in tiling mode, and reuse those exact edge insets
#      (outer gap on three sides, outer gap + bar strip on the bar's side). This
#      uses tiling's OWN output as the input -- nothing hardcoded, and it tracks
#      any gap/border/bar change automatically. Needs >=1 tiled window to exist
#      somewhere at the time (the usual case with per-monitor modes).
#   2. COMPUTED FALLBACK: if no tiled window exists to measure, rebuild the same
#      box from mango's config: window = monitor, inset by the OUTER GAP
#      (gappoh/gappov, read live from the effective config -- see effective_gap)
#      on every edge, minus the bar strip on the bar's edge. The bar strip has no
#      single config key, so bar_strip() derives it live from the adopter's own
#      DankBar settings (see that function); BAR_STRIP_FALLBACK below is only the
#      very last resort if even settings.json / jq can't be read.
# Both scale to any resolution (1080p / 1440p / 4K / ultrawide) automatically.
# ABSOLUTE last-resort bar strip (px), used ONLY if settings.json or jq are missing so
# bar_strip() can't derive the real value. This is the DMS DEFAULT bar (innerPadding 4,
# spacing 4, bottomGap 0 -> ~40px), NOT a personal number -- on any working system the
# derived value wins, and the first tiled window refreshes the real strip exactly.
BAR_STRIP_FALLBACK=40
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

# The OUTER gap (px) mango leaves between a tiled window and the screen edge,
# printed as "<horizontal> <vertical>". Read LIVE from the effective config so the
# COMPUTED-fallback float box uses the SAME numbers tiling does. Precedence: the
# DMS-generated dms/layout.conf wins (it is the LAST `source=` in config.conf, and
# that is the value mango actually applies), then any inline value in config.conf,
# then a sane default. gappoh/gappov are mango config keys -- if a future mango
# renames them, change the two grep patterns here.
effective_gap() {
  local gh gv f
  for f in "$LAYOUT" "$CONFIG"; do              # layout.conf first -> it wins
    [ -f "$f" ] || continue
    [ -n "${gh:-}" ] || gh="$(grep -oE '^[[:space:]]*gappoh[[:space:]]*=[[:space:]]*[0-9]+' "$f" 2>/dev/null | grep -oE '[0-9]+$' | tail -1)"
    [ -n "${gv:-}" ] || gv="$(grep -oE '^[[:space:]]*gappov[[:space:]]*=[[:space:]]*[0-9]+' "$f" 2>/dev/null | grep -oE '[0-9]+$' | tail -1)"
  done
  printf '%s %s\n' "${gh:-28}" "${gv:-28}"
}

# The vertical strip the DankBar reserves (its layer-shell exclusive zone), in px.
# DMS does NOT store this as a single setting -- DankBarWindow.qml COMPUTES it at
# runtime from the bar's own innerPadding / spacing / bottomGap. We mirror that
# (non-frame) formula from those adopter-configured values, read from settings.json
# with jq the same way bar_edge() does, so the cold-start fallback scales to whatever
# bar the adopter set up instead of a number baked in for one machine. DMS formula
# (DankBarWindow.qml): widgetThickness = max(20, 26 + innerPadding*0.6);
# effectiveBarThickness ~= widgetThickness + innerPadding + 4;
# reservedStrip = effectiveBarThickness + spacing + bottomGap. If a future DMS reworks
# the bar height, update this jq to match (it only affects the cold-start path).
bar_strip() {
  local v
  v="$(jq -r '
    (.barConfigs // []) | map(select(.enabled != false)) | (.[0] // {}) as $b
    | ($b.innerPadding // 4) as $ip
    | ($b.spacing // 4)      as $sp
    | ($b.bottomGap // 0)    as $bg
    | ([20, (26 + $ip * 0.6)] | max) as $wt
    | (($wt + $ip + 4) + $sp + $bg) | round
  ' "$DMS_SETTINGS" 2>/dev/null)"
  case "${v:-}" in ''|-*|*[!0-9]*) printf '%s' "$BAR_STRIP_FALLBACK"; return ;; esac
  printf '%s' "$v"
}

# Measure the edge insets (px) a SINGLE tiled window gets, printed as "L R T B", by
# reading real tiled windows off any monitor currently in TILING mode. This is
# tiling's OWN output reused directly as floating's target, so the two match to the
# pixel -- outer gaps, border, and the bar's reserved strip are all baked in, with
# nothing hardcoded. Prints nothing / returns 1 if there is no tiled window to
# measure right now (then load_target uses the computed fallback).
tiling_insets() {
  local mons m mx my mw mh bbox minx miny maxx maxy L R T B
  mons="$(mango_all_monitors_json | jq -r '.monitors[].name' 2>/dev/null)"
  [ -n "$mons" ] || return 1
  for m in $mons; do
    mon_is_floating "$m" && continue                 # need a TILING monitor
    read -r mx my mw mh <<<"$(mon_screen_geom "$m")"
    [ -n "${mw:-}" ] && [ "${mw:-0}" -gt 0 ] && [ "${mh:-0}" -gt 0 ] || continue
    # Bounding box of this monitor's REAL tiled windows. Skip floats, fullscreen and
    # scratchpads -- they don't sit in the tile layout and would distort the box.
    bbox="$(mango_all_clients_json | jq -r --arg m "$m" '
      [ (.clients // [])[] | select(.monitor==$m
          and ((.is_floating // false)|not)
          and ((.is_fullscreen // false)|not)
          and ((.is_namedscratchpad // false)|not)) ] as $c
      | if ($c|length) > 0 then
          "\([$c[].x]|min) \([$c[].y]|min) \([$c[]|(.x+.width)]|max) \([$c[]|(.y+.height)]|max)"
        else empty end' 2>/dev/null)"
    [ -n "$bbox" ] || continue
    read -r minx miny maxx maxy <<<"$bbox"
    L=$(( minx - mx )); T=$(( miny - my ))
    R=$(( mx + mw - maxx )); B=$(( my + mh - maxy ))
    # Sanity-gate the measurement: insets must be non-negative and a small fraction
    # of the screen. A rogue/off-screen window would give absurd values -> reject and
    # let the caller fall back rather than size a window wrong.
    if [ "$L" -ge 0 ] && [ "$R" -ge 0 ] && [ "$T" -ge 0 ] && [ "$B" -ge 0 ] \
       && [ "$L" -lt $(( mw / 4 )) ] && [ "$R" -lt $(( mw / 4 )) ] \
       && [ "$T" -lt $(( mh / 4 )) ] && [ "$B" -lt $(( mh / 4 )) ]; then
      printf '%s %s %s %s\n' "$L" "$R" "$T" "$B"; return 0
    fi
  done
  return 1
}

# Persist / recall the last good insets "L R T B" (see INSETS_CACHE up top). The
# reader validates the file is exactly four non-negative integers before trusting it,
# so a truncated/garbage cache is ignored rather than sizing a window wrong.
cache_write_insets() { mkdir -p "$(dirname "$INSETS_CACHE")" 2>/dev/null && printf '%s\n' "$1" >"$INSETS_CACHE" 2>/dev/null || true; }
cache_read_insets() {
  [ -f "$INSETS_CACHE" ] || return 1
  local a b c d _rest
  read -r a b c d _rest <"$INSETS_CACHE" || return 1
  [ -n "${d:-}" ] || return 1
  case "$a$b$c$d" in ""|*[!0-9]*) return 1 ;; esac
  printf '%s %s %s %s\n' "$a" "$b" "$c" "$d"
}

# Compute the float target for a SPECIFIC monitor into globals X/Y/W/H: a box sized
# and placed to match what a SINGLE TILED window gets on that monitor, so floating
# and tiling look identical for one window. The insets (edge margins) are found best
# first: (1) MEASURED live from a real tiled window (tiling_insets) and cached; (2)
# the last CACHED measurement, for when nothing is tiled right now (e.g. every
# monitor set to float); (3) COMPUTED from config gaps + a bar-strip estimate, only
# if we have never measured. All three are resolution-independent -- no captured
# coordinates, nothing per-machine. Falls back to a small box only if res is unknown.
load_target() {
  local mon=$1 mx my mw mh insets L R T B edge go_h go_v top_off usable_h bar
  read -r mx my mw mh <<<"$(mon_screen_geom "$mon")"
  if [ -z "${mw:-}" ] || [ "${mw:-0}" -le 0 ] || [ "${mh:-0}" -le 0 ]; then
    X=100 ; Y=100 ; W=1280 ; H=720; return          # resolution unknown -> safe box
  fi
  # PREFERRED: reuse the exact insets a real tiled window has right now (and remember
  # them). If nothing is tiled to measure, reuse the last measurement we cached.
  if insets="$(tiling_insets)"; then
    cache_write_insets "$insets"
  else
    insets="$(cache_read_insets)" || insets=""
  fi
  if [ -n "$insets" ]; then
    read -r L R T B <<<"$insets"
    X=$(( mx + L )); Y=$(( my + T ))
    W=$(( mw - L - R )); H=$(( mh - T - B ))
    return
  fi
  # COMPUTED FALLBACK (never measured yet): rebuild from config gaps + bar-strip est.
  read -r go_h go_v <<<"$(effective_gap)"
  edge="$(bar_edge)"
  bar="$(bar_strip)"                                  # DankBar reserved strip (derived)
  case "$edge" in
    top|bottom) usable_h=$(( mh - bar )) ;;           # bar eats a strip on one edge
    *)          usable_h=$mh ;;                        # no top/bottom bar -> full height
  esac
  # A top bar reserves its strip ABOVE the window; a bottom bar reserves it BELOW,
  # so the box still starts one outer-gap down from the monitor top.
  [ "$edge" = top ] && top_off=$bar || top_off=0
  W=$(( mw - 2 * go_h ))
  H=$(( usable_h - 2 * go_v ))
  X=$(( mx + go_h ))
  Y=$(( my + top_off + go_v ))
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
