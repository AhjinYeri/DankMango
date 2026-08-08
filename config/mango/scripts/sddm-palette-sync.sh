#!/usr/bin/env bash
#
# sddm-palette-sync.sh
# ====================
# Makes the DankMango SDDM LOGIN SCREEN follow the wallpaper -- both its COLORS
# and the wallpaper IMAGE itself -- the same way window borders, the bar and GTK
# apps already do.
#
# THE PROBLEM THIS SOLVES (the privilege boundary):
#   Everything else in DankMango re-tints by reading matugen output out of
#   ~/.cache/DankMaterialShell/dms-colors.json. The login screen CANNOT do that:
#   SDDM's greeter runs as the system user `sddm` (uid 960, home /var/lib/sddm)
#   BEFORE any user session exists. /home/chris is 0700, so the greeter cannot
#   even traverse into it, let alone read the palette or the wallpaper. It is a
#   real boundary, not a convention.
#
#   The common internet "fix" is `chmod 755 /home/$USER`. DO NOT DO THAT. It
#   exposes the entire home directory to every local account permanently, in
#   exchange for login-screen colors. Bad trade.
#
# HOW WE CROSS IT INSTEAD (no polkit, no setuid, no daemon):
#   SDDM themes support a two-file config: the theme ships `theme.conf`
#   (defaults, root owned) and SDDM ALSO reads `theme.conf.user` next to it,
#   layering it on top -- overriding matching keys and adding new ones. That
#   split exists precisely so user changes survive theme upgrades. (Verified
#   empirically against sddm 0.21 here, not just assumed.)
#
#   The install step (already root) does the privilege work ONCE, declaratively,
#   via file ownership:
#
#     /usr/share/sddm/themes/dankmango/            root:root 0755  <- QML = code
#     /usr/share/sddm/themes/dankmango/theme.conf  root:root 0644  <- defaults
#     /usr/share/sddm/themes/dankmango/theme.conf.user   YOU 0644  <- palette
#     /usr/share/sddm/themes/dankmango/wallpaper-a.jpg   YOU 0644  <- image slot
#     /usr/share/sddm/themes/dankmango/wallpaper-b.jpg   YOU 0644  <- image slot
#
#   After that, THIS script runs as your normal user with no elevation at all.
#   Nothing privileged ever executes.
#
#   The DIRECTORY stays root-owned because the greeter EXECUTES the QML in it,
#   as the sddm user, before anyone authenticates. A user-writable theme
#   directory would let anything running as you drop QML into a pre-auth
#   execution context. User-writable leaf FILES are a much smaller thing.
#
# WHY TWO WALLPAPER SLOTS (double buffering):
#   A ~3 MB image copy is not near-instantaneous, and we cannot do the usual
#   write-temp-then-rename atomic swap -- rename() needs write access to the
#   DIRECTORY, and keeping that root-owned is the whole security property above.
#   So a greeter starting mid-copy could read a truncated image. Instead we
#   always write the slot that is NOT currently in use, and only once it is
#   complete do we flip the `WallpaperPath` pointer inside theme.conf.user.
#   That reduces the torn-read window to the ~500-byte config write, which is
#   the same small race already accepted for the palette.
#
# SECURITY NOTE ON CARRYING AN IMAGE (read this before extending further):
#   Shipping an image across the boundary is a genuinely bigger deal than
#   shipping ten hex strings. The greeter now runs Qt's image DECODERS over a
#   user-writable file, pre-authentication. Qt ships SVG/TIFF/JP2/MNG/WebP
#   plugins and image decoders are historically a rich source of memory-safety
#   bugs. Re-encoding here (below) fixes the corrupt/oversized case but NOT a
#   deliberately hostile one: Qt detects format from CONTENT, not extension, so
#   a malicious file simply written directly into a slot still reaches a
#   decoder. The exposure is bounded -- an attacker must already have code
#   execution as you, and the sddm uid is lateral movement rather than a path to
#   root -- but it is a real increase over the palette-only design.
#   Disk-space abuse is NOT a new capability: /usr and /home are the same
#   filesystem here, and the slot filenames are fixed, so this adds no ability
#   that writing into $HOME did not already provide.
#
# WHEN IT RUNS:
#   Called by wallpaper-border-reload.sh whenever DMS regenerates the palette,
#   i.e. on wallpaper change. The greeter re-reads theme.conf.user every time it
#   starts, so the next login screen matches the current wallpaper.
#
# SAFE TO RUN ANY TIME: idempotent, writes only on actual change, and exits
# quietly (status 0) if the theme is not installed or not writable yet.
#
# Usage:  sddm-palette-sync.sh [--verbose] [--dry-run]
#
# Testing hook: set DANKMANGO_WALLPAPER_SRC to point at a different image
# without touching your live wallpaper, and DANKMANGO_SDDM_THEME_DIR to write
# into a checkout instead of /usr/share.

