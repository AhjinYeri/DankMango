#!/usr/bin/env bash
# =============================================================================
#  apply-combined-osd-patch.sh  --  DankMango combined audio OSD patch
# =============================================================================
#  Patches DMS's VolumeOSD.qml to add a device-name line, so an audio-output
#  switch shows ONE popup (icon + device name + volume slider) instead of two
#  stacked OSDs. The name comes from AudioService.displayName(), so it honours
#  custom device aliases (e.g. "Edifier R1280DB 2.0").
#
#  WHY THIS SCRIPT EXISTS: the target file is package-owned (dms-shell, root:root)
#  and is OVERWRITTEN by every DMS update. post-update-health.sh detects when the
#  patch has been clobbered and tells you to re-run this script. It is idempotent
#  (skips if already patched, unless --force) and backs up the current file first.
#
#  Usage:   ~/.config/mango/scripts/apply-combined-osd-patch.sh [--force]
#  (needs sudo -- it writes a root-owned file; you'll be prompted for a password)
# =============================================================================
set -euo pipefail

TARGET=/usr/share/quickshell/dms/Modules/OSD/VolumeOSD.qml
MARKER='DankMango patch: combined OSD device name'
BACKUP_DIR="$HOME/.config/mango/backups"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# --- already patched? bail early (unless --force) ----------------------------
if [ -f "$TARGET" ] && grep -qF "$MARKER" "$TARGET" && [ "$FORCE" -eq 0 ]; then
    echo "[combined-osd-patch] Already applied -- $TARGET has the marker. Nothing to do."
    echo "                     (re-run with --force to overwrite anyway.)"
    exit 0
fi

# --- materialise the patched file we ship (embedded below) -------------------
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<'DANKMANGO_VOLUMEOSD_EOF'
import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

