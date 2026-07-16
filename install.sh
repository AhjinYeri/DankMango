#!/usr/bin/env bash
#
# =============================================================================
#  DankMango installer
# =============================================================================
#  Takes a fresh CachyOS + MangoWM system and applies the DankMango rice:
#  packages, system files (keyd / SDDM), the mango + DankMaterialShell (DMS)
#  configs, the three DMS plugins, GTK/terminal theming, and a couple of
#  opt-in tweaks (power profile, easyeffects autostart).
#
#  It is meant to be SAFE TO RE-RUN:
#    * package installs use --needed (already-installed packages are skipped)
#    * every file it overwrites is backed up to <file>.bak-<timestamp> first
#    * every "copy from the repo" step is guarded: if the repo doesn't ship a
#      given file yet, that step WARNS and is skipped instead of failing.
#
#  Nothing here is hardcoded to a particular machine.
#
#  Usage:   cd DankMango && bash install.sh
# =============================================================================

# NOTE: deliberately NOT `set -e`. We want every stage to run and report, even
# if an earlier one had a problem. -u catches typos; pipefail surfaces failures.
set -uo pipefail

# Resolve the repo root from this script's own location (works from anywhere).
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# empty. Used only for the standard-apps prompt: those apps are pinned to the taskbar
# regardless, so the sensible default is to install them (a "no" leaves dead pins).
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
        manifest_add_change system-file-installed "$CUR_STAGE" "$dst" \
            "$(jq -nc --arg p "$dst" --argjson pre "$existed" '{path:$p, preexisting:($pre==1), scope:"system"}')" \
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
        manifest_add_change user-file-installed "$CUR_STAGE" "$dst" \
            "$(jq -nc --arg p "$dst" --argjson pre "$existed" '{path:$p, preexisting:($pre==1), scope:"user"}')" \
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
    "status": "in-progress"
  },
  "packages": [],
  "packagesSkipped": [],
  "backups": [],
  "systemChanges": []
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
        ' --arg version "$version" --arg commit "$commit" --arg repo "$REPO_DIR" \
          --arg now "$now" --arg stamp "$STAMP" \
          && info "updated existing install manifest -> $MANIFEST" \
          || info "existing manifest at $MANIFEST"
    fi
}

# manifest_add_package NAME SOURCE CATEGORY  — packages WE installed (ours to remove
# later). Dedupe by name. SOURCE = repo|aur ; CATEGORY = required|standard-app|optional-feature.
manifest_add_package() {
    manifest_jq '
        .packages = ([ .packages[] | select(.name != $n) ]
                     + [{name:$n, source:$s, category:$c, stamp:$stamp}])
    ' --arg n "$1" --arg s "$2" --arg c "$3" --arg stamp "$STAMP"
}

