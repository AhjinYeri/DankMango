# DankMango

My MangoWM + DankMaterialShell setup for CachyOS, packaged up so other people can use it too. Wallpaper-based theming, a Windows-style Super-tap launcher, per-monitor tiling/floating, a few custom bar plugins I built along the way.

**Dank** = DankMaterialShell, **Mango** = MangoWM. Not the most creative name, but it does the job.

> Needs **CachyOS + MangoWM**. Won't work on Hyprland, Sway, GNOME, or anything non-Arch — the installer's built specifically around this stack.

## Install

> **Heads up if you've already got a MangoWM/DMS setup you like.** This replaces your config wholesale — it's not a gentle merge on top of what you've already got. Your setup will visibly change the second you run it.
>
> Everything it overwrites gets backed up automatically, and `./uninstall.sh` can walk it back, so it *is* reversible. But if there's stuff in there you can't afford to lose, back up your own dotfiles independently first as well — a git commit, a snapper snapshot, whatever you'd normally do. Don't rely solely on DankMango's backups.
>
> The installer asks you to type a confirmation before it touches anything, so you get one more chance to bail.

```bash
git clone https://github.com/AhjinYeri/DankMango.git
cd DankMango
./install.sh
```

It'll ask you a few yes/no questions along the way (extra apps, power profile, that sort of thing) — just answer as you go, nothing's going to break if you say no to something.

Once it's done:

1. **Log out and back in.** A couple of things (the launcher especially) won't kick in until a fresh login.
2. Run the health check to make sure everything actually took:
   ```bash
   ~/.config/mango/scripts/post-update-health.sh
   ```

That's genuinely it. Everything install.sh does, how the tagrules get set up, updating, uninstalling — it's all written up properly in **[docs/GUIDE.md](docs/GUIDE.md)** if you want the full picture or something needs troubleshooting.

## What you're actually getting

- Wallpaper-driven theming (change your wallpaper, everything recolors — borders, GTK, terminal, the bar)
- Tap Super to open the launcher, no click needed
- Per-monitor tile/float, switchable from the bar
- Custom alt-tab switcher, output switcher, and monitor mode plugins
- Nemo and Zen themed to match
- Loupe set as your image viewer (a fresh CachyOS install has nothing that opens photos)
- SDDM login theme
- A health-check script so you know when something's actually broken

## Updating / uninstalling

```bash
./update.sh --dry-run     # see what it'd do first
./update.sh                # then actually do it
```

```bash
./uninstall.sh --dry-run   # same idea
./uninstall.sh
```

Both are safe by default — nothing gets deleted, everything's backed up, and every prompt defaults to "no." If you've hand-edited any of the configs DankMango installed, update won't quietly stomp them: it stops and asks you per file whether to keep yours, take the new one, or show you the diff — and keeping yours is the default. Full details in [docs/GUIDE.md](docs/GUIDE.md).

## Wallpapers

A handful of neon/cyberpunk ones ship with it, all free to use — sources are in [wallpapers/CREDITS.md](wallpapers/CREDITS.md). Swap your own in whenever, theming just follows along.

## Credits & license

Full credits (MangoWM, DMS, matugen, the SDDM theme, everyone this is built on) are in [CREDITS.md](CREDITS.md). Some of this was built with AI assistance — details on that are in there too.

License is [MIT](LICENSE). Bundled wallpapers/theme assets keep their own licenses, noted in CREDITS.md.

## Issues

Check the [Issues tab](../../issues) for known bugs and what's still being worked on.
