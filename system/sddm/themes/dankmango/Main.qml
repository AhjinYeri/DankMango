// DankMango SDDM theme -- entry point.
//
// SDDM instantiates this file (metadata.desktop -> MainScript) and injects a
// handful of context objects that exist ONLY inside the greeter. They are not
// importable and have no QML import statement:
//
//   sddm          login(user, pass, sessionIndex); powerOff(); reboot();
//                 suspend(); hibernate(); canPowerOff; canReboot; ...
//                 signals: loginSucceeded(), loginFailed()
//   userModel     roles: name, realName, icon;  property: lastIndex
//   sessionModel  roles: name, file;            property: lastIndex
//   config        key/value from theme.conf (+ theme.conf.user), all STRINGS
//   keyboard      capsLock, numLock
//   textConstants localised UI strings
//
// Because they are injected, this file cannot be previewed in plain `qml`/
// `qmlscene` -- it will fail on `userModel is not defined`. Use the real
// greeter in test mode instead (renders in a window, touches nothing):
//
//   sddm-greeter-qt6 --test-mode --theme <path-to-this-directory>
//
// Note that console.log() from here goes to the JOURNAL, not to the terminal:
//   journalctl --since '-5min' | grep sddm-greeter
//
// ---------------------------------------------------------------------------
// COLORS
// ---------------------------------------------------------------------------
// This theme re-tints with the wallpaper like the rest of DankMango. It cannot
// read matugen output directly -- the greeter runs as the `sddm` system user
// before any session exists, and $HOME is 0700 -- so the palette is pushed
// across that boundary into theme.conf.user by
// ~/.config/mango/scripts/sddm-palette-sync.sh. See the long comment at the top
// of that script for why this needs no polkit, setuid or daemon, and why the
// theme DIRECTORY must stay root-owned. All resolution/fallback lives in
// Components/Palette.qml.
//
// The wallpaper IMAGE crosses the same boundary the same way: the sync script
// writes a downscaled, re-encoded copy into one of two fixed slots beside this
// theme and points `WallpaperPath` at the completed one. Two slots because a
// multi-MB copy cannot be swapped atomically into a root-owned directory --
// see that script's header. If no wallpaper has been synced, the backdrop falls
// back to palette-derived blooms and the screen still looks deliberate.
//
// ---------------------------------------------------------------------------
// LAYOUT: ASYMMETRIC, DELIBERATELY
// ---------------------------------------------------------------------------
// Card left, large clock right, sharp accent motif anchoring the left edge.
//
// The previous revision stacked clock-above-card in the middle of the screen.
// That is the safe arrangement and it looked fine, but it wastes a widescreen
// display: everything huddles in the centre third and the wallpaper -- which
// this theme goes to real trouble to carry across a privilege boundary -- is
// only ever seen as empty margin. The asymmetric split gives the two elements
// their own halves and lets the picture be part of the composition.
//
// Everything is anchored RELATIVELY (card to the screen edge, clock and motif to
// the card) and sized in fractions of the screen, so the arrangement holds at
// whatever resolution the greeter comes up at. There are no absolute positions
// and no absolute sizes -- the card was the last fixed-width element and is not
// any more; see the note above it for why that was worth changing.
//
// ---------------------------------------------------------------------------
// BLUR: FULL SCREEN, DELIBERATELY
// ---------------------------------------------------------------------------
// The whole backdrop is blurred, matching the frosted treatment used elsewhere
// in DankMango (Nemo et al).
//
// An earlier revision blurred ONLY the regions behind the card, clock and power
// pill, via ShaderEffectSource slices with masks. That worked and is the more
// literal reading of "frosted glass", but seen on the real display it was not
// the look wanted. It has been removed rather than left switchable -- three
// slice+mask+blur passes are a lot of machinery to carry for a disabled code
// path. If it is ever wanted back, the shape was: slice a padded rect out of the
// backdrop, blur that small texture, mask it to the panel's rounded rect.
//
// Full-screen blur also makes text legibility EASIER, since nothing sits on
// sharp high-frequency detail any more. That is why the clock can carry a bolder
// weight here than the scoped version could.
// ---------------------------------------------------------------------------

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Effects

