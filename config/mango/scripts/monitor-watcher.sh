#!/usr/bin/env bash
#
# =============================================================================
#  monitor-watcher.sh  --  react to monitors being plugged in / unplugged
# =============================================================================
#
#  >>> IF SOMETHING STOPPED WORKING AFTER A SYSTEM UPDATE, START HERE <<<
#
#  Everything version-specific lives in ONE place: the box below marked
#  "########## EDIT HERE AFTER A MANGO UPDATE ##########". Read its plain-English
#  comments and fix the commands to match the new version.
#
# -----------------------------------------------------------------------------
#  WHAT THIS SCRIPT DOES (plain English)
# -----------------------------------------------------------------------------
#  It runs in the background for the whole session (started from config.conf's
#  exec-once) and watches the compositor for monitors appearing/disappearing.
#  When the SET of connected monitors changes it does two independent things:
#
#  (a) TAGRULES -- fully automatic, silent.
#      mango stores per-monitor tag rules keyed by the literal output name, so a
#      new monitor has NO rules until generate-tagrules.sh is re-run. This does
#      that for you and reloads the config. Nothing to confirm, no notification.
#
#      The catch this handles: generate-tagrules.sh writes every monitor with the
#      TILE layout, which would silently throw away per-monitor layouts you set
#      with the Monitor Mode plugin. So we CAPTURE each monitor's current layout
#      first, regenerate, then RE-APPLY the captured layouts via
#      set-monitor-layout.sh.
#
#      That alone only protects monitors that stay PLUGGED IN across the regen. An
#      unplugged monitor drops out of tagrules.conf entirely, so there's nothing
#      left to capture and it used to come back on tile. Hence the persistent
#      LAYOUT MEMORY (see LAYOUT_MEMORY below): every layout change is recorded
#      against the monitor's name, and a monitor we've seen before comes back on
#      its own layout when you replug it. A monitor with no memory entry is
#      genuinely new and still gets tile, which is the right default for a
#      monitor nobody has configured yet.
#
#  (b) MAIN DISPLAY -- never automatic, always asks.
#      Your chosen "main display" is stored in the DankMango manifest under
#      .userPrefs.mainDisplay. If that monitor disconnects we pick a safe
#      temporary stand-in so anything keyed on the main display keeps working,
#      but we NEVER rewrite your stored choice behind your back -- we send a
#      notification with buttons and let you decide. Replug the real one and
#      everything goes back to normal with no further prompting.
#
#      If .userPrefs.mainDisplay is absent or unreadable this whole half goes
#      inert: one line in the log, then silence. No notification, no fallback,
#      no error. That's the CORRECT permanent behaviour for anyone who never
#      picked a main display -- it isn't a stub, don't "fix" it later.
#
# -----------------------------------------------------------------------------
#  WHERE THINGS ARE
# -----------------------------------------------------------------------------
#    log            /tmp/mango-monitor-watcher.log
#    single-instance lock  /tmp/mango-monitor-watcher.lock
#    effective main display (for consumers to read, see below)
#                   $XDG_RUNTIME_DIR/mango-monitor-watcher/effective-main-display
#    layout memory  $XDG_STATE_HOME/mango-monitor-watcher/layout-memory.json
#                   (persistent on purpose -- see the LAYOUT_MEMORY comment)
#
#  THE EFFECTIVE-MAIN-DISPLAY SEAM: the manifest holds what you CHOSE; that
#  runtime file holds what's actually usable RIGHT NOW (they only differ while
#  your chosen monitor is unplugged). Anything that needs "the main display" --
#  e.g. future Steam spawn logic -- should read that file and fall back to its
#  own default if it's missing. That keeps the "never silently reassign" rule
#  intact: the stand-in lives in runtime state, never in your stored preference.
#
#  USAGE:
#    monitor-watcher.sh              # run the watcher (this is what exec-once does)
#    monitor-watcher.sh --once       # do one tagrule regen + main-display check, exit
#    monitor-watcher.sh --status     # print what the watcher currently sees, exit
#    monitor-watcher.sh --remember DP-2 monocle    # record a layout (set-monitor-layout.sh calls this)
#    monitor-watcher.sh --forget DP-2              # make a monitor "new" again (--forget --all wipes it)
#
set -uo pipefail

