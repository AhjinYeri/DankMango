// =============================================================================
//  HealthSection.qml  --  the hub's "Health & Repair" section
// =============================================================================
//
//  >>> IF THIS SECTION STOPPED WORKING, START HERE <<<
//  This file holds NO health checks and NO repairs. Not one. Everything on
//  screen comes out of one script:
//
//        ~/.config/mango/scripts/post-update-health.sh
//
//    * `--json` runs the whole scan and returns it as structured data: every
//      finding, and for each fixable one its entire walkthrough -- what broke,
//      what the fix does, the by-hand command, the Claude Code prompt, and a
//      STABLE ID.
//    * `--apply-fix <id>` applies exactly one of those, by id, through the same
//      remedy function (with the same did-it-actually-change guard) that
//      pressing "y" in the terminal walkthrough calls.
//
//  So the two things an update can break here are the script's PATH and the
//  JSON SHAPE, and both are in the box below.
//
//  WHY IT IS A WRAPPER AND NOTHING ELSE
//    A check re-implemented in QML is a check that can disagree with the one in
//    the script, and the day they disagree is the day the report stops being
//    worth reading. The same goes double for the repairs: every remedy in that
//    script verifies the machine actually changed before it reports success,
//    because this project has been bitten by a deploy layer that reported
//    success it never checked. A "Fix" button that ran its own copy of a repair
//    would be a second path where that guard could go missing. There is exactly
//    one path, and this file is not on it -- it asks by id and renders the
//    answer. This is the same arrangement PresetsSection has with set-preset.sh
//    and RipeChromaSection has with the colour engine.
//
// -----------------------------------------------------------------------------
//  WHY THE CARDS START COLLAPSED
// -----------------------------------------------------------------------------
//  The terminal's walkthrough shows one finding at a time and asks about it
//  before moving on. That is not a terminal quirk -- it is the answer to a real
//  problem: printing every breakdown at once and then asking is how people end
//  up saying yes to something they scrolled past.
//
//  A GUI can keep that discipline SPATIALLY instead of temporally. Every fixable
//  finding is one line until you open it, one is open at a time, and the buttons
//  live inside the opened card -- so the thing you are agreeing to is the thing
//  in front of you, exactly as it is in the terminal, without the report having
//  to be doled out in sequence.
//
//  NOTHING IS HIDDEN. The findings with nothing to act on -- the passes, the
//  warnings, the deliberately-off notes -- are all still here, under "Everything
//  else that was checked". They are just visually quiet, because there is no
//  decision to make about any of them.
//
// -----------------------------------------------------------------------------
//  THE ONE CARD THAT LOOKS DIFFERENT
// -----------------------------------------------------------------------------
//  One remedy in the script edits config.conf -- MangoWM's own settings file,
//  the file the guide tells people to edit by hand. Every other one works on a
//  file DankMango owns and rewrites freely. The script marks that finding
//  `"class": "userconfig"`, and this file gives it its own accent, its own icon
//  and a "READ THIS ONE FIRST" chip so it cannot be skimmed past as one more
//  routine recopy.
//
//  That is read from the DATA, not from a list of ids kept over here. A second
//  such finding added to the script in future gets the treatment automatically.
//
// -----------------------------------------------------------------------------
//  WHAT THIS DELIBERATELY DOESN'T DO
// -----------------------------------------------------------------------------
//    * No "fix everything" button. Deferred project-wide, not just in the
//      terminal, and for the same reason: one yes/no per finding is the point.
//    * No scanning unless you came here. Opening this section runs the scan;
//      nothing runs it for you at login, on a timer, or from the bar.
//    * No password prompts. A remedy that needs sudo (the package-patch one)
//      cannot be run from a surface with nowhere to type a password, so its card
//      offers the command instead of a button. It is not quietly skipped and it
//      is not quietly attempted.
// =============================================================================

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: section

    // Filled in by ControlHubPanel's Loader. Used to re-scan when the panel is
    // re-opened; the section works without it, it just wouldn't refresh.
    property var hub: null

    // #########################################################################
    // ########## EDIT HERE IF THE SCRIPT MOVES OR CHANGES #####################
    // #########################################################################

    // Resolved from $HOME at run time via `sh -c`, because execDetached and
    // Process run no shell and a bare "~" would be passed through literally.
    readonly property string healthTool: "\"$HOME/.config/mango/scripts/post-update-health.sh\""

    // --apply-fix's exit codes, straight from that script's header:
    //   0  applied, and the remedy verified the machine really changed
    //   1  the remedy ran and reported failure -- NOT fixed
    //   4  no finding with that id in a fresh scan (usually: already fixed)
    // Anything else is the script itself failing to run.
    readonly property int exitApplied: 0
    readonly property int exitRemedyFailed: 1
    readonly property int exitNotFound: 4

    // The JSON contract, documented in post-update-health.sh's own header:
    //   { schema, versions{}, summary{passed,issues,fixable},
    //     checks[ {tag,section,id,message,detail,manual,where} ],
    //     fixes[  {id,severity,class,needsPassword,headline,broke,does,
    //              manual,prompt} ] }
    // If a future scan bumps `schema`, read the new shape before trusting it.
    readonly property int expectedSchema: 1

    // How tall this section is allowed to get before it scrolls inside itself.
    // THE PANEL DOES NOT SCROLL -- it sizes itself to whatever its section asks
    // for (see ControlHubPanel's cardHeight). With ~50 findings and a couple of
    // cards open, an unbounded section would ask for more height than the screen
    // has and simply run off the bottom of it. The cap is set for the smaller of
    // this machine's two monitors with the panel's own padding allowed for.
    readonly property real maxContentHeight: 620

    // #########################################################################

    implicitHeight: Math.min(content.implicitHeight, section.maxContentHeight)

    // ---- scan state ---------------------------------------------------------
    property bool scanning: false
    property bool scanned: false            // a scan has come back at least once
    property string scanError: ""

    property var summary: null              // {passed, issues, fixable}
    property var versions: null             // {mango, dms, quickshell, changed}
    property var fixes: []                  // the [FIX!] findings, + our own uiState
    property var checks: []                 // every row the scan printed, in scan order

    // The quiet list is everything the cards above are NOT already showing. The
    // FIX rows are in `checks` too (the JSON reports the scan as it really ran),
    // and listing them here as well would say the same thing twice.
    readonly property var quietChecks: {
        var out = []
        for (var i = 0; i < section.checks.length; i++)
            if (section.checks[i].tag !== "FIX")
                out.push(section.checks[i])
        return out
    }

    // Opening a card scrolls it to the top of the viewport. Without this a card
    // whose prose is longer than the section is tall opens with its own buttons
    // below the fold, and the reader has to go looking for the thing they are
    // being asked to decide. The delay is for the expand animation's heights to
    // settle before the position is worked out.
    function reveal(item) {
        revealTimer.target = item
        revealTimer.restart()
    }

    Timer {
        id: revealTimer
        property var target: null
        interval: 80
        repeat: false
        onTriggered: {
            if (!revealTimer.target)
                return
            var y = revealTimer.target.mapToItem(content, 0, 0).y
            scroller.contentY = Math.max(0, Math.min(y - Theme.spacingS,
                                                     scroller.contentHeight - scroller.height))
        }
    }

    // Which card is open. ONE AT A TIME, deliberately -- see the header. It lives
    // here rather than in the delegate because `fixes` is reassigned wholesale
    // whenever a card's state changes (that is what makes the Repeater notice),
    // which would take any per-delegate state with it.
    property string expandedId: ""

    // The fix currently in flight. Guards every button, so a second click during
    // the second-or-so a remedy takes cannot start a second one.
    property string busyId: ""

    // The running tally, mirroring the terminal's closing "N fixed, N skipped"
    // line. Per scan, exactly as that line is per run -- a fresh scan is a fresh
    // report, so re-scanning resets it.
    property int nFixed: 0
    property int nFailed: 0
    property int nSkipped: 0
    readonly property bool anyAction: nFixed + nFailed + nSkipped > 0

    // =========================================================================
    //  TALKING TO THE SCRIPT
    // =========================================================================

    // A TRACKED Process, not execDetached. The presets section can fire and
    // forget because you can see its result on screen a moment later; here the
    // whole point is the answer, and for a fix the answer is an EXIT CODE. The
    // script's remedies are the only thing that knows whether a repair took, and
    // this is how that verdict reaches the card.
    Process {
        id: scanProc
        running: false
        stdout: StdioCollector { id: scanOut }
        stderr: StdioCollector { id: scanErr }
        onExited: function (exitCode) {
            section.scanning = false
            section.scanned = true
            if (exitCode !== 0) {
                var e = scanErr.text ? scanErr.text.trim() : ""
                section.scanError = e.length > 0
                    ? e
                    : "The health check could not run (exit " + exitCode + ")."
                return
            }
            section.parseScan(scanOut.text)
        }
    }

    function rescan() {
        if (section.scanning)
            return
        section.scanning = true
        section.scanError = ""
        section.expandedId = ""
        section.nFixed = 0
        section.nFailed = 0
        section.nSkipped = 0
        scanProc.running = false
        scanProc.command = ["sh", "-c", section.healthTool + " --json"]
        scanProc.running = true
    }

    // The findings are taken as they come. Each fixable one gets two properties
    // of OUR OWN bolted on -- uiState and uiResult -- which are the card's
    // state, never the script's: "fixed" here means --apply-fix returned 0,
    // which means the remedy verified it. It is not "the button was clicked".
    function parseScan(txt) {
        var parsed
        try {
            parsed = JSON.parse(txt)
        } catch (e) {
            section.scanError = "The health check's output could not be read as JSON."
            return
        }
        if (!parsed || parsed.schema !== section.expectedSchema) {
            section.scanError = "This section expects health-check output version "
                + section.expectedSchema + " and got "
                + (parsed && parsed.schema ? parsed.schema : "none")
                + ". Re-run install.sh so the two match."
            return
        }
        section.summary = parsed.summary || null
        section.versions = parsed.versions || null
        section.checks = parsed.checks || []

        var f = []
        var src = parsed.fixes || []
        for (var i = 0; i < src.length; i++) {
            var e = src[i]
            e.uiState = "pending"       // pending | fixing | fixed | failed | skipped
            e.uiResult = ""
            f.push(e)
        }
        section.fixes = f
        section.scanError = ""
    }

    // -- applying one fix -----------------------------------------------------
    Process {
        id: fixProc
        running: false
        stdout: StdioCollector { id: fixOut }
        stderr: StdioCollector { id: fixErr }
        onExited: function (exitCode) {
            var id = section.busyId
            section.busyId = ""
            // The script prints what it did (or why it could not) on stdout, and
            // its complaints on stderr. Both are shown verbatim rather than
            // being re-worded here: those lines name the backup file, and a
            // paraphrase of "your copy is saved at ..." is not a path.
            var out = (fixOut.text || "").trim()
            var err = (fixErr.text || "").trim()
            if (exitCode === section.exitApplied) {
                section.markFix(id, "fixed", out)
                section.nFixed++
            } else if (exitCode === section.exitNotFound) {
                // Not a failure. Between the scan on screen and the fresh scan
                // --apply-fix just ran, this finding stopped existing -- almost
                // always because it was already put right. Say that, and mark it
                // fixed, because it is.
                section.markFix(id, "fixed", err.length > 0 ? err : "Already resolved — this no longer shows up in a fresh scan.")
                section.nFixed++
            } else {
                var msg = out.length > 0 ? out : err
                section.markFix(id, "failed", msg.length > 0
                    ? msg
                    : "The fix reported failure (exit " + exitCode + ").")
                section.nFailed++
            }
        }
    }

    // The id is forwarded as an ARGUMENT ("$@"), never spliced into the command
    // string -- the same rule the presets section applies to preset names, and it
    // matters more here: some ids carry a file path in them.
    function applyFix(id) {
        if (section.busyId !== "")
            return
        section.busyId = id
        section.markFix(id, "fixing", "")
        fixProc.running = false
        fixProc.command = ["sh", "-c", section.healthTool + " --apply-fix \"$@\"", "sh", id]
        fixProc.running = true
    }

    function skipFix(id) {
        if (section.busyId !== "")
            return
        section.markFix(id, "skipped", "")
        section.nSkipped++
        section.expandedId = ""
    }

    // Reassigning the whole array is what makes the Repeater re-read it: mutating
    // one object in place changes nothing QML is watching.
    function markFix(id, state, text) {
        var f = section.fixes.slice()
        for (var i = 0; i < f.length; i++) {
            if (f[i].id !== id)
                continue
            f[i].uiState = state
            f[i].uiResult = text
        }
        section.fixes = f
    }

    // wl-copy is already a DankMango dependency (install.sh's Nemo action uses
    // it). Text goes in as an ARGUMENT for the same reason ids do.
    function copyText(t) {
        if (!t || t.length === 0)
            return
        Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy", "sh", t])
    }

    Component.onCompleted: section.rescan()

    // Re-scan when the panel is re-opened, the way the presets section re-reads
    // its list: the Loader keeps this file alive in between, and the user may
    // have run install.sh in a terminal since. A fresh scan is a fresh report, so
    // this resets the tally -- see rescan().
    Connections {
        target: section.hub
        enabled: section.hub !== null
        function onPanelOpenChanged() {
            if (section.hub.panelOpen)
                section.rescan()
        }
    }

    // =========================================================================
    //  TWO SMALL PIECES OF THE OPENED CARD
    // =========================================================================
    //  Inline components, not files of their own: the hub's rule is one section
    //  = one file, and these are two shapes used twice each inside this one
    //  card. Nothing else in the panel wants them.

    // A heading and a paragraph of the script's own prose.
    component HealthBlock: Column {
        property string label: ""
        property color labelColor: Theme.surfaceTextMedium
        property string body: ""

        spacing: 2
        visible: body.length > 0

        StyledText {
            width: parent.width
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: parent.labelColor
            text: parent.label
        }

        StyledText {
            width: parent.width
            wrapMode: Text.WordWrap
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceTextMedium
            text: parent.body
        }
    }

    // A heading, a copy button, and a block of something you would otherwise be
    // retyping by hand -- the by-hand command, or the Claude Code prompt.
    // MONOSPACE, and the copy button is the ONLY way out of it. The panel asks
    // for no keyboard focus (see ControlHubPanel's header -- that is what keeps
    // the keybind working while it is open), so there is no Ctrl+C to fall back
    // on and a drag-selectable block would be a half-working affordance. The
    // whole block is copied at once instead.
    component HealthCode: Column {
        id: codeBlock
        property string label: ""
        property string body: ""
        signal copyRequested

        spacing: 2
        visible: body.length > 0

        Item {
            width: parent.width
            height: 22

            StyledText {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceTextMedium
                text: codeBlock.label
            }

            DankActionButton {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                buttonSize: 22
                iconSize: Theme.iconSizeSmall - 2
                iconColor: Theme.surfaceTextMedium
                iconName: "content_copy"
                tooltipText: "Copy"
                onClicked: codeBlock.copyRequested()
            }
        }

        StyledRect {
            width: parent.width
            height: codeText.implicitHeight + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: Qt.rgba(Theme.surfaceContainerHighest.r, Theme.surfaceContainerHighest.g, Theme.surfaceContainerHighest.b, 0.6)

            // ANCHORED TO THE TOP, NOT THE CENTRE. Centring it inside a box whose
            // height is computed from this text's own implicitHeight is a binding
            // loop, and the way it shows up is a command that runs off the right
            // edge instead of wrapping -- which is exactly the text you cannot
            // afford to lose the end of.
            StyledText {
                id: codeText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: Theme.spacingS
                anchors.leftMargin: Theme.spacingS
                anchors.rightMargin: Theme.spacingS
                wrapMode: Text.WordWrap
                isMonospace: true
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceText
                text: codeBlock.body
            }
        }
    }

    // =========================================================================
    //  THE VIEW
    // =========================================================================
    //  Scrolls inside itself rather than growing the panel past the bottom of
    //  the screen -- see maxContentHeight above.
    DankFlickable {
        id: scroller
        anchors.fill: parent
        contentHeight: content.implicitHeight
        clip: true

        Column {
            id: content
            width: scroller.width
            spacing: Theme.spacingM

            // ---- what this is ------------------------------------------------
            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                text: "Checks everything a MangoWM or DankMaterialShell update can quietly break. Looking is always safe — nothing is changed until you open a card and press Fix."
            }

            // ---- scanning ----------------------------------------------------
            StyledRect {
                width: parent.width
                visible: section.scanning
                height: visible ? 64 : 0
                radius: Theme.cornerRadius
                color: Qt.rgba(Theme.surfaceContainerHigh.r, Theme.surfaceContainerHigh.g, Theme.surfaceContainerHigh.b, 0.5)

                Row {
                    anchors.centerIn: parent
                    spacing: Theme.spacingM

                    DankSpinner {
                        anchors.verticalCenter: parent.verticalCenter
                        size: 20
                        color: Theme.primary
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        color: Theme.surfaceText
                        font.pixelSize: Theme.fontSizeSmall
                        text: "Checking…"
                    }
                }
            }

            // ---- the scan itself could not run -------------------------------
            StyledRect {
                width: parent.width
                visible: !section.scanning && section.scanError.length > 0
                height: visible ? errCol.implicitHeight + Theme.spacingM * 2 : 0
                radius: Theme.cornerRadius
                color: Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.08)
                border.width: 1
                border.color: Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.4)

                Column {
                    id: errCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingM
                    spacing: Theme.spacingXS

                    StyledText {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        color: Theme.error
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        text: "The health check itself couldn't run."
                    }

                    StyledText {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        color: Theme.surfaceText
                        font.pixelSize: Theme.fontSizeSmall
                        text: section.scanError
                    }
                }
            }

            // ---- the summary line --------------------------------------------
            // The same three numbers the terminal prints, computed in the script
            // so the two cannot drift.
            Item {
                width: parent.width
                visible: section.scanned && !section.scanning && section.scanError.length === 0
                height: visible ? 34 : 0

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingS

                    Repeater {
                        model: section.summary ? [
                            { "n": section.summary.passed, "label": "passed",
                              "icon": "check_circle", "c": Theme.success },
                            { "n": section.summary.issues, "label": "issue" + (section.summary.issues === 1 ? "" : "s"),
                              "icon": "error", "c": section.summary.issues > 0 ? Theme.warning : Theme.surfaceTextMedium },
                            { "n": section.summary.fixable, "label": "fixable here",
                              "icon": "build_circle", "c": section.summary.fixable > 0 ? Theme.primary : Theme.surfaceTextMedium }
                        ] : []

                        StyledRect {
                            id: pill
                            required property var modelData

                            height: 34
                            width: pillRow.implicitWidth + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Qt.rgba(pill.modelData.c.r, pill.modelData.c.g, pill.modelData.c.b, 0.10)

                            Row {
                                id: pillRow
                                anchors.centerIn: parent
                                spacing: Theme.spacingXS

                                DankIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: pill.modelData.icon
                                    size: Theme.iconSizeSmall
                                    color: pill.modelData.c
                                }

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    color: pill.modelData.c
                                    text: pill.modelData.n + " " + pill.modelData.label
                                }
                            }
                        }
                    }
                }

                DankActionButton {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "refresh"
                    iconColor: Theme.surfaceTextMedium
                    tooltipText: "Check again"
                    enabled: !section.scanning && section.busyId === ""
                    onClicked: section.rescan()
                }
            }

            // ---- "a version changed" ------------------------------------------
            // The report's own first hint, kept: a version that moved since you
            // last looked is the prime suspect for anything below it.
            StyledText {
                width: parent.width
                visible: section.versions !== null && section.versions.changed === true
                wrapMode: Text.WordWrap
                color: Theme.warning
                font.pixelSize: Theme.fontSizeSmall
                text: section.versions
                    ? "A version changed since the last terminal run (mango " + section.versions.mango
                      + ", dms-shell " + section.versions.dms + ", quickshell " + section.versions.quickshell
                      + ") — if anything below is broken, that update is the likely cause."
                    : ""
            }

            // ---- nothing to do -------------------------------------------------
            StyledRect {
                width: parent.width
                visible: section.scanned && !section.scanning && section.scanError.length === 0
                         && section.fixes.length === 0
                height: visible ? okRow.implicitHeight + Theme.spacingM * 2 : 0
                radius: Theme.cornerRadius
                color: Qt.rgba(Theme.success.r, Theme.success.g, Theme.success.b, 0.10)

                Row {
                    id: okRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingM
                    spacing: Theme.spacingM

                    DankIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "task_alt"
                        size: Theme.iconSize - 2
                        color: Theme.success
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - Theme.iconSize - Theme.spacingM * 2
                        wrapMode: Text.WordWrap
                        color: Theme.surfaceText
                        font.pixelSize: Theme.fontSizeSmall
                        text: section.summary && section.summary.issues > 0
                            ? "Nothing here can be fixed from this panel. The full report in a terminal has step-by-step instructions for what's left."
                            : "Nothing to do — every check passed."
                    }
                }
            }

            // ---- the fixable findings, one card each ---------------------------
            //
            //  NO ORDINAL ("[2 of 3]"), unlike the terminal. That number exists
            //  there because a walkthrough arrives one finding at a time and you
            //  cannot see how far through you are. Here you can see all of them
            //  at once, which is the same information without a label.
            Repeater {
                model: section.fixes

                delegate: StyledRect {
                    id: card
                    required property var modelData

                    // "userconfig" is the script's own marking for the one remedy
                    // that edits config.conf. Read from the DATA -- there is no
                    // list of special ids over here, so a second such finding
                    // added to the script gets this treatment for free.
                    readonly property bool isUserConfig: card.modelData["class"] === "userconfig"
                    readonly property bool isOpen: section.expandedId === card.modelData.id
                    readonly property string st: card.modelData.uiState
                    readonly property bool actedOn: st === "fixed" || st === "failed" || st === "skipped"

                    readonly property color accent: card.isUserConfig ? Theme.warning : Theme.primary

                    width: content.width
                    height: cardCol.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    clip: true

                    // The distinct treatment is three things at once -- a warmer
                    // ground, a heavier border and (below) its own icon and chip
                    // -- because any one of them alone reads as decoration.
                    color: card.isUserConfig
                        ? Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.08)
                        : Qt.rgba(Theme.surfaceContainerHigh.r, Theme.surfaceContainerHigh.g, Theme.surfaceContainerHigh.b, 0.5)
                    border.width: card.isUserConfig ? 2 : 1
                    border.color: card.isUserConfig
                        ? Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.55)
                        : Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.35)

                    Behavior on height {
                        enabled: Theme.currentAnimationSpeed !== SettingsData.AnimationSpeed.None
                        NumberAnimation {
                            duration: Theme.shortDuration
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Theme.expressiveCurves.standard
                        }
                    }

                    Column {
                        id: cardCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingS

                        // ---- the collapsed line -------------------------------
                        // ONE line of plain English and an affordance, which is
                        // the whole answer to the wall-of-text problem the
                        // terminal solves by revealing findings in sequence.
                        Item {
                            width: parent.width
                            height: Math.max(24, headline.implicitHeight)

                            DankIcon {
                                id: cardIcon
                                anchors.left: parent.left
                                anchors.top: parent.top
                                name: card.st === "fixed" ? "check_circle"
                                    : card.st === "failed" ? "error"
                                    : card.st === "skipped" ? "remove_circle_outline"
                                    : card.isUserConfig ? "edit_document"
                                    : "build_circle"
                                size: Theme.iconSize - 2
                                // surfaceTextMedium, not surfaceTextLight: the
                                // latter is withAlpha(surfaceText, 0.06) and DMS
                                // only ever uses it as a FILL (a hover row, a
                                // placeholder pip), never as a foreground. It is
                                // what lines 429 and 614 already colour an icon
                                // with here.
                                color: card.st === "fixed" ? Theme.success
                                     : card.st === "failed" ? Theme.error
                                     : card.st === "skipped" ? Theme.surfaceTextMedium
                                     : card.accent
                            }

                            DankIcon {
                                id: chevron
                                anchors.right: parent.right
                                anchors.top: parent.top
                                name: "expand_more"
                                size: Theme.iconSizeSmall
                                color: Theme.surfaceTextMedium
                                rotation: card.isOpen ? 180 : 0

                                Behavior on rotation {
                                    enabled: Theme.currentAnimationSpeed !== SettingsData.AnimationSpeed.None
                                    NumberAnimation { duration: Theme.shortDuration }
                                }
                            }

                            // The state chip. "Fixed" here means --apply-fix
                            // returned 0, which means the script's own remedy
                            // verified the machine changed. It is never "the
                            // button was pressed".
                            StyledRect {
                                id: chip
                                anchors.right: chevron.left
                                anchors.rightMargin: Theme.spacingS
                                anchors.top: parent.top
                                visible: chipText.text.length > 0
                                width: visible ? chipRow.implicitWidth + Theme.spacingS * 2 : 0
                                height: 22
                                radius: height / 2
                                color: Qt.rgba(chipColor.r, chipColor.g, chipColor.b, 0.15)

                                // Drives THREE things: this pill's background
                                // (at 0.15 of it), the spinner, and the label
                                // below. At surfaceTextLight's 0.06 that made the
                                // pill a 0.009-alpha ghost and the word "Skipped"
                                // unreadable -- one token losing three elements.
                                readonly property color chipColor:
                                      card.st === "fixed"   ? Theme.success
                                    : card.st === "failed"  ? Theme.error
                                    : card.st === "skipped" ? Theme.surfaceTextMedium
                                    : card.isUserConfig     ? Theme.warning
                                    : card.modelData.needsPassword ? Theme.warning
                                    : Theme.primary

                                Row {
                                    id: chipRow
                                    anchors.centerIn: parent
                                    spacing: Theme.spacingXS

                                    DankSpinner {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: card.st === "fixing"
                                        size: 12
                                        color: chip.chipColor
                                    }

                                    StyledText {
                                        id: chipText
                                        anchors.verticalCenter: parent.verticalCenter
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        font.weight: Font.Medium
                                        color: chip.chipColor
                                        text: card.st === "fixing"  ? "Applying…"
                                            : card.st === "fixed"   ? "Fixed"
                                            : card.st === "failed"  ? "Not fixed"
                                            : card.st === "skipped" ? "Skipped"
                                            : card.isUserConfig     ? "READ THIS ONE FIRST"
                                            : card.modelData.needsPassword ? "Needs a terminal"
                                            : ""
                                    }
                                }
                            }

                            StyledText {
                                id: headline
                                anchors.left: cardIcon.right
                                anchors.leftMargin: Theme.spacingS
                                anchors.right: chip.visible ? chip.left : chevron.left
                                anchors.rightMargin: Theme.spacingS
                                anchors.top: parent.top
                                wrapMode: Text.WordWrap
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: card.isUserConfig ? Font.DemiBold : Font.Medium
                                color: card.st === "skipped" ? Theme.surfaceTextMedium : Theme.surfaceText
                                text: card.modelData.headline
                            }

                            // The whole line is the affordance, not just the
                            // chevron: a one-line summary you have to hit a 16px
                            // target to open is a one-line summary nobody opens.
                            StateLayer {
                                anchors.fill: parent
                                anchors.margins: -Theme.spacingXS
                                cornerRadius: Theme.cornerRadius
                                onClicked: {
                                    var opening = !card.isOpen
                                    section.expandedId = opening ? card.modelData.id : ""
                                    if (opening)
                                        section.reveal(card)
                                }
                            }
                        }

                        // ---- the opened card ----------------------------------
                        Column {
                            width: parent.width
                            visible: card.isOpen
                            spacing: Theme.spacingS

                            Rectangle {
                                width: parent.width
                                height: 1
                                color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.25)
                            }

                            // Same four headings, in the same order, in the same
                            // words as the terminal walkthrough prints them.
                            HealthBlock {
                                width: parent.width
                                label: "What broke"
                                labelColor: Theme.warning
                                body: card.modelData.broke
                            }

                            HealthBlock {
                                width: parent.width
                                label: "What this fix will do"
                                labelColor: Theme.success
                                body: card.modelData.does
                            }

                            HealthCode {
                                width: parent.width
                                label: "Or do it yourself, by hand"
                                body: card.modelData.manual
                                onCopyRequested: section.copyText(card.modelData.manual)
                            }

                            HealthCode {
                                width: parent.width
                                label: "Or paste this to Claude Code"
                                body: card.modelData.prompt
                                onCopyRequested: section.copyText(card.modelData.prompt)
                            }

                            // ---- what the script said -------------------------
                            // Verbatim. These lines name the backup file, and a
                            // paraphrase of "your copy is saved at ..." is not a
                            // path you can type.
                            StyledRect {
                                width: parent.width
                                visible: card.modelData.uiResult.length > 0
                                height: visible ? resultText.implicitHeight + Theme.spacingS * 2 : 0
                                radius: Theme.cornerRadius
                                color: card.st === "failed"
                                    ? Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.10)
                                    : Qt.rgba(Theme.success.r, Theme.success.g, Theme.success.b, 0.10)

                                StyledText {
                                    id: resultText
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.topMargin: Theme.spacingS
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.rightMargin: Theme.spacingS
                                    wrapMode: Text.WordWrap
                                    isMonospace: true
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: card.st === "failed" ? Theme.error : Theme.surfaceTextMedium
                                    text: card.modelData.uiResult
                                }
                            }

                            // ---- the sudo case ---------------------------------
                            // NOT a disabled button with a tooltip. There is
                            // nowhere on this surface to type a password, so the
                            // honest offer is the command, and the card says why
                            // rather than looking broken.
                            StyledText {
                                width: parent.width
                                visible: card.modelData.needsPassword && !card.actedOn
                                wrapMode: Text.WordWrap
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.warning
                                text: "This repair asks for your password, and there is nowhere to type one here. Copy the command above and run it in a terminal."
                            }

                            // ---- the two answers -------------------------------
                            // One yes/no per finding, exactly as in the terminal.
                            // There is deliberately no "fix everything" button.
                            Row {
                                spacing: Theme.spacingM
                                visible: !card.actedOn && !card.modelData.needsPassword

                                DankButton {
                                    text: card.st === "fixing" ? "Applying…" : "Fix this"
                                    iconName: card.st === "fixing" ? "hourglass_top" : "build"
                                    enabled: section.busyId === "" && card.st !== "fixing"
                                    opacity: enabled ? 1 : 0.6
                                    backgroundColor: card.accent
                                    textColor: card.isUserConfig ? Theme.background : Theme.primaryText
                                    onClicked: section.applyFix(card.modelData.id)
                                }

                                DankButton {
                                    text: "Skip"
                                    iconName: "close"
                                    enabled: section.busyId === ""
                                    opacity: enabled ? 1 : 0.6
                                    onClicked: section.skipFix(card.modelData.id)
                                }
                            }

                            // A failed fix is not the end of the road: the manual
                            // steps above still stand, and the same button is
                            // still allowed to try again.
                            Row {
                                spacing: Theme.spacingM
                                visible: card.st === "failed" || card.st === "skipped"

                                DankButton {
                                    text: card.st === "failed" ? "Try again" : "Fix this after all"
                                    iconName: "refresh"
                                    enabled: section.busyId === "" && !card.modelData.needsPassword
                                    opacity: enabled ? 1 : 0.6
                                    onClicked: section.applyFix(card.modelData.id)
                                }
                            }
                        }
                    }
                }
            }

            // ---- the tally -----------------------------------------------------
            // The terminal's closing line, kept visible rather than printed once.
            StyledText {
                width: parent.width
                visible: section.anyAction
                wrapMode: Text.WordWrap
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                text: {
                    var parts = []
                    if (section.nFixed > 0)
                        parts.push(section.nFixed + " fixed")
                    if (section.nSkipped > 0)
                        parts.push(section.nSkipped + " skipped")
                    if (section.nFailed > 0)
                        parts.push(section.nFailed + " tried and failed")
                    return parts.join(", ") + "."
                }
            }

            // ---- everything else that was checked -------------------------------
            // Visible for transparency and quiet by design: there is nothing to
            // act on in any of it. Collapsed behind one line because ~50 rows
            // would otherwise be the tallest thing in the panel.
            StyledRect {
                id: restCard
                width: parent.width
                visible: section.quietChecks.length > 0
                height: restHeader.height + (restCard.restOpen ? restList.implicitHeight + Theme.spacingS : 0)
                radius: Theme.cornerRadius
                color: Qt.rgba(Theme.surfaceContainerHigh.r, Theme.surfaceContainerHigh.g, Theme.surfaceContainerHigh.b, 0.35)
                clip: true

                property bool restOpen: false

                Behavior on height {
                    enabled: Theme.currentAnimationSpeed !== SettingsData.AnimationSpeed.None
                    NumberAnimation {
                        duration: Theme.shortDuration
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Theme.expressiveCurves.standard
                    }
                }

                Item {
                    id: restHeader
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 40

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Theme.spacingM
                        spacing: Theme.spacingS

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "checklist"
                            size: Theme.iconSizeSmall
                            color: Theme.surfaceTextMedium
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            text: "Everything else that was checked (" + section.quietChecks.length + ")"
                        }
                    }

                    DankIcon {
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        name: "expand_more"
                        size: Theme.iconSizeSmall
                        color: Theme.surfaceTextMedium
                        rotation: restCard.restOpen ? 180 : 0

                        Behavior on rotation {
                            enabled: Theme.currentAnimationSpeed !== SettingsData.AnimationSpeed.None
                            NumberAnimation { duration: Theme.shortDuration }
                        }
                    }

                    StateLayer {
                        anchors.fill: parent
                        cornerRadius: Theme.cornerRadius
                        onClicked: restCard.restOpen = !restCard.restOpen
                    }
                }

                Column {
                    id: restList
                    anchors.top: restHeader.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingM
                    spacing: 2
                    opacity: restCard.restOpen ? 1 : 0

                    Repeater {
                        model: restCard.restOpen ? section.quietChecks : []

                        Row {
                            required property var modelData
                            width: restList.width
                            spacing: Theme.spacingS

                            // Full-opacity Theme.surfaceText for every word in
                            // here -- NOT surfaceTextLight (withAlpha 0.06, a
                            // hairline tint that made this list invisible) and
                            // NOT surfaceTextMedium (0.7), which over this
                            // panel's blur still did not read. The whole point
                            // of the list is that it can be read once opened;
                            // its deprioritisation comes from being collapsed by
                            // default and set one size down, never from the
                            // colour. Only the tag column keeps a non-text
                            // colour, and only where that colour is semantic.
                            StyledText {
                                width: 44
                                font.pixelSize: Theme.fontSizeSmall
                                isMonospace: true
                                color: modelData.tag === "FAIL" ? Theme.error
                                     : modelData.tag === "WARN" ? Theme.warning
                                     : modelData.tag === "PASS" ? Theme.success
                                     : Theme.surfaceText
                                text: modelData.tag === "NOTE" ? "--" : modelData.tag
                            }

                            Column {
                                width: restList.width - 44 - Theme.spacingS
                                spacing: 0

                                StyledText {
                                    width: parent.width
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceText
                                    text: modelData.message
                                }

                                // Only where there is something to do about it. A
                                // WARN and a FAIL carry their advice in `detail`;
                                // a PASS has nothing to add and a note's whole
                                // point is that it is fine as it is.
                                StyledText {
                                    width: parent.width
                                    visible: (modelData.tag === "WARN" || modelData.tag === "FAIL")
                                             && modelData.detail.length > 0
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.surfaceText
                                    text: modelData.detail
                                }
                            }
                        }
                    }
                }
            }

            // ---- the footer: where the rest of the answer lives -----------------
            StyledText {
                width: parent.width
                visible: section.scanned && section.scanError.length === 0
                wrapMode: Text.WordWrap
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                text: "Everything here comes from post-update-health.sh. Run it in a terminal for the full report, including the findings this panel can't repair."
            }
        }
    }
}
