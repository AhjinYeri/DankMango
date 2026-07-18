# Monitor Mode — plain-English guide

A button that lives in your top bar (the **⊟ splitscreen** icon). Click it and a small
panel opens where you set **each monitor** to **Tile** or **Float**:

- **Tile** — windows automatically arrange to fill the screen (a normal tiling layout).
- **Float** — windows open as a big, draggable, "Windows-11 style" window. Each one is sized
  and placed to match exactly what a **single tiled window** would get on that monitor, so a
  Float monitor looks just like a Tile monitor holding one window (same margins, same strip
  reserved for the bar). There's no fixed percentage — it's derived from your live layout, so
  it fits any resolution automatically.

You can set each monitor on its own, or pick a ready-made combo (**All Tile**, **All Float**,
and — with exactly two monitors — **Tile / Float** and **Float / Tile**). Your monitors are
detected automatically from the compositor, so this works with any number of monitors at any
resolution; nothing about your hardware is hard-coded.

---

## How tile-vs-float is actually stored (the tagrules)

You normally never touch this — the bar button does it for you — but it helps to know where
the setting lives.

MangoWM decides a monitor's mode from its **tag rules**. In DankMango those live in their own
auto-generated file, `~/.config/mango/dms/tagrules.conf`, which `config.conf` sources — *not*
in `config.conf` itself. Tags (workspaces) are per-monitor, so each monitor gets a block of
**9 tagrules** — one per tag, `id:1` through `id:9`. The rule is simple:

- A monitor **floats** if its 9 tagrules contain **`open_as_floating:1`**.
- A monitor **tiles** if they don't.

All this plugin does is add or remove that one keyword (via the setter script below), then
reload MangoWM. So **use the bar button — don't hand-edit tagrules** unless you're
troubleshooting.

**Where the block lives:** `~/.config/mango/dms/tagrules.conf` — one 9-tagrule block per
monitor, generated for your actual hardware. `config.conf` sources it near the bottom
(search that file for `tagrules.conf`).

> **First-time setup is automatic.** MangoWM needs your monitors' *literal* output names and
> can't guess them, so the installer runs `generate-tagrules.sh`, which queries the live
> compositor (`mmsg get all-monitors`) and writes one block per connected monitor. Every
> monitor starts in **tile** mode; the bar button flips them from there. **The plugin can
> only control a monitor that already has its 9 tagrules present** — so if you add or remove
> a monitor later, regenerate them and reload (**Super+r**):
>
> ```
> ~/.config/mango/scripts/generate-tagrules.sh
> ```
>
> For hand-tuning an unusual setup, `config.conf` also keeps a commented
> **"Per-monitor window mode"** template (using a placeholder `MONITOR-1` name) you can adapt
> instead — but the generated file is the normal path, and `set-monitor-mode.sh` edits
> `tagrules.conf`, not `config.conf`.

---

## Dragging a window between monitors

Tagrules only decide a window's mode **when it first opens** — MangoWM applies
`open_as_floating` at open time and never re-checks it afterward. So on its own, MangoWM would
let a **dragged** window keep its old mode: a tiled window dragged onto a Float monitor would
stay a cramped tile, and a floating window dragged onto a Tile monitor would sit on top of the
tiling layout instead of joining it.

DankMango fixes this for you. The background **placer** (`dp2-floatsize.sh`) notices a window
arriving on a monitor and corrects its mode to match the **destination**:

- Drag a window onto a **Float** monitor → it's floated and given the big, tiled-window-sized box.
- Drag a window onto a **Tile** monitor → it's un-floated so it drops into the tiling layout.

This is a deliberate feature of this setup, **not** a MangoWM default — without the placer
running, dragged windows would keep whatever mode they opened in. (It's the same placer that
sizes floating windows, so if drag-correction ever stops, see the update-checks below.)

---

## How the whole thing fits together (3 pieces)

You don't need to read the code — just know which file does what, so if something breaks you
know where to look.

| Piece | File | What it does |
|------|------|--------------|
| **The button** (this plugin) | `~/.config/DankMaterialShell/plugins/monitorMode/MonitorModeBar.qml` | Just the buttons. Holds **no logic** — every button runs the setter script below. The setter path is resolved from `$HOME` at run time, so it's not tied to any user. |
| **The setter** | `~/.config/mango/scripts/set-monitor-mode.sh` | Adds/removes `open_as_floating` on a monitor's 9 tagrules in `dms/tagrules.conf`, saves it, and reloads MangoWM. |
| **The placer** | `~/.config/mango/scripts/dp2-floatsize.sh` | Runs in the background. Sizes/places floating windows to match a single tiled window on the same monitor, and auto-corrects a window's mode when you drag it between monitors (see below). Sizes are derived live from your layout — nothing to capture per machine. |

Both scripts have a clearly-marked **`EDIT HERE AFTER A MANGO / DMS UPDATE`** box at the top
that holds every command an update could change — you almost never need to touch anything
outside it.

---

## "It broke after a system update" — quick checks

Restart the shell first so you're testing the real current state (a plain plugin off/on
toggle reuses a cached copy): `dms restart`.

### I change a mode and OLD windows update, but NEW windows keep the old mode
The most common break: the config-reload command changed. Test it:
```
mmsg dispatch reload_config      # expect {"success":true}
```
If it errors, MangoWM renamed the verb — find the new one with `mmsg --help` and update
`mango_reload_config()` in `set-monitor-mode.sh`.

### Floating windows aren't sized/placed, or dragging between monitors doesn't tile
The background placer is using an outdated command. In `dp2-floatsize.sh`'s EDIT-HERE box,
test its mango commands by hand, e.g.:
```
mmsg get focusing-client
mmsg get all-monitors
```
Fix the matching wrapper for any that error, then restart the placer (or just log out/in —
it auto-starts on login).

### The bar button vanished or won't turn on (after a DMS update)
The plugin failed to load — usually DMS renamed a building block. Check the shell log for a
line naming `MonitorModeBar.qml`. **Known gotcha:** `DankIcon` uses `size:`, **not**
`font.pixelSize:`. After any edit run `dms restart`, then re-enable under DMS Settings
(`Ctrl+,`) → Plugins → **Monitor Mode**, and confirm it's in your bar (Settings → Appearance
→ DankBar Layout).

---

## Everyday tweaks

- **Bigger/smaller floating windows:** floating windows are sized to match a tiled window, so
  there's no separate size knob — change your **tiling gaps** instead (`gappoh`/`gappov`, via
  DMS or `~/.config/mango/dms/layout.conf`) and floating follows automatically, staying
  identical to tiling.
- **Moved your scripts?** update the `setter` property near the top of `MonitorModeBar.qml`
  (it's built from `$HOME`) and the paths in each script's EDIT-HERE box, then `dms restart`.
- **Debug the placer:** restart it with `DP2_DEBUG=1`, then `tail -f /tmp/dp2-floatsize.log`.
