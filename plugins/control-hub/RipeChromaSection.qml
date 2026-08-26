// =============================================================================
//  RipeChromaSection.qml  --  the hub's "Ripe Chroma" section
// =============================================================================
//
//  >>> IF THIS SECTION SAYS "NOT INSTALLED" AND YOU THINK IT SHOULD NOT <<<
//  This file holds NO colour logic. Everything comes from one binary:
//
//        ~/.local/bin/dankmango-ripe-chroma
//
//  That path is FIXED, not discovered. It is written by install.sh's opt-in
//  stage 13b (which builds tools/ripe-chroma/), and its EXISTENCE IS THE
//  OPT-IN RECORD -- there is no separate flag anywhere, by design. So:
//
//        no binary  ==  the user declined the engine at install time
//                       (or installed DankMango before it existed)
//
//  which is a perfectly healthy machine, not a fault. Hence the "not installed"
//  card below rather than an error, and hence this section staying VISIBLE in
//  the nav list instead of disappearing: a section that vanishes teaches nobody
//  that the feature exists, and "why is it missing?" is a worse question than
//  "how do I turn it on?". Same call PresetsSection makes for "no presets".
//
//  The path is duplicated in three other places (the wallpaper fan-out, the
//  health check, lib/common.sh). If it ever moves, grep the basename repo-wide.
//
// -----------------------------------------------------------------------------
//  THE THREE-WAY BOUNDARY: PREVIEW vs GENERATE vs USE
// -----------------------------------------------------------------------------
//  This is the single most important thing about this file. There are three
//  levels of commitment and they are deliberately NOT collapsed:
//
//    PREVIEW   runs the engine with `--output -` (stdout). Writes NO file,
//              touches NO setting. Happens automatically as you scrub the
//              slider or pick a mode. CANNOT change your desktop, by
//              construction -- there is nothing for it to change.
//
//    GENERATE  runs the engine with `--output <theme file>`. Writes ONE file.
//              Still does not touch DMS's settings, so it still cannot change
//              how your desktop looks -- unless that file is ALREADY the active
//              custom theme, in which case DMS's own FileView picks it up.
//
//    USE       points DMS's Custom theme at that file. This is the only step
//              that repaints the desktop, and it is only ever a button press.
//
//  Live preview was deliberately confined to the panel. Repainting the whole
//  desktop on every intermediate slider value would mean rapid theme swaps
//  through Quickshell's theme loader, which is a crash risk and not something
//  anyone asked for. Scrubbing explores; the buttons commit.
//
// -----------------------------------------------------------------------------
//  WHY PREVIEW IS CHEAP ENOUGH TO DO ON EVERY CHANGE  (measured 2026-08-24)
// -----------------------------------------------------------------------------
//  On a 3786x2122 wallpaper, on this machine:
//
//        generation only (--seed)            1 ms
//        full extraction, --count 3          74 ms
//        full extraction, --count 8          82 ms
//        all three modes IN PARALLEL         78 ms
//        all three modes sequentially       226 ms
//
//  Two facts fall out of that, and the whole preview design rests on them:
//
//    1. COUNT is the expensive axis and MODE is free. Cost barely moves with
//       --count (74 -> 82 ms) because it is dominated by decoding the image,
//       not by the k-means itself. Changing MODE costs the same as any other
//       run -- generation is 1 ms, so a mode change is paying ~75 ms of image
//       decode to redo work it already did.
//
//    2. Three modes in parallel cost the same wall time as one (78 ms vs 75 ms)
//       -- three processes, three cores, one image decode each.
//
//  So the preview does not run ONE mode, it runs ALL THREE at once and caches
//  the results. A count change pays 78 ms (once, after a debounce); every mode
//  click after that is a dictionary lookup and costs NOTHING. That is why there
//  is no debounce on the mode buttons: there is no work to debounce.
//
//  This also beats the obvious alternative of caching the extracted CLUSTERS and
//  re-running only generation, which would need new engine API surface (some way
//  to hand clusters back in) to save 1 ms of the 75. Caching the three finished
//  palettes needs no engine change at all.
//
//  SAFE TO CACHE BECAUSE THE ENGINE IS DETERMINISTIC. extract.rs seeds k-means
//  from a fixed constant (SEED = 0x44616e6b4d616e67) precisely so the same
//  wallpaper always gives the same palette. Verified: three identical runs are
//  byte-identical. If that seed is ever made random, this cache becomes a lie
//  and the three modes stop sharing a cluster basis -- re-check it before
//  touching extract.rs.
//
// -----------------------------------------------------------------------------
//  WHAT A SECTION IS: see PresetsSection.qml's header. Same two obligations --
//  a real implicitHeight, and `property var hub: null` for the panel to fill in.
// =============================================================================

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: section

    property var hub: null

    implicitHeight: content.implicitHeight

    // #########################################################################
    // ########## EDIT HERE IF THE ENGINE MOVES OR ITS CLI CHANGES #############
    // #########################################################################

    // The binary. Quoted and resolved through `sh -c` because execDetached runs
    // no shell of its own and would pass a bare "~" through literally.
    readonly property string engineBin: "\"$HOME/.local/bin/dankmango-ripe-chroma\""

    // The palette file the engine writes when no --output is given: DMS's
    // configured customThemeFile if it has one, else this default. Kept in sync
    // with src/output.rs's DEFAULT_OUTPUT.
    readonly property string defaultOutFile: Quickshell.env("HOME") + "/.config/DankMaterialShell/dankmango-theme.json"

    // #########################################################################

    // -- gate state ---------------------------------------------------------
    // tri-state on purpose: "checking" is not "missing". Rendering the
    // not-installed card during the few ms before the first probe returns would
    // flash a scary message at everyone who opens this section.
    property bool probed: false
    property bool engineInstalled: false

    Process {
        id: probeProc
        command: ["sh", "-c", "test -x " + section.engineBin + " && echo yes || echo no"]
        running: false
        stdout: StdioCollector {
            id: probeOut
            onStreamFinished: {
                section.engineInstalled = probeOut.text.trim() === "yes"
                section.probed = true
                if (section.engineInstalled)
                    section.refreshPreview()
            }
        }
    }

    function probe() {
        probeProc.running = false
        probeProc.running = true
    }

    // -- tuning state -------------------------------------------------------
    // Persisted through PluginService (the same store the preset switcher uses),
    // NOT in a file of our own: the panel is closed and re-opened constantly and
    // re-picking Vibrant/7-colours every time would make the section useless.
    // Keyed under the hub's own plugin id, since this section is part of it.
    readonly property var modeIds: ["accurate", "vibrant", "muted"]
    readonly property var modeLabels: ["Accurate", "Vibrant", "Muted"]
    readonly property var modeBlurbs: [
        "Keeps your wallpaper's true hue, giving up a little brightness to do it.",
        "Pushes the colour as far as the screen can show it.",
        "The softer, paler look, closest to the stock palette."
    ]
    property int modeIndex: 0
    property int colorCount: 5
    property bool useSeed: false
    property string seedHex: "#bf253c"

    function loadPrefs() {
        var d = PluginService.loadPluginData("controlHub", "colorEngine", null)
        if (!d)
            return
        var mi = section.modeIds.indexOf(d.mode || "accurate")
        section.modeIndex = mi >= 0 ? mi : 0
        section.colorCount = (d.count >= 3 && d.count <= 8) ? d.count : 5
        section.useSeed = d.useSeed === true
        if (d.seed)
            section.seedHex = d.seed
    }

    function savePrefs() {
        PluginService.savePluginData("controlHub", "colorEngine", {
            "mode": section.modeIds[section.modeIndex],
            "count": section.colorCount,
            "useSeed": section.useSeed,
            "seed": section.seedHex,
            "generatedAt": Date.now()
        })
    }

    // WRITES ARE DEBOUNCED, and only for the paths that need it. savePrefs()
    // itself stays immediate -- mode buttons, the seed field and the generate
    // run each fire it once and want it on disk now.
    //
    // The colour-count slider is the exception. It has to persist from
    // onSliderValueChanged rather than from onSliderDragFinished alone, because
    // DankSlider only emits sliderDragFinished from its MouseArea's onReleased:
    // the scroll-wheel path (onWheel) changes the value and emits
    // sliderValueChanged with NO drag-finished at all, so a wheel adjustment was
    // silently lost. Wiring valueChanged fixes that, but a single drag across the
    // track emits a change per step, and rewriting the whole plugin_settings.json
    // five or six times for values the user is merely passing through is pointless
    // disk churn. So: coalesce, and write once the value has settled.
    Timer {
        id: savePrefsDebounce
        interval: 400
        repeat: false
        onTriggered: section.savePrefs()
    }

    // =========================================================================
    //  LIVE PREVIEW
    // =========================================================================
    //  Runs the engine with `--output -` and keeps the result in memory. See the
    //  header for the boundary this sits behind and the measurements behind the
    //  all-three-modes-at-once design.

    // The three finished palettes for the CURRENT input, keyed by mode id, or
    // null when nothing has been computed yet. This is the whole cache -- there
    // is no key, because it only ever holds the current input's results and is
    // refilled whenever that input changes.
    property var previewCache: null
    property bool previewBusy: false
    property string previewError: ""

    // -- the dark/light dimension -------------------------------------------
    // The engine now emits DMS's {"dark":{..},"light":{..}} document, so every
    // cache entry is a PAIR, not a palette.
    //
    // THE CACHING STRATEGY DID NOT NEED CHANGING -- it got cheaper per palette.
    // One run still produces one JSON envelope covering all three modes, and each
    // of those now carries both schemes: six palettes for the same ~78 ms, because
    // building the light branch is pure generation (~1 ms) on clusters that were
    // already extracted. Switching mode is still a dictionary lookup, and so is
    // switching light/dark -- neither spawns a process.
    //
    // Which branch is SHOWN follows DMS's own light-mode state rather than being a
    // control of its own. The preview's job is to answer "what will my desktop
    // look like", and the answer depends on the mode the desktop is actually in.
    readonly property string previewScheme:
        (typeof SessionData !== "undefined" && SessionData.isLightMode) ? "light" : "dark"

    // One branch out of a wrapped document, tolerating a FLAT one.
    // A palette generated before the engine learned light mode has no wrapper,
    // and DMS itself falls back the same way (Theme.qml: themeData[colorMode] ||
    // themeData.dark || themeData.light), so this panel must not render such a
    // file as "broken" either.
    function branchOf(doc) {
        if (!doc)
            return null
        if (doc.dark || doc.light)
            return doc[section.previewScheme] || doc.dark || doc.light || null
        return doc
    }

    // The whole wrapped document currently being previewed, or null.
    readonly property var previewDoc: {
        if (section.previewCache) {
            var d = section.previewCache[section.modeIds[section.modeIndex]]
            if (d)
                return d
        }
        return null
    }

    // What the swatches actually show. Falls back to the palette ON DISK when
    // there is no preview yet, so the card is never empty on first open and so a
    // palette written by the WALLPAPER FAN-OUT (not by this panel) still shows.
    readonly property var previewPalette:
        section.branchOf(section.previewDoc) || section.branchOf(section.paletteDoc)

    // Whether what you are looking at is already the file's contents. Compared
    // by value rather than tracked with a flag: both sides come from the same
    // engine and the same serialiser, so an exact string match is the honest
    // test of "pressing Generate right now would change nothing".
    //
    // COMPARES THE WHOLE DOCUMENT, both branches, not just the visible one.
    // Generate writes dark AND light, so a file whose light branch is stale is a
    // file Generate would still change -- comparing only the shown branch would
    // grey the button out and leave the other half wrong with nothing to say so.
    readonly property bool previewMatchesFile: {
        if (!section.previewDoc || !section.paletteDoc)
            return false
        return JSON.stringify(section.previewDoc) === JSON.stringify(section.paletteDoc)
    }

    // The seed is forwarded as an ARGUMENT ($1 -> seed), never spliced into the
    // command string -- same rule the presets section applies to preset names.
    //
    // Runs the three modes in parallel into a scratch dir and prints ONE JSON
    // envelope, so QML parses a single stdout rather than juggling three
    // Processes. `j` emits null for a mode that failed, keeping the envelope
    // valid JSON so one bad mode cannot take the whole preview down.
    function buildPreviewCmd() {
        var s = "seed=\"$1\"; d=$(mktemp -d) || exit 1; trap 'rm -rf \"$d\"' EXIT; "
        var input
        if (section.useSeed) {
            input = "--seed \"$seed\""
        } else {
            s += "wp=\"$(jq -r '.wallpaperPath // empty' \"$HOME/.local/state/DankMaterialShell/session.json\")\"; "
            s += "[ -n \"$wp\" ] || { echo 'no wallpaper set' >&2; exit 1; }; "
            input = "--wallpaper \"$wp\" --count " + section.colorCount
        }
        s += "for m in accurate vibrant muted; do "
        s += section.engineBin + " " + input + " --mode \"$m\" --output - > \"$d/$m\" 2>/dev/null & "
        s += "done; wait; "
        s += "j() { if [ -s \"$d/$1\" ]; then cat \"$d/$1\"; else printf null; fi; }; "
        s += "printf '{\"accurate\":%s,\"vibrant\":%s,\"muted\":%s}' \"$(j accurate)\" \"$(j vibrant)\" \"$(j muted)\""
        return s
    }

    Process {
        id: previewProc
        running: false
        stdout: StdioCollector { id: previewOut }
        stderr: StdioCollector { id: previewErr }
        onExited: function (exitCode) {
            section.previewBusy = false
            if (exitCode !== 0) {
                var e = previewErr.text ? previewErr.text.trim() : ""
                section.previewError = e.length > 0 ? e : "Preview failed (exit " + exitCode + ")."
                return
            }
            try {
                var parsed = JSON.parse(previewOut.text)
                // A mode that failed comes back as null; keep whatever we had
                // for it rather than blanking that button's swatch.
                if (parsed && parsed.accurate && parsed.vibrant && parsed.muted) {
                    section.previewCache = parsed
                    section.previewError = ""
                } else {
                    section.previewError = "The engine returned an incomplete palette."
                }
            } catch (err) {
                section.previewError = "Could not read the engine's output."
            }
        }
    }

    function refreshPreview() {
        if (!section.engineInstalled)
            return
        previewDebounce.stop()
        section.previewBusy = true
        section.previewError = ""
        previewProc.running = false
        previewProc.command = ["sh", "-c", section.buildPreviewCmd(), "sh", section.seedHex]
        previewProc.running = true
    }

    // 250 ms, and only on the count/seed paths. Long enough that a drag across
    // the whole track fires ONE 78 ms run instead of six, short enough that
    // letting go feels immediate. Mode changes never come through here -- they
    // are served from the cache with no process at all.
    Timer {
        id: previewDebounce
        interval: 250
        repeat: false
        onTriggered: section.refreshPreview()
    }

    // The cache belongs to one input. Anything that changes the input invalidates
    // it -- but the STALE PALETTE IS LEFT ON SCREEN until the new one lands
    // rather than blanked, because a card that empties for 330 ms on every slider
    // step flickers badly. previewBusy is what tells the user it is catching up.
    function schedulePreview() {
        if (!section.engineInstalled)
            return
        section.previewBusy = true
        previewDebounce.restart()
    }

    onColorCountChanged: section.schedulePreview()
    onUseSeedChanged: section.schedulePreview()
    onSeedHexChanged: if (section.useSeed) section.schedulePreview()
    // Mode is free -- served from the cache. Only recompute if there is no cache
    // to serve from (first open, or the last run failed).
    onModeIndexChanged: if (!section.previewCache) section.schedulePreview()

    // -- generating ---------------------------------------------------------
    // A TRACKED Process, not execDetached, unlike the presets section. That one
    // fires a script whose effect you can see on screen a moment later; this one
    // writes a file you cannot see, so "did it work?" has to come from the exit
    // code. The run is a tenth of a second, so there is nothing to detach from.
    //
    // --output is passed EXPLICITLY even though the engine would resolve its own
    // default. If the user already points DMS at some other custom theme file,
    // the engine's own resolution would overwrite THAT file -- generating a
    // preview from this panel must never clobber a theme somebody else made.
    property bool generating: false
    property string resultText: ""
    property bool resultOk: false

    // The wallpaper path is read from DMS's own session state at RUN time, inside
    // the shell command, rather than being captured when the panel opened -- the
    // wallpaper may well have changed since, and this way there is one source of
    // truth for "the current wallpaper" shared with the fan-out script.
    readonly property string wallpaperExpr:
        "\"$(jq -r '.wallpaperPath // empty' \"$HOME/.local/state/DankMaterialShell/session.json\")\""

    function buildArgs() {
        var a = section.engineBin
        if (section.useSeed) {
            a += " --seed \"$1\""
        } else {
            a += " --wallpaper " + section.wallpaperExpr
            a += " --count " + section.colorCount
        }
        a += " --mode " + section.modeIds[section.modeIndex]
        a += " --output \"$HOME/.config/DankMaterialShell/dankmango-theme.json\""
        return a
    }

    Process {
        id: genProc
        running: false
        stdout: StdioCollector { id: genOut }
        stderr: StdioCollector { id: genErr }
        onExited: function (exitCode) {
            section.generating = false
            section.resultOk = exitCode === 0
            if (exitCode === 0) {
                // NO SUCCESS LINE, deliberately removed. The preview card above
                // already shows exactly what was written and its pill flips from
                // "Preview only" to "Saved" the moment the file lands, so a line
                // of prose restating it was pure duplication. The failure branch
                // below is KEPT -- an error still has nowhere else to appear.
                section.savePrefs()
                paletteFile.reload()
            } else {
                var msg = genErr.text ? genErr.text.trim() : ""
                section.resultText = msg.length > 0 ? msg : "Ripe Chroma failed (exit " + exitCode + ")."
            }
        }
    }

    function generate() {
        if (section.generating)
            return
        section.generating = true
        section.resultText = ""
        // The seed is forwarded as an ARGUMENT ($1), never spliced into the
        // command string -- same rule as the presets section applies to preset
        // names, for the same reason.
        genProc.command = ["sh", "-c", section.buildArgs(), "sh", section.seedHex]
        genProc.running = true
    }

    // -- the generated palette ----------------------------------------------
    // Read back from the file itself so the swatches are the real thing rather
    // than a guess, and so a palette generated by the WALLPAPER FAN-OUT (not by
    // this panel) still shows up here.
    // paletteDoc is the WHOLE document as written ({"dark":..,"light":..});
    // palette is just the branch being shown. Both are needed: the branch drives
    // the swatches, the document is what Generate would overwrite.
    property var paletteDoc: null
    readonly property var palette: section.branchOf(section.paletteDoc)

    FileView {
        id: paletteFile
        path: section.defaultOutFile
        blockLoading: false
        watchChanges: true
        onLoaded: {
            try {
                section.paletteDoc = JSON.parse(paletteFile.text())
            } catch (e) {
                section.paletteDoc = null
            }
        }
        onLoadFailed: section.paletteDoc = null
        onFileChanged: paletteFile.reload()
    }

    // -- activation ----------------------------------------------------------
    // Exactly what DMS's own Settings > Theme does when you pick a custom theme
    // file (ThemeColorsTab.qml): point the setting at the file, then switch the
    // theme to "custom". Nothing here writes settings.json by hand.
    readonly property bool isActive: {
        if (typeof SettingsData === "undefined" || typeof Theme === "undefined")
            return false
        return Theme.currentTheme === "custom"
            && SettingsData.customThemeFile === section.defaultOutFile
    }

    // BOTH calls are load-bearing, in this order. Setting customThemeFile only
    // records the path -- nothing in DMS watches that setting, so on its own it
    // changes the label and not the colours. switchTheme("custom") is what
    // reaches loadCustomThemeFromFile() and actually parses the palette, and it
    // reads the path back out of SettingsData, so the set has to come first.
    // Dropping either one leaves the button looking like it worked.
    function activate() {
        SettingsData.set("customThemeFile", section.defaultOutFile)
        Theme.switchTheme("custom")
    }

    // Pull one role out of whatever is being previewed, with a fallback for the
    // moment before the first preview lands.
    function role(name, fallback) {
        var p = section.previewPalette
        if (p && p[name])
            return p[name]
        return fallback
    }

    // The accent a given MODE would produce, straight from the cache -- this is
    // what lets each mode button wear its own result. Falls back to a neutral so
    // the buttons never flash black before the first run returns.
    // GOES THROUGH branchOf. Cache entries are wrapped documents now, so reading
    // .primary straight off one returns undefined and every dot silently falls
    // back to the neutral -- which is exactly what happened when the wrapper
    // landed: three hollow circles and no way to tell the modes apart.
    function modeAccent(i) {
        if (section.previewCache) {
            var p = section.branchOf(section.previewCache[section.modeIds[i]])
            if (p && p.primary)
                return p.primary
        }
        return Theme.surfaceVariant
    }

    Component.onCompleted: {
        section.loadPrefs()
        section.probe()
    }

    Column {
        id: content
        width: parent.width
        spacing: Theme.spacingM

        // ---- not installed ------------------------------------------------
        // Same shape as PresetsSection's empty state, but deliberately NOT an
        // error colour: nothing is broken, this is an extra that was declined.
        StyledRect {
            width: parent.width
            visible: section.probed && !section.engineInstalled
            height: visible ? missingRow.implicitHeight + Theme.spacingM * 2 : 0
            radius: Theme.cornerRadius
            color: Qt.rgba(Theme.surfaceContainerHigh.r, Theme.surfaceContainerHigh.g, Theme.surfaceContainerHigh.b, 0.5)
            border.width: 1
            border.color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.4)

            Row {
                id: missingRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "download_for_offline"
                    size: Theme.iconSize - 2
                    color: Theme.surfaceTextMedium
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Theme.iconSize - Theme.spacingM * 2
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                    text: "Not installed — this one is opt-in. Re-run install.sh from your DankMango folder and say yes at \"Build Ripe Chroma, the wallpaper colour engine?\". Nothing else here changes if you skip it."
                }
            }
        }

        // ---- installed: the controls -------------------------------------
        Column {
            width: parent.width
            spacing: Theme.spacingM
            visible: section.probed && section.engineInstalled

            // =================================================================
            //  THE PREVIEW  --  this section's headline, where the explanatory
            //  paragraph used to be.
            // =================================================================
            //  It is not a swatch strip. It is a small MOCK DESKTOP painted
            //  entirely in the palette being previewed: its own background, its
            //  own bar, its own window, its own text and buttons. A row of
            //  isolated squares tells you the palette contains a pink; this
            //  tells you what a pink surface with pink-tinted text on it will
            //  actually look like, which is the question you are really asking
            //  while you scrub.
            //
            //  Every colour below therefore comes from role(), NOT from Theme.
            //  Using Theme here would paint the preview in the CURRENT desktop
            //  palette and quietly defeat the entire point.
            StyledRect {
                width: parent.width
                height: previewInner.implicitHeight + Theme.spacingM * 2
                radius: Theme.cornerRadius * 1.5
                color: section.role("background", Theme.surfaceContainerHigh)
                border.width: 1
                border.color: section.role("outline", Theme.outline)

                // Settles the colour change instead of snapping, so scrubbing the
                // slider reads as one continuous thing rather than a strobe.
                Behavior on color {
                    ColorAnimation { duration: 180; easing.type: Easing.OutCubic }
                }

                Column {
                    id: previewInner
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingM
                    spacing: Theme.spacingS

                    // -- the fake bar -----------------------------------------
                    Rectangle {
                        width: parent.width
                        height: 24
                        radius: Theme.cornerRadius * 0.75
                        color: section.role("surfaceContainer", Theme.surfaceContainer)
                        Behavior on color { ColorAnimation { duration: 180 } }

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingXS

                            Repeater {
                                model: ["primary", "secondary", "tertiary"]
                                Rectangle {
                                    width: 8; height: 8; radius: 4
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: section.role(modelData, Theme.surfaceVariant)
                                    Behavior on color { ColorAnimation { duration: 180 } }
                                }
                            }
                        }

                        // Stand-in for bar text, so the preview shows contrast
                        // rather than only hue.
                        Rectangle {
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            width: 46; height: 6; radius: 3
                            color: section.role("surfaceVariantText", Theme.surfaceTextMedium)
                            opacity: 0.7
                            Behavior on color { ColorAnimation { duration: 180 } }
                        }
                    }

                    // -- the fake window --------------------------------------
                    Rectangle {
                        width: parent.width
                        height: fakeWin.implicitHeight + Theme.spacingS * 2
                        radius: Theme.cornerRadius
                        color: section.role("surface", Theme.surface)
                        border.width: 1
                        border.color: section.role("outline", Theme.outline)
                        Behavior on color { ColorAnimation { duration: 180 } }

                        Column {
                            id: fakeWin
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Theme.spacingS
                            anchors.rightMargin: Theme.spacingS
                            spacing: Theme.spacingXS

                            StyledText {
                                text: "The quick brown fox"
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: section.role("surfaceText", Theme.surfaceText)
                                Behavior on color { ColorAnimation { duration: 180 } }
                            }

                            StyledText {
                                text: "Body text on a surface, at rest."
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: section.role("surfaceVariantText", Theme.surfaceTextMedium)
                                Behavior on color { ColorAnimation { duration: 180 } }
                            }

                            Row {
                                spacing: Theme.spacingXS
                                topPadding: Theme.spacingXXS

                                // A filled button in `primary` -- the single most
                                // load-bearing colour in the palette, shown doing
                                // the job it will actually do.
                                Rectangle {
                                    width: 62; height: 18
                                    radius: Theme.cornerRadius * 0.75
                                    color: section.role("primary", Theme.primary)
                                    Behavior on color { ColorAnimation { duration: 180 } }
                                    StyledText {
                                        anchors.centerIn: parent
                                        text: "Primary"
                                        font.pixelSize: Theme.fontSizeSmall - 2
                                        color: section.role("primaryText", Theme.primaryText)
                                    }
                                }

                                Rectangle {
                                    width: 62; height: 18
                                    radius: Theme.cornerRadius * 0.75
                                    color: "transparent"
                                    border.width: 1
                                    border.color: section.role("outline", Theme.outline)
                                    StyledText {
                                        anchors.centerIn: parent
                                        text: "Outline"
                                        font.pixelSize: Theme.fontSizeSmall - 2
                                        color: section.role("surfaceText", Theme.surfaceText)
                                    }
                                }

                                // The semantic four, at a glance. These are the
                                // roles nothing else in the panel ever shows.
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    leftPadding: Theme.spacingXS
                                    spacing: Theme.spacingXXS
                                    Repeater {
                                        model: ["error", "warning", "success", "info"]
                                        Rectangle {
                                            width: 10; height: 10; radius: 5
                                            color: section.role(modelData, Theme.surfaceVariant)
                                            Behavior on color { ColorAnimation { duration: 180 } }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // -- caption: what you are looking at, and how committed ---
                    Item {
                        width: parent.width
                        height: Math.max(captionText.implicitHeight, statusPill.height)

                        StyledText {
                            id: captionText
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - statusPill.width - Theme.spacingS
                            elide: Text.ElideRight
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: section.role("surfaceVariantText", Theme.surfaceTextMedium)
                            text: section.useSeed
                                ? section.seedHex + " · " + section.modeLabels[section.modeIndex]
                                : "Wallpaper · " + section.colorCount + " colours · " + section.modeLabels[section.modeIndex]
                        }

                        // The commitment indicator. This is the boundary from the
                        // file header made visible: preview-only, on disk, or
                        // actually painting your desktop.
                        Rectangle {
                            id: statusPill
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            height: 18
                            width: statusLabel.implicitWidth + Theme.spacingS * 2
                            radius: 9
                            color: section.previewBusy
                                ? "transparent"
                                : (section.previewMatchesFile && section.isActive
                                    ? section.role("primary", Theme.primary)
                                    : "transparent")
                            border.width: 1
                            border.color: section.previewBusy || !(section.previewMatchesFile && section.isActive)
                                ? section.role("outline", Theme.outline)
                                : "transparent"
                            Behavior on color { ColorAnimation { duration: 180 } }

                            StyledText {
                                id: statusLabel
                                anchors.centerIn: parent
                                font.pixelSize: Theme.fontSizeSmall - 2
                                color: (section.previewMatchesFile && section.isActive && !section.previewBusy)
                                    ? section.role("primaryText", Theme.primaryText)
                                    : section.role("surfaceVariantText", Theme.surfaceTextMedium)
                                text: section.previewBusy
                                    ? "Updating…"
                                    : (!section.palette
                                        ? "Not generated"
                                        : (!section.previewMatchesFile
                                            ? "Preview only"
                                            : (section.isActive ? "In use" : "Saved")))
                            }
                        }
                    }
                }
            }

            // Preview trouble. Deliberately quiet and separate from the generate
            // result line below -- a failed preview costs the user nothing and
            // must not look like a failed generate.
            StyledText {
                width: parent.width
                visible: section.previewError.length > 0
                wrapMode: Text.WordWrap
                color: Theme.surfaceTextMedium
                font.pixelSize: Theme.fontSizeSmall - 1
                text: "Preview unavailable — " + section.previewError
            }

            // ---- 1. where the colours come from ------------------------
            StyledText {
                text: "Colours from"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
            }

            DankButtonGroup {
                model: ["Wallpaper", "Static"]
                currentIndex: section.useSeed ? 1 : 0
                selectionMode: "single"
                onSelectionChanged: (index, selected) => {
                    if (!selected)
                        return
                    section.useSeed = index === 1
                    section.savePrefs()
                }
            }

            // The static colour, as a swatch you can click rather than a hex
            // field you have to know the syntax of.
            //
            // NATIVE PICKER, NOT OURS. DMS ships a full HSV picker with a hex
            // field, a standard-colour grid and a recents list, and exposes it to
            // plugins as PopoutService.colorPickerModal -- Modules/Plugins/
            // ColorSetting.qml drives it exactly this way (set selectedColor, set
            // pickerTitle, set onColorSelectedCallback, call show()). Building a
            // picker here would be a worse copy of a component the shell already
            // has, and would not share the user's recent colours.
            //
            // The hex field is KEPT alongside it. The picker is for choosing a
            // colour by eye; the field is for pasting one you already have, which
            // is the more common case when someone is matching a brand or a
            // wallpaper they sampled elsewhere.
            Row {
                // EXPLICIT width, and it matters. Without it a Row sizes itself
                // from its children, so a child reading parent.width (the text
                // field below does) is a binding loop -- QML breaks the loop by
                // dropping the width to 0 and the whole row renders as nothing.
                // Taking the Column's width instead makes parent.width a known
                // quantity before the children are measured.
                width: parent.width
                height: visible ? seedSwatch.height : 0
                visible: section.useSeed
                spacing: Theme.spacingS

                Rectangle {
                    id: seedSwatch
                    width: 40
                    height: 36
                    radius: Theme.cornerRadius
                    anchors.verticalCenter: parent.verticalCenter
                    color: /^#[0-9a-fA-F]{6}$/.test(section.seedHex) ? section.seedHex : "transparent"
                    border.width: 2
                    border.color: Theme.outlineStrong

                    DankIcon {
                        anchors.centerIn: parent
                        name: "colorize"
                        size: Theme.iconSizeSmall
                        // Punched through the swatch, so it stays legible on both
                        // a very dark and a very light chosen colour.
                        color: seedSwatch.color.hslLightness > 0.5 ? "#000000" : "#ffffff"
                        opacity: seedMouse.containsMouse ? 1 : 0.65
                    }

                    MouseArea {
                        id: seedMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof PopoutService === "undefined" || !PopoutService.colorPickerModal)
                                return
                            PopoutService.colorPickerModal.selectedColor = section.seedHex
                            PopoutService.colorPickerModal.pickerTitle = "Ripe Chroma seed"
                            PopoutService.colorPickerModal.onColorSelectedCallback = function (picked) {
                                // The modal hands back a QML color; the engine
                                // takes #rrggbb, and toString() on an opaque
                                // colour gives exactly that.
                                section.seedHex = picked.toString().substring(0, 7)
                                section.savePrefs()
                            }
                            PopoutService.colorPickerModal.show()
                        }
                    }
                }

                DankTextField {
                    width: Math.min(160, parent.width - 40 - Theme.spacingS)
                    anchors.verticalCenter: parent.verticalCenter
                    text: section.seedHex
                    placeholderText: "#rrggbb"
                    maximumLength: 7
                    onTextChanged: {
                        var t = text.trim()
                        if (t.length > 0 && t.charAt(0) !== "#")
                            t = "#" + t
                        section.seedHex = t
                    }
                }
            }

            // ---- 2. how many colours -----------------------------------
            // Hidden for the seed path rather than disabled: with --seed there
            // is no image to cluster, so the engine ignores --count entirely.
            // A greyed-out slider would imply it still means something.
            StyledText {
                visible: !section.useSeed
                text: "Colours to extract"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
            }

            DankSlider {
                width: parent.width
                visible: !section.useSeed
                minimum: 3
                maximum: 8
                value: section.colorCount
                step: 1
                unit: ""
                leftIcon: "palette"
                alwaysShowValue: true
                onSliderValueChanged: newValue => {
                    section.colorCount = newValue
                    savePrefsDebounce.restart()
                }
                // Kept as well as the debounce, not replaced by it: releasing the
                // mouse is an unambiguous "I'm done", so persist immediately and
                // drop the pending timer rather than making the user wait it out.
                onSliderDragFinished: {
                    savePrefsDebounce.stop()
                    section.savePrefs()
                }
            }

            // ---- 3. mode -----------------------------------------------
            StyledText {
                text: "Mode"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
            }

            // NOT a DankButtonGroup, and this is the one place worth the custom
            // widget: each button WEARS THE COLOUR THAT MODE WOULD GIVE YOU.
            // The three-mode cache means all three accents are already in hand,
            // so the choice can be made by looking rather than by clicking
            // through all three and remembering. A generic segmented control
            // cannot show that.
            Row {
                width: parent.width
                spacing: Theme.spacingS

                Repeater {
                    model: 3

                    Rectangle {
                        id: modeCard
                        readonly property bool selected: section.modeIndex === index
                        width: (parent.width - Theme.spacingS * 2) / 3
                        height: 56
                        radius: Theme.cornerRadius
                        color: selected
                            ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.12)
                            : Qt.rgba(Theme.surfaceContainerHigh.r, Theme.surfaceContainerHigh.g, Theme.surfaceContainerHigh.b, 0.5)
                        border.width: selected ? 2 : 1
                        border.color: selected
                            ? Theme.primary
                            : Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.4)

                        Behavior on border.color { ColorAnimation { duration: 150 } }
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Column {
                            anchors.centerIn: parent
                            spacing: Theme.spacingXS

                            // The mode's own accent, live from the cache.
                            Rectangle {
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: 22; height: 22; radius: 11
                                color: section.modeAccent(index)
                                border.width: 1
                                border.color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.5)
                                Behavior on color { ColorAnimation { duration: 220; easing.type: Easing.OutCubic } }

                                // Faint pulse while the three modes are being
                                // recomputed, so a stale dot does not read as a
                                // finished answer.
                                SequentialAnimation on opacity {
                                    running: section.previewBusy
                                    loops: Animation.Infinite
                                    alwaysRunToEnd: true
                                    NumberAnimation { to: 0.45; duration: 400; easing.type: Easing.InOutQuad }
                                    NumberAnimation { to: 1.0;  duration: 400; easing.type: Easing.InOutQuad }
                                }
                            }

                            StyledText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: section.modeLabels[index]
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: modeCard.selected ? Font.Medium : Font.Normal
                                color: modeCard.selected ? Theme.surfaceText : Theme.surfaceTextMedium
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                section.modeIndex = index
                                section.savePrefs()
                            }
                        }
                    }
                }
            }

            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                color: Theme.surfaceTextMedium
                font.pixelSize: Theme.fontSizeSmall
                text: section.modeBlurbs[section.modeIndex]
            }

            // ---- 4. the two actions ------------------------------------
            Row {
                spacing: Theme.spacingM

                DankButton {
                    text: section.generating ? "Generating…" : "Generate"
                    iconName: section.generating ? "hourglass_top" : "auto_awesome"
                    // Nothing to do when the file already holds exactly what the
                    // preview is showing -- the preview is what makes that
                    // knowable without pressing it first.
                    //
                    // GUARDED ON previewCache, not on previewMatchesFile alone.
                    // With no cache, previewPalette falls back to the file, which
                    // makes previewMatchesFile trivially true -- so a machine
                    // where the preview cannot run (no jq, no wallpaper set) would
                    // find Generate greyed out forever with no way to reach it.
                    // Only a REAL preview is allowed to disable the button.
                    enabled: !section.generating
                             && !(section.previewCache && section.previewMatchesFile)
                    opacity: enabled ? 1 : 0.6
                    backgroundColor: Theme.primary
                    textColor: Theme.primaryText
                    onClicked: section.generate()
                }

                // Separate button, never automatic -- see the header. Disabled
                // until there is something to activate, and once it IS active
                // there is nothing left for it to do.
                DankButton {
                    text: section.isActive ? "In use" : "Use this palette"
                    iconName: section.isActive ? "check_circle" : "brush"
                    enabled: section.palette !== null && !section.isActive
                    opacity: enabled ? 1 : 0.6
                    onClicked: section.activate()
                }
            }

            // FAILURES ONLY now -- the success line was removed (see genProc's
            // onExited). resultText is left empty on a good run, so this collapses
            // to nothing and the preview card is the only report of success.
            StyledText {
                width: parent.width
                visible: section.resultText.length > 0
                wrapMode: Text.WordWrap
                color: section.resultOk ? Theme.surfaceTextMedium : Theme.error
                font.pixelSize: Theme.fontSizeSmall
                text: section.resultText
            }
        }
    }


    // Re-probe on every open: the user may have run install.sh in a terminal
    // since this section was last looked at, and the Loader keeps this file
    // alive in between. The probe's own callback refreshes the preview, which
    // also covers the wallpaper having changed while the panel was closed.
    Connections {
        target: section.hub
        enabled: section.hub !== null
        function onPanelOpenChanged() {
            if (section.hub.panelOpen)
                section.probe()
        }
    }
}
