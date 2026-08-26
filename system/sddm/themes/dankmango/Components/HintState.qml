// DankMango SDDM theme -- persistent state for the one-time hint.
//
// ---------------------------------------------------------------------------
// WHY THIS IS NOT IN theme.conf.user (checked first, deliberately)
// ---------------------------------------------------------------------------
// theme.conf.user is the established way this theme carries state across the
// greeter's privilege boundary, so it was the obvious candidate. It does not
// work here, for two independent reasons, and both are worth writing down so
// this does not get "simplified" back into it later:
//
//   1. IT IS READ-ONLY FROM IN HERE. That file is owned by the LOGIN USER and
//      the greeter runs as the `sddm` system user. The direction of travel is
//      user -> greeter, by design: install.sh hands the user a writable leaf
//      inside a root-owned directory precisely so the sync script can push into
//      it without elevation. The greeter has no write access to it at all, and
//      giving it any would mean making a file that the pre-auth QML executes
//      next to writable by the pre-auth QML -- which is the exact property the
//      whole install layout exists to prevent.
//
//   2. IT IS REGENERATED WHOLESALE. sddm-palette-sync.sh rewrites that file from
//      scratch on every wallpaper change. Even if a flag could be written there,
//      the next wallpaper change would drop it.
//
// So the question "does the existing layering already give us somewhere to keep
// this?" answers itself: no -- but it also turns out not to need one. The flag
// never has to CROSS the boundary. The greeter is what shows the hint and the
// greeter is what learns it is no longer needed, so the state can live entirely
// on the greeter's own side of the line, in the sddm user's own config
// directory, where writing it needs no elevation and grants nothing.
//
// That means no new cross-privilege mechanism, no second user-writable leaf in
// the theme directory, and no change to install.sh or to the sync script.
//
// ---------------------------------------------------------------------------
// WHERE IT ACTUALLY LANDS
// ---------------------------------------------------------------------------
// A file of our own, in the config directory of whoever is running the greeter:
//
//   in production   /var/lib/sddm/.config/dankmango-sddm.conf   (sddm's home)
//   in --test-mode  ~/.config/dankmango-sddm.conf               (yours)
//
// The test-mode split is a feature, not a leak: previewing the theme writes the
// flag into YOUR config, never into sddm's, so no amount of test-mode rendering
// can silently consume the real machine's first-boot hint.
//
// THE PATH IS SET EXPLICITLY, and that is worth a note because the obvious
// shorter version does not do what it looks like. Left to its own devices
// QSettings derives the filename from the application's organization and name,
// and the greeter sets no organization -- so it lands in a directory literally
// called "Unknown Organization", in a file shared with any other QSettings user
// in the same process, under a bare [General] section. `category:` does not
// rescue that: it was set here first and observed to be ignored, with the key
// still written to [General]. A generic key name in a shared file is a real
// collision risk, so the file is named here instead and the key has it to
// itself.
//
// Empty location falls back to QSettings' own default, which is what happens if
// the environment has no config directory to offer (no HOME). That degrades to
// "the flag never persists" -- see the failure direction discussed below.
//
// ---------------------------------------------------------------------------
// WHY IT IS ITS OWN FILE, LOADED THROUGH A Loader
// ---------------------------------------------------------------------------
// `import QtCore` is the only import in this theme that is not already proven to
// be present in the greeter's environment. A failed import is a FILE-LEVEL parse
// error -- it cannot be caught, and if it were in Main.qml it would take the
// entire login screen down with it. On the one screen you cannot fix from a
// session, a cosmetic hint is not worth that risk.
//
// Isolating it here and loading it via `Loader { source: ... }` bounds the blast
// radius exactly: if QtCore is missing, the Loader reports an error, `item`
// stays null, the hint never shows, and every other pixel on the screen renders
// as normal. Main.qml treats a null item as "no hint", which is the correct
// failure direction -- a hint that never appears is a missing nicety, a hint
// stuck on forever would be a permanent blemish.

import QtQuick 2.15
import QtCore

QtObject {
    id: state

    // Empty when the platform can offer no writable config directory; Settings
    // treats an empty location as "use your default", so this never resolves to
    // a nonsense path like "/dankmango-sddm.conf".
    readonly property url storePath: {
        var dir = StandardPaths.writableLocation(StandardPaths.GenericConfigLocation)
        if (!dir)
            return ""
        var s = dir.toString()
        if (s.length === 0)
            return ""
        return s + "/dankmango-sddm.conf"
    }

    // False until the first successful login has happened on this machine.
    readonly property bool hintPending: !store.hintShown

    // Called once from Main.qml on loginSucceeded. sync() is not optional here:
    // QSettings normally defers its write to an event-loop timer, and SDDM tears
    // the greeter down the moment authentication succeeds -- so without an
    // explicit flush the write would race the process exit and the hint would
    // come back on the next boot.
    function markShown() {
        if (store.hintShown)
            return
        store.hintShown = true
        store.sync()
    }

    property Settings store: Settings {
        location: state.storePath
        property bool hintShown: false
    }
}
