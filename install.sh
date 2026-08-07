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

# Shared helpers, manifest bookkeeping, package/seed arrays, the AUR-helper
# bootstrap, and the repo->dest routing table all live in lib/common.sh so that
# install.sh and update.sh use ONE copy. REPO_DIR (above) is resolved first
# because the library reads it; sourcing only defines things (no actions).
source "$REPO_DIR/lib/common.sh"

# ---- --reselect-main-display: re-run JUST the main-display prompt -------------
# A user who dismissed the watcher's "main display disconnected" notification
# without clicking either button has no other way back — the next prompt would only
# come with the next hotplug. Rather than invent a second UI, this re-runs the very
# same selector stage 7e uses and exits. Deliberately placed ABOVE the confirmation
# gate and manifest_init: it changes exactly one preference key, so making someone
# type "I understand" (a warning about replacing their whole config) would be a lie.
if [ "${1:-}" = "--reselect-main-display" ]; then
    echo "==================================================================="
    echo " DankMango — reselect main display"
    echo "==================================================================="
    if [ ! -f "$MANIFEST" ]; then
        die "no install manifest at $MANIFEST — run the installer first (bash install.sh)"
    fi
    if select_main_display; then
        info "monitor-watcher.sh has regenerated the game windowrules for the new choice."
    else
        info "nothing changed."
    fi
    exit 0
fi

echo "==================================================================="
echo " DankMango installer   ($STAMP)"
echo " repo: $REPO_DIR"
echo "==================================================================="

# =============================================================================
# Confirmation gate — runs on EVERY install, before anything else happens.
# =============================================================================
# Deliberately universal rather than "only if we detect an existing config":
# detection is guesswork, and the consequence of guessing wrong is someone's
# personalised setup changing under them without warning. One typed word is a
# cheap price for that. This sits above manifest_init so a declined run leaves
# NOTHING behind — not even a manifest.
printf '\n%s' "$c_yel"
cat <<'EOF'
    ------------------------------------------------------------------
     READ THIS FIRST
    ------------------------------------------------------------------
     This REPLACES your mango + DMS config wholesale. It is not a
     gentle merge on top of whatever you've already got set up — if
     you've personalised things, your setup will visibly change the
     moment this runs.

     Everything it overwrites is backed up first (<file>.bak-<stamp>),
     and ./uninstall.sh can walk it back. So it's reversible.

     But if you've got a MangoWM/DMS setup you actually care about,
     back it up yourself too before you continue — a git commit, a
     snapper snapshot, whatever you'd normally do. Don't lean solely
     on DankMango's own backups for something you can't afford to lose.
    ------------------------------------------------------------------
EOF
printf '%s\n' "$c_off"
if ! ask_typed "Type 'I understand' to continue (anything else aborts): " "I understand"; then
    echo ""
    info "Aborted — nothing was changed."
    exit 0
fi

# Stage 0 (setup, not user-facing): open the install manifest FIRST, so even a run
# that crashes early leaves an accurate partial record. Every stage below appends to
# it as it acts (one write per action), rather than a bulk dump at the end.
manifest_init

# =============================================================================
# 1. Sanity check: does this look like CachyOS? (soft — warn only)
# =============================================================================
stage "1/18  Checking this looks like a CachyOS system"
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
stage "2/18  Ensuring an AUR helper is available"
ensure_aur_helper
ok "using AUR helper: $AUR"

# =============================================================================
# 3. Install packages
# =============================================================================
stage "3/18  Installing packages"
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


# Install the core set in one resolve (--needed skips already-present ones efficiently).
if "$AUR" -S --needed --noconfirm "${REPO_PKGS[@]}" "${AUR_PKGS[@]}"; then
    ok "core packages installed (already-present ones were skipped)"
else
    warn "one or more core packages failed to install — scroll up for which, or check the"
    warn "manifest's packagesFailed (stage 17 prints it). Re-run after fixing, or install"
    warn "the missing ones by hand: $AUR -S ${REPO_PKGS[*]} ${AUR_PKGS[*]}"
fi
manifest_record_pkgs repo required "${REPO_PKGS[@]}"
manifest_record_pkgs aur  required "${AUR_PKGS[@]}"

# ---- Standard taskbar apps (issue #5) — one opt-in, default YES -------------------
info "standard taskbar apps (optional): ${STANDARD_APPS[*]}  (Spotify = spotify-launcher)"
if ask_yn_default_yes "Install the standard taskbar apps (Spotify, Steam, Discord)? Saying no just leaves them out — only installed apps get pinned."; then
    if "$AUR" -S --needed --noconfirm "${STANDARD_APPS[@]}"; then
        ok "standard apps installed (already-present ones were skipped)"
    else
        warn "one or more standard apps failed to install — add them later: $AUR -S ${STANDARD_APPS[*]}"
        warn "  (anything that failed is recorded in the manifest — see the stage 17 summary.)"
    fi
    manifest_record_pkgs repo standard-app "${STANDARD_APPS[@]}"
    info "(Spotify uses spotify-launcher — it fetches the actual client on first launch, so the"
    info " taskbar pin binds once you've opened Spotify once.)"
