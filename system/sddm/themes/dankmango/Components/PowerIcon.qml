// DankMango SDDM theme -- power icons, drawn rather than typed.
//
// WHY NOT GLYPHS: the obvious approach is Unicode symbols (U+23FB power,
// U+21BB restart, U+263E moon). On this machine those codepoints exist ONLY in
// MesloLGS Nerd Font / Adwaita Mono / Noto Sans Symbols 2 -- NOT in the default
// Noto Sans. That leaves the icons depending on Qt font fallback finding a
// secondary family, as the sddm user, on the one screen you cannot easily debug.
// A tofu box where the shutdown button should be is a bad failure. Canvas paths
// have no font dependency at all, so they render identically everywhere.

import QtQuick 2.15

Canvas {
    id: icon

    // "power" | "restart" | "suspend"
    property string kind: "power"
    property color color: "#ffffff"
    property real thickness: 1.8

    // Canvas does not repaint on property change by itself.
    onColorChanged: requestPaint()
    onKindChanged: requestPaint()

    onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.clearRect(0, 0, width, height)

        var cx = width / 2
        var cy = height / 2
        var r = Math.min(width, height) / 2 - thickness * 1.6

        ctx.strokeStyle = icon.color
        ctx.fillStyle = icon.color
        ctx.lineWidth = thickness
        ctx.lineCap = "round"

        if (kind === "power") {
            // Ring with a gap at the top, plus the vertical stem through it.
            ctx.beginPath()
            ctx.arc(cx, cy, r, -Math.PI / 2 + 0.55, -Math.PI / 2 - 0.55 + Math.PI * 2)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(cx, cy - r * 1.12)
            ctx.lineTo(cx, cy - r * 0.10)
            ctx.stroke()

        } else if (kind === "restart") {
            // Open circle plus an arrowhead at the leading end.
            var start = -Math.PI / 2 + 0.5
            var end = start + Math.PI * 1.75
            ctx.beginPath()
            ctx.arc(cx, cy, r, start, end)
            ctx.stroke()

            // Arrowhead, tangent to the arc at its end point.
            var ax = cx + r * Math.cos(end)
            var ay = cy + r * Math.sin(end)
            var a = end + Math.PI / 2      // tangent direction
            var s = thickness * 2.2
            ctx.beginPath()
            ctx.moveTo(ax + s * Math.cos(a), ay + s * Math.sin(a))
            ctx.lineTo(ax + s * Math.cos(a + 2.5), ay + s * Math.sin(a + 2.5))
            ctx.lineTo(ax + s * Math.cos(a - 2.5), ay + s * Math.sin(a - 2.5))
            ctx.closePath()
            ctx.fill()

        } else if (kind === "suspend") {
            // Crescent: a filled disc with a second disc punched out of it.
            ctx.beginPath()
            ctx.arc(cx - r * 0.10, cy, r, 0, Math.PI * 2)
            ctx.fill()
            ctx.globalCompositeOperation = "destination-out"
            ctx.beginPath()
            ctx.arc(cx + r * 0.55, cy - r * 0.42, r * 0.98, 0, Math.PI * 2)
            ctx.fill()
            ctx.globalCompositeOperation = "source-over"
        }
    }
}
