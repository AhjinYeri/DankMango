// =============================================================================
//  Alt-Tab Switcher  --  visual window switcher for mango Alt+Tab (DMS plugin)
// =============================================================================
//  Shows open windows as cards (app icon + app name + title), highlights the
//  focused one, frosted to match DMS/matugen, on the focused monitor.
//
//  >>> IF THE POPUP BROKE / VANISHED AFTER A DMS OR MANGO UPDATE, START HERE <<<
//
//  This file is the visual front-end ONLY. It does no focus-switching itself
//  (mango's focusstack does that -- see alt-switcher.sh). Everything an update
//  can break is one of the coupling points listed in the box below; the
//  plain-English fix steps are in README.md next to this file.
//
//  >>> SINGLE-INSTANCE GATE (why the Loader/engine below exists) <<<
//  A DankBar plugin is instantiated ONCE PER MONITOR. Two instances would each
//  register an IpcHandler for target "altswitcher"; quickshell 0.3.0-2 SEGFAULTS
//  (crashes the whole shell) when an IPC target has a duplicate handler and it's
//  invoked -- pressing Alt+Tab took the shell down. So the IPC handler + modal +
//  timers live inside `engine`, a Loader that is active on ONLY the primary-screen
//  instance (isPrimaryInstance). The popup is one window retargeted to the focused
//  monitor, so a single owner is enough. DO NOT move the IpcHandler back out to the
//  root, or the duplicate-handler crash returns.
//
// ----- ########## EDIT HERE AFTER A DMS / MANGO UPDATE ########## ------------
//
//  A) DMS building blocks this imports (a DMS update could rename one -> plugin
//     fails to load; the shell log names the offending line, see README):
//       qs.Common          -> Theme.* (colors/sizes), Paths.getAppIcon(appid, entry)
//       qs.Widgets         -> DankIcon (uses `size:` NOT font.pixelSize!), StyledText, StyledRect
//       Quickshell.Widgets -> IconImage (real app icons)
//       Quickshell         -> DesktopEntries.heuristicLookup(appid), Quickshell.screens
//       qs.Modules.Plugins -> PluginComponent (plugin root type)
//       qs.Modals.Common   -> DankModal (centered layershell surface; blurs wallpaper)
//       Quickshell.Io      -> Process, StdioCollector, IpcHandler
//
//  B) DankModal properties relied on: useOverlayLayer (keeps popup above floating
//     windows), backgroundColor/borderColor, positioning, shouldHaveFocus:false (so
//     Alt+Tab reaches mango), contentWindow.screen (monitor placement), open()/close(),
//     shouldBeVisible. If one is renamed, update it here.
//
//  C) mango IPC this depends on (test each in a terminal):
//       mmsg get all-clients   -> JSON {clients:[{title, appid, is_focused, monitor}, ...]}
//                                 (this file reads exactly those 4 fields)
//     If mango renames the command or those fields, fix them in the Process below.
//
//  D) The IPC contract with the wiring script: IpcHandler target "altswitcher"
//     with functions show/hide/toggle/next/prev. alt-switcher.sh calls these via
//     `dms ipc call altswitcher <fn>`. Keep the names in sync across both files.
//
//  E) Crash on Alt+Tab (shell disappears): almost certainly the duplicate-handler
//     issue above. Confirm in the log:  grep 'another handler is registered' <qslog>.
//     If present, the single-instance gate broke -- check isPrimaryInstance still
//     resolves true for exactly one instance (needs parentScreen.name to match
//     Quickshell.screens[0].name).
// ----------------------------------------------------------------------------
//
//  Design recap: not keyboard-focused (Alt+Tab reaches mango), so it can't be
//  closed by a key/click -- it auto-hides via the idle timer after the last poke.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import qs.Modals.Common

