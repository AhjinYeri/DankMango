#!/usr/bin/env bash
#
# docs-hub.sh
# ===========
# The in-session help hub. Bound to SUPER+SHIFT+/ (see config.conf).
#
# WHAT IT IS FOR
#   SUPER+/ already opens DMS's searchable keybind cheatsheet, which is great when
#   you know roughly what you are looking for. This hub is the other half: the
#   thing you open when you do NOT know what to look for yet. It offers a short,
#   grouped, curated key table, a written guide to how this desktop works, and a
#   way to jump into the DMS cheatsheet for the exhaustive list.
#
# THE ONE IDEA THAT MATTERS: THERE IS NO SECOND COPY OF THE DESCRIPTIONS
#   Every shortcut description shown here is read live out of config.conf -- the
#   comment line directly above each bind, which is the same comment DMS's SUPER+/
#   cheatsheet uses. This script stores none of them. docs/keys.tsv lists only
#   WHICH keys to show and in what order.
#
#   So: to change what this hub says about a shortcut, edit the comment above that
#   bind in config.conf. Do not look for the text in here -- it is not here.
#
#   The lookup is an exact match on the (modifiers, key) pair, not a substring
#   search, so "SUPER, i" can never accidentally match "SUPER+SHIFT, I". If a key
#   in keys.tsv has no matching bind in config.conf any more, it is rendered as
#   MISSING instead of being silently dropped -- that is deliberate, it is how you
#   find out the table has gone stale. `docs-hub.sh check` exits non-zero if any
#   key is MISSING, which is what post-update-health.sh should call.
#
# FIRST BIND WINS -- ON PURPOSE
#   mango obeys the FIRST bind it finds for a given key and ignores later
#   duplicates. config.conf currently has a few deliberately-dead duplicate binds
#   (SUPER+n, SUPER+ALT+Left/Right) whose comments say "Inactive:". The index
#   below keeps the FIRST match only, exactly like mango, so the hub shows you the
#   bind that actually fires rather than the dead one further down the file.
#
# USAGE
#   docs-hub.sh            open the interactive hub (this is what the keybind does)
#   docs-hub.sh keys       print the curated key table and exit
#   docs-hub.sh guide      print the guide and exit
#   docs-hub.sh flags      the copy-pasteable list of every DankMango command
#   docs-hub.sh flags NAME show one command's full --help (e.g. update.sh)
#   docs-hub.sh check      validate keys.tsv against config.conf; non-zero if stale
#
# THE SAME IDEA APPLIES TO `flags`
#   It stores no command lines and no descriptions. The COMMANDS list below says
#   WHICH scripts to show and in what order; every command line and its blurb is
#   read live from that script's own `# CMD: <command> :: <description>` header
#   lines. A flag added to any listed script shows up here with no edit to this
#   file. To change what a command says, edit that script -- not this one.
#
# ---------------------------------------------------------------------------
set -uo pipefail

# CMD lines are what docs-hub.sh's command list shows: a real, runnable command
# and a short description, separated by " :: ". They live here, next to the code
# that implements them, so the hub stores no copy of its own. Add a line when you
# add a flag worth showing; the fuller explanation stays in the Usage block above.
# CMD: ~/.config/mango/scripts/docs-hub.sh :: open this help hub (same as SUPER+SHIFT+/)
# CMD: ~/.config/mango/scripts/docs-hub.sh keys :: print the keyboard-shortcut table and exit

# Where the installed helper scripts live. Resolved from this script's own
# location rather than assumed, so the command menu still finds its siblings if
# the whole scripts dir is moved or run from a checkout.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANGO_DIR="${MANGO_DIR:-$HOME/.config/mango}"
CONFIG="$MANGO_DIR/config.conf"
DOCS_DIR="$MANGO_DIR/docs"
KEYS_FILE="$DOCS_DIR/keys.tsv"
# Named DESKTOP-GUIDE.md, not GUIDE.md, on purpose: the DankMango repo already has
# a docs/GUIDE.md (the GitHub-facing project guide). Two files with the same name
# and different audiences is how you end up editing the wrong one.
GUIDE_FILE="$DOCS_DIR/DESKTOP-GUIDE.md"

