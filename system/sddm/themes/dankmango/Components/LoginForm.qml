// DankMango SDDM theme -- login form.
//
// User picker, password field, session picker, login button, error line.
// Controls are styled explicitly rather than relying on the Qt Controls default
// style: the greeter runs with whatever style happens to be default for the
// sddm user, so anything not styled here is not reliably styled at all.

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

ColumnLayout {
    id: form

    // Injected by Main.qml. Declared with a default so this file still has a
    // resolvable palette if it is ever instantiated on its own.
    property var pal: null

    // Set by the card, which derives it from its own width against the 380px it
    // was tuned at. EVERY size in this file goes through s() rather than being a
    // literal, because the card is now screen-relative: without this the form's
    // type and padding would stay put while the card grew around them, and a
    // bigger card would just mean more empty glass and stubbier fields.
    //
    // Default 1.0 so instantiating this on its own still gives the tuned look.
    property real uiScale: 1.0

    // Reads as a unit conversion at every call site, which is the point -- the
    // literals stay recognisable as the values they were tuned at.
    function s(px) { return Math.round(px * form.uiScale) }

    // Row gap. Raised from the tuned 14 as part of making the card taller: the
    // four gaps between the five visible rows are the cheapest vertical height
    // to buy, because they add air without touching field or type size.
    spacing: s(20)

    property string errorText: ""
    // Guards against a second login() while one is already in flight -- SDDM
    // does not queue attempts, and a double-submit wedges the greeter.
    property bool busy: false

    readonly property int fieldHeight: s(44)
    readonly property int fieldRadius: s(12)

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

    // Card header: wordmark + mango icon, centred as a unit.
    RowLayout {
        Layout.fillWidth: true
        // On top of the row gap, so the wordmark sits clear of the fields rather
        // than reading as the first item in the same stack.
        Layout.bottomMargin: form.s(8)
        spacing: form.s(10)

        Item { Layout.fillWidth: true }   // centring spacer

        Label {
            text: "DankMango"
            color: pal.text
            font.pixelSize: form.s(30)
            font.weight: Font.Bold
            font.letterSpacing: form.s(2)
        }

        Image {
            // Cropped from dankmango-logo-transparent.png: the icon block only,
            // no "DANK MANGO" wordmark (the source has the two separated by a
            // clean transparent band, so this is a straight crop).
            source: "../logo.png"
            // Sized off the title's cap height rather than a magic number, so it
            // keeps sitting naturally beside the text if the title size changes.
            Layout.preferredHeight: form.s(30)
            Layout.preferredWidth: Layout.preferredHeight * (implicitWidth / implicitHeight)
            fillMode: Image.PreserveAspectFit
            // Pixel-art source at 588x672 shown around 26px wide -- let Qt
            // downsample smoothly rather than nearest-neighbour it into aliasing.
            smooth: true
            mipmap: true
            asynchronous: false
        }

        Item { Layout.fillWidth: true }   // centring spacer
    }

    // --- user picker -------------------------------------------------------
    ComboBox {
        id: userField
        Layout.fillWidth: true
        Layout.preferredHeight: form.fieldHeight
        model: userModel
        // theme.conf values are strings -- compare explicitly.
        textRole: config.UseRealName === "true" ? "realName" : "name"
        currentIndex: userModel.lastIndex

        background: Rectangle {
            radius: form.fieldRadius
            color: userField.hovered ? pal.fieldBgHot : pal.fieldBg
            border.width: 1
            border.color: userField.activeFocus ? pal.accent : pal.glassBorder
            Behavior on color { ColorAnimation { duration: 120 } }
        }
        contentItem: Text {
            leftPadding: form.s(14)
            rightPadding: userField.indicator.width + form.s(8)
            text: userField.displayText
            color: pal.text
            font.pixelSize: form.s(15)
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        indicator: Chevron {
            width: form.s(14)
            height: width
            x: userField.width - width - form.s(14)
            y: (userField.height - height) / 2
            color: pal.subText
        }
        popup: Popup {
            y: userField.height + form.s(4)
            width: userField.width
            implicitHeight: Math.min(contentItem.implicitHeight + form.s(8), form.s(220))
            padding: form.s(4)
            background: Rectangle {
                radius: form.fieldRadius
                color: pal.surfaceHigh
                border.width: 1
                border.color: pal.glassBorder
            }
            contentItem: ListView {
                clip: true
                implicitHeight: contentHeight
                model: userField.popup.visible ? userField.delegateModel : null
                currentIndex: userField.highlightedIndex
                ScrollIndicator.vertical: ScrollIndicator {}
            }
        }
        delegate: ItemDelegate {
            width: userField.width - form.s(8)
            height: form.s(36)
            highlighted: userField.highlightedIndex === index
            background: Rectangle {
                radius: form.s(8)
                color: highlighted ? pal.fieldBgHot : "transparent"
            }
            contentItem: Text {
                leftPadding: form.s(10)
                text: model[userField.textRole] || ""
                color: pal.text
                font.pixelSize: form.s(14)
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
        }
    }

    // --- password ----------------------------------------------------------
    TextField {
        id: passwordField
        Layout.fillWidth: true
        Layout.preferredHeight: form.fieldHeight
        echoMode: TextInput.Password
        placeholderText: "Password"
        placeholderTextColor: pal.subText
        color: pal.text
        font.pixelSize: form.s(15)
        leftPadding: form.s(14)
        rightPadding: form.s(14)
        enabled: !form.busy
        onAccepted: form.doLogin()

        background: Rectangle {
            radius: form.fieldRadius
            color: passwordField.activeFocus ? pal.fieldBgHot : pal.fieldBg
            border.width: 1
            border.color: passwordField.activeFocus ? pal.accent : pal.glassBorder
            Behavior on border.color { ColorAnimation { duration: 120 } }
        }
    }

    // --- session -----------------------------------------------------------
    ComboBox {
        id: sessionField
        Layout.fillWidth: true
        Layout.preferredHeight: form.fieldHeight
        model: sessionModel
        textRole: "name"
        currentIndex: sessionModel.lastIndex

        background: Rectangle {
            radius: form.fieldRadius
            color: sessionField.hovered ? pal.fieldBgHot : pal.fieldBg
            border.width: 1
            border.color: sessionField.activeFocus ? pal.accent : pal.glassBorder
            Behavior on color { ColorAnimation { duration: 120 } }
        }
        // Distinguished from the user picker by a leading label. Previously the
        // two combos were pixel-identical, which made the session control read
        // as a second account field -- the one genuinely confusable pair on the
        // form. Wiring is untouched; this is presentation only.
        contentItem: Item {
            anchors.fill: parent

            Text {
                id: sessionLabel
                anchors.left: parent.left
                anchors.leftMargin: form.s(14)
                anchors.verticalCenter: parent.verticalCenter
                text: "Session"
                color: pal.subText
                opacity: 0.75
                font.pixelSize: form.s(12)
                font.letterSpacing: form.s(1)
            }

            Text {
                anchors.left: sessionLabel.right
                anchors.leftMargin: form.s(10)
                anchors.right: parent.right
                anchors.rightMargin: sessionField.indicator.width + form.s(24)
                anchors.verticalCenter: parent.verticalCenter
                text: sessionField.displayText
                color: pal.text
                font.pixelSize: form.s(14)
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
        }
        indicator: Chevron {
            width: form.s(14)
            height: width
            x: sessionField.width - width - form.s(14)
            y: (sessionField.height - height) / 2
            color: pal.subText
        }
        popup: Popup {
            y: sessionField.height + form.s(4)
            width: sessionField.width
            implicitHeight: Math.min(contentItem.implicitHeight + form.s(8), form.s(220))
            padding: form.s(4)
            background: Rectangle {
                radius: form.fieldRadius
                color: pal.surfaceHigh
                border.width: 1
                border.color: pal.glassBorder
            }
            contentItem: ListView {
                clip: true
                implicitHeight: contentHeight
                model: sessionField.popup.visible ? sessionField.delegateModel : null
                currentIndex: sessionField.highlightedIndex
                ScrollIndicator.vertical: ScrollIndicator {}
            }
        }
        delegate: ItemDelegate {
            width: sessionField.width - form.s(8)
            height: form.s(36)
            highlighted: sessionField.highlightedIndex === index
            background: Rectangle {
                radius: form.s(8)
                color: highlighted ? pal.fieldBgHot : "transparent"
            }
            contentItem: Text {
                leftPadding: form.s(10)
                text: model.name || ""
                color: pal.text
                font.pixelSize: form.s(14)
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
        }
    }

    // --- submit ------------------------------------------------------------
    Button {
        id: loginButton
        Layout.fillWidth: true
        Layout.preferredHeight: form.fieldHeight
        // Matches the header's bottom margin, so the three input rows read as one
        // group with the wordmark above and the action below it.
        Layout.topMargin: form.s(8)
        text: form.busy ? "Signing in…" : "Log In"
        enabled: !form.busy

        background: Rectangle {
            radius: form.fieldRadius
            color: !loginButton.enabled ? pal.fieldBg
                 : loginButton.down     ? Qt.darker(pal.accent, 1.15)
                 : loginButton.hovered  ? Qt.lighter(pal.accent, 1.08)
                                        : pal.accent
            Behavior on color { ColorAnimation { duration: 120 } }
        }
        contentItem: Text {
            text: loginButton.text
            color: loginButton.enabled ? pal.onAccent : pal.subText
            font.pixelSize: form.s(15)
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        onClicked: form.doLogin()
    }

    // --- status ------------------------------------------------------------
    Label {
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        color: form.errorText !== "" ? pal.error : pal.subText
        font.pixelSize: form.s(13)
        visible: text.length > 0
        text: form.errorText !== "" ? form.errorText
                                    : (keyboard.capsLock ? "Caps Lock is on" : "")
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
}
