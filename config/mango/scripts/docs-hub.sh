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
#   docs-hub.sh flags      print install/update/uninstall's own --help output
#   docs-hub.sh check      validate keys.tsv against config.conf; non-zero if stale
#
# THE SAME IDEA APPLIES TO `flags`
#   It stores no flag list either. It shells out to `install.sh --help`,
#   `update.sh --help` and `uninstall.sh --help` in your clone, each of which
#   prints its own header comment. A flag added to any of those three shows up
#   here with no edit to this file. To change what a flag's description says,
#   edit that script's header -- the text is not in here.
#
# ---------------------------------------------------------------------------
set -uo pipefail

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
    return 0
}

pager() {
    if [[ -t 1 ]]; then less -R -X -F; else cat; fi
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
# show_flags -- the command-line flags of install/update/uninstall
#
# A thin wrapper on purpose: every word below the headings comes from the three
# scripts' own --help. Each is run with bash (not executed) so a lost exec bit
# doesn't break the view, and each prints its header before touching anything
# else -- no manifest, no network, no sudo -- so this is safe to open any time.
# ---------------------------------------------------------------------------
show_flags() {
    local repo s
    if ! repo="$(find_repo)"; then
        { echo
          echo "  COMMAND-LINE FLAGS"
          echo
          echo "  Couldn't find your DankMango folder (the one you cloned, with"
          echo "  install.sh in it), so there is nothing to read the flags out of."
          echo
          echo "  Nothing is broken -- this view just needs to know where that"
          echo "  folder is. Either open a terminal in it and run:"
          echo "      ./install.sh --help"
          echo "      ./update.sh --help"
          echo "      ./uninstall.sh --help"
          echo "  or tell this hub where it lives, once:"
          echo "      echo 'export DANKMANGO_REPO=/path/to/DankMango' >> ~/.zprofile"
          echo "  then log out and back in."
          echo
          nav_hint
          echo
        } | pager
        return 1
    fi
    { nav_hint
      echo
      echo "  COMMAND-LINE FLAGS"
      echo "  Read live from the scripts in $repo."
      echo "  These are things you type in a terminal, not keyboard shortcuts."
      for s in install.sh update.sh uninstall.sh; do
          printf '\n\033[1;36m  ==== %s ====\033[0m\n\n' "$s"
          bash "$repo/$s" --help 2>&1 | sed 's/^/  /'
      done
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
                "Command-line flags        what install / update / uninstall can be told to do" \
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
            select choice in "Keyboard shortcuts" "Look up one key" "Read the guide" "Command-line flags" "Search all shortcuts" "Quit"; do break; done
            [[ -z "${choice:-}" ]] && return 0
        fi

        case "$choice" in
            Keyboard*) show_keys ;;
            Look*)     lookup ;;
            Read*)     show_guide ;;
            Command*)  show_flags ;;
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

case "${1:-hub}" in
    hub|"")  hub ;;
    keys)    show_keys ;;
    guide)   show_guide ;;
    flags)   show_flags ;;
    check)   do_check ;;
    *)       die "usage: docs-hub.sh [hub|keys|guide|flags|check]" ;;
esac
