#!/usr/bin/env bash
#
# Re-apply the Japanese-style SDDM astronaut theme with a 12-hour clock,
# using an UPDATE-PROOF copy that pacman does not own.
#
# Why this exists:
#   The package `sddm-astronaut-theme` owns everything under
#   /usr/share/sddm/themes/sddm-astronaut-theme/, so editing those files in
#   place gets wiped on every package update (that's what reset your config).
#   Instead we keep a *separate* copy under a different directory name that the
#   package manager never touches, and point SDDM at it.
#
# What it does (idempotent — safe to re-run any time):
#   1. rsync the freshly-installed upstream theme -> the copy dir
#      (so the copy picks up any new upstream assets/fixes on re-run).
#   2. Overlay our tracked, customized japanese_aesthetic.conf (12h clock).
#   3. Point the copy's metadata.desktop at the Japanese variant.
#   4. Set Current= to the copy in /etc/sddm.conf.d/theme.conf.
#
# Usage:  sudo ~/.config/sddm-astronaut-japanese/apply.sh
#
set -euo pipefail

UPSTREAM="/usr/share/sddm/themes/sddm-astronaut-theme"
COPY="/usr/share/sddm/themes/sddm-astronaut-theme-japanese"
VARIANT="japanese_aesthetic.conf"
SDDM_CONF="/etc/sddm.conf.d/theme.conf"

# Resolve the directory this script lives in, so our tracked conf is found
# regardless of who (root via sudo) runs it.
SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
CUSTOM_CONF="$SCRIPT_DIR/$VARIANT"

if [[ $EUID -ne 0 ]]; then
    echo "This needs root. Re-running with sudo..." >&2
    exec sudo "$0" "$@"
fi

[[ -d "$UPSTREAM" ]]      || { echo "ERROR: upstream theme not found at $UPSTREAM (is sddm-astronaut-theme installed?)" >&2; exit 1; }
[[ -f "$CUSTOM_CONF" ]]   || { echo "ERROR: customized conf not found at $CUSTOM_CONF" >&2; exit 1; }

echo "==> Syncing upstream theme into update-proof copy: $COPY"
mkdir -p "$COPY"
rsync -a --delete \
    --exclude="metadata.desktop" \
    "$UPSTREAM/" "$COPY/"

echo "==> Installing customized Japanese config (12-hour clock, light text)"
install -m 0644 "$CUSTOM_CONF" "$COPY/Themes/$VARIANT"

echo "==> Installing custom dark background"
install -m 0644 "$SCRIPT_DIR/japanese_aesthetic_dark.png" "$COPY/Backgrounds/japanese_aesthetic_dark.png"

echo "==> Pointing copy's metadata.desktop at the Japanese variant"
# Rebuild metadata.desktop from upstream but force ConfigFile + a distinct id/name.
sed -e "s|^ConfigFile=.*|ConfigFile=Themes/$VARIANT|" \
    -e "s|^Name=.*|Name=sddm-astronaut-theme-japanese|" \
    -e "s|^Theme-Id=.*|Theme-Id=sddm-astronaut-theme-japanese|" \
    "$UPSTREAM/metadata.desktop" > "$COPY/metadata.desktop"
chmod 0644 "$COPY/metadata.desktop"

echo "==> Setting SDDM Current= theme in $SDDM_CONF"
mkdir -p "$(dirname "$SDDM_CONF")"
cat > "$SDDM_CONF" <<EOF
[Theme]
Current=sddm-astronaut-theme-japanese
EOF

echo
echo "Done. Active theme -> sddm-astronaut-theme-japanese (Japanese variant, 12h clock)."
echo "Preview with:  sddm-greeter-qt6 --test-mode --theme $COPY"
