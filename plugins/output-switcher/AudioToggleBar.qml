import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// =============================================================================
//  Audio Output Toggle  --  hybrid output switcher (PipeWire/WirePlumber)
// =============================================================================
//  Left-click switches the audio output, updates the bar icon, and shows a DMS
//  toast naming the new output. Two modes, chosen AUTOMATICALLY:
//
//   * DEFAULT (zero-config): cycle the default SINK across enumerated real sinks
//     via `wpctl set-default <id>` (virtual sinks filtered out). Correct for
//     setups with genuinely independent sinks -- USB DAC + onboard, HDMI, etc.
//
//   * NAMED TARGETS (opt-in, per-machine): if this plugin's settings define a
//     non-empty `outputTargets` list, clicking instead cycles those, applying
//     each with `pactl set-card-profile <card> <profile>`. This is REQUIRED for
//     hardware where "speakers" and "headphones" are two CARD PROFILES on one
//     card (e.g. S/PDIF-digital vs analog-jack) rather than two independent
//     sinks -- there is only ever one sink at a time, so sink-cycling has
//     nothing to switch to. Each target is {label, card, profile}; the profile
//     NAME is used (stable across reboots), NOT wpctl's numeric set-profile index.
//
//  outputTargets lives in ~/.config/DankMaterialShell/plugin_settings.json under
//  this plugin's id, e.g.:
//      "audioToggle": { "enabled": true, "outputTargets": [
//          {"label": "Speakers",   "card": "alsa_card.pci-0000_0d_00.4",
//           "profile": "output:iec958-stereo+input:analog-stereo"},
//          {"label": "Headphones", "card": "alsa_card.pci-0000_0d_00.4",
//           "profile": "output:analog-stereo+input:analog-stereo"} ] }
//  It is machine-specific (card + profile names differ per box), so the repo
//  ships WITHOUT it -> fresh installs default to zero-config sink cycling. Find
//  your own card + profile names with:  pactl list cards
//
//  >>> EDIT HERE AFTER A PIPEWIRE / DMS UPDATE <<<
//    * Sink enumerate + current default:  `wpctl status`       (parseStatus()).
//    * Card active profile:               `pactl list cards`   (parseCards()).
//    * Switch sink:     `wpctl set-default <id>`.
//    * Switch profile:  `pactl set-card-profile <card> <profile>`.
//    * Follow default:  `pactl set-default-sink <sink>` -- a profile switch drops
//      the old default's sink, so WirePlumber would otherwise auto-pick an
//      unrelated device (e.g. a USB mic's sink); we steer it back ourselves.
//    * OSD:             none emitted here. DMS's VolumeOSD -- patched by DankMango to
//      show the device name (see apply-combined-osd-patch.sh) -- pops up on the
//      resulting default-sink change, as ONE popup: icon + device name + slider.
//      Emitting audioOutputCycled too would stack a second (AudioOutputOSD) box.
//
//      HISTORY: that "pops up on the default-sink change" was NOT true as originally
//      written -- upstream VolumeOSD only re-syncs an already-visible OSD on a sink
//      change, so a sink change alone never opened it. The profile path below worked
//      only by accident (a profile switch destroys/recreates the sink node, and the
//      new node's async volume population fires volumeChanged, which DOES show()).
//      The sink-cycling path destroys nothing, so it silently showed no OSD at all on
//      multi-sink machines. apply-combined-osd-patch.sh now makes onSinkChanged open
//      the OSD itself, so BOTH paths trigger it deliberately rather than by accident.
//
//  This plugin shows NO success toast; the patched VolumeOSD is the visual feedback
//  on a switch. currentName still drives the bar icon. The only toasts it raises are
//  genuine FAILURES, titled "Audio switch failed".
// =============================================================================
PluginComponent {
    id: root

    // --- optional per-machine named targets (from plugin_settings.json) ----------
    //  {label, card, profile} entries. Non-empty -> profile-cycling mode; empty ->
    //  zero-config sink-cycling. `pluginData` is supplied and kept reactive by
    //  PluginComponent (it reloads on the DMS pluginDataChanged signal), so this
    //  binding updates automatically if the mapping is added/edited at runtime.
    readonly property var outputTargets: (pluginData && pluginData.outputTargets && pluginData.outputTargets.length > 0) ? pluginData.outputTargets : []
    readonly property bool hasTargets: outputTargets.length > 0
    // Index of the currently-active target (matched from `pactl list cards`), or -1.
    property int activeTargetIdx: -1

    // Parsed sinks from `wpctl status`: [{ id, name, isDefault }, ...] (sink mode).
    property var sinks: []
    // Human label of the current output (drives icon + toast): sink desc OR target label.
    property string currentName: ""
    // The label/name we're switching TO, kept across the async apply (for the toast).
    property string pendingName: ""
    // The card we just switched a profile on -- used to resolve its resulting sink so
    // the default sink follows the profile (profile mode only).
    property string pendingCard: ""
    // Set only when a manual switch just finished, so the poll timer never toasts.
    property bool justSwitched: false

    // ------------------------------------------------------------------------
    //  EDIT ME -- virtual-sink skip-list (sink-cycling mode only)
    // ------------------------------------------------------------------------
    //  Sinks whose display name (from `wpctl status`) CONTAINS any of these
    //  substrings are hidden from the cycle -- matched case-insensitively. This
    //  is how non-physical sinks (EasyEffects, loopbacks, monitor sinks, a mic
    //  that also exposes a sink, null/dummy outputs) stay out of the rotation.
    //  (Ignored entirely in named-targets/profile mode.)
    //
    //  Self-service tuning (no need to file an issue):
    //    * A REAL output of yours is being skipped -> remove the offending pattern.
    //    * A virtual sink slips through -> add a distinctive substring of its name.
    //  Find the exact names with:  wpctl status   (look at the "Sinks:" list).
    //
    //  NOTE: "iec958" is deliberately NOT included -- real S/PDIF and HDMI outputs
    //  are commonly reported as "... (IEC958)", so skipping it would hide a genuine
    //  output on many machines. Add "iec958" only if none of your REAL outputs use it.
    readonly property var skipSinkPatterns: [
        "easy effects", "easyeffects",   // EasyEffects processing sink
        "monitor",                        // monitor / loopback capture sinks
        "microphone",                     // a mic / interface that also exposes a sink
        "loopback",
        "null", "dummy"                   // null / dummy fallback outputs
    ]

    // True if `name` matches any skip pattern (case-insensitive substring test).
    function isVirtualSink(name) {
        var n = name.toLowerCase()
        for (var i = 0; i < root.skipSinkPatterns.length; i++)
            if (n.indexOf(root.skipSinkPatterns[i].toLowerCase()) !== -1)
                return true
        return false
    }

    // Icon HEURISTIC only (no device names hardcoded): a headphones-looking
    // label/description shows the headphones glyph, everything else a speaker.
    readonly property string iconName: /head(phone|set)/i.test(root.currentName) ? "headphones" : "speaker"

    // --- refresh: read state for whichever mode is active ------------------------
    function refresh() {
        if (root.hasTargets)
            cardProc.running = true
        else
            statusProc.running = true
    }
    // Re-read immediately when targets load/change (pluginData arrives async, and
    // the very first poll tick may fire before it does).
    onHasTargetsChanged: root.refresh()

    // ============================ SINK MODE (default) ============================

    // --- read the sink list + current default from `wpctl status` ----------------
    Process {
        id: statusProc
        command: ["wpctl", "status"]
        running: false
        stdout: StdioCollector {
            id: statusOut
            onStreamFinished: root.parseStatus(statusOut.text)
        }
    }

    // Parse the Audio -> Sinks subsection of `wpctl status`. Verified live layout:
    //   Audio
    //    |- Sinks:
    //    |      33. Easy Effects Sink                    [vol: 1.00]
    //    |  *   90. Starship/... Digital Stereo (IEC958) [vol: 0.60]
    //    |- Sources:
    // Kept box-drawing-agnostic on purpose: top-level sections start at column 0;
    // we only look inside "Audio" and, within it, the "Sinks:" block. A line is a
    // sink if it has "<id>. <description>"; a '*' before the id marks the current
    // default; a trailing "[...]" tag (volume / MUTED) is stripped from the name.
    function parseStatus(text) {
        var lines = text.split("\n")
        var out = []
        var curName = ""
        var top = ""
        var inSinks = false
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i]
            if (/^\S/.test(line)) {            // a column-0 line = top-level section header
                top = line.trim()
                inSinks = false
                continue
            }
            if (top !== "Audio")
                continue
            if (line.indexOf("Sinks:") !== -1) {
                inSinks = true
                continue
            }
            if (/(Devices|Sources|Filters|Streams|Clients):/.test(line)) {
                inSinks = false
                continue
            }
            if (!inSinks)
                continue
            var m = line.match(/(\d+)\.\s+(.*?)\s*(?:\[[^\]]*\]\s*)*$/)
            if (!m)
                continue
            var name = m[2].trim()
            if (name === "")
                continue
            var starIdx = line.indexOf("*")
            var isDefault = (starIdx !== -1 && starIdx < line.indexOf(m[1]))
            if (isDefault)
                curName = name                 // capture for the icon even if it's filtered out
            if (root.isVirtualSink(name))
                continue                        // keep virtual sinks out of the cycle
            out.push({
                "id": parseInt(m[1]),
                "name": name,
                "isDefault": isDefault
            })
        }
        root.sinks = out
        root.currentName = curName
        // Clear the transient post-switch state (no toast -- see header note).
        if (root.justSwitched) {
            root.justSwitched = false
            root.pendingName = ""
        }
    }

    // --- switch to the next available sink (wraps) -------------------------------
    function cycleSinks() {
        var list = root.sinks
        if (!list || list.length === 0)
            return
        if (list.length === 1)
            return                                  // nothing to switch to
        var idx = -1
        for (var i = 0; i < list.length; i++) {
            if (list[i].isDefault) {
                idx = i
                break
            }
        }
        var next = list[(idx + 1) % list.length]   // wrap; idx === -1 -> first entry
        root.pendingName = next.name
        setDefaultProc.command = ["wpctl", "set-default", "" + next.id]
        setDefaultProc.running = true
    }

    Process {
        id: setDefaultProc
        running: false
        // Re-read after the switch (refreshes icon + default marker). No OSD emitted
        // here: DMS's patched VolumeOSD pops up on the resulting default-sink change,
        // showing icon + device name + slider as ONE popup (see header note).
        //
        // This is the path that showed NO OSD before the onSinkChanged fix in
        // apply-combined-osd-patch.sh -- switching between two pre-existing sinks emits
        // no volumeChanged, so nothing opened the OSD. It relies on that patch being
        // applied; post-update-health.sh checks for it.
        onExited: {
            root.justSwitched = true
            root.refresh()
        }
    }

    // ====================== NAMED-TARGET / PROFILE MODE =========================

    // --- read each card's Active Profile from `pactl list cards` -----------------
    Process {
        id: cardProc
        command: ["pactl", "list", "cards"]
        running: false
        stdout: StdioCollector {
            id: cardOut
            onStreamFinished: root.parseCards(cardOut.text)
        }
    }

    // Map every card's Active Profile, then work out which configured target is
    // currently active (card's active profile == target.profile). Sets the icon
    // label (no toast). `pactl list cards` shape:
    //   Card #NN
    //       Name: alsa_card.pci-0000_0d_00.4
    //       ...
    //       Active Profile: output:iec958-stereo+input:analog-stereo
    function parseCards(text) {
        var lines = text.split("\n")
        var curCard = ""
        var active = ({})                       // card name -> active profile name
        for (var i = 0; i < lines.length; i++) {
            var nameM = lines[i].match(/^\s*Name:\s+(\S+)/)
            if (nameM) {
                curCard = nameM[1]
                continue
            }
            var apM = lines[i].match(/^\s*Active Profile:\s+(.+?)\s*$/)
            if (apM && curCard !== "")
                active[curCard] = apM[1]
        }
        var idx = -1
        var label = ""
        for (var j = 0; j < root.outputTargets.length; j++) {
            var t = root.outputTargets[j]
            if (active[t.card] === t.profile) {
                idx = j
                label = t.label
                break
            }
        }
        root.activeTargetIdx = idx
        root.currentName = label                // "" if none matched -> speaker icon
        // Clear the transient post-switch state (no toast -- see header note).
        if (root.justSwitched) {
            root.justSwitched = false
            root.pendingName = ""
        }
    }

    // --- switch to the next configured target (wraps) via card profile -----------
    function cycleProfiles() {
        var t = root.outputTargets
        if (!t || t.length === 0)
            return
        if (t.length === 1)
            return                                  // nothing to switch to
        var cur = root.activeTargetIdx              // -1 (unknown/external) -> start at first
        var next = t[(cur + 1) % t.length]
        root.pendingName = next.label
        root.pendingCard = next.card
        setProfileProc.command = ["pactl", "set-card-profile", "" + next.card, "" + next.profile]
        setProfileProc.running = true
    }

    // Switching a card profile is a 3-step async chain, because it DESTROYS the old
    // default's sink -> WirePlumber then auto-reassigns the default to an unrelated
    // device (confirmed: a USB mic's sink). So we steer the default back to THIS
    // card's new sink ourselves before declaring success:
    //   1. pactl set-card-profile           (setProfileProc)
    //   2. resolve the card's new sink from `pactl list sinks short`
    //      (sinkQueryProc -> applyDefaultSink), derived at switch-time (not hardcoded)
    //   3. pactl set-default-sink           (setDefaultSinkProc)
    Process {
        id: setProfileProc
        running: false
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {                        // profile switch failed -> abort
                ToastService.showError("Audio switch failed", "Couldn't change the audio profile")
                root.pendingName = ""
                root.pendingCard = ""
                return
            }
            sinkQueryProc.running = true                 // step 2
        }
    }

    // Step 2: find the sink the just-activated profile created for pendingCard.
    Process {
        id: sinkQueryProc
        command: ["pactl", "list", "sinks", "short"]
        running: false
        stdout: StdioCollector {
            id: sinkQueryOut
            onStreamFinished: root.applyDefaultSink(sinkQueryOut.text)
        }
    }

    // A card named "alsa_card.<busid>" owns sinks named "alsa_output.<busid>.<suffix>"
    // (verified for both PCI and USB cards), so match by that prefix -- general, with
    // no profile->sink-name hardcoding. `pactl list sinks short` is TAB-separated:
    //   <id>\t<name>\t<driver>\t<sample-spec>\t<state>
    function applyDefaultSink(text) {
        var prefix = "alsa_output." + root.pendingCard.replace(/^alsa_card\./, "") + "."
        var lines = text.split("\n")
        var sink = ""
        for (var i = 0; i < lines.length; i++) {
            var cols = lines[i].split("\t")
            if (cols.length >= 2 && cols[1].indexOf(prefix) === 0) {
                sink = cols[1]
                break
            }
        }
        if (sink === "") {
            // Profile switched but its sink can't be found -> surface it, re-read state.
            ToastService.showError("Audio switch failed", "Switched profile, but couldn't find its output")
            root.pendingName = ""
            root.pendingCard = ""
            root.refresh()
            return
        }
        setDefaultSinkProc.command = ["pactl", "set-default-sink", sink]
        setDefaultSinkProc.running = true                // step 3
    }

    // Step 3: the default sink now points at the card's new sink. Re-read state either
    // way (no toast -- the DMS volume OSD is the visual feedback on output changes).
    Process {
        id: setDefaultSinkProc
        running: false
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                root.justSwitched = true
                // No OSD emitted here: the default-sink change drives DMS's patched
                // VolumeOSD (icon + device name + slider) as ONE popup. See header note.
                //
                // Historically this worked by accident -- the profile switch above
                // recreates the sink node, and the new node's async volume population
                // fired volumeChanged. Since the onSinkChanged fix it triggers on the
                // sink change itself, like the sink-cycling path.
            } else {
                ToastService.showError("Audio switch failed", "Switched profile, but couldn't set the default output")
                root.pendingName = ""
                root.pendingCard = ""
            }
            root.refresh()
        }
    }

    // --- keep the icon correct even if the output changed elsewhere --------------
    Timer {
        interval: 4000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // No popout, so DMS routes pill clicks straight here.
    pillClickAction: function () {
        if (root.hasTargets)
            root.cycleProfiles()
        else
            root.cycleSinks()
    }

    horizontalBarPill: Component {
        DankIcon {
            name: root.iconName
            color: Theme.primary
            size: Theme.iconSize - 6
        }
    }

    verticalBarPill: Component {
        DankIcon {
            name: root.iconName
            color: Theme.primary
            size: Theme.iconSize - 6
        }
    }
}
