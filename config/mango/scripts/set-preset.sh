#!/usr/bin/env bash
#
# =============================================================================
#  set-preset.sh  --  switch the active MangoWM config PRESET
# =============================================================================
#
#  >>> IF SOMETHING STOPPED WORKING AFTER A SYSTEM UPDATE, START HERE <<<
#
#  Everything that can break when MangoWM updates lives in ONE place: the box
#  below marked "########## EDIT HERE AFTER A MANGO UPDATE ##########". Read its
#  plain-English comments and fix the commands to match the new version.
#
#  Plain-English guide: ~/.config/DankMaterialShell/plugins/presetSwitcher/README.md
#  How presets work:    ~/.config/mango/presets/README.md
#
# -----------------------------------------------------------------------------
#  WHAT THIS SCRIPT DOES (plain English)
# -----------------------------------------------------------------------------
#  A "preset" is a named bundle of MangoWM settings that can be swapped in and
#  out as a unit -- tighter gaps and faster animations, say -- without editing
#  config.conf and without anything to undo by hand afterwards.
#
#  Each preset is one self-contained config fragment:
#      ~/.config/mango/presets/<name>/preset.conf
#
#  config.conf reads exactly ONE of them, through a fixed path:
#      source-optional=~/.config/mango/active/preset.conf
#
#  ...and that path is a SYMLINK. Switching presets = repointing the symlink at
#  a different preset's fragment, then reloading MangoWM. Nothing is copied,
#  merged, or written into config.conf, so switching back is complete by
#  construction: there is no residue to miss.
#
#  The swap is ATOMIC (new link written to a temp name, then renamed into
#  place), so an interrupted switch can never leave config.conf pointing at
#  a half-written include.
#
#  USAGE:
#    set-preset.sh <name>              # switch to a preset and reload
#    set-preset.sh <name> --dry-run    # say what would change; change nothing
#    set-preset.sh --list              # show the available presets
#    set-preset.sh --list --porcelain  # same, tab-separated, for scripts/plugins
#    set-preset.sh --active            # print the active preset's name
#  EXAMPLES:
#    set-preset.sh minimal
#    set-preset.sh default
#
set -euo pipefail

# CMD lines are what docs-hub.sh's command list shows: a real, runnable command
# and a short description, separated by " :: ". They live here, next to the code
# that implements them, so the hub stores no copy of its own. Add a line when you
# add a flag worth showing; the fuller explanation stays in the Usage block above.
# CMD: ~/.config/mango/scripts/set-preset.sh --list :: list the desktop presets and show which one is active
# CMD: ~/.config/mango/scripts/set-preset.sh minimal :: switch to the Minimal preset (tight gaps, quick animations)
# CMD: ~/.config/mango/scripts/set-preset.sh default :: switch back to Default (removes every preset override)
# CMD: ~/.config/mango/scripts/set-preset.sh minimal --dry-run :: show exactly what switching would change, without changing anything

# #############################################################################
# ########## EDIT HERE AFTER A MANGO UPDATE ###################################
# #############################################################################
# Everything in this box is "version-specific": file paths, MangoWM config
# syntax, and the commands MangoWM understands. Fix things HERE after an update.

# --- 1. FILE PATHS ----------------------------------------------------------
# Where the presets live (one folder each, holding a preset.conf), and the fixed
# path config.conf includes. If you move either, change it here AND in the
# matching source-optional= line in config.conf -- they are two halves of one
# thing and a mismatch just makes every preset silently do nothing.
PRESETS_DIR="$HOME/.config/mango/presets"
ACTIVE_DIR="$HOME/.config/mango/active"
ACTIVE_LINK="$ACTIVE_DIR/preset.conf"

# The line config.conf must contain for any of this to have an effect. Only used
# to produce a clear error instead of a silent no-op -- see check_wired_up().
CONFIG_MAIN="$HOME/.config/mango/config.conf"
REQUIRED_INCLUDE="source-optional=~/.config/mango/active/preset.conf"

# DankMango's install manifest -- where the active preset is remembered across
# updates, beside the other user choices (.userPrefs.mainDisplay and friends).
# Best-effort throughout: a missing or unwritable manifest never blocks a switch.
MANIFEST="${XDG_STATE_HOME:-$HOME/.local/state}/dankmango/manifest.json"

# --- 2. COMMANDS THAT TALK TO MANGOWM ---------------------------------------
# Reload the config so the new preset takes effect on already-open windows.
#   mango 0.13 (DEAD): mmsg -s -d reload_config
#   mango 0.14+ (now): mmsg dispatch reload_config
# To test by hand:  mmsg dispatch reload_config   (should print {"success":true})
mango_reload_config() { mmsg dispatch reload_config >/dev/null 2>&1 || true; }

