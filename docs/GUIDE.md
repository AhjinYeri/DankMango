# DankMango — full guide

The stuff that got cut from the main README to keep it from being a wall of text. If you just want it running, the [README](../README.md) has you covered — come back here if something needs digging into.

## What install.sh actually does

- Checks you've got an AUR helper, installs one if not
- Installs the required packages (`nemo`, `matugen`, `keyd`, `loupe`, `celluloid`, `cosmic-icon-theme`, `cava`, `zen-browser-bin`, and a few more — see `REPO_PKGS` / `AUR_PKGS` in `lib/common.sh` for the exact list)
- Asks if you want the standard taskbar apps (Spotify, Steam, Discord). Say no and nothing bad happens — it only pins apps that actually got installed, so you won't end up with dead icons either way
- Sets Nemo as your default file manager, Loupe as your default image viewer, and Celluloid as your default video player
- Fixes Nemo's icon — Cosmic (the icon theme) draws a filing cabinet for generic file managers instead of a folder, so there's a small override that fixes that
- Copies the system-level stuff into place (keyd, the SDDM theme)
- Installs and registers the DMS plugins
- Sets up your per-monitor tagrules (more on this below) and seeds your taskbar pins + a default wallpaper
- Asks which monitor is your main display — the one Steam games should open on. Skipping is fine, and you can set or change it any time later with `./install.sh --reselect-main-display`
- Asks about pinning your power profile to performance (desktop only — it'll skip this on a laptop)
- Asks about autostarting easyeffects
- Asks about the combined audio OSD patch — this one's a bit different since it edits a file DMS itself owns, not something DankMango installed. It's opt-in for that reason, and it heals itself automatically if a DMS update wipes it. You can apply it later by hand too: `~/.config/mango/scripts/apply-combined-osd-patch.sh`
- Restarts DMS so all of it takes effect

## Per-monitor layout

mango needs to know your monitors' actual output names to handle per-monitor layouts — it can't work that out on its own from the config. The installer sorts this for you automatically: it runs `generate-tagrules.sh`, which asks mango what's connected (`mmsg get all-monitors`) and writes a tile-mode block for each monitor into `~/.config/mango/dms/tagrules.conf`.

Everything starts in tile mode. Change a monitor's layout from the bar (Monitor Mode button) whenever you want — no config editing needed.

If you add or remove a monitor later (docking a laptop, say), you don't need to do anything — a background watcher handles it, [see below](#monitors-plugging-them-in-and-out). If you ever want to force it by hand anyway:

```bash
~/.config/mango/scripts/generate-tagrules.sh
```
then `Super+r`. Be aware that running it directly resets every monitor to tile — the watcher is the path that puts your layouts back.

If you've got a weird setup and want to hand-write rules for a specific monitor, `config.conf` has a commented template you can use instead.

## Monitors: plugging them in and out

DankMango runs one small background program: `monitor-watcher.sh`, started automatically from an `exec-once` line in `config.conf`. It sits and waits for you to plug in or unplug a monitor, and does nothing else the rest of the time. It's mentioned here because you didn't ask for it and it never announces itself — worth knowing what's running on your machine.

It handles two situations, and treats them very differently on purpose.

**Plugging a monitor in or out — handled silently.** mango stores its layout rules per monitor, keyed by output name, so a monitor you've just plugged in has no rules at all until they're regenerated. The watcher does that for you and reloads mango. There's no prompt because there's no decision to make: the monitors are what they are, and there's exactly one correct answer. Asking would just be a dialog with one button.

The part that isn't obvious: regenerating those rules resets every monitor to tile. So the watcher captures your layouts first and puts them back afterwards. It also remembers them **persistently**, so a monitor you unplug and plug back in later comes back on the layout it had, rather than reverting to tile. A monitor it's never seen before starts on tile, as you'd expect. None of this needs anything from you.

**Your main display going away — always asked, never assumed.** If the monitor you picked as your main display gets unplugged, the watcher picks a temporary stand-in (leftmost, largest if that ties) so anything depending on it keeps working, and sends you a notification saying what happened. It does **not** quietly rewrite your choice — plug the original back in and everything returns to normal without you touching anything.

The notification has buttons: one to make the stand-in your new main display, one to keep your original. **DankMaterialShell only shows notification buttons when you hover the notification**, which catches people out. Ignoring it entirely is fine and changes nothing. Plug a genuinely new monitor in and you'll get a quieter notification offering to make that one your main display — offered once per monitor, so it won't nag.

## Your main display

The installer asks which monitor is your main one, since nothing can work it out for you — "the biggest" and "the leftmost" are both wrong often enough (a small primary next to a big secondary is a normal desk). Monitors are listed by physical position, left to right:

```
( ) DP-1  1st from left  2560x1440
( ) DP-2  2nd from left  1920x1080
```

To change it later:

```bash
./install.sh --reselect-main-display
```

That re-opens the same picker and changes nothing else — it won't re-run the installer. Move with the **arrow keys** or **Ctrl-P / Ctrl-N** (handy if your keyboard has no dedicated arrows), **Space** to select, **Enter** to confirm. Space matters: pressing Enter without it just accepts whatever was already highlighted.

**What it actually changes:** games launched from Steam open on that monitor instead of wherever your mouse happens to be. That's it, currently. It works through a generated rules file (`~/.config/mango/dms/mainmonitor.conf`) that the watcher rewrites whenever your main display changes — mango can't read a preference from disk at runtime, so the monitor name has to be written into a real rule. Don't hand-edit that file; it gets overwritten.

Skipping the question is fine. With no main display set, games just open wherever the pointer is, which is mango's normal behaviour.

## If the monitor stuff seems wrong

Check what the watcher currently thinks:

```bash
~/.config/mango/scripts/monitor-watcher.sh --status
```

That prints your connected monitors, your stored main display, which one is actually in use right now, and the layouts it has remembered. Its log is at `/tmp/mango-monitor-watcher.log` — every hotplug it handled, and what it did about it.

`post-update-health.sh` also checks this: it'll tell you if the watcher has stopped running, or if it's running but no longer wired into `config.conf` to start at login (which would work fine now and silently vanish at your next reboot).

## If your colours are stuck on the old wallpaper

Your window borders, the login screen and the visualiser accents all follow your wallpaper through one small background watcher. If you changed your wallpaper and those didn't change with it, the usual reason is that the watcher wasn't running at the moment you changed it. The health check tells you whether it's running now:

```bash
~/.config/mango/scripts/post-update-health.sh
```

Here's the part that catches people out. **Starting the watcher again doesn't fix colours that are already wrong.** It takes a reading of things the moment it starts and then waits for the *next* wallpaper change, so anything it missed while it was gone stays missed. You can have a perfectly healthy watcher running and stale colours sitting there indefinitely, and nothing will look broken.

To actually resync, you have to give it a change to react to. Changing your wallpaper to something else and back does it. So does nudging it directly, which is the lighter option since it leaves your wallpaper alone:

```bash
touch ~/.cache/DankMaterialShell/dms-colors.json
```

Within a second your borders, the login screen palette and the visualiser accents are all back in step.

One thing not to lean on here: `border-color-healthcheck.sh` checks that every link in the chain is *wired up*, not that your colours are *current*. It'll report "All links OK" while your borders are still showing last week's wallpaper — because the wiring genuinely is fine, it's the contents that are stale. Use it to find a broken chain, not to confirm your colours are up to date.

## If the login screen seems wrong

First, the thing worth knowing before you touch anything:

**Your way back in is Ctrl+Alt+F3.** If a login screen ever won't let you in, hold Ctrl and Alt and press F3. You get a plain text login prompt — type your username, Enter, your password, Enter — and you're on the machine with a working shell, from where anything below can be fixed. Ctrl+Alt+F1 takes you back to the graphical screen.

Use **F3**, not F2. SDDM sits on the first console, and if it's crashing and restarting it tends to take the second one as well, so F2 can just land you back in the mess you're trying to escape. F3 is the first one reliably clear of it. (F4 and F5 work just as well if you need them.)

It's worth doing this *before* you change anything to do with the login screen, not after — a console you already know works is a lot more reassuring than one you're hoping works.

### The login screen doesn't look like DankMango's

Installing the theme and *switching to it* are two separate steps on purpose — flipping that switch is the one change that can leave you staring at a broken login screen, so DankMango never does it behind your back. If you never ran the switch command, everything's working exactly as intended; you're just still on your old login screen.

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

`post-update-health.sh` checks all of this too, and will tell you which of the two situations you're in.

### The colours or background are out of date

The login screen can't read your home folder. It genuinely can't — it runs as a separate system user before you've logged in, and your home directory isn't readable by anyone but you. So it can't follow your wallpaper the way the bar and your window borders do.

What happens instead is that a small script copies your wallpaper's colours, and a shrunk copy of the image itself, into a couple of files the login screen *is* allowed to read. That runs automatically every time you change your wallpaper.

If the login screen is showing an old wallpaper or the wrong colours, run that script by hand:

```bash
~/.config/mango/scripts/sddm-palette-sync.sh --verbose
```

No password needed — that's the whole point of the design. `--verbose` makes it tell you what it did, or why it decided there was nothing to do.

If that fixes it but it goes stale again next time you change your wallpaper, the automatic trigger is what's broken rather than the sync itself. Nothing runs the sync on a timer — it's fired by the same background watcher that updates your window border colours. `post-update-health.sh` checks specifically for that and will say so.

### The power buttons don't do anything

**If you're looking at a `--test-mode` preview, this is expected and nothing is wrong.** The shutdown, restart and suspend buttons are deliberately disabled unless the SDDM service itself confirms the machine can do each one, and in a preview there's no SDDM service attached to confirm anything. They'd fail silently if they *were* clickable, so the theme greys them out instead. Log out properly and they'll work.

On a real login screen, a button that's greyed out means the system reported it can't do that action — most often suspend, on a machine with it disabled. Shutdown and restart being greyed out on a real login screen isn't normal; that points at something wrong with your system's login service rather than with the theme:

```bash
systemctl status sddm
```

There's no lock or log-out button, and that's not an oversight — the login screen runs before any session exists, so there's nothing yet to lock or log out of.

## Customizing your setup

A couple of things people tend to want to change straight away. Neither needs anything clever — they're both single values.

**Bar position.** Click the gear icon on the bar to open DankMaterialShell's settings, go to the **Dank Bar** tab, and set the position on your bar card — Top, Bottom, Left or Right. It's per-bar, so if you've added more than one they move independently. No restart needed.

**Gap width between windows.** In `~/.config/mango/config.conf`:

```
gappih = 20    # inner gaps — between tiled windows
gappiv = 20
gappoh = 40    # outer gaps — between windows and the screen edge
gappov = 40
```

Lower them if 40 feels too generous (20/20 is a common taste), then `Super+r` to reload.

**How long the alt-tab switcher stays up.** The card overlay hides itself a set time after your last Tab press. That's the `interval:` on the `idleHide` Timer in `~/.config/DankMaterialShell/plugins/altSwitcher/AltSwitcherBar.qml` — milliseconds, `800` (0.8s) by default:

```
interval: 800    // display duration after last Alt+Tab poke (0.8s)
```

Raise it if the switcher vanishes before you've picked a window, lower it if it lingers. Run `dms restart` afterwards to load the change — editing the file alone does nothing until the shell reloads the plugin.

## Updating

```bash
cd DankMango
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

After an update, run `~/.config/mango/scripts/post-update-health.sh`. It checks everything DankMango customises that a MangoWM or DMS update can quietly break — per-monitor tagrules, the monitor watcher (both that it's running and that it's still wired to start at login), the generated main-display game rules, the bar plugins, the combined audio OSD patch, the border colour chain, and the SDDM login theme (that it's installed, whether it's actually the one in use, and that its wallpaper sync is still wired up) — and prints a PASS or FAIL line for each, plus which versions changed since you last ran it.

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