# CMD lines are what docs-hub.sh's command list shows: a real, runnable command
# and a short description, separated by " :: ". They live here, next to the code
# that implements them, so the hub stores no copy of its own. Add a line when you
# add a flag worth showing; the fuller explanation stays in the Usage block above.
# CMD: ~/.config/mango/scripts/monitor-watcher.sh --status :: print what the monitor watcher currently sees
# CMD: ~/.config/mango/scripts/monitor-watcher.sh --once :: do one tagrule + main-display pass, then exit

# #############################################################################
# ########## EDIT HERE AFTER A MANGO UPDATE ###################################
# #############################################################################
# File paths, the compositor queries, and the notification command. Fix things
# HERE after an update.

# --- 1. FILE PATHS ----------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TAGRULES="$HOME/.config/mango/dms/tagrules.conf"      # generated per-monitor tagrules
GEN_TAGRULES="$SCRIPT_DIR/generate-tagrules.sh"       # writes the file above
SET_LAYOUT="$SCRIPT_DIR/set-monitor-layout.sh"        # re-applies a captured layout
MANIFEST="${XDG_STATE_HOME:-$HOME/.local/state}/dankmango/manifest.json"

# Persistent "which layout was this monitor last on" memory, so a monitor that's
# UNPLUGGED and later replugged comes back on its own layout instead of the tile
# default. (While unplugged it has no tagrules at all, so tagrules.conf can't be
# the memory -- the monitor has vanished from it.)
#
# This is STATE, not runtime: $XDG_RUNTIME_DIR is a tmpfs wiped at every reboot,
# which would lose the memory in exactly the case it exists for (unplug a monitor,
# reboot, replug). So it sits with this project's other persistent state --
# $XDG_STATE_HOME/dankmango holds the install manifest, $XDG_STATE_HOME/mango-health
# holds the health check's last-run versions.
# The GENERATED windowrules that send Steam games to the main display. mango's
# config is static -- a windowrule can't read a file at runtime -- so the rule has
# to be WRITTEN OUT with the monitor name baked in whenever the effective main
# display changes, exactly like dms/tagrules.conf. config.conf picks it up with
# `source-optional`, so a machine that never chose a main display just has no file
# and no rules (source-optional doesn't error on a missing file -- verified).
#
# NOT dms/windowrules.conf: that one belongs to DMS's Settings -> Window Rules tab
# (Modules/Settings/WindowRulesTab.qml writes it) and would be overwritten.
MAIN_RULES="$HOME/.config/mango/dms/mainmonitor.conf"

# What counts as "a Steam game" for the rule above. mango windowrule matchers take
# REGEX -- verified empirically: `appid:^zz_app_[0-9]+$` matched a window with appid
# zz_app_4711 and placed it on the named monitor while a DIFFERENT monitor was
# focused. That placement behaviour is the whole point: without it a game opens
# wherever the pointer/focus happens to be.
#
# To find a game's appid, launch it and run:
#     mmsg get all-clients | jq -r '.clients[].appid'
# then add a matcher here. The Steam CLIENT is deliberately NOT matched -- it keeps
# normal window behaviour (see the Rules section of config.conf).
STEAM_GAME_MATCHERS=(
  'appid:^steam_app_[0-9]+$'    # native + Proton titles launched by Steam
  'appid:^gamescope$'           # anything wrapped in gamescope
)

MEMORY_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mango-monitor-watcher"
LAYOUT_MEMORY="$MEMORY_DIR/layout-memory.json"
LAYOUT_MEMORY_LOCK="$MEMORY_DIR/layout-memory.lock"

# --- 2. TALKING TO MANGOWM --------------------------------------------------
# The one-shot query listing CONNECTED outputs, and the event stream that emits a
# full snapshot whenever anything about the monitors changes.
#   mango 0.13 (DEAD): mmsg -g -o   /  mmsg -w -t
#   mango 0.14+ (now): mmsg get all-monitors  /  mmsg watch all-monitors
# To test by hand:  mmsg get all-monitors | jq '.monitors[].name'
#
# NOTE: `mmsg get all-monitors` lists ONLY CONNECTED outputs, and its ".active"
# field means FOCUSED, not connected -- an idle-but-plugged-in monitor is
# active:false. So presence == "the name is in the array". Never filter on
# .active here.
#
# NO SETTLE DELAY IS NEEDED HERE, and that was MEASURED, not assumed -- don't add
# a speculative `sleep` if something looks flaky. Probed on 2026-07-31 (mango 0.14,
# DP-1 2560x1440 + DP-2 1920x1080) by querying immediately on the watch event and
# again at +50/100/250/500/1000ms:
#   unplug DP-2: +0ms already reported exactly [DP-1@0,0 2560x1440] and never changed through +1943ms
#   replug DP-2: +0ms already reported both outputs with final geometry, unchanged through +1920ms
# So `mmsg watch` fires AFTER the compositor has settled the output state: the
# first `mmsg get all-monitors` is complete and correct. (The old dp2-floatsize.sh
# `sleep 0.12` settles were for WINDOW geometry after focus/move -- a different
# subsystem, and no evidence about hotplug either way.) If a future mango version
# regresses this, re-probe before picking a number, and record the numbers here.
mango_monitors_json() { mmsg get all-monitors 2>/dev/null; }
mango_watch_monitors_json() { mmsg watch all-monitors 2>/dev/null; }
mango_reload_config() { mmsg dispatch reload_config >/dev/null 2>&1 || true; }