DankOSD {
    id: root

    readonly property bool useVertical: isVerticalLayout
    property int _displayVolume: 0

    function _syncVolume() {
        if (!AudioService.sink?.audio)
            return;
        _displayVolume = Math.min(AudioService.sinkMaxVolume, Math.round(AudioService.sink.audio.volume * 100));
    }

    // ---- DankMango patch: combined OSD device name --------------------------------
    // Adds a device-name line to the volume OSD so an audio-output switch shows ONE
    // popup (icon + device name + slider) instead of stacking a separate
    // AudioOutputOSD box on top of it. Sourced from AudioService.displayName(), so it
    // honours custom device aliases (e.g. "Edifier R1280DB 2.0").
    //
    // This file is PACKAGE-OWNED (dms-shell) and is OVERWRITTEN by DMS updates. It is
    // reapplied by  ~/.config/mango/scripts/apply-combined-osd-patch.sh  and its
    // presence is verified by  ~/.config/mango/scripts/post-update-health.sh , which
    // greps for the marker string  "DankMango patch: combined OSD device name"  below.
    readonly property string deviceName: AudioService.sink ? AudioService.displayName(AudioService.sink) : ""

    // Tracks whether a sink has EVER resolved. Used by the onSinkChanged handler below
    // to tell "the user just switched output" apart from "the shell is starting up and
    // the sink went null -> real", which must NOT flash the OSD on login.
    property bool _hadSink: false
    // ---- end DankMango patch ------------------------------------------------------

    osdWidth: useVertical ? (40 + Theme.spacingS * 2) : Math.min(260, screenWidth - Theme.spacingM * 2)
    // Horizontal OSD height = 9px top gap + name line + 1px name-to-slider gap + slider row
    // + 5px bottom gap (top-anchored content; see the Column's anchors below).
    osdHeight: useVertical ? Math.min(260, screenHeight - Theme.spacingM * 2) : (9 + (Theme.fontSizeMedium + Theme.spacingXS) + 1 + Theme.iconSize + 5)
    autoHideInterval: 3000
    enableMouseInteraction: true

    Connections {
        target: AudioService.sink?.audio ?? null

        function onVolumeChanged() {
            root._syncVolume();
            if (SettingsData.osdVolumeEnabled)
                root.show();
        }

        function onMutedChanged() {
            if (SettingsData.osdVolumeEnabled)
                root.show();
        }
    }

    Connections {
        target: AudioService

        // ---- DankMango patch: combined OSD device name ----------------------------
        // Upstream only re-syncs an ALREADY-VISIBLE OSD here (the shouldBeVisible
        // guard), so a default-sink change on its own can never OPEN the OSD.
        //
        // That went unnoticed because this repo's card-profile switching path happens
        // to work by accident: `pactl set-card-profile` DESTROYS the old sink node and
        // PipeWire creates a new one, and the new node's volume property populating
        // asynchronously fires volumeChanged on the Connections block above -- which
        // does show() unconditionally. The OSD was riding on node creation, not on the
        // sink change.
        //
        // A machine with two genuinely independent sinks (laptop speakers + projector)
        // never destroys a node: `wpctl set-default` just re-points defaultAudioSink at
        // an already-populated object. Rebinding a Connections target emits nothing, so
        // volumeChanged never fires and no OSD ever appeared on those switches.
        //
        // So open the OSD from here too -- but only once a sink has previously resolved,
        // otherwise the startup null -> sink transition flashes it on every login.
        function onSinkChanged() {
            root._syncVolume();
            if ((root._hadSink || root.shouldBeVisible) && SettingsData.osdVolumeEnabled)
                root.show();
            root._hadSink = (AudioService.sink != null);
        }
        // ---- end DankMango patch --------------------------------------------------
    }

    content: Loader {
        anchors.fill: parent
        sourceComponent: useVertical ? verticalContent : horizontalContent
    }

    Component {
        id: horizontalContent

        // ---- DankMango patch: combined OSD device name --------------------------------
        // Original icon+slider Item is preserved verbatim below; it is now the second
        // child of a Column whose first child is the device-name line.
        Column {
            // Top-anchored (not centred): the name sits a fixed 9px below the OSD top edge,
            // with a 1px gap down to the slider row (9+1 keeps the slider row and the overall
            // height unchanged -- only the text shifts down). (User-tuned exact spacing.)
            anchors.top: parent.top
            anchors.topMargin: 9
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - Theme.spacingS * 2
            spacing: 1

            // Bare single-line label at its NATURAL height -- deliberately NOT wrapped in
            // a fixed-height Item. That wrapper added ~4px of internal slack which stacked
            // with the Column's spacing into an uneven gap below the name (and extra box
            // height). With a bare Text the only gap to the row below is the one Column
            // spacing, so icon+name+slider read as a cohesive block.
            //   * font.weight (not font.bold): StyledText binds font.weight: Theme.fontWeight,
            //     which masks font.bold; an explicit weight overrides that binding.
            //   * maximumLineCount pins to one line so a long name elides (StyledText's base
            //     wrapMode is WordWrap, which would otherwise wrap and blow the height budget).
            StyledText {
                width: parent.width
                height: Theme.fontSizeMedium + Theme.spacingXS
                text: root.deviceName
                horizontalAlignment: Text.AlignHCenter
                maximumLineCount: 1
                elide: Text.ElideRight
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Bold
                color: Theme.surfaceText
                visible: text.length > 0
            }
            // ---- end DankMango patch --------------------------------------------------

            Item {
                property int gap: Theme.spacingS

                width: parent.width
                // Row holds the mute icon + slider, sized to the icon.
                height: Theme.iconSize

                Rectangle {
                    width: Theme.iconSize
                    height: Theme.iconSize
                    radius: Theme.iconSize / 2
                    color: "transparent"
                    x: parent.gap
                    anchors.verticalCenter: parent.verticalCenter

                    DankIcon {
                        anchors.centerIn: parent
                        name: AudioService.sink?.audio?.muted ? "volume_off" : "volume_up"
                        size: Theme.iconSize
                        color: muteButton.containsMouse ? Theme.primary : Theme.surfaceText
                    }

                    MouseArea {
                        id: muteButton

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: AudioService.toggleMute()
                        onContainsMouseChanged: setChildHovered(containsMouse || volumeSlider.containsMouse)
                    }
                }

                DankSlider {
                    id: volumeSlider

                    width: parent.width - Theme.iconSize - parent.gap * 3
                    height: Theme.iconSize
                    x: parent.gap * 2 + Theme.iconSize
                    anchors.verticalCenter: parent.verticalCenter
                    minimum: 0
                    maximum: AudioService.sinkMaxVolume
                    enabled: AudioService.sink?.audio ?? false
                    showValue: true
                    unit: "%"
                    thumbOutlineColor: Theme.surfaceContainer
                    valueOverride: root._displayVolume
                    alwaysShowValue: SettingsData.osdAlwaysShowValue

                    Component.onCompleted: {
                        root._syncVolume();
                        value = root._displayVolume;
                    }

                    onSliderValueChanged: newValue => {
                        if (!AudioService.sink?.audio)
                            return;
                        SessionData.suppressOSDTemporarily();
                        AudioService.sink.audio.volume = newValue / 100;
                        resetHideTimer();
                    }

                    onContainsMouseChanged: setChildHovered(containsMouse || muteButton.containsMouse)

                    Binding on value {
                        value: root._displayVolume
                        when: !volumeSlider.pressed
                    }
                }
            }
        }
    }

    Component {
        id: verticalContent

        Item {
            anchors.fill: parent
            property int gap: Theme.spacingS

            Rectangle {
                width: Theme.iconSize
                height: Theme.iconSize
                radius: Theme.iconSize / 2
                color: "transparent"
                anchors.horizontalCenter: parent.horizontalCenter
                y: gap

                DankIcon {
                    anchors.centerIn: parent
                    name: AudioService.sink?.audio?.muted ? "volume_off" : "volume_up"
                    size: Theme.iconSize
                    color: muteButtonVert.containsMouse ? Theme.primary : Theme.surfaceText
                }

                MouseArea {
                    id: muteButtonVert

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: AudioService.toggleMute()
                    onContainsMouseChanged: setChildHovered(containsMouse || vertSliderArea.containsMouse)
                }
            }

            Item {
                id: vertSlider
                width: 12
                height: parent.height - Theme.iconSize - gap * 3 - 24
                anchors.horizontalCenter: parent.horizontalCenter
                y: gap * 2 + Theme.iconSize

                property bool dragging: false
                property int value: root._displayVolume

                Rectangle {
                    id: vertTrack
                    width: parent.width
                    height: parent.height
                    anchors.centerIn: parent
                    color: Theme.outline
                    radius: Theme.cornerRadius
                }

                Rectangle {
                    id: vertFill
                    width: parent.width
                    height: (vertSlider.value / AudioService.sinkMaxVolume) * parent.height
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: Theme.primary
                    radius: Theme.cornerRadius
                }

                Rectangle {
                    id: vertHandle
                    width: 24
                    height: 8
                    radius: Theme.cornerRadius
                    y: {
                        const ratio = vertSlider.value / AudioService.sinkMaxVolume;
                        const travel = parent.height - height;
                        return Math.max(0, Math.min(travel, travel * (1 - ratio)));
                    }
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: Theme.primary
                    border.width: 3
                    border.color: Theme.surfaceContainer
                }

                MouseArea {
                    id: vertSliderArea
                    anchors.fill: parent
                    anchors.margins: -12
                    enabled: AudioService.sink?.audio ?? false
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor

                    onContainsMouseChanged: setChildHovered(containsMouse || muteButtonVert.containsMouse)

                    onPressed: mouse => {
                        vertSlider.dragging = true;
                        updateVolume(mouse);
                    }

                    onReleased: vertSlider.dragging = false

                    onPositionChanged: mouse => {
                        if (pressed)
                            updateVolume(mouse);
                    }

                    onClicked: mouse => updateVolume(mouse)

                    function updateVolume(mouse) {
                        if (!AudioService.sink?.audio)
                            return;
                        const maxVol = AudioService.sinkMaxVolume;
                        const ratio = 1.0 - (mouse.y / height);
                        const volume = Math.max(0, Math.min(maxVol, Math.round(ratio * maxVol)));
                        SessionData.suppressOSDTemporarily();
                        AudioService.sink.audio.volume = volume / 100;
                        resetHideTimer();
                    }
                }
            }

            StyledText {
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottomMargin: gap
                text: vertSlider.value + "%"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                visible: SettingsData.osdAlwaysShowValue
            }
        }
    }
}
DANKMANGO_VOLUMEOSD_EOF

