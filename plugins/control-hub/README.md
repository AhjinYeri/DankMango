# DankMango Hub — plain-English guide

One panel for the things DankMango adds to your desktop. Press the shortcut, it
opens; it stays open until you close it. Right now it holds one section, **Desktop
presets**, and it is built so the next one is two small edits away.

It is not a menu. Menus vanish the moment you look at something else — this is a
surface you can sit and read, click around in, and leave open while you go and
check whether the change did what you wanted.

---

## Opening and closing it

| What | How |
|---|---|
| Open / close | **SUPER+d**, which runs `dms ipc call controlhub toggle` |
| Close | the **✕** in the top-right |

Nothing else closes it. Clicking away leaves it alone, there is no timeout, and
Escape does nothing — the panel asks for no keyboard focus at all, which is also
why the keybind itself still works while the panel is up.

You can drive it by hand from a terminal, which is useful before a keybind is
chosen and useful again when something looks wrong:

```sh
dms ipc call controlhub toggle    # open if closed, close if open
dms ipc call controlhub open      # open; does nothing if already open
dms ipc call controlhub close     # close
```

> **`show` is not one of the words.** `dms ipc call <anything> show` is a *CLI
> verb* — it prints that target's list of functions instead of calling anything,
> and it does so successfully, so a typo here looks like it worked. The panel's
> functions are `open` / `close` / `toggle`, matching what DMS's own targets use.

## Which monitor it opens on

The focused one, re-checked on every open. It asks `mmsg get all-monitors` and
takes the monitor reporting `active: true`.

If that answer doesn't arrive within 800ms — mmsg missing, mmsg broken, mmsg
hanging — the panel opens anyway, on the **leftmost** monitor (ties broken by the
**largest**). That is the same fallback `monitor-watcher.sh` and the first-run
panel use, so "where DankMango stands when it can't tell" means one thing across
the whole project.

Two things it deliberately does *not* use, both checked rather than assumed:

* `CompositorService.getFocusedScreen()` returns null on mango — it only knows
  Hyprland and niri.
* `mmsg get focusing-client` carries a monitor name too, and is what the alt-tab
  switcher reads, but it is **empty when no window is focused**. "I just logged in
  and nothing is open yet" is an ordinary time to press this key. `all-monitors`
  always answers.

## Adding a section

This is the whole point of the thing. Two edits, neither to the layout code:

**1. Drop a QML file next to `ControlHubPanel.qml`**, e.g. `HealthSection.qml`.
It is an ordinary `Item` with two obligations:

```qml
Item {
    id: section
    property var hub: null                    // optional; filled in after loading
    implicitHeight: content.implicitHeight    // required; the card sizes off it

    Column { id: content; width: parent.width; /* ... */ }
}
```

**2. Add one entry to the `sections` array** in `ControlHubPanel.qml`:

```qml
{ "id": "health", "label": "Health check", "icon": "vital_signs", "source": "HealthSection.qml" }
```

That is it. The nav list is built from that array and the content area loads
`source` by name, so nothing in the shell knows how many sections there are or
what they are called. `PresetsSection.qml` is the worked example — copy its
shape.

`hub` gives a section access to the shell: `hub.panelOpen` (watch it to refresh
when the panel is re-opened, as the presets section does) and `hub.closePanel()`.

### What this deliberately isn't

A plugin framework. Sections are files in this folder, loaded by name. That is
the right amount of machinery for a panel with one section today, and the day it
needs sections that ship separately is the day to build more — not before.

## The check-native-first finding

DMS has two things that looked like they might already be this, and neither is:

**DMS's own Control Center** (`Modules/ControlCenter/`) takes plugins — set
`capabilities: ["control-center"]` and you get a toggle tile with an optional
detail dropdown. It was the closer of the two, and it is the wrong shape here for
three measured reasons: `ControlCenterPopout.qml` does `onBackgroundClicked:
close()`, so it is not a surface you can browse; it needs a *bar widget* plugin,
which DMS instantiates once per bar per screen; and growth means more separate
tiles in DMS's grid rather than sections of one branded thing. It remains a fine
home for a future one-tap toggle — it is just not a hub.