# Check that a preset fragment is valid BEFORE we point the live config at it.
#
# >>> READ THIS BEFORE "SIMPLIFYING" IT TO `mango -c "$1" -p >/dev/null` <<<
# `mango -c <file> -p` EXITS 0 EVEN WHEN THE FILE IS BROKEN. Measured on mango
# 0.16.0: a fragment containing `totally bogus !!!! syntax` prints
# "[ERROR]: Invalid line format: ..." and still exits 0, and so does an unknown
# keyword. So the exit status carries no information and testing it is the same
# as not validating at all. What IS reliable is the OUTPUT: a valid file prints
# absolutely nothing (verified against the full live config.conf, 0 bytes).
# Hence: capture stdout+stderr, and treat "any output" as "invalid".
#
# The probe wrapper uses a plain `source=` (NOT source-optional) so that a
# fragment which has gone missing is reported rather than silently accepted.
mango_validate_fragment() {
  local frag="$1" probe out rc=0
  probe="$(mktemp)"
  printf 'source=%s\n' "$frag" > "$probe"
  out="$(mango -c "$probe" -p 2>&1)" || true
  [ -n "$out" ] && { printf '%s\n' "$out" >&2; rc=1; }
  rm -f "$probe"
  return "$rc"
}

# #############################################################################
# ########## END OF EDIT-HERE BOX -- logic below should stay stable ###########
# #############################################################################

die() { echo "set-preset: $*" >&2; exit 1; }
say() { echo "set-preset: $*"; }

DRY_RUN=0

# --help prints this script's own header block (the only copy of its usage).
# Same one-line idiom as the other DankMango scripts, so docs-hub.sh's command
# menu can shell out to it instead of storing a second description.
self_help() { awk 'NR>2 && !/^#/{exit} NR>2 && sub(/^#[ ]?/,"")' "$0"; }

# ---------------------------------------------------------------------------
# Reading a preset's metadata
# ---------------------------------------------------------------------------
# Every preset.conf opens with four "# key: value" lines (preset/label/icon/
# blurb). They are comments, so mango ignores them completely -- they exist so
# that the preset FOLDER is the single source of truth for both this script and
# the launcher plugin, and adding a preset never means editing QML.
#
# meta FILE KEY -> the value, or "" if the line isn't there.
#
# Two deliberate narrownesses, both so that PROSE can't be mistaken for METADATA:
#   * only the first 20 lines are scanned -- the keys belong in the header; and
#   * the pattern is "# key: " with exactly one space, so the indented
#     "#      label:   ..." lines that EXPLAIN these keys further down the same
#     header can never match. (They are inside the 20-line window, so without
#     that they would.)
meta() {
  sed -n "1,20{s/^# $2: *//p}" "$1" 2>/dev/null | head -1
}

