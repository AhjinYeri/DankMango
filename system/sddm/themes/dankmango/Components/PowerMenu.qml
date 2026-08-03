// DankMango SDDM theme -- power actions.
//
// WHAT THE GREETER ACTUALLY EXPOSES (enumerated at runtime against sddm 0.21,
// not assumed -- `for (var k in sddm)` inside the real greeter):
//
//   powerOff()  reboot()  suspend()  hibernate()  hybridSleep()
//   canPowerOff canReboot canSuspend canHibernate canHybridSleep
//
// There is NO lock and NO logout. That is not an omission in this file: the
// greeter runs BEFORE any session exists, so there is nothing to lock or log out
// of. Do not add them looking for a matching API -- there isn't one.
//
// hibernate() and hybridSleep() are available and deliberately not surfaced
// here; canHibernate/canHybridSleep are normally false on this machine anyway.
// Adding them later is a two-line change following the pattern below.
//
// SAFETY: every button is gated on its capability flag. Those flags only ever
// become true when the SDDM daemon sends its Capabilities message, so under
// `--test-mode` (no daemon socket) they stay false and the buttons are disabled
// and unclickable. Upstream GreeterProxy writes each action to that same socket,
// so an action in test mode would silently fail regardless -- but the gating
// means it cannot be reached in the first place.

import QtQuick 2.15
import QtQuick.Layouts 1.15

Row {
    id: menu
    spacing: 6

    property var pal: null

    // Test-only escape hatch, never set by the shipped theme. It exists so the
    // ENABLED styling can be screenshotted without a daemon; it does not bypass
    // the capability check for the actual calls (see `act` below).
    property bool previewEnabled: false

    readonly property int btn: 40

    component PowerButton: Item {
        id: b
        width: menu.btn
        height: menu.btn

        property string kind: "power"
        property bool available: false
        property string tip: ""
        // The real action. Left null unless the capability is present, so it is
        // impossible to invoke a power action the daemon has not authorised --
        // independently of whatever `available` says.
        property var act: null

        // Drives APPEARANCE and hover only. Deliberately not tied to `act`, so
        // previewEnabled can show the enabled styling while the click path stays
        // inert (act is still null). Visual state and the ability to actually
        // fire an action are two separate gates.
        readonly property bool usable: b.available

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: !b.usable ? "transparent"
                 : ma.pressed  ? Qt.rgba(1, 1, 1, 0.20)
                 : ma.containsMouse ? Qt.rgba(1, 1, 1, 0.12)
                                    : "transparent"
            Behavior on color { ColorAnimation { duration: 110 } }
        }

        PowerIcon {
            anchors.centerIn: parent
            width: parent.width * 0.52
            height: parent.height * 0.52
            kind: b.kind
            // Dimmed rather than hidden when unavailable, so the row keeps its
            // shape and it is obvious WHY an action cannot be taken.
            color: b.usable ? menu.pal.text : menu.pal.subText
            opacity: b.usable ? 1.0 : 0.35
        }

        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            enabled: b.usable
            cursorShape: b.usable ? Qt.PointingHandCursor : Qt.ArrowCursor
            // Second gate: no capability -> act is null -> nothing happens.
            onClicked: if (b.act) b.act()
        }
    }

    PowerButton {
        kind: "suspend"
        tip: "Suspend"
        available: sddm.canSuspend || menu.previewEnabled
        act: sddm.canSuspend ? function() { sddm.suspend() } : null
    }

    PowerButton {
        kind: "restart"
        tip: "Restart"
        available: sddm.canReboot || menu.previewEnabled
        act: sddm.canReboot ? function() { sddm.reboot() } : null
    }

    PowerButton {
        kind: "power"
        tip: "Shut down"
        available: sddm.canPowerOff || menu.previewEnabled
        act: sddm.canPowerOff ? function() { sddm.powerOff() } : null
    }
}
