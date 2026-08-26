#!/usr/bin/env bash
#
# wallpaper-border-reload.sh
# ==========================
# Carries the wallpaper's palette to the three places DMS does NOT push it:
# mango's window borders, the SDDM login screen, and the cava visualiser accents.
#
# WHAT IT DOES (plain English):
#   DMS/matugen regenerates the palette into ~/.cache/DankMaterialShell/dms-colors.json
#   every time you change your wallpaper. This watcher notices that file change and
#   then does three things nothing else does:
#     1. writes ~/.config/mango/dms/colors.conf     (border colors -- see SELF-HEAL)
#     2. runs wallpaper-accent-extract.sh           (cava visualiser accent pair)
#     3. runs sddm-palette-sync.sh                  (login screen palette + wallpaper)
#   ...and then tells mango to re-read its config so the borders actually recolor.
#
# WHY THIS SCRIPT STILL EXISTS  (re-verified 2026-08-05 on mango 0.15.5)
#   Read this before "simplifying" or deleting it -- its ORIGINAL reason is gone,
#   but it's still load-bearing for three OTHER reasons.
#
#   The original reason (NO LONGER TRUE, kept only so nobody re-derives it):
#   DMS's reload hook used to run the pre-0.14 `mmsg -d reload_config`, which mango
#   0.14 removed, so nothing reloaded mango on a wallpaper change and borders only
#   updated on a manual SUPER+r. THAT IS FIXED UPSTREAM. matugen/configs/mangowc.toml
#   now runs `mmsg dispatch reload_config`, and DMS separately watches colors.conf
#   itself (Services/MangoService.qml) and reloads on any change. So the reload call
#   below is the third of three redundant reloads. Deliberately KEPT -- it's one
#   cheap command and the only reload we control -- but it's no longer why this
#   file is here.
#
#   The three reasons it IS still load-bearing:
#     a) colors.conf SELF-HEAL. matugen's mangowc template STILL silently fails to
#        write colors.conf. Verified by stopping this watcher and changing the
#        wallpaper: dms-colors.json regenerated correctly, colors.conf never moved.
#        Without the regen below, borders keep the PREVIOUS wallpaper's colors.
#     b) It's the ONLY caller of sddm-palette-sync.sh. Stop this script and the
#        login screen silently keeps the old palette and old background.
#     c) It's the ONLY caller of wallpaper-accent-extract.sh, so the cava
#        visualiser silently keeps the old accent pair.
#     d) It's what makes DankMango's own colour engine DYNAMIC. Without the
#        wallpaper branch at the bottom of the loop, the engine's palette only
#        ever changes when you press Generate in the control hub -- which defeats
#        the point of a palette derived from the wallpaper. Note that branch
#        watches session.json, NOT dms-colors.json like (a)-(c) do; the comment
#        there explains why that difference is load-bearing.
#   Even if (a) got fixed upstream tomorrow, deleting this script would still break
#   (b), (c) and (d) with no error anywhere. Re-check all four before retiring it.
#
# RESTARTING IT DOESN'T FIX ALREADY-STALE COLORS.
#   It baselines both mtimes and the current wallpaper path at startup and only
#   reacts to the NEXT change, so anything it missed while it was down stays
#   missed. To force a resync:
#       touch ~/.cache/DankMaterialShell/dms-colors.json
#   (border-color-healthcheck.sh will NOT catch this -- it checks that the chain is
#   wired up, not that the colors are current, and reports OK on stale values.)
#   That touch covers (a)-(c) only. For the colour engine (d), re-set the same
#   wallpaper from the control hub, or just press Generate.
#
self_help() { awk 'NR>2 && !/^#/{exit} NR>2 && sub(/^#[ ]?/,"")' "$0"; }
case "${1:-}" in -h|--help) self_help; exit 0 ;; esac
# --help prints everything ABOVE these two lines (the only copy of this script's
# usage), using the same one-line idiom as install.sh/update.sh/uninstall.sh.
#
# Two placement decisions, both deliberate:
#   * ABOVE the EDIT-HERE box and well above the flock. This script is a
#     long-lived watcher, so without an arm of its own `wallpaper-border-reload.sh
#     --help` fell straight through and STARTED the watcher on any machine where
#     it wasn't already running, instead of describing itself.
#   * This rationale sits BELOW the arm rather than above it. The extractor stops
#     at the first non-comment line, so anything written above would be printed to
#     users as if it were usage text; down here it stays a maintainer note.