else
    info "Skipped standard apps — Spotify/Steam/Discord won't be pinned. Install them later"
    info "and pin them by hand, or clear session.json's pin lists and re-run to re-seed."
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
# 4. Default applications (file manager, image viewer) + Nemo sidebar defaults
# =============================================================================
stage "4/18  Setting default applications (Nemo, Loupe, Celluloid)"

# 4a. Nemo icon override.
#
# Nemo's shipped .desktop declares `Icon=system-file-manager` -- correct per the
# icon-naming spec, but it means Nemo renders as whatever generic the icon theme
# provides for that name. DankMango ships cosmic-icon-theme (stage 3), and Cosmic
# draws system-file-manager as a grey filing cabinet (it's COSMIC Files' own
# branding), so the pinned Nemo entry in the DankBar shows a cabinet, not a folder.
#
# Verified chain, not assumed: AppsDock -> Paths.getAppIcon() prefers
# desktopEntry.icon over every other lookup, so the .desktop's Icon= is what wins.
# Fixing it there fixes it everywhere at once (bar pin, dock, launcher, GTK).
#
# We point it at `folder` -- NOT at `nemo`. Both fix the cabinet, but `nemo` gives
# you Nemo's own green branded icon, which then clashes with the plain grey folders
# Nemo draws in its actual file view. `folder` is the same generic name those folders
# use, so the pin matches the file manager's own visual language and, being generic,
# tracks whatever icon theme is active instead of pinning one app's branding. Under
# DankMango's default that resolves to Cosmic's scalable places/folder.svg -- no
# vendored asset needed. ~/.local/share/applications outranks
# /usr/share/applications, so the override survives nemo package updates.
#
# NOTE: .desktop files do NOT merge key-by-key -- a user-level file REPLACES the
# system one wholesale. That's why config/applications/nemo.desktop is a verbatim
# copy (all Name[xx] translations, MimeType, and the three Desktop Actions included)
# with ONLY the Icon= line changed. Don't trim it down to a few keys: that would
# silently drop Nemo's translations and its Home/Computer/Trash right-click actions.
if pacman -Qi nemo >/dev/null 2>&1; then
    if user_copy "$REPO_DIR/config/applications/nemo.desktop" \
                 "$HOME/.local/share/applications/nemo.desktop"; then
        # Refresh the user-dir desktop database so the MimeType associations in the
        # override (and the xdg-mime defaults set just below) resolve against it.
        if have update-desktop-database; then
            update-desktop-database "$HOME/.local/share/applications" 2>/dev/null \
                && ok "user desktop database refreshed" \
                || warn "update-desktop-database failed — harmless, but re-run it if Nemo's file associations look off"
        fi
    fi
else
    info "nemo isn't installed — skipping the Nemo icon override."
fi

# 4b. Nemo "Copy as Path" right-click action.
#
# Nemo has no built-in "copy the absolute path" entry. config/applications/
# copy-as-path.nemo_action adds one (copies the selection's path to the Wayland
# clipboard via wl-copy). Same authoring+deploy pattern as the nemo.desktop
# override: verbatim file in the repo, installed with user_copy (backup + manifest
# record), and routed by route_dest so update.sh re-syncs it. The ONE difference is
# the destination — Nemo scans ~/.local/share/nemo/actions/ for actions, NOT the
# .desktop applications dir — which is why route_dest special-cases *.nemo_action.
# wl-copy ships with wl-clipboard (a DankMango dependency); the action's own
# Dependencies=wl-copy; line hides the entry if it's ever missing.
if pacman -Qi nemo >/dev/null 2>&1; then
    user_copy "$REPO_DIR/config/applications/copy-as-path.nemo_action" \
              "$HOME/.local/share/nemo/actions/copy-as-path.nemo_action" \
        && ok "Nemo 'Copy as Path' action installed" || true
fi

# 4c. Quick-Access-style sidebar bookmarks (SEED ONLY -- never overwrites).
#
# Out of the box Nemo's sidebar has no bookmarks at all, so Documents/Pictures/
# Music/Videos/Downloads are only reachable by drilling into Home. Windows puts
# exactly those under a "Quick Access" group; this seeds the equivalent.
#
# Two moving parts, and they are NOT the same mechanism:
#
#   1. The bookmark LIST is ~/.config/gtk-3.0/bookmarks -- the shared GTK3
#      bookmarks file (Nemo reads it via g_get_user_config_dir()/gtk-3.0/bookmarks,
#      falling back to the legacy ~/.gtk-bookmarks). Format is one bookmark per
#      line, `URI[ optional label]`, split on the FIRST space. We deliberately
#      write the URI only: with no label Nemo shows the folder's own display
#      name, so a localized "Documents" stays localized instead of being pinned
#      to our English string.
#
#   2. The GROUPING is org.nemo.window-state sidebar-bookmark-breakpoint, an
#      index into that list. Bookmarks BEFORE the index render inline in the
#      "My Computer" section (SECTION_XDG_BOOKMARKS); bookmarks FROM the index
#      onward render under the collapsible "Bookmarks" heading (SECTION_BOOKMARKS).
#      Its default is -1, which Nemo clamps to "all of them inline" -- i.e. no
#      Bookmarks group at all. 0 puts every bookmark in the group, which is the
#      Quick Access look. Nemo rewrites this value itself when you drag a
#      bookmark across the section boundary, so it is user state: we only set it
#      on the same run in which we seed the list.
#
# This is a SEED, not a managed file: an existing non-empty bookmarks file is a
# hand-tuned list (the user bookmarked things, or reordered ours) and is left
# completely alone -- same principle as config.local.sh and the DMS state files.
# That is also why it is generated here rather than shipped in config/ and routed
# through route_dest: a repo file would be re-synced by update.sh on every run,
# which is exactly the clobbering we want to avoid.
NEMO_BOOKMARKS="$HOME/.config/gtk-3.0/bookmarks"

