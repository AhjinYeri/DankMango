# First-Run Welcome — plain-English guide

A small panel that opens **once**, the first time your new DankMango desktop starts. It
says hello, tells you about the help hub, and offers the handful of things actually
worth doing first. Dismiss it and it never comes back.

**What's on it:**

1. **A hero header** — the DankMango mango, large, over "Welcome to DankMango", on a
   band tinted with your accent colour and marked with the same sharp diamond motif the
   login screen uses. See "Why it looks like this" below.
2. **A welcome line** — you're set up, and nothing here is permanent. Under it, in
   smaller print, the thing a first-time Linux user most needs told: no terminal
   required, everything the installer replaced is backed up, updates take a snapshot
   before they touch anything, you can't break this.
3. **Four buttons that actually do the thing**, not just describe it:
   - **Open the guide** — launches the help hub, exactly as `SUPER+SHIFT+/` does.
   - **Pick a wallpaper** — opens DMS's own wallpaper picker (`SUPER+w`). DankMango does
     not ship a wallpaper UI of its own; this is the native one.
   - **Choose game display** — re-runs the game-display selector. Games launched from
     Steam are sent to whichever monitor you pick. (Only games — it isn't a general
     default-monitor setting.)
   - **Check my setup** — runs `post-update-health.sh` in a terminal: the same
     PASS/FAIL report you're told to run after an update, here so day one has a way of
     confirming the install actually landed. The terminal waits for Enter before
     closing, because on a healthy machine the report finishes in a second or two.
4. **Got it** — dismisses the panel and writes the marker file, so it never shows again.
   It's the filled, accent-coloured button; the four above it are deliberately quieter,
   because they're suggestions and this is the only thing you actually have to do.
5. **The help hub pointer, in the footer** — `SUPER+SHIFT+/` opens the full guide and
   every keybind, in plain English, with no Linux experience assumed. It used to be a
   highlighted row in the middle of the card, where it was the loudest thing on a panel
   whose job is to get out of the way; in the footer it's the last thing you read before
   clicking **Got it**, which is where a "you can always get back to this" line belongs.
6. **A version line** under it — which build you're on, read from
   `.dankmango.version` in the install manifest. Shown as just the release: **DankMango
   v1.3.0**, never the full `git describe` string the manifest actually stores
   (`v1.3.0-27-g58c5fe0-dirty`). The manifest keeps all of it — the commit count and
   hash are what you want when something needs diagnosing — but they are not what you
   greet someone with on their first login, so the panel cuts everything from the first
   hyphen for display only. Hidden entirely rather than showing "unknown" if the
   manifest can't be read at all.

**Only "Got it" closes the panel.** All four action buttons leave it exactly where it
is, so you can work through them in any order, more than once, and still have the card
in front of you afterwards. Two separate things used to break that: **Open the guide**
dismissed the panel itself (so having a look at the guide silently spent your one and
only welcome), and **Pick a wallpaper** opened DMS's wallpaper picker, which — because
DMS treats modals as mutually exclusive by default — evicted the panel from underneath
it. The panel now sets `allowStacking: true`, DMS's own opt-out from that, so the two
sit happily side by side.

The card sizes itself to its contents rather than to a fixed height, so a larger font
scale makes it taller instead of clipping the bottom off it. Its entrance and exit
animation is DankModal's own (a scale + fade, on DMS's expressive curves) — there is no
animation code in the plugin, deliberately, so it keeps honouring the animation-speed
setting in DMS settings.

## Which monitor it opens on

The one you chose as your **game display** during install — read from
`.userPrefs.mainDisplay` in the manifest and handed to `DankModal`'s own `targetScreen`
property. It's the closest thing to "the monitor you sit in front of" that DankMango
actually knows.

