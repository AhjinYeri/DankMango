#!/usr/bin/env bash
#
# =============================================================================
#  alt-switcher.sh  --  Alt+Tab visual switcher wiring (mango + DMS altSwitcher)
# =============================================================================
#
#  >>> IF ALT+TAB STOPPED WORKING AFTER A SYSTEM UPDATE, START HERE <<<
#
#  Everything an update can break lives in ONE place: the box below marked
#  "########## EDIT HERE AFTER A MANGO / DMS UPDATE ##########". It holds the two
#  (and only two) commands this script sends. Test each by hand (comments show how)
#  and fix it to match the new MangoWM / DMS version.
#
#  Plain-English guide + full troubleshooting:
#    ~/.config/DankMaterialShell/plugins/altSwitcher/README.md
#
# -----------------------------------------------------------------------------
#  WHAT THIS SCRIPT DOES (plain English)
# -----------------------------------------------------------------------------
#  One mango keybind can only run one action, but Alt+Tab needs to do TWO things:
#    1. cycle/raise window focus  (mango's native focusstack -- unchanged behavior)
#    2. show/refresh the visual popup  (the DMS altSwitcher plugin)
#  This script does both, in that order. mango's Alt+Tab bind calls it with the
#  direction as its argument:  alt-switcher.sh next   (Alt+Shift+Tab -> "prev").
#
#  The popup itself is the plugin at
#    ~/.config/DankMaterialShell/plugins/altSwitcher/  (QML front-end only).
#  This script is the ONLY thing that tells mango to change focus.
# =============================================================================

dir="${1:-next}"
case "$dir" in
    next|prev) ;;
    *) dir="next" ;;
esac

# ########## EDIT HERE AFTER A MANGO / DMS UPDATE #############################
#
# These two functions are the ONLY commands that leave this script. If Alt+Tab
# breaks after an update, one of them is wrong -- test it by hand and fix it.

# (1) mango focus cycle. Test:   mmsg dispatch focusstack,next   -> {"success":true}
#     If it errors, mango renamed the action -- run `mmsg --help` for the new form.
mango_cycle_focus() {
    mmsg dispatch focusstack,"$dir" >/dev/null 2>&1
}

# (2) poke the DMS popup. Test:  dms ipc call altswitcher next    -> ok
#     "altswitcher" is the IpcHandler target inside AltSwitcherBar.qml; "next"/"prev"
#     are its functions. If this errors: the plugin isn't loaded/enabled, OR DMS
#     renamed `dms ipc call`. Check:  dms ipc call altswitcher show
mango_poke_popup() {
    dms ipc call altswitcher "$dir" >/dev/null 2>&1
}
#
# ###########################################################################

mango_cycle_focus
mango_poke_popup
