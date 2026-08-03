// DankMango SDDM theme -- palette resolution.
//
// Single place where theme config turns into colors. Everything else in the
// theme reads from an instance of this, so there is exactly one copy of the
// fallback logic.
//
// WHERE THE VALUES COME FROM:
//   theme.conf       root-owned defaults shipped with the theme
//   theme.conf.user  regenerated from matugen on every wallpaper change by
//                    ~/.config/mango/scripts/sddm-palette-sync.sh
//   SDDM layers .user over the base and exposes the result as `config.<Key>`.
//
// TWO RULES THAT ARE EASY TO GET WRONG:
//   1. config values are always STRINGS. `config.Foo === "true"`, never
//      `if (config.Foo)` -- the string "false" is truthy in JavaScript.
//   2. A missing key does not come back as undefined; SDDM hands back an empty
//      string. So test with `|| fallback` AND validate the shape, because a
//      torn read of theme.conf.user (it is rewritten in place, non-atomically)
//      can in principle yield a partial value. Anything that is not a literal
//      #rrggbb falls back to the built-in default rather than rendering a
//      broken or invisible login screen.

import QtQuick 2.15

QtObject {
    id: pal

    // Built-in fallbacks. Deliberately a usable dark theme on their own: this
    // is what shows on a machine where the palette sync has never run.
    readonly property color fallbackBackground: "#15121c"
    readonly property color fallbackSurface:    "#1e1b26"
    readonly property color fallbackSurfaceHi:  "#211e28"
    readonly property color fallbackText:       "#e7e0ee"
    readonly property color fallbackSubText:    "#cbc4d2"
    readonly property color fallbackAccent:     "#d2bcff"
    readonly property color fallbackOnAccent:   "#3d008f"
    readonly property color fallbackOutline:    "#948e9c"
    readonly property color fallbackError:      "#ffb4ab"
    readonly property color fallbackScrim:      "#000000"

    // Accepts only a literal #rrggbb. See rule 2 above.
    function pick(value, fallback) {
        if (typeof value !== "string")
            return fallback
        if (!/^#[0-9a-fA-F]{6}$/.test(value))
            return fallback
        return value
    }

    readonly property color background:  pick(config.BackgroundColor,  fallbackBackground)
    readonly property color surface:     pick(config.SurfaceColor,     fallbackSurface)
    readonly property color surfaceHigh: pick(config.SurfaceHighColor, fallbackSurfaceHi)
    readonly property color text:        pick(config.TextColor,        fallbackText)
    readonly property color subText:     pick(config.SubTextColor,     fallbackSubText)
    readonly property color accent:      pick(config.AccentColor,      fallbackAccent)
    readonly property color onAccent:    pick(config.OnAccentColor,    fallbackOnAccent)
    readonly property color outline:     pick(config.OutlineColor,     fallbackOutline)
    readonly property color error:       pick(config.ErrorColor,       fallbackError)
    readonly property color scrim:       pick(config.ScrimColor,       fallbackScrim)

    // Frosted-glass surfaces. Qt.rgba(...) on a resolved color keeps these tied
    // to the live palette instead of hardcoding a second set of values.
    readonly property color glass:       Qt.rgba(surface.r, surface.g, surface.b, 0.55)
    readonly property color glassBorder: Qt.rgba(1, 1, 1, 0.10)
    readonly property color fieldBg:     Qt.rgba(1, 1, 1, 0.06)
    readonly property color fieldBgHot:  Qt.rgba(1, 1, 1, 0.10)

    // --- wallpaper ---------------------------------------------------------
    // Written by sddm-palette-sync.sh, which copies a downscaled, re-encoded
    // copy of the wallpaper into one of two fixed slots beside this theme and
    // then points here. Only those two exact filenames are accepted: the config
    // file is user-writable, so this stops a stray or tampered value from
    // pointing the greeter at an arbitrary path. Defence in depth -- the real
    // boundary is file ownership, not this regex.
    readonly property string wallpaperPath: {
        var p = config.WallpaperPath
        if (typeof p !== "string" || p.length === 0)
            return ""
        if (!/^\/[^\0]*\/wallpaper-[ab]\.jpg$/.test(p))
            return ""
        return p
    }
    readonly property bool hasWallpaper: wallpaperPath !== ""

    // Backdrop dim. Derived from the wallpaper's measured mean luminance by the
    // sync script, so a bright wallpaper gets dimmed harder than a dark one and
    // card text stays readable on both. Falls back to a middling value.
    readonly property real scrimOpacity: {
        var v = parseFloat(config.ScrimOpacity)
        if (isNaN(v) || v < 0 || v > 1)
            return 0.42
        return v
    }
}