# preset_names -> every installed preset's folder name, one per line, sorted,
# with "default" forced first so the baseline always leads the list.
#
# THIS IS THE WHITELIST. It is derived from what actually exists on disk rather
# than being a hardcoded list, so a preset you add yourself works immediately and
# a preset that was removed by an update stops being offered -- with no third
# place to keep in sync. A name that isn't a folder here is refused outright,
# which also means the argument can never reach ln/mv as a path fragment.
preset_names() {
  local d n
  if [ -f "$PRESETS_DIR/default/preset.conf" ]; then printf 'default\n'; fi
  for d in "$PRESETS_DIR"/*/; do
    [ -f "$d/preset.conf" ] || continue
    n="$(basename "$d")"
    if [ "$n" != "default" ]; then printf '%s\n' "$n"; fi
  done | sort
}

is_valid_preset() {
  local n
  while IFS= read -r n; do [ "$n" = "$1" ] && return 0; done < <(preset_names)
  return 1
}

# active_preset -> the name of the preset the symlink currently points at, or ""
# if there is no link / it dangles / it points somewhere unrecognisable.
#
# Derived from the link TARGET (its parent folder's name), never from a
# remembered value, so it reports what mango will actually read -- including the
# case where something outside this script repointed it.
active_preset() {
  local tgt
  [ -L "$ACTIVE_LINK" ] || return 0
  tgt="$(readlink -f "$ACTIVE_LINK" 2>/dev/null)" || return 0
  [ -n "$tgt" ] && [ -f "$tgt" ] || return 0
  basename "$(dirname "$tgt")"
}

# ---------------------------------------------------------------------------
# Listing
# ---------------------------------------------------------------------------
# --porcelain is the plugin's interface: one preset per line, TAB-separated,
#     name <TAB> label <TAB> icon <TAB> blurb <TAB> active(1|0)
# No colours, no headers, no trailing prose -- so the QML can split on \t and
# stop caring about anything else this script prints for humans.
do_list() {
  local porcelain="${1:-0}" n f label icon blurb act cur
  cur="$(active_preset)"
  if [ "$porcelain" = 0 ] && [ ! -d "$PRESETS_DIR" ]; then
    die "no presets folder at $PRESETS_DIR — re-run install.sh from your DankMango clone"
  fi
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    f="$PRESETS_DIR/$n/preset.conf"
    label="$(meta "$f" label)";  [ -n "$label" ] || label="$n"
    icon="$(meta "$f" icon)";    [ -n "$icon" ]  || icon="tune"
    blurb="$(meta "$f" blurb)"
    act=0; [ "$n" = "$cur" ] && act=1
    if [ "$porcelain" = 1 ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$label" "$icon" "$blurb" "$act"
    else
      printf '  %s %-12s %s\n' "$([ "$act" = 1 ] && echo '*' || echo ' ')" "$n" "$blurb"
    fi
  done < <(preset_names)
  if [ "$porcelain" = 0 ]; then
    echo
    if [ -n "$cur" ]; then
      echo "  (* = active)  Switch with:  $0 <name>"
    else
      echo "  No preset is active. Switch with:  $0 default"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Wiring check
# ---------------------------------------------------------------------------
# The one way this whole feature can be silently inert: config.conf not carrying
# the source-optional= line. mango reads a config with no include and reports no
# problem, so without this check a switch would print a cheerful success message
# and change absolutely nothing on screen. WARNS rather than aborts -- the
# symlink is still worth updating so that re-adding the line fixes it at once.
check_wired_up() {
  [ -f "$CONFIG_MAIN" ] || return 0
  grep -qF 'active/preset.conf' "$CONFIG_MAIN" && return 0
  echo "set-preset: WARNING — $CONFIG_MAIN has no preset include line, so presets do nothing yet." >&2
  echo "set-preset:   Add this line near the bottom, after the other source= lines, then press SUPER+r:" >&2
  echo "set-preset:     $REQUIRED_INCLUDE" >&2
  echo "set-preset:   (Re-running install.sh from your DankMango clone also restores it.)" >&2
}

# ---------------------------------------------------------------------------
# Manifest bookkeeping
# ---------------------------------------------------------------------------
# Records the active preset AND the one it replaced under .userPrefs, the same
# place install.sh keeps .userPrefs.mainDisplay -- user preference, not install
# bookkeeping, so an uninstall must never try to "revert" it.
#
# This script is the ONLY writer of .userPrefs.activePreset. lib/common.sh reads
# it and seeds the first switch by calling THIS script; it does not write the key
# itself, so there is exactly one place the value can come from.
#
# Same temp-file + mv shape as manifest_jq() in lib/common.sh, reimplemented here
# rather than sourced because this script ships standalone to
# ~/.config/mango/scripts/ and has no access to the repo's lib/ (the same reason
# apply-combined-osd-patch.sh carries its own copy of the retention constant).
# Best-effort throughout: bookkeeping must never turn a working switch into an
# error, so every failure path is a warning and a zero exit.
manifest_record_preset() {
  local new="$1" old="$2" tmp
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$MANIFEST" ] || return 0
  tmp="$(mktemp)"
  if jq --arg n "$new" --arg o "$old" \
       '.userPrefs = ((.userPrefs // {}) | .activePreset = $n | .previousPreset = $o)' \
       "$MANIFEST" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$MANIFEST"
  else
    rm -f "$tmp"
    echo "set-preset: note — couldn't record the preset in $MANIFEST (harmless; the symlink is what matters)" >&2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
WANT=""
LIST=0
PORCELAIN=0
SHOW_ACTIVE=0

[ "$#" -gt 0 ] || { self_help; exit 0; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)   self_help; exit 0 ;;
    --list|-l)   LIST=1 ;;
    --porcelain) PORCELAIN=1 ;;
    --active)    SHOW_ACTIVE=1 ;;
    --dry-run|-n) DRY_RUN=1 ;;
    -*)          die "unknown option '$1' (try --help)" ;;
    *)           [ -z "$WANT" ] || die "only one preset name at a time (got '$WANT' and '$1')"
                 WANT="$1" ;;
  esac
  shift
done

if [ "$SHOW_ACTIVE" = 1 ]; then
  a="$(active_preset)"
  [ -n "$a" ] || { echo "set-preset: no preset is active" >&2; exit 1; }
  printf '%s\n' "$a"
  exit 0
fi

if [ "$LIST" = 1 ]; then
  do_list "$PORCELAIN"
  exit 0
fi

[ -n "$WANT" ] || die "usage: $0 <name> [--dry-run] | --list | --active   (try --help)"

# ---------------------------------------------------------------------------
# The switch
# ---------------------------------------------------------------------------
[ -d "$PRESETS_DIR" ] || die "no presets folder at $PRESETS_DIR — re-run install.sh from your DankMango clone"

if ! is_valid_preset "$WANT"; then
  { echo "set-preset: no preset called '$WANT'. Installed presets:"
    preset_names | sed 's/^/  /'
  } >&2
  exit 1
fi

TARGET="$PRESETS_DIR/$WANT/preset.conf"
CURRENT="$(active_preset)"

# The header's "preset:" key must agree with the folder name. Cheap, and it
# catches the one mistake people actually make when adding a preset: copying an
# existing folder and forgetting to change the marker inside it. Left as a
# warning rather than a refusal -- the fragment is still valid config, and the
# only thing that misreads is the plugin's "which one is active" highlight.
DECLARED="$(meta "$TARGET" preset)"
if [ -n "$DECLARED" ] && [ "$DECLARED" != "$WANT" ]; then
  echo "set-preset: WARNING — $TARGET says '# preset: $DECLARED' but lives in the '$WANT' folder." >&2
  echo "set-preset:   Fix that line so the launcher marks the right preset active." >&2
fi

# Validate BEFORE touching the live symlink, so a broken fragment can never
# become the thing config.conf includes.
mango_validate_fragment "$TARGET" || die "'$WANT' has an invalid preset.conf (errors above) — nothing was changed"

if [ "$DRY_RUN" = 1 ]; then
  say "(dry-run) nothing was changed. This is what a real run would do:"
  echo "  active preset : ${CURRENT:-<none>}  ->  $WANT"
  echo "  symlink       : $ACTIVE_LINK  ->  $TARGET"
  echo "                  (written to a temp name first, then renamed into place)"
  echo "  reload        : mmsg dispatch reload_config"
  if command -v jq >/dev/null 2>&1 && [ -f "$MANIFEST" ]; then
    echo "  manifest      : .userPrefs.activePreset = \"$WANT\", .previousPreset = \"${CURRENT:-}\""
  else
    echo "  manifest      : skipped (no manifest or no jq — harmless)"
  fi
  echo
  echo "  settings this preset applies on top of your config:"
  grep -vE '^[[:space:]]*(#|$)' "$TARGET" | sed 's/^/    /' || true
  grep -qvE '^[[:space:]]*(#|$)' "$TARGET" || echo "    (none — this preset overrides nothing)"
  exit 0
fi

check_wired_up

if [ "$CURRENT" = "$WANT" ] && [ -L "$ACTIVE_LINK" ]; then
  # Still re-link and reload: "already active" by name can coexist with a link
  # that points at a stale path (a renamed clone, a restored backup), and the
  # cheapest way to be right is to just do the work again. Idempotent either way.
  say "'$WANT' is already active — re-applying it anyway (this is safe)."
fi

mkdir -p "$ACTIVE_DIR"

# ---- THE ATOMIC SWAP --------------------------------------------------------
# Write the new symlink under a temp name in the SAME directory, then rename it
# over the real one. rename(2) is atomic: at every instant the include path is
# either the old preset or the new one, never missing and never half-written. A
# crash, a full disk or a Ctrl-C in the middle leaves a working desktop.
#
# `mv -T` (--no-target-directory) is load-bearing, not decoration: without it,
# mv given an existing symlink as the destination can follow it and move the new
# link INSIDE the target's directory, silently creating
# presets/<name>/preset.conf/... instead of replacing the link. -T forbids that
# reading outright.
TMP_LINK="$ACTIVE_DIR/.preset.conf.new.$$"
rm -f "$TMP_LINK"
ln -s "$TARGET" "$TMP_LINK" || die "couldn't create the new link in $ACTIVE_DIR — is the folder writable?"
if ! mv -Tf "$TMP_LINK" "$ACTIVE_LINK"; then
  rm -f "$TMP_LINK"
  die "couldn't move the new link into place — $ACTIVE_LINK is unchanged (still ${CURRENT:-<none>})"
fi

# Apply live (the SUPER+r equivalent; no logout needed).
mango_reload_config

manifest_record_preset "$WANT" "${CURRENT:-}"

say "preset: ${CURRENT:-<none>} → $WANT"