# The IPC call that opens DMS's own searchable cheatsheet (the SUPER+/ one).
# If a DMS update renames this, it is the only line here that needs changing --
# test by hand with: dms ipc call keybinds toggle mangowc
CHEATSHEET_CMD=(dms ipc call keybinds toggle mangowc)

die() { printf '%s\n' "$*" >&2; exit 1; }

[[ -r "$CONFIG" ]]    || die "docs-hub: cannot read $CONFIG"
[[ -r "$KEYS_FILE" ]] || die "docs-hub: cannot read $KEYS_FILE"

# ---------------------------------------------------------------------------
# render_table
#   Walks keys.tsv, resolves each key against config.conf, prints the grouped
#   table. All the real work is one awk pass so we read config.conf once.
# ---------------------------------------------------------------------------
render_table() {
    awk -v config="$CONFIG" '
    function norm(s) {
        gsub(/[ \t]/, "", s)
        return toupper(s)
    }
    function trim(s) {
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        return s
    }

    BEGIN {
        # ---- Pass 1: index config.conf -> normalised "MODS|key" -----------
        comment = ""
        while ((getline line < config) > 0) {
            if (line ~ /^[ \t]*#/) {
                c = line
                sub(/^[ \t]*#[ \t]?/, "", c)
                comment = c
                continue
            }
            if (line ~ /^[ \t]*$/) { comment = ""; continue }
            if (line !~ /^[ \t]*bind[ \t]*=/) { comment = ""; continue }

            b = line
            sub(/^[ \t]*bind[ \t]*=[ \t]*/, "", b)
            n = split(b, part, ",")
            if (n < 2) { comment = ""; continue }

            k = norm(part[1]) "|" trim(part[2])

            # first bind wins, exactly like mango
            if (!(k in desc)) {
                desc[k] = comment
                # command = everything after the 2nd comma
                cmd = ""
                for (i = 3; i <= n; i++) cmd = cmd (i > 3 ? "," : "") part[i]
                command[k] = trim(cmd)
            }
            comment = ""
        }
        close(config)
        missing = 0
    }

    # ---- Pass 2: walk keys.tsv (stdin) --------------------------------------
    /^[ \t]*#/  { next }
    /^[ \t]*$/  { next }

    /^[ \t]*=/ {
        section = $0
        sub(/^[ \t]*=[ \t]*/, "", section)
        printf "\n  \033[1;36m%s\033[0m\n", section
        next
    }

    {
        # optional TAB-separated display override
        tabpos = index($0, "\t")
        if (tabpos > 0) {
            keyspec = substr($0, 1, tabpos - 1)
            label   = trim(substr($0, tabpos + 1))
        } else {
            keyspec = $0
            label   = ""
        }
        keyspec = trim(keyspec)

        n = split(keyspec, part, ",")
        if (n < 2) next
        k = norm(part[1]) "|" trim(part[2])

        shown = (label != "") ? label : keyspec
        # tidy up the raw form for display: single space after the comma
        if (label == "") {
            shown = trim(part[1]) ", " trim(part[2])
            gsub(/[ \t]+\+/, "+", shown); gsub(/\+[ \t]+/, "+", shown)
            gsub(/[ \t]+,/, ",", shown)
        }

        if (k in desc) {
            d = desc[k]
            if (d == "") d = "(no description -- add a comment above this bind in config.conf)"
            printf "    \033[1;37m%-26s\033[0m %s\n", shown, d
        } else {
            printf "    \033[1;31m%-26s MISSING -- no such bind in config.conf\033[0m\n", shown
            missing++
        }
    }

    END {
        if (missing > 0) {
            printf "\n  \033[1;31m%d key(s) in keys.tsv no longer exist in config.conf.\033[0m\n", missing
            exit 3
        }
    }
    ' < "$KEYS_FILE"
}

# ---------------------------------------------------------------------------
# check -- non-interactive validation, for post-update-health.sh
# ---------------------------------------------------------------------------
do_check() {
    local out rc
    out="$(render_table)"; rc=$?
    if [[ $rc -eq 3 ]]; then
        printf '%s\n' "$out" | grep -a "MISSING" >&2
        echo "docs-hub: keys.tsv is STALE (see above)" >&2
        return 1
    fi
    local n
    n=$(grep -acE '^[[:space:]]*[^#=[:space:]]' "$KEYS_FILE")
    echo "docs-hub: OK -- $n curated keys, all resolve against config.conf"

    # The command list goes stale the same way the key table does: a script gets
    # renamed or loses its "# CMD:" lines and the view quietly shows MISSING.
    # Report it here too, so post-update-health.sh catches it. A missing REPO
    # script is NOT counted -- not having the clone on this machine is normal and
    # is explained in the view itself, not a defect in the list.
    local bad=0 lines=0 e p name
    for e in "${COMMANDS[@]}"; do
        case "$e" in "="*|"cd:") continue ;; repo:*) continue ;; esac
        name="$(basename "${e#*:}")"
        p="$(cmd_path "$e")" || continue
        if [ ! -f "$p" ]; then
            echo "docs-hub: command MISSING -- $name is listed but not installed" >&2; bad=1
        elif [ -z "$(cmd_lines "$p")" ]; then
            echo "docs-hub: command MISSING -- $name has no '# CMD:' line" >&2; bad=1
        else
            lines=$(( lines + $(cmd_lines "$p" | wc -l) ))
        fi
    done
    if [ "$bad" -eq 1 ]; then
        echo "docs-hub: the command list is STALE (see above)" >&2
        return 1
    fi
    echo "docs-hub: OK -- $lines command line(s) across the installed scripts"
    return 0
}

