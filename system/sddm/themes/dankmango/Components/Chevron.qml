// DankMango SDDM theme -- combo-box chevron, drawn rather than typed.
//
// Same reasoning as PowerIcon: the obvious "▾" (U+25BE) is NOT present in the
// default Noto Sans on this machine -- it only renders because fontconfig falls
// back to DejaVu Sans. That happened to work here, but it is a font-fallback
// dependency in the login screen's most-used control, and it would show as a
// tofu box on any system where the fallback is missing. Two lines of Canvas
// removes the dependency entirely.

import QtQuick 2.15

Canvas {
    id: chev

    property color color: "#ffffff"
    property real thickness: 1.6

    onColorChanged: requestPaint()

    onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.clearRect(0, 0, width, height)

        var w = width, h = height
        var cx = w / 2, cy = h / 2
        var half = Math.min(w, h) * 0.30

        ctx.strokeStyle = chev.color
        ctx.lineWidth = thickness
        ctx.lineCap = "round"
        ctx.lineJoin = "round"

        ctx.beginPath()
        ctx.moveTo(cx - half, cy - half * 0.5)
        ctx.lineTo(cx, cy + half * 0.5)
        ctx.lineTo(cx + half, cy - half * 0.5)
        ctx.stroke()
    }
}
