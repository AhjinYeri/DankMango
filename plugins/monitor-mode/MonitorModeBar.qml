// =============================================================================
//  Monitor Mode  --  DMS bar plugin (front-end for the monitor scripts)
// =============================================================================
//
//  >>> IF THIS PLUGIN STOPPED WORKING AFTER A SYSTEM UPDATE, START HERE <<<
//  The plain-English guide next to this file explains what to check:
//        README.md  (in this same folder)
//
//  This plugin holds almost NO logic -- every button just runs a shell script.
//  The things here that can break after an update are:
//
//    1. `layoutSetter` / `setter` (below) -- paths to the scripts, resolved from
//       $HOME at run time via `sh -c` (execDetached runs no shell, so a bare "~"
//       would not expand). If you move your scripts, change them here.
//         layoutSetter -> set-monitor-layout.sh  (the 6 tiling layouts; ACTIVE)
//         setter       -> set-monitor-mode.sh    (tile/float; retained for the
//                         Float re-introduction -- see the big comment in the
//                         popout. Float is intentionally hidden for now.)
//    2. `monitors` (below) -- detected LIVE from Quickshell.screens (connector +
//       EDID model name), sorted left-to-right. Nothing to hand-edit when your
//       monitors change.
//    3. DMS building blocks used below -- PluginComponent, PopoutComponent,
//       DankIcon, StateLayer, StyledRect, StyledText, Theme.*, FileView, and
//       Quickshell.execDetached / Quickshell.screens / Quickshell.env. If a DMS
//       update renames one of these the plugin fails to load; see README.md.
//       (Gotcha that bit us once: DankIcon uses `size:`, NOT `font.pixelSize:`.)
//
//  All accent/selection colour comes from Theme.* (the live matugen palette),
//  so the UI re-tints on a wallpaper change with no restart.
//
//  After ANY edit to this file, run `dms restart` to pick it up (a plain
//  re-toggle reuses a cached copy). See README.md.
// =============================================================================

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // --- Script paths (resolved from $HOME at run time via `sh -c`) -----------
    // execDetached runs no shell, so setLayout()/setMode() invoke through `sh -c`
    // to expand $HOME; no personal absolute path is baked in.
    readonly property string layoutSetter: "\"$HOME/.config/mango/scripts/set-monitor-layout.sh\""
    readonly property string setter: "\"$HOME/.config/mango/scripts/set-monitor-mode.sh\"" // retained for Float re-add

    // --- The 6 curated tiling layouts -----------------------------------------
    // `name` is the exact mango layout_name string (verified; see the
    // mango-layout-names note). `icon` is a Material Symbol (decorative -- the
    // label is the source of truth). set-monitor-layout.sh whitelists these
    // exact names, so a typo here just no-ops rather than breaking the config.
    readonly property var layouts: [
        { "name": "tile",        "label": "Tiling",        "icon": "grid_view" },
        { "name": "monocle",     "label": "Monocle",       "icon": "crop_square" },
        { "name": "scroller",    "label": "Scrolling",     "icon": "view_carousel" },
        { "name": "grid",        "label": "Grid",          "icon": "grid_on" },
        { "name": "deck",        "label": "Deck",          "icon": "layers" },
        { "name": "center_tile", "label": "Center Tiling", "icon": "align_horizontal_center" }
    ]

    // --- Live per-monitor layout, parsed from tagrules.conf -------------------
    // Reflects the CURRENT config so the grid shows which layout is active and
    // re-tints after a change (set-monitor-layout.sh writes the file + reloads;
    // watchChanges -> reload() -> onLoaded repopulates this map). Same reactive
    // FileView pattern DMS uses for settings.json.
    property var currentLayouts: ({})

    FileView {
        id: tagrulesFile
        path: Quickshell.env("HOME") + "/.config/mango/dms/tagrules.conf"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.currentLayouts = root.parseLayouts(tagrulesFile.text())
    }

    // One "layout_name" per monitor (all 9 tag lines share it) -> {conn: layout}.
    function parseLayouts(txt) {
        var map = {}
        if (!txt)
            return map
        var lines = txt.split("\n")
        var reMon = /monitor_name:\s*([A-Za-z0-9_-]+)/
        var reLay = /layout_name:\s*([A-Za-z_]+)/
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i]
            if (l.indexOf("tagrule") < 0)
                continue
            var m = reMon.exec(l)
            var y = reLay.exec(l)
            if (m && y && !(m[1] in map))
                map[m[1]] = y[1]
        }
        return map
    }

    // --- Live monitor detection (UNCHANGED -- works on any hardware) ----------
    // Detected LIVE from the compositor (Quickshell.screens) -- no hardcoded
    // connectors. `conn` is passed to the scripts; `label` is the EDID model
    // name DMS Displays shows (fallbacks below). Sorted left-to-right by x.
    readonly property var monitors: {
        // Reference WlrOutputService.serial so this binding RE-EVALUATES when the
        // dms backend pushes output data asynchronously (make/model arrive after
        // component creation). Without this the labels could stick permanently on
        // the connector-name fallback if evaluated before that backend event.
        var _serial = WlrOutputService.serial
        var list = []
        var screens = Quickshell.screens
        for (var i = 0; i < screens.length; i++) {
            var s = screens[i]
            list.push({
                "conn": s.name,
                "label": root.labelFor(s),
                "x": s.x
            })
        }
        list.sort(function (a, b) {
            return a.x - b.x
        })
        return list
    }

    // Best available human label for a screen, in priority order:
    //   1. Real make + model from WlrOutputService (the SAME source DMS Settings
    //      > Displays uses; works even when sysfs EDID is 0 bytes and s.model is
    //      the literal "Unknown" sentinel).
    //   2. WlrOutputService model alone (guarded against "Unknown").
    //   3. Quickshell's s.model (guarded against "Unknown") -- legacy path.
    //   4. The connector name (s.name, e.g. "DP-1") -- always-correct last resort.
    function labelFor(s) {
        var o = WlrOutputService.getOutput(s.name)
        if (o) {
            if (o.make && o.model)
                return o.make + " " + o.model
            if (o.model && o.model !== "Unknown")
                return o.model
        }
        if (s.model && s.model.length > 0 && s.model !== "Unknown")
            return s.model
        return s.name
    }

    // Live "WxH" for a connector from Quickshell.screens (matches DMS Displays).
    function resolutionFor(conn) {
        for (var i = 0; i < Quickshell.screens.length; i++) {
            var s = Quickshell.screens[i]
            if (s.name === conn)
                return s.width + "×" + s.height
        }
        return ""
    }

    // Friendly label for a connector (for the section header).
    function labelForConn(conn) {
        for (var i = 0; i < root.monitors.length; i++)
            if (root.monitors[i].conn === conn)
                return root.monitors[i].label
        return conn
    }

    // --- Script call sites ----------------------------------------------------
    // Apply a layout to ONE monitor. Run via `sh -c` so $HOME expands; the
    // MON:layout token is forwarded as "$@". No popout close -- the picker stays
    // open so you can set several monitors in one go (dismiss with the X).
    function setLayout(conn, layout) {
        if (!conn)
            return
        Quickshell.execDetached(["sh", "-c", root.layoutSetter + " \"$@\"", "sh", conn + ":" + layout])
    }

    // Set a monitor to tile/float. UNUSED while Float is hidden -- kept so the
    // Float re-introduction (see popout comment) is a button add, not a rebuild.
    function setMode(conn, mode) {
        if (!conn)
            return
        Quickshell.execDetached(["sh", "-c", root.setter + " \"$@\"", "sh", conn + ":" + mode])
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

            headerText: "Window Layout"
            detailsText: "Pick a monitor, then a layout"
            showCloseButton: true

            // Which monitor the layout grid targets. Defaults to the first
            // monitor every time the popout opens (fresh instance) -- never an
            // empty state. Clicking a card assigns this (breaking the default).
            property string activeConn: root.monitors.length > 0 ? root.monitors[0].conn : ""

            Column {
                width: parent.width
                spacing: Theme.spacingL

                // ---- Monitor selector: clickable DMS-style cards ----
                // Selected card uses the SAME treatment as the wallpaper picker's
                // selected thumbnail: 3px Theme.primary border + primaryPressed
                // tint + StateLayer hover -- all live matugen colours.
                Row {
                    id: monRow
                    width: parent.width
                    spacing: Theme.spacingM

                    // Equal-width cards that fill the row for any monitor count.
                    property real cardW: root.monitors.length > 0
                        ? (width - Theme.spacingM * (root.monitors.length - 1)) / root.monitors.length
                        : width

                    Repeater {
                        model: root.monitors

                        StyledRect {
                            id: monCard
                            property bool isActive: popout.activeConn === modelData.conn

                            width: monRow.cardW
                            height: cardCol.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh
                            border.width: isActive ? 3 : 1
                            border.color: isActive
                                ? Theme.primary
                                : Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.4)

                            // Selected fill tint (matches wallpaper picker).
                            Rectangle {
                                anchors.fill: parent
                                radius: parent.radius
                                color: monCard.isActive ? Theme.primaryPressed : Theme.withAlpha(Theme.primaryPressed, 0)
                                Behavior on color {
                                    ColorAnimation {
                                        duration: Theme.shortDuration
                                        easing.type: Theme.standardEasing
                                    }
                                }
                            }

                            Column {
                                id: cardCol
                                anchors.centerIn: parent
                                width: parent.width - Theme.spacingM * 2
                                spacing: Theme.spacingXS

                                DankIcon {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    name: "monitor"
                                    size: Theme.iconSize
                                    color: monCard.isActive ? Theme.primary : Theme.surfaceText
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

                            // StateLayer IS a MouseArea: gives ripple/hover AND click.
                            StateLayer {
                                stateColor: Theme.primary
                                onClicked: popout.activeConn = modelData.conn
                            }
                        }
                    }
                }

                // ---- Divider ----
                Rectangle {
                    width: parent.width
                    height: 1
                    color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.3)
                }

                // ---- Layout grid (always visible; 3×2 of the 6 curated layouts) ----
                Column {
                    width: parent.width
                    spacing: Theme.spacingS

                    StyledText {
                        text: popout.activeConn !== "" ? ("Layout · " + root.labelForConn(popout.activeConn)) : "Layout"
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                        elide: Text.ElideRight
                        width: parent.width
                    }

                    Grid {
                        id: layoutGrid
                        width: parent.width
                        columns: 3
                        columnSpacing: Theme.spacingS
                        rowSpacing: Theme.spacingS

                        property real cellW: (width - columnSpacing * (columns - 1)) / columns

                        Repeater {
                            model: root.layouts

                            StyledRect {
                                id: layTile
                                // Reflects the live config layout for the active monitor.
                                property bool isSelected: root.currentLayouts[popout.activeConn] === modelData.name

                                width: layoutGrid.cellW
                                height: 74
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainerHigh
                                border.width: isSelected ? 3 : 1
                                border.color: isSelected
                                    ? Theme.primary
                                    : Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.4)

                                Rectangle {
                                    anchors.fill: parent
                                    radius: parent.radius
                                    color: layTile.isSelected ? Theme.primaryPressed : Theme.withAlpha(Theme.primaryPressed, 0)
                                    Behavior on color {
                                        ColorAnimation {
                                            duration: Theme.shortDuration
                                            easing.type: Theme.standardEasing
                                        }
                                    }
                                }

                                Column {
                                    anchors.centerIn: parent
                                    width: parent.width - Theme.spacingS * 2
                                    spacing: Theme.spacingXS

                                    DankIcon {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        name: modelData.icon
                                        size: Theme.iconSize
                                        color: layTile.isSelected ? Theme.primary : Theme.surfaceText
                                    }

                                    StyledText {
                                        width: parent.width
                                        horizontalAlignment: Text.AlignHCenter
                                        text: modelData.label
                                        color: layTile.isSelected ? Theme.primary : Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: layTile.isSelected ? Font.Medium : Font.Normal
                                        elide: Text.ElideRight
                                    }
                                }

                                StateLayer {
                                    stateColor: Theme.primary
                                    onClicked: root.setLayout(popout.activeConn, modelData.name)
                                }
                            }
                        }
                    }
                }

                // =====================================================================
                //  FLOAT MODE -- TEMPORARILY REMOVED (easy add-back point)
                // ---------------------------------------------------------------------
                //  Float (tile/float per monitor) is intentionally hidden here until the
                //  known "floating window stays at native size" bug in dp2-floatsize.sh
                //  is refined. The underlying feature is UNTOUCHED and still works
                //  (set-monitor-mode.sh + dp2-floatsize.sh + the SUPER+SHIFT+v keybind).
                //  NOTE: those two scripts are NO LONGER IN THE REPO (private dots only) -- reintroducing Float here means restoring/rebuilding them too, not just uncommenting this UI.
                //
                //  To bring it back into THIS UI, drop a per-monitor Tile/Float control
                //  under the layout grid (or as a header segment) that calls, for the
                //  selected monitor:
                //        root.setMode(popout.activeConn, "tile")     // re-tile
                //        root.setMode(popout.activeConn, "float")    // float
                //  `setMode()` and the `setter` path above are retained for exactly
                //  this. A matching "current mode" glow can read open_as_floating from
                //  tagrules.conf via the same parse used for layouts (currentLayouts).
                // =====================================================================
            }
        }
    }

    popoutWidth: 380
    popoutHeight: 440
}
