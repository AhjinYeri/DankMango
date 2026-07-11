# Alt-Tab Switcher — plain-English guide

When you hold **Alt** and tap **Tab**, a panel appears in the middle of your
focused monitor showing every open window as a card (app icon + name + title),
with the window you're about to switch to **highlighted**. Alt+Shift+Tab goes
backwards. Stop tapping and it fades away on its own.

It's styled to match your other DMS surfaces (frosted, dynamic wallpaper colors).
It does **not** show live thumbnails — that's not practical on Wayland — just
icons and titles, on purpose.

---

## How the whole thing fits together (3 pieces)

You don't need to understand the code — just know which file does what, so if
something breaks you know where to look.

| Piece | File | What it does |
|------|------|--------------|
| **The popup** (this plugin) | `~/.config/DankMaterialShell/plugins/altSwitcher/AltSwitcherBar.qml` | The visual panel only. Holds **no focus-switching logic** — it just draws the window list and highlights the focused one. |
| **The wiring** | `~/.config/mango/scripts/alt-switcher.sh` | What Alt+Tab actually runs. Does two things: cycles window focus (mango), then tells the popup to show/refresh. |
| **The keybinds** | `~/.config/mango/config.conf` | Two lines bind `ALT, Tab` and `ALT+SHIFT, Tab` to the wiring script (search the file for `alt-switcher.sh`). |

**How they talk:** Alt+Tab → the wiring script → (a) `mmsg dispatch focusstack`
changes focus, (b) `dms ipc call altswitcher next` pokes the popup. The popup then
reads the window list from mango (`mmsg get all-clients`) and highlights whichever
window is now focused.

**Both the plugin and the script have a clearly-marked box at the top called
`EDIT HERE AFTER A DMS / MANGO UPDATE`.** That box lists every command, DMS
building block, and keyword an update could change. You almost never need to touch
anything outside it.

---

## "It broke after a system update" — what to check

First, restart the shell so you're testing the real current state (a plain
off/on plugin toggle reuses a cached copy and won't pick up edits):
```
dms restart
```

### Symptom: Alt+Tab changes focus, but NO popup appears
The focus half works, so the problem is the popup half.

1. Test the popup directly in a terminal:
   ```
   dms ipc call altswitcher show
   ```
   - Prints `ok` and the panel appears → the plugin is fine; the problem is the
     wiring script or the keybind (next two symptoms).
   - Errors / prints nothing → the plugin isn't loaded (see "popup vanished" below).

### Symptom: the popup appears, but window focus DOESN'T cycle
The popup half works; mango's focus command changed.

1. Open `~/.config/mango/scripts/alt-switcher.sh`, find `mango_cycle_focus()` in
   the EDIT-HERE box.
2. Test its command by hand:
   ```
   mmsg dispatch focusstack,next      # expect {"success":true}
   ```
   If it errors, mango renamed the action — run `mmsg --help` for the new form
   and update the function.

### Symptom: NOTHING happens on Alt+Tab (no focus change, no popup)
The keybind or the script path is broken.

1. Check the binds still point at the script:
   ```
   grep alt-switcher.sh ~/.config/mango/config.conf
   ```
   You should see the `ALT, Tab` and `ALT+SHIFT, Tab` lines. If missing, a config
   reset dropped them — re-add them (see "Everyday tasks" below).
2. Make sure the script is runnable: `ls -l ~/.config/mango/scripts/alt-switcher.sh`
   (needs the `x` permission; fix with `chmod +x`).
3. Reload mango: **Super+R**.

### Symptom: the popup shows but with the WRONG windows / no highlight
The plugin reads mango's window list; a field got renamed.

1. Look at what mango reports:
   ```
   mmsg get all-clients
   ```
2. The plugin uses exactly these fields per window: `title`, `appid`,
   `is_focused`, `monitor`. If any is renamed in that JSON, update the matching
   name in the `Process`/`onStreamFinished` section of `AltSwitcherBar.qml`
   (all four are called out in comments), then `dms restart`.