set -uo pipefail

# CMD lines are what docs-hub.sh's command list shows: a real, runnable command
# and a short description, separated by " :: ". They live here, next to the code
# that implements them, so the hub stores no copy of its own. Add a line when you
# add a flag worth showing; the fuller explanation stays in the Usage block above.
# CMD: ~/.config/mango/scripts/sddm-palette-sync.sh :: push your current wallpaper colours to the login screen
# CMD: ~/.config/mango/scripts/sddm-palette-sync.sh --dry-run :: show what it would write, without writing it

DMS_COLORS_JSON="${DMS_COLORS_JSON:-$HOME/.cache/DankMaterialShell/dms-colors.json}"
DMS_SESSION_JSON="${DMS_SESSION_JSON:-$HOME/.local/state/DankMaterialShell/session.json}"
THEME_DIR="${DANKMANGO_SDDM_THEME_DIR:-/usr/share/sddm/themes/dankmango}"
TARGET="$THEME_DIR/theme.conf.user"

# Longest edge the login screen ever needs. The source is frequently far larger
# (the current one is 5120x2880 / 3.4 MB); downscaling keeps the copy small and
# normalises it through a re-encode.
MAX_DIM="${DANKMANGO_SDDM_WALLPAPER_MAX:-2560}"

VERBOSE=0
DRY_RUN=0
# --help prints this script's own header block (the only copy of its usage).
# Same one-line idiom as install.sh/update.sh/uninstall.sh, so docs-hub.sh's
# command menu can shell out to it instead of storing a second description.
self_help() { awk 'NR>2 && !/^#/{exit} NR>2 && sub(/^#[ ]?/,"")' "$0"; }
case "${1:-}" in -h|--help) self_help; exit 0 ;; esac

for arg in "$@"; do
    case "$arg" in
        --verbose) VERBOSE=1 ;;
        --dry-run) DRY_RUN=1; VERBOSE=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

log() { [ "$VERBOSE" -eq 1 ] && echo "$*" >&2; return 0; }

# --- single instance -------------------------------------------------------
# WHY THIS IS HERE (it is not boilerplate -- the failure was reproduced):
#   wallpaper-border-reload.sh fires this script in the BACKGROUND on every
#   palette change. Change wallpapers twice inside one re-encode (~0.27s here,
#   against a 0.5s watcher poll) and two copies run concurrently. Both then read
#   the SAME `WallpaperPath` pointer, both conclude the same slot is the free
#   one, and both write it.
#
#   The two-slot design stops the greeter reading a half-written file; it does
#   NOT stop two WRITERS choosing the same slot. Observed when reproduced:
#     - both instances wrote wallpaper-b.jpg simultaneously
#     - the loser's luminance probe read the file mid-write and produced no
#       value, so ScrimOpacity vanished from the config entirely and the theme
#       silently fell back to its default dimming
#     - the config ended up recording instance B's FINGERPRINT next to instance
#       A's IMAGE
#   That last one is the nasty part: it is sticky, not transient. The fingerprint
#   short-circuit below sees a match on every later run and skips re-encoding, so
#   the login screen keeps showing the wrong wallpaper until the user picks some
#   third one.
#
# WAIT, don't skip. The other watchers in this project use `flock -n ... || exit`
# because a second *watcher* is simply redundant. That is the wrong behaviour
# here: this script is a one-shot triggered by an edge that has already been
# consumed, so an instance that exits early drops that change on the floor and
# the login screen keeps the previous wallpaper. Instead we wait, matching the
# `flock -w` idiom monitor-watcher.sh already uses for its inner lock. Queued
# runs are cheap -- whichever one goes first applies the newest state, and the
# rest fall straight through the fingerprint check as no-ops.
LOCK="${XDG_RUNTIME_DIR:-/tmp}/dankmango-sddm-palette-sync.lock"
LOCK_WAIT="${DANKMANGO_SDDM_SYNC_LOCK_WAIT:-15}"

