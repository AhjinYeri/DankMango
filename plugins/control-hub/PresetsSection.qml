// =============================================================================
//  PresetsSection.qml  --  the hub's "Desktop presets" section
// =============================================================================
//
//  >>> IF THIS SECTION STOPPED WORKING, START HERE <<<
//  This file holds NO preset logic and no list of presets. Everything comes from
//  one script:
//
//        ~/.config/mango/scripts/set-preset.sh
//
//    * `--list --porcelain` gives it the items to show AND which one is active,
//      as tab-separated  name \t label \t icon \t blurb \t active(1|0)
//    * `<name>` applies one.
//
//  That is deliberate: adding a preset means adding a FOLDER under
//  ~/.config/mango/presets/, never editing this file. It is also exactly what
//  the launcher-type preset plugin does -- see WHY BOTH EXIST below.
//
//  So the two things an update can break here are the script's PATH and the
//  --porcelain OUTPUT SHAPE, and both are in the box below.
//
// -----------------------------------------------------------------------------
//  WHY BOTH THIS AND THE LAUNCHER PLUGIN EXIST
// -----------------------------------------------------------------------------
//  plugins/preset-switcher/ puts the same presets in DMS's launcher: open the
//  launcher, type "preset", pick one. That still works and is staying -- it is
//  the fast path for someone who already knows what they want, and it costs no
//  bar space and no keybind.
//
//  This is the other half: a surface you can LOOK at. A launcher row gets an
//  icon, a name and a subtitle, and then the launcher closes the instant you
//  choose -- so it can never show you a preset's blurb next to the others', and
//  it can never show you the switch actually taking effect. Here the cards sit
//  side by side, the active one is visibly the active one, and the panel is
//  still open afterwards to prove the check mark moved.
//
//  Both front-ends call the same script with the same arguments. Neither knows
//  the other exists.
//
// -----------------------------------------------------------------------------
//  WHAT A SECTION IS (if you are here to write another one)
// -----------------------------------------------------------------------------
//  An ordinary Item with two obligations, both visible in the first few lines
//  below:
//    * `implicitHeight` -- the panel sizes its card from it
//    * `property var hub: null` -- optional; ControlHubPanel fills it in after
//      loading, and it is how you reach panelOpen, closePanel(), and anything
//      else the shell exposes
//  Everything else is yours. Register it in the `sections` array in
//  ControlHubPanel.qml and it appears in the nav list.
// =============================================================================

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: section

    // Filled in by ControlHubPanel's Loader. Used only to notice the panel being
    // re-opened (see the Connections at the bottom) -- the section works without
    // it, it just wouldn't re-read the list.
    property var hub: null

    implicitHeight: content.implicitHeight

    // #########################################################################
    // ########## EDIT HERE IF THE SCRIPT MOVES OR CHANGES #####################
    // #########################################################################

    // Resolved from $HOME at run time via `sh -c`, because execDetached runs no
    // shell and a bare "~" would be passed through literally.
    readonly property string presetTool: "\"$HOME/.config/mango/scripts/set-preset.sh\""

    // The --porcelain contract, documented in set-preset.sh's own header:
    //     name \t label \t icon \t blurb \t active(1|0)
    // If a future set-preset.sh changes the field order, fix parseList() below.
    readonly property int fieldCount: 5

    // #########################################################################

    // Each entry: { name, label, icon, blurb, active }
    property var presets: []

    // Set once the first read has come back, so "no presets" can be told apart
    // from "we haven't looked yet" -- the difference between showing a
    // something-is-wrong message and showing nothing at all.
    property bool loaded: false

    // Guards the cards while a switch is in flight. The reload takes a moment and
    // a second click during it would run a second switch for no reason.
    property string applying: ""

    Process {
        id: listProc
        command: ["sh", "-c", section.presetTool + " --list --porcelain"]
        running: false
        stdout: StdioCollector {
            id: listOut
            onStreamFinished: section.parseList(listOut.text)
        }
    }

    function refresh() {
        listProc.running = false
        listProc.running = true
    }

    // Anything without all five fields is skipped rather than shown half-parsed:
    // a malformed line means the script and this file disagree, and a card with
    // no name would apply nothing when clicked.
    function parseList(txt) {
        var out = []
        if (txt) {
            var lines = txt.split("\n")
            for (var i = 0; i < lines.length; i++) {
                if (lines[i].length === 0)
                    continue
                var f = lines[i].split("\t")
                if (f.length < section.fieldCount || f[0].length === 0)
                    continue
                out.push({
                    "name": f[0],
                    "label": f[1].length > 0 ? f[1] : f[0],
                    "icon": f[2].length > 0 ? f[2] : "tune",
                    "blurb": f[3],
                    "active": f[4] === "1"
                })
            }
        }
        section.presets = out
        section.loaded = true
    }

    // The preset name is forwarded as "$@" so it is an ARGUMENT and never spliced
    // into the command string. set-preset.sh does the validation, the atomic
    // symlink swap, the reload and the manifest write -- none of that lives here.
    function apply(name) {
        if (section.applying !== "")
            return
        section.applying = name
        Quickshell.execDetached(["sh", "-c", section.presetTool + " \"$@\"", "sh", name])
        settleTimer.restart()
    }

    // Comfortably past the symlink swap and mango's reload. Unlike the launcher
    // -- which has closed by now and can only leave a toast behind -- the panel
    // is still open, so the re-read below moves the check mark in front of the
    // person who just clicked.
    Timer {
        id: settleTimer
        interval: 400
        repeat: false
        onTriggered: {
            section.applying = ""
            section.refresh()
        }
    }

    Component.onCompleted: section.refresh()

    Column {
        id: content
        width: parent.width
        spacing: Theme.spacingM

        StyledText {
            width: parent.width
            wrapMode: Text.WordWrap
            color: Theme.surfaceTextMedium
            font.pixelSize: Theme.fontSizeSmall
            text: "A preset is a bundle of desktop settings you can swap in and out as a unit. Switching is instant and leaves nothing behind — your own settings are never edited."
        }

        // ---- The "something is wrong" case -------------------------------
        // Only shown once a read has actually come back empty. Says what was
        // expected and what to do, rather than just being blank.
        StyledRect {
            width: parent.width
            visible: section.loaded && section.presets.length === 0
            height: visible ? emptyRow.implicitHeight + Theme.spacingM * 2 : 0
            radius: Theme.cornerRadius
            color: Qt.rgba(Theme.surfaceContainerHigh.r, Theme.surfaceContainerHigh.g, Theme.surfaceContainerHigh.b, 0.5)
            border.width: 1
            border.color: Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.4)

            Row {
                id: emptyRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "error_outline"
                    size: Theme.iconSize - 2
                    color: Theme.error
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Theme.iconSize - Theme.spacingM * 2
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                    text: "No presets found. They should be in ~/.config/mango/presets/ — re-run install.sh from your DankMango folder."
                }
            }
        }

        // ---- The cards ----------------------------------------------------
        // Same idiom as monitor-mode's layout tiles -- StyledRect, accent border
        // and wash when selected, StateLayer for the click and its ripple -- but
        // full-width rows rather than a grid, because each preset carries a
        // sentence of explanation and a grid cell has nowhere to put one.
        Repeater {
            model: section.presets

            StyledRect {
                id: presetCard

                readonly property bool isActive: modelData.active
                readonly property bool isApplying: section.applying === modelData.name

                width: content.width
                height: Math.max(64, cardText.implicitHeight + Theme.spacingM * 2)
                radius: Theme.cornerRadius
                color: isActive
                    ? Theme.primaryPressed
                    : Qt.rgba(Theme.surfaceContainerHigh.r, Theme.surfaceContainerHigh.g, Theme.surfaceContainerHigh.b, 0.55)
                border.width: isActive ? 3 : 1
                border.color: isActive
                    ? Theme.primary
                    : Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.4)

                // Dimmed while its own switch is in flight, so a slow reload
                // looks like something happening rather than like a dead click.
                opacity: section.applying !== "" && !isApplying ? 0.5 : 1

                Behavior on color {
                    ColorAnimation {
                        duration: Theme.shortDuration
                        easing.type: Theme.standardEasing
                    }
                }

                Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingM
                    spacing: Theme.spacingM

                    DankIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: modelData.icon
                        size: Theme.iconSize
                        color: presetCard.isActive ? Theme.primary : Theme.surfaceText
                    }

                    Column {
                        id: cardText
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - Theme.iconSize - activeMark.width - Theme.spacingM * 3
                        spacing: 2

                        StyledText {
                            width: parent.width
                            text: modelData.label
                            color: presetCard.isActive ? Theme.primary : Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: presetCard.isActive ? Font.Medium : Font.Normal
                            elide: Text.ElideRight
                        }

                        StyledText {
                            width: parent.width
                            text: modelData.blurb
                            color: Theme.surfaceTextMedium
                            font.pixelSize: Theme.fontSizeSmall
                            wrapMode: Text.WordWrap
                        }
                    }

                    // The active preset is marked by the border AND by this,
                    // because the border alone is a colour cue and colour alone
                    // is not an answer to "which one am I on?".
                    Item {
                        id: activeMark
                        anchors.verticalCenter: parent.verticalCenter
                        width: Theme.iconSize
                        height: Theme.iconSize

                        DankIcon {
                            anchors.centerIn: parent
                            name: "check_circle"
                            size: Theme.iconSize - 2
                            color: Theme.primary
                            visible: presetCard.isActive && !presetCard.isApplying
                        }

                        DankIcon {
                            anchors.centerIn: parent
                            name: "hourglass_top"
                            size: Theme.iconSize - 2
                            color: Theme.primary
                            visible: presetCard.isApplying
                        }
                    }
                }

                // Clicking the one you are already on is a no-op rather than a
                // pointless reload, and nothing is clickable while a switch is
                // in flight.
                //
                // `disabled` and `enabled` are BOTH set because they do different
                // jobs: StateLayer's own `disabled` drops the hover/ripple and
                // the pointing-hand cursor (so a dead card doesn't invite the
                // click), while `enabled` is MouseArea's and is what actually
                // stops the press landing.
                StateLayer {
                    stateColor: Theme.primary
                    disabled: presetCard.isActive || section.applying !== ""
                    enabled: !disabled
                    onClicked: section.apply(modelData.name)
                }
            }
        }
    }

    // The panel can be closed and re-opened without this file being reloaded --
    // the Loader keeps it alive as long as the section stays selected. Someone
    // may well have run `set-preset.sh` in a terminal in between, so re-read on
    // every open rather than trusting what was on screen last time.
    Connections {
        target: section.hub
        enabled: section.hub !== null
        function onPanelOpenChanged() {
            if (section.hub.panelOpen)
                section.refresh()
        }
    }
}