# XDG keys in the order they should appear in the sidebar. DOWNLOAD is singular
# -- that is the actual xdg-user-dirs key name, `DOWNLOADS` resolves to nothing.
NEMO_BOOKMARK_DIRS=(DOCUMENTS PICTURES MUSIC VIDEOS DOWNLOAD)

# Percent-encode a filesystem path for use in a file:// URI, leaving '/' and the
# RFC 3986 unreserved set alone. Nemo hands each line to g_file_new_for_uri(),
# which does NOT tolerate a raw space -- so a $HOME containing a space (or any
# non-ASCII byte) would silently produce a dead bookmark without this.
uri_encode_path() {
    # LC_ALL=C makes ${#s} / ${s:i:1} step over BYTES rather than characters, so a
    # multi-byte UTF-8 name encodes to one %XX per byte (what RFC 3986 wants) and
    # not one %XX per codepoint (which would be wrong and unopenable).
    local s="$1" out="" i c LC_ALL=C
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9._~/-]) out+="$c" ;;
            *) out+="$(printf '%%%02X' "'$c")" ;;
        esac
    done
    printf '%s' "$out"
}

if [ -s "$NEMO_BOOKMARKS" ]; then
    info "$NEMO_BOOKMARKS already has entries — leaving your bookmarks untouched"
else
    bookmark_lines=""
    bookmark_count=0
    for key in "${NEMO_BOOKMARK_DIRS[@]}"; do
        # xdg-user-dir returns $HOME for any key it can't resolve (no
        # ~/.config/user-dirs.dirs yet, or the key is absent from it), so a bare
        # "did it print something" check isn't enough — compare against $HOME.
        dir=""
        if have xdg-user-dir; then
            dir="$(xdg-user-dir "$key" 2>/dev/null || true)"
            [ "$dir" = "$HOME" ] && dir=""
        fi
        # Fall back to the conventional English name under $HOME. Capitalise the
        # key, and special-case DOWNLOAD -> Downloads (dir is plural, key isn't).
        if [ -z "$dir" ]; then
            case "$key" in
                DOWNLOAD) dir="$HOME/Downloads" ;;
                *) dir="$HOME/$(printf '%s' "${key:0:1}")$(printf '%s' "${key:1}" | tr '[:upper:]' '[:lower:]')" ;;
            esac
        fi
        # Skip what doesn't exist. A bookmark pointing at a missing folder shows
        # up broken in the sidebar and makes Nemo nag "Do you want to remove any
        # bookmarks with the non-existing location from your list?" on startup —
        # a bad first impression on a system with, say, no ~/Music.
        if [ -d "$dir" ]; then
            bookmark_lines+="file://$(uri_encode_path "$dir")"$'\n'
            bookmark_count=$((bookmark_count + 1))
        else
            info "no $dir — skipping that bookmark"
        fi
    done

    if [ "$bookmark_count" -eq 0 ]; then
        warn "none of the XDG user folders exist — skipping the sidebar bookmarks seed."
    else
        mkdir -p "$(dirname "$NEMO_BOOKMARKS")"
        printf '%s' "$bookmark_lines" > "$NEMO_BOOKMARKS"
        ok "seeded $bookmark_count sidebar bookmarks -> $NEMO_BOOKMARKS"
        have jq && manifest_add_change user-file-installed "$CUR_STAGE" "$NEMO_BOOKMARKS" \
            "$(jq -nc --arg p "$NEMO_BOOKMARKS" --argjson n "$bookmark_count" \
                '{path:$p, preexisting:false, scope:"user", seeded:true, count:$n}')" \
            "rm $NEMO_BOOKMARKS"

        # Only now — on the run that seeded the list — claim the breakpoint.
        if pacman -Qi nemo >/dev/null 2>&1 && have gsettings; then
            # (Whether that heading starts expanded is 4d's business, not ours.)
            if gsettings set org.nemo.window-state sidebar-bookmark-breakpoint 0 2>/dev/null; then
                ok "sidebar bookmarks grouped under a 'Bookmarks' heading (Quick Access style)"
                have jq && manifest_add_change gsetting "$CUR_STAGE" \
                    "org.nemo.window-state/sidebar-bookmark-breakpoint" \
                    "$(jq -nc '{schema:"org.nemo.window-state", key:"sidebar-bookmark-breakpoint", value:0}')" \
                    "gsettings reset org.nemo.window-state sidebar-bookmark-breakpoint"
            else
                warn "couldn't set sidebar-bookmark-breakpoint — bookmarks will show inline under My Computer."
            fi
        fi
    fi
fi

