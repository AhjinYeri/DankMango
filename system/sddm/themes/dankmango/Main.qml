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

    // --- clock -------------------------------------------------------------
    // Sits above the card rather than in a corner, so the card + clock read as
    // one centred composition. Anchored to the card so it never collides with
    // it as the form grows.
    Clock {
        id: clock
        anchors.horizontalCenter: card.horizontalCenter
        anchors.bottom: card.top
        anchors.bottomMargin: 48
        timeColor: pal.text
        dateColor: pal.subText
    }

    // --- login card --------------------------------------------------------
    Rectangle {
        id: card
        anchors.centerIn: parent
        width: 380
        height: form.implicitHeight + 56
        radius: 28
        color: pal.glass
        border.width: 1
        border.color: pal.glassBorder

        LoginForm {
            id: form
            anchors.centerIn: parent
            width: parent.width - 56
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
