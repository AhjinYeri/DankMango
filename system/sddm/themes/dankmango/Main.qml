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
// LAYOUT: ONE SCENE, NOT A UI ON A PICTURE
// ---------------------------------------------------------------------------
// Clock high and right, login cluster low and left, a pair of nested accent
// diamonds standing free in the left backdrop, system controls bottom right. The asymmetry is
// deliberate and now runs diagonally rather than across: the two focal blocks
// take opposite corners instead of sharing a centreline, which uses the whole
// height of the wallpaper -- which this theme goes to real trouble to carry
// across a privilege boundary -- instead of leaving its top and bottom as empty
// margin.
//
// WHAT CHANGED IS THAT THE CARD IS GONE. The fields used to sit inside a rounded
// frosted-glass panel. Everything on the screen now sits directly in the scene:
// no panel behind the fields, no pill behind the system controls. The screen
// reads as one continuous image rather than as a dialog placed on top of a
// photograph.
//
// That is a real trade, not a free win, and the two things the card was quietly
// doing are paid for explicitly elsewhere rather than lost:
//
//   CONTRAST    the cluster carries its own shadow layer, the same technique
//               Clock.qml has always used for the one element that was never in
//               the card. See the note at the bottom of Components/LoginForm.qml.
//   AFFORDANCE  chevrons, underlines and an accent hover/focus state, plus a
//               one-time hint before the first successful login. See the same
//               file, and Components/HintState.qml for where that flag lives.
//
// Everything is anchored RELATIVELY (cluster to the screen edge, clock and motif
// to the cluster) and sized in fractions of the screen or in millimetres off the
// panel's real DPI, so the arrangement holds at whatever resolution the greeter
// comes up at. There are no absolute positions.
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
// path. Note that it could not come back now even if it were wanted: it masked
// blur to the panels' rounded rects, and there are no panels any more.
//
// Full-screen blur also makes text legibility EASIER, since nothing sits on
// sharp high-frequency detail any more. That is why the clock can carry a bolder
// weight here than the scoped version could, and it is a large part of why
// dropping the card was affordable at all.
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

    // Screen margins for the two corner groups: login bottom-left, clock
    // top-right. LITERAL pixels, deliberately not run through any of this
    // theme's scaling. Everything else here is either a fraction of the screen
    // or a physical millimetre size off the panel's DPI, and these are neither
    // by instruction -- they are fixed gaps to the glass edge, the same on a
    // 1080p laptop as on a 4k desktop. If they ever need to scale, that is a
    // decision to take deliberately, not by quietly wrapping them in s().
    //
    // THESE WERE ONE SHARED CONSTANT and are now three, because they turned out
    // not to be one thing. Sharing was only ever correct while every edge wanted
    // the same number; the moment one of them needed to move, sharing meant the
    // other four moved with it silently. Three of the four sites below have since
    // gone to 30 and one has stayed at 20, which is precisely the split a single
    // constant could not express.
    //
    // Named per edge rather than per value, so that two of them being 30 today
    // is a coincidence the code does not depend on.
    readonly property int panelLeftGap:   20
    readonly property int panelBottomGap: 30
    readonly property int clockGap:       30

    Palette { id: pal }

    // --- backdrop ----------------------------------------------------------
    // Soft accent blooms behind the wallpaper. Without something structured back
    // here, a missing wallpaper would leave the screen flat grey.
    //
    // If the wallpaper has been synced across the privilege boundary it is drawn
    // ON TOP of the blooms and covers them; if it has not (fresh install, sync
    // never ran, image failed to decode) the blooms remain and the login screen
    // still looks deliberate. That is the graceful-degradation path.
    //
    // These are NOT the "scattered decorative shapes" that the accent motif was
    // cut down from -- they are a fallback BACKDROP, they live under the
    // wallpaper, and they are invisible whenever there is one.
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

    // --- one-time hint state -----------------------------------------------
    // Deliberately behind a Loader rather than instantiated directly. The whole
    // reasoning -- why the flag cannot live in theme.conf.user, where it does
    // live instead, and why a failed load must degrade to "no hint" rather than
    // taking the login screen with it -- is at the top of that file. Read it
    // before changing anything here.
    Loader {
        id: hintState
        source: "Components/HintState.qml"
        asynchronous: false
        onStatusChanged: if (status === Loader.Error)
                             console.log("DankMango: hint state unavailable; first-boot hint disabled")
    }

    // The user has plainly worked out that the pickers are pickers, so the hint
    // has done its job for this session even if the flag never gets persisted.
    // This is what keeps a failed/unwritable HintState from being annoying: the
    // worst case is a line of text that disappears the moment you touch a picker,
    // rather than one that follows you around forever.
    property bool hintDismissed: false

    // --- accent anchor -----------------------------------------------------
    // ONE shape, not the two the previous revision drew -- see the header of
    // Components/AccentShape.qml for why the second one had to go.
    //
    // Declared BEFORE the cluster so the cluster draws over it (equal z, so file
    // order decides). The geometry below keeps the motif clear of the text
    // anyway, so this is belt-and-braces: on a squarer screen the cluster sits
    // further left and the point can reach it, and when it does it must go
    // behind, not across. That matters more than it used to -- there is no
    // opaque card to hide a stray edge behind any more, so a collision here
    // would be a line drawn straight through the username.
    AccentShape {
        id: accentShape
        accent: pal.accent

        // SIZE, from the mockup's proportion rather than from a screen fraction.
        // The mockup draws a 90px square against a 320px-wide login cluster, so
        // the shape is expressed against the cluster's width and holds that
        // proportion at any resolution or DPI. A screen fraction was tried twice
        // and grew into a background element both times.
        //
        // `edge` is the UNROTATED side; the item sizes itself to the rotated
        // bounding box, so no conversion is needed here.
        edge: loginPanel.width * 90 / 320

        // POSITION: relative to the login panel, not to the screen.
        //
        // The mockup positions this absolutely (`left: 6%; bottom: 34%`) and the
        // previous revision copied that literally. It looked right only because
        // the panel happened to be at 8%/14% -- the two were independently
        // positioned and merely landed next to each other. Move one and the
        // composition silently comes apart, which is exactly what an absolute
        // 20px panel anchor would have done to it.
        //
        // So the offsets below are the mockup's SPACING between the shape and the
        // cluster, re-expressed against the panel that the shape belongs to. The
        // mockup's own numbers, on its 1920x1080 canvas with a 320px cluster:
        //
        //   shape centre x   160px, cluster left edge 153.6px  -> +6.4px, /320
        //   shape centre y   sits on the brand line once the vertical offset
        //                    that made it clip into "chris" is taken out
        //
        // Vertically it is now CENTRED on the brand row rather than carrying the
        // mockup's downward offset. That offset is what pushed the lower vertex
        // into the username row; LoginForm opens up a matching gap beneath the
        // brand row (see accentClearance) so nothing has to overlap for the
        // shape to sit where it does.
        x: loginPanel.x + Math.round(loginPanel.width * 0.02) - width / 2
        y: loginPanel.y + form.brandCenterY - height / 2
    }

    // --- clock -------------------------------------------------------------
    // The right-hand half of the composition, and a focal element in its own
    // right rather than a caption above a card. Sizes are fractions of the
    // screen so it stays the same share of the layout at any resolution; the
    // floors keep it sane if the greeter ever comes up at something tiny.
    //
    // THE CLOCK NO LONGER CENTRES ON THE CLUSTER. It used to, and that was right
    // while the two sat on one horizontal axis -- it is what stopped the
    // asymmetric split reading as something that had failed to centre. They are
    // now deliberately on different axes: clock high, cluster low. Sharing a
    // centreline was the thing holding them into a single band across the middle
    // of the screen, and pulling them apart is the point.
    //
    // The element itself is otherwise untouched. It was already working and
    // already sitting directly on the wallpaper -- it is, in fact, the precedent
    // the login cluster follows for its own legibility. Type sizes, shadow and
    // alignment are all exactly as they were; only the anchor moved.
    //
    // Legibility was measured against both a bright and a dark wallpaper when it
    // moved out to the right, and it did NOT come for free with the bigger type.
    // The numbers and what had to change because of them are in the shadow
    // comment in Components/Clock.qml.
    Clock {
        id: clock
        // The opposite corner to the login group. Both edges share one value
        // because they moved together and read as one corner inset; split them
        // if they ever need to differ, rather than reintroducing a constant
        // shared with the login group's edges.
        //
        // NOTE, because the reverse has been assumed once already: this margin is
        // the ITEM's edge, and nothing here compensates for type metrics. The
        // clock's ink measures further in than this number -- roughly 15px on the
        // right and 35px on the top at the current size -- because a glyph's side
        // bearing, its trailing letter-spacing and the line box's internal leading
        // all sit inside the item. That inset is a property of the font at that
        // size; it is not a correction applied anywhere in this file, and it is
        // not proportional to the margin. Change this number and the ink moves by
        // exactly the same amount.
        anchors.right: parent.right
        anchors.rightMargin: root.clockGap
        anchors.top: parent.top
        anchors.topMargin: root.clockGap
        alignRight: true

        // 0.088 of screen height, down from 0.115 -- a 23% reduction, which at
        // 2560x1440 is 166px -> 127px.
        //
        // The old figure was set when the clock was one of two focal blocks
        // sharing a centreline with a login CARD, and it was sized to hold its
        // half of that. It is neither of those things now: the card is gone, the
        // cluster is a set of thin rules in the opposite corner, and at 166px the
        // clock was simply the largest object on the screen by a factor of three.
        //
        // Sanity check against the concept mockup, which is the only other place
        // this ratio is written down: 74px time against a 17px date is 4.35:1.
        // At 0.115 ours was 6.9:1; at 0.088 it is 5.3:1, so this moves toward the
        // mockup's proportion as well as simply being smaller. The date is
        // deliberately left alone -- shrinking both would keep the same ratio and
        // change nothing about the relationship being corrected.
        //
        // Floor lowered in step with the ratio so it still only bites on a very
        // short screen rather than becoming the effective size on a normal one.
        timeSize: Math.max(56, Math.round(root.height * 0.088))
        dateSize: Math.max(14, Math.round(root.height * 0.017))
        // A plain ceiling, not a collision guard: the clock and the login group
        // are in opposite corners and cannot meet. This only stops a
        // height-derived clock on a very square panel from running off the left
        // of the screen -- it shrinks instead. Expressed as the full width less
        // the same edge gap at each side.
        // Inert at 16:9 -- see the note on maxWidth in Components/Clock.qml.
        maxWidth: root.width - root.clockGap * 2
        timeColor: pal.text
        dateColor: pal.subText
    }

    // --- login cluster -----------------------------------------------------
    // Left-anchored, and sized to a fixed PHYSICAL width -- millimetres on the
    // glass -- rather than to a share of the pixel width.
    //
    // This is a bare Item now, not a Rectangle: it exists only to give the form
    // a width and a position. Nothing is drawn here.
    //
    // Two earlier bases for that width were both wrong, in opposite directions.
    // A fixed 380px is a physically SMALLER block on a denser panel, which is
    // backwards for something looked at from a fixed distance. Replacing it with
    // a fraction of the screen (0.21, clamped 340..560) fixed that only by
    // coincidence: a fraction holds its physical size only while every panel has
    // the same physical size. It does on the 27in pair this was tuned on, so it
    // looked solved. Put a 27in 4k next to a 27in 1080p -- same glass, twice the
    // pixels -- and the fraction hits the 560 clamp and hands back a form two
    // thirds the physical size of its neighbour.
    //
    // Resolution was never the thing being asked about. The question is how big
    // the form is in millimetres, so ask the panel: Screen.pixelDensity is real
    // physical DPI, read from EDID (via XRandR -- SDDM runs DisplayServer=x11).
    // Pixel width then drops out of the calculation entirely.
    Item {
        id: loginPanel

        // The width the form's type sizes and spacings were tuned at. uiScale is
        // measured against it, so at 380 everything below reproduces the tuned
        // look exactly and the DPI sizing is a pure scaling, not a retune.
        readonly property int refWidth: 380

        // Physical pixels per millimetre for the panel this window is on. Panels
        // that report no physical size at all (EDID-less, some KVMs and
        // projectors) give 0 here; fall back to the 96dpi Xorg itself assumes in
        // that case rather than collapsing the form to nothing.
        readonly property real pxPerMm: Screen.pixelDensity > 0.5 ? Screen.pixelDensity
                                                                  : 96 / 25.4

        // 127mm is what the old screen-fraction happened to produce on the 27in
        // panels this was tuned on, and it was already the size everything
        // INSIDE the card was scaled against.
        //
        // The card itself was deliberately NARROWER than that (118mm) because a
        // frame as wide as its content read as squat -- so the old code carried
        // two millimetre figures and a ratio to keep the type from shrinking
        // with the frame. There is no frame now, so there is nothing to be squat
        // and nothing to compensate for: the cluster is simply the content
        // width, and the second figure and the ratio are gone with the card.
        //
        // 127mm at refWidth 380 is exactly the type and spacing the old card
        // produced, so this is not a retune either.
        readonly property int contentMM: 127
        readonly property int idealWidth: Math.round(contentMM * pxPerMm)

        readonly property real uiScale: width / refWidth

        // How far the accent shape's left vertex reaches PAST this item's own
        // left edge. The shape is centred just inside the panel (+0.02 of the
        // width) and its rotated bounding box is half a diagonal wide
        // (0.28125 * sqrt(2) / 2 = 0.1989 of the width), so it overhangs by the
        // difference. Both constants are the mockup's, and both are stated where
        // the shape itself is declared.
        readonly property int accentOverhang: Math.round(width * (0.1989 - 0.02))

        // The 20px gap is measured to the GROUP, and the leftmost thing in the
        // group is the accent shape, not the text. So the text column is inset by
        // the shape's overhang on top of the gap -- which is what keeps the
        // shape's left vertex exactly 20px off the screen edge instead of
        // hanging off it.
        //
        // If the intent was 20px to the TEXT instead, this is the line to change:
        // drop accentOverhang and the shape goes partly off-screen.
        anchors.left: parent.left
        anchors.leftMargin: root.panelLeftGap + accentOverhang

        // Anchored to the BOTTOM, not centred. The cluster and the clock used to
        // share a centreline through the middle of the screen, which kept the
        // whole composition in one horizontal band and left the top and bottom
        // of the wallpaper as dead margin. Clock high and cluster low uses the
        // full height of the picture and gives the form somewhere to sit rather
        // than something to float in.
        //
        // Anchored by its bottom edge specifically, so the cluster grows UPWARD
        // as rows appear -- the error line and the first-boot hint both add
        // height at the bottom, and a centred or top-anchored cluster would
        // shift every field on screen when they did.
        //
        // A fixed 20px, replacing the percentage that made this ambiguous. The
        // percentage form was genuinely confusing to reason about -- 14% is a
        // distance UP from the bottom edge, so "further down" meant a SMALLER
        // number, and the mockup's own 14% moved the cluster up rather than down.
        // An absolute gap to the screen edge has no such sign to get backwards.
        //
        // Still anchored by the BOTTOM edge specifically, so the cluster grows
        // upward as rows appear: the error line and the first-boot hint both add
        // height at the bottom, and a top-anchored cluster would shift every
        // field on screen when they did.
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.panelBottomGap

        // Physical size first, then two guards that only ever bite on hardware
        // where honouring it would be worse than not: never more than a third of
        // the screen (a small or narrow panel would otherwise be swallowed), and
        // never below what the fields need. Both shrink uiScale with the
        // cluster, so a clamped cluster stays internally proportionate rather
        // than becoming a narrow column with huge text.
        width: Math.max(340, Math.min(Math.round(root.width * 0.33), idealWidth))
        height: form.implicitHeight

        LoginForm {
            id: form
            width: parent.width
            uiScale: loginPanel.uiScale
            pal: pal

            // Half the accent shape's rotated height. LoginForm opens a gap
            // under the brand row big enough to clear it, so the shape can be
            // centred on that row without its lower vertex reaching the username.
            accentClearance: accentShape.height / 2

            // Null item -> no hint. See the Loader above.
            showHint: !root.hintDismissed
                      && hintState.item !== null
                      && hintState.item.hintPending
            onPickerUsed: root.hintDismissed = true
        }
    }

    // --- system controls ---------------------------------------------------
    // Bottom-right, the conventional spot. Outlined circles sitting directly in
    // the scene: the glass pill that used to hold them went with the card it was
    // matching. See the header of Components/PowerMenu.qml for why they are
    // outlined rather than bare, and for why there are three of them and not the
    // five a desktop shell would have.
    PowerMenu {
        id: powerMenu
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: Math.round(root.width * 0.028)
        anchors.bottomMargin: Math.round(root.height * 0.045)
        pal: pal
        // Same share of the screen at any resolution, like everything else here.
        btn: Math.max(40, Math.round(root.height * 0.033))
    }

    Connections {
        target: sddm

        // The hint is retired on the first SUCCESSFUL login, which is the moment
        // that proves someone got through the screen -- not on the first attempt,
        // and not merely on having been shown once. markShown() flushes
        // immediately; see the note on it in Components/HintState.qml for why
        // that cannot be left to QSettings' usual deferred write.
        function onLoginSucceeded() {
            if (hintState.item)
                hintState.item.markShown()
        }
    }

    // Focus the password field as soon as the greeter is up, so the common case
    // (last user already selected) is type-password-and-enter.
    Component.onCompleted: form.focusPassword()
}
