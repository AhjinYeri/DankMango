// =============================================================================
//  Preset Switcher  --  settings page (DMS Settings -> Plugins -> Preset Switcher)
// =============================================================================
//  This exists for ONE reason: DMS lets you edit the launcher trigger of its own
//  built-in launcher plugins from Settings -> Launcher, but NOT that of a
//  third-party one (see Modules/Settings/LauncherTab.qml -- the trigger field is
//  rendered only for built-ins). Without this page the trigger would be frozen at
//  whatever plugin.json ships, forever.
//
//  Everything is stored through pluginService.savePluginData("presetSwitcher", ...),
//  which is the same store DMS reads with SettingsData.getPluginSetting(), so the
//  two keys below are the ones PluginService.getPluginTrigger() actually looks at:
//      trigger    -- the text you type in the launcher to reach the presets
//      noTrigger  -- true = show the presets in ordinary launcher search too
//
//  Styled with Theme.* and DMS widgets so it re-tints with the wallpaper, unlike
//  the hardcoded hex colours in DMS's own LauncherExample settings page.
// =============================================================================

import QtQuick
import qs.Common
import qs.Widgets

FocusScope {
    id: root

    property var pluginService: null

    implicitHeight: col.implicitHeight + Theme.spacingL * 2
    height: implicitHeight

    function saveSetting(key, value) {
        if (pluginService)
            pluginService.savePluginData("presetSwitcher", key, value)
    }

    function loadSetting(key, defaultValue) {
        if (pluginService)
            return pluginService.loadPluginData("presetSwitcher", key, defaultValue)
        return defaultValue
    }

    Column {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Theme.spacingL
        spacing: Theme.spacingL

        StyledText {
            width: parent.width
            text: "Desktop presets are reached from the launcher, not the bar — switching them is a deliberate, occasional thing, so they don't take up permanent bar space."
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.3)
        }

        DankToggle {
            id: noTriggerToggle
            width: parent.width
            text: "Show presets in ordinary search"
            description: "On: presets appear alongside apps when you search. Off: type the trigger below to reach them."
            checked: root.loadSetting("noTrigger", false)
            onToggled: checked => {
                root.saveSetting("noTrigger", checked)
                if (!checked)
                    root.saveSetting("trigger", triggerField.text.trim() || "preset")
            }
        }

        Column {
            width: parent.width
            spacing: Theme.spacingS
            visible: !noTriggerToggle.checked

            StyledText {
                text: "Launcher trigger"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
            }

            StyledText {
                width: parent.width
                text: "Open the launcher and type this to list your presets. It is matched as a prefix, so a whole word is safer than a single letter — \"p\" would swallow every search starting with p."
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: Text.WordWrap
            }

            DankTextField {
                id: triggerField
                width: Math.min(220, parent.width)
                text: root.loadSetting("trigger", "preset")
                placeholderText: "preset"
                onTextEdited: {
                    var t = text.trim()
                    root.saveSetting("trigger", t || "preset")
                    root.saveSetting("noTrigger", false)
                }
            }
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.3)
        }

        StyledText {
            width: parent.width
            text: "Presets live in ~/.config/mango/presets/ — one folder each. Add a folder there and it shows up here with no code to write. From a terminal: set-preset.sh --list"
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
        }
    }
}