# 4d. Sidebar section collapse defaults (PER-KEY SEED -- never clobbers a choice).
#
# Nemo's places sidebar has four collapsible sections, each with its own
# org.nemo.window-state key, and all four default to true (expanded):
#
#     my-computer-expanded   Home, Desktop, Recent, File System, ...
#     bookmarks-expanded     the "Bookmarks" group seeded in 4c
#     devices-expanded       mounted disks and removable media
#     network-expanded       network shares
#
# All-expanded is a wall of entries. Windows keeps the equivalents of Devices
# ("This PC") and Network folded away until you ask for them, which is also the
# honest ordering here: My Computer and Bookmarks hold what actually gets
# clicked, so those two stay open and the other two start closed.
#
# "Don't clobber a user preference" is exact here rather than a heuristic. Nemo
# writes these keys only from update_expanded_state(), which early-returns while
# sidebar->updating_sidebar is set -- so the programmatic expand/collapse it runs
# on every startup and every sidebar refresh writes nothing, and a key acquires a
# user-level dconf value ONLY when someone clicks a disclosure triangle. That
# makes an empty `dconf read` a precise "never touched this" signal: we seed it,
# and anything already carrying a value is a deliberate choice we leave alone --
# on the first install and on every update after it.
#
# Note this is deliberately per-key rather than gated on 4c having seeded the
# bookmarks file: existing DankMango installs already have that file, and tying
# the two together would mean they never picked these defaults up at all.
#
# Not set here: the "Recent" row. Its only gate anywhere in Nemo is
# org.cinnamon.desktop.privacy remember-recent-files (NOT the org.gnome one),
# and that is a system-wide privacy switch -- turning it off stops recent-file
# tracking for every GTK app's file chooser, not just this sidebar row. Too
# blunt to flip on someone's behalf for a cosmetic win. To hide the row:
#     gsettings set org.cinnamon.desktop.privacy remember-recent-files false
NEMO_SECTION_DEFAULTS=(
    "my-computer-expanded=true"
    "bookmarks-expanded=true"
    "devices-expanded=false"
    "network-expanded=false"
)

if pacman -Qi nemo >/dev/null 2>&1 && have gsettings; then
    if ! have dconf; then
        # Without dconf there's no way to tell "user chose true" from "schema
        # default true", and guessing would mean re-collapsing a section every
        # update for someone who keeps opening it. Doing nothing is correct.
        info "dconf not available — leaving Nemo's sidebar section states alone"
    else
        for entry in "${NEMO_SECTION_DEFAULTS[@]}"; do
            section_key="${entry%%=*}"
            section_val="${entry#*=}"
            if [ -n "$(dconf read "/org/nemo/window-state/$section_key" 2>/dev/null || true)" ]; then
                info "$section_key already chosen — leaving it as you set it"
                continue
            fi
            if gsettings set org.nemo.window-state "$section_key" "$section_val" 2>/dev/null; then
                ok "sidebar default: $section_key=$section_val"
                have jq && manifest_add_change gsetting "$CUR_STAGE" \
                    "org.nemo.window-state/$section_key" \
                    "$(jq -nc --arg k "$section_key" --argjson v "$section_val" \
                        '{schema:"org.nemo.window-state", key:$k, value:$v}')" \
                    "gsettings reset org.nemo.window-state $section_key"
            else
                warn "couldn't set $section_key — that section keeps Nemo's default."
            fi
        done
    fi
fi

# Image types Loupe takes over. Loupe already declares these in its own .desktop
# MimeType list; setting them here only decides which app WINS, so a double-click in
# Nemo lands in Loupe instead of whatever happens to sort first. Add a type here and
# it's picked up automatically -- the manifest records one entry per mimetype, so the
# uninstaller can report each one it changed.
IMAGE_MIMES=(image/jpeg image/png image/gif image/webp image/bmp image/tiff image/svg+xml)

# Video types Celluloid takes over -- same reasoning and same mechanism as IMAGE_MIMES
# above (Celluloid declares these itself; setting them here only decides the winner).
# Kept to formats mpv handles natively, which is all of these.
VIDEO_MIMES=(video/mp4 video/x-matroska video/webm video/quicktime video/x-msvideo video/mpeg video/ogg video/x-ms-wmv)