# --dry-run writes nothing, so it neither needs the lock nor should block on one.
if [ "$DRY_RUN" -eq 0 ]; then
    exec 9>"$LOCK" || { log "cannot open lock $LOCK; continuing unlocked"; }
    if ! flock -w "$LOCK_WAIT" 9; then
        # Only reachable if something is wedged: every normal run is well under
        # a second. Bail rather than pile up, and let the next change retrigger.
        log "timed out after ${LOCK_WAIT}s waiting for another sync; skipping"
        exit 0
    fi
fi

command -v jq >/dev/null 2>&1 || { log "jq not installed; nothing to do"; exit 0; }
[ -f "$DMS_COLORS_JSON" ] || { log "no palette json at $DMS_COLORS_JSON"; exit 0; }

# Not installed yet, or install step never granted ownership -> do nothing.
# This is the normal state on a machine that hasn't run the theme's install.sh,
# so it must stay silent rather than erroring on every wallpaper change.
if [ "$DRY_RUN" -eq 0 ]; then
    if [ ! -e "$TARGET" ]; then
        log "theme not installed ($TARGET missing); skipping"
        exit 0
    fi
    if [ ! -w "$TARGET" ]; then
        log "$TARGET not writable by $(id -un); skipping (run the theme's install.sh)"
        exit 0
    fi
fi

# --- colours ---------------------------------------------------------------
# Material 3 roles as matugen emits them (snake_case in dms-colors.json; note
# it is on_surface, NOT onSurface -- camelCase silently yields null).
# Keep this list in sync with the keys Components/Palette.qml actually reads.
read_role() {
    jq -r --arg r "$1" '.colors.dark[$r] // empty' "$DMS_COLORS_JSON" 2>/dev/null
}