# --- integrity: the embedded copy must itself carry the marker ---------------
if ! grep -qF "$MARKER" "$TMP"; then
    echo "[combined-osd-patch] ERROR: embedded QML is missing the marker; refusing to write." >&2
    exit 1
fi

# --- back up whatever is there now (stock or an older patch) -----------------
if [ -f "$TARGET" ]; then
    mkdir -p "$BACKUP_DIR"
    BK="$BACKUP_DIR/VolumeOSD.qml.$(date +%Y%m%d-%H%M%S)"
    cp "$TARGET" "$BK"
    echo "[combined-osd-patch] Backed up current file -> $BK"
else
    echo "[combined-osd-patch] WARNING: $TARGET does not exist (DMS moved/renamed it?)." >&2
    echo "                     Writing anyway; verify the OSD path is still correct." >&2
fi

# --- write it (root-owned, world-readable) -----------------------------------
echo "[combined-osd-patch] Writing patched VolumeOSD.qml (sudo)..."
sudo install -m 0644 -o root -g root "$TMP" "$TARGET"

# --- verify -----------------------------------------------------------------
if grep -qF "$MARKER" "$TARGET"; then
    echo "[combined-osd-patch] OK -- patch applied to $TARGET"
    echo "[combined-osd-patch] Reload DMS to pick it up:   dms restart"
else
    echo "[combined-osd-patch] ERROR: post-write verify failed; marker not found in $TARGET." >&2
    exit 1
fi
