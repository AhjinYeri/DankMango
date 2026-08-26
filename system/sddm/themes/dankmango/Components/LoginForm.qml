// DankMango SDDM theme -- login cluster.
//
// User picker, password, session picker, submit, status line. Controls are
// styled explicitly rather than relying on the Qt Controls default style: the
// greeter runs with whatever style happens to be default for the sddm user, so
// anything not styled here is not reliably styled at all.
//
// ---------------------------------------------------------------------------
// NO CONTAINER, AND WHAT THAT COSTS
// ---------------------------------------------------------------------------
// This used to live inside a rounded frosted-glass card. It does not any more:
// the fields sit directly in the scene so the screen reads as one picture rather
// than as a UI floating on top of a photograph.
//
// The card was not only decoration, though, and pretending otherwise is how this
// change goes wrong. It was doing two jobs:
//
//   1. CONTRAST. 55%-opaque glass over a blurred wallpaper is a guaranteed
//      backdrop for the text on it. Without it, every glyph here sits on the
//      wallpaper directly and inherits whatever that pixel happens to be -- and
//      the left third of a wallpaper is not reliably dark. Clock.qml already
//      solved exactly this problem for the one element that was always outside
//      the card, and the fix is the same one: the cluster carries its own shadow
//      (see the layer at the bottom of this file). Take it away and this form is
//      legible only by luck.
//
//   2. AFFORDANCE. A boxed field says "type here" without being asked. Bare text
//      on a photo does not. That is a real cost of the new look, not a detail,
//      and it is paid for deliberately in three places: a chevron that is always
//      visible next to the two pickers, an underline under every row, and a
//      hover/focus state that lights both in the accent colour. See `hot` below.
//
// ---------------------------------------------------------------------------
// NO LABELS
// ---------------------------------------------------------------------------
// There is no "User", "Password" or "Session" caption anywhere. The VALUE is the
// field: the row shows "chris" and "Mango", not "User: chris". The password row
// is the one place a word still appears, and it is a PLACEHOLDER inside the
// field rather than a label above it -- an empty rule with nothing on it would
// be genuinely undiscoverable, which is the failure this whole design is trying
// to avoid rather than a rule to follow off a cliff.

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Effects