# ===========================================================================
# EDIT HERE AFTER A MANGO / DMS UPDATE  (the only version-sensitive bits)
# ===========================================================================
# 1) Where DMS/matugen writes the border colors (matugen output_path,
#    CONFIG_DIR/mango/dms/colors.conf):
COLORS_FILE="$HOME/.config/mango/dms/colors.conf"
#
# 2) The command that tells the RUNNING mango to re-read its config.
#    Now redundant (see the header -- upstream reloads too), kept deliberately.
#    If borders stop auto-updating after a mango update, TEST this by hand:
#        mmsg dispatch reload_config      # expect {"success":true}
#    If that prints {"error":"unknown command"}, the CLI changed again --
#    find the new form with `mmsg --help` and update the line below.
mango_reload_config() { mmsg dispatch reload_config >/dev/null 2>&1; }
#
# 3) Poll interval in seconds (no inotify-tools installed, so we poll mtime).
#    stat-ing one file twice a second is negligible CPU; lower = snappier borders.
POLL_SECONDS=0.5
# ===========================================================================

LOCK="/tmp/mango-wallpaper-border-reload.lock"

# Single instance (same flock idiom as the other mango helpers).
exec 9>"$LOCK"
flock -n 9 || exit 0

# If the colors file isn't there yet (e.g. first boot before DMS writes it),
# wait for it rather than dying.
while [ ! -f "$COLORS_FILE" ]; do sleep "$POLL_SECONDS"; done

# --- SELF-HEAL for the broken generate link --------------------------------
# DMS is supposed to write COLORS_FILE via its mangowc matugen template. As of
# 2026-07-19 that template silently stopped running on wallpaper change: the
# theming pass still rewrites dms-colors.json AND the GTK template, but skips
# mangowc, so COLORS_FILE froze and window borders stuck on an old colour while
# the bar (which reads DMS Theme directly) kept updating correctly.
#
# STILL BROKEN as of 2026-08-05 (mango 0.15.5). Re-tested directly: with this
# watcher stopped, a wallpaper change regenerated dms-colors.json but left
# COLORS_FILE untouched at its old values. Re-run that test before assuming an
# update has fixed it -- upstream fixed the matugen POST-HOOK, not the template.
#
# dms-colors.json DOES update reliably on every wallpaper change, so derive
# COLORS_FILE from it ourselves rather than depending on the template. The role
# mapping below is exactly what the template produces (verified against a known
# good `dms matugen generate` run: bordercolor=outline, focuscolor=primary,
# urgentcolor=error).
DMS_COLORS_JSON="$HOME/.cache/DankMaterialShell/dms-colors.json"
ACCENT_EXTRACT="$HOME/.config/mango/scripts/wallpaper-accent-extract.sh"
# Pushes the same palette to the SDDM login screen. The greeter runs as the
# `sddm` system user and cannot read $HOME (0700), so it can't follow the
# wallpaper the way everything else does; this script writes the colors into a
# user-owned theme.conf.user that the greeter CAN read. No elevation involved --
# see the script's header for why. Exits quietly if the theme isn't installed.
SDDM_PALETTE_SYNC="$HOME/.config/mango/scripts/sddm-palette-sync.sh"
# DankMango's own colour engine, Ripe Chroma (tools/ripe-chroma). Regenerates the DMS custom
# theme palette straight from the wallpaper, holding the wallpaper's true hue
# instead of letting Material You's tonal mapping wash it out -- the reason a red
# wallpaper produces a salmon accent under matugen. Reads the wallpaper path from
# DMS's own session state rather than being told, so it stays a fan-out consumer
# like the two above and needs nothing passed in.
#
# THIS IS WHAT MAKES THE ENGINE DYNAMIC. Without this block the palette only ever
# changes when you click Generate in the control hub, which defeats the point --
# the whole reason it reads the wallpaper is so it can follow the wallpaper.
#
# GUARDED ON -x ON PURPOSE: the engine is an OPT-IN extra (install.sh stage 13b
# asks, because the rust toolchain is ~295 MB), so on any machine that declined it
# this block is a no-op and the fan-out behaves exactly as it did before. It also
# only *writes a file*; whether DMS reads it is a separate user choice (Settings
# -> Theme -> Custom, pointed at RIPE_CHROMA_THEME), so this cannot change
# anyone's colours until they opt in.
RIPE_CHROMA="$HOME/.local/bin/dankmango-ripe-chroma"
DMS_SESSION_JSON="$HOME/.local/state/DankMaterialShell/session.json"
# The control hub's Ripe Chroma section persists the user's choices here, under
# the hub's own plugin id. An automatic regeneration MUST honour them: silently
# regenerating at the built-in defaults would undo the user's Vibrant/7-colour
# choice every single time they changed their wallpaper.
DMS_PLUGIN_SETTINGS="$HOME/.config/DankMaterialShell/plugin_settings.json"
# Written EXPLICITLY rather than letting the engine resolve its own default. The
# engine's default is "whatever DMS currently has as customThemeFile", so if the
# user has pointed DMS at somebody else's theme.json, the default would overwrite
# THAT file. Same rule the control-hub section follows, for the same reason.
RIPE_CHROMA_THEME="$HOME/.config/DankMaterialShell/dankmango-theme.json"
# Fallbacks for when nothing has been saved yet (engine's own defaults).
RIPE_CHROMA_MODE_DEFAULT="accurate"   # accurate | vibrant | muted
RIPE_CHROMA_COUNT_DEFAULT=5
# satty's annotation colour palette (screenshot.sh's editor). Generated inline
# below rather than as its own script: it's one jq call with no other caller,
# unlike the two above.
SATTY_CONFIG="$HOME/.config/satty/config.toml"