# --- 3. NOTIFICATIONS -------------------------------------------------------
# DMS's notification server supports real clickable ACTION BUTTONS
# (NotificationService.qml: actionsSupported: true), and libnotify's
# `notify-send -A key=Label` round-trips the clicked key back to us on stdout.
# `dms ipc call toast ...` is NOT usable here -- toasts are text-only.
# APP_NAME is what DMS matches its per-app notification rules against, so keep it
# stable and recognisable (it's how you'd mute this script deliberately).
APP_NAME="DankMango"
NOTIFY_CMD=(notify-send)

# Buttons only appear when the popup is HOVERED (NotificationPopup.qml gates the
# button Row on cardHoverHandler.hovered), so bodies say "hover" on purpose.
#
# How long a background waiter will sit there waiting for a click before giving
# up. This exists because DMS drops pending notifications on a shell reload
# (NotificationServer keepOnReload: false), which would otherwise leave a waiter
# blocked forever on a notification that no longer exists.
WAITER_TIMEOUT=86400

# --- 4. LAYOUT NAMES --------------------------------------------------------
# Must match set-monitor-layout.sh's whitelist. We validate captured layouts
# against this before feeding them back, because that script uses `set -e` and
# would abort the whole re-apply on one unrecognised name.
VALID_LAYOUTS="tile monocle scroller grid deck center_tile"
DEFAULT_LAYOUT="tile"          # what generate-tagrules.sh gives a brand-new monitor

# #############################################################################
# ########## END OF EDIT-HERE BOX -- logic below should stay stable ###########
# #############################################################################

LOCK="/tmp/mango-monitor-watcher.lock"
LOG="/tmp/mango-monitor-watcher.log"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/mango-monitor-watcher"
EFFECTIVE_MAIN="$STATE_DIR/effective-main-display"

