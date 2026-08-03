// DankMango SDDM theme -- clock.
//
// Deliberately dependency-free: no Qt.labs.calendar, no locale plumbing, just a
// Timer and Date. The greeter runs in a minimal environment as the sddm user,
// so the fewer optional QML modules this theme reaches for, the fewer ways it
// can fail to load at the one moment you cannot debug it.
//
// 12-hour format, matching the clock treatment in the rest of DankMango.

import QtQuick 2.15
import QtQuick.Effects

Column {
    id: clock
    spacing: 2

    property color timeColor: "#ffffff"
    property color dateColor: "#cccccc"

    property date now: new Date()

    // The clock is the only text sitting directly on the wallpaper rather than
    // on the card, so it carries its own contrast. This is what lets the
    // backdrop scrim stay gentle enough to keep a bright wallpaper looking like
    // a wallpaper -- without it, legibility here would force the whole screen to
    // be dimmed into grey mush.
    // Tighter and stronger than a decorative shadow would be: the text colour
    // comes from the palette's dark-scheme on_surface (near white) regardless of
    // how bright the wallpaper is, so on a light wallpaper this shadow is doing
    // all the contrast work, not just adding depth.
    layer.enabled: true
    layer.effect: MultiEffect {
        shadowEnabled: true
        shadowBlur: 0.7
        shadowColor: "#000000"
        shadowOpacity: 0.9
        shadowVerticalOffset: 2
        blurMax: 24
    }

    // Ticks once a second. Aligning to the minute boundary would be marginally
    // cheaper but risks a visibly late minute rollover on a screen whose whole
    // job is to be looked at while idle.
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: clock.now = new Date()
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: Qt.formatDateTime(clock.now, "h:mm AP")
        color: clock.timeColor
        font.pixelSize: 68
        // Weight history, so this does not get "fixed" back: originally Thin,
        // which vanished against a bright wallpaper (one-pixel strokes, and no
        // amount of shadow rescues that). Then Light. Now DemiBold, which is
        // affordable because the backdrop is fully blurred again -- nothing sits
        // on sharp high-frequency detail, so weight is a free win rather than a
        // legibility crutch.
        font.weight: Font.DemiBold
        font.letterSpacing: 1
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: Qt.formatDateTime(clock.now, "dddd, d MMMM")
        color: clock.dateColor
        font.pixelSize: 16
        font.weight: Font.DemiBold
        font.letterSpacing: 3
    }
}
