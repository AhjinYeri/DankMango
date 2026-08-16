// =============================================================================
//  ControlHubPanel.qml  --  the DankMango hub: one panel, many sections
// =============================================================================
//
//  >>> IF SOMETHING STOPPED WORKING AFTER A DMS OR MANGO UPDATE, START HERE <<<
//
//  Everything version-specific is in the ONE box below marked
//  "########## EDIT HERE AFTER A DMS / MANGO UPDATE ##########". Fix the paths
//  and commands there to match the new version; the rest is plain QML.
//
// -----------------------------------------------------------------------------
//  WHAT THIS IS (plain English)
// -----------------------------------------------------------------------------
//  DankMango adds a handful of things to your desktop that have nowhere obvious
//  to live: desktop presets, and -- over time -- whatever comes next. Each one on
//  its own would be another keybind you have to already know exists. This is the
//  one place they all appear: press the shortcut, a panel opens, everything
//  DankMango can do for you is on the left, and it stays open until you close it.
//
//  It is a HUB, not a preset switcher that grew a frame. Adding a section is
//  meant to be two small edits and nothing else -- see "ADDING A SECTION" below.
//
//  HOW YOU OPEN AND CLOSE IT
//    open/close   SUPER+d, which runs `dms ipc call controlhub toggle`
//    close only   the X in the top-right of the panel
//  Nothing else closes it. Clicking away leaves it where it is, on purpose: this
//  is a surface you browse, not a menu that evaporates the moment you look at
//  something else. There is no timeout either.
//
//  WHICH MONITOR IT OPENS ON: the focused one, re-checked every time it opens.
//  See "SCREEN TARGETING" below for how that is asked for, and what happens when
//  the answer doesn't come back.
//
// -----------------------------------------------------------------------------
//  ADDING A SECTION  (the whole point of this file)
// -----------------------------------------------------------------------------
//  Two edits, neither of them to the layout code:
//
//    1. Drop a new QML file next to this one, e.g. `HealthSection.qml`. It is an
//       ordinary Item. Give it a real `implicitHeight` (the panel sizes itself
//       from it) and, if it needs to talk to the panel, declare
//       `property var hub: null` -- the loader fills that in for you.
//    2. Add one entry to the `sections` array in the box below:
//           { "id": "health", "label": "Health check",
//             "icon": "vital_signs", "source": "HealthSection.qml" }
//
//  That is it. The nav list is built from that array, the content area loads
//  `source` by name, and nothing in the shell below knows how many sections
//  there are or what they are called.
//
//  WHAT THIS DELIBERATELY DOESN'T DO: it is not a plugin framework. Sections are
//  files in this folder, loaded by name, and that is the right amount of
//  machinery for a panel that has one of them today. If it ever needs sections
//  that ship separately, that is the day to build more -- not before.
//
// -----------------------------------------------------------------------------
//  WHY THIS IS A BARE PanelWindow, AND WHY IT IS A "daemon" PLUGIN
// -----------------------------------------------------------------------------
//  Both answers were already paid for by the first-run panel, and this file is
//  deliberately the same shape as plugins/first-run-panel/FirstRunPanel.qml.
//  The short version, with the long version in that file's header:
//
//    * BARE PanelWindow, NOT DankModal. DankModal makes its surface the size of
//      the whole output (so every click on that monitor lands on it) and takes a
//      keyboard grab on anything that isn't Hyprland. Neither is fixable by
//      setting properties. A bare PanelWindow the size of the card, masked to
//      the card, asking for no keyboard focus, has neither problem by
//      construction. This is DMS's own DankOSD.qml shape.
//
//    * "daemon", NOT a bar widget. Bar widgets are instantiated ONCE PER BAR PER
//      SCREEN. That matters enormously here, because this file registers an
//      IpcHandler: quickshell segfaults -- takes the whole shell down -- when an
//      IPC target has a duplicate handler and something calls it. The alt-tab
//      switcher is a bar widget and has to hide its IpcHandler behind an
//      "am I on the first screen?" gate to survive (see its header). A daemon
//      plugin needs no such gate: DMS keeps exactly one instance per plugin id
//      (Services/PluginService.qml, pluginDaemonInstances), so the handler below
//      can sit at the root where you can see it.
//
//  NO KEYBOARD FOCUS is also what makes "only the X closes it" true rather than
//  merely intended: with WlrKeyboardFocus.None, Escape never reaches this panel,
//  so there is no second way to dismiss it that could drift out of step.
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
    // ########## EDIT HERE AFTER A DMS / MANGO UPDATE #########################
    // #########################################################################

    // --- 1. THE SECTION REGISTRY --------------------------------------------
    // The hub's whole table of contents. Order here is the order in the nav
    // list. Read "ADDING A SECTION" in the header before touching it.
    //
    //   id      stable, internal, never shown -- it is what currentSectionId
    //           holds and what a future `dms ipc call controlhub open <id>`
    //           would take
    //   label   what the user reads in the nav list
    //   icon    a Material Symbols name (the same set DMS uses everywhere)
    //   source  a QML file IN THIS FOLDER, loaded by name at click time
    readonly property var sections: [
        {
            "id": "presets",
            "label": "Desktop presets",
            "icon": "tune",
            "source": "PresetsSection.qml"
        }
    ]

    // --- 2. THE IPC NAME ----------------------------------------------------
    // What the keybind calls: `dms ipc call controlhub toggle`. If this string
    // changes, the bind line in config.conf changes with it -- they are two
    // halves of one thing.
    //
    // It is NOT "control-center": DMS already owns that target for its own
    // Control Center popout (DMSShellIPC.qml), and registering a duplicate is
    // the crash described in the header.
    readonly property string ipcTarget: "controlhub"

    // #########################################################################
    // ########## END OF THE VERSION-SPECIFIC BOX ##############################
    // #########################################################################

    // ---- OPEN/CLOSE STATE ---------------------------------------------------
    // One property, written in exactly three places: the IPC handler's hide(),
    // the close button, and the screen probe (which opens it). There is no
    // ModalManager here, no background click-catcher, and no keyboard focus, so
    // nothing else in the shell can put this down.
    property bool panelOpen: false

    // Which section the content area is showing. Defaults to the first entry in
    // the registry, so an empty registry is survivable rather than fatal.
    property string currentSectionId: sections.length > 0 ? sections[0].id : ""

    // The registry entry matching currentSectionId, or null. THIS is what
    // replaces DMS Settings' hardcoded `active: currentIndex === 37` chain --
    // see the README next to this file for why that pattern was not copied.
    readonly property var currentSection: {
        for (var i = 0; i < root.sections.length; i++) {
            if (root.sections[i].id === root.currentSectionId)
                return root.sections[i]
        }
        return null
    }

    property var panelScreen: null

    // ---- SCREEN TARGETING ---------------------------------------------------
    // Unlike the first-run panel -- which opens on the monitor you chose at
    // install time, because it is a greeting and there is no "current" monitor
    // when you have just logged in -- this follows the FOCUSED monitor. You
    // pressed a key; the panel belongs where you were looking.
    //
    // WHERE THE ANSWER COMES FROM: `mmsg get all-monitors` reports `active:true`
    // on exactly one monitor, and that is mango's own idea of which one is
    // focused. Two alternatives were checked and are worse:
    //   * CompositorService.getFocusedScreen() returns null on mango -- it only
    //     knows Hyprland and niri. (Same finding as the alt-tab switcher.)
    //   * `mmsg get focusing-client` also carries a monitor name, which is what
    //     the alt-tab switcher reads -- but it is EMPTY when no window is
    //     focused, and "I just logged in and nothing is open yet" is a perfectly
    //     ordinary time to press this key. all-monitors always answers.
    //
    // FALLBACK, when mmsg is missing, fails, or reports no active monitor:
    //   LEFTMOST, ties broken by LARGEST -- the same rule monitor-watcher.sh's
    //   fallback_main_display uses and the same one the first-run panel falls
    //   back to, so "the monitor DankMango stands on when it can't tell" has one
    //   definition across the whole project.
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

    // True between "the keybind was pressed" and "the panel actually appeared".
    // The one thing it exists for is to make sure the panel opens EXACTLY ONCE
    // per press no matter which of the two paths below gets there first.
    property bool openPending: false

    // Asked EVERY time the panel opens, not once at startup: the focused monitor
    // is the one fact here that is different on every press.
    Process {
        id: focusProbe
        running: false
        command: ["mmsg", "get", "all-monitors"]
        stdout: StdioCollector {
            id: focusOut
            onStreamFinished: {
                var name = ""
                try {
                    var mons = (JSON.parse(focusOut.text) || {}).monitors || []
                    for (var i = 0; i < mons.length; i++) {
                        if (mons[i].active) {
                            name = mons[i].name || ""
                            break
                        }
                    }
                } catch (e) {
                    name = ""       // falls through to the leftmost/largest rule
                }
                root.finishOpen(name)
            }
        }
    }

    // ---- THE "ASK DIDN'T COME BACK" SAFETY NET ------------------------------
    // >>> THIS IS LOAD-BEARING. MEASURED, not defensive programming. <<<
    //
    // If mmsg can't be run at all, the panel opened from inside the stdout
    // handler above would never open, and the keybind would be silently dead --
    // no window, no error, nothing to notice. That was reproduced on this
    // machine by pointing the Process at a command that doesn't exist: pressing
    // the bind did nothing at all.
    //
    // The first fix tried was a `Connections { target: focusProbe; onExited }`
    // that opened on a non-zero exit. IT DOES NOT FIRE when the command cannot
    // be started -- measured the same way -- so it fixed nothing. Do not put it
    // back; a timer is the only thing that catches every way an answer can fail
    // to arrive, including the process hanging, which an exit handler cannot
    // catch by definition.
    //
    // 800ms is well past mmsg's real answer (milliseconds) and short enough that
    // a fallback open still feels like a response to the key you pressed.
    Timer {
        id: probeWatchdog
        interval: 800
        repeat: false
        onTriggered: root.finishOpen("")   // "" -> the leftmost/largest fallback
    }

    // The ONLY place the panel is opened. Both the probe's answer and the
    // watchdog come through here, and openPending makes whichever arrives first
    // the winner -- so a slow answer can never re-open a panel that has already
    // been closed again, and a fast one is never followed by the watchdog.
    function finishOpen(name) {
        if (!root.openPending)
            return
        root.openPending = false
        probeWatchdog.stop()
        root.panelScreen = root.resolveScreen(name)
        root.panelOpen = true
    }

    function openPanel() {
        if (root.panelOpen)
            return
        root.openPending = true
        focusProbe.running = false
        focusProbe.running = true
        probeWatchdog.restart()
    }

    // Cancels a pending open as well as closing an open panel. Without that, a
    // press-then-immediately-press-again inside the watchdog's window would
    // close the panel and then have it reappear on its own.
    function closePanel() {
        root.openPending = false
        probeWatchdog.stop()
        root.panelOpen = false
    }

    // A PENDING OPEN COUNTS AS OPEN. Measured: without that, pressing the bind
    // twice quickly left the panel OPEN rather than closing it again -- the
    // second press ran while panelOpen was still false, read that as "shut", and
    // started a second open. From the user's side the panel is on its way, so
    // the second press has to mean "no, cancel that".
    function togglePanel() {
        if (root.panelOpen || root.openPending)
            root.closePanel()
        else
            root.openPanel()
    }

    // ---- THE KEYBIND'S WAY IN -----------------------------------------------
    // Same mechanism the alt-tab switcher uses (`dms ipc call <target> <fn>`
    // from a bind in config.conf), minus its single-instance gate -- see the
    // header for why a daemon plugin doesn't need one.
    //
    // toggle() is what the keybind calls. open()/close() exist because they cost
    // two lines each and they are what any future script wants: "open the hub"
    // is a sensible thing for the installer or the help hub to do, and it should
    // not have to guess whether the panel is already up.
    //
    // >>> DO NOT RENAME open() TO show() <<<  MEASURED, not guessed:
    // `dms ipc call <target> show` never reaches the shell. The dms CLI treats
    // `show` as its own verb -- "print this target's interface" -- so the call
    // prints a function list and returns success while doing nothing at all.
    // (Reproduce on any target: `dms ipc call altswitcher show`.) That is also
    // why the names here are open/close/toggle: it is what DMS's own targets use
    // (clipboard, dash, keybinds, color-picker all do), so it is the convention
    // that is known to survive contact with the CLI.
    IpcHandler {
        target: root.ipcTarget

        function toggle(): string {
            root.togglePanel()
            return "ok"
        }
        function open(): string {
            root.openPanel()
            return "ok"
        }
        function close(): string {
            root.closePanel()
            return "ok"
        }
    }

    // Monitor hotplug while the panel is open. Re-resolving rather than hiding:
    // unplugging a monitor should move the panel, not silently take it away
    // while the user is halfway through reading it.
    Connections {
        target: Quickshell
        function onScreensChanged() {
            if (!root.panelOpen)
                return
            root.panelScreen = root.resolveScreen(root.panelScreen ? root.panelScreen.name : "")
        }
    }

    // =========================================================================
    //  THE PANEL ITSELF
    // =========================================================================
    //  Structure lifted from the first-run panel, which lifted it from DMS's own
    //  Widgets/DankOSD.qml: bare PanelWindow, transparent, anchored top+left and
    //  pushed into place with layer-shell margins, sized to its content plus a
    //  shadow allowance, masked down to the card. Every comment explaining WHY
    //  each property is set the way it is lives in FirstRunPanel.qml; this file
    //  notes only where it differs.
    PanelWindow {
        id: panelWindow

        screen: root.panelScreen
        visible: root.panelOpen
        color: "transparent"

        // Keeps the "dms:" prefix so mango's blur_layer/layerrule handling treats
        // this like any other shell surface.
        WlrLayershell.namespace: "dms:controlhub"

        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.exclusiveZone: -1

        // NO KEYBOARD GRAB -- this is what keeps the keybind itself working while
        // the panel is up, and what makes "only the X closes it" structural
        // rather than a rule to remember. Everything here is mouse-driven; the
        // day a section grows a text field, this becomes OnDemand and that
        // section's own field asks for focus.
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        readonly property real dpr: screen ? CompositorService.getScreenScale(screen) : 1
        readonly property real screenWidth: screen ? screen.width : 1920
        readonly property real screenHeight: screen ? screen.height : 1080

        // Room for the drop shadow to render into. Not part of the card, and
        // masked out of the input region below, so it swallows no clicks.
        readonly property real shadowBuffer: 15

        // Nav rail plus a content column wide enough for a row of preset cards.
        readonly property real cardWidth: 780

        // HEIGHT FOLLOWS THE CONTENT. A fixed height is a clipping bug waiting
        // for the first person with a larger font scale, and sections are not
        // all going to be the same height anyway.
        readonly property real cardHeight: body.implicitHeight + Theme.spacingXL * 2

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

        // The input region is the card and nothing else: a click one pixel
        // outside it goes to whatever is underneath, rather than to us.
        mask: Region {
            item: cardBackground
        }

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

            // Same fill, radius, outline and shadow as the first-run panel: a
            // matugen readableSurface with alpha so the wallpaper blur shows
            // through, and an accent-tinted edge so the card moves with the
            // wallpaper like the window borders and the bar do.
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
                //  TITLE BAR
                // =========================================================
                //  Brand on the left, the one control that closes this on the
                //  right. Deliberately quiet compared with the first-run panel's
                //  hero header: that panel is seen once and has to introduce
                //  itself, this one is somewhere you come back to and should get
                //  out of the way of its own content.
                Item {
                    id: titleBar
                    width: parent.width
                    height: Math.max(titleText.implicitHeight, closeButton.height)

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingM

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "dashboard"
                            size: Theme.iconSize
                            color: Theme.primary
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            StyledText {
                                id: titleText
                                text: "DankMango"
                                font.pixelSize: Theme.fontSizeLarge
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                            }

                            StyledText {
                                text: root.currentSection ? root.currentSection.label : ""
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceTextMedium
                            }
                        }
                    }

                    // THE only thing that closes the panel. DankActionButton is
                    // DMS's own icon-button, the same one its popouts use for
                    // exactly this job.
                    DankActionButton {
                        id: closeButton
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: "close"
                        iconColor: Theme.surfaceText
                        tooltipText: "Close"
                        onClicked: root.closePanel()
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 1
                    color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.3)
                }

                // =========================================================
                //  NAV RAIL + CONTENT
                // =========================================================
                //  The shape is DMS's own Settings window -- a list of sections
                //  down the left, the chosen one filling the rest -- because
                //  that is the navigation people already met in this desktop.
                //  What it does NOT copy is how DMS wires the two halves
                //  together; see the README next to this file.
                //
                //  THE RAIL IS SHOWN EVEN WITH ONE SECTION IN IT, on purpose. It
                //  says what this panel is: a place things get added to, not a
                //  preset switcher with a frame around it. The day it holds one
                //  entry forever is the day to reconsider.
                Row {
                    id: split
                    width: parent.width
                    spacing: Theme.spacingL

                    readonly property real railWidth: 190

                    Column {
                        id: rail
                        width: split.railWidth
                        spacing: Theme.spacingXS

                        Repeater {
                            model: root.sections

                            // The row idiom is the same one monitor-mode's layout
                            // tiles use -- StyledRect + accent border when
                            // selected + StateLayer for the click and the ripple
                            // -- laid out as a row rather than a tile because
                            // these are named destinations, not pictures.
                            StyledRect {
                                id: navRow

                                readonly property bool isSelected: root.currentSectionId === modelData.id

                                width: rail.width
                                height: 44
                                radius: Theme.cornerRadius
                                color: isSelected
                                    ? Theme.primaryPressed
                                    : Qt.rgba(Theme.surfaceContainerHigh.r, Theme.surfaceContainerHigh.g, Theme.surfaceContainerHigh.b, 0.5)
                                border.width: isSelected ? 2 : 1
                                border.color: isSelected
                                    ? Theme.primary
                                    : Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.4)

                                Row {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.rightMargin: Theme.spacingM
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: modelData.icon
                                        size: Theme.iconSize - 2
                                        color: navRow.isSelected ? Theme.primary : Theme.surfaceText
                                    }

                                    StyledText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: rail.width - Theme.iconSize - Theme.spacingM * 3
                                        text: modelData.label
                                        color: navRow.isSelected ? Theme.primary : Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: navRow.isSelected ? Font.Medium : Font.Normal
                                        elide: Text.ElideRight
                                    }
                                }

                                StateLayer {
                                    stateColor: Theme.primary
                                    onClicked: root.currentSectionId = modelData.id
                                }
                            }
                        }
                    }

                    // ---- THE CONTENT AREA --------------------------------
                    // One Loader, pointed at a filename from the registry. This
                    // is the whole content-side dispatch: there is no per-section
                    // code in this file, and adding a section adds none.
                    //
                    // WHY `source` AND NOT A LIST OF Components: a Component per
                    // section would have to be declared here, which puts every
                    // section's identity back in the shell -- the exact coupling
                    // this is avoiding. Loading by filename keeps the shell
                    // ignorant of what a section is.
                    //
                    // `hub` is injected after load rather than bound, because a
                    // file loaded by URL has no lexical access to `root`. A
                    // section that doesn't declare the property simply doesn't
                    // get one, which is why this is guarded rather than assumed.
                    Loader {
                        id: sectionLoader

                        width: split.width - split.railWidth - split.spacing
                        // The rail is the floor: a short section shouldn't make
                        // the card shorter than its own navigation.
                        height: Math.max(rail.implicitHeight, item ? item.implicitHeight : 0)

                        asynchronous: false
                        source: root.currentSection ? Qt.resolvedUrl(root.currentSection.source) : ""

                        onLoaded: {
                            if (item && item.hasOwnProperty("hub"))
                                item.hub = root
                        }

                        // A section file that fails to load (renamed, typo in the
                        // registry, broken QML) would otherwise be a blank right
                        // half with no explanation. Say so instead: this is a
                        // message for whoever is adding the section, and it is
                        // the only failure mode this shell has of its own.
                        StyledText {
                            anchors.centerIn: parent
                            width: parent.width
                            visible: sectionLoader.status === Loader.Error
                            wrapMode: Text.WordWrap
                            horizontalAlignment: Text.AlignHCenter
                            color: Theme.surfaceTextMedium
                            font.pixelSize: Theme.fontSizeSmall
                            text: root.currentSection
                                ? ("Couldn't load " + root.currentSection.source + " — check the shell log for the QML error.")
                                : "No sections are registered."
                        }
                    }
                }
            }
        }
    }
}
