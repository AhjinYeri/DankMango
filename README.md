# DankMango

A MangoWM + DankMaterialShell (DMS) desktop setup for CachyOS — wallpaper-driven theming, a Windows-style Super-tap launcher, per-monitor tiling/floating, and a handful of custom DMS plugins, all wired together and (hopefully) easy to adopt.

**Dank** = DankMaterialShell, **Mango** = MangoWM.

## Requirements

This is built for and tested on:

- **CachyOS**
- **MangoWM** (`mangowm` package)
- **DankMaterialShell** (`dms-shell` package)

It is **not** cross-distro and **not** cross-desktop-environment. It won't work as-is on Hyprland, Sway, GNOME, or non-Arch distros — the install script assumes a CachyOS + MangoWM base. If you're on something else, this repo can still be a reference for how the pieces fit together, but the installer will not do the right thing for you.

It should work on any monitor count or resolution — nothing here is hardcoded to specific hardware.

## What's included

- **Dynamic theming** — matugen recolors window borders, GTK, Qt, your terminal, and DMS itself based on your current wallpaper
- **Windows-style launcher** — tap `Super` alone to open the app launcher, via `keyd`
- **Per-monitor tiling/floating** — native `mango` tag rules, works with any drag direction, reactive mode switching
- **Monitor Mode plugin** — a custom DMS plugin exposing per-monitor tiling controls in the bar
- **Output/Sound switcher plugin** — a custom DMS plugin for switching audio outputs, with auto-detected device names
- **Alt-tab switcher** — custom icon+title card switcher, frosted/transparent, matugen-themed
- **Themed Nemo & Zen browser** — frosted transparency, colors follow your wallpaper
- **SDDM astronaut theme** — 12-hour clock, custom background
- **Post-update health check** — a script that verifies plugins/theming/borders are intact after a `mango` or DMS update, and tells you what broke

## Installation

1. Make sure you're on a fresh (or existing) **CachyOS + MangoWM** install.
2. Clone this repo:
   ```bash
   git clone https://github.com/AhjinYeri/DankMango.git
   cd DankMango
   ```
3. Run the installer:
   ```bash
   ./install.sh
   ```
   The script will:
   - Check for an AUR helper (install one if missing)
   - Install required packages (`nemo`, `matugen`, `zen-browser`, `keyd`, and a few others — full list in `install.sh`)
   - Set Nemo as your default file manager
   - Copy system-level configs (keyd, SDDM theme) into place
   - Install the DMS plugins and register them
   - Ask before pinning your power profile to performance (desktop only — skip this on a laptop)
   - Ask before applying the **combined audio OSD patch** — an opt-in tweak that merges the device-name and volume popups into a single OSD when you switch audio output. Unlike the rest of the install this edits a DMS *package-owned* core file, so it's your call; it's self-healing (the health check re-applies it after DMS updates) and backs the original file up first. Applying it later by hand: `~/.config/mango/scripts/apply-combined-osd-patch.sh`
   - Restart DMS to apply everything

4. **Log out and back in** once the script finishes — some pieces (like the `keyd` launcher) only take effect on a fresh login, not a DMS reload.

5. **Verify everything applied** by running the health check:
   ```bash
   ~/.config/mango/scripts/post-update-health.sh
   ```
   It checks that the theming/border colour chain, tagrules, and other moving parts are wired up correctly, and points you at anything that didn't take. Run it any time after an install or a system update.

## Wallpapers

A handful of cyberpunk/neon wallpapers are bundled, all sourced free-to-use and credited in [`wallpapers/CREDITS.md`](wallpapers/CREDITS.md). Swap in your own any time — the theming system will follow whatever wallpaper is active.

## Credits

This project stands on the work of several others — full list in [`CREDITS.md`](CREDITS.md), including the MangoWM and DankMaterialShell projects, the SDDM astronaut theme author, matugen, and the wallpaper artists/sources.

**On AI assistance:** parts of this repo's code (plugin implementations, install script logic) were built with AI assistance. The architecture, design decisions, testing, and troubleshooting are my own — I'm disclosing the AI involvement because I think that's the honest thing to do, not because the ideas or the debugging weren't mine.

## Known issues / in progress

See open issues on this repo for current known bugs and planned improvements.

## License

See [`LICENSE`](LICENSE). Bundled third-party assets (wallpapers, SDDM theme) retain their own licenses/attribution as noted in `CREDITS.md`.