# -R  keep the colour escapes we print
# -F  don't page at all if the view fits on one screen
#
# DO NOT ADD -X BACK. It suppresses the alternate-screen teardown, so a view's
# text stayed on the terminal after you quit it -- open the same view twice and
# you had two copies stacked in your scrollback. Without it, a view that pages
# is cleared on quit and you land back on the menu with a clean screen.
#
# -X used to be paired with -F for a reason: on less older than ~590, quitting
# immediately under -F still tore down the alternate screen, which ERASED short
# content instead of leaving it visible. less 704 (what CachyOS ships) doesn't
# enter the alternate screen at all when -F quits, so short views survive and
# long ones still clear. Both cases verified before this line was changed.
pager() {
    if [[ -t 1 ]]; then less -R -F; else cat; fi
}

# Set by hub() while it is driving, so the navigation hint can tell the truth:
# q returns you to the menu when you arrived from it, but quits outright when
# you ran `docs-hub.sh keys` / `guide` straight from a terminal.
IN_HUB=0

# One line of "how do I get out of here", printed at the TOP AND BOTTOM of every
# paged view. Both ends earn their keep: less opens at the top, but the guide is
# longer than a screen, so by the time you have read to the end the top hint is
# long gone -- and the end is exactly where someone stops and wonders what now.
nav_hint() {
    if [[ $IN_HUB -eq 1 ]]; then
        echo "  Press q to go back to the menu."
    else
        echo "  Press q to quit."
    fi
}

show_keys() {
    { echo
      echo "  KEYBOARD SHORTCUTS"
      echo "  Descriptions come live from config.conf."
      nav_hint
      render_table
      echo
      nav_hint
      echo
    } | pager
}

