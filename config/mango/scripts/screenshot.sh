#!/usr/bin/env bash
#
# screenshot.sh  --  capture a screenshot, then annotate it in satty.
#
# MODES (first argument, default "region"):
#
#   region       drag out a region with slurp, then open it in satty to
#                annotate (crop / arrow / text / highlight / blur) before
#                saving.                                    [Print, SUPER+p]
#   fullscreen   grab the whole monitor the cursor is on, then open it in
#                satty the same way.                        [Shift+Print]
#   quick        drag out a region and go STRAIGHT to clipboard + file with
#                no editor. This is exactly what this script did before satty
#                existed, kept because "grab it and paste it" shouldn't cost
#                you a round trip through an annotation window. [Ctrl+Print]
#
# WHY THE `dms ipc call screenshot begin/end` DANCE
#   DMS's popouts (bar menus, launcher, control centre) take
#   WlrKeyboardFocus.Exclusive while they're open. Exclusive means exactly
#   that: the compositor routes keyboard input to that layer surface and
#   nothing else can have it. slurp needs Escape to cancel, and satty needs
#   basically the whole keyboard (tool shortcuts, text entry, Ctrl+S/Ctrl+C),
#   so a popout that happens to be open when you hit Print would otherwise
#   swallow the lot.
#
#   DMS exposes a handshake for this. `screenshot begin` sets
#   PopoutManager.screenshotActive, and Common/KeyboardFocus.qml short-circuits
#   on it:
#
#       function keyboardFocus(active, customFocus) {
#           if (PopoutManager.screenshotActive)
#               return WlrKeyboardFocus.None;
#
#   ...so every DMS surface drops to focus None for the duration. `end` puts it
#   back.
#
#   THE TRAP IS NOT OPTIONAL. screenshotActive is a latch, not a timeout — if
#   this script exits without calling `end`, DMS keeps keyboard focus disabled
#   shell-wide until something else clears it (a modal open/close, or a
#   restart). Cancelling slurp with Escape is the common path out of here and
#   it must still restore focus, so `end` is wired to an EXIT trap that also
#   covers INT/TERM/HUP rather than being a line at the bottom of the script.
#
# SINGLE INSTANCE
#   Two overlapping runs would race on that latch: the second one's `end` would
#   re-enable DMS keyboard focus while the first is still sitting in satty. The
#   flock below makes a second press while satty is open a no-op instead.
#
set -uo pipefail

# SUMMARY is the ONE-LINE description docs-hub.sh shows in its command menu.
# It lives here, not in the hub, so there is no second copy to drift.
# SUMMARY: take a screenshot: region, fullscreen or quick

# --help prints this script's own header block (the only copy of its usage).
# Same one-line idiom as install.sh/update.sh/uninstall.sh, so docs-hub.sh's
# command menu can shell out to it instead of storing a second description.
self_help() { awk 'NR>2 && !/^#/{exit} NR>2 && sub(/^#[ ]?/,"")' "$0"; }
case "${1:-}" in -h|--help) self_help; exit 0 ;; esac

MODE="${1:-region}"

DIR="$HOME/Pictures/Screenshots"
ICON="$HOME/.config/mango/scripts/screenshot.png"
mkdir -p "$DIR"

# satty does its own saving, so it gets a strftime TEMPLATE rather than a
# resolved path -- it stamps the name at save time, which is the correct moment
# (you may sit in the editor for a while). `quick` mode resolves its own name
# below. Both land in the same folder with the same shape of filename.
FILE_TEMPLATE="$DIR/screenshot_%Y-%m-%d_%H-%M-%S.png"

LOCK="/tmp/mango-screenshot.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0

dms_screenshot_mode() {
    # Never let a DMS hiccup take the screenshot down with it -- if the shell
    # isn't running there are no popouts to steal focus in the first place.
    command -v dms >/dev/null 2>&1 || return 0
    dms ipc call screenshot "$1" >/dev/null 2>&1 || true
}

TMP="$(mktemp -t mango-screenshot-XXXXXX.png)"
cleanup() {
    dms_screenshot_mode end
    rm -f "$TMP"
}
# cleanup hangs off EXIT only, and the signal traps just exit into it -- trapping
# cleanup on all four directly would run it twice on a signal (once for the
# signal, once for the EXIT that follows).
trap cleanup EXIT
trap 'exit' INT TERM HUP

dms_screenshot_mode begin

# --- capture ---------------------------------------------------------------
# Returns non-zero when the user backed out (Escape in slurp), which is a
# normal exit, not an error -- hence the quiet `exit 0` at the call site.
capture() {
    local geom out
    case "$MODE" in
        fullscreen)
            # Which monitor is "the" screen is a question only the cursor can
            # answer here. mmsg reports the monitor it's over; falling back to
            # a bare `grim` (whole layout) is fine but on a mixed-resolution
            # setup that means a letterboxed image, so prefer the named output.
            out="$(mmsg get cursorpos 2>/dev/null | jq -r '.monitor // empty' 2>/dev/null)"
            if [ -n "$out" ]; then
                grim -o "$out" "$TMP"
            else
                grim "$TMP"
            fi
            ;;
        *)
            geom="$(slurp)" || return 1
            [ -n "$geom" ] || return 1
            grim -g "$geom" "$TMP"
            ;;
    esac
}

capture || exit 0
[ -s "$TMP" ] || exit 0

# --- annotate / save -------------------------------------------------------
if [ "$MODE" = "quick" ]; then
    FILE="$DIR/screenshot_$(date +'%Y-%m-%d_%H-%M-%S').png"
    cp "$TMP" "$FILE"
    wl-copy < "$TMP"
    notify-send "Screenshot Captured" "Saved to $FILE" -i "$ICON"
    exit 0
fi

if ! command -v satty >/dev/null 2>&1; then
    # Degrade to the old behaviour rather than losing the capture the user
    # already framed.
    FILE="$DIR/screenshot_$(date +'%Y-%m-%d_%H-%M-%S').png"
    cp "$TMP" "$FILE"
    wl-copy < "$TMP"
    notify-send "Screenshot Captured (satty not installed)" "Saved to $FILE" -i "$ICON"
    exit 0
fi

# Behaviour lives here on the command line, NOT in satty's config.toml. That
# file is generated from the wallpaper palette by wallpaper-border-reload.sh
# and gets rewritten wholesale on every wallpaper change, so it holds colours
# and nothing else. satty gives the CLI precedence over the config file, so
# these win regardless.
#   --early-exit all  : close after a save/copy instead of idling in the editor
#   --initial-tool    : arrow is the annotation you reach for most
satty --filename "$TMP" \
      --output-filename "$FILE_TEMPLATE" \
      --copy-command wl-copy \
      --early-exit all \
      --initial-tool arrow