mkdir -p "$STATE_DIR" 2>/dev/null

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# log_once KEY MESSAGE -- for steady-state facts we don't want repeated on every
# hotplug (e.g. "no main display stored"). Keyed so different facts don't
# suppress each other.
declare -A _logged_once=()
log_once() {
  local key="$1"; shift
  [ -n "${_logged_once[$key]:-}" ] && return 0
  _logged_once[$key]=1
  log "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---- monitor queries --------------------------------------------------------

# Connected output names, sorted + deduped so a fingerprint is order-independent.
monitor_names() { mango_monitors_json | jq -r '.monitors[].name' 2>/dev/null | sed '/^[[:space:]]*$/d' | sort -u; }

# Fingerprint of the monitor SET (this is what we diff to detect a hotplug).
monitor_fingerprint() { monitor_names | paste -sd, -; }

# "name x width" per monitor, used to pick a stand-in main display.
monitor_geometry() { mango_monitors_json | jq -r '.monitors[] | "\(.name) \(.x) \(.width)"' 2>/dev/null; }

# The safe stand-in when the chosen main display is gone: LEFTMOST, tie-broken by
# LARGEST. Deterministic from data we already have, so it never depends on focus,
# ordering, or stored state -- the same unplug always yields the same answer.
fallback_main_display() {
  monitor_geometry | sort -k2,2n -k3,3nr | awk 'NR==1 {print $1}'
}

list_has() {  # list_has NEEDLE < list-on-stdin
  local needle="$1" line
  while IFS= read -r line; do [ "$line" = "$needle" ] && return 0; done
  return 1
}

# ---- persistent monitor -> layout memory ------------------------------------
#
# Shape: {"version":1,"monitors":{"DP-2":"monocle"}}
#
# Every layout change funnels through set-monitor-layout.sh (the Monitor Mode
# plugin shells out to it, and so does this watcher's re-apply), and that script
# calls `monitor-watcher.sh --remember MON LAYOUT` afterwards. Keeping the ONE
# implementation here means the setter needs no jq logic of its own -- and if this
# file is ever missing, the setter's hook fails harmlessly and layouts still work.

memory_get() {   # MON -> remembered layout, or nothing
  [ -r "$LAYOUT_MEMORY" ] || return 0
  have jq || return 0
  jq -r --arg m "$1" '.monitors[$m] // empty' "$LAYOUT_MEMORY" 2>/dev/null
}

memory_set() {   # MON LAYOUT -- create-or-update, atomic, concurrency-safe
  local mon="$1" lay="$2"
  have jq || return 1
  mkdir -p "$MEMORY_DIR" 2>/dev/null
  (
    # The plugin (user clicks a layout) and this watcher (hotplug re-apply) can
    # write at the same moment, so serialise the read-modify-write.
    flock -w 5 8 || exit 1
    # Re-seed if absent, empty, or corrupt -- a damaged memory file must never
    # block a layout change, and losing it only costs us the tile default.
    if ! jq -e . "$LAYOUT_MEMORY" >/dev/null 2>&1; then
      printf '%s\n' '{"version":1,"monitors":{}}' > "$LAYOUT_MEMORY"
    fi
    local tmp
    tmp="$(mktemp)" || exit 1
    if jq --arg m "$mon" --arg l "$lay" '.version = 1 | .monitors[$m] = $l' \
         "$LAYOUT_MEMORY" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      mv "$tmp" "$LAYOUT_MEMORY"
    else
      rm -f "$tmp"; exit 1
    fi
  ) 8>>"$LAYOUT_MEMORY_LOCK"
}

# ---- (a) tagrules: capture layouts -> regenerate -> re-apply -----------------

is_valid_layout() {
  local l
  for l in $VALID_LAYOUTS; do [ "$l" = "$1" ] && return 0; done
  return 1
}

# Read the CURRENT tagrules file into "MON<TAB>layout" lines, one per monitor.
# All 9 tagrules of a monitor carry the same layout_name, so first match wins.
capture_layouts() {
  [ -r "$TAGRULES" ] || return 0
  awk '
    /^[[:space:]]*tagrule/ {
      mon = ""; lay = ""
      if (match($0, /monitor_name:[ \t]*[^,[:space:]]+/))
        { mon = substr($0, RSTART, RLENGTH); sub(/monitor_name:[ \t]*/, "", mon) }
      if (match($0, /layout_name:[ \t]*[^,[:space:]]+/))
        { lay = substr($0, RSTART, RLENGTH); sub(/layout_name:[ \t]*/, "", lay) }
      if (mon != "" && lay != "" && !(mon in seen)) { seen[mon] = lay; print mon "\t" lay }
    }
  ' "$TAGRULES"
}

regenerate_tagrules() {
  [ -x "$GEN_TAGRULES" ] || { log "(a) generate-tagrules.sh not executable at $GEN_TAGRULES -- skipping tagrule regen"; return 1; }

  # 1. Capture what each monitor's layout is RIGHT NOW, before the generator
  #    flattens everything back to tile.
  declare -A saved=()
  local mon lay
  while IFS=$'\t' read -r mon lay; do
    [ -n "$mon" ] && saved[$mon]="$lay"
  done < <(capture_layouts)
  log "(a) captured layouts: $(for mon in "${!saved[@]}"; do printf '%s=%s ' "$mon" "${saved[$mon]}"; done)"

  # Fold what we just captured into the persistent memory. This is what makes the
  # memory self-seeding: layouts set before this feature existed (or by anything
  # that edited tagrules.conf directly) get remembered the first time we run,
  # without the user doing anything.
  for mon in "${!saved[@]}"; do
    [ "$(memory_get "$mon")" = "${saved[$mon]}" ] && continue
    memory_set "$mon" "${saved[$mon]}" \
      && log "(a) memory: $mon -> ${saved[$mon]}" \
      || log "(a) memory: FAILED to record $mon -> ${saved[$mon]}"
  done

  # 2. Regenerate (overwrites; safe to re-run -- never appends or duplicates).
  local genout
  genout="$("$GEN_TAGRULES" 2>&1)"
  local genrc=$?
  log "(a) generate-tagrules.sh rc=$genrc: $(printf '%s' "$genout" | tr '\n' '|')"
  [ "$genrc" -eq 0 ] || return 1

  # 3. Re-apply every captured layout that (i) belongs to a monitor that still
  #    exists, (ii) isn't already what the generator wrote, and (iii) is a name
  #    set-monitor-layout.sh will accept. Everything else keeps the tile default.
  local -a pairs=()
  while IFS= read -r mon; do
    [ -n "$mon" ] || continue
    lay="${saved[$mon]:-}"
    if [ -z "$lay" ]; then
      # No tagrule for this monitor a moment ago. Two very different cases: it's
      # RECONNECTING (we've seen it before and remember its layout), or it's
      # GENUINELY NEW (nothing remembered) and keeps the tile default by design.
      lay="$(memory_get "$mon")"
      if [ -n "$lay" ]; then
        log "(a) $mon reconnected -- restoring its remembered layout '$lay'"
      else
        log "(a) $mon is new (nothing remembered) -- keeping the $DEFAULT_LAYOUT default"
        continue
      fi
    fi
    [ "$lay" = "$DEFAULT_LAYOUT" ] && continue
    if ! is_valid_layout "$lay"; then
      log "(a) $mon had unrecognised layout '$lay' -- leaving it at $DEFAULT_LAYOUT"
      continue
    fi
    pairs+=("$mon:$lay")
  done < <(monitor_names)

  # set-monitor-layout.sh takes every pair in one call and reloads once itself.
  # With nothing to re-apply we still owe the config a reload so the freshly
  # generated rules take effect.
  if [ "${#pairs[@]}" -gt 0 ] && [ -x "$SET_LAYOUT" ]; then
    local setout
    setout="$("$SET_LAYOUT" "${pairs[@]}" 2>&1)"
    log "(a) re-applied layouts rc=$? [${pairs[*]}]: $(printf '%s' "$setout" | tr '\n' '|')"
  else
    [ "${#pairs[@]}" -gt 0 ] && log "(a) set-monitor-layout.sh missing at $SET_LAYOUT -- layouts NOT re-applied"
    mango_reload_config
    log "(a) reloaded config (no layouts needed re-applying)"
  fi
  return 0
}

# ---- (b) main display: stored preference vs. what's actually plugged in ------

# Empty output means "nothing stored" and "couldn't read it" alike; the caller
# treats both the same way (skip the branch silently), so there's no need to tell
# them apart.
stored_main_display() {
  [ -r "$MANIFEST" ] || return 0
  have jq || return 0
  jq -r '.userPrefs.mainDisplay // empty' "$MANIFEST" 2>/dev/null
}

# The ONLY writer of the stored preference -- and it only ever runs from a
# notification button the user actually clicked.
set_stored_main_display() {
  local name="$1" tmp
  [ -w "$MANIFEST" ] || { log "(b) manifest not writable at $MANIFEST -- cannot store main display"; return 1; }
  tmp="$(mktemp)" || return 1
  if jq --arg n "$name" '.userPrefs = ((.userPrefs // {}) | .mainDisplay = $n)' "$MANIFEST" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$MANIFEST"
    log "(b) stored main display -> $name (user clicked the button)"
    return 0
  fi
  rm -f "$tmp"
  log "(b) FAILED to store main display '$name' -- manifest left unchanged"
  return 1
}

write_effective_main() { printf '%s\n' "$1" > "$EFFECTIVE_MAIN" 2>/dev/null; }

# write_main_rules [NAME] -- regenerate MAIN_RULES for NAME (empty NAME = no main
# display chosen, so emit a header with no rules and let Steam behave normally).
# Reloads mango only when the file actually CHANGED, so the steady state costs
# nothing. Deliberately carries no timestamp: the content must be byte-stable for
# an unchanged main display, otherwise every hotplug would trigger a pointless
# reload (and reloads re-arrange tiled windows).
write_main_rules() {
  local name="${1:-}" tmp m
  mkdir -p "$(dirname "$MAIN_RULES")" 2>/dev/null
  tmp="$(mktemp)" || return 1
  {
    echo "# ==========================================================================="
    echo "# mainmonitor.conf  --  AUTO-GENERATED by scripts/monitor-watcher.sh."
    echo "# DO NOT hand-edit: it gets rewritten whenever the main display changes."
    echo "# Sourced by config.conf:  source-optional=~/.config/mango/dms/mainmonitor.conf"
    echo "#"
    if [ -n "$name" ]; then
      echo "# Main display: $name  -- Steam games open here instead of wherever the"
      echo "# pointer happens to be. Change it with: ./install.sh --reselect-main-display"
      echo "# ==========================================================================="
      for m in "${STEAM_GAME_MATCHERS[@]}"; do
        echo "windowrule = monitor:$name, $m"
      done
    else
      echo "# No main display chosen, so there are no rules here and Steam games open"
      echo "# wherever the pointer is (mango's normal behaviour). To choose one:"
      echo "#     ./install.sh --reselect-main-display"
      echo "# ==========================================================================="
    fi
  } > "$tmp"

  if cmp -s "$tmp" "$MAIN_RULES" 2>/dev/null; then
    rm -f "$tmp"; return 0                      # already correct, nothing to do
  fi
  # Validate before installing, the same guard set-monitor-layout.sh uses: a bad
  # fragment must never reach the live config.
  if ! mango -c "$tmp" -p >/dev/null 2>&1; then
    rm -f "$tmp"
    log "(b) generated main-display rules FAILED validation -- $MAIN_RULES left unchanged"
    return 1
  fi
  mv "$tmp" "$MAIN_RULES"
  mango_reload_config
  if [ -n "$name" ]; then
    log "(b) main-display windowrules -> $name (${#STEAM_GAME_MATCHERS[@]} matcher(s)); reloaded"
  else
    log "(b) main-display windowrules cleared (no main display chosen); reloaded"
  fi
  return 0
}

# ---- notifications ----------------------------------------------------------

# fire_notification URGENCY EXPIRE_MS SUMMARY BODY HANDLER ID_FILE [key=Label ...]
# Sends an actionable notification and waits for the click IN THE BACKGROUND --
# `notify-send -A` implies --wait and blocks, so this can never run inline.
# HANDLER is a function name; it gets the clicked key as $1.
# ID_FILE (may be "") receives the server's notification id, so a superseded
# notification can be withdrawn later -- see retire_drift_notification.
fire_notification() {
  local urgency="$1" expire="$2" summary="$3" body="$4" handler="$5" idfile="${6:-}"; shift 6
  local -a aargs=() spec
  for spec in "$@"; do aargs+=(-A "$spec"); done
  [ -n "$idfile" ] && : > "$idfile"

  (
    local out
    # stderr is deliberately NOT merged into stdout: on expiry notify-send prints
    # "Wait timeout expired", which would otherwise be read back as an action key.
    # --id-fd keeps the notification id off stdout too, for the same reason.
    if [ -n "$idfile" ]; then
      out="$(timeout "$WAITER_TIMEOUT" "${NOTIFY_CMD[@]}" -a "$APP_NAME" -u "$urgency" \
               -t "$expire" --id-fd 4 "${aargs[@]}" "$summary" "$body" 2>/dev/null 4>"$idfile")"
    else
      out="$(timeout "$WAITER_TIMEOUT" "${NOTIFY_CMD[@]}" -a "$APP_NAME" -u "$urgency" \
               -t "$expire" "${aargs[@]}" "$summary" "$body" 2>/dev/null)"
    fi
    # A real action key is a single bare token. Dismissed/expired/withdrawn gives
    # us empty output; anything with spaces is stray text, not a key.
    if [[ "$out" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
      log "notification: clicked '$out'"
      "$handler" "$out"
    else
      log "notification: dismissed, withdrawn or expired (no action taken)"
    fi
  ) &
}

# Both notifications route their "make this the main display" button here.
on_action_setmain() {
  local key="$1"
  case "$key" in
    setmain:*)
      local name="${key#setmain:}"
      set_stored_main_display "$name" && write_effective_main "$name"
      ;;
    keep)
      log "(b) user chose to keep the stored main display -- nothing written"
      ;;
    *) log "(b) unknown action key '$key' -- ignored" ;;
  esac
}

