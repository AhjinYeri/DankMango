// DankMango SDDM theme -- system controls.
//
// ---------------------------------------------------------------------------
// WHAT THE GREETER ACTUALLY EXPOSES
// ---------------------------------------------------------------------------
// Enumerated at runtime against sddm 0.21, not assumed -- `for (var k in sddm)`
// inside the real greeter:
//
//   powerOff()  reboot()  suspend()  hibernate()  hybridSleep()
//   canPowerOff canReboot canSuspend canHibernate canHybridSleep
//
// There is NO lock, NO logout and NO display/night-mode control. That is not an
// omission in this file, and it is not something a nicer button style can fix:
// the greeter runs BEFORE any session exists, so there is nothing to lock, log
// out of, or apply a colour temperature to. Do not go looking for a matching API
// to hang a fourth and fifth button off -- there isn't one, and faking them with
// buttons that do nothing would be worse than three buttons that all work.
//
// hibernate() and hybridSleep() ARE available and deliberately not surfaced;
// canHibernate/canHybridSleep are normally false on this machine anyway. Adding
// one later is a five-line change following the pattern at the bottom.
//
// ---------------------------------------------------------------------------
// WHY THESE ARE OUTLINED CIRCLES NOW
// ---------------------------------------------------------------------------
// They used to be three bare glyphs inside a single small glass pill: 40px
// targets with no individual edge, reading as one lozenge of decoration rather
// than as three controls. On a screen where the only other interactive things
// are now a set of underlines, that was the easiest element on the whole display
// to miss entirely.
//
// Each button now carries its own outline, at the same weight and colour as the
// field underlines in the login cluster (pal.rule). That is the point of using
// that shared token rather than a local constant: the ring around "shut down"
// and the line under "chris" are the same statement about what is touchable, so
// they have to be the same line. Hover lights the ring in the accent colour for
// the same reason the underlines do.
//
// The containing pill is gone with the card that it matched.
//
// ---------------------------------------------------------------------------
// SAFETY
// ---------------------------------------------------------------------------
// Every button is gated on its capability flag. Those flags only ever become
// true when the SDDM daemon sends its Capabilities message, so under
// `--test-mode` (no daemon socket) they stay false and the buttons are disabled
// and unclickable. Upstream GreeterProxy writes each action to that same socket,
// so an action in test mode would silently fail regardless -- but the gating
// means it cannot be reached in the first place.

import QtQuick 2.15

Row {
    id: menu

    property var pal: null

    // Set by Main.qml off screen height, so the controls stay the same share of
    // the screen the way everything else in this theme does.
    property int btn: 44
    spacing: Math.round(btn * 0.32)

    // Test-only escape hatch, never set by the shipped theme. It exists so the
    // ENABLED styling can be screenshotted without a daemon; it does not bypass
    // the capability check for the actual calls (see `act` below).
    property bool previewEnabled: false

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
        readonly property bool hot: b.usable && ma.containsMouse

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            antialiasing: true

            // Barely-there fill at rest. Enough to hold the circle together over
            // a busy wallpaper without becoming a solid button; the outline is
            // what defines the shape.
            color: !b.usable      ? "transparent"
                 : ma.pressed     ? Qt.rgba(1, 1, 1, 0.22)
                 : ma.containsMouse ? menu.pal.fieldBgHot
                                    : menu.pal.fieldBg

            border.width: Math.max(1, Math.round(menu.btn * 0.032))
            // Same line as the field underlines at rest, same accent on hover.
            border.color: b.hot ? menu.pal.accent
                                : (b.usable ? menu.pal.rule
                                            : Qt.rgba(1, 1, 1, 0.14))

            Behavior on color        { ColorAnimation { duration: 120 } }
            Behavior on border.color { ColorAnimation { duration: 120 } }
        }

        PowerIcon {
            anchors.centerIn: parent
            width: parent.width * 0.42
            height: parent.height * 0.42
            kind: b.kind
            // Dimmed rather than hidden when unavailable, so the row keeps its
            // shape and it is obvious WHY an action cannot be taken.
            color: b.hot ? menu.pal.accent
                         : (b.usable ? menu.pal.text : menu.pal.subText)
            opacity: b.usable ? 1.0 : 0.35
            thickness: Math.max(1.6, menu.btn * 0.038)
            Behavior on color { ColorAnimation { duration: 120 } }
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
