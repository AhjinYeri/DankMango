# Credits

DankMango is a personal desktop configuration built on top of the work of others. Everything not written by me is credited here.

## Core projects

- **[MangoWM](https://github.com/mangowm/mango)** — the Wayland compositor this whole setup is built around.
- **[DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)** — the bar/shell that powers theming, widgets, and the plugin system DankMango's custom plugins hook into.
- **[matugen](https://github.com/InioX/matugen)** by InioX — the wallpaper-driven Material You color generation engine behind DankMango's dynamic theming.
- **[SDDM](https://github.com/sddm/sddm)** — the display manager DankMango's own login theme is written against. The theme uses SDDM's Qt6 greeter and its two-file (`theme.conf` + `theme.conf.user`) config layering; SDDM itself ships with CachyOS and is not installed by DankMango.

## Ideas borrowed

- **[ML4W dotfiles](https://github.com/mylinuxforwork/dotfiles)** by Stephan Raabe — DankMango's **desktop presets** (`config/mango/presets/`, `set-preset.sh`, the Presets launcher plugin) are inspired by ML4W's "Configuration Variations": the idea of swapping a whole bundle of settings at once by repointing a **native include line** at a different config fragment, rather than rewriting the main config in place. That approach is what makes switching reversible with nothing to clean up, and it's a genuinely good idea I would not have arrived at on my own.

  **Nothing is ported.** No ML4W code, file layout, or naming was copied — DankMango's implementation is its own (a symlink swapped atomically behind MangoWM's `source-optional=`, wired into this project's existing manifest/backup/dry-run lifecycle). The credit is for the concept, and it's here because a good idea deserves naming whether or not any of its code came with it.

- **[pywal](https://github.com/dylanaraps/pywal)** by Dylan Araps and **[wallust](https://codeberg.org/explosion-mental/wallust)** by explosion-mental — Ripe Chroma's **Vibrant** mode is inspired by their direct-extraction philosophy: take the colours that are actually in the wallpaper and keep them saturated, rather than treating the image as a seed for a tonal system that then decides what the colours *should* be. Material You's approach is the opposite, and for a lot of wallpapers pywal's answer is simply the one people want.

  **Nothing is ported.** No pywal or wallust code, palette maths, or output format was copied — Vibrant is DankMango's own generator run with different parameters (it pushes chroma toward the sRGB gamut cusp and accepts more lightness drift to get there). The credit is for the philosophy, which is theirs and which the Material-derived default genuinely does not serve.

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

## Ripe Chroma (the colour engine)

`tools/ripe-chroma/` is **Ripe Chroma**, DankMango's own wallpaper-to-palette generator, written from scratch for this project. It exists because Material You's tonal system picks a lightness per role first and asks for the seed hue at that lightness second — and sRGB cannot make a light, saturated red, so a red wallpaper reliably produces a salmon-pink accent no matter which Matugen scheme is selected (tested against all of them, including `fidelity` and `content`). The engine inverts that priority: hue is held exactly, and the target lightness is what gives way.

The maths it does **not** do itself:

- **[palette](https://github.com/Ogeon/palette)** by Ogeon — all Oklab/OKLCH ↔ sRGB colour-space conversion. Note for anyone touching this code: palette's `into_color()` *clamps* into the target type's range, so out-of-gamut colours come back looking valid; the gamut boundary search depends on `into_color_unclamped()` to tell the truth.
- **[kmeans-colors](https://github.com/okaneco/kmeans-colors)** by okaneco — the k-means clustering that reduces a wallpaper to its handful of real colours. The crate ships `Calculate` implementations for palette's `Lab` and `Rgb` only, so the Oklab point type in `src/extract.rs` is DankMango's, written against the crate's own documented guidance to use the `Lab` implementation as the template for other colour spaces. The clustering algorithm itself is okaneco's.

Everything else — seed selection, the lightness/chroma trade-off, the role targets, the three modes — is original to this project. The Vibrant mode's inspiration is credited above.

## Legacy assets

Superseded, but still in the repository:

- **[sddm-astronaut-theme](https://github.com/Keyitdev/sddm-astronaut-theme)** by Keyitdev — served DankMango's login screen before v2 grew its own theme. Nothing installs or uses it any more, but `system/sddm/sddm-astronaut-japanese/` is kept on purpose so `update.sh` doesn't offer to delete the config that v1.x installs are still logging in through (see the note at `lib/common.sh:499`). That directory contains `japanese_aesthetic_dark.png`, a color-inverted edit of the theme's "Japanese aesthetic" wallpaper. As a modified GPLv3+ asset it stays under **GPLv3+**, and this notice stays with it for as long as the file is distributed.

## AI assistance disclosure

Parts of this repository's code — plugin implementations and install script logic in particular — were built with AI assistance (Claude). The architecture, design decisions, testing and debugging are my own work. I'm noting the AI involvement because it's the honest thing to do, not to talk down the effort that went into building and validating this.

## License

See [`LICENSE`](LICENSE) for DankMango's own code. Third-party projects and assets listed above retain their own licenses as linked.