# Only one drift question is useful at a time, and a stale one is worse than none
# -- once you replug the real monitor, "Main display disconnected" has to stop
# being clickable. We WITHDRAW it server-side (CloseNotification) rather than
# killing our waiter: closing makes notify-send return empty, so the waiter
# retires itself and the popup leaves the screen. Killing the waiter alone would
# leave a live-looking notification whose buttons do nothing.
DRIFT_ID_FILE="$STATE_DIR/drift-notification-id"
retire_drift_notification() {
  local id
  id="$(cat "$DRIFT_ID_FILE" 2>/dev/null | tr -dc '0-9')"
  [ -n "$id" ] || return 0
  : > "$DRIFT_ID_FILE"
  have gdbus || return 0
  gdbus call -e -d org.freedesktop.Notifications -o /org/freedesktop/Notifications \
    -m org.freedesktop.Notifications.CloseNotification "$id" >/dev/null 2>&1
  log "(b) withdrew the stale drift notification (id $id)"
}

notify_main_display_gone() {
  local gone="$1" standin="$2"
  retire_drift_notification
  # -t 0 keeps it up until answered: it survives in the notification centre, whose
  # cards render the same action buttons, so a click still works minutes later.
  fire_notification critical 0 \
    "Main display disconnected" \
    "$gone is gone. Using $standin for now — your saved choice is unchanged. Hover this notification to choose." \
    on_action_setmain "$DRIFT_ID_FILE" \
    "setmain:$standin=Make $standin main" "keep=Keep $gone"
  log "(b) DRIFT: stored main '$gone' disconnected; standing in with '$standin'; asked the user"
}