# ---------------------------------------------------------------------------
# find_repo -- locate the DankMango clone (install.sh & friends live there, not here)
#
# This script is installed into ~/.config/mango/scripts, which is NOT inside the
# clone, so the three lifecycle scripts have to be found. In order of trust:
#   1. $DANKMANGO_REPO, if it points at a real clone (override / testing hook)
#   2. the install manifest's .dankmango.repoDir -- written by install.sh and
#      refreshed on every install/update run, so it survives the folder being moved
#   3. the handful of places people actually clone things into
#   4. a depth-limited search of $HOME, skipping dotfile dirs (last resort; a v1-era
#      manifest predates repoDir, so this is the path those installs take)
# A candidate only counts if all three scripts are in it -- a stray empty folder
# called "DankMango" must not win over the real clone further down the list.
# ---------------------------------------------------------------------------
find_repo() {
    local m c
    _is_repo() { [[ -f "$1/install.sh" && -f "$1/update.sh" && -f "$1/uninstall.sh" ]]; }

    if [[ -n "${DANKMANGO_REPO:-}" ]] && _is_repo "$DANKMANGO_REPO"; then
        printf '%s\n' "$DANKMANGO_REPO"; return 0
    fi
    m="${XDG_STATE_HOME:-$HOME/.local/state}/dankmango/manifest.json"
    if [[ -r "$m" ]] && command -v jq >/dev/null 2>&1; then
        c="$(jq -r '.dankmango.repoDir // empty' "$m" 2>/dev/null)"
        if [[ -n "$c" ]] && _is_repo "$c"; then printf '%s\n' "$c"; return 0; fi
    fi
    for c in "$HOME/DankMango" "$HOME/Projects/DankMango" "$HOME/projects/DankMango" \
             "$HOME/git/DankMango" "$HOME/src/DankMango" "$HOME/Documents/DankMango" \
             "$HOME/Downloads/DankMango"; do
        if _is_repo "$c"; then printf '%s\n' "$c"; return 0; fi
    done
    while IFS= read -r c; do
        c="$(dirname "$c")"
        if _is_repo "$c"; then printf '%s\n' "$c"; return 0; fi
    done < <(find "$HOME" -maxdepth 4 -name '.*' -prune -o -name 'install.sh' -print 2>/dev/null)
    return 1
}

# ---------------------------------------------------------------------------
# COMMANDS -- the terminal side of DankMango
#
# A FLAT, COPY-PASTEABLE REFERENCE, NOT A MENU
#   Every entry is a real command line you can select and paste into a terminal
#   as-is, with its description under it. There is nothing to drill into: the
#   thing you came for is on screen. (`docs-hub.sh flags NAME` still opens one
#   script's full --help when you want the long version.)
#
# WHERE THE TEXT COMES FROM -- THE SAME RULE AS THE KEY TABLE
#   This list stores WHICH scripts to show and in what order. It stores no
#   command lines and no descriptions. Both are read live from each script's own
#   `# CMD: <command> :: <description>` header lines. To change what a command
#   says here, or to add one, edit that script -- the text is not in here.
#   A listed script with no CMD lines renders as MISSING rather than vanishing,
#   the same way keys.tsv reports a bind that no longer exists.
#
# Entries are "=Section", "cd:" (the one line this file does own -- see below),
# or a script path relative to REPO or to this script's own directory.
# ---------------------------------------------------------------------------
COMMANDS=(
    "=SETTING UP AND UPDATING"
    "cd:"
    "repo:update.sh"
    "repo:install.sh"
    "repo:uninstall.sh"
    "=CHECKING AND FIXING"
    "here:post-update-health.sh"
    "here:apply-patches.sh"
    "here:border-color-healthcheck.sh"
    "=DESKTOP TOOLS   (mostly run for you by keybinds and watchers)"
    "here:monitor-watcher.sh"
    "here:set-monitor-layout.sh"
    "here:generate-tagrules.sh"
    "here:sddm-palette-sync.sh"
    "here:screenshot.sh"
    "here:alt-switcher.sh"
    "here:docs-hub.sh"
)