# Regenerate satty's colour palette from the wallpaper.
#
# WHY BOTH SCHEMES, not just .colors.dark like everything else here:
#   Material You's DARK scheme roles are all light, low-chroma tones -- they're
#   designed as ink ON a dark surface, not as ink on an arbitrary screenshot. On
#   a pink wallpaper, dark.{primary,error,tertiary,secondary} came out as
#   #ffb2ba / #ffb4ab / #ffb690 / #f6b8ac: four swatches you can't tell apart,
#   which is a useless palette. The LIGHT scheme's equivalents are the saturated
#   versions (#bd0042 / #ba1a1a / #895031) and read properly as annotation ink.
#
#   So the palette pairs them deliberately: the light-scheme tones for marking
#   up normal (bright) screenshots, plus the dark-scheme accent and a near-white
#   for marking up screenshots OF DARK UIs, where dark ink would vanish. Order
#   matters -- satty binds number keys 1-9 to palette slots, so the two you
#   actually reach for (accent, red) are 1 and 2.
#
# This file is written WHOLESALE on every wallpaper change, so it deliberately
# carries colours and nothing else; screenshot.sh passes behaviour on satty's
# command line, which takes precedence over the config file anyway.
regen_satty_palette() {
    [ -f "$DMS_COLORS_JSON" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1

    local palette custom
    # -> "#rrggbbff" per line, in the slot order described above.
    palette="$(jq -r '
        [ .colors.light.primary,          # 1: wallpaper accent, as ink
          .colors.light.error,            # 2: red, the universal "look here"
          .colors.dark.primary,           # 3: accent again, for dark screenshots
          .colors.light.on_background,    # 4: near-black
          .colors.dark.on_background,     # 5: near-white
          .colors.light.tertiary          # 6: warm contrast
        ] | map(select(. != null)) | .[]' "$DMS_COLORS_JSON" 2>/dev/null)"
    [ -n "$palette" ] || return 1

    # Colour-picker presets: just the accent at both polarities.
    custom="$(jq -r '[ .colors.light.primary, .colors.dark.primary ]
                     | map(select(. != null)) | .[]' "$DMS_COLORS_JSON" 2>/dev/null)"

    local new
    new="$(
        printf '%s\n' \
            '# ! Auto-generated file. Do not edit directly.' \
            '# Regenerated from the wallpaper palette by wallpaper-border-reload.sh.' \
            '# satty behaviour (tools, save paths, early-exit) is set on the command' \
            '# line in screenshot.sh, which overrides anything written here.' \
            '' \
            '[color-palette]' \
            'palette = ['
        printf '%s\n' "$palette" | sed 's/^/    "/; s/$/ff",/'
        printf '%s\n' \
            ']' \
            'custom = ['
        printf '%s\n' "$custom" | sed 's/^/    "/; s/$/ff",/'
        printf '%s\n' ']'
    )"

    # Only touch the file when it would actually change, matching the churn
    # guard in regen_colors_conf.
    [ "$new" = "$(cat "$SATTY_CONFIG" 2>/dev/null)" ] && return 1
    mkdir -p "$(dirname "$SATTY_CONFIG")"
    printf '%s\n' "$new" > "$SATTY_CONFIG"
    return 0
}