notify_new_monitor() {
  local name="$1"
  fire_notification low 10000 \
    "New display connected" \
    "$name is now connected. Hover this notification to make it your main display." \
    on_action_setmain "" \
    "setmain:$name=Set as main"
  log "(b) offered '$name' as main display"
}

# ---- change handling --------------------------------------------------------

declare -A NOTIFIED_NEW=()      # per-session suppression: offer each output once
PREV_NAMES=""                   # comma-joined, for spotting genuinely new outputs

handle_main_display() {
  local main names
  main="$(stored_main_display)"
  if [ -z "$main" ]; then
    # Also drop any stale effective-main file (e.g. the preference was removed):
    # with nothing stored we assert nothing, so consumers fall back to their own
    # default rather than reading a value nobody chose.
    rm -f "$EFFECTIVE_MAIN" 2>/dev/null
    write_main_rules ""
    log_once nomain "(b) no .userPrefs.mainDisplay in the manifest -- main-display branch inactive (choose one with ./install.sh --reselect-main-display)"
    return 0
  fi
  names="$(monitor_names)"

  if ! printf '%s\n' "$names" | list_has "$main"; then
    local standin
    standin="$(fallback_main_display)"
    [ -n "$standin" ] || { log "(b) stored main '$main' is gone and NO monitors are connected -- nothing to stand in"; return 0; }
    write_effective_main "$standin"
    # Point the game rules at the stand-in too: the whole reason for a stand-in is
    # that things depending on the main display keep working while it's gone.
    write_main_rules "$standin"
    notify_main_display_gone "$main" "$standin"
    return 0
  fi

  # Chosen monitor is present: it IS the effective one, and a replug needs no
  # prompting at all -- the stored preference was never touched.
  write_effective_main "$main"
  write_main_rules "$main"
  retire_drift_notification

  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ "$n" = "$main" ] && continue
    [ -n "${NOTIFIED_NEW[$n]:-}" ] && continue
    printf '%s\n' "${PREV_NAMES//,/$'\n'}" | list_has "$n" && continue
    NOTIFIED_NEW[$n]=1
    notify_new_monitor "$n"
  done <<< "$names"
}