# Reject anything that is not a literal #rrggbb. This is the validation layer:
# a truncated (torn-read), corrupt or hostile palette file must degrade to the
# theme's built-in defaults, never render an unreadable or blank login screen.
valid_hex() { [[ "$1" =~ ^#[0-9a-fA-F]{6}$ ]]; }

emit=""
add_key() {
    local key="$1" role="$2" val
    val="$(read_role "$role")"
    if valid_hex "$val"; then
        emit+="$key=$val"$'\n'
    else
        log "skip $key: role '$role' missing or not #rrggbb (got '${val:-<empty>}')"
    fi
}

add_key BackgroundColor      surface
add_key SurfaceColor         surface_container
add_key SurfaceHighColor     surface_container_high
add_key TextColor            on_surface
add_key SubTextColor         on_surface_variant
add_key AccentColor          primary
add_key OnAccentColor        on_primary
add_key OutlineColor         outline
add_key ErrorColor           error
add_key ScrimColor           scrim

if [ -z "$emit" ]; then
    log "no valid colors extracted; leaving existing file untouched"
    exit 0
fi

# --- wallpaper -------------------------------------------------------------
# Read the currently-live values so we can (a) pick the free slot and (b) avoid
# re-encoding an unchanged wallpaper on every poll.
prev_val() { [ -f "$TARGET" ] && sed -n "s/^$1=//p" "$TARGET" 2>/dev/null | tail -1; }

WALLPAPER_SRC="${DANKMANGO_WALLPAPER_SRC:-}"
if [ -z "$WALLPAPER_SRC" ] && [ -f "$DMS_SESSION_JSON" ]; then
    WALLPAPER_SRC="$(jq -r '.wallpaperPath // empty' "$DMS_SESSION_JSON" 2>/dev/null)"
fi

prev_slot="$(prev_val WallpaperPath)"
prev_fp="$(prev_val WallpaperFingerprint)"
wallpaper_emit=""

if [ -n "$WALLPAPER_SRC" ] && [ -f "$WALLPAPER_SRC" ] && command -v magick >/dev/null 2>&1; then
    # Cheap change detector: path + mtime + size. Avoids re-encoding a multi-MB
    # source twice a second just because the palette file was touched.
    fp="$(stat -c '%n:%Y:%s' "$WALLPAPER_SRC" 2>/dev/null)"
    fp="$(printf '%s@%s' "$fp" "$MAX_DIM" | md5sum | cut -d' ' -f1)"

    # Flip to whichever slot is not currently in use.
    case "$prev_slot" in
        *wallpaper-a.jpg) slot="wallpaper-b.jpg" ;;
        *)                slot="wallpaper-a.jpg" ;;
    esac
    slot_path="$THEME_DIR/$slot"

    if [ "$fp" = "$prev_fp" ] && [ -s "${prev_slot:-/nonexistent}" ]; then
        # Unchanged: keep pointing at the existing slot, re-encode nothing.
        log "wallpaper unchanged; keeping $prev_slot"
        wallpaper_emit="WallpaperPath=$prev_slot"$'\n'"WallpaperFingerprint=$prev_fp"$'\n'
        slot_path="$prev_slot"
    elif [ "$DRY_RUN" -eq 1 ]; then
        wallpaper_emit="WallpaperPath=$slot_path"$'\n'"WallpaperFingerprint=$fp"$'\n'
    elif [ ! -w "$slot_path" ]; then
        log "slot $slot_path not writable; skipping wallpaper sync"
        slot_path=""
    else
        # Downscale + re-encode. -strip drops metadata; the re-encode normalises
        # whatever the source format was into a plain baseline JPEG.
        # '>' means shrink-only, never upscale a small wallpaper.
        if magick "$WALLPAPER_SRC" -auto-orient -strip \
                  -resize "${MAX_DIM}x${MAX_DIM}>" -quality 88 \
                  "JPEG:$slot_path" 2>/dev/null && [ -s "$slot_path" ]; then
            log "wrote wallpaper slot $slot_path ($(stat -c %s "$slot_path") bytes)"
            wallpaper_emit="WallpaperPath=$slot_path"$'\n'"WallpaperFingerprint=$fp"$'\n'
        else
            log "wallpaper re-encode failed; leaving previous slot in place"
            slot_path=""
            [ -n "$prev_slot" ] && wallpaper_emit="WallpaperPath=$prev_slot"$'\n'"WallpaperFingerprint=$prev_fp"$'\n'
        fi
    fi

    # --- scrim ------------------------------------------------------------
    # The backdrop dim is derived from how bright the wallpaper actually is,
    # rather than being one compromise constant. A dark wallpaper needs almost
    # no dimming; a bright one needs a lot for the card text to stay readable.
    # Measured on the DOWNSCALED copy so it reflects what is actually shown.
    lum_src="$slot_path"
    [ -n "$lum_src" ] && [ -s "$lum_src" ] || lum_src="$WALLPAPER_SRC"
    lum="$(magick "$lum_src" -colorspace Gray -resize 1x1! -format '%[fx:mean]' info: 2>/dev/null)"
    if [[ "$lum" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        # Range deliberately GENTLE. An earlier pass used 0.28..0.72, which kept
        # text perfectly legible but crushed a bright wallpaper into flat grey --
        # defeating the point of syncing the image at all. The login card
        # supplies its own contrast (it is a dark translucent surface), so the
        # only element sitting on the raw backdrop is the clock, and that gets a
        # drop shadow in Components/Clock.qml instead. So the scrim only has to
        # take the edge off, not carry legibility on its own.
        scrim="$(awk -v l="$lum" 'BEGIN{
            s = 0.20 + 0.28*l;              # dark ~0.23, very bright ~0.47
            if (s < 0.20) s = 0.20;
            if (s > 0.50) s = 0.50;
            printf "%.2f", s
        }')"
        log "wallpaper mean luminance $lum -> ScrimOpacity $scrim"
        wallpaper_emit+="ScrimOpacity=$scrim"$'\n'
    fi
else
    [ -n "$WALLPAPER_SRC" ] || log "no wallpaper path in $DMS_SESSION_JSON"
    command -v magick >/dev/null 2>&1 || log "imagemagick not installed; skipping wallpaper sync"
fi

emit+="$wallpaper_emit"

new_content="# ! Auto-generated by sddm-palette-sync.sh -- do not edit directly.
# Regenerated from ~/.cache/DankMaterialShell/ on wallpaper change. Anything you
# put here WILL be overwritten; edit theme.conf instead (that file holds the
# fallback defaults and is root-owned).
[General]
$emit"

if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s' "$new_content"
    exit 0
fi

# Only write on real change, so we don't churn mtime on every wallpaper poll.
if [ -f "$TARGET" ] && [ "$(cat "$TARGET" 2>/dev/null)" = "$new_content" ]; then
    log "nothing changed; no write"
    exit 0
fi

# In-place rewrite. We deliberately CANNOT do the usual write-temp-then-rename
# atomic swap: rename() needs write permission on the DIRECTORY, and keeping the
# directory root-owned is the whole security property above. The exposure is a
# sub-millisecond torn read against a file the greeter opens once at startup,
# and the validation above plus the QML-side fallbacks make a torn read degrade
# to defaults. The wallpaper image avoids this race entirely via the two slots.
if printf '%s' "$new_content" > "$TARGET" 2>/dev/null; then
    log "wrote $TARGET"
else
    log "failed writing $TARGET (permissions?)"
    exit 0
fi