regen_colors_conf() {
    [ -f "$DMS_COLORS_JSON" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local border focus urgent
    border="$(jq -r '.colors.dark.outline // empty' "$DMS_COLORS_JSON" 2>/dev/null)"
    focus="$(jq -r '.colors.dark.primary // empty' "$DMS_COLORS_JSON" 2>/dev/null)"
    urgent="$(jq -r '.colors.dark.error // empty' "$DMS_COLORS_JSON" 2>/dev/null)"
    [ -n "$border" ] && [ -n "$focus" ] && [ -n "$urgent" ] || return 1
    # #rrggbb -> 0xrrggbbff (mango's format)
    border="0x${border#\#}ff"; focus="0x${focus#\#}ff"; urgent="0x${urgent#\#}ff"
    # Only rewrite when something actually changed, so we don't churn the file
    # (and thereby retrigger our own reload) every poll.
    grep -q "$focus" "$COLORS_FILE" 2>/dev/null && grep -q "$border" "$COLORS_FILE" 2>/dev/null && return 1
    cat > "$COLORS_FILE" <<EOF
# ! Auto-generated file. Do not edit directly.
# Remove source = ./dms/colors.conf from your config to override.

bordercolor = $border
focuscolor  = $focus
urgentcolor = $urgent
EOF
    return 0
}

# The wallpaper DMS is currently showing, straight from its own session state --
# the same single source of truth the control hub's Generate button reads, so a
# manual run and an automatic one can never disagree about which image is "the
# wallpaper". Empty (not an error) when jq is missing or nothing is set yet.
read_wallpaper_path() {
    command -v jq >/dev/null 2>&1 || return 0
    jq -r '.wallpaperPath // empty' "$DMS_SESSION_JSON" 2>/dev/null
}

# Regenerate the DankMango custom-theme palette from the current wallpaper,
# honouring whatever the user last chose in the control hub's Ripe Chroma
# section.
#
# READS THE SAVED PREFERENCES, DOES NOT ASSUME DEFAULTS. mode and count come from
# plugin_settings.json, so an automatic run produces the same palette the Generate
# button would produce right now. Anything missing or out of range falls back to
# the engine's own defaults rather than failing.
#
# SKIPS ENTIRELY IN STATIC MODE. useSeed:true means the user deliberately pinned
# the palette to one hand-picked colour; a wallpaper change must not silently
# throw that away. Static is the documented opt-out from this whole block.
#
# NO RELOAD CALL AFTERWARDS, DELIBERATELY. DMS watches the file itself:
# Common/Theme.qml's customThemeFileView is a FileView with
# `watchChanges: currentTheme === "custom"` and `onFileChanged: reload()`, and the
# engine writes atomically (temp + rename), so the shell only ever sees a complete
# palette and picks it up live on its own. Verified on DMS's shipped Theme.qml --
# re-check that FileView before adding a reload here, don't add one on a hunch.
regen_ripe_chroma() {
    [ -x "$RIPE_CHROMA" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1

    local prefs mode count use_seed wp
    prefs="$(jq -c '.controlHub.colorEngine // empty' "$DMS_PLUGIN_SETTINGS" 2>/dev/null)"

    # Static / manual-colour mode -> hands off. Note this is checked BEFORE the
    # wallpaper lookup: in static mode the wallpaper is irrelevant by definition.
    use_seed="$(printf '%s' "$prefs" | jq -r '.useSeed // false' 2>/dev/null)"
    [ "$use_seed" = "true" ] && return 1

    mode="$(printf '%s' "$prefs" | jq -r '.mode // empty' 2>/dev/null)"
    count="$(printf '%s' "$prefs" | jq -r '.count // empty' 2>/dev/null)"
    case "$mode"  in accurate|vibrant|muted) ;; *) mode="$RIPE_CHROMA_MODE_DEFAULT"   ;; esac
    case "$count" in 3|4|5|6|7|8)            ;; *) count="$RIPE_CHROMA_COUNT_DEFAULT" ;; esac

    wp="$(jq -r '.wallpaperPath // empty' "$DMS_SESSION_JSON" 2>/dev/null)"
    [ -n "$wp" ] && [ -f "$wp" ] || return 1

    "$RIPE_CHROMA" --wallpaper "$wp" --count "$count" --mode "$mode" \
        --output "$RIPE_CHROMA_THEME" >/dev/null 2>&1
}

