// =============================================================================
//  Monitor Mode  --  DMS bar plugin (front-end for set-monitor-mode.sh)
// =============================================================================
//
//  >>> IF THIS PLUGIN STOPPED WORKING AFTER A SYSTEM UPDATE, START HERE <<<
//  The plain-English guide next to this file explains what to check:
//        README.md  (in this same folder)
//
//  This plugin holds NO logic -- every button just runs the shell script
//  set-monitor-mode.sh. The only things here that can break after an update are:
//
//    1. `setter` (below) -- the path to set-monitor-mode.sh, resolved from $HOME
//       at run time via `sh -c` (execDetached runs no shell, so a bare "~" would
//       not expand). If you move your scripts, change it here.
//    2. `monitors` (below) -- now detected LIVE from Quickshell.screens (connector
//       + EDID model name), sorted left-to-right. Nothing to hand-edit when your
//       monitors change; if a name looks wrong, check `s.model`/`s.name` there.
//    3. DMS (DankMaterialShell) building blocks used below -- PluginComponent,
//       PopoutComponent, DankButton, DankIcon, StyledRect, StyledText, Theme.*,
//       and Quickshell.execDetached / Quickshell.screens. If a DMS update renames
//       one of these, the plugin fails to load; see README.md for how to read the
//       error log. (Gotcha that bit us once: DankIcon uses `size:`, NOT
//       `font.pixelSize:`.)
//
//  After ANY edit to this file, run `dms restart` to pick it up (a plain
//  re-toggle reuses a cached copy). See README.md.
// =============================================================================

