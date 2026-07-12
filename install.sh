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

# ---- pretty output ----------------------------------------------------------
c_blu=$'\033[1;34m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
stage() { printf '\n%s==> %s%s\n' "$c_blu" "$1" "$c_off"; }
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

# Copy a SYSTEM file (needs sudo). Backs up an existing, differing target.
#   sys_copy SRC DST
sys_copy() {
    local src="$1" dst="$2"
    if [ ! -f "$src" ]; then
        warn "repo is missing '$src' -> skipping (nothing to install for this step yet)"
        return 1
    fi
    sudo mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ] && ! sudo cmp -s "$src" "$dst"; then
        sudo cp -a "$dst" "$dst.bak-$STAMP"
        info "backed up existing $dst -> $dst.bak-$STAMP"
    fi
    sudo cp "$src" "$dst"
    ok "installed $dst"
    return 0
}

# Copy a USER file (no sudo). Backs up an existing, differing target.
#   user_copy SRC DST
user_copy() {
    local src="$1" dst="$2"
    if [ ! -f "$src" ]; then
        warn "repo is missing '$src' -> skipping this step"
        return 1
    fi
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
        cp -a "$dst" "$dst.bak-$STAMP"
        info "backed up existing $dst -> $dst.bak-$STAMP"
    fi
    cp "$src" "$dst"
    ok "installed $dst"
    return 0
}

echo "==================================================================="
echo " DankMango installer   ($STAMP)"
echo " repo: $REPO_DIR"
echo "==================================================================="

# =============================================================================
# 1. Sanity check: does this look like CachyOS? (soft — warn only)
# =============================================================================
stage "1/16  Checking this looks like a CachyOS system"
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
stage "2/16  Ensuring an AUR helper is available"
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
stage "3/16  Installing packages"
# Official-repo packages (the AUR helper pulls these straight from the repos).
REPO_PKGS=(nemo nemo-fileroller matugen cosmic-icon-theme xdg-desktop-portal-wlr keyd)
# AUR packages that DankMango needs.
AUR_PKGS=(zen-browser-bin sddm-astronaut-theme)
# NOTE: intentionally NOT installed here (CachyOS + MangoWM base already ships
# them): sddm, alacritty, the pipewire stack, wireplumber, networkmanager,
# power-profiles-daemon, bluez, fonts (noto / meslo-nerd), jq, libnotify, gawk,
# psmisc, xdg-desktop-portal-core. And capitaine-cursors is NOT used at all.
info "official-repo: ${REPO_PKGS[*]}"
info "AUR (required): ${AUR_PKGS[*]}"
# Run everything through the AUR helper: it installs repo packages from the
# official repos and AUR packages from the AUR in one resolve, which avoids
# guessing which repo (CachyOS vs Arch) matugen currently lives in.
if "$AUR" -S --needed --noconfirm "${REPO_PKGS[@]}" "${AUR_PKGS[@]}"; then
    ok "packages installed (already-present ones were skipped)"
else
    warn "one or more packages failed to install — scroll up for which. Re-run after fixing,"
    warn "or install the missing ones by hand: $AUR -S ${REPO_PKGS[*]} ${AUR_PKGS[*]}"
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
stage "4/16  Setting Nemo as the default file manager"
if have xdg-mime; then
    xdg-mime default nemo.desktop inode/directory && ok "Nemo set for inode/directory" \
        || warn "xdg-mime call failed — set Nemo as default file manager manually."
else
    warn "xdg-mime not found — skipping default-file-manager step."
fi

# =============================================================================
# 5. System-level files (need sudo)
# =============================================================================
stage "5/16  Installing system files (keyd, SDDM) — will prompt for sudo"

# 5a. keyd (Super-tap launcher etc.)
if sys_copy "$REPO_DIR/system/keyd/default.conf" "/etc/keyd/default.conf"; then
    if sudo systemctl enable --now keyd 2>/dev/null; then
        ok "keyd service enabled and started"
    else
        warn "couldn't enable/start keyd — run: sudo systemctl enable --now keyd"
    fi
else
    info "no keyd config shipped in the repo yet -> not enabling the keyd service."
fi

