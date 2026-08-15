// =============================================================================
//  FirstRunPanel.qml  --  the one-time "here's where to start" panel
// =============================================================================
//
//  >>> IF SOMETHING STOPPED WORKING AFTER A DMS UPDATE, START HERE <<<
//
//  Everything version-specific is in the ONE box below marked
//  "########## EDIT HERE AFTER A DMS UPDATE ##########". Fix the paths and
//  commands there to match the new version; the rest is plain QML.
//
// -----------------------------------------------------------------------------
//  WHAT THIS DOES (plain English)
// -----------------------------------------------------------------------------
//  On a brand-new install it opens once, says hello, tells you about the help
//  hub, and offers the handful of things actually worth doing first. Every one of
//  those actions leaves the panel where it is -- only "Got it" closes it, and only
//  "Got it" writes the marker. Dismiss it and it never comes back.
//
//  WHY A "daemon" PLUGIN AND NOT A BAR WIDGET: the other three DankMango plugins
//  are bar widgets, which are instantiated once PER BAR PER SCREEN. This has no
//  bar presence at all and must exist exactly once, so it uses DMS's `daemon`
//  surface -- "any Item exposing pluginService / pluginId, instantiated once"
//  (PLUGINS/README.md). PluginComponent is the root anyway, matching DMS's own
//  ExampleCompositePlugin/CompositeDaemon.qml.
//
//  WHY ITS OWN STATE FILE rather than DMS's .firstlaunch: DMS has a first-launch
//  greeter of its own (FirstLaunchService + GreeterModal), but its check is
//  "marker missing AND settings.json missing = first launch". DankMango's
//  installer DEPLOYS settings.json, so by the time DMS first starts it classifies
//  the user as an existing one, silently writes .firstlaunch, and never shows its
//  greeter. Hooking that flag would therefore never fire. See the README.
//
//  THE SHOW/HIDE RULE, once: absence of the state file means show. The file is
//  written on dismiss, and only on dismiss -- an install that never reaches a
//  running shell must still get its welcome on the next login.
//
//  WHICH MONITOR IT OPENS ON: the one chosen as the GAME DISPLAY at install time
//  (.userPrefs.mainDisplay in the manifest -- the key keeps its old name, only the
//  words shown to people changed). See "SCREEN TARGETING" further down.
//
// -----------------------------------------------------------------------------
//  WHY THIS IS A BARE PanelWindow AND NOT A DankModal  (read before "fixing" it)
// -----------------------------------------------------------------------------
//  It used to be a DankModal on the overlay layer. Two things were wrong with
//  that and neither was fixable by tuning DankModal's properties:
//
//    1. THE SURFACE COVERED THE WHOLE MONITOR. DankModalStandalone computes
//       `useSingleWindow = isHyprland || useBackground`, and useBackground is
//       `showBackground && ... && SettingsData.modalDarkenBackground` -- both on
//       by default. With useSingleWindow true the content window anchors all four
//       edges, so the surface is the size of the OUTPUT and every click on that
//       monitor lands on us.
//    2. IT HELD A KEYBOARD GRAB. Left to itself DankModal asks Common/
//       KeyboardFocus.qml, which returns WlrKeyboardFocus.Exclusive on anything
//       that isn't Hyprland -- a layer-shell grab, which is why you could not
//       type in the guide terminal this panel had just opened.
//
//  Both are avoided here by construction rather than by configuration: the
//  surface is only as big as the card (and masked to it, so even the shadow
//  margin isn't ours), and it asks for no keyboard focus at all. The structure is
//  DMS's own DankOSD.qml -- a bare PanelWindow that sits over everything without
//  being in the way -- because that is the house pattern for exactly this shape
//  of surface.
//
//  >>> WHAT DOES **NOT** WORK, MEASURED ON THIS MACHINE -- DO NOT RE-TRY <<<
//
//  The plan this replaced assumed mango would let the panel "hide behind" the
//  windows its own buttons open, because mango raises a focused FLOATING window
//  above the Top layer. That is true, and it is irrelevant here: the windows
//  these buttons open are TILED (both monitors run tile/monocle layouts), and a
//  layer-shell surface on Top sits above every tiled toplevel. Screenshotted and
//  confirmed -- a Top-layer panel covers a tiled terminal, full stop.
//
//  Three follow-on dead ends, all tested rather than reasoned about:
//    * Layer Bottom does hide the panel behind toplevels -- but the switch back
//      to Top NEVER takes effect (0/3 trials, 6s timeout each). One-way only, so
//      "drop to Bottom while busy" cannot come back up.
//    * A real toplevel (Quickshell FloatingWindow) IS a mango client and can be
//      focused with `mmsg dispatch focusid client,<id>` -- but once floated it
//      stays above tiled windows no matter who has focus, so it does not hide
//      either; and unfloated it joins the tiling layout and stops being a card.
//    * `mmsg dispatch focusid client,<N>` cannot target this panel at all. Layer
//      -shell surfaces are not mango clients and never appear in
//      `mmsg get all-clients`, so there is no id to aim at. This is why the
//      refocus below is a visibility toggle and not a focus dispatch.
//
//  So the panel GETS OUT OF THE WAY by hiding itself while something it launched
//  is on screen, and comes back when that thing exits. With a fullscreen-tiled
//  terminal -- the actual case on monocle -- that is indistinguishable from
//  sitting behind it, and unlike "behind" it is reliable in both directions
//  (measured: ~0.3s to hide, ~0.7s to come back, 3/3 trials).
// =============================================================================

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland     // WlrLayer / WlrKeyboardFocus -- see the window below
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // #########################################################################
    // ########## EDIT HERE AFTER A DMS UPDATE #################################
    // #########################################################################

    // --- 1. STATE FILE -------------------------------------------------------
    // Lives beside the install manifest in XDG state, NOT in config: it is
    // runtime state, it must survive a config re-deploy, and update.sh must never
    // route a repo file over the top of it. Empty marker; only existence matters.
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/dankmango"
    readonly property string stateFile: stateDir + "/first-run-complete"

    // The install manifest, read once at startup for two display-only facts: which
    // monitor to open on, and what version to print in the corner. Both are
    // best-effort -- see the probe below.
    readonly property string manifestFile: stateDir + "/manifest.json"

    // --- 2. THE THINGS THE BUTTONS DO ---------------------------------------
    // Each is exactly what the matching keybind in config.conf runs, so there is
    // one behaviour to keep working, not two. If a bind changes, change it here.
    //
    //   help hub    <- SUPER+SHIFT+/   (a TUI, so it needs a terminal)
    //   wallpaper   <- SUPER+w         (clean IPC, no terminal)
    //
    //   health check <- no bind; the same script update.sh tells you to run
    //
    // NOTE the `exec` on the terminal ones. These are run as tracked Process
    // objects now (see "LAUNCHING" below), and this panel decides it is busy for
    // exactly as long as that Process lives. Without exec, `sh` would linger as a
    // parent around alacritty and the timing would still work -- but with exec the
    // sh IS the terminal, so "process exited" and "window closed" are the same
    // event rather than two events that usually coincide.
    readonly property var cmdHelpHub: ["sh", "-c", "exec alacritty -e ~/.config/mango/scripts/docs-hub.sh"]
    readonly property var cmdWallpaper: ["sh", "-c", "dms ipc call dash toggle wallpaper"]

    // The health check is a REPORT, not a TUI: it prints and exits, so unlike the
    // help hub it would flash a terminal open and shut on a machine where
    // everything passes -- which is the machine most people clicking this have.
    // The `read` holds the window open so the report can actually be read. It
    // does not change what runs: the script keeps its own stdin (`[ -t 0 ]` is
    // still true), so its end-of-run re-apply prompts still work.
    readonly property var cmdHealthCheck: ["sh", "-c", `exec alacritty -e sh -c '"$HOME"/.config/mango/scripts/post-update-health.sh; echo; printf "Press Enter to close. "; read _'`]

    // The game-display selector is whiptail (a TUI), so it ALSO needs a terminal,
    // and it lives in the repo rather than in ~/.config -- so we have to find the
    // repo first. The manifest records where it was installed from; if that is
    // missing or the clone has moved, we say so instead of failing silently.
    // This is the weakest of the three paths, which is why it sits last.
    // Reports its own failure with notify-send rather than back through stdout:
    // nothing reads these processes' output, only their exit.
    //
    // NOTE the flag is still --reselect-main-display: only the WORDS changed, never
    // the flag, the manifest key, or the generated file. Renaming a flag breaks
    // muscle memory and anyone's scripts for no gain.
    readonly property var cmdGameDisplay: ["sh", "-c", `
        M="\${XDG_STATE_HOME:-$HOME/.local/state}/dankmango/manifest.json"
        R="$(jq -r '.dankmango.repoDir // empty' "$M" 2>/dev/null)"
        if [ -n "$R" ] && [ -f "$R/install.sh" ]; then
            exec alacritty -e bash "$R/install.sh" --reselect-main-display
        fi
        notify-send "DankMango" "Couldn't find the DankMango folder. Run it yourself: ./install.sh --reselect-main-display"
    `]

    // #########################################################################
    // ########## END OF THE VERSION-SPECIFIC BOX ##############################
    // #########################################################################

    property bool checked: false

    // Filled in by the startup probe below. Both are DISPLAY-ONLY: nothing here
    // decides whether the panel appears, so an unreadable manifest (or no jq)
    // costs a nicety, never the welcome itself.
    property string buildVersion: ""      // .dankmango.version -- git describe output
    property string gameDisplayName: ""   // .userPrefs.mainDisplay -- a monitor name
    property var panelScreen: null        // resolved live screen, see resolveScreen()

    // ---- THE ONE PIECE OF OPEN/CLOSE STATE ----------------------------------
    // Replaces DankModal's open()/close(). It is set true in exactly one place
    // (the probe, when the marker is absent) and false in exactly one place
    // (dismiss(), behind "Got it").
    //
    // "ONLY GOT IT DISMISSES THE PANEL" IS NOW TRUE BY CONSTRUCTION, not by
    // convention. Under DankModal it took a property to defend -- ModalManager
    // treats modals as mutually exclusive, so opening DMS's dash fired
    // closeAllModalsExcept() and evicted us unless allowStacking was set. There is
    // no ModalManager in this file any more, nothing else can write panelOpen,
    // there is no background click-catcher, and the window asks for no keyboard
    // focus so Escape never reaches it. Nothing but "Got it" can put it down.
    property bool panelOpen: false

    // ---- GETTING OUT OF THE WAY ---------------------------------------------
    // Hidden-but-still-open, for as long as something this panel launched is on
    // screen. See the header for why this is a visibility toggle rather than a
    // stacking or focus trick (short version: measured, the alternatives do not
    // work on mango). NEITHER of these touches panelOpen -- the panel is still
    // open the whole time, it is just not drawn.
    //
    //   spawnedRunning -- count, not a bool: the buttons are deliberately not
    //                     mutually exclusive, so two terminals can be open at
    //                     once and the panel must stay hidden until the LAST
    //                     one goes. Guarded so it can never go negative.
    //   popoutActive   -- a DMS popout (the wallpaper dash) is up on our monitor;
    //                     see the PopoutManager block near the bottom.
    property int spawnedRunning: 0
    property bool popoutActive: false
    readonly property bool outOfTheWay: spawnedRunning > 0 || popoutActive

    // The version, cut down to something a first-time user can read.
    //
    // buildVersion holds raw `git describe --tags --always --dirty` output, which on
    // any install that isn't sitting exactly on a tag looks like
    // "v1.1.0-27-g58c5fe0-dirty". That is the right thing to STORE -- it says exactly
    // which commit you're on, and post-update-health and anything else reading the
    // manifest wants all of it -- but it is the wrong thing to greet someone with.
    //
    // The cut is "everything before the first hyphen", which works because DankMango's
    // tags are plain vX.Y.Z with no hyphen in them (v1.0.0 ... v1.3.0). Everything
    // describe appends -- the commit count, the g-hash, -dirty -- comes after one.
    //
    // The three inputs this has to survive, all real:
    //   "v1.1.0-27-g58c5fe0-dirty" -> "v1.1.0"   (a working clone, the usual case)
    //   "v1.3.0"                   -> "v1.3.0"   (clean checkout sitting on a tag)
    //   ""                         -> ""         (no jq / unreadable manifest / v1-era
    //                                             manifest -- the footer hides itself)
    // A repo with no tags at all describes as a bare hash ("58c5fe0"), which has no
    // hyphen either and so passes through untouched. That's the honest answer for it.
    //
    // DISPLAY ONLY. Nothing writes this back: the manifest keeps the full string, and
    // buildVersion above still holds it for anything else that ever wants it.
    readonly property string displayVersion: {
        const v = root.buildVersion
        const cut = v.indexOf("-")
        return cut === -1 ? v : v.substring(0, cut)
    }

    // ---- SCREEN TARGETING ---------------------------------------------------
    // Same resolution logic as before -- only the property it feeds changed, from
    // DankModal.targetScreen to PanelWindow.screen. The name -> live screen lookup
    // is the same one CompositorService.getFocusedScreen() does (walk
    // Quickshell.screens, match on .name), because that is the only mapping there
    // is; there's no shared helper in DMS to call instead.
    //
    // FALLBACK, deliberately copied from monitor-watcher.sh's fallback_main_display:
    //   LEFTMOST, ties broken by LARGEST  (its `sort -k2,2n -k3,3nr` on x then width)
    // Same rule in both places means "the monitor DankMango stands in when your
    // choice is gone" has exactly one definition. Reached when nothing is stored
    // (choosing is skippable at install time) or when the stored monitor is
    // unplugged. Only returns null when there are no screens at all, which is the
    // one case PanelWindow's own default has to cover.
    function resolveScreen(name) {
        const screens = Quickshell.screens
        if (!screens || screens.length === 0)
            return null
        if (name) {
            for (let i = 0; i < screens.length; i++) {
                if (screens[i].name === name)
                    return screens[i]
            }
        }
        let best = screens[0]
        for (let i = 1; i < screens.length; i++) {
            const s = screens[i]
            if (s.x < best.x || (s.x === best.x && s.width > best.width))
                best = s
        }
        return best
    }

    // Monitor hotplug. DankModalStandalone had its own onScreensChanged handler;
    // that went with it, so the same job is done here. Re-resolving rather than
    // hiding (which is what DankOSD does) because a welcome panel that vanishes
    // when you unplug a monitor has silently spent the user's one and only
    // welcome -- it should walk to whatever screen is left instead.
    Connections {
        target: Quickshell
        function onScreensChanged() {
            if (!root.panelOpen)
                return
            root.panelScreen = root.resolveScreen(root.gameDisplayName)
        }
    }

    // ---- STARTUP PROBE ------------------------------------------------------
    // One shell call answers all three startup questions, so there is one process,
    // one result, and no race between "should I show?" and "where?".
    //
    // Field 1 (show/skip) is the ONLY one that gates anything, and it is decided by
    // `test -f` alone -- no jq, no manifest. Anything unexpected is treated as
    // "already seen": a welcome panel that wrongly reappears is far more annoying
    // than one that wrongly stays away, so the uncertain case fails to quiet.
    //
    // Fields 2 and 3 come from the manifest and are allowed to be empty: a machine
    // without jq, a v1-era manifest, or an install that skipped the game-display
    // question all land here, and all three are ordinary states rather than faults.
    //
    // \${...} is escaped because this is a JS template literal -- unescaped, QML
    // would try to interpolate the shell's parameter expansion. Same idiom as
    // cmdGameDisplay above.
    Process {
        id: startupProbe
        running: false
        command: ["sh", "-c", `
            [ -f '` + root.stateFile + `' ] && seen=skip || seen=show
            ver=""; disp=""
            if command -v jq >/dev/null 2>&1 && [ -r '` + root.manifestFile + `' ]; then
                ver="$(jq -r '.dankmango.version // empty' '` + root.manifestFile + `' 2>/dev/null)"
                disp="$(jq -r '.userPrefs.mainDisplay // empty' '` + root.manifestFile + `' 2>/dev/null)"
            fi
            printf '%s\t%s\t%s\n' "$seen" "$ver" "$disp"
        `]
        stdout: SplitParser {
            onRead: data => {
                root.checked = true
                const f = data.trim().split("\t")
                root.buildVersion = f[1] || ""
                root.gameDisplayName = f[2] || ""
                if (f[0] === "show") {
                    // Resolve at open time, not at load time: hotplug between shell
                    // start and here would otherwise leave us holding a dead screen.
                    root.panelScreen = root.resolveScreen(root.gameDisplayName)
                    root.panelOpen = true
                }
            }
        }
    }

    // ---- LAUNCHING THE THREE TERMINALS --------------------------------------
    // These are tracked Process objects, NOT execDetached, and that reversal is
    // deliberate -- read this before changing it back.
    //
    // The original code used execDetached for everything, for a real reason: a
    // Process started from a click handler died when the panel closed, because the
    // handler tore down the surface the Process object lived on. That failure mode
    // is GONE, and specifically because of the container swap, not because someone
    // decided to risk it:
    //
    //   * these Process objects are children of root (the PluginComponent), which
    //     is the plugin's long-lived daemon instance -- it is created once when DMS
    //     loads plugins and lives until DMS exits;
    //   * none of the three buttons closes anything (they never did, since the
    //     "stays open until Got it" fix), and "Got it" only flips panelOpen, which
    //     hides a window -- it destroys no objects;
    //   * so nothing in this file can now destroy a running Process.
    //
    // And we need them tracked, because the exit of that process is the ONLY
    // signal available for "the window I opened has gone away" -- see the header
    // for the alternatives that were measured and rejected.
    //
    // The marker write in dismiss() stays on execDetached, unchanged: it is
    // fire-and-forget, nothing waits on it, and it is the one call that genuinely
    // races the panel going away.
    function launch(proc) {
        if (proc.running)      // second click while the first window is still up
            return
        root.spawnedRunning++
        proc.running = true
    }

    // Called from every tracked Process's onExited. Guarded against going negative
    // so that a stray exit signal can never leave the panel permanently hidden.
    function spawnFinished() {
        if (root.spawnedRunning > 0)
            root.spawnedRunning--
    }

    Process {
        id: guideProc
        command: root.cmdHelpHub
        running: false
        onExited: (code, status) => root.spawnFinished()
    }

    Process {
        id: gameDisplayProc
        command: root.cmdGameDisplay
        running: false
        onExited: (code, status) => root.spawnFinished()
    }

    Process {
        id: healthCheckProc
        command: root.cmdHealthCheck
        running: false
        onExited: (code, status) => root.spawnFinished()
    }

    // The wallpaper picker is the odd one out and stays detached: it is an instant
    // `dms ipc call`, so its process exits immediately and tells us nothing about
    // whether the dash is open. Its visibility handling is the PopoutManager block
    // below instead.
    function run(cmd) {
        Quickshell.execDetached({ command: cmd })
    }

    // Written ONLY on dismiss (see the header). Best-effort: if the state dir can't be
    // written the panel still closes -- refusing to close because a marker failed would
    // be a worse bug than showing the panel twice.
    function dismiss() {
        Quickshell.execDetached({
            command: ["sh", "-c", `mkdir -p '` + root.stateDir + `' && touch '` + root.stateFile + `'`]
        })
        root.panelOpen = false
    }

    // ---- "PICK A WALLPAPER": WHY THIS BLOCK EXISTS --------------------------
    // That button fires `dms ipc call dash toggle wallpaper` and hands control to
    // DMS's own dash. There is no process of ours to wait on, so the trick used
    // for the other three does not apply, and the question was whether anything
    // NATIVE reports "the dash closed".
    //
    // It does. DMS's Common/PopoutManager.qml is a singleton (so a plugin can
    // import it, unlike the dash's own state, which hangs off the shell root's
    // dankDashPopoutLoader and is unreachable from here). It tracks the open
    // popout per screen in currentPopoutsByScreen, exposes getActivePopout(screen),
    // and emits popoutChanged() from BOTH showPopout() and hidePopout() -- and
    // hidePopout() runs when the close animation finishes, which is exactly the
    // "it's gone now" edge we want.
    //
    // So this needs no polling, no window-manager window tracking, and no
    // workaround: it is the same open/closed treatment the terminals get, driven
    // by DMS's own signal.
    //
    // SCOPE, on purpose: this reacts to ANY popout on our monitor, not only the
    // wallpaper dash. PopoutManager allows one popout per screen, they all draw
    // over this card anyway, and "the panel steps aside for DMS's own surfaces" is
    // a simpler rule to hold in your head than a special case for one of them.
    Connections {
        target: PopoutManager
        function onPopoutChanged() {
            root.popoutActive = !!(root.panelScreen && PopoutManager.getActivePopout(root.panelScreen))
        }
    }

    Component.onCompleted: startupProbe.running = true

    // =========================================================================
    //  THE PANEL ITSELF
    // =========================================================================
    //  Structure lifted from DMS's Widgets/DankOSD.qml, which is its own
    //  always-available-never-in-the-way surface: bare PanelWindow, transparent,
    //  anchored top+left and pushed into place with layer-shell margins, sized to
    //  its content plus a shadow allowance, masked down to the card.
    PanelWindow {
        id: panelWindow

        // Re-pointed from DankModal.targetScreen. Same value, same resolution
        // logic (resolveScreen above); PanelWindow falls back to its own default
        // if this is null, which only happens when there are no screens at all.
        screen: root.panelScreen

        // OPEN, minus "currently getting out of the way". Both halves matter:
        // panelOpen is the real state and only "Got it" clears it; outOfTheWay is
        // temporary and always comes back on its own.
        visible: root.panelOpen && !root.outOfTheWay

        color: "transparent"

        // Namespace keeps the "dms:" prefix the rest of the shell uses so mango's
        // blur_layer/layerrule handling treats it like any other shell surface.
        WlrLayershell.namespace: "dms:firstrun"

        // Top, not Overlay. Overlay was chosen originally to sit above focused
        // floating windows; it is not needed now that the panel hides itself while
        // anything it opened is up, and Top is the layer DMS's own modals default
        // to. Do NOT read this as "Top makes it hide behind tiled windows" -- it
        // does not, that was measured; see the header.
        WlrLayershell.layer: WlrLayer.Top

        // Reserve no space -- this is a floating card, not a bar.
        WlrLayershell.exclusiveZone: -1

        // NO KEYBOARD GRAB. This is half of the original bug: left to itself
        // DankModal asked Common/KeyboardFocus.qml, which returns
        // WlrKeyboardFocus.Exclusive on anything that isn't Hyprland, and the keys
        // meant for the guide terminal were being delivered here instead. The
        // panel is entirely mouse-driven -- no text field, nothing to Tab through
        // -- so None is honest, and it also means a stray keypress can never land
        // on a focused button and dismiss the panel. This is what DankOSD uses.
        // (OnDemand if it ever grows a text field.)
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        readonly property real dpr: screen ? CompositorService.getScreenScale(screen) : 1
        readonly property real screenWidth: screen ? screen.width : 1920
        readonly property real screenHeight: screen ? screen.height : 1080

        // Room around the card for the drop shadow to render into. Same value and
        // same purpose as DankOSD's. It is NOT part of the card and is explicitly
        // masked out of the input region below, so it swallows no clicks.
        readonly property real shadowBuffer: 15

        // Wide enough that the FOUR optional actions sit on one row at the default
        // font scale. They're in a Flow, so a bigger font wraps them instead of
        // pushing them through the side of the card. Measured at 720 the row is a
        // couple of dozen pixels short of holding all four, so it wrapped the
        // health check onto a line of its own, which reads as a leftover rather
        // than as a fourth suggestion. Checked at font scale 1.3 as well, where
        // the Flow does wrap (three then one) and everything stays inside the card
        // -- wrapping is the intended behaviour up there, not a bug to widen away.
        readonly property real cardWidth: 800

        // HEIGHT FOLLOWS THE CONTENT, measured from the children below. A fixed
        // height is a clipping bug waiting for the first person with a larger font
        // scale. No binding loop: everything feeding this is driven by the card's
        // WIDTH, which is the constant above.
        //
        // spacingXL (24) x3 = the top margin, the body-to-footer gap and the
        // bottom margin. Keep this token and the two anchors.margins the same or
        // the bottom margin stops matching the top one.
        readonly property real cardHeight: body.implicitHeight + footer.height + Theme.spacingXL * 3

        readonly property real alignedWidth: Theme.px(cardWidth, dpr)
        readonly property real alignedHeight: Theme.px(cardHeight, dpr)
        readonly property real alignedX: Theme.snap((screenWidth - alignedWidth) / 2, dpr)
        readonly property real alignedY: Theme.snap((screenHeight - alignedHeight) / 2, dpr)

        anchors {
            top: true
            left: true
        }

        WlrLayershell.margins {
            left: Math.max(0, Theme.snap(panelWindow.alignedX - panelWindow.shadowBuffer, panelWindow.dpr))
            top: Math.max(0, Theme.snap(panelWindow.alignedY - panelWindow.shadowBuffer, panelWindow.dpr))
        }

        implicitWidth: alignedWidth + (shadowBuffer * 2)
        implicitHeight: alignedHeight + (shadowBuffer * 2)

        // THE OTHER HALF OF THE ORIGINAL BUG, fixed by shape rather than by a
        // property: the input region is the card and nothing else. The surface is
        // already only card-plus-shadow rather than the whole output, and this
        // trims the shadow margin off too, so a click a pixel outside the card
        // goes to whatever is underneath. Same idiom as DankOSD's
        // `mask: Region { item: bgShadowLayer }`.
        mask: Region {
            item: cardBackground
        }

        // Frosted glass, matching the switcher and the bar. DankModal used to
        // arrange this itself; done by hand here, tracking the card's rect.
        WindowBlur {
            targetWindow: panelWindow
            blurX: panelWindow.shadowBuffer
            blurY: panelWindow.shadowBuffer
            blurWidth: panelWindow.visible ? panelWindow.alignedWidth : 0
            blurHeight: panelWindow.visible ? panelWindow.alignedHeight : 0
            blurRadius: Theme.cornerRadius
        }

        Item {
            id: card

            x: panelWindow.shadowBuffer
            y: panelWindow.shadowBuffer
            width: panelWindow.alignedWidth
            height: panelWindow.alignedHeight

            // NO ENTRANCE ANIMATION, on purpose. DankModal brought a scale/fade
            // with it; re-implementing that here would be a second animation
            // system that ignores the user's animation-speed setting, for a card
            // that is shown once ever. Correctness over polish for this one.

            // The card's fill, corner radius, outline and shadow, all rendered
            // together by one rounded-rect shader -- the native way to draw a
            // surface like this in DMS, and the same component DankOSD and
            // DankModal both hand their colours to.
            //
            // Colours are unchanged from the DankModal version: a matugen
            // `readableSurface` with alpha so the wallpaper blur shows through,
            // and an accent-tinted edge (Theme.primary rather than the neutral
            // outline) so the card moves with the wallpaper like the window
            // borders, the bar and the login button do.
            ElevationShadow {
                id: cardBackground
                anchors.fill: parent
                level: Theme.elevationLevel3
                fallbackOffset: 6
                targetRadius: Theme.cornerRadius
                targetColor: Qt.rgba(Theme.readableSurface.r, Theme.readableSurface.g, Theme.readableSurface.b, 0.82)
                borderColor: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.45)
                borderWidth: 1
                shadowEnabled: Theme.elevationEnabled && SettingsData.popoutElevationEnabled && Quickshell.env("DMS_DISABLE_LAYER") !== "true" && Quickshell.env("DMS_DISABLE_LAYER") !== "1"
            }

            Column {
                id: body
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.spacingXL
                spacing: Theme.spacingL

                // =========================================================
                //  HERO HEADER
                // =========================================================
                // Was a small "waving_hand" icon beside a 20px title, which is the
                // header you give a settings sub-page, not the one thing a brand-new
                // desktop shows its owner. The shape of this is DMS's own -- its
                // GreeterWelcomePage does exactly logo-over-title, centred, with the
                // logo sized off Theme.iconSize -- so this is the house pattern at
                // card scale rather than a header invented here. What it does NOT
                // copy is that page's MultiEffect colourisation of the logo: DMS's
                // mark is a flat monochrome SVG and takes the accent well, ours is
                // a five-colour pixel-art mango and would be destroyed by it. The
                // accent goes into the band around it instead.
                Rectangle {
                    id: hero
                    width: parent.width
                    height: heroContent.implicitHeight + Theme.spacingXL * 2
                    radius: Theme.cornerRadius
                    // Accent wash + accent edge: the same matugen `primary` the
                    // window borders, the bar and the login button all re-tint from,
                    // so this band moves with the wallpaper like everything else.
                    color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.10)
                    border.width: 1
                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.30)
                    // The motif below deliberately runs off the left edge; this is
                    // what cuts it there.
                    clip: true

                    // ---- accent motif -----------------------------------
                    // The SDDM theme's signature, brought across: a hard-edged
                    // rotated square, no radius, no gradient, in the live accent,
                    // running off the frame so only its point reaches the content.
                    // Someone who has just seen the login screen should recognise
                    // this. It is the DESIGN carried over, not the file --
                    // Components/AccentShape.qml lives in a root-owned tree that
                    // only exists if the SDDM step ran, the plugin can't import
                    // across to it, and every DankMango plugin so far is a single
                    // QML file, so the two elements are restated here at card
                    // scale. Geometry, border-width formula and both opacities are
                    // the originals; only the placement is re-derived, because
                    // AccentShape's own positioning assumes a full screen with the
                    // card off to one side.
                    Item {
                        id: motif
                        // Edge length BEFORE rotation, tied to the band so it stays
                        // in proportion at any font scale. Sized so the diamond is
                        // taller than the band: its top and bottom points are cut
                        // off too, which is what stops it reading as a small shape
                        // sitting inside a box.
                        readonly property real edge: hero.height * 1.1
                        width: edge * Math.SQRT2      // rotated bounding box
                        height: width
                        // Straddling the left edge, vertically centred. At this
                        // offset the outline crosses x=0 well clear of both rounded
                        // corners -- clip is rectangular, so a shape cutting through
                        // a corner would draw outside the radius.
                        x: -width * 0.35
                        y: (hero.height - height) / 2

                        Rectangle {
                            anchors.centerIn: parent
                            width: motif.edge
                            height: motif.edge
                            rotation: 45
                            // Rotated edges alias badly without this; Rectangle only
                            // turns it on by default when there's a radius, and this
                            // one deliberately has none.
                            antialiasing: true
                            color: "transparent"
                            border.width: Math.max(2, Math.round(motif.edge * 0.010))
                            border.color: Theme.primary
                            opacity: 0.50
                        }
                    }

                    // The detached second point. In the SDDM composition this is the
                    // element that actually registers as an accent -- the outline
                    // does the structural work but is too faint to be a focal point
                    // alone -- and it is deliberately NOT welded to the outline, so
                    // the two read as a rhythm rather than a thicker bit of line.
                    // Here it goes right, opposite the outline, which is where the
                    // open space in a centred header is.
                    Rectangle {
                        width: Math.round(motif.edge * 0.13)
                        height: width
                        x: hero.width - Theme.spacingXL - width
                        y: Math.round(hero.height * 0.28)
                        rotation: 45
                        antialiasing: true
                        color: Theme.primary
                        opacity: 0.85
                    }

                    Column {
                        id: heroContent
                        anchors.centerIn: parent
                        width: parent.width - Theme.spacingXL * 2
                        spacing: Theme.spacingM

                        // The mango itself, same crop the login screen uses (icon
                        // block, no wordmark) -- shipped in this plugin's own folder
                        // rather than pointed at the SDDM theme's copy, which is
                        // root-owned and only exists if that install step ran.
                        // install.sh and update.sh both copy the whole plugin
                        // directory, so the asset travels with the QML for free.
                        //
                        // Sized off Theme.iconSize, which does NOT grow with the
                        // font scale -- so a big font makes the text around it
                        // bigger while the logo stays put, which is the right way
                        // round for keeping the card's height in check.
                        Image {
                            id: heroLogo
                            anchors.horizontalCenter: parent.horizontalCenter
                            height: Math.round(Theme.iconSize * 3.2)
                            width: implicitHeight > 0 ? height * (implicitWidth / implicitHeight) : height
                            source: Qt.resolvedUrl("logo.png")
                            fillMode: Image.PreserveAspectFit
                            // Pixel-art source at 588x672 shown around 68px wide --
                            // let Qt downsample it smoothly rather than
                            // nearest-neighbour it into aliasing. Synchronous
                            // because the width binding above needs implicit size
                            // on the first frame, exactly as LoginForm.qml does it.
                            smooth: true
                            mipmap: true
                            asynchronous: false
                            visible: status !== Image.Error
                        }

                        // If the asset somehow isn't there -- an older plugin folder
                        // that predates it, a half-finished copy -- the header falls
                        // back to the icon this panel used to lead with rather than
                        // leaving a hole where the logo goes. Invisible items take
                        // no space in a Column, so exactly one of these two ever
                        // occupies the slot.
                        DankIcon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            name: "waving_hand"
                            size: Math.round(Theme.iconSize * 2.4)
                            color: Theme.primary
                            visible: heroLogo.status === Image.Error
                        }

                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "Welcome to DankMango"
                            font.pixelSize: Theme.fontSizeXLarge + 6
                            font.weight: Font.Bold
                            color: Theme.surfaceText
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    text: "Your desktop is set up and ready to use. Everything here can be changed later — nothing is baked in."
                }

                // For the person whose first Linux desktop this is. Smaller and
                // dimmer than the line above because it's reassurance, not
                // instruction -- it should be there when you need it and easy to
                // skim past when you don't.
                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeSmall
                    // The second sentence is the answer to "what if an update
                    // breaks my desktop", which is a specific fear and deserves a
                    // specific answer rather than more soothing. It states what
                    // update.sh actually does (see docs/GUIDE.md, "The snapshot it
                    // takes first"), so keep the two in step.
                    //
                    // "if it can" is doing real work and is not hedging for the sake
                    // of it: the snapshot needs Btrfs with snapper set up, which is
                    // stock CachyOS and so true for most readers, but promising it
                    // flatly would be a lie on ext4 -- and a reassurance that turns
                    // out to be false is worse than none.
                    text: "You won't need the terminal unless you want it, and the installer backed up everything it replaced — so click about. You can't break this. Updates take a snapshot of your system first where it can, so a bad one is a rollback away rather than an evening gone."
                }

                // (The help-hub tip that used to sit here as its own bordered box
                // now lives in the footer, next to the version -- see below.)

                StyledText {
                    text: "Worth doing now:"
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeSmall
                }

                // SECONDARY, all four. These are suggestions you can ignore; the
                // only action that has to be taken is "Got it", and it's the one
                // that's filled in. DankButton's DEFAULT colours are Theme.buttonBg /
                // Theme.buttonText, which for the stock buttonColorMode resolve to
                // the accent -- i.e. leaving them alone is what made all four
                // buttons look equally important. The pairing below is DMS's own
                // secondary treatment, lifted from its GreeterModal's Back button.
                //
                // Flow, not Row: it wraps to a second line at large font scales
                // instead of running off the edge of the card.
                Flow {
                    width: parent.width
                    spacing: Theme.spacingM

                    // NONE of these four dismiss the panel. The three that open a
                    // terminal go through launch(), which hides the card until that
                    // terminal exits and then brings it straight back; the fourth
                    // hands off to DMS's dash and is handled by the PopoutManager
                    // block above. Hiding is not closing: panelOpen stays true
                    // throughout, so the panel is still owed to the user and only
                    // "Got it" can settle that debt.
                    DankButton {
                        text: "Open the guide"
                        iconName: "menu_book"
                        backgroundColor: Theme.surfaceContainerHighest
                        textColor: Theme.surfaceText
                        onClicked: root.launch(guideProc)
                    }

                    DankButton {
                        text: "Pick a wallpaper"
                        iconName: "wallpaper"
                        backgroundColor: Theme.surfaceContainerHighest
                        textColor: Theme.surfaceText
                        onClicked: root.run(root.cmdWallpaper)
                    }

                    DankButton {
                        text: "Choose game display"
                        iconName: "desktop_windows"
                        backgroundColor: Theme.surfaceContainerHighest
                        textColor: Theme.surfaceText
                        onClicked: root.launch(gameDisplayProc)
                    }

                    // "vital_signs" is DMS's own icon for this exact idea -- it
                    // marks the Doctor page in its greeter (Modals/Greeter/
                    // GreeterDoctorPage.qml) and the diagnostics entry in Settings
                    // (Modules/Settings/AboutTab.qml). Borrowing it means the
                    // health check looks like the same concept everywhere the user
                    // meets it, rather than picking a fresh stethoscope here.
                    DankButton {
                        text: "Check my setup"
                        iconName: "vital_signs"
                        backgroundColor: Theme.surfaceContainerHighest
                        textColor: Theme.surfaceText
                        onClicked: root.launch(healthCheckProc)
                    }
                }
            }

            // The footer is anchored to the card's edges WITH THE SAME MARGIN the
            // body uses, which is the fix for "Got it" hanging over the border:
            // it was previously anchored to parent.right/parent.bottom with no
            // margin at all, so it sat flush against the frame.
            //
            // THREE things live here now: the help-hub tip, the version, and the
            // one button that closes the card. The arrangement is "everything you
            // read on the left, the thing you click on the right", with the two
            // text lines stacked as one block -- so the footer stays a single band
            // and "Got it" keeps the far corner it already had.
            //
            // The tip sits ABOVE the version inside that block on purpose: it is
            // the line that still has something to tell you, and the version is a
            // footnote. Reading order down the left is therefore tip -> version,
            // i.e. most useful first.
            //
            // HEIGHT is the taller of the two sides, not gotIt.height as it was
            // when the button was all that was down here. The tip wraps, so at a
            // large font scale or a long version string the text block is the taller
            // one, and hard-coding the button's height would have clipped it.
            Item {
                id: footer
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: Theme.spacingXL
                height: Math.max(gotIt.height, footerText.height)

                Column {
                    id: footerText
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    // Everything the button doesn't need. Left as the wrap width for
                    // the tip below rather than letting it run under "Got it".
                    width: parent.width - gotIt.width - Theme.spacingL
                    spacing: Theme.spacingXS

                    // The help-hub tip, which used to be a bordered callout in the
                    // middle of the card. It was the loudest thing on a panel whose
                    // job is to get out of the way, and it was competing with the
                    // actions for the eye. Down here it is still the last thing you
                    // read before clicking, which is where a "you can always get
                    // back to this" line belongs.
                    //
                    // It keeps the accent icon -- that is what stops it reading as
                    // small print next to the version underneath it -- and the
                    // wording now says the guide assumes nothing, because the person
                    // who most needs to press that shortcut is the person who is not
                    // sure the guide is written for them.
                    Row {
                        width: parent.width
                        spacing: Theme.spacingS

                        DankIcon {
                            name: "help"
                            size: Theme.fontSizeMedium
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            width: parent.width - Theme.fontSizeMedium - Theme.spacingS
                            wrapMode: Text.WordWrap
                            anchors.verticalCenter: parent.verticalCenter
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            text: "Press SUPER+SHIFT+/ any time for the full guide and every keybind, in plain English — no Linux experience assumed."
                        }
                    }

                    // Which build you're actually running. Comes from the manifest's
                    // .dankmango.version, written by manifest_init() from
                    // `git describe --tags --always --dirty` -- so it's whatever the
                    // repo really was at install time, never a string typed in here
                    // that could go stale. Shown as just the tag ("DankMango v1.3.0"):
                    // see displayVersion up top for why, and for what the full string
                    // looks like. Hidden entirely rather than showing "unknown" when
                    // it can't be read at all.
                    //
                    // IT SITS TIGHTER INTO THE CORNER THAN EVERYTHING ELSE, on purpose.
                    // Left alone it lands on the card's standard spacingXL (24) inset,
                    // the same as the body text and the tip above it -- which reads as
                    // indented and floating rather than as a footnote pinned to the
                    // corner. The nudge below pulls it to roughly 12px in and 16px up
                    // from the card's edges.
                    //
                    // Done with a Translate rather than by moving the label: this is a
                    // PURELY VISUAL offset, and it has to stay that way. The Column
                    // owns this item's y, and footerText.height feeds footer.height,
                    // which feeds panelWindow.cardHeight -- so anything that changed the
                    // item's real geometry would change how tall the whole card is.
                    // A transform is applied at paint time and is invisible to all of
                    // that, so the card's measured height is exactly what it was.
                    // (x could have been set directly, since a Column only positions y,
                    // but keeping both axes in one place beats splitting the nudge
                    // across two mechanisms.)
                    StyledText {
                        visible: root.displayVersion !== ""
                        text: "DankMango " + root.displayVersion
                        color: Theme.surfaceTextMedium
                        font.pixelSize: Theme.fontSizeSmall
                        opacity: 0.7
                        transform: Translate {
                            x: -Theme.spacingM
                            y: Theme.spacingS
                        }
                    }
                }

                // THE primary action: filled, accent-coloured, the one thing that
                // both closes the panel and writes the marker. Theme.primary /
                // Theme.primaryText is the pairing DMS uses for the confirming
                // button in its own modals (GreeterModal's Finish, SwitchUserModal's
                // Log Out).
                DankButton {
                    id: gotIt
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Got it"
                    iconName: "check"
                    backgroundColor: Theme.primary
                    textColor: Theme.primaryText
                    onClicked: root.dismiss()
                }
            }
        }
    }
}
