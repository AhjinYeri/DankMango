# Credits

DankMango is a personal desktop configuration built on top of the work of others. Everything not written by me is credited here.

## Core projects

- **[MangoWM](https://github.com/mangowm/mango)** — the Wayland compositor this whole setup is built around.
- **[DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)** — the bar/shell that powers theming, widgets, and the plugin system DankMango's custom plugins hook into.
- **[matugen](https://github.com/InioX/matugen)** by InioX — the wallpaper-driven Material You color generation engine behind DankMango's dynamic theming.
- **[sddm-astronaut-theme](https://github.com/Keyitdev/sddm-astronaut-theme)** by Keyitdev — the SDDM login theme DankMango configures (Japanese aesthetic variant, 12-hour clock). The SDDM background used is a modified (color-inverted) version of this theme's default wallpaper for that variant — see [Wallpapers](#wallpapers) below.

## Wallpapers

All desktop wallpapers are AI-generated images from StockCake, released public domain / CC0 (attribution not legally required, credited here anyway):

- [Neon Cityscape View](https://stockcake.com/i/neon-cityscape-view_1120271_392833) — StockCake
- [Illuminated Urban Night](https://stockcake.com/i/illuminated-urban-night_1383839_1064564) — StockCake
- [Futuristic Cityscape Sunset](https://stockcake.com/i/futuristic-cityscape-sunset_1090536_1095837) — StockCake
- [Neon Cyberpunk Nights](https://stockcake.com/i/neon-cyberpunk-nights_4718630_2012212) — StockCake
- [Futuristic Cityscape Rain](https://stockcake.com/i/futuristic-cityscape-rain_655419_330997) — StockCake

Images were downloaded at StockCake's free tier and upscaled locally to 2912×1632 using [Upscayl](https://www.upscayl.org), an open-source offline AI upscaler.

The SDDM background is a color-inverted edit of the default wallpaper bundled with the sddm-astronaut-theme "Japanese aesthetic" variant (see [Core projects](#core-projects) above). As a modified version of a GPLv3+-licensed asset, this file is distributed under the same license.

## Tools & packages

DankMango's install script sets up several third-party tools it doesn't author, including but not limited to:

- **Nemo** file manager
- **Zen Browser**
- **keyd** (for the Windows-style Super-tap launcher)
- **xdg-desktop-portal-wlr**

Full package list is in `install.sh`.

## AI assistance disclosure

Parts of this repository's code — plugin implementations and install script logic in particular — were built with AI assistance (Claude). The architecture, design decisions, testing, and debugging are my own work; I'm noting the AI involvement for transparency, not to diminish the effort that went into building and validating this setup.

## License

See [`LICENSE`](LICENSE) for DankMango's own code. Third-party projects and assets listed above retain their own licenses as linked.