### Symptom: the popup appears BEHIND floating windows
The overlay layer setting was lost. In `AltSwitcherBar.qml`, the `DankModal` block
must have `useOverlayLayer: true` (there's a comment explaining why). Restore it,
then `dms restart`.

### Symptom: pressing Alt+Tab CRASHES the whole shell (bar + everything disappears)
This happened once, after a **quickshell** update (bundled in a mango/system
update: `quickshell 0.3.0-1 → 0.3.0-2`). Cause: a DankBar plugin loads **once per
monitor**, so the plugin was registering the `altswitcher` IPC handler twice; the
newer quickshell **segfaults** when an IPC target has a duplicate handler and it's
invoked. The older one only logged a warning.

The fix (already in `AltSwitcherBar.qml`): the IPC handler + popup live inside a
`Loader` (`engine`) that is active on **only one** instance — the one whose bar is
on the primary screen (`isPrimaryInstance`). If this ever regresses:

1. Confirm it's the duplicate handler — look in the shell log:
   ```
   grep 'another handler is registered for target altswitcher' /run/user/$(id -u)/quickshell/by-id/*/log.log
   ```
   If that line is present, two handlers are registering again.
2. In `AltSwitcherBar.qml`, make sure the `IpcHandler`/`DankModal` are still inside
   the `engine` Loader and that `isPrimaryInstance` resolves `true` for exactly one
   instance (it needs `parentScreen.name` to equal `Quickshell.screens[0].name`).
   **Never** put the `IpcHandler` back at the plugin root.
3. Test the fix safely from a terminal *before* pressing Alt+Tab (it drives the same
   IPC path without touching focus):
   ```
   dms ipc call altswitcher next    # expect "ok", shell stays alive
   ```

### Symptom: the popup vanished entirely, or won't load (after a DMS update)
The plugin failed to load, usually because DMS renamed a building block.

1. Read the shell's error log for the offending line:
   ```
   grep -iE 'altSwitcher|AltSwitcherBar' ~/.local/share/sddm/wayland-session.log | tail
   ```
   (or the live log under `/run/user/$(id -u)/quickshell/by-id/*/log.log`)
   Look for a line naming `AltSwitcherBar.qml` and a property/type it didn't like.
2. Cross-check it against section **A/B** of the EDIT-HERE box at the top of
   `AltSwitcherBar.qml` — those list every DMS import, `DankModal` property, and
   `Theme` color the plugin uses. Fix the renamed one.
   - Known gotcha: `DankIcon` uses `size:`, **not** `font.pixelSize:`.
3. `dms restart`, then re-enable if needed: DMS Settings (`Ctrl+,`) → Plugins →
   "Alt-Tab Switcher" on, and confirm it's in the bar (Settings → Appearance →
   DankBar Layout). *(The bar pill is only a manual toggle/health-check button;
   Alt+Tab works without looking at it.)*

---

## Everyday tasks

- **Change how long it stays up after your last Tab:** edit `interval:` on the
  `idleHide` Timer in `AltSwitcherBar.qml` (milliseconds; currently `1200`), then
  `dms restart`.
- **Change card size / panel width:** `modalWidth` and the card `height:` in the
  `DankModal` block, then `dms restart`.
- **Re-add the keybinds** (if a config reset dropped them):
  ```
  bind = ALT, Tab, spawn, ~/.config/mango/scripts/alt-switcher.sh next
  bind = ALT+SHIFT, Tab, spawn, ~/.config/mango/scripts/alt-switcher.sh prev
  ```
  then **Super+R**.
- **An app shows the generic fallback icon** (a plain window glyph): its `appid`
  didn't match a desktop entry. Check the `appid` with `mmsg get all-clients`; the
  fix is usually a `.desktop` file whose name matches, not a plugin change.

## Enable/disable safely
This plugin is enabled by two entries: `"altSwitcher"` in
`~/.config/DankMaterialShell/plugin_settings.json` and an `{"id":"altSwitcher"}`
line in a `*Widgets` array in `settings.json`. To fully disable, remove the block
from `plugin_settings.json` (fast, leaves files intact).
