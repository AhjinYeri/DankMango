// DankMango SDDM theme -- accent anchor.
//
// ONE shape. That is the whole design of this file, and it is a deliberate
// reversal of what was here before.
//
// The previous revision drew two: a large outline diamond straddling the screen
// edge, plus a small solid diamond floating free above and left of the card, on
// the reasoning that the outline alone was "too faint to be a focal point" and
// needed a detached companion to give the left side rhythm. Seen against the
// finished screen that reading was wrong. Two disconnected marks do not anchor
// anything -- they scatter, and scattered geometry is exactly the vocabulary of
// every generic "modern" login wallpaper. The composition read as decorated
// rather than composed.
//
// So there is now a single mark, and it is made to carry the weight on its own
// instead of being propped up by a second one: heavier stroke, higher opacity,
// and a faint interior wash so it reads as a PLANE with an edge rather than as a
// wire outline. Fill and stroke are the same shape, so this is still one shape.
//
// DELIBERATELY SHARP. Everything else on this screen is soft -- blurred backdrop,
// rounded pill button, round system controls -- so the single hard-edged element
// is what gives the composition its tension. A rotated square: no radius, no
// gradient, no glow. It is a motif, not an illustration, and in particular it is
// NOT derived from the pixel-art logo (that stays a logo, beside the wordmark).
//
// TWO CONCENTRIC SQUARES, NOT ONE. This is the shape's fourth revision and the
// history is worth keeping, because three of the four were guesses and the
// fourth is not: it is transcribed from the concept mockup
// (~/Downloads/sddm-concept-no-card.html, `.accent-shape` and its ::after).
//
//   v1  two shapes, one large outline plus a small detached diamond -- scattered
//   v2  one shape, sized to straddle the screen edge -- dominated the screen
//   v3  one shape, sized to the wordmark and set beside it -- quiet, but not
//       what the mockup drew: the mockup's nesting was read as a single outline
//   v4  what the mockup actually specifies, below
//
// Every ratio here comes from the mockup's CSS rather than from taste:
//
//   outer   90px square, 2px border, accent at 0.55        -> stroke 2/90
//   inner   inset 18px on all sides (so 54px), 1px border, accent at 0.30
//   both    rotated 45 degrees together, whole thing at opacity 0.8
//
// The inner square is a ::after INSET FROM THE OUTER ONE, not a second floating
// element -- which is why it lives inside the rotation container here rather
// than being positioned independently. One rotation, applied once, to both.
//
// NO FILL. v2 and v3 carried a faint accent wash on the reasoning that a bare
// outline reads as a hole punched in the wallpaper. The mockup has no
// background on either square, and with two strokes instead of one there is
// enough line to hold the shape without it.
//
// If it ever stops being noticeable, make the STROKE stronger -- do not make the
// shape bigger. That was v2's mistake and it is the easy one to repeat.
//
// ---------------------------------------------------------------------------
// COLOR
// ---------------------------------------------------------------------------
// Driven by the live palette's `accent`, which is matugen's `primary` role
// carried across the privilege boundary by sddm-palette-sync.sh (it already
// writes AccentColor into theme.conf.user -- see `add_key AccentColor primary`).
// So this re-tints with the wallpaper exactly like the login button and the
// field underlines do, with NO new plumbing: no new config key, no change to the
// sync script, no change to Palette.qml.
//
// It draws ABOVE the scrim on purpose. The scrim's job is to dim the wallpaper
// so text stays readable; dimming the accent too would make the anchor fade in
// and out depending on how bright the wallpaper happens to be, which is exactly
// the inconsistency the fixed opacities below avoid.

import QtQuick 2.15

Item {
    id: motif

    property color accent: "#ffffff"

    // Edge length of the OUTER square before rotation -- the mockup's 90px.
    // Everything else is a fraction of this, so the caller tunes one number.
    property real edge: 320

    // The mockup's ratios, named so the numbers below stay traceable to it.
    readonly property real insetRatio: 18 / 90        // ::after { inset: 18px }
    readonly property real outerStroke: 2 / 90        // border: 2px
    readonly property real innerStroke: 1 / 90        // ::after border: 1px

    // Sized to the ROTATED bounding box, so the caller can anchor by what is
    // actually drawn rather than by an unrotated square that does not match it.
    // A 45-degree square's bounding box is edge * sqrt(2) on both axes.
    implicitWidth: edge * Math.SQRT2
    implicitHeight: implicitWidth
    width: implicitWidth
    height: implicitHeight

    // Whole-shape opacity, matching the mockup's `opacity: 0.8` on the element.
    // It multiplies the two per-square alphas below rather than replacing them.
    opacity: 0.8

    // The rotation container. Both squares are children of it, so they share one
    // 45-degree rotation and stay concentric by construction -- rotating them
    // separately would leave the inner one able to drift out of alignment with
    // the outer as sizes change.
    Item {
        anchors.centerIn: parent
        width: motif.edge
        height: motif.edge
        rotation: 45

        // Outer.
        Rectangle {
            anchors.fill: parent
            color: "transparent"
            // Rotated edges alias badly without this; Rectangle only enables it
            // by default when it has a radius, and these deliberately have none.
            antialiasing: true
            border.width: Math.max(2, Math.round(motif.edge * motif.outerStroke))
            border.color: motif.accent
            opacity: 0.55
        }

        // Inner -- the mockup's ::after, inset equally on all four sides.
        Rectangle {
            anchors.fill: parent
            anchors.margins: Math.round(motif.edge * motif.insetRatio)
            color: "transparent"
            antialiasing: true
            border.width: Math.max(1, Math.round(motif.edge * motif.innerStroke))
            border.color: motif.accent
            opacity: 0.30
        }
    }
}
