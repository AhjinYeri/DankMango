import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// =============================================================================
//  Audio Output Toggle  --  self-contained output switcher (PipeWire/WirePlumber)
// =============================================================================
//  Left-click cycles the DEFAULT audio sink to the next available output (wraps
//  around), updates the bar icon, and shows a DMS toast naming the new device.
//  Everything is done with `wpctl` (WirePlumber's CLI) -- no external scripts,
//  nothing hardcoded to a particular machine or device.
//
//  >>> EDIT HERE AFTER A PIPEWIRE / DMS UPDATE <<<
//    * Enumerate + current default:  `wpctl status`  (parsed in parseStatus()
//      below). If WirePlumber ever changes that text layout, fix the parser.
//    * Switch:  `wpctl set-default <id>`  where <id> is the wpctl node id from
//      the status list (NOT a pactl sink index -- the two namespaces differ).
//    * Toast:   ToastService.showInfo(title, details)  (DMS, from qs.Services).
// =============================================================================
PluginComponent {
    id: root

    // Parsed sinks from `wpctl status`: [{ id: <int>, name: <string>, isDefault: <bool> }, ...]
    property var sinks: []
    // Human description of the current default sink (drives the icon + toast).
    property string currentName: ""
    // The name we're switching TO, kept across the async set-default (for the toast).
    property string pendingName: ""
    // Set only when a manual switch just finished, so the poll timer never toasts.
    property bool justSwitched: false

    // ------------------------------------------------------------------------
    //  EDIT ME -- virtual-sink skip-list
    // ------------------------------------------------------------------------
    //  Sinks whose display name (from `wpctl status`) CONTAINS any of these
    //  substrings are hidden from the cycle -- matched case-insensitively. This
    //  is how non-physical sinks (EasyEffects, loopbacks, monitor sinks, a mic
    //  that also exposes a sink, null/dummy outputs) stay out of the rotation.
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
    // description shows the headphones glyph, everything else a speaker.
    readonly property string iconName: /head(phone|set)/i.test(root.currentName) ? "headphones" : "speaker"

    function refresh() {
        statusProc.running = true
    }

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
        // Toast only when this refresh followed a manual switch (not the poll timer),
        // so the default is already the new one by the time we name it.
        if (root.justSwitched) {
            ToastService.showInfo("Audio output", curName !== "" ? curName : root.pendingName)
            root.justSwitched = false
            root.pendingName = ""
        }
    }

    // --- switch to the next available sink (wraps) -------------------------------
    function cycle() {
        var list = root.sinks
        if (!list || list.length === 0)
            return
        if (list.length === 1) {
            ToastService.showInfo("Audio output", "Only one output available")
            return
        }
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
        // Re-read after the switch: refreshes the icon + default marker, and lets
        // parseStatus fire the toast (justSwitched gate) with the real new default.
        onExited: {
            root.justSwitched = true
            root.refresh()
        }
    }

    // Keep the icon correct even if the default was changed elsewhere (DMS, another app).
    Timer {
        interval: 4000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // No popout, so DMS routes pill clicks straight here.
    pillClickAction: function () {
        root.cycle()
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
