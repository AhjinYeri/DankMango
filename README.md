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
- **Loupe image viewer** — GNOME's viewer, set up as the default for common image types (a base install ships none, so photos don't open at all until something claims them)
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
   - Install required packages (`nemo`, `matugen`, `keyd`, `loupe`, `cosmic-icon-theme`, `cava`, `zen-browser-bin`, and a few others — the full lists are `REPO_PKGS` / `AUR_PKGS` in `lib/common.sh`)
   - Ask before installing the **standard taskbar apps** (Spotify, Steam, Discord). Declining is safe — only apps that are actually installed get pinned, so you never end up with dead icons
   - Set Nemo as your default file manager, and Loupe as your default image viewer
   - Drop in a small Nemo `.desktop` override so its icon is a folder rather than the filing cabinet the Cosmic icon theme draws for the generic `system-file-manager` name
   - Copy system-level configs (keyd, SDDM theme) into place
   - Install the DMS plugins and register them
   - Generate your per-monitor tagrules (see step 5) and seed your taskbar pins + default wallpaper
   - Ask before pinning your power profile to performance (desktop only — skip this on a laptop)
   - Ask before autostarting easyeffects with your session
   - Ask before applying the **combined audio OSD patch** — an opt-in tweak that merges the device-name and volume popups into a single OSD when you switch audio output. Unlike the rest of the install this edits a DMS *package-owned* core file, so it's your call; it's self-healing (the health check re-applies it after DMS updates) and backs the original file up first. Applying it later by hand: `~/.config/mango/scripts/apply-combined-osd-patch.sh`
   - Restart DMS to apply everything

4. **Log out and back in** once the script finishes — some pieces (like the `keyd` launcher) only take effect on a fresh login, not a DMS reload.

5. **Per-monitor tiling/floating — set up automatically.** `mango` needs your monitors' *literal* output names for per-monitor tile/float, and can't auto-detect them from the config. The installer handles this for you: it runs `config/mango/scripts/generate-tagrules.sh` (installed to `~/.config/mango/scripts/`), which queries your connected outputs (`mmsg get all-monitors`) and writes one tile-mode block per monitor into `~/.config/mango/dms/tagrules.conf` (sourced by `config.conf`). Every monitor starts in **tile** mode; flip one to **float** anytime with the **Monitor Mode** bar button — no config editing.

   If you later dock a laptop or add/remove a monitor, just re-run it and reload (**Super+r**):
   ```bash
   ~/.config/mango/scripts/generate-tagrules.sh
   ```
   For unusual setups or hand-tuning a specific monitor, `config.conf` keeps a commented **"Per-monitor window mode"** fallback template you can use instead.

6. **Verify everything applied** by running the health check:
   ```bash
   ~/.config/mango/scripts/post-update-health.sh
   ```
   It checks that the theming/border colour chain, tagrules, and other moving parts are wired up correctly, and points you at anything that didn't take. Run it any time after an install or a system update.

## Updating

Once DankMango is installed, you don't re-run `install.sh` to pick up repo changes — `update.sh` applies **only what changed** since your last run:

```bash
git pull
./update.sh --dry-run   # show the full plan, change nothing — run this first
./update.sh
```

It works out the delta from the commit recorded in your install manifest to the repo's current `HEAD`, then installs newly-added packages, re-copies changed config/script files (backing up first), retires files the repo has dropped, and runs any pending migrations for live state that a plain file copy can't express (`settings.json` / `session.json`). The new commit is stamped into the manifest only after everything succeeds.

It won't clobber a file you hand-edited since installing without asking first. If it can't safely compute the delta — an interrupted previous run, rebased history, a dirty tree — it says so and points you back at `install.sh` rather than guessing.

## Uninstalling

`install.sh` records everything it does — packages it installed (as opposed to ones you already had), files it backed up, and system-level changes — in an install manifest at `~/.local/state/dankmango/manifest.json`. `uninstall.sh` reads that manifest and walks the install back, so you don't have to hunt down every file and setting by hand.

**Always look before you leap.** A dry run prints exactly what would happen and changes nothing:

```bash
./uninstall.sh --dry-run
```

When you're happy with the plan:

```bash
./uninstall.sh
```

It is conservative by design:

- **Nothing is ever deleted.** Everything it removes is *moved* into a rescue dir (`~/.local/state/dankmango/uninstall-<timestamp>/`) that mirrors the original paths, so any step can be undone by hand. Delete that dir yourself once you're happy.
- **Your files come back.** Anything the installer overwrote is restored from the backup it made first.
- **Packages are opt-in.** It offers to remove only packages *it* installed, grouped by category, defaulting to keeping them — anything you already had is never touched, and it won't remove a package something else still depends on.
- **It asks before anything destructive**, and every prompt defaults to No.
- **It won't clobber state you've changed since installing.** For example, if your taskbar pins no longer match what the installer seeded, it leaves them alone and tells you so rather than wiping pins you added yourself.

Anything it can't safely reverse on its own (a default-application association, say) is listed at the end as an explicit manual step, alongside the reversal hint the installer recorded at the time. If the manifest is missing, older, or incomplete, it warns about what it couldn't determine instead of guessing.

## Wallpapers

A handful of cyberpunk/neon wallpapers are bundled, all sourced free-to-use and credited in [`wallpapers/CREDITS.md`](wallpapers/CREDITS.md). Swap in your own any time — the theming system will follow whatever wallpaper is active.

## Credits

This project stands on the work of several others — full list in [`CREDITS.md`](CREDITS.md), including the MangoWM and DankMaterialShell projects, the SDDM astronaut theme author, matugen, and the wallpaper artists/sources.

**On AI assistance:** parts of this repo's code were built with AI assistance — see the [full disclosure in `CREDITS.md`](CREDITS.md#ai-assistance-disclosure).

## Known issues / in progress

See open issues on this repo for current known bugs and planned improvements.

## License

See [`LICENSE`](LICENSE). Bundled third-party assets (wallpapers, SDDM theme) retain their own licenses/attribution as noted in `CREDITS.md`.
