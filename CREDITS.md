# Credits

DankMango is a personal desktop configuration built on top of the work of others. Everything not written by me is credited here.

## Core projects

- **[MangoWM](https://github.com/mangowm/mango)** — the Wayland compositor this whole setup is built around.
- **[DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)** — the bar/shell that powers theming, widgets, and the plugin system DankMango's custom plugins hook into.
- **[matugen](https://github.com/InioX/matugen)** by InioX — the wallpaper-driven Material You color generation engine behind DankMango's dynamic theming.
- **[SDDM](https://github.com/sddm/sddm)** — the display manager DankMango's own login theme is written against. The theme uses SDDM's Qt6 greeter and its two-file (`theme.conf` + `theme.conf.user`) config layering; SDDM itself ships with CachyOS and is not installed by DankMango.

## Tools & packages

DankMango's install script sets up a number of third-party tools it didn't write, including:

- **Nemo** file manager
- **Zen Browser**
- **[Loupe](https://apps.gnome.org/Loupe/)** — GNOME's image viewer, shipped as DankMango's default for common image types
- **[Celluloid](https://celluloid-player.github.io/)** — GTK front-end to mpv, shipped as DankMango's default for common video types
- **keyd** (for the Windows-style Super-tap launcher)
- **xdg-desktop-portal-wlr**
- **[Cosmic icon theme](https://github.com/pop-os/cosmic-icon-theme)** by System76 — shipped as DankMango's default icon theme
- **[cava](https://github.com/karlstav/cava)** by karlstav — the audio-visualiser backend behind DMS's Media-widget waveform
- **[ImageMagick](https://imagemagick.org)** — downscales and re-encodes the wallpaper copy the login screen shows, and measures its brightness so the theme can dim behind the text

Full package lists are the `REPO_PKGS` / `AUR_PKGS` / `STANDARD_APPS` arrays in `lib/common.sh`.

## The login theme

DankMango's SDDM theme (`system/sddm/themes/dankmango/`) is written from scratch for this project — the QML, the layout, and the palette wiring are all original.

It deliberately has **no font or icon-set dependency**. No font family is named anywhere in the theme; it renders in whatever the system default is. The power and chevron icons are drawn as Canvas paths rather than set as glyphs, specifically so the login screen can't render a tofu box on a machine whose font fallback differs — see the header comments in `Components/PowerIcon.qml` and `Components/Chevron.qml`.

The background it shows is **your own current wallpaper**, copied across the privilege boundary by `sddm-palette-sync.sh` — the theme ships no wallpaper of its own. The bundled wallpapers are credited in [`wallpapers/CREDITS.md`](wallpapers/CREDITS.md). Its colors are Material 3 roles produced by matugen (credited above); nothing else is drawn from.

## Legacy assets

Superseded, but still in the repository:

- **[sddm-astronaut-theme](https://github.com/Keyitdev/sddm-astronaut-theme)** by Keyitdev — served DankMango's login screen before v2 grew its own theme. Nothing installs or uses it any more, but `system/sddm/sddm-astronaut-japanese/` is kept on purpose so `update.sh` doesn't offer to delete the config that v1.x installs are still logging in through (see the note at `lib/common.sh:499`). That directory contains `japanese_aesthetic_dark.png`, a color-inverted edit of the theme's "Japanese aesthetic" wallpaper. As a modified GPLv3+ asset it stays under **GPLv3+**, and this notice stays with it for as long as the file is distributed.

## AI assistance disclosure

Parts of this repository's code — plugin implementations and install script logic in particular — were built with AI assistance (Claude). The architecture, design decisions, testing and debugging are my own work. I'm noting the AI involvement because it's the honest thing to do, not to talk down the effort that went into building and validating this.

## License

See [`LICENSE`](LICENSE) for DankMango's own code. Third-party projects and assets listed above retain their own licenses as linked.
