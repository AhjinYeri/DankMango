#!/usr/bin/env bash
# =============================================================================
#  apply-keybinds-columns-patch.sh  --  DankMango keybinds 2-column cap patch
# =============================================================================
#  Patches DMS's KeybindsContent.qml so the SUPER+/ cheatsheet lays its keybind
#  categories out in at most TWO columns instead of three.
#
#  WHY: each keybind row puts the description at a fixed 170px offset inside its
#  column, so the room a description gets is (column width - 170). At the
#  overlay cheatsheet's 1200px modal width that is:
#
#      3 columns (stock)   (1200-32-24)/3 = 381px column ->  211px description
#      2 columns (patched) (1200-32-12)/2 = 578px column ->  408px description
#
#  211px is about 35 characters, so most of this config's descriptions elide
#  mid-sentence. 408px fits all but a handful of them.
#
#  WHY THIS SCRIPT EXISTS: the target file is package-owned (dms-shell, root:root)
#  and gets OVERWRITTEN by every DMS update. post-update-health.sh spots when the
#  patch has been clobbered and tells you to re-run this (via apply-patches.sh).
#  It's idempotent (skips if already patched, unless --force) and backs the
#  current file up first.
#
#  UNLIKE the combined-OSD patch, this does NOT embed a whole copy of the target.
#  The edit is one property line, so it is applied as a surgical rewrite of that
#  line: a DMS update that improves anything ELSE in this 336-line file keeps its
#  improvement. If upstream ever restructures the line, this script refuses to
#  write and says so rather than guessing.
#
#  Usage:   ~/.config/mango/scripts/apply-keybinds-columns-patch.sh [--force]
#  (needs sudo -- it writes a root-owned file; you'll be prompted for a password)
# =============================================================================
set -euo pipefail

TARGET=/usr/share/quickshell/dms/Modals/KeybindsContent.qml
MARKER='DankMango patch: keybinds 2-column cap'
BACKUP_DIR="$HOME/.config/mango/backups"
MAX_COLUMNS=2
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ ! -f "$TARGET" ]; then
    echo "[keybinds-columns-patch] ERROR: $TARGET isn't there." >&2
    echo "                         DMS moved or renamed it. Find it with:" >&2
    echo "                             pacman -Ql dms-shell | grep KeybindsContent" >&2
    exit 1
fi

# --- already patched? bail early (unless --force) ----------------------------
if grep -qF "$MARKER" "$TARGET" && [ "$FORCE" -eq 0 ]; then
    echo "[keybinds-columns-patch] Already applied -- $TARGET has the marker. Nothing to do."
    echo "                         (re-run with --force to rewrite it anyway.)"
    exit 0
fi

# --- transform ---------------------------------------------------------------
# Two things happen, in one awk pass:
#   1. Any previous DankMango patch block is stripped, so --force over an already
#      patched file rewrites cleanly instead of stacking comment blocks.
#   2. The numColumns line has its cap replaced and the marker block inserted
#      above it, at the line's own indentation.
#
# The match is deliberately narrow -- `property int numColumns:` followed by the
# Math.max/Math.min/Math.floor shape upstream uses. It tolerates a different cap
# (so --force works on an already-patched file) and a different width divisor (so
# an upstream tweak to 350 doesn't break us), but nothing more. Anything else and
# we write nothing.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