# 5b. SDDM astronaut theme customisations (12h clock + custom background), copied
#     into place so an AUR package update to sddm-astronaut-theme can't clobber them.
#     Convention: theme files live under system/sddm/theme/ ; drop-in *.conf under
#     system/sddm/ go to /etc/sddm.conf.d/. Both are guarded — nothing is invented.
if [ -d "$REPO_DIR/system/sddm/theme" ] && [ -n "$(ls -A "$REPO_DIR/system/sddm/theme" 2>/dev/null)" ]; then
    dest="/usr/share/sddm/themes/sddm-astronaut-theme"
    if [ -d "$dest" ]; then
        sudo cp -a "$dest" "$dest.bak-$STAMP" && info "backed up $dest -> $dest.bak-$STAMP"
    fi
    sudo mkdir -p "$dest"
    sudo cp -a "$REPO_DIR/system/sddm/theme/." "$dest/" && ok "SDDM theme customisations copied into $dest"
else
    warn "no SDDM theme files in system/sddm/theme/ -> skipping theme customisation."
    info "(the sddm-astronaut-theme AUR package still installed its own default theme.)"
fi

# 5c. SDDM drop-in config(s): system/sddm/*.conf -> /etc/sddm.conf.d/
shopt -s nullglob
sddm_confs=("$REPO_DIR"/system/sddm/*.conf)
shopt -u nullglob
if [ "${#sddm_confs[@]}" -gt 0 ]; then
    for f in "${sddm_confs[@]}"; do
        sys_copy "$f" "/etc/sddm.conf.d/$(basename "$f")"
    done
else
    warn "no SDDM *.conf drop-ins in system/sddm/ -> skipping /etc/sddm.conf.d/ setup."
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
stage "6/16  Making mango scripts executable"
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
stage "7/16  Installing mango + DankMaterialShell configs"

# 7a. mango tree (config.conf + scripts/) -> ~/.config/mango/
mkdir -p "$HOME/.config/mango"
if [ -f "$HOME/.config/mango/config.conf" ] && ! cmp -s "$REPO_DIR/config/mango/config.conf" "$HOME/.config/mango/config.conf"; then
    cp -a "$HOME/.config/mango/config.conf" "$HOME/.config/mango/config.conf.bak-$STAMP"
    info "backed up existing config.conf -> config.conf.bak-$STAMP"
fi
cp -a "$REPO_DIR/config/mango/." "$HOME/.config/mango/" && ok "mango config + scripts -> ~/.config/mango/"

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
    fi
done
cp -a "$REPO_DIR/config/dms/DankMaterialShell/." "$HOME/.config/DankMaterialShell/" \
    && ok "DMS config -> ~/.config/DankMaterialShell/"

# =============================================================================
# 8. Wallpapers -> ~/Pictures/Wallpapers/  (a sensible default matugen source)
#    Never clobbers existing wallpapers: same-named files already there are
#    skipped with a warning, same pattern as the other copy steps.
# =============================================================================
stage "8/16  Installing default wallpapers"
WALL_DST="$HOME/Pictures/Wallpapers"
if compgen -G "$REPO_DIR/wallpapers/*.png" >/dev/null; then
    mkdir -p "$WALL_DST"
    wall_copied=0; wall_skipped=0
    for w in "$REPO_DIR"/wallpapers/*.png; do
        base="$(basename "$w")"
        if [ -e "$WALL_DST/$base" ]; then
            warn "wallpaper already exists, not overwriting: $WALL_DST/$base"
            wall_skipped=$((wall_skipped+1))
        else
            cp "$w" "$WALL_DST/$base" && wall_copied=$((wall_copied+1))
        fi
    done
    ok "wallpapers: $wall_copied copied, $wall_skipped left untouched -> $WALL_DST"
    info "point matugen / your wallpaper picker at $WALL_DST"
else
    warn "no *.png files under wallpapers/ in the repo -> skipping wallpaper install."
fi

# =============================================================================
# 9. GTK theming (dank-colors + transparency import into gtk-3.0 / gtk-4.0)
# =============================================================================
stage "9/16  Layering GTK theming (gtk-3.0 / gtk-4.0)"
# Look for GTK theming source files in the repo. None are shipped today, so this
# is guarded rather than invented.
gtk_found=0
for pair in \
    "$REPO_DIR/config/gtk/gtk-3.0/gtk.css:$HOME/.config/gtk-3.0/gtk.css" \
    "$REPO_DIR/config/gtk/gtk-4.0/gtk.css:$HOME/.config/gtk-4.0/gtk.css" \
    "$REPO_DIR/config/dms/gtk-3.0/gtk.css:$HOME/.config/gtk-3.0/gtk.css" \
    "$REPO_DIR/config/dms/gtk-4.0/gtk.css:$HOME/.config/gtk-4.0/gtk.css"; do
    s="${pair%%:*}"; d="${pair##*:}"
    if [ -f "$s" ]; then user_copy "$s" "$d" && gtk_found=1; fi
done
if [ "$gtk_found" -eq 0 ]; then
    warn "no GTK theming files found in the repo (expected config/gtk/gtk-{3,4}.0/gtk.css)."
    warn "GTK frosted-glass theming is NOT applied — add those files to the repo, then re-run."
fi

# =============================================================================
# 10. DMS popupTransparency = 0.75
# =============================================================================
stage "10/16  Checking DMS popupTransparency"
SETTINGS="$HOME/.config/DankMaterialShell/settings.json"
if [ -f "$SETTINGS" ] && grep -q '"popupTransparency"[[:space:]]*:[[:space:]]*0.75' "$SETTINGS"; then
    ok "popupTransparency already 0.75 in settings.json (shipped) — no change needed"
elif [ -f "$SETTINGS" ] && have jq; then
    tmp="$(mktemp)"
    if jq '.popupTransparency = 0.75' "$SETTINGS" > "$tmp" && [ -s "$tmp" ]; then
        cp -a "$SETTINGS" "$SETTINGS.bak-$STAMP"; mv "$tmp" "$SETTINGS"
        ok "set popupTransparency = 0.75"
    else
        rm -f "$tmp"; warn "couldn't edit popupTransparency with jq — set it by hand in settings.json."
    fi
else
    warn "settings.json missing or jq unavailable — couldn't verify popupTransparency."
fi

# =============================================================================
# 11. Alacritty config (CachyOS's default has a known duplicate-key error)
# =============================================================================
stage "11/16  Installing Alacritty config"
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
stage "12/16  Power profile (optional)"
info "Pinning to 'performance' is great for a DESKTOP, but you should SKIP this on a laptop"
info "(it hurts battery life)."
if ask_yn "Pin power profile to 'performance' now?"; then
    if have powerprofilesctl; then
        sudo systemctl enable --now power-profiles-daemon.service 2>/dev/null
        if powerprofilesctl set performance 2>/dev/null; then
            ok "power profile set to performance for this session"
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
stage "13/16  easyeffects autostart (optional)"
CONF="$HOME/.config/mango/config.conf"
EE_LINE_RE='^[[:space:]]*#?[[:space:]]*exec-once[[:space:]]*=[[:space:]]*easyeffects'
if [ -f "$CONF" ] && grep -qE "$EE_LINE_RE" "$CONF"; then
    if ask_yn "Autostart easyeffects with your session?"; then
        # uncomment the exec-once easyeffects line
        sed -i -E "s|^[[:space:]]*#[[:space:]]*(exec-once[[:space:]]*=[[:space:]]*easyeffects.*)|\1|" "$CONF"
        ok "easyeffects autostart ENABLED (exec-once left active in config.conf)"
        have easyeffects || warn "easyeffects isn't installed — install it, or the autostart line will no-op."
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
stage "14/16  Installing DMS plugins"
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
    # sanity-check it's registered (it ships registered; warn if somehow not)
    grep -q "\"$pid\"" "$HOME/.config/DankMaterialShell/plugin_settings.json" 2>/dev/null \
        || warn "plugin '$pid' not found in plugin_settings.json — enable it in DMS Settings -> Plugins."
    grep -q "\"$pid\"" "$SETTINGS" 2>/dev/null \
        || warn "plugin '$pid' not in settings.json bar widgets — add it via Settings -> Appearance -> DankBar Layout."
done

# =============================================================================
# 15. Restart DMS to apply
# =============================================================================
stage "15/16  Restarting DankMaterialShell"
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

# =============================================================================
# 16. Done — next steps
# =============================================================================
stage "16/16  Done"
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
EOF
