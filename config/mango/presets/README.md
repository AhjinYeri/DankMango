# Desktop presets — how they work

A **preset** is a named bundle of MangoWM settings you can switch between as a unit —
tighter gaps and quicker animations, say — without editing `config.conf` and with nothing to
undo by hand afterwards.

DankMango ships two, on purpose: **Default** (adds nothing) and **Minimal** (tight gaps, quick
animations). Two is enough to prove the mechanism; the point is that adding your own is easy.

**The normal way to switch is the launcher.** Open it (`Super+Ctrl+Return`, or the launcher
button) and type **`preset`** — your presets are listed, the current one marked *Active*. Press
Enter on one to apply it. There is deliberately **no bar button**: switching presets is a
thing you do occasionally and on purpose, so it doesn't earn permanent space in the bar.
Everything below is for when you want to add one, or when something looks wrong.

---

## The mechanism, in four lines

1. Each preset is one self-contained config fragment: `~/.config/mango/presets/<name>/preset.conf`
2. `config.conf` includes exactly one fixed path, near the bottom:
   `source-optional=~/.config/mango/active/preset.conf`
3. That path is a **symlink**. Switching presets repoints it at a different preset's fragment.
4. `mmsg dispatch reload_config` applies it live.

Nothing is copied into `config.conf` and nothing is merged, so switching back is complete by
construction — there is no residue to miss. `source-**optional**` (rather than plain `source`)
means a missing or dangling link is not an error: you get baseline behaviour, not a broken
desktop.

The swap itself is atomic — the new link is written under a temp name and *renamed* into
place — so an interrupted switch can never leave `config.conf` pointing at a half-written
include.

`set-preset.sh` is the only thing that writes the symlink. It also remembers the active preset
in DankMango's install manifest (`.userPrefs.activePreset`), beside the other user choices.

---

## Adding your own preset

1. Make the folder and the fragment:

   ```
   mkdir -p ~/.config/mango/presets/myname
   cp ~/.config/mango/presets/minimal/preset.conf ~/.config/mango/presets/myname/preset.conf
   ```

2. Edit the **four header lines** at the top — they are read by `set-preset.sh` and by the
   launcher plugin, so they are not decoration. `preset:` must match the folder name; the
   format is `# key: value` with exactly one space after the `#`:

   ```
   # preset: myname
   # label: My Preset
   # icon: tune
   # blurb: One short line, shown as the subtitle in the launcher.
   ```

   `icon:` is a [Material Symbol](https://fonts.google.com/icons) name and is decorative — if
   your icon font doesn't have it the row still works, the label is what matters. The blurb is
   searchable, so put the words you'd actually type in it.

   Note the launcher marks the active preset with a check icon and an "Active" subtitle rather
   than a highlight — a launcher row has only an icon, a title and a subtitle to work with.

3. Put whatever `config.conf` settings you want below the header. Check it and switch:

   ```
   ~/.config/mango/scripts/set-preset.sh myname --dry-run
   ~/.config/mango/scripts/set-preset.sh myname
   ```

That's it — no QML to edit and no list to keep in sync. The launcher plugin asks `set-preset.sh`
for the list at runtime, and `set-preset.sh` derives it from the folders that actually exist.

---

## What a preset can and can't override

Presets are **compositor-only**. They change MangoWM settings in `config.conf` terms; they do
not touch DankMaterialShell's own theming or `settings.json`.

Within that, three rules follow from how mango reads its config. The preset is sourced **last**,
after every other `source=` line:

| | |
|---|---|
| **Plain settings** (gaps, animations, borders, layout tuning) | **The preset wins.** Last definition wins, and the preset is last. |
| **Keybinds** (`bind = ...`) | **The preset loses** for any key that is *already* bound. mango is first-bind-wins. A preset can add a *new* bind; it cannot rebind an existing one. |
| **Border colours** (`bordercolor` / `focuscolor` / `urgentcolor`) | **Don't set them here.** They belong to the wallpaper colour chain (`dms/colors.conf`), which is sourced earlier and, for colours, first-definition-wins. |

### The one thing that surprises people

DankMaterialShell writes `gappih` / `gappiv` / `gappoh` / `gappov`, `border_radius` and
`borderpx` into `~/.config/mango/dms/layout.conf` whenever you move the sliders in
**DMS Settings → Compositor Layout**. Your preset is sourced *after* that file — so a preset
that sets gaps **wins over the DMS slider**, and while it is active the slider appears to do
nothing.

That is intended: picking a preset is a deliberate choice and should beat an ambient slider.
But it looks exactly like a broken slider if you don't know. Three ways out, all fine:

* switch back to **Default** (which sets nothing, so the slider works again immediately);
* delete the `gapp*` lines from your preset and let it own only what DMS doesn't; or
* set DMS Settings → Compositor Layout → gaps to **unmanaged**, which stops DMS writing them
  at all and hands gaps to your config permanently.

This is also why **Default is an empty fragment** rather than a copy of the baseline numbers.
A copy would freeze today's values in and then override the DMS sliders forever.

### If you set gaps, leave room for the bar

The bar can **cover more pixels than it reserves**. DMS computes its exclusive zone (the strip
mango keeps windows out of) as `barThickness + spacing + bottomGap`, while the bar is drawn
`barThickness + spacing` tall — so if you have set the bar's **Gap** to a negative value, it
overhangs by exactly that much.

`gappov` (the outer *vertical* gap) is what covers the difference, which gives one rule:

> **`gappov` must be at least `-bottomGap`** whenever the bar's Gap setting is negative.

Set it lower and the bottom edge of every tiled window — border included — is drawn underneath
the bar. That is why the shipped **Minimal** preset uses `gappov = 18` while `gappoh` (the
horizontal one) is 6: nothing reserves space at the left and right edges, so only the vertical
gap has to make room. `post-update-health.sh` checks this rule against your actual bar settings
and tells you the number you need.

It does **not** vary with your display or font settings. The bar's thickness is a function of its
own **inner padding** and **spacing** only (`Theme.barHeight` is a hardcoded 48; font and icon
scale don't affect it), and both terms appear in the exclusive-zone *and* the visual-height
formula, so they cancel. Change the bar's size however you like — the overhang stays exactly
`-bottomGap`. Measured at two bar thicknesses (47px and 59px): the overhang was 15px at both.

---

## Commands

```
~/.config/mango/scripts/set-preset.sh --list              # what's installed, and what's active
~/.config/mango/scripts/set-preset.sh minimal --dry-run   # what would change; changes nothing
~/.config/mango/scripts/set-preset.sh minimal             # switch
~/.config/mango/scripts/set-preset.sh default             # switch back
```

`post-update-health.sh` checks that the active-preset symlink still resolves to a real file —
the one failure an update can introduce (a preset folder goes away, the link is left dangling,
and mango says nothing because the include is optional).

---

## Credit

The idea of swapping config fragments behind a native include line comes from
[ML4W's](https://github.com/mylinuxforwork/dotfiles) "Configuration Variations". DankMango's
implementation is its own — see [`CREDITS.md`](../../../CREDITS.md).