handle_change() {
  local fp="$1"
  log "monitor set changed: [${PREV_NAMES:-none}] -> [$fp]"
  regenerate_tagrules
  handle_main_display
  PREV_NAMES="$fp"
}

# ---- subcommands ------------------------------------------------------------

# --help prints this script's own header block (the only copy of its usage).
# Same one-line idiom as install.sh/update.sh/uninstall.sh, so docs-hub.sh's
# command menu can shell out to it instead of storing a second description.
self_help() { awk 'NR>2 && !/^#/{exit} NR>2 && sub(/^#[ ]?/,"")' "$0"; }
case "${1:-}" in -h|--help) self_help; exit 0 ;; esac

case "${1:-}" in
  --remember)
    # Called by set-monitor-layout.sh after every successful layout change, so the
    # memory tracks what you actually chose. Deliberately silent and cheap: it runs
    # on your click path, and must never delay or fail a layout change.
    [ $# -eq 3 ] || { echo "monitor-watcher: usage: $0 --remember <MON> <layout>" >&2; exit 2; }
    is_valid_layout "$3" || { echo "monitor-watcher: refusing to remember invalid layout '$3'" >&2; exit 2; }
    memory_set "$2" "$3" || exit 1
    log "memory: $2 -> $3 (recorded by set-monitor-layout.sh)"
    exit 0
    ;;
  --forget)
    # Escape hatch: drop one monitor (or all) from the memory, so it goes back to
    # behaving like a monitor nobody has ever configured.
    have jq || { echo "monitor-watcher: jq not found" >&2; exit 1; }
    mkdir -p "$MEMORY_DIR" 2>/dev/null
    tmp="$(mktemp)" || exit 1
    if [ "${2:-}" = "" ] || [ "${2:-}" = "--all" ]; then
      printf '%s\n' '{"version":1,"monitors":{}}' > "$LAYOUT_MEMORY" && echo "monitor-watcher: forgot all remembered layouts"
    elif jq --arg m "$2" 'del(.monitors[$m])' "$LAYOUT_MEMORY" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      mv "$tmp" "$LAYOUT_MEMORY"; echo "monitor-watcher: forgot '$2'"
    else
      rm -f "$tmp"; echo "monitor-watcher: nothing to forget (no readable memory file)" >&2; exit 1
    fi
    exit 0
    ;;
  --status)
    echo "connected : $(monitor_fingerprint)"
    echo "stored main : $(stored_main_display || true)"
    echo "effective main : $(cat "$EFFECTIVE_MAIN" 2>/dev/null || echo '(unset)')"
    echo "fallback would be : $(fallback_main_display)"
    echo "captured layouts :"; capture_layouts | sed 's/^/  /'
    echo "remembered layouts :"
    if [ -r "$LAYOUT_MEMORY" ] && have jq; then
      jq -r '.monitors | to_entries[] | "  \(.key)\t\(.value)"' "$LAYOUT_MEMORY" 2>/dev/null \
        || echo "  (memory file unreadable or corrupt)"
    else
      echo "  (nothing remembered yet)"
    fi
    if have fuser && [ -n "$(fuser "$LOCK" 2>/dev/null)" ]; then
      echo "watcher : RUNNING"
    else
      echo "watcher : not running"
    fi
    exit 0
    ;;
  --once)
    PREV_NAMES="$(monitor_fingerprint)"
    log "=== --once run ==="
    regenerate_tagrules
    handle_main_display
    exit 0
    ;;
  "") : ;;
  *) echo "monitor-watcher: unknown argument '$1' (want --once, --status, or nothing)" >&2; exit 2 ;;