last="$(stat -c %Y "$COLORS_FILE" 2>/dev/null)"
last_json="$(stat -c %Y "$DMS_COLORS_JSON" 2>/dev/null)"
# The colour engine is triggered off the WALLPAPER, not off DMS_COLORS_JSON like
# everything else here -- see the branch below for why that distinction is
# load-bearing rather than a style choice.
last_session="$(stat -c %Y "$DMS_SESSION_JSON" 2>/dev/null)"
last_wp="$(read_wallpaper_path)"
while sleep "$POLL_SECONDS"; do
    # 1. DMS regenerated its palette -> rebuild COLORS_FILE if the template didn't.
    now_json="$(stat -c %Y "$DMS_COLORS_JSON" 2>/dev/null)"
    if [ -n "$now_json" ] && [ "$now_json" != "$last_json" ]; then
        last_json="$now_json"
        regen_colors_conf
        # Also re-extract the wallpaper's real accent pair for the cava
        # visualiser. Backgrounded: it costs up to 5 matugen runs (~1.7s) and
        # must not delay the border reload below.
        [ -x "$ACCENT_EXTRACT" ] && "$ACCENT_EXTRACT" >/dev/null 2>&1 &
        # Re-tint the login screen too. Cheap (one jq pass, writes only on an
        # actual change) but backgrounded anyway so it can never delay the
        # border reload below.
        [ -x "$SDDM_PALETTE_SYNC" ] && "$SDDM_PALETTE_SYNC" >/dev/null 2>&1 &
        # And re-tint satty's annotation palette. Pure jq + a small write, so
        # it runs inline rather than backgrounded like the two above.
        regen_satty_palette
    fi

    # 2. COLORS_FILE changed (by us, or by the template if it ever works again)
    #    -> tell mango to re-read it.
    now="$(stat -c %Y "$COLORS_FILE" 2>/dev/null)" || continue
    if [ "$now" != "$last" ]; then
        last="$now"
        mango_reload_config
    fi

    # 3. The wallpaper itself changed -> regenerate the DankMango palette.
    #
    # WHY THIS HANGS OFF session.json AND NOT DMS_COLORS_JSON LIKE (1) DOES.
    #   Measured 2026-08-23, and it is the whole reason the engine never updated
    #   automatically: DMS only rewrites dms-colors.json when it re-runs matugen,
    #   which it does for the DYNAMIC theme. Once you point DMS at a custom theme
    #   file -- which is exactly what using this engine means -- matugen stops
    #   being the source of the palette and dms-colors.json stops moving. A
    #   wallpaper change then updates session.json and colors.conf while
    #   dms-colors.json keeps its old mtime, so a colour-engine hook inside
    #   branch (1) can never fire for the one audience that has the engine
    #   installed. Watching the wallpaper is also just the honest trigger: the
    #   wallpaper is the engine's actual input.
    #
    #   Re-test before "unifying" this back into branch (1): set DMS to a custom
    #   theme, change the wallpaper, and compare dms-colors.json's mtime.
    #
    # COMPARES THE PATH, NOT THE MTIME. session.json is DMS's general session
    # state -- do-not-disturb, night mode, light/dark, per-monitor wallpapers --
    # so it is rewritten for plenty of reasons that are not a wallpaper change.
    # Regenerating on mtime alone would re-run the engine every time the user
    # toggled DND. The mtime is used only to skip the jq call on an idle poll.
    now_session="$(stat -c %Y "$DMS_SESSION_JSON" 2>/dev/null)"
    if [ -n "$now_session" ] && [ "$now_session" != "$last_session" ]; then
        last_session="$now_session"
        now_wp="$(read_wallpaper_path)"
        if [ -n "$now_wp" ] && [ "$now_wp" != "$last_wp" ]; then
            last_wp="$now_wp"
            # Backgrounded like the accent/SDDM consumers: ~0.13s on a 4K
            # wallpaper, small but not free, and the border reload above must
            # never wait on it. Every guard (engine installed, static mode,
            # saved prefs) lives inside the function.
            regen_ripe_chroma &
        fi
    fi
done
