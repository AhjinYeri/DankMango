#!/usr/bin/env bash
#
# =============================================================================
#  DankMango shared library  (lib/common.sh)
# =============================================================================
#  Sourced by BOTH install.sh and update.sh so the two share ONE copy of:
#    * pretty-output helpers (stage/ok/info/warn/die/have, ask_yn*)
#    * the file-copy helpers (sys_copy / user_copy) with backup + manifest record
#    * the whole manifest_* bookkeeping family
#    * the package sets (REPO_PKGS / AUR_PKGS / STANDARD_APPS) and seed config
#    * the AUR-helper bootstrap (ensure_aur_helper)
#    * the repo-path -> install-destination routing table (route_dest), used by
#      update.sh to map a changed repo file to the copy action install.sh would do
#    * file_hash, used to stamp/detect per-file installedHash
#
#  This file is a LIBRARY: sourcing it only DEFINES things (plus sets the shared
#  STAMP / colour vars / arrays). It must never take a user-visible action on its
#  own -- no prompts, no installs, no manifest writes happen at source time.
#
#  It does NOT set `set -uo pipefail` or compute REPO_DIR: each entry-point script
#  owns those (REPO_DIR must be resolved from the caller's own location). Every
#  function here that needs REPO_DIR / STAMP / PKG_PRE reads them as globals at
#  CALL time, so the caller just has to have them set before calling.
# =============================================================================

# ---- shared run state (timestamp + warning counter) -------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
WARNINGS=0

# Default wallpaper used to SEED first-boot theming (matugen recolors the whole
# desktop from it — see stage 16). Must be one of the filenames under wallpapers/
# (they get installed to ~/Pictures/Wallpapers/). Change this to pick a different
# out-of-the-box look.
SEED_WALLPAPER="futuristic-cityscape-sunset-stockcake_upscayl_2x_upscayl-standard-4x.png"

# Taskbar/dock apps pinned out of the box. These live in DMS's SessionData
# (~/.local/state/DankMaterialShell/session.json), NOT settings.json, so the
# installer seeds them explicitly (stage 16) — otherwise a fresh install boots
# with an empty taskbar. Values are the exact app IDs DMS matches (.desktop id /
# WM class), taken from a live working setup. Alacritty/nemo/zen come from the core
# package set; discord/steam/Spotify are installed by the stage-3 STANDARD_APPS opt-in
# (issue #5) so these pins aren't dead by default. Edit this list to taste.
SEED_PINNED_APPS=(Alacritty nemo zen Spotify steam discord)

# Which PACKAGE backs each pin above. Stage 16 checks these with `pacman -Qi` and pins
# ONLY what is actually installed, so a declined or failed install can never leave a
# dead icon behind. The names deliberately do NOT match the pin IDs 1:1 -- pins are DMS
# app IDs, these are pacman targets:
#   Alacritty -> alacritty        (base CachyOS+mango install; `pacman -Qi Alacritty` FAILS -- case matters)
#   nemo      -> nemo             (REPO_PKGS, stage 3)
#   zen       -> zen-browser-bin  (AUR_PKGS, stage 3)
#   Spotify   -> spotify-launcher (STANDARD_APPS, stage 3)
#   steam/discord                 (STANDARD_APPS, stage 3 -- these two happen to match)
# If you edit SEED_PINNED_APPS, add the pin's package here too; an unmapped pin falls
# back to using its own name as the package name.
declare -A PIN_PKG=(
    [Alacritty]=alacritty
    [nemo]=nemo
    [zen]=zen-browser-bin
    [Spotify]=spotify-launcher
    [steam]=steam
    [discord]=discord
)

# ---- pretty output ----------------------------------------------------------
c_blu=$'\033[1;34m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
# CUR_STAGE tracks the current stage NUMBER (parsed from the "N/17" label) so the
# manifest helpers can tag each record with the stage that produced it, without
# every call site having to pass it explicitly.
CUR_STAGE="0"
stage() { CUR_STAGE="${1%%/*}"; printf '\n%s==> %s%s\n' "$c_blu" "$1" "$c_off"; }
ok()    { printf '    %s[ ok ]%s %s\n' "$c_grn" "$c_off" "$1"; }
info()  { printf '    %s%s%s\n' "$c_dim" "$1" "$c_off"; }
warn()  { printf '    %s[warn]%s %s\n' "$c_yel" "$c_off" "$1"; WARNINGS=$((WARNINGS+1)); }
die()   { printf '    %s[FAIL]%s %s\n' "$c_red" "$c_off" "$1"; exit 1; }

have()  { command -v "$1" >/dev/null 2>&1; }

# ask_yn "question"  -> returns 0 for yes, 1 for no. Defaults to No on empty.
ask_yn() {
    local ans
    read -r -p "    $1 [y/N] " ans
    case "$ans" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ask_yn_default_yes "question"  -> returns 0 for yes, 1 for no. Defaults to YES on
# empty. Used only for the standard-apps prompt: they're the everyday apps most people
# want out of the box, so yes is the useful default. Declining is harmless — stage 16
# pins only what's actually installed, so a "no" just leaves them out, unpinned.
ask_yn_default_yes() {
    local ans
    read -r -p "    $1 [Y/n] " ans
    case "$ans" in [nN]*) return 1 ;; *) return 0 ;; esac
}

# ask_typed "question" "expected"  -> returns 0 only if the user types EXACTLY the
# expected word (case-insensitively). Deliberately NOT a y/N prompt: this is for the
# one gate that shouldn't be blow-through-able by a reflexive Enter or a stray "y".
ask_typed() {
    local ans
    read -r -p "    $1 " ans
    [ "${ans,,}" = "${2,,}" ]
}

# ---- main-display selection --------------------------------------------------
# Which monitor is "the main one" is a USER preference — nothing can infer it from
# hardware (biggest/leftmost is a guess, and often wrong for a desk with a small
# primary and a big secondary). So we ask, once, and store the answer in the
# manifest under .userPrefs.mainDisplay.
#
# That key is read by scripts/monitor-watcher.sh, which keeps
# $XDG_RUNTIME_DIR/mango-monitor-watcher/effective-main-display current and
# regenerates the main-display windowrules. Nothing else may write the key: if the
# chosen monitor is unplugged, the watcher stands in a temporary replacement but
# deliberately leaves the stored preference alone, so a replug restores intent.
#
# Kept HERE rather than in install.sh because `install.sh --reselect-main-display`
# re-runs exactly this prompt later (a user who dismissed the watcher's drift
# notification needs a way back without waiting for the next hotplug).

# monitor_names_for_prompt -> connected output names, one per line. Delegates to
# generate-tagrules.sh --list-outputs so the mmsg query lives in exactly ONE place
# (that script's EDIT-HERE box) and a mango rename is a one-file fix.
#
# The --list-outputs support check is STATIC (grep) and not optional: an older
# generator without the flag ignores it and does its normal job instead, which
# REWRITES tagrules.conf and resets every monitor to the tile layout. Probing by
# running it would cause exactly the damage the check exists to avoid. The output
# is then filtered to bare output names, so the generator's human-readable progress
# lines can never be mistaken for monitors.
monitor_names_for_prompt() {
    local gen
    for gen in "$REPO_DIR/config/mango/scripts/generate-tagrules.sh" \
               "$HOME/.config/mango/scripts/generate-tagrules.sh"; do
        [ -x "$gen" ] || continue
        grep -q -- '--list-outputs' "$gen" || continue
        "$gen" --list-outputs 2>/dev/null | grep -xE '[A-Za-z0-9._-]+'
        return 0
    done
    return 1
}

