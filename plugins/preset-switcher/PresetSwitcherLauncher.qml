// =============================================================================
//  Preset Switcher  --  DMS LAUNCHER plugin (front-end for set-preset.sh)
// =============================================================================
//
//  >>> IF THIS PLUGIN STOPPED WORKING AFTER A SYSTEM UPDATE, START HERE <<<
//  The plain-English guide next to this file explains what to check:
//        README.md  (in this same folder)
//
//  WHY THIS IS A LAUNCHER PLUGIN AND NOT A BAR WIDGET
//  Switching presets is a deliberate, infrequent action. A permanent bar pill
//  costs real estate every second of every day to serve something used once a
//  week, so this lives on DMS's launcher surface instead: open the launcher and
//  type the trigger (default "preset"). DMS's own Settings Search ("?") and
//  Clipboard ("cb") are the same pattern, and are the precedent this follows.
//
//  This plugin holds NO preset logic and no list of presets. Everything comes
//  from one script:
//
//        ~/.config/mango/scripts/set-preset.sh
//
//    * `--list --porcelain` gives it the items to show AND which one is active,
//      as tab-separated  name \t label \t icon \t blurb \t active(1|0)
//    * `<name>` applies one.
//
//  That is deliberate: adding a preset means adding a FOLDER under
//  ~/.config/mango/presets/, never editing this file.
//
//  The things here that can break after an update are:
//
//    1. `presetTool` (below) -- the path to that script, resolved from $HOME at
//       run time via `sh -c` (execDetached runs no shell, so a bare "~" would
//       not expand). If you move your scripts, change it here.
//    2. The `--list --porcelain` OUTPUT SHAPE. If a future set-preset.sh changes
//       the field order, fix parseList() below to match. The script's own header
//       documents the contract.
//    3. THE DMS LAUNCHER PLUGIN CONTRACT, which is what this file implements:
//           property var pluginService   // injected by PluginService
//           property string trigger      // what you type to reach these items
//           signal itemsChanged()
//           function getItems(query) -> [ {name, icon, comment, action, categories} ]
//           function executeItem(item)
//       Documented at /usr/share/quickshell/dms/PLUGINS/LauncherExample/README.md.
//       If DMS renames any of it the plugin loads but returns nothing; see
//       README.md for how to tell that apart from a missing script.
//
//  NOTE ON getItems() BEING SYNCHRONOUS. DMS calls it and uses the return value
//  immediately -- there is no way to await a subprocess inside it. So the preset
//  list is CACHED here and refreshed out of band (on load, after a switch, and
//  at most once every few seconds while the launcher is being typed into).
//  getItems() only ever reads that cache.
//
//  After ANY edit to this file, run `dms restart` to pick it up (a plain
//  re-toggle reuses a cached copy). See README.md.
// =============================================================================

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

