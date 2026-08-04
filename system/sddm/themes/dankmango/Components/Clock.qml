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
    // Also proportional -- a 2px gap under a 165px numeral reads as a collision.
    spacing: Math.max(2, Math.round(effTimeSize * 0.04))

    property color timeColor: "#ffffff"
    property color dateColor: "#cccccc"

    // Type sizes are set by the caller rather than baked in, because the clock is
    // now a focal element in its own right and has to scale with the screen. The
    // defaults are the values it carried when it was a small label above the
    // card, so instantiating this with no sizes still gives the old look.
    property int timeSize: 68
    property int dateSize: 16

    // Hard ceiling on how wide the clock may get. 0 disables it.
    //
    // WHY THIS EXISTS: timeSize is derived from screen HEIGHT, and the space the
    // clock has to fit into is governed by screen WIDTH. On 16:9 there is a wide
    // gap and this never engages -- but the greeter comes up at whatever the
    // panel is, and on a squarer display a height-derived clock grows straight
    // through the login card. Reproduced at 1051x988: the time overlapped the
    // form by ~60px. Shrinking is the right failure mode; colliding is not.
    property real maxWidth: 0

    // Right-aligned when the clock sits on the right of an asymmetric layout, so
    // its ragged edge is the one facing the middle of the screen. Anchoring the
    // children horizontally is fine inside a Column -- Column only owns y.
    property bool alignRight: false

    property date now: new Date()

    // Measures the WIDEST string the 12-hour clock can ever produce, at the
    // REQUESTED size. Its font is an input (timeSize), never the computed result
    // below, so there is no binding loop -- and because glyph advance scales
    // linearly with pixelSize, the ratio it yields is exact rather than a guessed
    // average-character-width constant.
    TextMetrics {
        id: timeMetrics
        // MUST be timeSize, the REQUESTED size -- never effTimeSize. effTimeSize
        // is derived from this object's advanceWidth, so measuring at it would
        // close the loop and Qt would evaluate the binding forever.
        font.pixelSize: clock.timeSize
        font.weight: Font.DemiBold
        font.letterSpacing: clock.timeSize * 0.015
        text: "00:00 AM"
    }

    // 1.0 unless the clock would overrun maxWidth, in which case it is exactly
    // the factor that makes it fit. Applied to the date as well, so the two lines
    // keep their relative sizes instead of the date outgrowing the time.
    readonly property real fitScale:
        (maxWidth > 0 && timeMetrics.advanceWidth > maxWidth)
            ? maxWidth / timeMetrics.advanceWidth
            : 1.0

    readonly property int effTimeSize: Math.max(12, Math.round(timeSize * fitScale))
    readonly property int effDateSize: Math.max(9, Math.round(dateSize * fitScale))

    // The clock is the only text sitting directly on the wallpaper rather than
    // on the card, so it carries its own contrast. This is what lets the
    // backdrop scrim stay gentle enough to keep a bright wallpaper looking like
    // a wallpaper -- without it, legibility here would force the whole screen to
    // be dimmed into grey mush.
    // Tighter and stronger than a decorative shadow would be: the text colour
    // comes from the palette's dark-scheme on_surface (near white) regardless of
    // how bright the wallpaper is, so on a light wallpaper this shadow is doing
    // all the contrast work, not just adding depth.
    //
    // The shadow's absolute size tracks the type size. At 68px a 24px blur is a
    // tight halo hugging the strokes; left fixed while the glyphs grew that same
    // 24px would thin out into a hairline and stop reading as contrast at all.
    //
    // IT IS ALSO STRONGER THAN IT WAS, and that is not a taste change -- it pays
    // for the move to the right-hand side.
    //
    // Measured by rendering the real greeter twice, identically, once with this
    // clock hidden, and reading the backdrop straight out of the difference. On
    // the bright wallpaper the backdrop under the glyphs went from mean luminance
    // 0.088 in the old centred position to 0.153 out here, because the right
    // third of that picture is misty sky where the middle was dark buildings.
    // Bigger glyphs do NOT cancel that on their own -- contrast ignoring the
    // shadow got WORSE, 13.3% of glyph area under 3:1 before against 30.2% after.
    // So the new position is harder than the old one, and it is only legible
    // because of this shadow. Weaken it and the clock goes under.
    //
    // Contrast AS RENDERED, which is the figure that matters, comes out at 3.51:1
    // at the 5th percentile of glyph area with 2.0% of that area under 3:1. The
    // worst single pixels reach 1.87:1, but those are isolated points on
    // antialiased stroke tips, not a legible-or-not region. Dark wallpaper is not
    // close either way: 10.9:1 at the 5th percentile, nothing under 3:1 at all.
    //
    // Re-measured at 2560x1440 as well as 1920x1080, since the greeter comes up at
    // whatever the primary display is. The two agree to within a rounding error
    // (3.51 vs 3.49 at p5, 2.0% vs 2.1% of area; dark 10.89 vs 10.94) -- everything
    // here is proportional to type size, so this is resolution-independent and does
    // not need re-checking per display.
    //
    // Tried and rejected: a TIGHTER halo (blur 0.22, shadowBlur 0.85). Intuition
    // says a dense halo hugging the strokes should lift local contrast more, but
    // it measured worse than the current value on every statistic -- at this size
    // the bright backdrop shows through between the strokes, so the halo has to
    // be wide enough to cover that gap, not just outline the glyph.
    //
    // NO VERTICAL OFFSET, and that is deliberate. A drop shadow is offset by
    // definition, but this is not decoration -- it is the contrast source, and
    // offsetting it moves cover AWAY from the glyph's top edge. Measured on the
    // bright wallpaper, the pixels failing 3:1 were not scattered: half of them
    // sat in one 32px band along the TOPS of the numerals, which is exactly where
    // a downward offset thins the halo. Taking the offset to zero and widening the
    // blur to compensate improved every statistic at once, measured back to back on
    // one screen: worst case 1.79:1 -> 1.87:1, 5th percentile 3.24:1 -> 3.56:1, and
    // the share of glyph area under 3:1 from 3.2% to 1.9%.
    //
    // 0.40 is the knee, not a maximum: 0.52 was also rendered and measured in that
    // same comparison, and it bought 3.56 -> 3.67 at the 5th percentile with no
    // change at all to the area figure, for a visibly larger cloud around the text.
    // Not worth it.
    layer.enabled: true
    layer.effect: MultiEffect {
        shadowEnabled: true
        shadowBlur: 1.0
        shadowColor: "#000000"
        shadowOpacity: 1.0
        shadowVerticalOffset: 0
        blurMax: Math.max(24, Math.round(clock.effTimeSize * 0.40))
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
        anchors.right: clock.alignRight ? parent.right : undefined
        anchors.horizontalCenter: clock.alignRight ? undefined : parent.horizontalCenter
        text: Qt.formatDateTime(clock.now, "h:mm AP")
        color: clock.timeColor
        font.pixelSize: clock.effTimeSize
        // Weight history, so this does not get "fixed" back: originally Thin,
        // which vanished against a bright wallpaper (one-pixel strokes, and no
        // amount of shadow rescues that). Then Light. Now DemiBold, which is
        // affordable because the backdrop is fully blurred again -- nothing sits
        // on sharp high-frequency detail, so weight is a free win rather than a
        // legibility crutch.
        font.weight: Font.DemiBold
        // Proportional, not fixed: 1px of tracking is a comfortable gap at 68px
        // and an invisible one at 165px.
        font.letterSpacing: clock.effTimeSize * 0.015
    }

    Text {
        anchors.right: clock.alignRight ? parent.right : undefined
        anchors.horizontalCenter: clock.alignRight ? undefined : parent.horizontalCenter
        text: Qt.formatDateTime(clock.now, "dddd, d MMMM")
        color: clock.dateColor
        font.pixelSize: clock.effDateSize
        font.weight: Font.DemiBold
        font.letterSpacing: clock.effDateSize * 0.19
    }
}