import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Front-end ONLY. Every button just calls set-monitor-mode.sh with MON:mode args;
// all mode logic + the desktop notification live in that proven script
// (~/.config/mango/scripts/set-monitor-mode.sh). The plugin holds no state.
PluginComponent {
    id: root

    // Path resolved from $HOME at run time (matches audioToggle) so no personal
    // absolute path is baked in; execDetached runs no shell, so setMode() invokes
    // it through `sh -c` to expand $HOME.
    readonly property string setter: "\"$HOME/.config/mango/scripts/set-monitor-mode.sh\""

    // Monitors are detected LIVE from the compositor (Quickshell.screens) — no
    // hardcoded connectors, so this works on any setup. `conn` is the connector
    // passed to the script; `label` is the EDID model name DMS Displays shows
    // (falls back to the connector if the model is unknown). Sorted left-to-right
    // by x so cards and combos match the physical layout.
    readonly property var monitors: {
        var list = []
        var screens = Quickshell.screens
        for (var i = 0; i < screens.length; i++) {
            var s = screens[i]
            list.push({
                "conn": s.name,
                "label": (s.model && s.model.length > 0) ? s.model : s.name,
                "x": s.x
            })
        }
        list.sort(function (a, b) {
            return a.x - b.x
        })
        return list
    }

    // Live "WxH" for a connector from Quickshell.screens (matches DMS Displays styling).
    function resolutionFor(conn) {
        for (var i = 0; i < Quickshell.screens.length; i++) {
            var s = Quickshell.screens[i]
            if (s.name === conn)
                return s.width + "×" + s.height
        }
        return ""
    }

    // Single call site for every button: run the setter with MON:mode tokens.
    // One call = one config reload + one notification (the script handles both).
    // Run via `sh -c` so $HOME in `setter` expands; tokens are forwarded as "$@".
    function setMode(args) {
        Quickshell.execDetached(["sh", "-c", root.setter + " \"$@\"", "sh"].concat(args))
    }

    // Every detected monitor set to one mode (each connector + ":" + mode).
    function allMode(mode) {
        var a = []
        for (var i = 0; i < root.monitors.length; i++)
            a.push(root.monitors[i].conn + ":" + mode)
        return a
    }

    horizontalBarPill: Component {
        DankIcon {
            name: "splitscreen"
            color: Theme.primary
            size: Theme.iconSize - 6
        }
    }

    verticalBarPill: Component {
        DankIcon {
            name: "splitscreen"
            color: Theme.primary
            size: Theme.iconSize - 6
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: "Window Modes"
            detailsText: "Set each monitor, or pick a combo"
            showCloseButton: true

            Column {
                width: parent.width
                spacing: Theme.spacingL

                // ---- Per-monitor: a DMS-style monitor card + Tile/Float under each ----
                Row {
                    width: parent.width
                    spacing: Theme.spacingM

                    Repeater {
                        model: root.monitors

                        Column {
                            // Two equal columns across the popout width.
                            width: (parent.width - Theme.spacingM) / 2
                            spacing: Theme.spacingS

                            // Monitor card — mirrors DMS Displays > Monitor Configuration:
                            // bordered surfaceContainerHigh panel, monitor icon, name,
                            // resolution underneath.
                            StyledRect {
                                width: parent.width
                                height: cardCol.implicitHeight + Theme.spacingM * 2
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainerHigh
                                border.width: 1
                                border.color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.4)

                                Column {
                                    id: cardCol
                                    anchors.centerIn: parent
                                    width: parent.width - Theme.spacingM * 2
                                    spacing: Theme.spacingXS

                                    DankIcon {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        name: "monitor"
                                        size: Theme.iconSize
                                        color: Theme.primary
                                    }

                                    StyledText {
                                        width: parent.width
                                        horizontalAlignment: Text.AlignHCenter
                                        text: modelData.label
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        elide: Text.ElideRight
                                    }

                                    StyledText {
                                        width: parent.width
                                        horizontalAlignment: Text.AlignHCenter
                                        text: root.resolutionFor(modelData.conn)
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                }
                            }

                            DankButton {
                                width: parent.width
                                buttonHeight: 36
                                text: "Tile"
                                iconName: "grid_view"
                                onClicked: {
                                    root.setMode([modelData.conn + ":tile"])
                                    popout.closePopout()
                                }
                            }

                            DankButton {
                                width: parent.width
                                buttonHeight: 36
                                text: "Float"
                                iconName: "open_in_full"
                                onClicked: {
                                    root.setMode([modelData.conn + ":float"])
                                    popout.closePopout()
                                }
                            }
                        }
                    }
                }

                // ---- Divider between per-monitor and combos ----
                Rectangle {
                    width: parent.width
                    height: 1
                    color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.3)
                }

                // ---- Combo presets (2×2 grid; left of "/" = first monitor, right = second) ----
                Column {
                    width: parent.width
                    spacing: Theme.spacingS

                    StyledText {
                        text: root.monitors.length === 2 ? ("Combos · " + root.monitors[0].conn + " / " + root.monitors[1].conn) : "Combos"
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                    }

                    Grid {
                        width: parent.width
                        columns: 2
                        columnSpacing: Theme.spacingS
                        rowSpacing: Theme.spacingS

                        property real cellWidth: (width - columnSpacing) / 2

                        DankButton {
                            width: parent.cellWidth
                            buttonHeight: 36
                            text: "All Tile"
                            iconName: "grid_view"
                            onClicked: {
                                root.setMode(root.allMode("tile"))
                                popout.closePopout()
                            }
                        }

                        DankButton {
                            width: parent.cellWidth
                            buttonHeight: 36
                            text: "All Float"
                            iconName: "open_in_full"
                            onClicked: {
                                root.setMode(root.allMode("float"))
                                popout.closePopout()
                            }
                        }

                        // Mixed presets only make sense with exactly two monitors;
                        // positioners skip invisible children, so they vanish otherwise.
                        DankButton {
                            visible: root.monitors.length === 2
                            width: parent.cellWidth
                            buttonHeight: 36
                            text: "Tile / Float"
                            onClicked: {
                                root.setMode([root.monitors[0].conn + ":tile", root.monitors[1].conn + ":float"])
                                popout.closePopout()
                            }
                        }

                        DankButton {
                            visible: root.monitors.length === 2
                            width: parent.cellWidth
                            buttonHeight: 36
                            text: "Float / Tile"
                            onClicked: {
                                root.setMode([root.monitors[0].conn + ":float", root.monitors[1].conn + ":tile"])
                                popout.closePopout()
                            }
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 360
    popoutHeight: 470
}
