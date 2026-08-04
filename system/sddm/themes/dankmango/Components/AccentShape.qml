// DankMango SDDM theme -- accent motif.
//
// A geometric counterweight for the asymmetric layout. The card sits left and
// the clock sits right; without something holding the left side down those two
// read as two unrelated things drifting apart. This pins the card.
//
// DELIBERATELY SHARP. Everything else on this screen is soft -- rounded glass
// card, blurred backdrop, round-ended power pill -- so the single hard-edged
// element is what gives the composition its tension. Rotated squares: no radius,
// no gradient, no glow. It is a motif, not an illustration, and in particular it
// is NOT derived from the pixel-art logo (that stays a logo, on the card).
//
// IT IS MEANT TO BREAK THE FRAME. The caller sizes and positions it so the large
// diamond runs off the left screen edge. Nothing clips it -- the root Rectangle
// does not set clip -- so the overhanging part simply is not drawn, which is the
// intended effect rather than an accident to be guarded against.
//
// ---------------------------------------------------------------------------
// COLOR
// ---------------------------------------------------------------------------
// Driven by the live palette's `accent`, which is matugen's `primary` role
// carried across the privilege boundary by sddm-palette-sync.sh (it already
// writes AccentColor into theme.conf.user -- see `add_key AccentColor primary`).
// So this re-tints with the wallpaper exactly like the window borders, the bar
// and the login button do, with NO new plumbing: no new config key, no change to
// the sync script, no change to Palette.qml. The existing backdrop blooms
// already use the same property, so this is the established path, not a new one.
//
// It draws ABOVE the scrim on purpose. The scrim's job is to dim the wallpaper
// so text stays readable; dimming the accent too would make the motif fade in
// and out depending on how bright the wallpaper happens to be, which is exactly
// the inconsistency the fixed opacities below avoid.

import QtQuick 2.15

Item {
    id: motif

    property color accent: "#ffffff"

    // Edge length of the large diamond BEFORE rotation. Everything else is a
    // fraction of this, so the caller tunes one number.
    property real edge: 320

    // Sized to the ROTATED bounding box, so the caller can anchor by what is
    // actually drawn rather than by an unrotated square that does not match it.
    // A 45-degree square's bounding box is edge * sqrt(2) on both axes.
    implicitWidth: edge * Math.SQRT2
    implicitHeight: implicitWidth
    width: implicitWidth
    height: implicitHeight

    // Large outline. The caller straddles this across the left screen edge, so
    // its left half is cut off and its right vertex points at the card.
    //
    // AN EARLIER REVISION CENTRED THIS ON THE CARD ITSELF, and it was wrong in a
    // way that only showed up in a render: to reach the screen edge from a card
    // inset 12% of the way in, the diamond has to be wide enough that its two
    // edges then run diagonally across the whole form. Behind 55%-opaque glass
    // that is not a subtle tint -- it is a pair of lines drawn straight through
    // the username, password and session fields. Hence the geometry below, where
    // only the point approaches the card and nothing crosses it.
    Rectangle {
        anchors.centerIn: parent
        width: motif.edge
        height: motif.edge
        rotation: 45
        // Rotated edges alias badly without this; Rectangle only enables it by
        // default when it has a radius, and this one deliberately has none.
        antialiasing: true
        color: "transparent"
        border.width: Math.max(2, Math.round(motif.edge * 0.010))
        border.color: motif.accent
        opacity: 0.50
    }

    // Solid marker, floating free above and left of the card in open backdrop.
    // This is the element that actually registers as an accent -- the outline
    // does the structural work but is too faint to be a focal point on its own.
    //
    // Deliberately NOT sitting on the outline's edge: as a second, detached
    // point it gives the left side of the composition a rhythm, where a node
    // welded to the line would just read as a thicker bit of line. The position
    // is expressed relative to this item's own box so it travels with the motif.
    Rectangle {
        width: motif.edge * 0.13
        height: width
        x: motif.width - motif.edge * 0.14 - width / 2
        y: motif.height * 0.10 - height / 2
        rotation: 45
        antialiasing: true
        color: motif.accent
        opacity: 0.85
    }
}
