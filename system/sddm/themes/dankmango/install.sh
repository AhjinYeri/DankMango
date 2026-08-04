#!/usr/bin/env bash
#
# Install the DankMango SDDM theme.
#
# This is the ONLY step that needs root, and it is where the whole
# privilege-boundary design gets set up. After this runs once, the palette
# follows the wallpaper with no elevation, no polkit and no daemon --
# sddm-palette-sync.sh just rewrites one file as your normal user.
#
# What it lays down:
#   /usr/share/sddm/themes/dankmango/            root:root 0755  <- QML is CODE
#   /usr/share/sddm/themes/dankmango/*.qml       root:root 0644
#   /usr/share/sddm/themes/dankmango/theme.conf  root:root 0644  <- defaults
#   /usr/share/sddm/themes/dankmango/theme.conf.user  $USER 0644 <- palette
#
# WHY THE DIRECTORY STAYS ROOT-OWNED: the greeter executes the QML in that
# directory, as the sddm user, BEFORE anyone authenticates. If the directory
# were user-writable, anything running as you could drop QML into a pre-auth
# execution context. Making a single leaf INI file user-writable is a different
# and much smaller thing: its values reach QML as plain strings, and the theme
# only ever consumes them as validated #rrggbb colors.
#
# It also means the palette file cannot be replaced atomically (rename() needs
# write access to the directory). That is a deliberate trade -- see the note in
# sddm-palette-sync.sh.
#
# This does NOT switch SDDM over to the theme. Setting Current= is the step that
# can leave you at a broken login screen, so it stays a separate, explicit
# decision -- see the end of this script for the one-liner.
#
# Usage:  sudo ./install.sh [--user <name>]
#
set -euo pipefail

DEST="/usr/share/sddm/themes/dankmango"
SRC="$(cd "$(dirname "$(realpath "$0")")" && pwd)"

# Keep the ORIGINAL argv for the sudo re-exec below. Parsing --user first and then
# re-exec'ing with "$@" would drop it (the shift already happened), so an explicit
# `--user someone-else` silently became "whoever ran sudo".
ORIG_ARGS=("$@")

# Who owns the palette file. Defaults to the user invoking sudo, not root.
PALETTE_USER="${SUDO_USER:-}"
if [ "${1:-}" = "--user" ]; then
    PALETTE_USER="${2:-}"
    shift 2
fi

if [ "$EUID" -ne 0 ]; then
    echo "This needs root. Re-running with sudo..." >&2
    exec sudo -- "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
fi

if [ -z "$PALETTE_USER" ]; then
    echo "ERROR: could not determine which user should own the palette file." >&2
    echo "       Run via sudo (so SUDO_USER is set), or pass --user <name>." >&2
    exit 1
fi

if ! id -u "$PALETTE_USER" >/dev/null 2>&1; then
    echo "ERROR: no such user: $PALETTE_USER" >&2
    exit 1
fi

[ -f "$SRC/metadata.desktop" ] || { echo "ERROR: run this from the theme source dir" >&2; exit 1; }

echo "==> Installing theme to $DEST"
install -d -o root -g root -m 0755 "$DEST"
install -d -o root -g root -m 0755 "$DEST/Components"

install -o root -g root -m 0644 "$SRC/metadata.desktop" "$DEST/metadata.desktop"
install -o root -g root -m 0644 "$SRC/theme.conf"       "$DEST/theme.conf"
install -o root -g root -m 0644 "$SRC/Main.qml"         "$DEST/Main.qml"
# Theme assets. logo.png is referenced by Components/LoginForm.qml as "../logo.png";
# if it is not installed the card header renders a broken image.
install -o root -g root -m 0644 "$SRC/logo.png"         "$DEST/logo.png"
for f in "$SRC"/Components/*.qml; do
    install -o root -g root -m 0644 "$f" "$DEST/Components/$(basename "$f")"
done

# The user-writable leaves. Created empty (so the theme renders on its built-in
# defaults immediately) and handed to the user so the sync script can rewrite
# them later without any elevation.
#
#   theme.conf.user   the palette + the pointer to the live wallpaper slot
#   wallpaper-a.jpg   \_ two slots, so a multi-MB image can be written fully
#   wallpaper-b.jpg   /  before the pointer flips -- no torn reads
#
# These files must exist here and now: the sync script deliberately refuses to
# CREATE anything in this directory, because creating a file requires write
# permission on the directory itself, which is exactly what must stay root-only.
echo "==> Creating user-writable palette + wallpaper slots, owned by $PALETTE_USER"
PALETTE_GROUP="$(id -gn "$PALETTE_USER")"
for leaf in theme.conf.user wallpaper-a.jpg wallpaper-b.jpg; do
    [ -f "$DEST/$leaf" ] || : > "$DEST/$leaf"
    chown "$PALETTE_USER":"$PALETTE_GROUP" "$DEST/$leaf"
    chmod 0644 "$DEST/$leaf"
done

echo "==> Populating the palette from the current wallpaper"
SYNC="$(getent passwd "$PALETTE_USER" | cut -d: -f6)/.config/mango/scripts/sddm-palette-sync.sh"
if [ -x "$SYNC" ]; then
    sudo -u "$PALETTE_USER" -- "$SYNC" --verbose || echo "    (sync reported nothing to do)"
else
    echo "    skipped: $SYNC not found (it runs on the next wallpaper change anyway)"
fi

echo
echo "Installed. Verify it renders BEFORE switching to it:"
echo "    sddm-greeter-qt6 --test-mode --theme $DEST"
echo
echo "Then, to actually use it as the login screen:"
echo "    sudo sh -c 'printf \"[Theme]\\nCurrent=dankmango\\n\" > /etc/sddm.conf.d/theme.conf'"
echo
echo "Keep a TTY (Ctrl+Alt+F3) available the first time you reboot into it."
echo "F3, not F2: SDDM holds the first console and takes the second one too"
echo "if it is crash-looping, so F2 can land you back in the broken greeter."