if have xdg-mime; then
    if xdg-mime default nemo.desktop inode/directory; then
        ok "Nemo set for inode/directory"
        have jq && manifest_add_change default-app "$CUR_STAGE" "inode/directory" \
            "$(jq -nc '{mime:"inode/directory", app:"nemo.desktop"}')" \
            "reset with: xdg-mime default <your-previous-fm>.desktop inode/directory"
    else
        warn "xdg-mime call failed — set Nemo as default file manager manually."
    fi

    # Only claim the image types if Loupe is ACTUALLY installed. Same reasoning as the
    # taskbar pins in stage 16, and the same failure it prevents: if the stage-3 install
    # fell over (a mirror hiccup is enough), pointing every image type at a missing app
    # would make double-clicking a photo do NOTHING -- strictly worse than leaving
    # whatever viewer you already had. `loupe` is the exact package name in the official
    # repos (cachyos-extra-v3 / Arch extra); org.gnome.Loupe.desktop is the exact ID it
    # ships -- both verified against the package, not assumed.
    if pacman -Qi loupe >/dev/null 2>&1; then
        if xdg-mime default org.gnome.Loupe.desktop "${IMAGE_MIMES[@]}"; then
            ok "Loupe set as the default image viewer (${#IMAGE_MIMES[@]} image types)"
            if have jq; then
                for m in "${IMAGE_MIMES[@]}"; do
                    manifest_add_change default-app "$CUR_STAGE" "$m" \
                        "$(jq -nc --arg m "$m" '{mime:$m, app:"org.gnome.Loupe.desktop"}')" \
                        "reset with: xdg-mime default <your-previous-viewer>.desktop $m"
                done
            fi
        else
            warn "xdg-mime call failed — set Loupe as your image viewer manually:"
            warn "  xdg-mime default org.gnome.Loupe.desktop ${IMAGE_MIMES[*]}"
        fi
    else
        warn "loupe isn't installed — leaving your current image viewer alone."
        info "  (did stage 3 fail? install it with: sudo pacman -S loupe, then re-run install.sh)"
    fi

    # Same guard, same reasoning as Loupe above: only claim the video types if Celluloid
    # actually installed, so a failed stage 3 can't leave every video file opening
    # NOTHING. `celluloid` is the package name in the official repos (extra);
    # io.github.celluloid_player.Celluloid.desktop is the ID it ships.
    if pacman -Qi celluloid >/dev/null 2>&1; then
        if xdg-mime default io.github.celluloid_player.Celluloid.desktop "${VIDEO_MIMES[@]}"; then
            ok "Celluloid set as the default video player (${#VIDEO_MIMES[@]} video types)"
            if have jq; then
                for m in "${VIDEO_MIMES[@]}"; do
                    manifest_add_change default-app "$CUR_STAGE" "$m" \
                        "$(jq -nc --arg m "$m" '{mime:$m, app:"io.github.celluloid_player.Celluloid.desktop"}')" \
                        "reset with: xdg-mime default <your-previous-player>.desktop $m"
                done
            fi
        else
            warn "xdg-mime call failed — set Celluloid as your video player manually:"
            warn "  xdg-mime default io.github.celluloid_player.Celluloid.desktop ${VIDEO_MIMES[*]}"
        fi
    else
        warn "celluloid isn't installed — leaving your current video player alone."
        info "  (did stage 3 fail? install it with: sudo pacman -S celluloid, then re-run install.sh)"
    fi
else
    warn "xdg-mime not found — skipping the default-application steps."
fi

# =============================================================================
# 5. System-level files (need sudo)
# =============================================================================
stage "5/18  Installing system files (keyd, SDDM) — will prompt for sudo"

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

# 5b. SDDM: DankMango's own login theme.
#
#     REPLACES the old sddm-astronaut-theme (AUR) + apply.sh arrangement. That one
#     needed an AUR package, rsync, and an update-proof copy dance purely because we
#     were customising somebody else's package-owned theme. Shipping our own theme
#     deletes all three problems, and buys the thing the astronaut theme could never
#     do: the login screen follows the wallpaper, via scripts/sddm-palette-sync.sh.
#
#     THE PRIVILEGE BOUNDARY IS THE WHOLE DESIGN — the theme's install.sh owns it:
#       $SDDM_THEME_DEST/            root:root 0755   <- the greeter EXECUTES the QML
#       $SDDM_THEME_DEST/*.qml       root:root 0644      in here, as the `sddm` user,
#       $SDDM_THEME_DEST/theme.conf  root:root 0644      BEFORE anyone authenticates
#       $SDDM_THEME_DEST/theme.conf.user      $USER 0644 <- palette (2 writable leaves,
#       $SDDM_THEME_DEST/wallpaper-[ab].jpg   $USER 0644    values only, never code)
#     We deliberately do NOT reimplement that split here: one copy of a pre-auth
#     privilege boundary is enough. sddm_theme_install() shells out to the theme's
#     own installer (see lib/common.sh).
#
#     WHAT THIS STAGE DOES NOT DO: set Current=. See SDDM_SET_CURRENT in lib/common.sh.
if [ -d "$REPO_DIR/system/sddm/themes/$SDDM_THEME_ID" ]; then
    info "Installing the DankMango login theme to $SDDM_THEME_DEST — needs sudo."
    if sddm_theme_install; then
        ok "DankMango login theme installed (root-owned code, user-owned palette leaves)"
        # Recorded as a SYSTEM-scoped owned-tree: uninstall.sh moves the whole tree to
        # the rescue dir (with sudo — the tree is root-owned) rather than deleting it.
        have jq && manifest_add_change owned-tree "$CUR_STAGE" "$SDDM_THEME_DEST" \
            "$(jq -nc --arg d "$SDDM_THEME_DEST" --arg id "$SDDM_THEME_ID" \
                '{dir:$d, scope:"system", themeId:$id, note:"root-owned theme tree; holds the user-writable theme.conf.user + wallpaper-[ab].jpg leaves"}')" \
            "sudo rm -rf $SDDM_THEME_DEST"
    else
        warn "the login theme didn't install — re-run: sudo $REPO_DIR/system/sddm/themes/$SDDM_THEME_ID/install.sh"
    fi

    # ---- the deferred cutover (OFF by default) ------------------------------
    # Gated, not commented out, so the cutover session can exercise this exact path.
    if [ "$SDDM_SET_CURRENT" = 1 ] && [ -d "$SDDM_THEME_DEST" ]; then
        warn "DANKMANGO_SDDM_SET_CURRENT=1 — switching the ACTIVE login theme to $SDDM_THEME_ID."
        warn "Keep a TTY (Ctrl+Alt+F3) available before you reboot (F3, not F2 —"
        warn "SDDM holds the first console and a crash-loop takes the second too)."
        sddm_warn_shadowing_dropin || true
        # Capture the pre-flip state BEFORE writing, so uninstall can put it back even
        # when Current= lived in a file we never touch (e.g. /etc/sddm.conf).
        prev_cur=""; prev_file=""
        if cur_tsv="$(sddm_current_theme)"; then
            IFS=$'\t' read -r prev_cur prev_file <<<"$cur_tsv"
            info "previous login theme: ${prev_cur:-<sddm default>} (from ${prev_file:-nowhere})"
        fi
        # Write via a temp file + sys_copy so the existing /etc/sddm.conf.d/theme.conf
        # (if any) gets the standard manifest-tracked backup — that backup is what
        # uninstall.sh stage 3 restores.
        tmp_theme_conf="$(mktemp)"
        printf '[Theme]\nCurrent=%s\n' "$SDDM_THEME_ID" > "$tmp_theme_conf"
        if sys_copy "$tmp_theme_conf" "$SDDM_THEME_CONF"; then
            ok "login theme switched -> $SDDM_THEME_ID"
            have jq && manifest_add_change sddm-theme-applied "$CUR_STAGE" "theme.conf" \
                "$(jq -nc --arg id "$SDDM_THEME_ID" --arg w "$SDDM_THEME_CONF" \
                          --arg pc "$prev_cur" --arg pf "$prev_file" \
                    '{themeId:$id, writes:[$w],
                      previousCurrent:(if $pc=="" then null else $pc end),
                      previousCurrentFile:(if $pf=="" then null else $pf end),
                      note:"if previousCurrentFile is not this file, removing this drop-in restores the old value on its own"}')" \
                "remove $SDDM_THEME_CONF (reverts to ${prev_cur:-the SDDM default theme})"
        else
            warn "couldn't write $SDDM_THEME_CONF — the login theme was NOT switched."
        fi
        rm -f "$tmp_theme_conf"
    else
        sddm_print_cutover_hint
    fi