esac

# ---- watcher ----------------------------------------------------------------

command -v mmsg >/dev/null 2>&1 || { echo "monitor-watcher: mmsg not found -- is MangoWM running?" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "monitor-watcher: jq not found" >&2; exit 1; }

# Single instance. mango re-runs exec-once on reload_config, and this script's own
# branch (a) issues a reload -- so without the lock every hotplug would spawn
# another watcher. Same flock idiom as wallpaper-border-reload.sh.
exec 9>"$LOCK"
flock -n 9 || exit 0

# `mmsg watch all-monitors` emits a FULL snapshot on ANY monitor change -- focus
# moves and window-count changes included, which are far more frequent than
# hotplugs. jq reduces each snapshot to just the sorted monitor-name list, and we
# act only when that fingerprint actually differs. That's what keeps this a
# hotplug watcher rather than a busy loop.
exec 3< <(mango_watch_monitors_json | jq -rc --unbuffered '[.monitors[].name] | sort | join(",")')

# Prime the baseline from the initial snapshot without acting on it, then drain
# the rest of that first burst.
IFS= read -r -u 3 PREV_NAMES || { log "watch stream closed immediately -- exiting"; exit 0; }
while IFS= read -t 0.6 -r -u 3 line; do PREV_NAMES="$line"; done
log "=== started; baseline [$PREV_NAMES] ==="

# One user action (a plug/unplug) produces a BURST of snapshots, so block for the
# first line, drain the burst, and evaluate the settled state once.
while IFS= read -r -u 3 fp; do
  while IFS= read -t 0.25 -r -u 3 line; do fp="$line"; done
  [ "$fp" = "$PREV_NAMES" ] && continue
  handle_change "$fp"
done

log "=== watch stream ended -- watcher exiting (press SUPER+r to respawn it) ==="