Item {
    id: root

    // --- DMS launcher plugin contract ----------------------------------------
    property var pluginService: null
    property string trigger: "preset"
    signal itemsChanged

    // --- Script path (resolved from $HOME at run time via `sh -c`) ------------
    readonly property string presetTool: "\"$HOME/.config/mango/scripts/set-preset.sh\""

    // --- Cached preset list ---------------------------------------------------
    // Each entry: { name, label, icon, blurb, active }.
    property var presets: []
    // Set once the first refresh has come back, so an empty list can be told
    // apart from "we haven't looked yet" -- the difference between showing a
    // "something is wrong" row and showing nothing at all.
    property bool loaded: false
    property double lastRefresh: 0

    Component.onCompleted: {
        if (pluginService)
            trigger = pluginService.loadPluginData("presetSwitcher", "trigger", "preset")
        refresh(true)
    }

    onTriggerChanged: {
        if (pluginService)
            pluginService.savePluginData("presetSwitcher", "trigger", trigger)
    }

    Process {
        id: listProc
        // --porcelain, not the human list: stable, tab-separated, no colours.
        command: ["sh", "-c", root.presetTool + " --list --porcelain"]
        running: false
        stdout: StdioCollector {
            id: listOut
            onStreamFinished: root.parseList(listOut.text)
        }
    }

    // refresh(force) -- re-read the preset list.
    //
    // Throttled to once every 3s unless forced, because getItems() calls this on
    // every keystroke. Without the throttle, typing "preset min" would spawn a
    // subprocess per character for a list that changes maybe twice a month.
    function refresh(force) {
        var now = Date.now()
        if (!force && now - root.lastRefresh < 3000)
            return
        root.lastRefresh = now
        listProc.running = false
        listProc.running = true
    }

    // name \t label \t icon \t blurb \t active(1|0)
    // Anything without all five fields is skipped rather than shown half-parsed:
    // a malformed line means the script and this file disagree, and a row with no
    // name would apply nothing when selected.
    function parseList(txt) {
        var out = []
        if (txt) {
            var lines = txt.split("\n")
            for (var i = 0; i < lines.length; i++) {
                if (lines[i].length === 0)
                    continue
                var f = lines[i].split("\t")
                if (f.length < 5 || f[0].length === 0)
                    continue
                out.push({
                    "name": f[0],
                    "label": f[1].length > 0 ? f[1] : f[0],
                    "icon": f[2].length > 0 ? f[2] : "tune",
                    "blurb": f[3],
                    "active": f[4] === "1"
                })
            }
        }
        root.presets = out
        root.loaded = true
        root.itemsChanged()
    }

    // --- The launcher contract: items -----------------------------------------
    // The active preset is marked TWICE, and on purpose. A launcher row shows
    // only an icon, a name and a subtitle -- there is no accent border or glow to
    // borrow, so "which one am I on?" has to be carried by the content itself:
    //   * the icon becomes a filled check, which is the at-a-glance scan cue, and
    //   * the subtitle is prefixed "Active", which is the unambiguous statement.
    // Non-active rows keep their own icon, which is where identity actually helps
    // you pick.
    function getItems(query) {
        // Fire-and-forget: returns the cache now, and the next keystroke gets the
        // fresh copy. Cheap because refresh() throttles itself.
        refresh(false)

        if (root.loaded && root.presets.length === 0) {
            return [
                {
                    "name": "No presets found",
                    "icon": "material:error_outline",
                    "comment": "Expected them in ~/.config/mango/presets/ — re-run install.sh from your DankMango folder",
                    "action": "noop:",
                    "categories": ["Presets"]
                }
            ]
        }

        var items = []
        for (var i = 0; i < root.presets.length; i++) {
            var p = root.presets[i]
            items.push({
                "name": p.label,
                "icon": p.active ? "material:check_circle" : "material:" + p.icon,
                "comment": p.active ? ("Active  ·  " + p.blurb) : p.blurb,
                "action": "preset:" + p.name,
                "categories": ["Presets"]
            })
        }

        if (!query || query.length === 0)
            return items

        var q = query.toLowerCase()
        return items.filter(function (it) {
            return it.name.toLowerCase().indexOf(q) >= 0 || it.comment.toLowerCase().indexOf(q) >= 0
        })
    }

    // --- The launcher contract: execute ---------------------------------------
    // Same call the bar widget used to make, unchanged: run via `sh -c` so $HOME
    // expands, with the preset name forwarded as "$@" so it is an ARGUMENT and
    // never spliced into the command string. set-preset.sh does the validation,
    // the atomic symlink swap, the reload and the manifest write -- none of that
    // moved when the UI did.
    function executeItem(item) {
        if (!item || !item.action)
            return
        var idx = item.action.indexOf(":")
        var type = idx < 0 ? item.action : item.action.substring(0, idx)
        var data = idx < 0 ? "" : item.action.substring(idx + 1)

        if (type !== "preset" || data.length === 0)
            return

        Quickshell.execDetached(["sh", "-c", root.presetTool + " \"$@\"", "sh", data])

        // The launcher closes the moment this returns, so a toast is the only
        // confirmation the user gets that anything happened.
        if (typeof ToastService !== "undefined")
            ToastService.showInfo("Desktop preset", "Switched to " + item.name)

        // Re-read once the swap and reload have had time to land, so the check
        // mark is on the right row next time the launcher is opened.
        refreshAfterApply.restart()
    }

    Timer {
        id: refreshAfterApply
        interval: 400          // comfortably past the symlink swap + reload_config
        repeat: false
        onTriggered: root.refresh(true)
    }
}