else
    warn "no login theme in system/sddm/themes/$SDDM_THEME_ID/ -> skipping SDDM theming."
    info "(SDDM keeps whatever login theme it is already using.)"
fi

# 5c. SDDM drop-in config(s) that are plain static copies (e.g. numlock.conf):
#     system/sddm/sddm.conf.d/*.conf -> /etc/sddm.conf.d/
#     NOTE: theme.conf is intentionally NOT shipped here. It is written (or not)
#     by the gated cutover in 5b, because it has to record the PREVIOUS Current=
#     value in the manifest — a static copy can't do that.
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
stage "6/18  Making mango scripts executable"
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
stage "7/18  Installing mango + DankMaterialShell configs"

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

# 7d. Auto-generate per-monitor layout tagrules -> ~/.config/mango/dms/tagrules.conf
#     config.conf sources this file; the generator queries the RUNNING compositor for
#     connected outputs and writes one 9-line TILE block per monitor -- replacing the
#     old "hand-edit the MONITOR-1 template" step. Core functionality, so it runs
#     unconditionally (no prompt). It needs mango up (DankMango assumes an existing
#     session); if it can't detect outputs it still writes a valid header-only file so
#     the source= line never dangles. We also drop a placeholder first, mirroring the
#     outputs.conf pattern, so a generator failure can't leave a missing source target.
TAGRULES_GEN="$HOME/.config/mango/scripts/generate-tagrules.sh"
TAGRULES_FILE="$HOME/.config/mango/dms/tagrules.conf"
if [ ! -f "$TAGRULES_FILE" ]; then
    printf '# Auto-generated by scripts/generate-tagrules.sh. Placeholder created by install.sh.\n' > "$TAGRULES_FILE"
fi
if [ -x "$TAGRULES_GEN" ]; then
    if "$TAGRULES_GEN"; then
        ok "generated per-monitor tagrules -> $TAGRULES_FILE"
    else
        warn "generate-tagrules.sh had a problem — re-run it after login: $TAGRULES_GEN"
    fi
    # A generated (not backed-up) file: record it as a systemChange so uninstall can
    # find/remove it, with the monitors it was built from for context.
    if have jq; then
        mons_json="$(mmsg get all-monitors 2>/dev/null | jq -c '[.monitors[].name]' 2>/dev/null)"; [ -n "$mons_json" ] || mons_json='[]'
        manifest_add_change files-generated "$CUR_STAGE" "$TAGRULES_FILE" \
            "$(jq -nc --arg f "$TAGRULES_FILE" --argjson m "$mons_json" '{file:$f, generator:"generate-tagrules.sh", monitors:$m, note:"regenerate with the generator after hardware changes"}')" \
            "rm $TAGRULES_FILE (re-created by generate-tagrules.sh)"
    fi
else
    warn "generate-tagrules.sh not found/executable at $TAGRULES_GEN — per-monitor tagrules not generated."
    info "Was config/mango/scripts/ copied in stage 7a? Then run: $TAGRULES_GEN"
