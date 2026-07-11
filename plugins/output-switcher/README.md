# Audio Output Toggle — plain-English guide

A one-click bar button (a **speaker / headphones** icon) that switches your audio output.
Left-click **cycles to the next available output** (and wraps back to the first); the bar
icon updates and a toast names the device you just switched to.

It's **fully self-contained** — it talks to **PipeWire / WirePlumber** directly via `wpctl`,
with no external scripts and nothing hardcoded to a particular machine or device. It works
with however many outputs you have.

---

## How it works

Everything lives in this one plugin; there's no helper script to install.

| Piece | What it does |
|------|--------------|
| **The button** (this plugin, `AudioToggleBar.qml`) | On click, cycles the default sink to the next one; every few seconds re-reads the state to keep the icon correct. |
| **`wpctl status`** | How it lists the available sinks and finds which one is currently the default. |
| **`wpctl set-default <id>`** | How it switches — `<id>` is the WirePlumber node id parsed from `wpctl status`. |
| **DMS `ToastService`** | Shows the "Audio output → *device name*" toast on each switch (a native DMS toast, so it respects your notification settings). |

The bar icon is chosen by a simple heuristic on the current device's name — a
headphones-looking name shows the headphones glyph, everything else a speaker. No device
names are hardcoded.

---

## Requirements

- **PipeWire + WirePlumber** (provides `wpctl`) — already a base-install assumption for
  DankMango. Nothing else is needed (no `pipewire-pulse`/`pactl`, no personal scripts).

---

## Virtual sinks are filtered (and it's self-service to tune)

`wpctl` reports **every** sink PipeWire exposes, which on some setups includes **virtual**
sinks — an Easy Effects processing sink, a loopback, a monitor sink, a mic/interface that
also exposes a sink, a null/dummy output — that you don't want in the normal rotation.

So the plugin skips any sink whose **display name matches a name pattern** in a small,
editable **skip-list**. It lives near the top of `AudioToggleBar.qml` as:

```qml
readonly property var skipSinkPatterns: [
    "easy effects", "easyeffects",
    "monitor",
    "microphone",
    "loopback",
    "null", "dummy"
]
```

Matching is a **case-insensitive substring** test against the sink's display name, so
`"monitor"` skips `Monitor of Built-in Audio`, etc.

**If a virtual sink of yours still shows up in the cycle,** add a distinctive piece of its
name to that list. **If one of your real outputs is being skipped,** remove the pattern
that's catching it. Find the exact names in the **`Sinks:`** section of:

```
wpctl status
```

Then `dms restart` to pick up the change. (No need to file an issue — this is meant to be
edited locally.)

> **Why `iec958` isn't a default pattern:** real **S/PDIF** and **HDMI** outputs are commonly
> reported as `… (IEC958)`, so skipping that would hide a genuine output on many machines
> (including some onboard setups). Add `"iec958"` yourself only if none of your *real*
> outputs use it.

---

## Test / enable

1. Copy `plugins/output-switcher` into `~/.config/DankMaterialShell/plugins/`.
2. `dms restart`.
3. DMS Settings (`Ctrl+,`) → Plugins → enable **Audio Output Toggle**, and add it to your bar
   (Settings → Appearance → DankBar Layout).
4. With **two or more real outputs** available, click the pill → the default output changes,
   a toast shows the new device's name, and the icon updates. Click again to cycle to the
   next (it wraps around).