# cmd_path ENTRY -> absolute path, or non-zero if we can't resolve it.
# Only the repo: ones can fail (the clone may be missing); here: ones sit beside
# this script, which is by definition installed if this script is running.
cmd_path() {
    local e="$1"
    case "$e" in
        here:*) printf '%s/%s\n' "$SCRIPT_DIR" "${e#here:}" ;;
        repo:*) local r; r="$(find_repo)" || return 1
                printf '%s/%s\n' "$r" "${e#repo:}" ;;
    esac
}

# cmd_lines PATH -> that script's own "command :: description" lines, verbatim.
# Anchored to a line starting "# CMD: " so the explanatory comment above them
# (which also contains the word CMD) can never match.
cmd_lines() {
    [ -r "$1" ] || return 1
    sed -n 's/^# CMD: //p' "$1"
}

# one_entry COMMAND DESCRIPTION -- the copy-pasteable pair.
#
# The command sits alone on its line, never wrapped and never prefixed with a
# $ or a bullet, because anything else on that line ends up in the paste buffer
# when you drag-select it. The description is folded underneath instead of being
# aligned to the right of the command: once "~/.config/mango/scripts/..." is in
# front, an aligned column would push past 80 columns and wrap the command.
one_entry() {
    printf '    \033[1;37m%s\033[0m\n' "$1"
    # printf '%s\n' (not '%s'): fold passes the missing final newline straight
    # through, and without it the next entry's command lands on this line.
    # `fold -s` breaks AFTER the space, so strip the trailing one it leaves.
    printf '%s\n' "$2" | fold -s -w 66 | sed -e 's/[[:space:]]*$//' -e 's/^/        /'
}