# _ordinal N -> "1st", "2nd", "3rd", "4th"... Handles the 11th/12th/13th exception,
# which the naive last-digit rule gets wrong. Nobody is plugging in eleven monitors,
# but the rule costs one case statement and a wrong ordinal reads as a bug.
_ordinal() {
    local n="$1"
    case $(( n % 100 )) in
        11|12|13) printf '%dth' "$n"; return ;;
    esac
    case $(( n % 10 )) in
        1) printf '%dst' "$n" ;;
        2) printf '%dnd' "$n" ;;
        3) printf '%drd' "$n" ;;
        *) printf '%dth' "$n" ;;
    esac
}

# select_main_display  -> prompts, writes .userPrefs.mainDisplay, returns 0.
# Returns 1 (with an explanatory info/warn) when it can't run: mango not up, no
# outputs, whiptail missing, or the user cancelled. Never fatal — the whole feature
# is optional, and the watcher treats "nothing stored" as a valid steady state.
select_main_display() {
    local -a names=()
    mapfile -t names < <(monitor_names_for_prompt)
    if [ "${#names[@]}" -eq 0 ]; then
        warn "couldn't list monitors (is MangoWM running?) — skipping game-display selection"
        info "set it later with:  ./install.sh --reselect-main-display"
        return 1
    fi

    # One monitor: nothing to choose. Store it silently rather than making the user
    # confirm the only possible answer — and it still gets recorded, so plugging in
    # a second monitor later behaves correctly from the first moment.
    if [ "${#names[@]}" -eq 1 ]; then
        _store_main_display "${names[0]}" && ok "game display: ${names[0]} (only monitor connected)"
        return $?
    fi

    if ! have whiptail; then
        warn "whiptail not found — skipping game-display selection"
        info "set it later with:  ./install.sh --reselect-main-display"
        return 1
    fi

    # One geometry snapshot, reused for ordering, labels and the default pick, so the
    # list can't be built from two different moments in time.
    local geom; geom="$(mmsg get all-monitors 2>/dev/null)"

    # Order the monitors LEFT TO RIGHT by x. Physical position is the only thing a
    # user reliably knows about their own desk — "DP-2" means nothing, "2nd from
    # left" is unambiguous at any monitor count (unlike "middle", which stops working
    # the moment there are four).
    # KNOWN LIMIT, deliberately not solved: purely horizontal. A vertically stacked
    # pair shares an x and will read as two adjacent ordinals. Out of scope.
    local -a ordered=()
    mapfile -t ordered < <(
        local nm x
        for nm in "${names[@]}"; do
            x="$(printf '%s' "$geom" | jq -r --arg m "$nm" '.monitors[]|select(.name==$m)|.x' 2>/dev/null)"
            case "$x" in ''|null) x=999999 ;; esac   # unknown geometry sorts last, never drops the row
            printf '%s\t%s\n' "$x" "$nm"
        done | sort -n -k1,1 -k2,2 | cut -f2
    )
    [ "${#ordered[@]}" -gt 0 ] || ordered=("${names[@]}")

    # Pre-select whatever is already stored, else the leftmost monitor — the same
    # tie-break the watcher uses for its temporary stand-in, so the suggested answer
    # matches what the system would do on its own.
    local current=""
    [ -f "$MANIFEST" ] && have jq && current="$(jq -r '.userPrefs.mainDisplay // empty' "$MANIFEST" 2>/dev/null)"
    local default_pick="$current"
    [ -n "$default_pick" ] || default_pick="${ordered[0]}"

    # Radiolist rows: TAG "description" ON/OFF. whiptail always renders the TAG
    # column first, so the connector leads and the description carries the position
    # and resolution. The tag has to stay the connector: it is the return value and
    # what gets stored.
    local -a rows=() n desc res i=0
    for n in "${ordered[@]}"; do
        i=$((i + 1))
        res="$(printf '%s' "$geom" | jq -r --arg m "$n" \
            '.monitors[]|select(.name==$m)|"\(.width)x\(.height)"' 2>/dev/null)"
        desc="$(_ordinal "$i") from left"
        [ -n "$res" ] && [ "$res" != "null" ] && desc="$desc  $res"
        rows+=("$n" "$desc" "$([ "$n" = "$default_pick" ] && echo ON || echo OFF)")
    done

    # Height: fixed chrome (title, body, buttons) + one line per monitor, so the box
    # grows with the list instead of clipping it on a 3+ monitor desk. The constant
    # counts the WRAPPED body lines, so re-count it if you edit the prompt text --
    # it went 14 -> 15 when the "nothing else moves" sentence was added below.
    local box_h=$(( 15 + ${#ordered[@]} ))

    local choice
    choice="$(whiptail --title "DankMango — game display" \
        --radiolist "Which monitor should GAMES open on?\n\nGames launched from Steam are sent here instead of wherever the mouse happens to be. Nothing else moves — this is not a general default screen. You can change it later with:\n  ./install.sh --reselect-main-display\n\nMove: ↑/↓ or Ctrl-P/Ctrl-N   Select: Space   Confirm: Enter" \
        "$box_h" 74 "${#ordered[@]}" "${rows[@]}" 3>&1 1>&2 2>&3)" || {
        info "game-display selection cancelled — nothing stored"
        info "set it later with:  ./install.sh --reselect-main-display"
        return 1
    }
    [ -n "$choice" ] || { info "no monitor picked — nothing stored"; return 1; }

    _store_main_display "$choice" && ok "game display: $choice"
}

# _store_main_display NAME — the one writer of .userPrefs.mainDisplay on the
# install side. userPrefs is created if absent and otherwise left alone: it is user
# preference, NOT install bookkeeping, so uninstall must not try to revert it.
_store_main_display() {
    local name="$1"
    [ -f "$MANIFEST" ] || { warn "no manifest yet — cannot store the game display"; return 1; }
    manifest_jq '.userPrefs = ((.userPrefs // {}) | .mainDisplay = $n)' --arg n "$name" || return 1
    # Make it take effect now rather than at the next hotplug: the watcher owns the
    # generated windowrules, so ask it to refresh them (no-op if it isn't installed).
    local watcher="$HOME/.config/mango/scripts/monitor-watcher.sh"
    [ -x "$watcher" ] && "$watcher" --once >/dev/null 2>&1
    return 0
}

# ---- desktop presets ---------------------------------------------------------
# A "preset" is a named bundle of MangoWM settings swapped as a unit (see
# config/mango/presets/README.md). config.conf includes ONE fixed path,
# ~/.config/mango/active/preset.conf, which is a symlink into a preset folder;
# switching presets repoints that symlink.
#
# OWNERSHIP, and it is the whole reason these are only THREE lines: scripts/
# set-preset.sh is the SOLE writer of both the symlink and the manifest key.
# Nothing here writes either. install.sh seeds the first preset by CALLING that
# script (seed_active_preset below), exactly as _store_main_display applies the
# main display by calling monitor-watcher.sh rather than duplicating its logic.
# So there is one implementation of "switch preset", and it is the one the
# launcher plugin and the user's terminal also go through.
ACTIVE_PRESET_LINK="$HOME/.config/mango/active/preset.conf"
DEFAULT_PRESET="default"

# manifest_active_preset -> the remembered preset name, or "" if none/unknown.
# READ-ONLY. For reporting; the symlink, not this key, is what mango obeys, so
# treat a disagreement between the two as "the symlink is right".
manifest_active_preset() {
    [ -f "$MANIFEST" ] || return 0
    have jq || return 0
    jq -r '.userPrefs.activePreset // empty' "$MANIFEST" 2>/dev/null
}

# seed_active_preset — make sure SOME preset is active, once, at install time.
#
# Deliberately does nothing if the symlink already exists: re-running install.sh
# must never reset a preset the user chose. It is also non-fatal in every failure
# mode — the include is source-OPTIONAL, so "no preset active" is a valid steady
# state that simply means baseline behaviour, not a broken desktop.
seed_active_preset() {
    local setter="$HOME/.config/mango/scripts/set-preset.sh"
    if [ -L "$ACTIVE_PRESET_LINK" ]; then
        info "desktop preset: keeping your current choice ($(basename "$(dirname "$(readlink -f "$ACTIVE_PRESET_LINK" 2>/dev/null)")" 2>/dev/null))"
        return 0
    fi
    if [ ! -x "$setter" ]; then
        warn "set-preset.sh not found/executable at $setter — no desktop preset activated."
        info "Was config/mango/scripts/ copied in stage 7a? Then run: $setter $DEFAULT_PRESET"
        return 1
    fi
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "(dry-run) would activate the '$DEFAULT_PRESET' desktop preset"
        return 0
    fi
    if "$setter" "$DEFAULT_PRESET" >/dev/null 2>&1; then
        ok "desktop preset: $DEFAULT_PRESET (change it from the launcher — type \"preset\")"
    else
        warn "couldn't activate the '$DEFAULT_PRESET' preset — harmless; the desktop just uses its baseline settings."
        info "try it by hand to see why:  $setter $DEFAULT_PRESET"
        return 1
    fi
    return 0
}

# ---- backup retention -------------------------------------------------------
# How many timestamped backups to keep PER ORIGINAL FILE. Tune it here and nowhere
# else — no other line in this repo knows the number. Deliberately mirrors
# DANKMANGO_SNAPSHOT_RETAIN in update.sh, which caps snapper snapshots the same way.
#
# Also hardcoded in config/mango/scripts/apply-combined-osd-patch.sh, which prunes
# ~/.config/mango/backups and ships standalone (it can't source this file) — keep the
# two in sync.
DANKMANGO_BACKUP_RETAIN=10

# prune_file_backups ORIGINAL [NEED_SUDO] — never returns non-zero, by design.
#
# Every overwrite leaves ORIGINAL.bak-<stamp> beside the original, so a file touched
# by twenty updates ends up with twenty copies that nothing ever removed. This keeps
# the newest $DANKMANGO_BACKUP_RETAIN and deletes our older ones. It's called right
# after a new backup is written, so each file prunes its own history — same shape as
# prune_dankmango_snapshots in update.sh, and for the same reason: housekeeping of our
# own artifacts should just happen, with no prompt and no report line unless something
# was actually tidied.
#
# THE ONE RULE: a file is ours ONLY if it is exactly ORIGINAL.bak-YYYYmmdd-HHMMSS.
# Hand-made and other-script backups share the .bak- prefix but not the shape
# (.bak-altswitcher, .bak-logout, .bak-transp, .bak-pre-blur-<stamp>, .bak-0.14-<stamp>),
# and quietly deleting somebody's labelled safety copy is unforgivable — so the stamp is
# matched STRICTLY, digit by digit, and anything else is left alone. That strictness is
# also what makes the rm below safe on a directory: the only way to match is to be a
# sibling of a path we just backed up ourselves.
#
# Sorted by the STAMP IN THE NAME, never by mtime. Backups are made with `cp -a`, which
# preserves the ORIGINAL's mtime — so a backup's mtime is the age of its CONTENT, not
# the moment the backup was taken, and sorting by it would delete the wrong files. The
# stamp format sorts lexicographically in chronological order, so plain `sort` is right.
prune_file_backups() {
    local orig="${1:-}" need_sudo="${2:-0}" f total cut
    local -a found=() doomed=() rm_cmd=(rm -rf)
    [ -n "$orig" ] || return 0
    [ "$need_sudo" = 1 ] && rm_cmd=(sudo rm -rf)

    while IFS= read -r f; do
        [ -n "$f" ] && found+=("$f")
    done < <(compgen -G "$orig.bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]" 2>/dev/null | sort)

    total=${#found[@]}
    [ "$total" -gt "$DANKMANGO_BACKUP_RETAIN" ] || return 0   # under the cap — stay quiet
    cut=$(( total - DANKMANGO_BACKUP_RETAIN ))
    doomed=( "${found[@]:0:cut}" )                            # the oldest $cut, and only those

    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "(dry-run) would tidy $cut older backup(s) of $(basename "$orig"), keeping the most recent $DANKMANGO_BACKUP_RETAIN"
        return 0
    fi
    if "${rm_cmd[@]}" "${doomed[@]}" 2>/dev/null; then
        info "tidied $cut older backup(s) of $(basename "$orig") — the most recent $DANKMANGO_BACKUP_RETAIN are kept."
    else
        warn "couldn't tidy $cut older backup(s) of $orig — left in place. Harmless; they only take up space."
    fi
    return 0
}

# Copy a SYSTEM file (needs sudo). Backs up an existing, differing target.
# Records the backup (if any) and a system-file-installed change in the manifest,
# noting whether the target pre-existed (so uninstall knows: restore vs. delete).
#   sys_copy SRC DST
#
# EVERY cp here is checked, and that is not defensive padding -- an unchecked one
# is how a file goes silently stale FOREVER. The old version ran `cp` bare, then
# unconditionally printed "installed" and recorded the SOURCE's hash in the
# manifest. So a copy that failed (sudo declined or timed out, target read-only,
# disk full) was reported as a success, counted in update.sh's "FILES updated"
# list, and left the manifest asserting a hash the file on disk does not have.
# Nothing downstream could ever notice: the recorded hash matches the repo, so
# update.sh's edit-detection sees "unchanged", and the file is not in any FUTURE
# delta -- a later update only re-copies what changed in ITS commit range, so it
# never revisits the one that got missed. One failed write, silently permanent.
sys_copy() {
    local src="$1" dst="$2"
    if [ ! -f "$src" ]; then
        warn "repo is missing '$src' -> skipping (nothing to install for this step yet)"
        return 1
    fi
    sudo mkdir -p "$(dirname "$dst")"
    local existed=0
    if [ -f "$dst" ]; then
        existed=1
        if ! sudo cmp -s "$src" "$dst"; then
            # Backup first, and STOP if it fails: never overwrite a file we've just
            # proven we can't make a restore point for. (In practice a failed backup
            # means the directory isn't writable, so the copy below would fail too --
            # this just fails at the safe end of that.)
            if ! sudo cp -a "$dst" "$dst.bak-$STAMP"; then
                warn "couldn't back up $dst — leaving it UNCHANGED rather than overwriting a file we can't restore."
                return 1
            fi
            info "backed up existing $dst -> $dst.bak-$STAMP"
            manifest_add_backup "$dst" "$dst.bak-$STAMP" system "$CUR_STAGE"
            prune_file_backups "$dst" 1
        fi
    fi
    if ! sudo cp "$src" "$dst"; then
        warn "couldn't write $dst — it is UNCHANGED (still the old version). Nothing was recorded for it, so this update is NOT finished. Fix the cause (admin rights, read-only file, full disk) and re-run install.sh."
        return 1
    fi
    ok "installed $dst"
    if have jq; then
        local h; h="$(file_hash "$src")"
        manifest_add_change system-file-installed "$CUR_STAGE" "$dst" \
            "$(jq -nc --arg p "$dst" --argjson pre "$existed" --arg h "$h" '{path:$p, preexisting:($pre==1), scope:"system", hash:$h}')" \
            "$( [ "$existed" = 1 ] && printf 'preexisting; restore its .bak-* if one was made' || printf 'sudo rm %s' "$dst" )"
    fi
    return 0
}

# Copy a USER file (no sudo). Backs up an existing, differing target. Same manifest
# bookkeeping as sys_copy, scoped "user".
#   user_copy SRC DST
#
# Same checked-cp rule as sys_copy, and for the same reason -- see the long note
# there. This is the path every ~/.config/mango/scripts/*.sh goes through on an
# update, so an unchecked failure here is exactly how a machine ends up running a
# shipped DankMango script that is several releases old while the updater reports
# a clean run.
user_copy() {
    local src="$1" dst="$2"
    if [ ! -f "$src" ]; then
        warn "repo is missing '$src' -> skipping this step"
        return 1
    fi
    mkdir -p "$(dirname "$dst")"
    local existed=0
    if [ -f "$dst" ]; then
        existed=1
        if ! cmp -s "$src" "$dst"; then
            if ! cp -a "$dst" "$dst.bak-$STAMP"; then
                warn "couldn't back up $dst — leaving it UNCHANGED rather than overwriting a file we can't restore."
                return 1
            fi
            info "backed up existing $dst -> $dst.bak-$STAMP"
            manifest_add_backup "$dst" "$dst.bak-$STAMP" user "$CUR_STAGE"
            prune_file_backups "$dst"
        fi
    fi
    if ! cp "$src" "$dst"; then
        warn "couldn't write $dst — it is UNCHANGED (still the old version). Nothing was recorded for it, so this update is NOT finished. Fix the cause (read-only file, full disk) and re-run install.sh."
        return 1
    fi
    ok "installed $dst"
    if have jq; then
        local h; h="$(file_hash "$src")"
        manifest_add_change user-file-installed "$CUR_STAGE" "$dst" \
            "$(jq -nc --arg p "$dst" --argjson pre "$existed" --arg h "$h" '{path:$p, preexisting:($pre==1), scope:"user", hash:$h}')" \
            "$( [ "$existed" = 1 ] && printf 'preexisting; restore its .bak-* if one was made' || printf 'rm %s' "$dst" )"
    fi
    return 0
}

# ---- install manifest -------------------------------------------------------
# A queryable record of what THIS DankMango run did — packages we installed (NOT
# ones already present), files we backed up, and system-level changes — so the
# future uninstaller/updater don't have to re-derive it from scattered .bak files.
# Lives in XDG_STATE_HOME (persistent STATE, not config/cache), beside DMS's own
# session.json, so it outlives the repo clone. Best-effort: a failed manifest write
# WARNS and never aborts the install. Every helper is idempotent on a natural key,
# so re-running install.sh never duplicates entries.
MANIFEST_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dankmango"
MANIFEST="$MANIFEST_DIR/manifest.json"

# Atomically apply a jq filter to the manifest (temp file + mv). No-op+warn if jq
# is unavailable or the edit fails — bookkeeping must never break the install.
manifest_jq() {
    local filter="$1"; shift
    have jq || { warn "jq unavailable — a manifest update was skipped (record is incomplete)"; return 1; }
    [ -f "$MANIFEST" ] || return 1
    local tmp; tmp="$(mktemp)"
    if jq "$@" "$filter" "$MANIFEST" > "$tmp" && [ -s "$tmp" ]; then
        mv "$tmp" "$MANIFEST"
    else
        rm -f "$tmp"; warn "a manifest update failed (jq) — record may be incomplete"; return 1
    fi
}

# Create the manifest on first run (full skeleton via printf/heredoc — NO jq needed,
# so a jq-less fresh system or a crash before stage 3 installs jq still leaves valid,
# version-stamped JSON). On a re-run (jq guaranteed by then) refresh run metadata.
# Captures DankMango's git commit + version so the updater knows what it upgrades from.
manifest_init() {
    mkdir -p "$MANIFEST_DIR"
    local commit version now
    commit="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    version="$(git -C "$REPO_DIR" describe --tags --always --dirty 2>/dev/null || echo unknown)"
    now="$(date --iso-8601=seconds 2>/dev/null || date)"
    if [ ! -f "$MANIFEST" ]; then
        # Values here are trusted local strings (a git sha, git-describe output, and a
        # $HOME-rooted path from pwd) — no untrusted input, so heredoc JSON is safe.
        cat > "$MANIFEST" <<JSON
{
  "manifestVersion": 1,
  "dankmango": {
    "version": "$version",
    "commit": "$commit",
    "repoDir": "$REPO_DIR",
    "firstInstall": { "at": "$now", "commit": "$commit" },
    "lastRunAt": "$now",
    "runs": ["$STAMP"],
    "lastAppliedCommit": null,
    "status": "in-progress"
  },
  "packages": [],
  "packagesSkipped": [],
  "packagesFailed": [],
  "backups": [],
  "systemChanges": [],
  "migrationsApplied": []
}
JSON
        ok "created install manifest -> $MANIFEST"
    else
        # firstInstall is preserved (not touched); refresh current version/run info.
        manifest_jq '
            .dankmango.version   = $version
          | .dankmango.commit    = $commit
          | .dankmango.repoDir   = $repo
          | .dankmango.lastRunAt = $now
          | .dankmango.runs      = ((.dankmango.runs // []) + [$stamp] | unique)
          | .dankmango.status    = "in-progress"
          | .dankmango.lastAppliedCommit = (.dankmango.lastAppliedCommit // null)
          | .migrationsApplied   = (.migrationsApplied // [])
        ' --arg version "$version" --arg commit "$commit" --arg repo "$REPO_DIR" \
          --arg now "$now" --arg stamp "$STAMP" \
          && info "updated existing install manifest -> $MANIFEST" \
          || info "existing manifest at $MANIFEST"
    fi
}

# manifest_add_package NAME SOURCE CATEGORY  — packages WE installed (ours to remove
# later). Dedupe by name. SOURCE = repo|aur ; CATEGORY = required|standard-app|optional-feature.
# Also clears any earlier packagesFailed entry: a package that installs on a later run is
# no longer failed, and a stale "failed" record is worse than none.
manifest_add_package() {
    manifest_jq '
        .packages = ([ .packages[] | select(.name != $n) ]
                     + [{name:$n, source:$s, category:$c, stamp:$stamp}])
      | .packagesFailed = [ (.packagesFailed // [])[] | select(.name != $n) ]
    ' --arg n "$1" --arg s "$2" --arg c "$3" --arg stamp "$STAMP"
}

# manifest_add_failed NAME SOURCE CATEGORY  — we TRIED to install it and it is still not
# there (see manifest_record_pkgs). Recorded so a failure survives the terminal scrollback
# that hid it on the laptop install: `jq .packagesFailed ~/.local/state/dankmango/manifest.json`
# answers "did anything fail?" long after the install output is gone. NOT ours to remove --
# an uninstaller must ignore this list; it exists purely to report. Cleared automatically
# once the package shows up (see manifest_add_package / manifest_add_skipped).
manifest_add_failed() {
    manifest_jq '
        .packagesFailed = ([ (.packagesFailed // [])[] | select(.name != $n) ]
                           + [{name:$n, source:$s, category:$c, stamp:$stamp}])
    ' --arg n "$1" --arg s "$2" --arg c "$3" --arg stamp "$STAMP"
}

# manifest_add_skipped NAME REASON  — packages present BEFORE us (never ours; the
# uninstaller must not touch them). Dedupe by name. Also clears any earlier
# packagesFailed entry (it failed once, the user installed it by hand, it's here now).
manifest_add_skipped() {
    manifest_jq '
        .packagesSkipped = ([ .packagesSkipped[] | select(.name != $n) ]
                            + [{name:$n, reason:$r, stamp:$stamp}])
      | .packagesFailed = [ (.packagesFailed // [])[] | select(.name != $n) ]
    ' --arg n "$1" --arg r "$2" --arg stamp "$STAMP"
}

# manifest_add_backup ORIGINAL BACKUP SCOPE STAGE  — dedupe by ORIGINAL and KEEP THE
# FIRST: the earliest backup holds the true pre-DankMango file; a re-run would only
# back up our own already-installed copy, which is useless for restore.
manifest_add_backup() {
    manifest_jq '
        if (.backups | map(.original) | index($o)) then .
        else .backups += [{original:$o, backup:$b, scope:$scope, stage:$stage, stamp:$stamp}] end
    ' --arg o "$1" --arg b "$2" --arg scope "$3" --arg stage "$4" --arg stamp "$STAMP"
}

# manifest_add_change TYPE STAGE KEY DETAIL_JSON [REVERSAL]  — a system-level change.
# Dedupe by (type + KEY). DETAIL_JSON must be a valid JSON object string (build it with
# `jq -nc ...` at the call site so values are escaped). REVERSAL is a short hint string.
manifest_add_change() {
    local type="$1" stage="$2" key="$3" detail="$4" reversal="${5:-}"
    manifest_jq '
        ($type + "|" + $key) as $sig
      | .systemChanges = ([ .systemChanges[] | select((.type + "|" + (.key // "")) != $sig) ]
          + [{type:$type, stage:$stage, key:$key, stamp:$stamp, detail:($detail|fromjson), reversal:$reversal}])
    ' --arg type "$type" --arg stage "$stage" --arg key "$key" \
      --arg detail "$detail" --arg reversal "$reversal" --arg stamp "$STAMP"
}

# Mark the run complete (final stage). Partial runs keep status "in-progress".
# ALSO stamps lastAppliedCommit = the commit recorded at init — done HERE, after all
# work, so it reflects a commit that was actually APPLIED end-to-end. This is the fix
# for the commit-timing gap: .dankmango.commit is written at init (run start), so a
# crashed run leaves it pointing at a HEAD that wasn't fully applied; lastAppliedCommit
# only advances on success, so update.sh can trust it (gated on status == "complete").
manifest_finalize() {
    manifest_jq '
        .dankmango.status = "complete"
      | .dankmango.lastAppliedCommit = .dankmango.commit
    '
}

# ---- package sets (moved verbatim from install.sh stage 3) ------------------
# Official-repo packages (the AUR helper pulls these straight from the repos).
# rsync: NOT part of a base CachyOS install. It's no longer needed by the SDDM
# stage (DankMango's own login theme replaced the astronaut theme's apply.sh, which
# was the thing that needed it), but it stays pinned: an existing v1.x user who has
# not cut over yet still re-runs that apply.sh by hand, and it would be a poor trade
# to break their login-screen tooling to save one small, universally-useful package.
# jq: relied on all over this rice (the tagrules generator, the taskbar-pin +
# wallpaper seeds, the popupTransparency edit). It's only incidentally present on
# some systems (pulled in by scx-scheds etc.), so pin it explicitly here.
# cava: the runtime backend for DMS's built-in Media-widget audio waveform. Without
# it CavaService.cavaAvailable is false and the widget silently falls back to a static
# icon (issue #3). Not in a base install, so pin it here.
# loupe: GNOME's image viewer, made the default for the common image types in stage 4.
# A base CachyOS+mango install ships no image viewer at all, so double-clicking a photo
# in Nemo does nothing until something claims those mimetypes.
# celluloid: the same gap for VIDEO -- a base install has nothing that opens a video
# file either. GTK4/libadwaita front-end to mpv, so it matches the rest of the rice
# (and config/gtk-4.0/celluloid-transparency.css themes it). Made the default for the
# common video types in stage 4, same guarded pattern as loupe.
# imagemagick: `magick` is what scripts/sddm-palette-sync.sh uses to downscale and
# re-encode the wallpaper into the login theme's slot files. Without it the palette
# still syncs but the login screen keeps a stale/blank backdrop, silently (the script
# logs and exits 0 by design). It's NOT part of a base CachyOS install -- on this dev
# box it was only present as a zbar dependency -- so pin it explicitly.
REPO_PKGS=(nemo nemo-fileroller loupe celluloid matugen cosmic-icon-theme xdg-desktop-portal-wlr keyd rsync jq cava imagemagick satty)
# AUR packages that DankMango needs.
#
# sddm-astronaut-theme was REMOVED from this list when DankMango grew its own login
# theme (system/sddm/themes/dankmango). Two things follow from that, and both are
# deliberate:
#   * Existing v1.x installs keep the package. Nothing here uninstalls it -- their
#     login screen is still SERVED by it until they flip Current= by hand, and pulling
#     the package out from under an active greeter is how you get a black login screen.
#     It stays in their manifest's .packages, so uninstall.sh still offers to remove it.
#   * system/sddm/sddm-astronaut-japanese/ stays in the repo for the same reason. If it
#     were deleted, update.sh's retire_file() would offer to remove the very config dir
#     those users' working login screen is built from. It's inert for new installs
#     (nothing copies it any more) and costs a few hundred KB.
AUR_PKGS=(zen-browser-bin)
# Standard taskbar apps (issue #5): the SEED_PINNED_APPS set minus what's already
# core-installed (Alacritty/nemo/zen). OPTIONAL + opt-in (default yes). Declining is
# safe: stage 16 pins only what is actually installed, so a skipped app is simply not
# pinned rather than left as a dead icon. All
# three are official-repo on CachyOS -- no AUR build needed. steam pulls multilib libs
# (multilib is enabled by default on CachyOS). Spotify ships as spotify-launcher (the
# official launcher; it fetches the real client on first run).
STANDARD_APPS=(discord steam spotify-launcher)
# NOTE: intentionally NOT installed here (CachyOS + MangoWM base already ships
# them): sddm, alacritty, the pipewire stack, wireplumber, networkmanager,
# power-profiles-daemon, bluez, fonts (noto / meslo-nerd), jq, libnotify, gawk,
# psmisc, xdg-desktop-portal-core. And capitaine-cursors is NOT used at all.

# manifest_record_pkgs SRC CAT pkg...  — from the pre-snapshot: preexisting -> skipped
# (not ours); newly present -> ours; still absent -> the install we just attempted FAILED,
# so record it as failed. Only ever called right AFTER an install attempt (never on the
# declined path, which records its own skips), so "absent" here unambiguously means the
# attempt failed rather than "was never tried".
manifest_record_pkgs() {
    local src="$1" cat="$2"; shift 2
    local p
    for p in "$@"; do
        if [ "${PKG_PRE[$p]:-0}" = "1" ]; then
            manifest_add_skipped "$p" already-installed
        elif pacman -Qi "$p" >/dev/null 2>&1; then
            manifest_add_package "$p" "$src" "$cat"
        else
            manifest_add_failed "$p" "$src" "$cat"
        fi
    done
}

# ---- AUR helper bootstrap (moved verbatim from install.sh stage 2) ----------
# Sets the global $AUR to paru|yay, bootstrapping paru from the AUR if neither is
# present. Body is byte-identical to the old inline stage-2 code; install.sh now
# calls this between its stage banner and the "using AUR helper" line.
ensure_aur_helper() {
AUR=""
if have paru; then AUR="paru"
elif have yay; then AUR="yay"
fi
if [ -z "$AUR" ]; then
    info "No AUR helper found — bootstrapping paru from the AUR."
    sudo pacman -S --needed --noconfirm base-devel git || die "couldn't install base-devel/git (needed to build paru)"
    tmp="$(mktemp -d)"
    if git clone https://aur.archlinux.org/paru.git "$tmp/paru"; then
        ( cd "$tmp/paru" && makepkg -si --noconfirm ) || die "paru build failed — install paru or yay manually, then re-run."
        AUR="paru"
        rm -rf "$tmp"
    else
        die "couldn't clone paru from the AUR — check your network, then re-run."
    fi
fi
}

# ---- file hashing (installedHash) -------------------------------------------
# file_hash PATH -> sha256 hex of the file's contents, or "" if missing / no
# hasher. Used to stamp installedHash when a file is written, and (in update.sh)
# to detect that the user edited an installed file since DankMango wrote it.
file_hash() {
    [ -f "$1" ] || { printf ''; return; }
    if have sha256sum; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif have shasum; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    else printf ''; fi
}

# =============================================================================
# SDDM login theme (DankMango's own)
# =============================================================================
# Shared by install.sh (stage 5b) and update.sh (the migration + the
# dankmango-sddm-theme route), so the ownership rules and the "we do NOT flip
# Current= for you" policy live in exactly one place.
SDDM_THEME_ID="dankmango"
# DANKMANGO_SDDM_THEME_DIR is a TESTING hook, and the same one scripts/sddm-palette-sync.sh
# already documents: point it at a scratch dir to exercise the install/update/retire
# paths without root and without touching the real login screen. Unset in normal use.
SDDM_THEME_DEST="${DANKMANGO_SDDM_THEME_DIR:-/usr/share/sddm/themes/$SDDM_THEME_ID}"
# The drop-in DankMango would write if/when it ever flips the active theme.
# /etc/sddm.conf.d/*.conf is read AFTER /etc/sddm.conf, so a drop-in wins over the
# main file; within the directory it is plain alphabetical order, last one wins.
SDDM_THEME_CONF="/etc/sddm.conf.d/theme.conf"

# ---- THE DEFERRED CUTOVER ---------------------------------------------------
# Setting Current= is the ONE step in this whole project that can leave a machine
# with no usable login screen, and the failure mode is discovered at reboot, long
# after the installer's output has scrolled away. So it is opt-in, and OFF:
#
#     DANKMANGO_SDDM_SET_CURRENT=1 ./install.sh
#
# The code path below is fully written and exercised by that flag -- it is gated,
# not commented out, so the cutover session can dry-run the exact code that will
# run for real. Until someone sets the flag, install.sh/update.sh deploy the theme
# and print the one-liner, and the live login screen is not touched at all.
SDDM_SET_CURRENT="${DANKMANGO_SDDM_SET_CURRENT:-0}"

# sddm_current_theme -> prints "VALUE<TAB>FILE" for the Current= that is in effect
# right now, or nothing if no file sets one (SDDM then falls back to its built-in
# default). Scans in SDDM's own precedence order and keeps the LAST match, so the
# answer is the one the greeter will actually use.
sddm_current_theme() {
    local f val out=""
    for f in /etc/sddm.conf /etc/sddm.conf.d/*.conf; do
        [ -f "$f" ] || continue
        # Uncommented `Current=` only; take the last one in the file.
        val="$(sed -n 's/^[[:space:]]*Current[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$f" 2>/dev/null | tail -1)"
        [ -n "$val" ] && out="$val"$'\t'"$f"
    done
    [ -n "$out" ] && printf '%s\n' "$out"
}

# Warn if a drop-in that sorts AFTER ours also sets Current=: our write would be
# silently overridden, which looks exactly like "the cutover didn't work".
sddm_warn_shadowing_dropin() {
    local base f shadow=0
    base="$(basename "$SDDM_THEME_CONF")"
    for f in /etc/sddm.conf.d/*.conf; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" \> "$base" ] || continue
        grep -qE '^[[:space:]]*Current[[:space:]]*=' "$f" 2>/dev/null || continue
        warn "$f also sets Current= and sorts after $base — it would override our theme."
        shadow=1
    done
    return "$shadow"
}

# sddm_theme_install [--quiet] -- run the theme's own install.sh under sudo.
# That script owns the ownership split (root-owned dir + QML, user-writable
# theme.conf.user / wallpaper-[ab].jpg leaves); duplicating it here would mean two
# places to get a pre-auth privilege boundary right. Returns non-zero on failure.
sddm_theme_install() {
    local src="$REPO_DIR/system/sddm/themes/$SDDM_THEME_ID" quiet=0
    [ "${1:-}" = "--quiet" ] && quiet=1
    if [ ! -x "$src/install.sh" ]; then
        warn "no theme installer at $src/install.sh — skipping the login theme."
        return 1
    fi
    have sudo || { warn "sudo not available — can't install the login theme."; return 1; }
    if [ "$quiet" = 1 ]; then
        sudo "$src/install.sh" --user "$(id -un)" >/dev/null 2>&1
    else
        sudo "$src/install.sh" --user "$(id -un)"
    fi
}

# Print the manual cutover instructions. Used by install.sh and by the update
# migration, so the wording (and the TTY warning) can't drift between them.
sddm_print_cutover_hint() {
    info "The login screen has NOT been switched over — that stays a deliberate step."
    info "  1. Preview it first:   sddm-greeter-qt6 --test-mode --theme $SDDM_THEME_DEST"
    info "  2. Then switch:        sudo sh -c 'printf \"[Theme]\\nCurrent=$SDDM_THEME_ID\\n\" > $SDDM_THEME_CONF'"
    info "  Keep a TTY (Ctrl+Alt+F3) open the first time you reboot into it."
    info "  F3, not F2 — SDDM holds the first console, and a crash-looping"
    info "  greeter takes the second one too."
}

# ---- repo path -> install destination routing table -------------------------
# route_dest REPO_REL_PATH -> prints "DEST<TAB>SCOPE<TAB>KIND", or returns 1 if the
# path isn't something DankMango installs. Derived DIRECTLY from what install.sh's
# stages copy (not invented): update.sh uses it to turn a changed repo file into the
# same copy action install.sh would have taken. KIND tells update.sh HOW to apply it:
#   user_copy / sys_copy : straight copy via that helper (backup + manifest record)
#   dms-state  : a DankMaterialShell state JSON (settings/plugin_settings) -- NOT a
#                blind copy; belongs to a migration (user may have customised it)
#   plugin     : lives in a DMS plugin tree (needs plugin.json id handling, stage 14)
#   sddm-theme : part of the LEGACY astronaut SDDM config dir (sudo apply.sh re-run)
#   dankmango-sddm-theme : part of DankMango's own login theme -- reinstalled as a
#                whole tree by the theme's install.sh (ownership split), never file-by-file
#   wallpaper  : a bundled wallpaper (copy into ~/Pictures/Wallpapers)
route_dest() {
    local p="$1"
    case "$p" in
        config/dms/DankMaterialShell/settings.json|config/dms/DankMaterialShell/plugin_settings.json)
            printf '%s\tuser\tdms-state\n' "$HOME/.config/DankMaterialShell/${p#config/dms/DankMaterialShell/}" ;;
        config/dms/DankMaterialShell/*)
            printf '%s\tuser\tuser_copy\n' "$HOME/.config/DankMaterialShell/${p#config/dms/DankMaterialShell/}" ;;
        config/dms/*.conf)
            printf '%s\tuser\tuser_copy\n' "$HOME/.config/mango/dms/${p#config/dms/}" ;;
        config/mango/*)
            printf '%s\tuser\tuser_copy\n' "$HOME/.config/mango/${p#config/mango/}" ;;
        config/gtk-3.0/*|config/gtk-4.0/*|config/alacritty/*)
            printf '%s\tuser\tuser_copy\n' "$HOME/.config/${p#config/}" ;;
        config/applications/*.nemo_action)
            # Nemo actions live in nemo/actions/, NOT applications/ — Nemo never
            # scans the .desktop dir for them. Must come before the generic
            # config/applications/* rule below or it'd land in the wrong place.
            printf '%s\tuser\tuser_copy\n' "$HOME/.local/share/nemo/actions/${p#config/applications/}" ;;
        config/applications/*)
            printf '%s\tuser\tuser_copy\n' "$HOME/.local/share/applications/${p#config/applications/}" ;;
        wallpapers/*.png|wallpapers/*.jpg|wallpapers/*.jpeg)
            printf '%s\tuser\twallpaper\n' "$HOME/Pictures/Wallpapers/${p#wallpapers/}" ;;
        plugins/*)
            printf '%s\tuser\tplugin\n' "$p" ;;
        system/keyd/*)
            printf '/etc/keyd/%s\tsystem\tsys_copy\n' "${p#system/keyd/}" ;;
        system/sddm/sddm.conf.d/*)
            printf '/etc/sddm.conf.d/%s\tsystem\tsys_copy\n' "${p#system/sddm/sddm.conf.d/}" ;;
        system/sddm/themes/dankmango/*)
            # DankMango's own login theme. The DEST is the real per-file path, but the
            # KIND tells update.sh not to treat it as a per-file copy: reproducing the
            # ownership split (root-owned dir + code, two user-writable leaves) is the
            # theme installer's job, and a plain `cp` would land QML as the wrong owner
            # in a directory the greeter executes from pre-auth. So an ADDED/MODIFIED
            # file means "re-run the installer once"; the per-file path only matters for
            # the REMOVED case, where a stale file has to be deleted out of the live
            # tree (the installer only ever adds/overwrites, it never prunes).
            printf '%s\tsystem\tdankmango-sddm-theme\n' "$SDDM_THEME_DEST/${p#system/sddm/themes/dankmango/}" ;;
        system/sddm/sddm-astronaut-japanese/*)
            printf '%s\tuser\tsddm-theme\n' "$HOME/.config/sddm-astronaut-japanese/${p#system/sddm/sddm-astronaut-japanese/}" ;;
        system/xdg-desktop-portal/*)
            printf '/etc/xdg/xdg-desktop-portal/%s\tsystem\tsys_copy\n' "${p#system/xdg-desktop-portal/}" ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# Zen browser theming
# =============================================================================
# DMS's matugen `zenbrowser` template regenerates ~/.config/DankMaterialShell/zen.css
# on every theme change, but NOTHING consumes that file — Zen only reads CSS from
# <profile>/chrome/userChrome.css. Without the bridge below, `matugenTemplateZenBrowser`
# produces a themed stylesheet that no browser ever loads. (This is why Zen looked
# themed on the dev machine and nowhere else: that profile had a hand-written
# userChrome.css that was never in the repo.)
#
# Two files are needed inside the profile, and both may already contain the user's
# own work, so both are edited with a marker-guarded block rather than overwritten:
#   chrome/userChrome.css  — @import of the DMS-generated palette
#   user.js                — toolkit.legacyUserProfileCustomizations.stylesheets=true
#
# NOT prefs.js. prefs.js is owned by the browser: it is rewritten wholesale from
# memory on shutdown, so a line appended while Zen is running is silently discarded
# the next time it closes. user.js is the supported input side of the same store —
# read at every startup and merged into prefs.js — and is safe to edit at any time.
#
# Zen reads userChrome.css only at startup, so a full quit+relaunch (not a reload)
# is required before any of this is visible. That's inherent to the Firefox family,
# not something this step can fix.
ZEN_CSS="$HOME/.config/DankMaterialShell/zen.css"
ZEN_MARK_BEGIN="/* >>> DankMango-managed — regenerated on install/update; edit outside this block <<< */"
ZEN_MARK_END="/* <<< end DankMango-managed >>> */"
ZEN_JS_MARK_BEGIN="// >>> DankMango-managed — regenerated on install/update; edit outside this block <<<"
ZEN_JS_MARK_END="// <<< end DankMango-managed >>>"

# zen_profile_dir — echo the absolute path of the active Zen profile, or return 1.
#
# Resolution order matters and is NOT the obvious one. A long-lived profile set can
# carry a stale `Default=1` on a [ProfileN] that was never actually used, while the
# profile the browser really opens is named by the [InstallXXXXXXXX] section. That's
# the exact shape on the dev machine: [Profile1] Default=1 points at an empty dir
# holding only times.json, while [Install15B76BAA26BA15E7] Default= names the real
# one. So: Install section first, [ProfileN] Default=1 only as a fallback.
#
# Both roots are checked because the location depends on the build's XDG handling:
# ~/.zen is the classic path, ~/.config/zen is what the AUR zen-browser-bin uses.
zen_profile_dir() {
    local root ini rel
    for root in "$HOME/.zen" "$HOME/.config/zen"; do
        ini="$root/profiles.ini"
        [ -f "$ini" ] || continue

        # 1. The install-scoped default — what the browser actually launches.
        rel="$(awk '
            /^\[Install/ { ins=1; next }
            /^\[/        { ins=0 }
            ins && /^Default=/ { v=$0; sub(/^Default=/, "", v); gsub(/\r/, "", v); print v; exit }
        ' "$ini")"

        # 2. Fallback: a [ProfileN] flagged Default=1 (only if no Install section).
        if [ -z "$rel" ]; then
            rel="$(awk '
                /^\[Profile/ { inp=1; p=""; d=0; next }
                /^\[/        { if (inp && d && p != "") { print p; exit } inp=0 }
                inp && /^Path=/     { p=$0; sub(/^Path=/, "", p); gsub(/\r/, "", p) }
                inp && /^Default=1/ { d=1 }
                END { if (inp && d && p != "") print p }
            ' "$ini")"
        fi

        [ -n "$rel" ] || continue
        # IsRelative=0 profiles store an absolute Path=; relative ones hang off the root.
        case "$rel" in /*) printf '%s\n' "$rel" ;; *) printf '%s/%s\n' "$root" "$rel" ;; esac
        return 0
    done
    return 1
}

# _zen_strip_block FILE BEGIN END — echo FILE's contents with any existing managed
# block removed. Everything outside the markers is passed through byte-for-byte.
_zen_strip_block() {
    [ -f "$1" ] || return 0
    awk -v b="$2" -v e="$3" '
        $0 == b { skip=1; next }
        $0 == e { skip=0; next }
        !skip   { print }
    ' "$1"
}

# _zen_write FILE NEW_CONTENT LABEL — write only if the content actually changes,
# backing up the previous version first. Keeps re-runs from churning backups.
_zen_write() {
    local f="$1" new="$2" label="$3"
    if [ -f "$f" ] && [ "$(cat "$f")" = "$new" ]; then
        info "  $label already up to date — unchanged"
        return 0
    fi
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "  [dry-run] would write $label ($f)"
        return 0
    fi
    if [ -f "$f" ]; then
        cp -a "$f" "$f.bak-$STAMP"
        [ -n "${MANIFEST:-}" ] && [ -f "${MANIFEST:-}" ] && \
            manifest_add_backup "$f" "$f.bak-$STAMP" user "${CUR_STAGE:-zen}"
        prune_file_backups "$f"
        printf '%s\n' "$new" > "$f"
        ok "  updated $label (backup: $(basename "$f").bak-$STAMP)"
    else
        printf '%s\n' "$new" > "$f"
        ok "  created $label"
    fi
}

# zen_apply_theming — the whole step. Idempotent; honours DRY_RUN.
# Returns 0 when applied or already correct, 1 when it could not run (no profile).
zen_apply_theming() {
    if ! have zen-browser && ! pacman -Qi zen-browser-bin >/dev/null 2>&1; then
        info "Zen isn't installed — skipping Zen theming"
        return 0
    fi

    local prof
    if ! prof="$(zen_profile_dir)"; then
        warn "Zen is installed but no profile exists yet (never launched)."
        warn "  Zen creates its profile on first run, so there is nothing to theme yet."
        warn "  Fix: launch Zen once, quit it, then re-run this step:"
        warn "      cd $REPO_DIR && bash install.sh     (or: bash update.sh)"
        return 1
    fi
    if [ ! -d "$prof" ]; then
        warn "profiles.ini names a profile that doesn't exist on disk: $prof"
        warn "  Launch Zen once so it creates the profile, then re-run."
        return 1
    fi
    ok "resolved Zen profile: $prof"

    [ -f "$ZEN_CSS" ] || warn "  $ZEN_CSS doesn't exist yet — DMS writes it on the next theme/wallpaper change; the @import will start working then."

    # ---- 1. chrome/userChrome.css -------------------------------------------
    # The managed block is PREPENDED, not appended: CSS requires @import to precede
    # every other rule in the stylesheet, so a block added at the end of a file that
    # already has rules would be parsed and then ignored outright.
    local chrome="$prof/chrome" uc="$prof/chrome/userChrome.css"
    if [ ! -d "$chrome" ]; then
        if [ "${DRY_RUN:-0}" = 1 ]; then info "  [dry-run] would create $chrome"
        else mkdir -p "$chrome"; ok "  created $chrome"; fi
    fi
    local rest block new
    rest="$(_zen_strip_block "$uc" "$ZEN_MARK_BEGIN" "$ZEN_MARK_END")"
    block="$(printf '%s\n%s\n%s\n%s' \
        "$ZEN_MARK_BEGIN" \
        "/* Wallpaper-following palette, regenerated by DMS/matugen on every theme change." \
        " * Takes effect on Zen's next full restart — userChrome.css is read at startup. */" \
        "@import url(\"file://$ZEN_CSS\");
$ZEN_MARK_END")"
    # Strip leading blank lines from the remainder so repeated runs don't accrete them.
    rest="$(printf '%s' "$rest" | awk 'NF {found=1} found {print}')"
    if [ -n "$rest" ]; then new="$block"$'\n\n'"$rest"; else new="$block"; fi
    _zen_write "$uc" "$new" "userChrome.css"

    # ---- 2. user.js ----------------------------------------------------------
    # Without this pref Zen ignores userChrome.css completely.
    local ujs="$prof/user.js" jrest jblock jnew
    jrest="$(_zen_strip_block "$ujs" "$ZEN_JS_MARK_BEGIN" "$ZEN_JS_MARK_END")"
    jblock="$(printf '%s\n%s\n%s\n%s' \
        "$ZEN_JS_MARK_BEGIN" \
        "// Required for chrome/userChrome.css to be loaded at all." \
        "user_pref(\"toolkit.legacyUserProfileCustomizations.stylesheets\", true);" \
        "$ZEN_JS_MARK_END")"
    jrest="$(printf '%s' "$jrest" | awk 'NF {found=1} found {print}')"
    if [ -n "$jrest" ]; then jnew="$jblock"$'\n\n'"$jrest"; else jnew="$jblock"; fi
    _zen_write "$ujs" "$jnew" "user.js"

    if [ "${DRY_RUN:-0}" != 1 ]; then
        [ -n "${MANIFEST:-}" ] && [ -f "${MANIFEST:-}" ] && \
            manifest_add_change zen-theming "${CUR_STAGE:-zen}" "$prof" \
                "$(jq -nc --arg p "$prof" --arg c "$ZEN_CSS" '{profile:$p, imports:$c}')" \
                "remove the DankMango-managed blocks from chrome/userChrome.css and user.js"
        info "  Zen must be fully quit and reopened before this is visible."
    fi
    return 0
}
