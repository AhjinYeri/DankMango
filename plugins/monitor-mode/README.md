# Monitor Mode — plain-English guide

A button that lives in your top bar (the **⊟ splitscreen** icon). Click it and a small
panel opens where you pick a **tiling layout for each monitor**.

**How the panel works:**

1. **Monitor cards** across the top — one per connected monitor, showing its name and
   resolution. Click a card to select that monitor; the selected card glows with your
   current accent colour.
2. **Layout grid** below — the six layouts as icon-and-label tiles. Click one to apply it to
   the selected monitor. The layout that monitor is already using is highlighted, so you can
   see the current state at a glance.

Pick a monitor, pick a layout — that's the whole flow. Your monitors are detected
automatically from the compositor, so this works with any number of monitors at any
resolution; nothing about your hardware is hard-coded.

## The six layouts

| Label | mango `layout_name` | Roughly |
|-------|---------------------|---------|
| **Tiling** | `tile` | Windows arranged side by side to fill the screen (the default). |
| **Monocle** | `monocle` | One window fills the screen at a time; the rest are stacked behind it. |
| **Scrolling** | `scroller` | Windows sit in columns you scroll through horizontally. |
| **Grid** | `grid` | Windows laid out in an even grid. |
| **Deck** | `deck` | A main window with the others stacked as a "deck" beside it. |
| **Center Tiling** | `center_tile` | The main window centred, with the others to the sides. |

The label is what you click; the `layout_name` is what actually gets written to the config
(see below).

---

## How the layout is actually stored (the tagrules)

You normally never touch this — the bar button does it for you — but it helps to know where
the setting lives.

MangoWM sets a monitor's layout from its **tag rules**. In DankMango those live in their own
auto-generated file, `~/.config/mango/dms/tagrules.conf`, which `config.conf` sources — *not*
in `config.conf` itself. Tags (workspaces) are per-monitor, so each monitor gets a block of
**9 tagrules** — one per tag, `id:1` through `id:9`. Each rule carries a `layout_name:` field:

```
tagrule = id:1, monitor_name:DP-1, layout_name:tile
```

All this plugin does is rewrite that `layout_name` on a monitor's 9 tagrules (via the setter
script below), then reload MangoWM. So **use the bar button — don't hand-edit tagrules**
unless you're troubleshooting.

**Where the block lives:** `~/.config/mango/dms/tagrules.conf` — one 9-tagrule block per
monitor, generated for your actual hardware. `config.conf` sources it near the bottom
(search that file for `tagrules.conf`).

> **First-time setup is automatic.** MangoWM needs your monitors' *literal* output names and
> can't guess them, so the installer runs `generate-tagrules.sh`, which queries the live
> compositor (`mmsg get all-monitors`) and writes one block per connected monitor. Every
> monitor starts with the **tile** layout; the bar button changes them from there. **The
> plugin can only control a monitor that already has its 9 tagrules present** — so if you add
> or remove a monitor later, regenerate them and reload (**Super+r**):
>
> ```
> ~/.config/mango/scripts/generate-tagrules.sh
> ```
>
> For hand-tuning an unusual setup, `config.conf` also keeps a commented
> **"Per-monitor window layout"** template (using a placeholder `MONITOR-1` name) you can
> adapt instead — but the generated file is the normal path, and `set-monitor-layout.sh`
> edits `tagrules.conf`, not `config.conf`.

---

## How the whole thing fits together (2 pieces)

You don't need to read the code — just know which file does what, so if something breaks you
know where to look.

| Piece | File | What it does |
|------|------|--------------|
| **The button** (this plugin) | `~/.config/DankMaterialShell/plugins/monitorMode/MonitorModeBar.qml` | The panel: monitor cards + the layout grid. Holds **no layout logic** — clicking a layout runs the setter script below. It reads `tagrules.conf` live to highlight each monitor's current layout. The setter path is resolved from `$HOME` at run time, so it's not tied to any user. |
| **The setter** | `~/.config/mango/scripts/set-monitor-layout.sh` | Rewrites `layout_name` on a monitor's 9 tagrules in `dms/tagrules.conf`, validates the file, saves it, and reloads MangoWM. Whitelists the six layout names, so a bad name is refused rather than silently ignored. |

The setter has a clearly-marked **`EDIT HERE AFTER A MANGO UPDATE`** box at the top that holds
every command an update could change — you almost never need to touch anything outside it.

---

## "It broke after a system update" — quick checks

Restart the shell first so you're testing the real current state (a plain plugin off/on
toggle reuses a cached copy): `dms restart`.

### I pick a layout and nothing happens / windows don't rearrange
The most common break: the config-reload command changed. Test it:
```
mmsg dispatch reload_config      # expect {"success":true}
```
If it errors, MangoWM renamed the verb — find the new one with `mmsg --help` and update
`mango_reload_config()` in `set-monitor-layout.sh`.

### The bar button vanished or won't turn on (after a DMS update)
The plugin failed to load — usually DMS renamed a building block. Check the shell log for a
line naming `MonitorModeBar.qml`. **Known gotcha:** `DankIcon` uses `size:`, **not**
`font.pixelSize:`. After any edit run `dms restart`, then re-enable under DMS Settings
(`Ctrl+,`) → Plugins → **Monitor Mode**, and confirm it's in your bar (Settings → Appearance
→ DankBar Layout).

### A layout tile shows no icon
The Material Symbol name for that layout isn't in your icon font. The tile still works (the
label is what matters); swap the `icon:` in the `layouts` list near the top of
`MonitorModeBar.qml` for one your font has, then `dms restart`.

---

## Everyday tweaks

- **Moved your scripts?** update the `layoutSetter` property near the top of
  `MonitorModeBar.qml` (it's built from `$HOME`) and the paths in the setter's EDIT-HERE box,
  then `dms restart`.
- **Tiling gaps** (space between windows) are set with `gappih`/`gappiv`/`gappoh`/`gappov` in
  `~/.config/mango/config.conf` (or via DMS) — reload with **Super+r**.

---

> **A note on Float mode.** Earlier versions of this plugin also toggled a monitor between
> tile and "Windows-11 style" floating. That's temporarily not exposed here while a sizing
> bug is refined. The QML keeps a clearly-marked add-back block so it can be reintroduced
> without a rebuild — see the `FLOAT MODE — TEMPORARILY REMOVED` comment in
> `MonitorModeBar.qml`.