ColumnLayout {
    id: form

    // Injected by Main.qml. Declared with a default so this file still has a
    // resolvable palette if it is ever instantiated on its own.
    property var pal: null

    // Set by Main.qml, which derives it from the cluster's width against the
    // 380px it was tuned at. EVERY size in this file goes through s() rather
    // than being a literal, because the cluster is sized in millimetres off the
    // panel's real DPI: without this the type and spacing would stay put while
    // the cluster grew around them.
    //
    // Default 1.0 so instantiating this on its own still gives the tuned look.
    property real uiScale: 1.0

    // Reads as a unit conversion at every call site, which is the point -- the
    // literals stay recognisable as the values they were tuned at.
    function s(px) { return Math.round(px * form.uiScale) }

    // Whether the one-time "these are clickable" hint is currently wanted.
    // Owned by Main.qml (which persists the flag); this file only renders it and
    // reports back when the user has plainly discovered the pickers on their own.
    property bool showHint: false
    signal pickerUsed()

    // Size of the brand mark beside the wordmark, from the mockup's ratio of the
    // two: a 28px swatch against a 20px wordmark. Expressed against the wordmark
    // rather than as its own literal so the pair keeps its proportions if the
    // type size is ever retuned.
    //
    // It is also the brand row's HEIGHT: the swatch is taller than the wordmark's
    // line box, so it is what sets the row. Several things below measure against
    // it for that reason.
    readonly property int markSize: Math.round(form.s(26) * 28 / 20)

    // Half the height of the accent shape Main.qml draws over the brand row.
    // Injected rather than recomputed here: Main.qml owns that shape's geometry,
    // and two independent copies of the same ratio is how a gap silently stops
    // matching the thing it was sized to clear.
    property real accentClearance: 0

    // Where the wordmark's centreline sits, in this item's coordinates -- the
    // line Main.qml centres the accent shape on. Published as a property rather
    // than letting the caller reach into brandRow directly, because the layout
    // owns brandRow's y and that is exactly the sort of value that moves without
    // anyone noticing.
    readonly property real brandCenterY: brandRow.y + brandRow.height / 2

    // What has to sit between the brand row and the first field so the accent
    // shape, centred on the brand row, clears the username entirely.
    //
    // The shape reaches accentClearance below that centreline; the brand row
    // itself only accounts for half its own height; the rest has to come out of
    // this margin, plus a real gap on top so the two are visibly separated
    // rather than merely not touching.
    //
    // Measured against markSize rather than brandRow.height on purpose: brandRow's
    // height is a layout output, and feeding a layout's output back into one of
    // its own margins is a binding loop waiting to happen. markSize is an input
    // and is what sets that height anyway.
    //
    // Falls back to the plain tuned margin when no shape is injected, so this
    // file still lays out correctly on its own.
    //
    // The trailing term is the visible gap between the shape's lower vertex and
    // the top of the username row -- the only part of this expression that is a
    // taste decision rather than geometry. s(13) measures 18px on a 27in 1440p
    // panel, down from the s(16)/23px it was first set at.
    //
    // WORTH KNOWING WHICH WAY THIS MOVES THINGS. The panel is anchored by its
    // BOTTOM edge, so shrinking this does not lift the fields towards the brand
    // row -- the fields are below it and stay where they are, and the brand row
    // and its accent shape come DOWN to meet them instead. The gap closes by the
    // full amount either way, which is what this controls; but if the intent was
    // ever specifically to raise the fields up the screen, this is the wrong
    // number and the panel's bottom margin in Main.qml is the right one.
    readonly property int brandGap: Math.max(form.s(10),
                                             Math.round(form.accentClearance
                                                        - form.markSize / 2
                                                        + form.s(13)))

    spacing: s(16)

    property string errorText: ""
    // Guards against a second login() while one is already in flight -- SDDM
    // does not queue attempts, and a double-submit wedges the greeter.
    property bool busy: false

    function focusPassword() {
        passwordField.forceActiveFocus()
    }

    function doLogin() {
        if (form.busy || passwordField.text.length === 0)
            return
        form.busy = true
        form.errorText = ""
        // sessionModel is indexed by row; currentIndex is what login() wants.
        sddm.login(userField.currentText,
                   passwordField.text,
                   sessionField.currentIndex)
    }

    // --- shared row furniture ----------------------------------------------
    // The underline that replaces the field box. One per row, full cluster
    // width, so the three rows read as a single stack of rules rather than as
    // three separate widgets -- which is the whole "continuous scene" idea.
    //
    // `hot` is the discoverability state: hovered OR keyboard-focused OR (for a
    // picker) popped open. All three are folded into one property per row so the
    // underline and the chevron cannot disagree about whether the row is active,
    // which is exactly the sort of thing that goes unnoticed until it looks
    // broken on the one screen that is hard to iterate on.
    component Underline: Rectangle {
        property bool hot: false
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        // Rest is deliberately quiet but NOT hairline. A 1px rule measured fine
        // in isolation and then disappeared over the bright half of a real
        // wallpaper -- and on a form with no boxes, a rule that disappears takes
        // the field with it. 1.5 rounds to 2 at the scale a 27in panel produces,
        // which is the smallest weight that survived the render.
        height: hot ? Math.max(2, form.s(2.5)) : Math.max(1, form.s(1.5))
        color: hot ? form.pal.accent : form.pal.rule
        Behavior on color  { ColorAnimation  { duration: 140 } }
        Behavior on height { NumberAnimation { duration: 140 } }
    }

    // Shared popup styling for the two pickers. The popup is the one place a
    // real surface is still drawn -- a transparent dropdown over a photograph is
    // unreadable, and "no card" was a statement about the resting screen, not a
    // ban on ever painting a background.
    component PickerPopup: Popup {
        property var owner: null
        y: owner.height + form.s(6)
        width: owner.width
        implicitHeight: Math.min(contentItem.implicitHeight + form.s(8), form.s(240))
        padding: form.s(4)
        background: Rectangle {
            radius: form.s(12)
            color: form.pal.surfaceHigh
            border.width: 1
            border.color: form.pal.glassBorder
        }
        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: owner.popup.visible ? owner.delegateModel : null
            currentIndex: owner.highlightedIndex
            ScrollIndicator.vertical: ScrollIndicator {}
        }
    }

    // --- brand ---------------------------------------------------------------
    // Mark then wordmark, in that order, left-aligned like everything else in
    // the cluster. Both the order and the swatch come from the mockup's
    // `.brand`, which puts `.mark` before `.word`.
    //
    // WHY A DRAWN SWATCH AND NOT logo.png. The previous revision put the
    // pixel-art mango icon here, at a size where it read as an emoji dropped
    // into the text rather than as a mark. The mockup does not use the logo at
    // all: it draws a plain rounded square filled with a mango gradient, which
    // is legible at any size, has no image to fail to load, and sits as a shape
    // beside the word rather than competing with it as a picture. logo.png is
    // left installed and unreferenced -- removing it is an install.sh change and
    // out of scope here.
    RowLayout {
        id: brandRow
        Layout.fillWidth: true
        // Sized to clear the accent shape rather than to a tuned constant -- see
        // brandGap above for why, and for what it degrades to without one.
        Layout.bottomMargin: form.brandGap
        // The mockup's 10px gap between the swatch and the word, in the same
        // units as everything else here.
        spacing: form.s(10)

        Rectangle {
            Layout.preferredWidth: form.markSize
            Layout.preferredHeight: form.markSize
            Layout.alignment: Qt.AlignVCenter
            antialiasing: true

            // The mockup asks for 6px on the top corners and 8px on the bottom.
            // Per-corner radii exist on Rectangle from Qt 6.7, but reaching for
            // a revision-gated property in the one QML file that has to load on
            // a screen with no session behind it is a poor trade for a two-pixel
            // difference on a 50px swatch. One radius, the average of the two.
            radius: Math.round(form.markSize * 7 / 28)

            // Brand colours, deliberately NOT palette-derived. Everything else
            // on this screen re-tints with the wallpaper; this is the one mark
            // that identifies the distro, and a mango that turns blue with the
            // wallpaper is not a mango. Same three stops as the mockup.
            //
            // A plain vertical Gradient rather than the mockup's 160deg: QML's
            // built-in Gradient is axis-aligned, and 160deg is 20 degrees off
            // straight down. Matching it exactly would mean QtQuick.Shapes or a
            // ShaderEffect -- another module to load, pre-auth, for a tilt that
            // is invisible at this size.
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#ffb15a" }
                GradientStop { position: 0.5; color: "#ff5a7a" }
                GradientStop { position: 1.0; color: "#ff3a5c" }
            }
        }

        Label {
            text: "DankMango"
            color: pal.text
            font.pixelSize: form.s(26)
            font.weight: Font.Bold
            font.letterSpacing: form.s(2)
            Layout.alignment: Qt.AlignVCenter
        }

        Item { Layout.fillWidth: true }
    }

    // --- user picker -------------------------------------------------------
    // The largest type in the cluster. With no card header and no label, the
    // username is what tells you whose machine this is, so it gets the weight
    // the wordmark used to have.
    ComboBox {
        id: userField
        Layout.fillWidth: true
        Layout.preferredHeight: form.s(50)
        model: userModel
        // theme.conf values are strings -- compare explicitly.
        textRole: config.UseRealName === "true" ? "realName" : "name"
        currentIndex: userModel.lastIndex

        readonly property bool hot: hovered || activeFocus || popup.visible
        onPressedChanged: if (pressed) form.pickerUsed()

        background: Item { Underline { hot: userField.hot } }

        // The default indicator is a chevron pinned to the RIGHT EDGE of the
        // control, which is what a boxed combo wants. This one is not boxed, and
        // a chevron floating alone at the far end of an invisible box does not
        // read as belonging to the name. It has to sit against the value --
        // "chris ⌄" -- so it is drawn in the contentItem instead and the real
        // indicator is dropped.
        indicator: null

        contentItem: Item {
            Text {
                id: userText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                // Long names elide rather than running under the chevron.
                width: Math.min(implicitWidth, parent.width - form.s(34))
                text: userField.displayText
                color: pal.text
                font.pixelSize: form.s(27)
                font.weight: Font.Medium
                elide: Text.ElideRight
            }
            Chevron {
                anchors.left: userText.right
                anchors.leftMargin: form.s(11)
                anchors.verticalCenter: userText.verticalCenter
                // Optical, not geometric: the chevron's ink sits in the lower
                // half of its box, so centring the BOX leaves it looking high.
                anchors.verticalCenterOffset: form.s(2)
                width: form.s(16)
                height: width
                thickness: Math.max(1.6, form.s(1.8))
                color: userField.hot ? pal.accent : pal.subText
                Behavior on color { ColorAnimation { duration: 140 } }
            }
        }

        popup: PickerPopup { owner: userField }

        delegate: ItemDelegate {
            width: userField.width - form.s(8)
            height: form.s(38)
            highlighted: userField.highlightedIndex === index
            background: Rectangle {
                radius: form.s(8)
                color: highlighted ? pal.fieldBgHot : "transparent"
            }
            contentItem: Text {
                leftPadding: form.s(10)
                text: model[userField.textRole] || ""
                color: pal.text
                font.pixelSize: form.s(15)
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
        }
    }

    // --- password ----------------------------------------------------------
    TextField {
        id: passwordField
        Layout.fillWidth: true
        Layout.preferredHeight: form.s(46)
        echoMode: TextInput.Password
        placeholderText: "Password"
        placeholderTextColor: pal.subText
        color: pal.text
        font.pixelSize: form.s(17)
        // No box, so no inset. The text starts on the same vertical line as the
        // username above it and the session below it; that shared left edge is
        // what holds the three rows together now that nothing frames them.
        leftPadding: 0
        rightPadding: 0
        enabled: !form.busy
        onAccepted: form.doLogin()

        readonly property bool hot: hovered || activeFocus

        background: Item { Underline { hot: passwordField.hot } }
    }

    // --- session + submit --------------------------------------------------
    // ONE row, not two. The session picker is the row you touch least and the
    // button is the one you touch every time, so stacking them full-width gave
    // equal billing to two very unequal controls -- and made the cluster a
    // column of four identical-width bars. Side by side, the picker takes the
    // space it needs on the shared left edge and the button sits at the end of
    // the line as a discrete object.
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: form.s(14)
        spacing: form.s(16)

        ComboBox {
            id: sessionField
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            // Matched to the button beside it, so the underline and the pill's
            // lower edge land on the same line instead of missing each other by a
            // couple of pixels.
            Layout.preferredHeight: form.s(42)
            model: sessionModel
            textRole: "name"
            currentIndex: sessionModel.lastIndex

            readonly property bool hot: hovered || activeFocus || popup.visible
            onPressedChanged: if (pressed) form.pickerUsed()

            background: Item { Underline { hot: sessionField.hot } }
            indicator: null

            contentItem: Item {
                Text {
                    id: sessionText
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, parent.width - form.s(30))
                    text: sessionField.displayText
                    color: sessionField.hot ? pal.text : pal.subText
                    font.pixelSize: form.s(15)
                    elide: Text.ElideRight
                    Behavior on color { ColorAnimation { duration: 140 } }
                }
                Chevron {
                    anchors.left: sessionText.right
                    anchors.leftMargin: form.s(9)
                    anchors.verticalCenter: sessionText.verticalCenter
                    anchors.verticalCenterOffset: form.s(1)
                    width: form.s(13)
                    height: width
                    thickness: Math.max(1.4, form.s(1.6))
                    color: sessionField.hot ? pal.accent : pal.subText
                    Behavior on color { ColorAnimation { duration: 140 } }
                }
            }

            popup: PickerPopup { owner: sessionField }

            delegate: ItemDelegate {
                width: sessionField.width - form.s(8)
                height: form.s(38)
                highlighted: sessionField.highlightedIndex === index
                background: Rectangle {
                    radius: form.s(8)
                    color: highlighted ? pal.fieldBgHot : "transparent"
                }
                contentItem: Text {
                    leftPadding: form.s(10)
                    text: model.name || ""
                    color: pal.text
                    font.pixelSize: form.s(15)
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                }
            }
        }

        // An OUTLINED pill, not a filled one. A solid accent block was the heaviest
        // thing on the screen by a wide margin -- in a cluster whose every other
        // element is a thin rule or a two-pixel chevron, it read as a control
        // borrowed from a different design. Reducing it to a border puts it in the
        // same vocabulary as the underlines and the system-control rings: same line
        // weight, same resting colour, same accent on approach.
        //
        // It is still unmistakably the primary action, because it is the only closed
        // shape in the cluster. It no longer shouts about it.
        Button {
            id: loginButton
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredHeight: form.s(42)
            // Sized to its text rather than filling the row, which is what makes it
            // an object on the line instead of a fourth bar.
            Layout.preferredWidth: form.s(132)
            text: form.busy ? "Signing in…" : "Log In"
            enabled: !form.busy

            readonly property bool hot: enabled && (hovered || activeFocus)

            background: Rectangle {
                // A true pill: radius is half the height, so it stays a pill at any
                // uiScale rather than becoming a rounded rectangle on a big panel.
                radius: height / 2
                color: !loginButton.enabled ? "transparent"
                     : loginButton.down     ? pal.fieldBgHot
                     : loginButton.hovered  ? pal.fieldBg
                                            : "transparent"
                border.width: Math.max(1, form.s(1.5))
                border.color: !loginButton.enabled ? Qt.rgba(1, 1, 1, 0.14)
                            : loginButton.hot      ? pal.accent
                                                   : pal.rule
                Behavior on color        { ColorAnimation { duration: 120 } }
                Behavior on border.color { ColorAnimation { duration: 120 } }
            }
            contentItem: Text {
                text: loginButton.text
                color: !loginButton.enabled ? pal.subText
                     : loginButton.hot      ? pal.accent
                                            : pal.text
                font.pixelSize: form.s(15)
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                Behavior on color { ColorAnimation { duration: 120 } }
            }
            onClicked: form.doLogin()
        }
    }

    // --- status ------------------------------------------------------------
    // Errors and Caps Lock. Left-aligned with everything else now; it was
    // centred under a centred card.
    Label {
        Layout.fillWidth: true
        color: form.errorText !== "" ? pal.error : pal.subText
        font.pixelSize: form.s(13)
        visible: text.length > 0
        text: form.errorText !== "" ? form.errorText
                                    : (keyboard.capsLock ? "Caps Lock is on" : "")
    }

    // --- one-time hint -----------------------------------------------------
    // Shown only until the first successful login, and only while the flag says
    // so -- see Components/HintState.qml and the note in Main.qml for where that
    // flag lives and why it lives there.
    //
    // Small, muted, and NOT an error: it sits below the button in the position
    // a footnote would, so it reads as an aside rather than as something wrong.
    Label {
        Layout.fillWidth: true
        Layout.topMargin: form.s(4)
        visible: form.showHint
        opacity: form.showHint ? 0.8 : 0
        color: pal.subText
        font.pixelSize: form.s(12)
        font.italic: true
        wrapMode: Text.WordWrap
        text: "click your name or session to change them"
        Behavior on opacity { NumberAnimation { duration: 200 } }
    }

    Connections {
        target: sddm

        // Qt6 / QML Connections require the function-style handler.
        function onLoginFailed() {
            form.busy = false
            form.errorText = "Login failed"
            passwordField.text = ""
            passwordField.forceActiveFocus()
        }

        function onLoginSucceeded() {
            // Greeter is torn down by SDDM at this point; just stop showing an
            // error so the last frame is not a stale failure message.
            form.busy = false
            form.errorText = ""
        }
    }

    // --- contrast ----------------------------------------------------------
    // What the card's glass used to do, done the way Clock.qml already does it:
    // the cluster carries its own dark halo, so its legibility does not depend
    // on what the wallpaper happens to be doing behind it.
    //
    // ONE layer over the whole cluster rather than a shadow per Text. Same
    // reasoning as the single accent shape: the rows have to look like one
    // object, and per-element shadows drift apart at different sizes. The
    // filled button is inside the layer too and that is fine -- a solid accent
    // block with a soft dark halo reads as sitting ON the scene, which is
    // exactly what is wanted now that nothing else grounds it.
    //
    // NO VERTICAL OFFSET, for the reason worked out at length in Clock.qml: this
    // is a contrast source, not decoration, and offsetting it moves cover away
    // from the tops of the glyphs, which is measurably where legibility fails
    // first on a bright wallpaper.
    //
    // The popups are NOT in this layer -- Popup renders into the window's
    // overlay, not as a child of this item -- so opening a picker is unaffected.
    layer.enabled: true
    layer.effect: MultiEffect {
        shadowEnabled: true
        shadowBlur: 1.0
        shadowColor: "#000000"
        shadowOpacity: 0.85
        shadowVerticalOffset: 0
        // Tracks type size, like the clock's does. The cluster's largest glyph
        // is the username; sizing the halo off that keeps it a tight surround
        // rather than a cloud.
        blurMax: Math.max(16, form.s(22))
    }
}
