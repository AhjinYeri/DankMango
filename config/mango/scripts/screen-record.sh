#!/usr/bin/env bash
#
# screen-record.sh
# ================
# Start/stop a screen recording. Bound to SUPER+ALT+r (see config.conf), which is
# the closest thing here to Windows' Win+Alt+R game-bar recording.
#
# HOW IT BEHAVES
#   Press once  -> starts recording the monitor your mouse/focus is on.
#   Press again -> stops it, finalises the file, and tells you where it went.
#   One keybind does both; there's no separate stop key to forget.
#
# WHY A PIDFILE AND NOT pkill
#   Stopping wf-recorder MUST be a clean SIGINT -- kill it any harder and you get
#   an unplayable, unfinalised file, because the container never gets its trailer
#   written. So we track the exact PID we started in a pidfile and signal only
#   that PID. Deliberately NOT `pkill wf-recorder`: matching by process name is
#   how you end up killing something you didn't start.
#
# AUDIO IS OFF BY DEFAULT -- and that's deliberate
#   Recording audio means naming a PipeWire source, and the right source changes
#   depending on whether you're on speakers or headphones (see the audio-switch
#   scripts). A recording that silently captures the wrong device -- or nothing --
#   is worse than one that captures no audio at all and says so. To turn it on,
#   set AUDIO=1 below and put the source name in AUDIO_SOURCE. Find sources with:
#       pactl list short sources
#
# OUTPUT
#   ~/Videos/Recordings/recording_YYYY-MM-DD_HH-MM-SS.mp4
#   Matches the layout screenshot.sh uses for ~/Pictures/Screenshots.
#
# ---------------------------------------------------------------------------
set -uo pipefail

DIR="$HOME/Videos/Recordings"
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/mango-screen-record.pid"

# Set AUDIO=1 to record sound, and set AUDIO_SOURCE to a name from
# `pactl list short sources`. Left empty on purpose -- see the header.
AUDIO=0
AUDIO_SOURCE=""

ICON="$HOME/.config/mango/scripts/screenshot.png"
notify() { notify-send "$1" "$2" ${ICON:+-i "$ICON"} 2>/dev/null || true; }

# ---- Already recording? Then this press means stop. ------------------------
if [[ -f "$PIDFILE" ]]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || echo "")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        # SIGINT, not SIGKILL -- lets wf-recorder finalise the container.
        kill -INT "$pid" 2>/dev/null
        # Give it a moment to write the trailer before we report success.
        for _ in {1..50}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        rm -f "$PIDFILE"
        last="$(ls -t "$DIR"/recording_*.mp4 2>/dev/null | head -1)"
        if [[ -n "$last" ]]; then
            notify "Recording stopped" "Saved to $last"
        else
            notify "Recording stopped" "But no output file was found."
        fi
        exit 0
    fi
    # Stale pidfile (e.g. we were killed, or the machine rebooted). Clear and fall
    # through to start a fresh recording rather than refusing to do anything.
    rm -f "$PIDFILE"
fi

# ---- Not recording: start. -------------------------------------------------
command -v wf-recorder >/dev/null 2>&1 || {
    notify "Cannot record" "wf-recorder is not installed."
    exit 1
}

mkdir -p "$DIR" || { notify "Cannot record" "Could not create $DIR"; exit 1; }

# Which monitor to record: the one the pointer is on.
#
# NOTE FOR FUTURE EDITS -- don't "improve" this into `mmsg get all-monitors` and
# look for selmon. mango 0.14 rewrote the mmsg CLI and there's no selmon field
# any more (verified on 0.15.5: the monitor object has no such key). The two
# things that DO report a monitor are `get cursorpos` and `get focusing-client`.
# cursorpos wins because it always answers -- there's always a pointer, but
# there isn't always a focused window.
#
# Parsed with grep, not jq, on purpose: cursorpos is flat JSON, and jq is only a
# soft dependency of install.sh. If this lookup fails we leave OUTPUT empty and
# let wf-recorder choose, rather than aborting the recording.
OUTPUT="$(mmsg get cursorpos 2>/dev/null \
    | grep -oE '"monitor":"[^"]+"' | head -1 | cut -d'"' -f4)"

FILE="$DIR/recording_$(date +'%Y-%m-%d_%H-%M-%S').mp4"

args=(-f "$FILE")
[[ -n "$OUTPUT" ]] && args+=(-o "$OUTPUT")
if [[ "$AUDIO" == "1" && -n "$AUDIO_SOURCE" ]]; then
    args+=(--audio="$AUDIO_SOURCE")
fi

setsid wf-recorder "${args[@]}" >/dev/null 2>&1 &
rec_pid=$!
echo "$rec_pid" > "$PIDFILE"

# Confirm it actually survived startup -- wf-recorder exits immediately if the
# output name is wrong or the encoder is unavailable, and a notification saying
# "recording" when nothing is recording is the worst possible outcome here.
sleep 1
if kill -0 "$rec_pid" 2>/dev/null; then
    notify "Recording started" "${OUTPUT:-screen} -> $(basename "$FILE")  (press again to stop)"
else
    rm -f "$PIDFILE"
    notify "Recording failed" "wf-recorder exited immediately. Run it by hand to see why."
    exit 1
fi
