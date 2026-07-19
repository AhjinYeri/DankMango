# DankMango — full guide

The stuff that got cut from the main README to keep it from being a wall of text. If you just want it running, the [README](../README.md) has you covered — come back here if something needs digging into.

## What install.sh actually does

- Checks you've got an AUR helper, installs one if not
- Installs the required packages (`nemo`, `matugen`, `keyd`, `loupe`, `cosmic-icon-theme`, `cava`, `zen-browser-bin`, and a few more — see `REPO_PKGS` / `AUR_PKGS` in `lib/common.sh` for the exact list)
- Asks if you want the standard taskbar apps (Spotify, Steam, Discord). Say no and nothing bad happens — it only pins apps that actually got installed, so you won't end up with dead icons either way
- Sets Nemo as your default file manager and Loupe as your default image viewer
- Fixes Nemo's icon — Cosmic (the icon theme) draws a filing cabinet for generic file managers instead of a folder, so there's a small override that fixes that
- Copies the system-level stuff into place (keyd, the SDDM theme)
- Installs and registers the DMS plugins
- Sets up your per-monitor tagrules (more on this below) and seeds your taskbar pins + a default wallpaper
- Asks about pinning your power profile to performance (desktop only — it'll skip this on a laptop)
- Asks about autostarting easyeffects
- Asks about the combined audio OSD patch — this one's a bit different since it edits a file DMS itself owns, not something DankMango installed. It's opt-in for that reason, and it heals itself automatically if a DMS update wipes it. You can apply it later by hand too: `~/.config/mango/scripts/apply-combined-osd-patch.sh`
- Restarts DMS so all of it takes effect

## Per-monitor tiling/floating

mango needs to know your monitors' actual output names to handle per-monitor tile/float — it can't work that out on its own from the config. The installer sorts this for you automatically: it runs `generate-tagrules.sh`, which asks mango what's connected (`mmsg get all-monitors`) and writes a tile-mode block for each monitor into `~/.config/mango/dms/tagrules.conf`.

Everything starts in tile mode. Flip a monitor to float from the bar (Monitor Mode button) whenever you want — no config editing needed.

If you add or remove a monitor later (docking a laptop, say), just re-run it and reload:

```bash
~/.config/mango/scripts/generate-tagrules.sh
```
then `Super+r`.

If you've got a weird setup and want to hand-write rules for a specific monitor, `config.conf` has a commented template you can use instead.

## Updating

```bash
git pull
./update.sh --dry-run
./update.sh
```

`update.sh` only touches what's actually changed since you last updated — it's not re-running the whole installer. It works this out from the commit recorded in your install manifest, compares it to the repo's current state, and from there:

- installs any new packages
- re-copies any config/script files that changed (backing up first)
- removes anything the repo itself has dropped
- runs any migrations needed for stuff like `settings.json` or `session.json` — things a plain file copy can't handle properly since they hold your own live settings

It won't overwrite something you've hand-edited since installing without checking with you first. And if it can't work out the delta safely — say your last update got interrupted, or your git history's been rebased, or you've got uncommitted changes sitting around — it'll just tell you and point you at `install.sh` instead of guessing.

## What to do when the health check fails

After an update, run `~/.config/mango/scripts/post-update-health.sh`. It checks everything DankMango customises that a MangoWM or DMS update can quietly break — per-monitor tagrules, the bar plugins, the combined audio OSD patch, the border colour chain — and prints a PASS or FAIL line for each, plus which versions changed since you last ran it.

If anything fails you get a numbered list of problems, and each one comes with a plain-English walkthrough: the exact commands to type, what each does, and why you're running it. It assumes no prior Linux knowledge, and following the steps as written is the entire fix — there's no AI tooling involved. A ready-made Claude Code prompt gets printed underneath as well for anyone who happens to use it, but it's strictly optional and safe to ignore. A few failures are expected and take a single command (the audio OSD patch gets wiped by every DMS update and just needs re-applying); one or two genuinely can't be fixed by hand, and those say so plainly instead of sending you round in circles.

## Uninstalling

```bash
./uninstall.sh --dry-run
./uninstall.sh
```

Everything install.sh does gets logged to a manifest (`~/.local/state/dankmango/manifest.json`) — what packages it installed, what files it backed up, what system stuff it changed. `uninstall.sh` reads that and walks it all back for you.

A few things about how it behaves:

- **Nothing gets deleted.** Anything it removes gets moved into a rescue folder (`~/.local/state/dankmango/uninstall-<timestamp>/`) that mirrors where everything came from. You can put anything back by hand, and once you're happy, delete the folder yourself.
- **Your original files come back** — whatever DankMango overwrote gets restored from its backup.
- **Package removal is opt-in.** It'll only ever offer to remove packages it installed itself, grouped up, and defaults to keeping them. Anything you already had stays completely untouched, and it won't remove something another package still needs.
- **Every prompt defaults to no.** Nothing destructive happens without you saying yes.
- **It won't clobber your own changes.** If your taskbar pins don't match what DankMango originally set, for example, it'll leave them alone and just tell you.

Anything it genuinely can't undo on its own (like a default-app association) gets listed at the end as something to fix manually, along with a hint on how. If the manifest's missing or looks incomplete, it'll say so rather than guess at what to do.