If you skipped that question (it's optional), or the monitor you picked isn't plugged in
right now, it falls back to the **leftmost** connected monitor, ties broken by the
**largest** — the same stand-in rule `monitor-watcher.sh` uses when your game display
disappears, so there's one definition of "the safe substitute monitor" rather than two.
Failing even that, DankModal's own default (the focused screen) applies and the panel
still appears.

## When it appears

Absence of `~/.local/state/dankmango/first-run-complete` means "show me". The file is
written **only when you dismiss the panel** — so an install that never quite reached a
running shell still gets its welcome at the next login, rather than silently burning it.

`install.sh` restarts DMS at the end of a **fresh install only** so the panel appears
straight away. Re-running the installer, or running `update.sh`, never does that: you've
already seen it, and restarting your shell unprompted would be rude.

To see it again deliberately:

```
rm ~/.local/state/dankmango/first-run-complete && dms restart
```

## Why it looks like this

This is the first thing a brand-new install shows anyone, so it is deliberately not
styled like an ordinary settings dialog.

**The header is the logo, big.** The shape of it — mark over title, centred, logo sized
off `Theme.iconSize` — is DMS's own: its `GreeterWelcomePage` does exactly this. What
this panel doesn't copy is that page's recolouring of the logo to the accent, because
DMS's mark is a flat monochrome SVG that takes it well and ours is a five-colour
pixel-art mango that would be destroyed by it. The accent goes into the band instead.

The logo file lives **in this plugin's own folder**, not pointed at the login theme's
copy of it — that one is root-owned and only exists if the SDDM step of the install ran.
`install.sh` and `update.sh` both copy the whole plugin directory, so the asset travels
with the QML on its own. If it's ever missing, the header falls back to the `waving_hand`
icon this panel used to lead with rather than leaving a hole.

**The accent motif is the login screen's.** The sharp rotated square running in from the
left of the header band, and the small solid one floating opposite it, are the same
device `Components/AccentShape.qml` draws on the login screen, in the same live matugen
accent, at the same opacities. Seeing the login screen and then this should feel like
one product rather than two. It's the *design* that's shared, not the file: that
component sits in a root-owned tree a Quickshell plugin can't import across to, so the
two elements are restated here at card scale. The card's own border is accent-tinted for
the same reason.

**It is roomier than DMS's default.** Wider card, `spacingXL` margins, `spacingL` between
sections. The card's height still follows its contents, and the four action buttons are
still in a `Flow` rather than a `Row` — rechecked with the fourth button at font scale
1.3, where they wrap to a second line and the card grows to fit rather than clipping or
overflowing. The card went 720 → 800 wide when that fourth button arrived, purely so all
four still sit on one row at the default scale.

## Why it doesn't use DMS's own first-launch flag

DMS has a first-launch greeter of its own (`FirstLaunchService` + `GreeterModal`, also
reachable any time with `dms ipc call welcome open`). DankMango can't hook into it.

Its check is *"marker missing **and** `settings.json` missing = first launch"*. DankMango's
installer **deploys `settings.json`**, so by the time DMS first starts, the file is already
there — DMS classifies you as an existing user, silently writes its `.firstlaunch` marker,
and never shows its greeter. Hooking that flag would mean hooking something that never
fires on a DankMango install.

Hence a separate marker in DankMango's own state directory, beside the install manifest.
A side effect worth knowing: **DMS's native welcome never appears on a DankMango install**
for the same reason. If you want to see it, `dms ipc call welcome open`.

## Why it's a "daemon" plugin

The other three DankMango plugins are bar widgets, which DMS instantiates **once per bar
per screen**. This panel has no bar presence and must exist exactly once, so it uses DMS's
`daemon` surface — *"any Item exposing `pluginService` / `pluginId`, instantiated once"*
(DMS's `PLUGINS/README.md`). There is no bar icon for it; that's deliberate.

## Requirements

- `jq` — for reading the install manifest: the version line, which monitor to open on,
  and (for the **Choose game display** button) where the repo lives. Without it the
  panel still appears and every button still works; you just lose the version line and
  it opens on whichever monitor DMS would have picked.
- `alacritty` — the guide, the health check and the game-display selector are all
  terminal programs.

Neither is needed for the panel to show or to be dismissed. Whether it appears at all is
decided by `test -f` on the marker file, nothing more.

## Troubleshooting

### Symptom: the panel never appeared on a fresh install

Check the marker isn't already there:

```
ls ~/.local/state/dankmango/first-run-complete
```

If it exists, something already dismissed it — delete it and `dms restart`. If it
doesn't, check the plugin is enabled: DMS Settings → Plugins → **First-Run Welcome**, or
look for `"firstRunPanel": {"enabled": true}` in
`~/.config/DankMaterialShell/plugin_settings.json`. Composite and daemon plugins are
**not** auto-loaded — they respect that toggle.

### Symptom: "Choose game display" says it can't find the DankMango folder

That button needs the repo you installed from, and finds it via `.dankmango.repoDir` in
`~/.local/state/dankmango/manifest.json`. If the clone has moved or been deleted, the
button can't work — run it yourself from wherever the repo lives now:

```
./install.sh --reselect-main-display
```

(The flag keeps its old name on purpose — only the words on the button changed. Renaming
a flag people have typed and scripted buys nothing.)

This is the weakest of the four buttons for exactly that reason: the other three call
things that live in `~/.config`, which never move.

### Symptom: it opened on the wrong monitor

It aims for your game display. Check what's stored:

```
~/.config/mango/scripts/monitor-watcher.sh --status
```

If "stored game display" is empty you never picked one (that's fine — set it with
`./install.sh --reselect-main-display`), and the panel used its leftmost/largest
fallback. If it's set but names a monitor that isn't plugged in, the same fallback
applied. Either way the choice is made fresh each time the panel opens, so nothing needs
resetting.

### Symptom: the panel doesn't come back after you close the guide (or the health
### check, or the game-display picker)

Those three buttons run as tracked `Process` objects, and the panel hides itself for
exactly as long as that process lives — `spawnedRunning` in `FirstRunPanel.qml` counts
them, `onExited` decrements it, and the window's `visible` follows. If the panel stays
hidden, a process is still alive: check with `mmsg get all-clients` for a leftover
terminal. The count is guarded against going negative, so it cannot get stuck that way.

The wallpaper button is the odd one out: it hands off to DMS's own dash, so it is driven
by `PopoutManager.popoutChanged` instead. If a DMS update moves that singleton or renames
`getActivePopout`, that `Connections` block is the thing to fix.

### Symptom: the panel covers a window it opened

It shouldn't — it hides itself while anything it launched is on screen. If you are
tempted to "fix" this with a layer or focus change, read the box at the top of
`FirstRunPanel.qml` first: layer Bottom, a real toplevel window, and
`mmsg dispatch focusid` were all tried and measured, and none of them works here. A
layer-shell surface is not a mango client, so it has no client id to focus, and a
Top-layer surface sits above tiled windows no matter who has focus.

### After editing this plugin

`dms restart` — a plain reload reuses a cached copy. Load errors show up in
`~/.local/share/sddm/wayland-session.log`.