fi

# 7e. Main display -- the ONE thing here that genuinely cannot be inferred.
#     "Biggest" and "leftmost" are both wrong often enough (small primary + big
#     secondary is a common desk) that guessing would be worse than asking. The
#     answer goes in the manifest under .userPrefs.mainDisplay, which
#     scripts/monitor-watcher.sh reads to keep the generated Steam game
#     windowrules (dms/mainmonitor.conf) pointed at the right monitor.
#     Never fatal: declining, cancelling, a single-monitor machine, or mango not
#     being up all leave the key unset, which the watcher treats as a valid state.
if select_main_display; then
    MAINRULES_FILE="$HOME/.config/mango/dms/mainmonitor.conf"
    if have jq && [ -f "$MAINRULES_FILE" ]; then
        # The rules file is generated (never backed up), so record it for uninstall.
        # The PREFERENCE itself is not recorded: userPrefs is the user's, not install
        # bookkeeping, and uninstall has no business reverting it.
        manifest_add_change files-generated "$CUR_STAGE" "$MAINRULES_FILE" \
            "$(jq -nc --arg f "$MAINRULES_FILE" '{file:$f, generator:"monitor-watcher.sh", note:"regenerated whenever the main display changes"}')" \
            "rm $MAINRULES_FILE (re-created by monitor-watcher.sh)"
    fi
else
    info "no main display recorded — Steam games will open wherever the pointer is."
    info "you can set it any time with:  ./install.sh --reselect-main-display"
fi

# =============================================================================
# 8. Wallpapers -> ~/Pictures/Wallpapers/  (a sensible default matugen source)
#    Never clobbers existing wallpapers: same-named files already there are
#    skipped with a warning, same pattern as the other copy steps.
# =============================================================================
stage "8/18  Installing default wallpapers"
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
stage "9/18  Layering GTK theming (gtk-3.0 / gtk-4.0)"
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
stage "10/18  Checking DMS popupTransparency"
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
# 10b. DMS keybindsFloatingWindow = true  (SUPER+/ cheatsheet readability)
# =============================================================================
# The cheatsheet's description column truncates almost every entry, and this is
# the only lever that exists for it. There is NO DMS setting for column width,
# description length, or wrapping -- Modals/KeybindsContent.qml hardcodes all
# three:
#
#     numColumns: Math.max(1, Math.min(3, Math.floor(width / 350)))
#     ...
#     anchors.leftMargin: 170     // fixed gutter for the key column
#     elide: Text.ElideRight
#     wrapMode: Text.NoWrap
#
# The overlay is capped at Math.min(screenWidth * 0.92, 1200), so it always
# lands on 3 columns of ~392px, leaving ~222px per description -- about 35
# characters at fontSizeSmall. 61% of DankMango's bind descriptions are longer
# than that, hence "almost every one is cut off".
#
# keybindsFloatingWindow swaps that fixed-width overlay for a real window, which
# a tiling monitor gives the full screen width. At 2500px the same 3 columns are
# ~825px each, ~655px per description, and nothing truncates. Verified.
#
# The trade-off, stated plainly: the cheatsheet becomes a WINDOW rather than an
# overlay, so it takes a slot in the tiling layout instead of floating above it.
# On a float-mode monitor it opens at its implicit 1000px, which is only 2
# columns and still clips the longest descriptions -- a windowrule can't fix
# that either, since mango discards width/height on open_as_floating windows
# (see the note by the Rules block in config.conf). Prefer the overlay? One line:
#     dms ipc call settings set keybindsFloatingWindow false
stage "10b/18 Checking DMS keybinds cheatsheet width"
if [ -f "$SETTINGS" ] && grep -q '"keybindsFloatingWindow"[[:space:]]*:[[:space:]]*true' "$SETTINGS"; then
    ok "keybindsFloatingWindow already true — no change needed"
elif [ -f "$SETTINGS" ] && have jq; then
    tmp="$(mktemp)"
    if jq '.keybindsFloatingWindow = true' "$SETTINGS" > "$tmp" && [ -s "$tmp" ]; then
        cp -a "$SETTINGS" "$SETTINGS.bak-$STAMP"; mv "$tmp" "$SETTINGS"
        ok "set keybindsFloatingWindow = true (SUPER+/ descriptions stop truncating)"
        manifest_add_backup "$SETTINGS" "$SETTINGS.bak-$STAMP" user "$CUR_STAGE"
        manifest_add_change config-edit "$CUR_STAGE" "settings.json:keybindsFloatingWindow" \
            "$(jq -nc --arg f "$SETTINGS" '{file:$f, key:"keybindsFloatingWindow", value:true}')" \
            "restore $SETTINGS from its .bak-*"
    else
        rm -f "$tmp"; warn "couldn't edit keybindsFloatingWindow with jq — set it by hand in settings.json."
    fi
else
    warn "settings.json missing or jq unavailable — couldn't verify keybindsFloatingWindow."
fi