PluginComponent {
    id: root

    // TRUE on exactly one instance: the one whose bar is on the first screen.
    // Gates `engine` so only one IpcHandler/modal exists (see header: duplicate
    // handler -> quickshell segfault). parentScreen is set by DankBar WidgetHost.
    readonly property bool isPrimaryInstance: {
        var s = Quickshell.screens
        if (!s || s.length === 0 || !root.parentScreen)
            return false
        return root.parentScreen.name === s[0].name
    }

    // All the IPC/window machinery lives here and loads on ONE instance only.
    Loader {
        id: engine
        active: root.isPrimaryInstance
        sourceComponent: engineComponent
    }

    Component {
        id: engineComponent

        Item {
            id: eng

            property var clients: []

            // Map a mango monitor name (its compositor connector) to a Quickshell.screens entry, so the
            // popup can be placed on the focused window's monitor. Needed because
            // CompositorService.getFocusedScreen() is null on mango (not Hyprland/sway).
            function screenForName(name) {
                var s = Quickshell.screens
                for (var i = 0; i < s.length; i++)
                    if (s[i].name === name)
                        return s[i]
                return null
            }

            Process {
                id: clientProc
                command: ["mmsg", "get", "all-clients"]
                stdout: StdioCollector {
                    id: clientOut
                    onStreamFinished: {
                        var list = []
                        var focusedMon = ""
                        try {
                            var data = JSON.parse(clientOut.text)
                            list = data.clients || []
                            for (var i = 0; i < list.length; i++) {
                                if (list[i].is_focused) {
                                    focusedMon = list[i].monitor
                                    break
                                }
                            }
                        } catch (e) {
                            list = []
                        }
                        eng.clients = list
                        var scr = eng.screenForName(focusedMon)
                        if (scr) {
                            modal.targetScreen = scr
                            if (modal.contentWindow)
                                modal.contentWindow.screen = scr
                        }
                        modal.open()
                    }
                }
            }

            // Not focused -> no Escape/click close; auto-hide after the last poke.
            Timer {
                id: idleHide
                interval: 1200   // display duration after last Alt+Tab poke (1.2s)
                repeat: false
                onTriggered: modal.close()
            }

            function showSwitcher() {
                clientProc.running = true   // refresh -> onStreamFinished opens the modal
                idleHide.restart()
            }
            function hideSwitcher() {
                idleHide.stop()
                modal.close()
            }
            function toggleSwitcher() {
                if (modal.shouldBeVisible)
                    hideSwitcher()
                else
                    showSwitcher()
            }

            IpcHandler {
                target: "altswitcher"
                function toggle(): string { eng.toggleSwitcher(); return "ok" }
                function show(): string   { eng.showSwitcher();   return "ok" }
                function hide(): string   { eng.hideSwitcher();   return "ok" }
                // Direction handled by mango's focusstack; both just refresh + keep alive.
                function next(): string { eng.showSwitcher(); return "ok" }
                function prev(): string { eng.showSwitcher(); return "ok" }
            }

            DankModal {
                id: modal
                modalWidth: 640
                modalHeight: Math.max(120, Math.min(660, Theme.spacingL * 2 + eng.clients.length * 60))
                positioning: "center"
                shouldHaveFocus: false
                closeOnBackgroundClick: true
                // Overlay layer (not default Top): on mango a focused floating window
                // gets raised above Top-layer surfaces, which hid the popup. Overlay
                // sits above all toplevels.
                useOverlayLayer: true
                // Frosted glass: same matugen color as before (Theme.readableSurface,
                // still wallpaper-driven), but with an alpha so DankModal's wallpaper
                // blur shows through -- matching the DankBar/Nemo frosted look. Uses the
                // Qt.rgba(theme-color, alpha) pattern already used for text below.
                backgroundColor: Qt.rgba(Theme.readableSurface.r, Theme.readableSurface.g, Theme.readableSurface.b, 0.72)
                borderColor: Theme.outlineMedium

                content: Component {
                    Item {
                        anchors.fill: parent

                        Column {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingL
                            spacing: Theme.spacingS

                            Repeater {
                                model: eng.clients

                                StyledRect {
                                    width: parent.width
                                    height: 52
                                    radius: Theme.cornerRadius
                                    // Focused card stays solid (clear highlight); the rest are
                                    // semi-transparent so the frosted panel shows through. Both
                                    // colors remain matugen-driven (Theme.*), just alpha-wrapped.
                                    color: modelData.is_focused ? Theme.primaryContainer
                                                                : Qt.rgba(Theme.readableSurfaceHigh.r, Theme.readableSurfaceHigh.g, Theme.readableSurfaceHigh.b, 0.55)
                                    border.width: modelData.is_focused ? 2 : 0
                                    border.color: Theme.primary

                                    Row {
                                        anchors.fill: parent
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM

                                        Item {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 32
                                            height: 32

                                            IconImage {
                                                id: appIcon
                                                anchors.fill: parent
                                                smooth: true
                                                mipmap: true
                                                asynchronous: true
                                                visible: status === Image.Ready
                                                source: {
                                                    if (!modelData.appid)
                                                        return ""
                                                    return Paths.getAppIcon(modelData.appid,
                                                        DesktopEntries.heuristicLookup(modelData.appid))
                                                }
                                            }
                                            DankIcon {
                                                anchors.centerIn: parent
                                                visible: appIcon.status !== Image.Ready
                                                name: "web_asset"
                                                size: 26
                                                color: modelData.is_focused ? Theme.primary : Theme.surfaceText
                                            }
                                        }

                                        Column {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: parent.width - 32 - Theme.spacingM
                                            spacing: 1

                                            StyledText {
                                                width: parent.width
                                                elide: Text.ElideRight
                                                text: modelData.appid || "Unknown"
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: modelData.is_focused ? Font.DemiBold : Font.Normal
                                                color: modelData.is_focused ? Theme.primaryText : Theme.surfaceText
                                            }
                                            StyledText {
                                                width: parent.width
                                                elide: Text.ElideRight
                                                visible: (modelData.title || "") !== ""
                                                text: modelData.title || ""
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: modelData.is_focused
                                                       ? Qt.rgba(Theme.primaryText.r, Theme.primaryText.g, Theme.primaryText.b, 0.75)
                                                       : Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.65)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Bar pill (health-check / manual toggle). Present on every monitor's bar, but
    // only does something on the instance that owns the engine; Alt+Tab uses IPC,
    // which always reaches the single engine, so this is just a convenience.
    horizontalBarPill: Component {
        DankIcon {
            name: "switch_access_shortcut"
            color: Theme.primary
            size: Theme.iconSize - 6
        }
    }
    verticalBarPill: Component {
        DankIcon {
            name: "switch_access_shortcut"
            color: Theme.primary
            size: Theme.iconSize - 6
        }
    }
    pillClickAction: function () { if (engine.item) engine.item.toggleSwitcher() }
}
