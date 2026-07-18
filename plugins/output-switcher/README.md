# Audio Output Toggle — plain-English guide

A one-click bar button (a **speaker / headphones** icon) that switches your audio output.
Left-click **cycles to the next available output** (and wraps back to the first); the bar
icon updates and a toast names the device you just switched to.

It's **zero-config by default** — it talks to **PipeWire / WirePlumber** directly via `wpctl`,
with no external scripts and nothing hardcoded, and works with however many outputs you have.

For hardware where your outputs aren't separate sinks but separate **card profiles** (e.g.
digital **S/PDIF** speakers vs the **analog headphone jack** on one card), there's an optional
per-machine mapping that switches by profile instead — see **[Named targets](#named-targets--for-card-profile-hardware)** below.

---

## How it works

Everything lives in this one plugin; there's no helper script to install.

| Piece | What it does |
|------|--------------|
| **The button** (this plugin, `AudioToggleBar.qml`) | On click, cycles the default sink to the next one; every few seconds re-reads the state to keep the icon correct. |
| **`wpctl status`** | How it lists the available sinks and finds which one is currently the default. |
| **`wpctl set-default <id>`** | How it switches — `<id>` is the WirePlumber node id parsed from `wpctl status`. |
| **DMS `ToastService`** | Shows the "Audio output → *device name*" toast on each switch (a native DMS toast, so it respects your notification settings). |

The bar icon is chosen by a simple heuristic on the current output's name/label — a
headphones-looking name shows the headphones glyph, everything else a speaker. No device
names are hardcoded.

---

## Two modes (chosen automatically)

The plugin has **two switching mechanisms** and picks one based on whether you've configured
a named-targets mapping (see below):

| Mode | When | How it switches |
|------|------|-----------------|
| **Sink cycling** (default, zero-config) | No `outputTargets` configured | `wpctl set-default <id>` across enumerated real sinks. Best for genuinely independent sinks — USB DAC, HDMI, onboard, etc. |
| **Profile cycling** (opt-in, per-machine) | `outputTargets` present & non-empty | `pactl set-card-profile <card> <profile>` across your named targets. Needed when "speakers" and "headphones" are two **card profiles** on one card (only one sink exists at a time, so sink cycling has nothing to switch to). |

---

## Requirements

- **PipeWire + WirePlumber** (provides `wpctl`) — already a base-install assumption for
  DankMango. This covers the default **sink-cycling** mode with no other dependencies.
- **`pactl`** (from `libpulse` / `pipewire-pulse`) — only needed if you use the optional
  **profile-cycling** mode (named targets). Most PipeWire setups already have it.

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

## Named targets — for card-profile hardware

Some cards don't expose your outputs as separate sinks at all. A common case: **one** sound
card whose **digital S/PDIF output** ("speakers") and **analog headphone jack** ("headphones")
are two mutually-exclusive **card profiles** — only one produces a sink at a time. There's
nothing for sink-cycling to switch *to*, so the default mode gets stuck on one output.

For these, add an **`outputTargets`** mapping. When it's present and non-empty, clicking the
pill cycles through *your* named targets and applies each with `pactl set-card-profile`,
toasting the target's label. It lives in
`~/.config/DankMaterialShell/plugin_settings.json`, under this plugin's id (`audioToggle`):

```json
{
  "audioToggle": {
    "enabled": true,
    "outputTargets": [
      { "label": "Speakers",
        "card": "alsa_card.pci-0000_0d_00.4",
        "profile": "output:iec958-stereo+input:analog-stereo" },
      { "label": "Headphones",
        "card": "alsa_card.pci-0000_0d_00.4",
        "profile": "output:analog-stereo+input:analog-stereo" }
    ]
  }
}
```

Each entry is:

| Key | Meaning |
|-----|---------|
| `label` | What the toast shows, and what drives the icon (a `headphone`/`headset`-looking label gets the headphones glyph). |
| `card` | The ALSA card name — the `Name:` line in `pactl list cards`. |
| `profile` | The exact profile name to activate — one of the entries under that card's `Profiles:` list. The profile **name** is used (stable), not `wpctl`'s numeric index. |

**Find your values** with:

```
pactl list cards
```

Look at the target card's `Name:`, then pick the two `Profiles:` entries that correspond to
your outputs (e.g. `output:iec958-stereo+input:analog-stereo` for digital,
`output:analog-stereo+input:analog-stereo` for the analog jack). You can list **more than
two** targets; clicking just cycles through them in order and wraps around.

> **This mapping is machine-specific** (card and profile names differ per box), so DankMango
> **ships without it** — a fresh install defaults to zero-config sink cycling. Add it by hand
> only if your hardware needs it. After editing, `dms restart`.

---

## Test / enable

1. `install.sh` installs this for you (stage 14) — into `~/.config/DankMaterialShell/plugins/audioToggle/`,
   named for the plugin **id** from `plugin.json`, not the repo folder name. To install it by
   hand, copy `plugins/output-switcher/` to that `audioToggle` path; DMS keys off the id, so
   copying it under the repo's own directory name won't load.
2. `dms restart`.
3. DMS Settings (`Ctrl+,`) → Plugins → enable **Audio Output Toggle**, and add it to your bar
   (Settings → Appearance → DankBar Layout). It ships pre-registered, so this is usually
   already done.
4. With **two or more real outputs** available, click the pill → the default output changes,
   a toast shows the new device's name, and the icon updates. Click again to cycle to the
   next (it wraps around).