# =============================================================================
# 11. Alacritty config (CachyOS's default has a known duplicate-key error)
# =============================================================================
stage "11/18  Installing Alacritty config"
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
stage "12/18  Power profile (optional)"
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
stage "13/18  easyeffects autostart (optional)"
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
stage "14/18  Installing DMS plugins"
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
stage "15/18  Combined audio OSD patch (optional)"
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
stage "16/18  Seeding taskbar pins, restarting DankMaterialShell + seeding theme"

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
    # Pin ONLY apps whose package is actually installed RIGHT NOW (PIN_PKG maps pin ID ->
    # pacman target). Deliberately a live check rather than remembering stage 3's exit
    # status: correct under every path -- prompt declined, whole transaction failed, a
    # PARTIAL failure where some of the set installed, or a package removed later -- with
    # no success/fail flag threaded across the ~500 lines between the two stages. Seeding
    # blind is what put dead icons on a fresh laptop install: the standard-apps prompt was
    # accepted, the install transaction failed on a mirror hiccup, stage 3 warned (and the
    # warning scrolled past), and these pins were written anyway.
    pins_present=(); pins_absent=()
    for a in "${SEED_PINNED_APPS[@]}"; do
        if pacman -Qi "${PIN_PKG[$a]:-$a}" >/dev/null 2>&1; then pins_present+=("$a")
        else pins_absent+=("$a"); fi
    done
    # Guard the empty case: `printf '%s\n'` with no args still emits one blank line, which
    # would seed a bogus [""] pin rather than an empty list.
    if [ "${#pins_present[@]}" -gt 0 ]; then
        pins_json="$(printf '%s\n' "${pins_present[@]}" | jq -R . | jq -s .)"
    else
        pins_json='[]'
    fi
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
        if [ "${#pins_present[@]}" -gt 0 ]; then
            ok "seeded taskbar/dock pins (installed apps only): ${pins_present[*]}"
        else
            warn "no pins seeded — none of the pinned apps are installed on this system."
        fi
        if [ "${#pins_absent[@]}" -gt 0 ]; then
            warn "NOT pinned, package not installed: ${pins_absent[*]}"
            warn "  install them and pin by hand — this seed only fills an EMPTY pin list,"
            warn "  so re-running install.sh will not add them once the list has anything in it."
        fi
        [ -n "$wp" ] && ok "seeded default wallpaper into session.json (DMS themes on first login: $SEED_WALLPAPER)"
        manifest_add_change session-seed "$CUR_STAGE" "session.json:seed" \
            "$(jq -nc --arg f "$sess" --argjson pins "$pins_json" \
                '{file:$f, keysSeeded:["barPinnedApps","pinnedApps","wallpaperPath"], pinsSeeded:$pins,
                  note:"only set when empty/absent; pins filtered to packages actually installed"}')" \
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

# Push that freshly-generated palette to the LOGIN screen too. This has to happen
# here, not in stage 5b: the theme install runs before stage 7 deploys the script and
# before matugen has ever produced ~/.cache/DankMaterialShell/dms-colors.json, so at
# that point there is simply no palette to sync. Best-effort and silent-on-skip by
# design — no theme installed, no colors json yet, or no imagemagick all exit 0.
SDDM_SYNC="$HOME/.config/mango/scripts/sddm-palette-sync.sh"
if [ -x "$SDDM_SYNC" ]; then
    if "$SDDM_SYNC"; then
        ok "login-screen palette synced from the current wallpaper"
    else
        info "login-screen palette not synced yet — it retries on the next wallpaper change."
    fi
    info "(from now on wallpaper-border-reload.sh re-runs this on every wallpaper change.)"
fi

# =============================================================================
# 17. Zen browser theming (userChrome.css bridge)
# =============================================================================
# Runs LAST-but-one, deliberately: it wants stage 3's zen-browser-bin install and
# stage 16's matugen run (which generates the zen.css it imports) to have happened.
#
# KNOWN ORDERING LIMITATION — read this before assuming a fresh install is covered:
# Zen creates its profile directory on FIRST LAUNCH, not at package install. On a
# fresh machine this stage therefore runs before any profile exists, finds nothing
# to write to, and says so. There is no clean way around it from inside the
# installer: we are not going to launch a browser on the user's behalf mid-install,
# and fabricating a profile directory by hand risks colliding with the one Zen
# generates itself. So on a fresh install this stage WARNS and defers; the user
# launches Zen once and re-runs install.sh (or update.sh, which carries the same
# step as a migration). On any machine where Zen has been used at all — which is
# every existing-install case — it applies immediately.
stage "17/18  Zen browser theming"
zen_apply_theming || true

# =============================================================================
# 18. Done — next steps
# =============================================================================
stage "18/18  Done"
# Mark the manifest complete (a partial/crashed run leaves status "in-progress").
manifest_finalize
# Surface failed installs HERE, at the end, where they can't scroll past unseen — a
# mid-install warning is exactly what got missed on the laptop that shipped dead pins.
if have jq && [ -f "$MANIFEST" ]; then
    failed="$(jq -r '[ (.packagesFailed // [])[] | .name ] | join(" ")' "$MANIFEST" 2>/dev/null)"
    if [ -n "${failed:-}" ]; then
        echo
        warn "THESE PACKAGES FAILED TO INSTALL: $failed"
        warn "  Nothing was pinned for them, and features needing them won't work."
        warn "  Retry with:  $AUR -S $failed"
        warn "  Then re-run this installer, or pin them by hand in the taskbar."
    fi
fi
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