import "Components"

Rectangle {
    id: root

    // SDDM resizes the root to the screen; these are sane fallbacks so the item
    // is never zero-sized if that has not happened yet.
    width: Screen.width || 1920
    height: Screen.height || 1080

    color: pal.background

    Palette { id: pal }

    // --- backdrop ----------------------------------------------------------
    // Soft accent blooms behind the wallpaper. Without something structured back
    // here, a missing wallpaper would leave the card frosting nothing but flat
    // grey.
    //
    // If the wallpaper has been synced across the privilege boundary it is drawn
    // ON TOP of the blooms and covers them; if it has not (fresh install, sync
    // never ran, image failed to decode) the blooms remain and the login screen
    // still looks deliberate. That is the graceful-degradation path.
    //
    // Hidden: this is never drawn directly, only consumed as the blur's source.
    Item {
        id: backdrop
        anchors.fill: parent
        visible: false

        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: pal.background }
                GradientStop { position: 1.0; color: pal.surfaceHigh }
            }
        }

        // Positioned in fractions of the screen so the composition survives
        // whatever resolution the greeter comes up at.
        Rectangle {
            width: root.width * 0.55; height: width
            radius: width / 2
            x: -width * 0.18; y: -height * 0.28
            color: pal.accent
            opacity: 0.28
        }
        Rectangle {
            width: root.width * 0.45; height: width
            radius: width / 2
            x: root.width - width * 0.72; y: root.height - height * 0.55
            color: pal.accent
            opacity: 0.18
        }
        Rectangle {
            width: root.width * 0.30; height: width
            radius: width / 2
            x: root.width * 0.55; y: -height * 0.25
            color: pal.outline
            opacity: 0.20
        }

        Image {
            id: wallpaper
            anchors.fill: parent
            // NOTE: visible must NOT be gated on `status === Image.Ready`. This
            // Image lives inside a hidden, texture-sourced subtree, and gating
            // visibility on load status deadlocks -- Qt defers loading an image
            // it believes is invisible, so status never reaches Ready and the
            // wallpaper silently never appears. Gate OPACITY instead: it hides
            // a half-decoded frame without suppressing the load.
            visible: pal.hasWallpaper
            opacity: status === Image.Ready ? 1 : 0
            source: pal.hasWallpaper ? "file://" + pal.wallpaperPath : ""
            fillMode: Image.PreserveAspectCrop
            // Synchronous on purpose: this is a local, already-downscaled file,
            // and a deterministic first frame matters more on a login screen
            // than shaving milliseconds off startup.
            asynchronous: false
            cache: false
            // The synced copy is already capped to 2560px by the sync script;
            // this just stops Qt holding a larger decode than the screen needs.
            sourceSize.width: root.width
            sourceSize.height: root.height
            // A decode failure is not fatal: visible stays false and the blooms
            // above show through instead.
            onStatusChanged: if (status === Image.Error)
                                 console.log("DankMango: wallpaper failed to load:", source)
        }
    }

    // Softened, not obliterated: enough blur to sit behind text comfortably
    // while the wallpaper is still recognisably itself.
    MultiEffect {
        anchors.fill: parent
        source: backdrop
        blurEnabled: true
        blur: pal.hasWallpaper ? 0.65 : 1.0
        blurMax: pal.hasWallpaper ? 40 : 64
        autoPaddingEnabled: false
    }

    // Darkening veil, over the blur rather than inside it so its opacity is
    // exactly what the palette asked for. The value is NOT a fixed constant:
    // sddm-palette-sync.sh measures the wallpaper's mean luminance and scales
    // this so a bright wallpaper is dimmed harder than a dark one. Tuning one
    // constant to suit both is impossible -- a value that keeps white text
    // legible on a bright photo turns a dark one into a black rectangle.
    Rectangle {
        anchors.fill: parent
        color: pal.scrim
        opacity: pal.scrimOpacity
    }

    // --- accent motif ------------------------------------------------------
    // Declared BEFORE the card so the card draws over it (equal z, so file order
    // decides). The geometry below keeps the motif clear of the card anyway, so
    // this is belt-and-braces: on a squarer screen the card sits further left and
    // the point can reach it, and when it does it must go behind, not across.
    AccentShape {
        id: accentShape
        accent: pal.accent

        // The geometry is driven by where the POINT has to land, and the diamond's
        // size follows from that -- not the other way round. Two earlier revisions
        // picked a size first and then tried to place it, and both failed in a
        // render: one ran its edges diagonally across the login form, the other
        // buried the point behind the card so all that showed was two stray
        // diagonal lines. The point is the whole shape; it has to be visible and
        // it has to be clear of the form.
        //
        //   pointX   a small gap to the LEFT of the card, so the diamond aims at
        //            the form without touching it
        //   overhang how far past the screen edge the far side runs, which is
        //            what breaks the frame
        //
        // Everything else is forced: the half-diagonal is pointX + overhang, and
        // the diamond that produces it is that times sqrt(2).
        readonly property real pointX: card.x - Math.round(root.width * 0.025)
        readonly property real overhang: Math.round(root.width * 0.05)
        edge: (pointX + overhang) * Math.SQRT2

        x: pointX - width
        anchors.verticalCenter: card.verticalCenter
    }

    // --- clock -------------------------------------------------------------
    // The right-hand half of the composition, and a focal element in its own
    // right rather than a caption above the card. Sizes are fractions of the
    // screen so it stays the same share of the layout at any resolution; the
    // floors keep it sane if the greeter ever comes up at something tiny.
    //
    // Vertically centred on the CARD, not on the screen, so the two focal blocks
    // sit on one axis and the asymmetry reads as deliberate rather than as
    // something that failed to centre.
    //
    // Legibility was re-measured against both a bright and a dark wallpaper after
    // the move, and it did NOT come for free with the bigger type -- the
    // right-hand third of a wallpaper is not the middle of it, so the old
    // measurement did not carry over. The numbers and what had to change because
    // of them are in the shadow comment in Components/Clock.qml.
    Clock {
        id: clock
        anchors.right: parent.right
        anchors.rightMargin: Math.round(root.width * 0.10)
        anchors.verticalCenter: card.verticalCenter
        alignRight: true
        timeSize: Math.max(72, Math.round(root.height * 0.115))
        dateSize: Math.max(14, Math.round(root.height * 0.017))
        // Everything from the card's right edge to the clock's right margin,
        // less a gap so the two never come close enough to read as one block.
        // Inert at 16:9 -- see the note on maxWidth in Components/Clock.qml.
        maxWidth: root.width - (card.x + card.width)
                  - Math.round(root.width * 0.10) - Math.round(root.width * 0.05)
        timeColor: pal.text
        dateColor: pal.subText
    }

    // --- login card --------------------------------------------------------
    // Left-anchored, and sized to a fixed PHYSICAL width -- millimetres on the
    // glass -- rather than to a share of the pixel width.
    //
    // Two earlier bases were both wrong, in opposite directions. A fixed 380px
    // is a physically SMALLER card on a denser panel, which is backwards for
    // something looked at from a fixed distance. Replacing it with a fraction of
    // the screen (0.21, clamped 340..560) fixed that only by coincidence: a
    // fraction holds its physical size only while every panel has the same
    // physical size. It does on the 27in pair this was tuned on, so it looked
    // solved. Put a 27in 4k next to a 27in 1080p -- same glass, twice the pixels
    // -- and the fraction hits the 560 clamp and hands back a card two thirds
    // the physical size of its neighbour.
    //
    // Resolution was never the thing being asked about. The question is how big
    // the card is in millimetres, so ask the panel: Screen.pixelDensity is real
    // physical DPI, read from EDID (via XRandR -- SDDM runs DisplayServer=x11).
    // Pixel width then drops out of the calculation entirely.
    //
    // The old objection to a bigger card still holds for the FIELDS, and is
    // handled as before: uiScale drives the form's type and padding along with
    // the width, so the card grows without the fields getting longer relative to
    // their own height.
    Rectangle {
        id: card

        // The width the form's type sizes and paddings were originally tuned at.
        // uiScale is measured against it, so at 380 everything below reproduces
        // the old look exactly and this change is a pure scaling, not a retune.
        readonly property int refWidth: 380

        // Physical pixels per millimetre for the panel this window is on. Panels
        // that report no physical size at all (EDID-less, some KVMs and
        // projectors) give 0 here; fall back to the 96dpi Xorg itself assumes in
        // that case rather than collapsing the card to nothing.
        readonly property real pxPerMm: Screen.pixelDensity > 0.5 ? Screen.pixelDensity
                                                                  : 96 / 25.4

        // How wide the card is, and how big the things inside it are, are two
        // separate questions, so they are two separate numbers.
        //
        // 127mm (5in) is what the old 0.21 fraction happened to produce on the
        // 27in panels this was tuned on, and it is still the size everything
        // INSIDE the card is scaled against -- so this is not a retune, and the
        // type is the same physical size it has always been.
        //
        // The CARD is 118mm. Seen on real hardware rather than in test-mode, a
        // card as wide as its content wanted to be read as squat. Taking ~7% off
        // the width narrows the frame; because uiScale is pinned to contentMM
        // and not to this, the text does not come down with it.
        readonly property int targetMM: 118
        readonly property int contentMM: 127
        readonly property int idealWidth: Math.round(targetMM * pxPerMm)

        // Narrowing the card must not shrink the type with it, so the reference
        // uiScale is measured against narrows by the same ratio the card did:
        // 380 * 118/127 = 353. A 118mm card at 353 is then pixel-for-pixel the
        // same type and padding a 127mm card at 380 was, which is the whole
        // point -- the frame got narrower, the contents did not get smaller.
        //
        // Deliberately still "width over a reference width", exactly as before.
        // DPI cancels out of this entirely (both sides of the ratio carry it),
        // so the guards below keep behaving as they always did: a card the
        // clamps shrink scales its contents down with it, and stays internally
        // proportionate rather than becoming a small card with huge text.
        readonly property real contentRefWidth: refWidth * targetMM / contentMM
        readonly property real uiScale: width / contentRefWidth

        // Asymmetric on purpose. The horizontal inset is the tuned 28; the
        // vertical one is over half again as much, which is where most of the
        // card's extra height comes from. Padding rather than a taller form,
        // because the ask was a taller SHAPE -- growing the fields to fill a
        // taller card would just be the squat card again at a larger size.
        readonly property int padH: Math.round(28 * uiScale)
        readonly property int padV: Math.round(44 * uiScale)

        anchors.left: parent.left
        anchors.leftMargin: Math.round(root.width * 0.12)
        anchors.verticalCenter: parent.verticalCenter

        // Physical size first, then two guards that only ever bite on hardware
        // where honouring it would be worse than not: never more than a third of
        // the screen (a small or narrow panel would otherwise be swallowed by
        // the card), and never below what the fields need. Both shrink uiScale
        // with the card, so a clamped card stays internally proportionate.
        width: Math.max(340, Math.min(Math.round(root.width * 0.33), idealWidth))
        height: form.implicitHeight + padV * 2
        radius: Math.round(28 * uiScale)
        color: pal.glass
        border.width: 1
        border.color: pal.glassBorder

        LoginForm {
            id: form
            anchors.centerIn: parent
            width: parent.width - card.padH * 2
            uiScale: card.uiScale
            pal: pal
        }
    }

    // --- power menu --------------------------------------------------------
    // Bottom-right, the conventional spot, in a glass pill so it reads as the
    // same material as the login card rather than as loose icons floating on the
    // wallpaper.
    Rectangle {
        width: powerMenu.width + 20
        height: powerMenu.height + 12
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: 28
        anchors.bottomMargin: 28
        radius: height / 2
        color: pal.glass
        border.width: 1
        border.color: pal.glassBorder

        PowerMenu {
            id: powerMenu
            anchors.centerIn: parent
            pal: pal
        }
    }

    // Focus the password field as soon as the greeter is up, so the common case
    // (last user already selected) is type-password-and-enter.
    Component.onCompleted: form.focusPassword()
}
