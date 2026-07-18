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

# Copy a SYSTEM file (needs sudo). Backs up an existing, differing target.
# Records the backup (if any) and a system-file-installed change in the manifest,
# noting whether the target pre-existed (so uninstall knows: restore vs. delete).
#   sys_copy SRC DST
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
            sudo cp -a "$dst" "$dst.bak-$STAMP"
            info "backed up existing $dst -> $dst.bak-$STAMP"
            manifest_add_backup "$dst" "$dst.bak-$STAMP" system "$CUR_STAGE"
        fi
    fi
    sudo cp "$src" "$dst"
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
            cp -a "$dst" "$dst.bak-$STAMP"
            info "backed up existing $dst -> $dst.bak-$STAMP"
            manifest_add_backup "$dst" "$dst.bak-$STAMP" user "$CUR_STAGE"
        fi
    fi
    cp "$src" "$dst"
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

# Mark the run complete (stage 17). Partial runs keep status "in-progress".
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
# rsync: NOT part of a base CachyOS install, and it's a hard dependency of the
# SDDM stage's apply.sh -- install it here so that stage never hits its fallback.
# jq: relied on all over this rice (the dp2-floatsize placer, the taskbar-pin +
# wallpaper seeds, the popupTransparency edit). It's only incidentally present on
# some systems (pulled in by scx-scheds etc.), so pin it explicitly here.
# cava: the runtime backend for DMS's built-in Media-widget audio waveform. Without
# it CavaService.cavaAvailable is false and the widget silently falls back to a static
# icon (issue #3). Not in a base install, so pin it here.
# loupe: GNOME's image viewer, made the default for the common image types in stage 4.
# A base CachyOS+mango install ships no image viewer at all, so double-clicking a photo
# in Nemo does nothing until something claims those mimetypes.
REPO_PKGS=(nemo nemo-fileroller loupe matugen cosmic-icon-theme xdg-desktop-portal-wlr keyd rsync jq cava)
# AUR packages that DankMango needs.
AUR_PKGS=(zen-browser-bin sddm-astronaut-theme)
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

# ---- repo path -> install destination routing table -------------------------
# route_dest REPO_REL_PATH -> prints "DEST<TAB>SCOPE<TAB>KIND", or returns 1 if the
# path isn't something DankMango installs. Derived DIRECTLY from what install.sh's
# stages copy (not invented): update.sh uses it to turn a changed repo file into the
# same copy action install.sh would have taken. KIND tells update.sh HOW to apply it:
#   user_copy / sys_copy : straight copy via that helper (backup + manifest record)
#   dms-state  : a DankMaterialShell state JSON (settings/plugin_settings) -- NOT a
#                blind copy; belongs to a migration (user may have customised it)
#   plugin     : lives in a DMS plugin tree (needs plugin.json id handling, stage 14)
#   sddm-theme : part of the SDDM theme config dir (needs a sudo apply.sh re-run)
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
        wallpapers/*.png|wallpapers/*.jpg|wallpapers/*.jpeg)
            printf '%s\tuser\twallpaper\n' "$HOME/Pictures/Wallpapers/${p#wallpapers/}" ;;
        plugins/*)
            printf '%s\tuser\tplugin\n' "$p" ;;
        system/keyd/*)
            printf '/etc/keyd/%s\tsystem\tsys_copy\n' "${p#system/keyd/}" ;;
        system/sddm/sddm.conf.d/*)
            printf '/etc/sddm.conf.d/%s\tsystem\tsys_copy\n' "${p#system/sddm/sddm.conf.d/}" ;;
        system/sddm/sddm-astronaut-japanese/*)
            printf '%s\tuser\tsddm-theme\n' "$HOME/.config/sddm-astronaut-japanese/${p#system/sddm/sddm-astronaut-japanese/}" ;;
        system/xdg-desktop-portal/*)
            printf '/etc/xdg/xdg-desktop-portal/%s\tsystem\tsys_copy\n' "${p#system/xdg-desktop-portal/}" ;;
        *) return 1 ;;
    esac
}
