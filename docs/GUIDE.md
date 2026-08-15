# DankMango — full guide

The stuff that got cut from the main README to keep it from being a wall of text. If you just want it running, the [README](../README.md) has you covered — come back here if something needs digging into.

## What install.sh actually does

- Checks you've got an AUR helper, installs one if not
- Installs the required packages (`nemo`, `matugen`, `keyd`, `loupe`, `celluloid`, `cosmic-icon-theme`, `cava`, `zen-browser-bin`, and a few more — `REPO_PKGS` / `AUR_PKGS` in `lib/common.sh` is the exact list)
- Asks if you want the standard taskbar apps (Spotify, Steam, Discord). Say no and nothing bad happens — it only pins apps that actually got installed, so you won't end up with dead icons either way
- Sets Nemo as your default file manager, Loupe as your image viewer, and Celluloid as your video player
- Fixes Nemo's icon — Cosmic (the icon theme) draws a filing cabinet for generic file managers instead of a folder, so there's a small override for that
- Seeds Nemo's sidebar with Documents / Pictures / Music / Videos / Downloads under a "Bookmarks" heading, so you get Windows' Quick Access grouping out of the box. Folders you don't have are skipped, and if you already have bookmarks it leaves them alone — this only ever fills in an empty list, including on updates
- Starts that sidebar with My Computer and Bookmarks open and Devices and Network folded away, so it opens on the things you actually click instead of a wall of entries. Each section is remembered separately, and once you've expanded or collapsed one yourself that choice sticks — updates won't fold it back up
- Wires up the screenshot keys: `Print` snips a region and opens it in satty to mark up (crop, arrow, text, highlight, blur) before saving, `Shift+Print` does the same for the whole monitor your cursor is on, and `Ctrl+Print` grabs a region straight to the clipboard with no editor. `Super+P` still works as an alias for `Print`. Satty's pen colours regenerate from your wallpaper alongside everything else, so they always match
- Copies the system-level stuff into place (keyd, the SDDM theme)
- Installs and registers the DMS plugins
- Sets up your per-monitor tagrules (more on this below) and seeds your taskbar pins + a default wallpaper
- Asks which monitor is your game display — the one Steam games should open on. Nothing else moves; it's not a general default screen. Skipping is fine, and you can set or change it later with `./install.sh --reselect-main-display`
- Asks about pinning your power profile to performance (desktop only — it skips this on a laptop)
- Asks about autostarting easyeffects
- Asks about the combined audio OSD patch. That one's different: it edits a file DMS itself owns, not something DankMango installed, which is why it's opt-in. Changed your mind after saying no? `~/.config/mango/scripts/apply-patches.sh combined-audio-osd` applies it; see [Patches](#patches-the-bits-that-edit-other-programs-files) for what happens to it after a DMS update
- Restarts DMS so all of it takes effect

## The welcome panel

The first time your new desktop starts, a small panel opens to say hello. It points you at the help hub (`SUPER+SHIFT+/`), and gives you buttons for the two or three things worth doing on day one — open the guide, pick a wallpaper, choose your game display. It opens on your game display, or on your leftmost monitor if you never picked one.

It shows up **once**. Hitting "Got it" writes a marker file and that's the last you see of it. If you're wondering why it didn't appear on an install you've done before, that's why — the marker's still there from last time.

Dismissed it too fast and want another look?

```bash
rm ~/.local/state/dankmango/first-run-complete && dms restart
```

`dms restart` reloads the bar, launcher and popups. It doesn't log you out and it won't close your windows.

Worth knowing: DankMaterialShell has a welcome tour of its own, which you never see on a DankMango install (DankMango's installer writes the settings file DMS uses to decide you're a new user, so DMS decides you aren't one). It's still there if you're curious — `dms ipc call welcome open`.

## Per-monitor layout

mango needs your monitors' actual output names to handle per-monitor layouts, and it can't work them out from the config on its own. The installer sorts this for you: it runs `generate-tagrules.sh`, which asks mango what's connected (`mmsg get all-monitors`) and writes a tile block for each monitor into `~/.config/mango/dms/tagrules.conf`.

Everything starts on tile. Change a monitor's layout from the bar (Monitor Mode button) whenever you want — no config editing needed.

Add or remove a monitor later (docking a laptop, say) and you don't need to do anything: a background watcher handles it, [see below](#monitors-plugging-them-in-and-out). If you want to force it by hand anyway:

```bash
~/.config/mango/scripts/generate-tagrules.sh
```
then `Super+r`. Running it directly resets every monitor to tile — the watcher is the path that puts your layouts back.

If you've got an unusual setup and want to hand-write rules for a specific monitor, `config.conf` has a commented template for that.

## Monitors: plugging them in and out

DankMango runs one small background program: `monitor-watcher.sh`, started from an `exec-once` line in `config.conf`. It waits for you to plug in or unplug a monitor and does nothing else the rest of the time. It's mentioned here because you didn't ask for it and it never announces itself — worth knowing what's running on your machine.

It handles two situations, and treats them very differently on purpose.

**Plugging a monitor in or out — handled silently.** mango keys its layout rules to the output name, so a monitor you've just plugged in has no rules at all until they're regenerated. The watcher does that and reloads mango. No prompt, because there's no decision to make — asking would be a dialog with one button.

The part that isn't obvious: regenerating those rules resets every monitor to tile. So the watcher captures your layouts first and puts them back afterwards. It also remembers them **persistently**, so a monitor you unplug and replug later comes back on the layout it had. A monitor it's never seen before starts on tile, as you'd expect. None of this needs anything from you.

**Your game display going away — always asked, never assumed.** If the monitor you picked as your game display gets unplugged, the watcher stands in a temporary replacement (leftmost, largest if that ties) so anything depending on it keeps working, and tells you what happened. It does **not** quietly rewrite your choice — plug the original back in and everything returns to normal on its own.

The notification has two buttons: use the stand-in for games from now on, or keep your original. **DankMaterialShell only shows notification buttons when you hover the notification**, which catches people out. Ignoring it is fine and changes nothing. Plug a genuinely new monitor in and you get a quieter notification offering to open games on that one instead — once per monitor, so it won't nag.

## Your game display

The installer asks which monitor games should open on, because nothing can work it out for you — "the biggest" and "the leftmost" are both wrong often enough (a small primary next to a big secondary is a normal desk). Monitors are listed by physical position, left to right:

```
( ) DP-1  1st from left  2560x1440
( ) DP-2  2nd from left  1920x1080
```

To change it later:

```bash
./install.sh --reselect-main-display
```

That re-opens the same picker and changes nothing else — it won't re-run the installer. Move with the **arrow keys** or **Ctrl-P / Ctrl-N** (handy if your keyboard has no dedicated arrows), **Space** to select, **Enter** to confirm. Space matters: pressing Enter without it just accepts whatever was already highlighted.

**What it actually changes:** games launched from Steam open on that monitor instead of wherever your mouse happens to be. That's it, for now — it is **not** a general "default monitor" setting, and nothing else you open pays any attention to it. It works through a generated rules file (`~/.config/mango/dms/mainmonitor.conf`) that the watcher rewrites whenever your game display changes — mango can't read a preference from disk at runtime, so the monitor name has to be baked into a real rule. Don't hand-edit that file; it gets overwritten.

Skipping the question is fine. With no game display set, games open wherever the pointer is, which is mango's normal behaviour.

(Under the bonnet the setting is still stored as `mainDisplay`, and the flag is still `--reselect-main-display`. Only the wording changed — renaming either would break every existing install and anyone's muscle memory for no real gain.)

## If the monitor stuff seems wrong

Check what the watcher currently thinks:

```bash
~/.config/mango/scripts/monitor-watcher.sh --status
```

That prints your connected monitors, your stored game display, which one's actually in use right now, and the layouts it's remembered. Its log is at `/tmp/mango-monitor-watcher.log` — every hotplug it handled and what it did about it.

`post-update-health.sh` checks this too: it'll tell you if the watcher has stopped running, or if it's running but no longer wired into `config.conf` to start at login (which works fine now and silently vanishes at your next reboot).

## If your colours are stuck on the old wallpaper

Your window borders, the login screen and the visualiser accents all follow your wallpaper through one small background watcher. If you changed your wallpaper and those didn't follow, the usual reason is the watcher wasn't running at the moment you changed it. The health check tells you whether it's running now:

```bash
~/.config/mango/scripts/post-update-health.sh
```

Here's the part that catches people out. **Starting the watcher again doesn't fix colours that are already wrong.** It takes a reading the moment it starts and then waits for the *next* wallpaper change, so anything it missed while it was gone stays missed. You can have a perfectly healthy watcher running and stale colours sitting there indefinitely, and nothing looks broken.

To resync, you have to give it a change to react to. Setting your wallpaper to something else and back does it. So does nudging it directly, which is the lighter option since it leaves your wallpaper alone:

```bash
touch ~/.cache/DankMaterialShell/dms-colors.json
```

Within a second your borders, the login screen palette and the visualiser accents are back in step.

One thing not to lean on: `border-color-healthcheck.sh` checks that every link in the chain is *wired up*, not that your colours are *current*. It'll report "All links OK" while your borders are still showing last week's wallpaper — the wiring genuinely is fine, it's the contents that are stale. Use it to find a broken chain, not to confirm your colours are up to date.

## If your borders thin out or flicker (Nvidia)

If your window borders look uneven — thinner down one edge, or flickering as windows move — and you're on the Nvidia proprietary driver, that isn't DankMango. It's a known bug in scenefx, the rendering library mango draws borders with: it asks for `mediump` fragment shader precision, Nvidia's GLES implementation honours that literally, and the resulting rounding error is enough to eat a pixel off a border.

The upstream fix is [wlrfx/scenefx#177](https://github.com/wlrfx/scenefx/pull/177), which adds a flag to force high precision. Until that lands and reaches your distro's scenefx package, the only workaround is building scenefx yourself with the patch and pointing mango at your build.

DankMango deliberately doesn't ship or automate that. It's Nvidia-specific, it means shadowing a packaged system library, and the fix belongs upstream rather than in a config repo. If the borders bother you enough, check the PR for its current status and build from there.

## If the login screen seems wrong

First, the thing worth knowing before you touch anything:

**Your way back in is Ctrl+Alt+F3.** If a login screen ever won't let you in, hold Ctrl and Alt and press F3. You get a plain text login prompt — type your username, Enter, your password, Enter — and you're on the machine with a working shell, from where anything below can be fixed. Ctrl+Alt+F1 takes you back to the graphical screen.

Use **F3**, not F2. SDDM sits on the first console, and if it's crashing and restarting it tends to take the second one with it, so F2 can land you right back in the mess you're trying to escape. F3 is the first one reliably clear of it. (F4 and F5 work just as well.)

Do this *before* you change anything to do with the login screen, not after — a console you already know works beats one you're hoping works.

### The login screen doesn't look like DankMango's

Installing the theme and *switching to it* are two separate steps on purpose — flipping that switch is the one change that can leave you staring at a broken login screen, so DankMango never does it behind your back. If you never ran the switch command, everything's working as intended; you're just still on your old login screen.

Check which one is actually set:

```bash
cat /etc/sddm.conf.d/theme.conf
```

If it doesn't say `Current=dankmango`, that's your answer. To switch:

```bash
sudo sh -c 'printf "[Theme]\nCurrent=dankmango\n" > /etc/sddm.conf.d/theme.conf'
```

Then reboot — with a console open on Ctrl+Alt+F3, the first time.

You can also just look at it without logging out at all:

```bash
sddm-greeter-qt6 --test-mode --theme /usr/share/sddm/themes/dankmango
```

That opens a preview window you can close again. Handy for checking a change took, though see the power-button note below — some things genuinely can't work in a preview.

`post-update-health.sh` checks all of this too, and tells you which of the two situations you're in.

### The colours or background are out of date

The login screen can't read your home folder. It genuinely can't — it runs as a separate system user before you've logged in, and your home directory isn't readable by anyone but you. So it can't follow your wallpaper the way the bar and your window borders do.

Instead, a small script copies your wallpaper's colours, plus a shrunk copy of the image itself, into a couple of files the login screen *is* allowed to read. That runs every time you change your wallpaper.

If the login screen is showing an old wallpaper or the wrong colours, run that script by hand:

```bash
~/.config/mango/scripts/sddm-palette-sync.sh --verbose
```

No password needed — that's the whole point of the design. `--verbose` makes it tell you what it did, or why it decided there was nothing to do.

If that fixes it but it goes stale again next time you change your wallpaper, the automatic trigger is what's broken, not the sync itself. Nothing runs the sync on a timer — it's fired by the same background watcher that updates your window border colours. `post-update-health.sh` checks specifically for that and says so.

### The power buttons don't do anything

**If you're looking at a `--test-mode` preview, this is expected and nothing is wrong.** The shutdown, restart and suspend buttons stay disabled unless the SDDM service itself confirms the machine can do each one, and in a preview there's no SDDM service attached to confirm anything. They'd fail silently if they *were* clickable, so the theme greys them out instead. Log out properly and they work.

On a real login screen, a greyed-out button means the system reported it can't do that action — most often suspend, on a machine with it disabled. Shutdown and restart greyed out on a real login screen isn't normal, and points at something wrong with your system's login service rather than the theme:

```bash
systemctl status sddm
```

There's no lock or log-out button, and that's not an oversight — the login screen runs before any session exists, so there's nothing yet to lock or log out of.

## Customizing your setup

A few things people tend to want to change straight away. None of them need anything clever — they're all single values.

**Bar position.** Click the gear icon on the bar to open DankMaterialShell's settings, go to the **Dank Bar** tab, and set the position on your bar card — Top, Bottom, Left or Right. It's per-bar, so if you've added more than one they move independently. No restart needed.

**Gap width between windows.** In `~/.config/mango/config.conf`:

```
gappih = 20    # inner gaps — between tiled windows
gappiv = 20
gappoh = 40    # outer gaps — between windows and the screen edge
gappov = 40
```

Lower them if 40 feels too generous (20/20 is a common taste), then `Super+r` to reload.

**How long the alt-tab switcher stays up.** The card overlay hides a set time after your last Tab press — the `interval:` on the `idleHide` Timer in `~/.config/DankMaterialShell/plugins/altSwitcher/AltSwitcherBar.qml`, in milliseconds, `800` (0.8s) by default. Raise it if the switcher vanishes before you've picked a window, lower it if it lingers. `dms restart` afterwards — editing the file alone does nothing until the shell reloads the plugin.

## Updating

```bash
cd DankMango
git pull
./update.sh --dry-run
./update.sh
```

Every DankMango script documents its own flags behind `--help`, including the helpers in `~/.config/mango/scripts/`. You don't have to hunt for them: `SUPER+SHIFT+/` → **Commands you can type** lists every DankMango command exactly as you'd type it, one line of description each. Same list from a terminal with `docs-hub.sh flags`, or `docs-hub.sh flags update.sh` for one script's full `--help`.

`update.sh` only touches what's actually changed since you last updated — it isn't re-running the whole installer. It works that out from the commit recorded in your install manifest, compares it to the repo's current state, and from there:

- takes a snapshot first, so a bad update is a rollback away
- installs any new packages
- re-copies any config/script files that changed (backing up first)
- removes anything the repo has dropped
- runs migrations for things like `settings.json` or `session.json` — files a plain copy can't handle, since they hold your own live settings

It won't overwrite something you've hand-edited without checking with you first. And if it can't work out the delta safely — your last update got interrupted, your git history's been rebased, you've got uncommitted changes sitting around — it tells you and points you at `install.sh` instead of guessing.

### The snapshot it takes first

Before it changes anything, `update.sh` asks snapper to take a snapshot of your system, described `DankMango pre-update: <old commit> -> <new commit>`. If an update goes badly, that snapshot is waiting for you in the boot menu (this is what grub-btrfs puts there), and you can boot straight back into how things were ten minutes ago.

This needs two things, and it checks for both rather than assuming: your root filesystem is Btrfs, and snapper is already set up on it. That's the default on a stock CachyOS install, so most people get it for free. If you're on ext4, or on Btrfs without snapper, `update.sh` says so in one line and gets on with the update — nothing is wrong and there's nothing you need to do. It's a bonus when it's available, never a requirement, so even a snapshot that outright fails only prints a warning: an update never gets blocked over it.

It won't ask which snapper config to use either. If you have one named `root` — nearly everyone does — it uses that; otherwise it uses the first one you've got.

It keeps the 10 most recent of its own snapshots and quietly clears out older ones as it goes, so they don't pile up on your disk. Snapshots you took yourself, and anything snapper or pacman made, are never touched — it only ever removes snapshots it created and labelled itself.

The health check (`SUPER+SHIFT+/` → **Run the health check**) confirms afterwards that a snapshot actually landed. That check is informational: it can't fail, and it stays quiet entirely on machines without Btrfs and snapper.

## If `git pull` says your branch has diverged

You run `git pull` and instead of an update you get a wall of text mentioning `pull.rebase`, `--ff-only`, or `Need to specify how to reconcile divergent branches`. `update.sh` prints a plain-English version of all this when it hits the same situation, so you shouldn't need this section — it's here for when you hit it outside the updater.

**What it means.** Your DankMango folder has changes GitHub doesn't have, and GitHub has changes your folder doesn't. Git calls that a *diverged branch* and refuses to guess which side wins, so it asks you to pick a merge strategy. You don't need to pick one.

Nothing is broken and nothing is lost. Your desktop keeps running exactly as it is — this is only about the folder you cloned into.

**The fix.** That folder is only ever meant to be a copy of DankMango, so throw your side away and take GitHub's. The command for that is `git reset --hard`, which **cannot be undone** — it permanently deletes anything in that folder that isn't on GitHub. So check what's in there first. That check isn't optional.

1. In a terminal, go to the folder and ask git what's sitting in it:

   ```bash
   cd ~/DankMango        # wherever you cloned it
   git status
   ```

2. Read the reply.

   - `nothing to commit, working tree clean` means you've nothing to lose — go to step 3.
   - Anything listed under **Changes not staged for commit**, **Changes to be committed**, or **Untracked files** is *yours*, and step 4 will delete it. Stop and copy it somewhere outside the folder first (`cp ~/DankMango/the-file ~/Desktop/`), then carry on.

   This only concerns the clone. Your live settings live in `~/.config/mango` and `~/.config/DankMaterialShell`, and none of these steps touch them.

3. Only if you've deliberately made your own commits in that folder — you'd know, you'd have typed `git commit` yourself — park them under a name first so they survive:

   ```bash
   git branch my-dankmango-changes
   ```

4. Now take GitHub's version:

   ```bash
   git fetch origin
   git reset --hard origin/main
   ```

   `fetch` downloads the newest version without applying it; `reset --hard` then makes your folder identical to it, discarding the local side you checked in steps 2 and 3.

5. Update as normal:

   ```bash
   ./update.sh --dry-run
   ./update.sh
   ```

If any of that goes sideways, a clean re-clone is always safe — nothing about your installed desktop lives in this folder:

```bash
cd ~                              # one level above the clone
mv DankMango DankMango-old
git clone https://github.com/AhjinYeri/DankMango.git
```

Then run `./update.sh` from the new folder and delete `DankMango-old` once you're happy.

## What to do when the health check fails

After an update, run `~/.config/mango/scripts/post-update-health.sh`. It checks everything DankMango customises that a MangoWM or DMS update can quietly break — per-monitor tagrules, the monitor watcher (both that it's running and that it's still wired to start at login), the generated game-display rules, the bar plugins, the welcome panel, the combined audio OSD patch, the border colour chain, and the SDDM login theme (installed, actually in use, and its wallpaper sync still wired up) — and prints a PASS or FAIL line for each, plus which versions changed since you last ran it.

If anything fails you get a numbered list of problems, each with a plain-English walkthrough: the exact commands to type, what each one does, and why you're running it. It assumes no prior Linux knowledge, and following the steps as written is the entire fix — no AI tooling involved. A ready-made Claude Code prompt gets printed underneath for anyone who happens to use it, but it's strictly optional and safe to ignore. A few failures are expected and take a single command (a patch wiped by a DMS update just needs re-applying — see [Patches](#patches-the-bits-that-edit-other-programs-files) below); one or two genuinely can't be fixed by hand, and those say so plainly instead of sending you round in circles.

## Patches: the bits that edit other programs' files

Most of DankMango is its own files, which nothing else touches. A couple of features aren't: they're small edits to files belonging to somebody *else's* package. The combined audio OSD is the one that ships today — it adds the device name to the volume popup by editing a file the `dms-shell` package owns.

Files like that get replaced wholesale whenever their package updates, which silently reverts the edit. That's expected, it isn't damage, and one command fixes all of it:

```bash
~/.config/mango/scripts/apply-patches.sh
```

It checks every patch DankMango knows about and re-applies **only** the ones that have actually been wiped. You don't need to know their names or which one broke. Safe to run any time — it backs each file up first, does nothing when there's nothing to do, and running it twice doesn't apply anything twice. It asks for your password, because the files it repairs belong to the system rather than to you. Afterwards, `dms restart` to pick the change up.

To see what state things are in without changing anything:

```bash
~/.config/mango/scripts/apply-patches.sh status
```

Each patch reads as one of:

- **ok** — applied and current
- **STALE** — you have this patch, and a package update wiped it. A bare `apply-patches.sh` repairs it
- **`--`** — not applied here. These are opt-in, so this just means you said no (or were never asked). A bare run will *never* apply one of these behind your back; name it explicitly to opt in: `apply-patches.sh combined-audio-osd`
- **BROKEN** — the package moved or deleted the file the patch targets, so it has nowhere to go. This one needs a human; the health check prints the walkthrough

`--force` re-applies even when the marker is already there, which is only useful for overwriting a file you think has gone bad.

## Uninstalling

```bash
./uninstall.sh --dry-run
./uninstall.sh
```

Everything install.sh does gets logged to a manifest (`~/.local/state/dankmango/manifest.json`) — what packages it installed, what files it backed up, what system stuff it changed. `uninstall.sh` reads that and walks it all back.

How it behaves:

- **Nothing gets deleted.** Anything it removes moves into a rescue folder (`~/.local/state/dankmango/uninstall-<timestamp>/`) that mirrors where everything came from. Put anything back by hand, and delete the folder yourself once you're happy.
- **Your original files come back** — whatever DankMango overwrote gets restored from its backup.
- **Package removal is opt-in.** It only ever offers to remove packages it installed itself, grouped up, and defaults to keeping them. Anything you already had stays untouched, and it won't remove something another package still needs.
- **Every prompt defaults to no.** Nothing destructive happens without you saying yes.
- **It won't clobber your own changes.** If your taskbar pins don't match what DankMango originally set, say, it leaves them alone and tells you.

Anything it genuinely can't undo on its own (a default-app association, say) gets listed at the end as something to fix manually, with a hint on how. If the manifest's missing or looks incomplete, it says so rather than guessing.