render_commands() {
    local e p line cmd desc repo
    for e in "${COMMANDS[@]}"; do
        case "$e" in
            "="*)  printf '\n  \033[1;36m%s\033[0m\n\n' "${e#=}"; continue ;;
            "cd:") # The only line this file authors, because no script owns it:
                   # the lifecycle commands are run from the clone, and the path
                   # is per-machine. find_repo already knows where that is.
                   if repo="$(find_repo)"; then
                       one_entry "cd $repo" "go here first -- the three commands below are run from inside your DankMango folder"
                       echo
                   else
                       printf '    \033[1;31m%s\033[0m\n' "(your DankMango folder wasn't found -- see the note above)"
                   fi
                   continue ;;
        esac
        if ! p="$(cmd_path "$e")" || [ ! -f "$p" ]; then
            printf '    \033[1;31m%-28s MISSING -- not installed here\033[0m\n' "$(basename "${e#*:}")"
            continue
        fi
        if [ -z "$(cmd_lines "$p")" ]; then
            printf '    \033[1;31m%-28s MISSING -- no "# CMD:" line in %s\033[0m\n' "$(basename "${e#*:}")" "$p"
            continue
        fi
        while IFS= read -r line; do
            cmd="${line%% :: *}"; desc="${line#* :: }"
            one_entry "$cmd" "$desc"
        done < <(cmd_lines "$p")
    done
}

# show_one NAME -- the full --help for a single command.
#
# Run with `bash` rather than executed, so a lost exec bit doesn't break the
# view. Every script listed above answers --help before it does anything else --
# no manifest, no network, no sudo, and (for the two health checks) without
# running the check -- so opening this can never have a side effect.
show_one() {
    local want="$1" e p
    for e in "${COMMANDS[@]}"; do
        case "$e" in "="*) continue ;; esac
        [ "$(basename "${e#*:}")" = "$want" ] || continue
        p="$(cmd_path "$e")" && [ -f "$p" ] || { echo "docs-hub: $want is not installed here" >&2; return 1; }
        { nav_hint
          printf '\n\033[1;36m  %s\033[0m\n' "$want"
          echo
          bash "$p" --help 2>&1 | sed 's/^/  /'
          echo
          nav_hint
          echo
        } | pager
        return 0
    done
    echo "docs-hub: no such command: $want" >&2
    return 1
}

# The commands view. A plain paged reference, deliberately NOT an fzf picker:
# this is something you read and copy out of, and fzf's filter box would put the
# list behind a keystroke. `keys` is rendered the same way for the same reason.
show_flags() {
    local repo_missing=0
    find_repo >/dev/null 2>&1 || repo_missing=1
    { nav_hint
      echo
      echo "  DANKMANGO COMMANDS"
      echo "  Every line below can be copied straight into a terminal."
      [ "$repo_missing" = 1 ] && {
          echo
          echo "  NOTE: your DankMango folder (the cloned one, with install.sh in"
          echo "  it) wasn't found, so the setup/update commands can't be shown."
          echo "  Point the hub at it once with:"
          echo "      echo 'export DANKMANGO_REPO=/path/to/DankMango' >> ~/.zprofile"
      }
      render_commands
      echo
      echo "  Any of these takes --help for the full detail, e.g."
      echo "      ~/.config/mango/scripts/apply-patches.sh --help"
      echo
      nav_hint
      echo
    } | pager
}

show_guide() {
    [[ -r "$GUIDE_FILE" ]] || { echo "docs-hub: $GUIDE_FILE not found" >&2; return 1; }
    # The guide carries its own title, so this only adds the hint around it.
    { nav_hint
      echo
      cat "$GUIDE_FILE"
      echo
      nav_hint
      echo
    } | pager
}

# ---------------------------------------------------------------------------
# The interactive hub
# ---------------------------------------------------------------------------
hub() {
    IN_HUB=1
    while :; do
        local choice
        if command -v fzf >/dev/null 2>&1; then
            choice=$(printf '%s\n' \
                "Keyboard shortcuts        the curated list, grouped by what you are doing" \
                "Look up one key           type to filter every shortcut" \
                "Read the guide            how this desktop works, in plain English" \
                "Commands you can type     every DankMango command, and what its options do" \
                "Search all shortcuts      open the full DMS cheatsheet (same as SUPER+/)" \
                "Quit" \
                | fzf --prompt='help > ' --height=100% --reverse \
                      --header=$'MangoWM help hub\nEnter to choose, Esc to quit' \
                      --no-info 2>/dev/null) || return 0
        else
            # No fzf, so no header line -- print the same hint by hand, in the
            # form that actually applies to a numbered `select` menu.
            echo; echo "  MangoWM help hub"
            echo "  Type a number and press Enter. Pick Quit to leave."
            select choice in "Keyboard shortcuts" "Look up one key" "Read the guide" "Commands you can type" "Search all shortcuts" "Quit"; do break; done
            [[ -z "${choice:-}" ]] && return 0
        fi

        case "$choice" in
            Keyboard*) show_keys ;;
            Look*)     lookup ;;
            Read*)     show_guide ;;
            Commands*) show_flags ;;
            Search*)   "${CHEATSHEET_CMD[@]}" >/dev/null 2>&1 \
                         || echo "docs-hub: could not reach DMS (is the shell running?)" >&2
                       return 0 ;;
            Quit|"")   return 0 ;;
        esac
    done
}

lookup() {
    command -v fzf >/dev/null 2>&1 || { show_keys; return; }
    # strip colour and section headers, keep only the key rows
    render_table \
      | sed -e 's/\x1b\[[0-9;]*m//g' \
      | grep -aE '^    \S' \
      | fzf --prompt='key > ' --height=100% --reverse \
            --header='Type any part of a key or its description. Esc to go back.' \
            --no-info >/dev/null 2>&1
}

# --help prints the header block above -- same idiom as every other DankMango
# script, so the command menu can shell out to this one too.
self_help() { awk 'NR>2 && !/^#/{exit} NR>2 && sub(/^#[ ]?/,"")' "$0"; }

case "${1:-hub}" in
    -h|--help) self_help ;;
    hub|"")  hub ;;
    keys)    show_keys ;;
    guide)   show_guide ;;
    flags|commands)
             if [ -n "${2:-}" ]; then show_one "$2"; else show_flags; fi ;;
    check)   do_check ;;
    *)       die "usage: docs-hub.sh [hub|keys|guide|flags [NAME]|check]" ;;
esac
