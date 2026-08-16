# Preset Switcher — plain-English guide

Open your launcher and type **`preset`**. Your desktop presets are listed; press Enter on one to
apply it immediately — no logout, no editing config files.

A **preset** is a named bundle of MangoWM settings you swap as a unit. DankMango ships two:

| Preset | What it does |
|--------|--------------|
| **Default** | Adds nothing. Your desktop exactly as your own settings describe it. |
| **Minimal** | Tight gaps and quick animations — more screen, less motion. |

The one you're currently on shows a **✓ check icon** and an **"Active"** subtitle. Switching back
to **Default** undoes everything a preset did; nothing is written into `config.conf`, so there is
nothing to clean up by hand.

---

## Why there's no bar button

There used to be one. It was removed on purpose.

Switching presets is a **deliberate, occasional** action — the sort of thing you do when you sit
down to change how the desktop feels, not something you reach for many times a day. A permanent
bar pill costs screen space every second of every day regardless, so the trade was a bad one.
DankMango's rule now: **low-frequency actions belong on the launcher, not the bar**, whenever the
launcher can carry the UI they need.

It can here. A launcher row shows an icon, a title and a subtitle, which is exactly what the old
card showed. DMS's own **Settings Search** (`?`) and **Clipboard** (`cb`) work the same way, and
are the pattern this follows.

**Prefer it always visible?** Turn on *"Show presets in ordinary search"* in DMS Settings →
Plugins → Preset Switcher, and presets appear alongside apps with no trigger needed.

**Want a different trigger?** Same settings page. It's matched as a prefix, so pick a whole word
— a single letter like `p` would swallow every search starting with p.

---

## Two things worth knowing

**1. A preset overrides the matching DMS sliders while it's active.**

The gaps sliders in **DMS Settings → Compositor Layout** write to a file that MangoWM reads
*before* your preset. Mango uses the last value it reads, so while **Minimal** is active it wins
and the DMS gaps slider appears to do nothing. That's intended — picking a preset is a deliberate
choice and should beat an ambient slider — but it looks like a broken slider if you don't know.
Switch to **Default** and the slider works again immediately.

**2. Adding your own preset needs no code.**

Make a folder under `~/.config/mango/presets/`, put a `preset.conf` in it, and it appears in the
launcher at once — this plugin asks `set-preset.sh` for the list at runtime rather than holding
one of its own. Full instructions, including the four header lines each preset needs and the
**bar-clearance rule for `gappov`**: `~/.config/mango/presets/README.md`.

---

## How the whole thing fits together (2 pieces)

You don't need to read the code — just know which file does what, so if something breaks you know
where to look.

| Piece | File | What it does |
|------|------|--------------|
| **The launcher entry** (this plugin) | `~/.config/DankMaterialShell/plugins/presetSwitcher/PresetSwitcherLauncher.qml` | Supplies the rows. Holds **no preset logic and no preset list** — it runs `set-preset.sh --list --porcelain` for both, and selecting a row runs `set-preset.sh <name>`. The script path is resolved from `$HOME` at run time, so it's not tied to any user. |
| **The setter** | `~/.config/mango/scripts/set-preset.sh` | Validates the chosen preset, atomically repoints the `~/.config/mango/active/preset.conf` symlink at it, reloads MangoWM, and records the choice in DankMango's manifest. Only offers presets that actually exist on disk, so a typo is refused rather than silently ignored. |

(`PresetSwitcherSettings.qml` is the third file — it only exists so the trigger is editable. DMS
provides a trigger field for its *own* launcher plugins but not for third-party ones.)

The setter has a clearly-marked **`EDIT HERE AFTER A MANGO UPDATE`** box at the top that holds
every command an update could change — you almost never need to touch anything outside it.

The mechanism itself (the symlink, the `source-optional=` include, the atomic swap and why
`Default` is an empty file) is written up once, in
[`~/.config/mango/presets/README.md`](../../config/mango/presets/README.md).

---

## "It broke after a system update" — quick checks

Restart the shell first so you're testing the real current state (a plain plugin off/on toggle
reuses a cached copy): `dms restart`.

### Typing `preset` in the launcher finds nothing
Three things to separate, in order.

1. **Is the plugin on?** DMS Settings (`Ctrl+,`) → Plugins → **Preset Switcher** must be enabled.
   A launcher plugin that isn't enabled has no trigger at all.
2. **Is the trigger still `preset`?** DMS Settings → Plugins → Preset Switcher shows it. It's also
   listed under Settings → Launcher, in the plugin-visibility list.
3. **Does the backend work?** Run it directly:
   ```
   ~/.config/mango/scripts/set-preset.sh --list
   ```
   If that lists your presets but the launcher doesn't, the plugin loaded but DMS changed the
   launcher plugin contract — check the shell log (below) and compare
   `PresetSwitcherLauncher.qml` against
   `/usr/share/quickshell/dms/PLUGINS/LauncherExample/README.md`, which is the contract's
   reference copy. If `--list` comes up empty too, it's the presets that are missing — re-run
   `./install.sh` from your DankMango folder.

### The list shows "No presets found"
That row means the plugin is working and `set-preset.sh` returned nothing. Your presets folder
(`~/.config/mango/presets/`) is empty or gone. Re-run `./install.sh` — it re-copies every file,
where `update.sh` only re-copies what changed in its commit range.

### I pick a preset, the toast appears, but nothing changes on screen
Two possible causes, in order of likelihood.

1. **`config.conf` lost the include line.** `set-preset.sh` warns about this on every switch, but
   from the launcher you won't see its output — run it in a terminal to check:
   ```
   ~/.config/mango/scripts/set-preset.sh default
   ```
   Look for "has no preset include line". The fix is in that warning, or just re-run
   `./install.sh`. To check by hand, `config.conf` must contain:
   ```
   source-optional=~/.config/mango/active/preset.conf
   ```
   and it must be the **last** `source` line in the file.
2. **The reload command changed.** Test it:
   ```
   mmsg dispatch reload_config      # expect {"success":true}
   ```
   If it errors, MangoWM renamed the verb — find the new one with `mmsg --help` and update
   `mango_reload_config()` in `set-preset.sh`.

### The check mark is on the wrong preset
The `# preset:` line inside that preset's `preset.conf` doesn't match its folder name — most
often after copying a preset folder without editing the header. `set-preset.sh` warns about this
when you switch from a terminal. Fix the line, then switch again.

### Windows are clipped under the bar after switching to Minimal
That's the `gappov` bar-clearance rule, not this plugin. Run
`~/.config/mango/scripts/post-update-health.sh` — section 10 works out the number your bar needs
and tells you. Background: `~/.config/mango/presets/README.md`.

### The plugin won't load at all (after a DMS update)
Check the shell log (`~/.local/share/sddm/wayland-session.log`) for a line naming
`PresetSwitcherLauncher.qml`. After any edit run `dms restart`, then re-enable under DMS Settings
(`Ctrl+,`) → Plugins → **Preset Switcher**.

---

## Everyday tweaks

- **Moved your scripts?** update the `presetTool` property near the top of
  `PresetSwitcherLauncher.qml` (it's built from `$HOME`), then `dms restart`.
- **Prefer the terminal?** `set-preset.sh --list`, `set-preset.sh minimal`,
  `set-preset.sh minimal --dry-run` (shows exactly what would change, changes nothing).
- **Health check:** `post-update-health.sh` verifies the active-preset symlink still resolves and
  that the active preset clears the bar.