awk -v marker="$MARKER" -v maxcols="$MAX_COLUMNS" '
    # Drop a previously-applied block: everything from our opening marker comment
    # through the "end DankMango patch" line, EXCEPT the numColumns line itself,
    # which is re-emitted (rewritten) by the rule below.
    /---- DankMango patch: keybinds 2-column cap/ { inblock = 1; next }
    inblock && /---- end DankMango patch/         { inblock = 0; next }

    /property int numColumns:[[:space:]]*Math\.max\(1,[[:space:]]*Math\.min\([0-9]+,[[:space:]]*Math\.floor\(width \/ [0-9]+\)\)\)/ {
        found++
        match($0, /^[[:space:]]*/); pad = substr($0, 1, RLENGTH)
        print pad "// ---- " marker " ---------------------------------"
        print pad "// Upstream caps the keybind cheatsheet at 3 columns. At the overlay modal'"'"'s"
        print pad "// 1200px width that leaves each description ~211px (about 35 characters), so"
        print pad "// most of DankMango'"'"'s descriptions elide mid-sentence. Capping at " maxcols " gives"
        print pad "// each description ~408px and only the longest few still elide."
        print pad "//"
        print pad "// This file is PACKAGE-OWNED (dms-shell) and gets OVERWRITTEN by DMS updates."
        print pad "// It is put back by  ~/.config/mango/scripts/apply-keybinds-columns-patch.sh"
        print pad "// (or just  apply-patches.sh ), and  post-update-health.sh  checks it is still"
        print pad "// here by grepping this file for the marker string above."
        sub(/Math\.min\([0-9]+,/, "Math.min(" maxcols ",")
        print
        print pad "// ---- end DankMango patch -----------------------------------------------------"
        next
    }

    inblock { next }
    { print }

    END {
        if (found != 1) {
            printf("[keybinds-columns-patch] matched %d numColumns line(s), expected exactly 1.\n", found) > "/dev/stderr"
            exit 3
        }
    }
' "$TARGET" > "$TMP" || {
    echo "[keybinds-columns-patch] ERROR: could not find exactly one numColumns line in $TARGET." >&2
    echo "                         Upstream changed the shape of that property, so this patch has" >&2
    echo "                         nowhere safe to go. Look at it and update this script:" >&2
    echo "                             grep -n numColumns $TARGET" >&2
    exit 1
}

# --- integrity: the rewritten file must carry the marker AND the new cap ------
if ! grep -qF "$MARKER" "$TMP"; then
    echo "[keybinds-columns-patch] ERROR: rewritten file is missing the marker; refusing to write." >&2
    exit 1
fi
if ! grep -q "property int numColumns:.*Math\.min($MAX_COLUMNS," "$TMP"; then
    echo "[keybinds-columns-patch] ERROR: cap was not rewritten to $MAX_COLUMNS; refusing to write." >&2
    exit 1
fi

# --- back up whatever is there now (stock or an older patch) -----------------
mkdir -p "$BACKUP_DIR"
BK="$BACKUP_DIR/KeybindsContent.qml.$(date +%Y%m%d-%H%M%S)"
cp "$TARGET" "$BK"
echo "[keybinds-columns-patch] Backed up current file -> $BK"

# Keep the newest N and drop our older ones, right here where the new one was
# written -- otherwise every DMS update that needs a re-patch adds a permanent
# copy and nothing ever removes it.
#
# BACKUP_RETAIN duplicates lib/common.sh's DANKMANGO_BACKUP_RETAIN. This script is
# deployed standalone to ~/.config/mango/scripts and can't source that file, so the
# two must be changed together.
#
# Only files named EXACTLY KeybindsContent.qml.YYYYmmdd-HHMMSS are ours; the
# digit-by-digit glob is what keeps hand-labelled copies out of the sweep. Sorted
# by the stamp in the NAME, not mtime, for the same reason as lib/common.sh: `cp`
# here preserves nothing useful to sort on.
BACKUP_RETAIN=10
mapfile -t _kb_bk < <(compgen -G "$BACKUP_DIR/KeybindsContent.qml.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]" 2>/dev/null | sort || true)
if [ "${#_kb_bk[@]}" -gt "$BACKUP_RETAIN" ]; then
    _kb_cut=$(( ${#_kb_bk[@]} - BACKUP_RETAIN ))
    # Never fatal: this runs under `set -e`, and a cleanup step must not be the
    # thing that aborts a patch that already succeeded.
    if rm -f "${_kb_bk[@]:0:$_kb_cut}" 2>/dev/null; then
        echo "[keybinds-columns-patch] Tidied $_kb_cut older backup(s); newest $BACKUP_RETAIN kept."
    else
        echo "[keybinds-columns-patch] NOTE: couldn't tidy $_kb_cut older backup(s) -- harmless, they only take space." >&2
    fi
fi

# --- write it (root-owned, world-readable) -----------------------------------
echo "[keybinds-columns-patch] Writing patched KeybindsContent.qml (sudo)..."
sudo install -m 0644 -o root -g root "$TMP" "$TARGET"

# --- verify -----------------------------------------------------------------
if grep -qF "$MARKER" "$TARGET" && grep -q "property int numColumns:.*Math\.min($MAX_COLUMNS," "$TARGET"; then
    echo "[keybinds-columns-patch] OK -- patch applied to $TARGET"
    echo "[keybinds-columns-patch] Reload DMS to pick it up:   dms restart"
else
    echo "[keybinds-columns-patch] ERROR: post-write verify failed; marker or cap not found in $TARGET." >&2
    exit 1
fi