# manifest_add_skipped NAME REASON  — packages present BEFORE us (never ours; the
# uninstaller must not touch them). Dedupe by name.
manifest_add_skipped() {
    manifest_jq '
        .packagesSkipped = ([ .packagesSkipped[] | select(.name != $n) ]
                            + [{name:$n, reason:$r, stamp:$stamp}])
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
manifest_finalize() { manifest_jq '.dankmango.status = "complete"'; }

echo "==================================================================="
echo " DankMango installer   ($STAMP)"
echo " repo: $REPO_DIR"
echo "==================================================================="

# Stage 0 (setup, not user-facing): open the install manifest FIRST, so even a run
# that crashes early leaves an accurate partial record. Every stage below appends to
# it as it acts (one write per action), rather than a bulk dump at the end.
manifest_init

# =============================================================================
# 1. Sanity check: does this look like CachyOS? (soft — warn only)
# =============================================================================
stage "1/17  Checking this looks like a CachyOS system"
if grep -qi 'cachy' /etc/os-release 2>/dev/null || [ -f /etc/cachyos-release ] || pacman -Sl cachyos >/dev/null 2>&1; then
    ok "CachyOS detected"
else
    warn "This doesn't clearly look like CachyOS. DankMango targets CachyOS + MangoWM;"
    warn "continuing anyway, but some base-system assumptions may not hold."
fi
if ! have pacman; then
    die "pacman not found — this installer only supports Arch-based systems (CachyOS)."
fi

# =============================================================================
# 2. AUR helper: use paru/yay; bootstrap paru if neither is present
# =============================================================================
stage "2/17  Ensuring an AUR helper is available"
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
ok "using AUR helper: $AUR"

# =============================================================================
# 3. Install packages
# =============================================================================
stage "3/17  Installing packages"
# Official-repo packages (the AUR helper pulls these straight from the repos).
# rsync: NOT part of a base CachyOS install, and it's a hard dependency of the
# SDDM stage's apply.sh -- install it here so that stage never hits its fallback.
# jq: relied on all over this rice (the dp2-floatsize placer, the taskbar-pin +
# wallpaper seeds, the popupTransparency edit). It's only incidentally present on
# some systems (pulled in by scx-scheds etc.), so pin it explicitly here.
# cava: the runtime backend for DMS's built-in Media-widget audio waveform. Without
# it CavaService.cavaAvailable is false and the widget silently falls back to a static
# icon (issue #3). Not in a base install, so pin it here.
REPO_PKGS=(nemo nemo-fileroller matugen cosmic-icon-theme xdg-desktop-portal-wlr keyd rsync jq cava)
# AUR packages that DankMango needs.
AUR_PKGS=(zen-browser-bin sddm-astronaut-theme)
# Standard taskbar apps (issue #5): the SEED_PINNED_APPS set minus what's already
# core-installed (Alacritty/nemo/zen). These are pinned to the taskbar regardless, so
# without them a fresh install shows dead pins. OPTIONAL + opt-in (default yes). All
# three are official-repo on CachyOS -- no AUR build needed. steam pulls multilib libs
# (multilib is enabled by default on CachyOS). Spotify ships as spotify-launcher (the
# official launcher; it fetches the real client on first run).
STANDARD_APPS=(discord steam spotify-launcher)
# NOTE: intentionally NOT installed here (CachyOS + MangoWM base already ships
# them): sddm, alacritty, the pipewire stack, wireplumber, networkmanager,
# power-profiles-daemon, bluez, fonts (noto / meslo-nerd), jq, libnotify, gawk,
# psmisc, xdg-desktop-portal-core. And capitaine-cursors is NOT used at all.
info "official-repo: ${REPO_PKGS[*]}"
info "AUR (required): ${AUR_PKGS[*]}"

# IDEMPOTENCY + OWNERSHIP: snapshot which of our packages are ALREADY installed BEFORE
# we touch anything, so the manifest attributes each correctly. A package that pre-
# existed is recorded as "skipped" (never ours -> a future uninstall must not remove
# it); one we actually install is recorded as ours. This is what makes a re-run clean:
# on the second run everything is preexisting, nothing reinstalls, and the dedup in the
# manifest helpers means no second entry is added.
declare -A PKG_PRE=()
for p in "${REPO_PKGS[@]}" "${AUR_PKGS[@]}" "${STANDARD_APPS[@]}"; do
    if pacman -Qi "$p" >/dev/null 2>&1; then PKG_PRE[$p]=1; else PKG_PRE[$p]=0; fi
done

# jq is in REPO_PKGS but is ALSO what the manifest writer needs for the rest of this
# stage, so install it up front. Its true pre-state was already captured above, so it's
# still attributed correctly (ours if it wasn't there, skipped if it was).
if ! have jq; then
    info "installing jq up front (needed to record the install manifest)"
    sudo pacman -S --needed --noconfirm jq >/dev/null 2>&1 \
        || "$AUR" -S --needed --noconfirm jq >/dev/null 2>&1 || true
fi

# manifest_record_pkgs SRC CAT pkg...  — from the pre-snapshot: preexisting -> skipped
# (not ours); newly present -> ours; still absent -> install failed, leave unrecorded.
manifest_record_pkgs() {
    local src="$1" cat="$2"; shift 2
    local p
    for p in "$@"; do
        if [ "${PKG_PRE[$p]:-0}" = "1" ]; then
            manifest_add_skipped "$p" already-installed
        elif pacman -Qi "$p" >/dev/null 2>&1; then
            manifest_add_package "$p" "$src" "$cat"
        fi
    done
}

# Install the core set in one resolve (--needed skips already-present ones efficiently).
if "$AUR" -S --needed --noconfirm "${REPO_PKGS[@]}" "${AUR_PKGS[@]}"; then
    ok "core packages installed (already-present ones were skipped)"
else
    warn "one or more core packages failed to install — scroll up for which. Re-run after fixing,"
    warn "or install the missing ones by hand: $AUR -S ${REPO_PKGS[*]} ${AUR_PKGS[*]}"
fi
manifest_record_pkgs repo required "${REPO_PKGS[@]}"
manifest_record_pkgs aur  required "${AUR_PKGS[@]}"

# ---- Standard taskbar apps (issue #5) — one opt-in, default YES -------------------
info "standard taskbar apps (optional): ${STANDARD_APPS[*]}  (Spotify = spotify-launcher)"
if ask_yn_default_yes "Install the standard taskbar apps (Spotify, Steam, Discord)? They're pinned either way — saying no leaves those pins with nothing behind them."; then
    if "$AUR" -S --needed --noconfirm "${STANDARD_APPS[@]}"; then
        ok "standard apps installed (already-present ones were skipped)"
    else
        warn "one or more standard apps failed to install — add them later: $AUR -S ${STANDARD_APPS[*]}"
    fi
    manifest_record_pkgs repo standard-app "${STANDARD_APPS[@]}"
    info "(Spotify uses spotify-launcher — it fetches the actual client on first launch, so the"
    info " taskbar pin binds once you've opened Spotify once.)"
else
    info "Skipped standard apps — the Spotify/Steam/Discord pins stay inert until you install them."
    # Still record any that were already present, so the uninstaller can prove it won't touch them.
    for p in "${STANDARD_APPS[@]}"; do
        [ "${PKG_PRE[$p]:-0}" = "1" ] && manifest_add_skipped "$p" already-installed
    done
fi

# wpctl (from wireplumber) is the output-switcher plugin's only backend. It's
# base on CachyOS, so we don't install it — just sanity-check and warn.
if have wpctl; then
    ok "wpctl present (output-switcher plugin dependency satisfied)"
else
    warn "wpctl NOT found — the output-switcher plugin can't switch audio. Install wireplumber."
fi

# =============================================================================
# 4. Nemo as the default file manager
# =============================================================================
stage "4/17  Setting Nemo as the default file manager"
if have xdg-mime; then
    if xdg-mime default nemo.desktop inode/directory; then
        ok "Nemo set for inode/directory"
        have jq && manifest_add_change default-app "$CUR_STAGE" "inode/directory" \
            "$(jq -nc '{mime:"inode/directory", app:"nemo.desktop"}')" \
            "reset with: xdg-mime default <your-previous-fm>.desktop inode/directory"
    else
        warn "xdg-mime call failed — set Nemo as default file manager manually."
    fi
else
    warn "xdg-mime not found — skipping default-file-manager step."
fi

# =============================================================================
# 5. System-level files (need sudo)
# =============================================================================
stage "5/17  Installing system files (keyd, SDDM) — will prompt for sudo"

# 5a. keyd (Super-tap launcher etc.)
if sys_copy "$REPO_DIR/system/keyd/default.conf" "/etc/keyd/default.conf"; then
    if sudo systemctl enable --now keyd 2>/dev/null; then
        ok "keyd service enabled and started"
        have jq && manifest_add_change service-enabled "$CUR_STAGE" "keyd" \
            "$(jq -nc '{service:"keyd", scope:"system"}')" "sudo systemctl disable --now keyd"
    else
        warn "couldn't enable/start keyd — run: sudo systemctl enable --now keyd"
    fi
else
    info "no keyd config shipped in the repo yet -> not enabling the keyd service."
fi

# 5b. SDDM: Japanese astronaut theme (12h clock + custom background), installed
#     via the UPDATE-PROOF apply.sh pattern -- NOT a theme/conf split.
#     How it really works (verified against the live system):
#       * The source of truth is a small config dir (apply.sh + the customized
#         japanese_aesthetic.conf + the background png). We install it to
#         ~/.config/sddm-astronaut-japanese/.
#       * apply.sh (run as root) rsyncs the package-owned upstream theme into a
#         SEPARATE copy dir that pacman never touches, overlays our conf + bg,
#         fixes metadata.desktop, and writes /etc/sddm.conf.d/theme.conf. That's
#         what survives sddm-astronaut-theme package updates.
#     So here we (1) drop the config dir into ~/.config, then (2) run apply.sh.
SDDM_SRC="$REPO_DIR/system/sddm/sddm-astronaut-japanese"
SDDM_CFG_DST="$HOME/.config/sddm-astronaut-japanese"
if [ -f "$SDDM_SRC/apply.sh" ]; then
    if [ -d "$SDDM_CFG_DST" ]; then
        cp -a "$SDDM_CFG_DST" "$SDDM_CFG_DST.bak-$STAMP" && info "backed up existing $SDDM_CFG_DST -> $SDDM_CFG_DST.bak-$STAMP"
        manifest_add_backup "$SDDM_CFG_DST" "$SDDM_CFG_DST.bak-$STAMP" user "$CUR_STAGE"
    fi
    mkdir -p "$SDDM_CFG_DST"
    cp -a "$SDDM_SRC/." "$SDDM_CFG_DST/"
    chmod +x "$SDDM_CFG_DST/apply.sh"
    ok "SDDM theme config -> $SDDM_CFG_DST"
    have jq && manifest_add_change owned-tree "$CUR_STAGE" "$SDDM_CFG_DST" \
        "$(jq -nc --arg d "$SDDM_CFG_DST" '{dir:$d, scope:"user"}')" "rm -rf $SDDM_CFG_DST"
    info "(tip: your display isn't 1080p? edit ScreenWidth/ScreenHeight in japanese_aesthetic.conf first.)"

    # apply.sh needs rsync and the upstream package to be present.
    if ! have rsync; then
        warn "rsync not found — apply.sh needs it. Install rsync, then run: sudo $SDDM_CFG_DST/apply.sh"
    elif [ ! -d /usr/share/sddm/themes/sddm-astronaut-theme ]; then
        warn "upstream sddm-astronaut-theme not installed yet — run 'sudo $SDDM_CFG_DST/apply.sh' after it is."
    else
        info "Running apply.sh (builds the update-proof theme copy + sets it active) — needs sudo."
        if sudo "$SDDM_CFG_DST/apply.sh"; then
            ok "SDDM Japanese theme applied (12h clock, custom background, update-proof copy)"
            have jq && manifest_add_change sddm-theme-applied "$CUR_STAGE" "theme.conf" \
                "$(jq -nc --arg cd "$SDDM_CFG_DST" '{configDir:$cd, writes:["/etc/sddm.conf.d/theme.conf"], note:"apply.sh also builds an update-proof theme copy under /usr/share/sddm/themes"}')" \
                "remove /etc/sddm.conf.d/theme.conf (reverts to default SDDM theme)"
        else
            warn "apply.sh failed — re-run it manually: sudo $SDDM_CFG_DST/apply.sh"
        fi
    fi
else
    warn "no SDDM theme config in system/sddm/sddm-astronaut-japanese/ -> skipping SDDM theming."
    info "(the sddm-astronaut-theme AUR package still installed its own default theme.)"
fi

# 5c. SDDM drop-in config(s) that apply.sh does NOT manage (e.g. numlock.conf):
#     system/sddm/sddm.conf.d/*.conf -> /etc/sddm.conf.d/
#     NOTE: theme.conf is intentionally NOT shipped here — apply.sh writes it.
shopt -s nullglob
sddm_confs=("$REPO_DIR"/system/sddm/sddm.conf.d/*.conf)
shopt -u nullglob
if [ "${#sddm_confs[@]}" -gt 0 ]; then
    for f in "${sddm_confs[@]}"; do
        sys_copy "$f" "/etc/sddm.conf.d/$(basename "$f")"
    done
else
    warn "no SDDM drop-ins in system/sddm/sddm.conf.d/ -> skipping /etc/sddm.conf.d/ setup."
fi

# 5d. wlr xdg-desktop-portal config, IF the repo ships a system-level one.
#     (xdg-desktop-portal-wlr works on package defaults without this; only copy
#     a config if one actually exists in the repo.)
portal_src=""
for cand in "$REPO_DIR/system/xdg-desktop-portal/wlr.conf" \
            "$REPO_DIR/system/sddm/wlr.conf" \
            "$REPO_DIR/system/portals/wlr.conf"; do
    [ -f "$cand" ] && { portal_src="$cand"; break; }
done
if [ -n "$portal_src" ]; then
    sys_copy "$portal_src" "/etc/xdg/xdg-desktop-portal/wlr.conf"
else
    info "no wlr portal config shipped in the repo -> using xdg-desktop-portal-wlr defaults (fine)."
fi

# =============================================================================
# 6. Make the mango helper scripts executable
# =============================================================================
stage "6/17  Making mango scripts executable"
if compgen -G "$REPO_DIR/config/mango/scripts/*.sh" >/dev/null; then
    chmod +x "$REPO_DIR"/config/mango/scripts/*.sh && ok "chmod +x on config/mango/scripts/*.sh"
else
    warn "no *.sh scripts found under config/mango/scripts/."
fi

# =============================================================================
# 7. Install the mango + DMS configs
#    Mapping comes straight from config.conf's source= lines:
#      source=~/.config/mango/dms/{colors,layout,outputs}.conf
#      source=./dms/{cursor,binds}.conf   (./ = ~/.config/mango/)
#    => all dms/*.conf live at ~/.config/mango/dms/ ; the mango tree at
#       ~/.config/mango/ ; the DMS tree at ~/.config/DankMaterialShell/.
# =============================================================================
stage "7/17  Installing mango + DankMaterialShell configs"

# 7a. mango tree (config.conf + scripts/) -> ~/.config/mango/
mkdir -p "$HOME/.config/mango"
if [ -f "$HOME/.config/mango/config.conf" ] && ! cmp -s "$REPO_DIR/config/mango/config.conf" "$HOME/.config/mango/config.conf"; then
    cp -a "$HOME/.config/mango/config.conf" "$HOME/.config/mango/config.conf.bak-$STAMP"
    info "backed up existing config.conf -> config.conf.bak-$STAMP"
    manifest_add_backup "$HOME/.config/mango/config.conf" "$HOME/.config/mango/config.conf.bak-$STAMP" user "$CUR_STAGE"
fi
cp -a "$REPO_DIR/config/mango/." "$HOME/.config/mango/" && ok "mango config + scripts -> ~/.config/mango/"
have jq && manifest_add_change owned-tree "$CUR_STAGE" "$HOME/.config/mango" \
    "$(jq -nc --arg d "$HOME/.config/mango" '{dir:$d, scope:"user"}')" "rm -rf ~/.config/mango"

# 7b. dms/*.conf -> ~/.config/mango/dms/
mkdir -p "$HOME/.config/mango/dms"
for f in "$REPO_DIR"/config/dms/*.conf; do
    user_copy "$f" "$HOME/.config/mango/dms/$(basename "$f")"
done
# config.conf sources dms/outputs.conf, which DMS generates at runtime and we do
# NOT ship. Create an empty placeholder so the first launch doesn't error on a
# missing source= file; DMS will overwrite it with real output config.
if [ ! -f "$HOME/.config/mango/dms/outputs.conf" ]; then
    printf '# Auto-generated by DankMaterialShell at runtime. Placeholder created by install.sh.\n' \
        > "$HOME/.config/mango/dms/outputs.conf"
    ok "created placeholder ~/.config/mango/dms/outputs.conf (DMS regenerates it)"
fi

# 7c. DankMaterialShell tree -> ~/.config/DankMaterialShell/ (merge, don't wipe
#     runtime state). Back up the two stateful JSONs before overwrite.
mkdir -p "$HOME/.config/DankMaterialShell"
for j in settings.json plugin_settings.json; do
    tgt="$HOME/.config/DankMaterialShell/$j"
    src="$REPO_DIR/config/dms/DankMaterialShell/$j"
    if [ -f "$tgt" ] && [ -f "$src" ] && ! cmp -s "$src" "$tgt"; then
        cp -a "$tgt" "$tgt.bak-$STAMP"
        info "backed up existing $j -> $j.bak-$STAMP"
        manifest_add_backup "$tgt" "$tgt.bak-$STAMP" user "$CUR_STAGE"
    fi
done
cp -a "$REPO_DIR/config/dms/DankMaterialShell/." "$HOME/.config/DankMaterialShell/" \
    && ok "DMS config -> ~/.config/DankMaterialShell/"
have jq && manifest_add_change owned-tree "$CUR_STAGE" "$HOME/.config/DankMaterialShell" \
    "$(jq -nc --arg d "$HOME/.config/DankMaterialShell" '{dir:$d, scope:"user", note:"runtime state (session.json etc.) lives here too; uninstall should preserve or back it up"}')" \
    "back up ~/.config/DankMaterialShell, then remove the DankMango-shipped files"

# =============================================================================
# 8. Wallpapers -> ~/Pictures/Wallpapers/  (a sensible default matugen source)
#    Never clobbers existing wallpapers: same-named files already there are
#    skipped with a warning, same pattern as the other copy steps.
# =============================================================================
stage "8/17  Installing default wallpapers"
WALL_DST="$HOME/Pictures/Wallpapers"
if compgen -G "$REPO_DIR/wallpapers/*.png" >/dev/null; then
    mkdir -p "$WALL_DST"
    wall_copied=0; wall_skipped=0; wall_copied_list=()
    for w in "$REPO_DIR"/wallpapers/*.png; do
        base="$(basename "$w")"
        if [ -e "$WALL_DST/$base" ]; then
            warn "wallpaper already exists, not overwriting: $WALL_DST/$base"
            wall_skipped=$((wall_skipped+1))
        else
            cp "$w" "$WALL_DST/$base" && { wall_copied=$((wall_copied+1)); wall_copied_list+=("$base"); }
        fi
    done
    ok "wallpapers: $wall_copied copied, $wall_skipped left untouched -> $WALL_DST"
    # Record ONLY the files we actually copied (not skipped pre-existing ones), so an
    # uninstall removes only ours.
    if [ "$wall_copied" -gt 0 ] && have jq; then
        files_json="$(printf '%s\n' "${wall_copied_list[@]}" | jq -R . | jq -sc .)"
        manifest_add_change files-copied "$CUR_STAGE" "$WALL_DST" \
            "$(jq -nc --arg d "$WALL_DST" --argjson f "$files_json" '{dst:$d, files:$f, scope:"user"}')" \
            "rm the listed files from $WALL_DST (leaves any you added yourself)"
    fi
    info "point matugen / your wallpaper picker at $WALL_DST"
else
    warn "no *.png files under wallpapers/ in the repo -> skipping wallpaper install."
fi

# =============================================================================
# 9. GTK theming (dank-colors + transparency import into gtk-3.0 / gtk-4.0)
# =============================================================================
stage "9/17  Layering GTK theming (gtk-3.0 / gtk-4.0)"
# Ship the hand-authored LAYER files only: each gtk.css @imports the matugen-
# generated dank-colors.css (created at runtime -- NOT shipped) plus a scoped
# per-app transparency file that must ship alongside it or the @import dangles.
# settings.ini is deliberately NOT touched here (icon theme is set via DMS
# settings.json). user_copy backs up any existing destination (.bak-<timestamp>)
# and warns (rather than fails) if a source file is unexpectedly missing.
gtk_found=0
for pair in \
    "$REPO_DIR/config/gtk-3.0/gtk.css:$HOME/.config/gtk-3.0/gtk.css" \
    "$REPO_DIR/config/gtk-3.0/nemo-transparency.css:$HOME/.config/gtk-3.0/nemo-transparency.css" \
    "$REPO_DIR/config/gtk-4.0/gtk.css:$HOME/.config/gtk-4.0/gtk.css" \
    "$REPO_DIR/config/gtk-4.0/celluloid-transparency.css:$HOME/.config/gtk-4.0/celluloid-transparency.css"; do
    s="${pair%%:*}"; d="${pair##*:}"
    user_copy "$s" "$d" && gtk_found=1
done
if [ "$gtk_found" -eq 0 ]; then
    warn "no GTK theming files found in the repo (expected config/gtk-{3,4}.0/*.css)."
    warn "GTK frosted-glass theming is NOT applied — check the repo, then re-run."
fi

# =============================================================================
# 10. DMS popupTransparency = 0.75
# =============================================================================
stage "10/17  Checking DMS popupTransparency"
SETTINGS="$HOME/.config/DankMaterialShell/settings.json"
if [ -f "$SETTINGS" ] && grep -q '"popupTransparency"[[:space:]]*:[[:space:]]*0.75' "$SETTINGS"; then
    ok "popupTransparency already 0.75 in settings.json (shipped) — no change needed"
elif [ -f "$SETTINGS" ] && have jq; then
    tmp="$(mktemp)"
    if jq '.popupTransparency = 0.75' "$SETTINGS" > "$tmp" && [ -s "$tmp" ]; then
        cp -a "$SETTINGS" "$SETTINGS.bak-$STAMP"; mv "$tmp" "$SETTINGS"
        ok "set popupTransparency = 0.75"
        manifest_add_backup "$SETTINGS" "$SETTINGS.bak-$STAMP" user "$CUR_STAGE"
        manifest_add_change config-edit "$CUR_STAGE" "settings.json:popupTransparency" \
            "$(jq -nc --arg f "$SETTINGS" '{file:$f, key:"popupTransparency", value:0.75}')" \
            "restore $SETTINGS from its .bak-*"
    else
        rm -f "$tmp"; warn "couldn't edit popupTransparency with jq — set it by hand in settings.json."
    fi
else
    warn "settings.json missing or jq unavailable — couldn't verify popupTransparency."
fi

# =============================================================================
# 11. Alacritty config (CachyOS's default has a known duplicate-key error)
# =============================================================================
stage "11/17  Installing Alacritty config"
alac_src=""
for cand in "$REPO_DIR/config/alacritty/alacritty.toml" "$REPO_DIR/config/alacritty.toml"; do
    [ -f "$cand" ] && { alac_src="$cand"; break; }
done
if [ -n "$alac_src" ]; then
    user_copy "$alac_src" "$HOME/.config/alacritty/alacritty.toml"
else
    warn "no Alacritty config in the repo (expected config/alacritty/alacritty.toml) -> skipped."
    warn "CachyOS's stock alacritty.toml has a known duplicate-key error; ship ours to fix it."
fi

# =============================================================================
# 12. Power profile (opt-in; skip on laptops)
# =============================================================================
stage "12/17  Power profile (optional)"
info "Pinning to 'performance' is great for a DESKTOP, but you should SKIP this on a laptop"
info "(it hurts battery life)."
if ask_yn "Pin power profile to 'performance' now?"; then
    if have powerprofilesctl; then
        sudo systemctl enable --now power-profiles-daemon.service 2>/dev/null
        if powerprofilesctl set performance 2>/dev/null; then
            ok "power profile set to performance for this session"
            have jq && manifest_add_change service-enabled "$CUR_STAGE" "power-profiles-daemon" \
                "$(jq -nc '{service:"power-profiles-daemon", scope:"system", profile:"performance"}')" \
                "powerprofilesctl set balanced; sudo systemctl disable power-profiles-daemon (if you don't want it)"
            info "(power-profiles-daemon doesn't persist this across reboot on its own; see the"
            info " 'mango power profile' notes if you want a systemd --user service to re-pin it.)"
        else
            warn "powerprofilesctl couldn't set performance — set it via your bar/DMS instead."
        fi
    else
        warn "power-profiles-daemon (powerprofilesctl) not found — skipping."
    fi
else
    info "Left power profile unchanged."
fi

# =============================================================================
# 13. easyeffects autostart (opt-in; deliberate decision)
# =============================================================================
stage "13/17  easyeffects autostart (optional)"
CONF="$HOME/.config/mango/config.conf"
EE_LINE_RE='^[[:space:]]*#?[[:space:]]*exec-once[[:space:]]*=[[:space:]]*easyeffects'
if [ -f "$CONF" ] && grep -qE "$EE_LINE_RE" "$CONF"; then
    if ask_yn "Autostart easyeffects with your session? (installs easyeffects if not already present)"; then
        # Install easyeffects on demand -- ONLY because the user opted in here. It's
        # deliberately NOT in the stage-3 package list (someone who says "no" shouldn't
        # get it). Same AUR-helper invocation as stage 3; the helper pulls it from the
        # official repos.
        if have easyeffects; then
            ok "easyeffects already installed"
            manifest_add_skipped easyeffects already-installed
        elif "$AUR" -S --needed --noconfirm easyeffects; then
            ok "easyeffects installed"
            manifest_add_package easyeffects repo optional-feature
        else
            warn "easyeffects failed to install — the autostart line will no-op until you install it by hand: $AUR -S easyeffects"
        fi
        # uncomment the exec-once easyeffects line
        sed -i -E "s|^[[:space:]]*#[[:space:]]*(exec-once[[:space:]]*=[[:space:]]*easyeffects.*)|\1|" "$CONF"
        ok "easyeffects autostart ENABLED (exec-once left active in config.conf)"
        have jq && manifest_add_change config-edit "$CUR_STAGE" "config.conf:easyeffects-autostart" \
            "$(jq -nc --arg f "$CONF" '{file:$f, change:"uncommented exec-once = easyeffects"}')" \
            "re-comment the 'exec-once = easyeffects' line in $CONF"
    else
        # comment it out if not already commented
        sed -i -E "s|^([[:space:]]*)(exec-once[[:space:]]*=[[:space:]]*easyeffects.*)|\1# \2|" "$CONF"
        ok "easyeffects autostart DISABLED (exec-once commented out in config.conf)"
    fi
else
    warn "no 'exec-once = easyeffects' line found in config.conf — nothing to toggle."
fi

# =============================================================================
# 14. DMS plugins -> ~/.config/DankMaterialShell/plugins/<id>/
#     Target folder = the plugin.json "id" (monitorMode / altSwitcher /
#     audioToggle), matching the live DMS convention and the plugin READMEs.
#     Registration in plugin_settings.json + settings.json already ships in the
#     copied JSONs (step 7), so we only copy files and verify — no duplicates.
# =============================================================================
stage "14/17  Installing DMS plugins"
PLUGINS_DST="$HOME/.config/DankMaterialShell/plugins"
mkdir -p "$PLUGINS_DST"
for pdir in "$REPO_DIR"/plugins/*/; do
    [ -f "$pdir/plugin.json" ] || continue
    pid="$(grep -oP '"id"\s*:\s*"\K[^"]+' "$pdir/plugin.json" | head -1)"
    [ -n "$pid" ] || { warn "no id in $pdir/plugin.json — skipping"; continue; }
    tgt="$PLUGINS_DST/$pid"
    if [ -d "$tgt" ]; then
        cp -a "$tgt" "$tgt.bak-$STAMP" && info "backed up existing plugin -> $tgt.bak-$STAMP"
    fi
    mkdir -p "$tgt"
    cp -a "$pdir." "$tgt/" && ok "plugin '$pid' -> $tgt"
    have jq && manifest_add_change owned-tree "$CUR_STAGE" "$tgt" \
        "$(jq -nc --arg d "$tgt" --arg id "$pid" '{dir:$d, pluginId:$id, scope:"user"}')" "rm -rf $tgt"
    # sanity-check it's registered (it ships registered; warn if somehow not)
    grep -q "\"$pid\"" "$HOME/.config/DankMaterialShell/plugin_settings.json" 2>/dev/null \
        || warn "plugin '$pid' not found in plugin_settings.json — enable it in DMS Settings -> Plugins."
    grep -q "\"$pid\"" "$SETTINGS" 2>/dev/null \
        || warn "plugin '$pid' not in settings.json bar widgets — add it via Settings -> Appearance -> DankBar Layout."
done

# =============================================================================
# 15. Combined audio OSD patch (OPT-IN — modifies a package-owned DMS core file)
#     Everything above only touches DankMango's OWN configs/plugins. THIS step is
#     different: it patches /usr/share/quickshell/dms/Modules/OSD/VolumeOSD.qml so
#     an audio-output switch shows ONE popup (icon + device name + slider) instead
#     of two stacked OSDs. That file is owned by the dms-shell PACKAGE and is
#     overwritten by every DMS update, so we do NOT apply it silently — it's an
#     opt-in prompt (same y/N pattern as the power-profile / easyeffects steps).
#     It's self-healing: post-update-health.sh detects when a DMS update clobbered
#     it and tells you to re-run the script. The script is idempotent (skips if the
#     marker is already present) and backs up the current file first, so NO --force
#     is needed on a fresh install — --force is reserved for forcing a re-apply
#     over a known-bad state. Runs BEFORE the stage-16 restart so a running DMS
#     picks the patch up immediately.
# =============================================================================
stage "15/17  Combined audio OSD patch (optional)"
OSD_PATCH="$HOME/.config/mango/scripts/apply-combined-osd-patch.sh"
OSD_TARGET="/usr/share/quickshell/dms/Modules/OSD/VolumeOSD.qml"
info "This merges the device-name + volume popups into a SINGLE OSD on audio-output"
info "switches. Unlike the rest of the install it edits a DMS CORE file (package-owned)."
info "It's self-healing (re-applied via the health check after DMS updates) and backs"
info "up the file first — but it does modify a file DankMango doesn't own, so it's your call."
if [ ! -f "$OSD_PATCH" ]; then
    warn "patch script not found at $OSD_PATCH — skipping (was config/mango/scripts/ copied in stage 7?)."
elif [ ! -f "$OSD_TARGET" ]; then
    warn "DMS OSD file not found at $OSD_TARGET — DMS core isn't installed where expected; skipping."
    info "Install/verify DankMaterialShell, then run: $OSD_PATCH"
elif ask_yn "Apply the combined audio OSD patch now? (modifies a DMS package file; needs sudo)"; then
    # Run the script AS YOU (it backs up under ~/.config/mango/backups and calls sudo
    # ITSELF for the root-owned write) — do NOT prefix it with sudo. It self-skips if
    # already patched; --force is intentionally NOT passed here (that's only for
    # re-applying over a known-bad state, never a fresh install).
    if "$OSD_PATCH"; then
        ok "combined audio OSD patch applied (the restart in the next stage picks it up)"
        have jq && manifest_add_change patch-applied "$CUR_STAGE" "$OSD_TARGET" \
            "$(jq -nc --arg t "$OSD_TARGET" '{target:$t, marker:"DankMango patch: combined OSD device name", backupsDir:"~/.config/mango/backups", packageOwned:true}')" \
            "restore the newest ~/.config/mango/backups/VolumeOSD.qml.* to $OSD_TARGET, or reinstall dms-shell"
    else
        warn "combined OSD patch failed — re-run it manually: $OSD_PATCH"
    fi
else
    info "Left DMS's stock OSD untouched. You can apply it later: $OSD_PATCH"
fi

# =============================================================================
# 16. Restart DMS to apply, then seed first-boot theming from a bundled wallpaper
# =============================================================================
stage "16/17  Seeding taskbar pins, restarting DankMaterialShell + seeding theme"

# Seed the taskbar/dock pins AND (offline) the default wallpaper into DMS's
# SessionData file BEFORE (re)starting DMS, in one jq pass. Both live in session.json
# under ~/.local/state — a file the installer otherwise never touches, so without this
# a fresh install boots with an empty taskbar and default (un-themed) colors. On load
# DMS runs Theme.generateSystemThemesFromCurrentTheme() (SessionData.qml), which
# regenerates the matugen theme from wallpaperPath — that's what makes the offline
# wallpaper seed actually theme the desktop on first login. Non-clobbering: we only set
# lists/keys that are currently empty/absent, preserving everything else. No-op without
# jq. (The live `dms ipc call wallpaper set` path below still runs when DMS is already
# up, to apply + run matugen immediately instead of at next login.)
sess="${XDG_STATE_HOME:-$HOME/.local/state}/DankMaterialShell/session.json"
seed_wall="$HOME/Pictures/Wallpapers/$SEED_WALLPAPER"
if have jq; then
    pins_json="$(printf '%s\n' "${SEED_PINNED_APPS[@]}" | jq -R . | jq -s .)"
    wp=""; [ -f "$seed_wall" ] && wp="$seed_wall"
    mkdir -p "$(dirname "$sess")"
    had_sess=0; [ -f "$sess" ] && had_sess=1
    [ "$had_sess" -eq 1 ] || printf '{}\n' > "$sess"
    tmp="$(mktemp)"
    if jq --argjson pins "$pins_json" --arg wp "$wp" '
            .barPinnedApps = (if ((.barPinnedApps // []) | length) == 0 then $pins else .barPinnedApps end)
          | .pinnedApps    = (if ((.pinnedApps    // []) | length) == 0 then $pins else .pinnedApps    end)
          | .wallpaperPath = (if (($wp | length) > 0 and ((.wallpaperPath // "") | length) == 0) then $wp else (.wallpaperPath // "") end)
        ' "$sess" > "$tmp" && [ -s "$tmp" ]; then
        if [ "$had_sess" -eq 1 ]; then
            cp -a "$sess" "$sess.bak-$STAMP"
            manifest_add_backup "$sess" "$sess.bak-$STAMP" user "$CUR_STAGE"
        fi
        cat "$tmp" > "$sess"
        ok "seeded taskbar/dock pins: ${SEED_PINNED_APPS[*]}"
        info "discord/steam/Spotify are installed by the standard-apps step (stage 3) unless you declined it."
        [ -n "$wp" ] && ok "seeded default wallpaper into session.json (DMS themes on first login: $SEED_WALLPAPER)"
        manifest_add_change session-seed "$CUR_STAGE" "session.json:seed" \
            "$(jq -nc --arg f "$sess" '{file:$f, keysSeeded:["barPinnedApps","pinnedApps","wallpaperPath"], note:"only set when empty/absent"}')" \
            "restore $sess from its .bak-*, or clear the seeded keys"
    else
        warn "couldn't seed pins/wallpaper into session.json (jq edit failed) — set them by hand after login."
    fi
    rm -f "$tmp"
else
    warn "jq not available — can't seed taskbar pins or wallpaper. Pin apps + pick a wallpaper by hand after login."
fi

if have dms; then
    if dms restart 2>/dev/null; then
        ok "DMS restarted"
    else
        warn "'dms restart' didn't succeed (DMS may not be running yet)."
        info "That's fine on a first install — config.conf autostarts it (exec-once = dms run &) at next login."
    fi
else
    warn "'dms' command not found — is DankMaterialShell installed? It will start at login if so."
fi

# Theme immediately if DMS is already up: `dms ipc call wallpaper set` applies the
# wallpaper, runs matugen, and persists state in one action — nicer than waiting for
# first login. On a fresh install DMS usually isn't up yet, and that's fine: the
# wallpaper was already seeded into session.json above, so DMS themes itself on first
# login (matugen only writes its theme files — dank-theme.toml, colors.conf, ... — the
# first time a wallpaper is applied, which either path now guarantees).
if [ ! -f "$seed_wall" ]; then
    warn "seed wallpaper not found: $seed_wall — theming not seeded."
    info "Set a wallpaper once in DMS (Super+W) to generate the theme. (SEED_WALLPAPER names the default.)"
elif ! have matugen; then
    warn "matugen not installed — can't generate the theme. Install it, then set a wallpaper once."
elif have dms && sleep 1 && seed_out="$(dms ipc call wallpaper set "$seed_wall" 2>/dev/null)" \
     && [ "${seed_out#ERROR}" = "$seed_out" ]; then
    ok "applied theming from $SEED_WALLPAPER via DMS now (wallpaper set + matugen, state persisted)"
else
    info "DMS not running yet — wallpaper was seeded into session.json above; DMS themes on first login."
fi

# =============================================================================
# 17. Done — next steps
# =============================================================================
stage "17/17  Done"
# Mark the manifest complete (a partial/crashed run leaves status "in-progress").
manifest_finalize
echo
echo "==================================================================="
printf ' %sDankMango install finished.%s' "$c_grn" "$c_off"
[ "$WARNINGS" -gt 0 ] && printf '  (%s%d warning(s) above — scroll up.%s)' "$c_yel" "$WARNINGS" "$c_off"
echo
echo "==================================================================="
cat <<EOF

  NEXT STEPS
   1. LOG OUT and back in. Some things only take effect on a fresh login,
      not a DMS reload — notably the keyd launcher (Super-tap) and any
      newly-enabled services.
   2. After logging back in, run the health check to confirm everything
      applied:
          ~/.config/mango/scripts/post-update-health.sh
   3. If anything shows [FAIL] there, it prints a paste-ready block you can
      hand to Claude Code.

  Backups of anything this script overwrote are alongside the originals with
  a  .bak-$STAMP  suffix.

  A record of everything this run did (packages installed, files backed up,
  system changes) is written to:
      $MANIFEST
  Future uninstall/update tooling reads this — leave it in place.
EOF