**DMS's Settings window** is the right *shape* — a list of sections down the left,
the chosen one filling the rest — and this panel copies that shape on purpose,
because it is the navigation people have already met in this desktop. Its nav
model is even the same idea as the registry above: `SettingsSidebar.qml` holds a
`categoryStructure` array of `{id, text, icon, tabIndex}`.

What is **not** copied is how it joins the two halves. `SettingsContent.qml` is
722 lines of

```qml
Loader { active: root.currentIndex === 37; sourceComponent: CompositorLayoutTab {} }
```

— one hand-written branch per tab, keyed on a magic number, so adding a section
means editing the shell's core layout and picking an unused integer. This panel
maps `id → filename` and loads it, which is the same navigation with the coupling
taken out. That was the one place it was worth departing from the native pattern,
and it is why.

## Why it's a "daemon" plugin

Bar widgets are instantiated **once per bar per screen**. That matters here
because this plugin registers an `IpcHandler`, and quickshell **segfaults — takes
the whole shell down —** when an IPC target has a duplicate handler and something
calls it. The alt-tab switcher is a bar widget and has to hide its handler behind
an "am I on the first screen?" gate to survive this.

A daemon plugin needs no such gate: DMS keeps exactly one instance per plugin id
(`Services/PluginService.qml`, `pluginDaemonInstances`), so the handler sits at
the root of the file where you can see it. Same reasoning as the first-run panel,
which is a daemon for the same underlying reason.

## Why it's a bare `PanelWindow` and not a `DankModal`

Paid for once already by the first-run panel; its README has the long version.
Short: `DankModal` makes its surface the size of the whole output (so every click
on that monitor lands on it) and takes a keyboard grab on anything that isn't
Hyprland. Neither is fixable by setting properties. A bare `PanelWindow` the size
of the card, masked to the card, asking for no keyboard focus, has neither problem
by construction — and it is DMS's own `DankOSD.qml` shape.

## Requirements

* `mmsg` — for opening on the focused monitor. Missing it costs you the *right*
  monitor, never the panel.
* `~/.config/mango/scripts/set-preset.sh` — the presets section's entire backend.

## Troubleshooting

### The keybind does nothing

Check the panel is reachable at all:

```sh
dms ipc call controlhub toggle
```

* prints `ok` → the plugin is fine; the problem is the bind line in `config.conf`.
* prints a list of functions → you typed `show`. See the box near the top.
* errors → the plugin isn't loaded. Check `controlHub` is enabled in
  `~/.config/DankMaterialShell/plugin_settings.json`, then `dms restart`.

### It opens on the wrong monitor

```sh
mmsg get all-monitors | jq -r '.monitors[] | "\(.name) active=\(.active)"'
```

Exactly one should say `active=true`, and it should be the one you're looking at.
If none does, or mmsg errors, the panel is on its leftmost-monitor fallback and
that is the thing to fix.

### The right-hand side says "Couldn't load …"

The section file named in the registry didn't load — renamed file, typo in
`source`, or a QML error inside the section. The message names the file it tried.

### Presets: the list is empty, or a switch does nothing

That is the script, not this panel — see
`plugins/preset-switcher/README.md`, which covers the same backend from the
launcher side. Quick check:

```sh
~/.config/mango/scripts/set-preset.sh --list --porcelain
```

Five tab-separated fields per line, one line per preset. No output means no
presets; different fields mean the script and `PresetsSection.qml` have drifted
apart.

### After editing this plugin

```sh
dms restart
```

A plain re-toggle reuses a cached copy of the QML.

## Why the launcher preset plugin still exists

`plugins/preset-switcher/` puts the same presets in DMS's launcher — open it,
type `preset`, pick one — and it is staying. It is the fast path for someone who
already knows what they want, and it costs no bar space and no keybind.

This is the other half: a surface you can *look* at. A launcher row gets an icon,
a name and a subtitle, and then the launcher closes the instant you choose — so it
can never show you one preset's description next to another's, and it can never
show you the switch taking effect. Here the cards sit side by side, the active one
is visibly the active one, and the panel is still open afterwards to prove the
check mark moved.

Both front-ends call the same script with the same arguments. Neither knows the
other exists.
