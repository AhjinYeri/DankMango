#!/usr/bin/env bash
#
# =============================================================================
#  DankMango updater
# =============================================================================
#  Applies ONLY what changed since your last update, instead of re-running the
#  whole installer. It works out the delta from the install manifest's recorded
#  lastAppliedCommit -> the repo's current HEAD, then:
#    * takes a named snapper snapshot first, so a bad update is a rollback away —
#      only on Btrfs systems that already have snapper set up; skipped with a note
#      on any machine that doesn't, and never allowed to block the update
#    * installs any newly-added packages (--needed, so nothing reinstalls)
#    * re-copies changed/added config + script files (backing up first, and
#      NOT clobbering a file you hand-edited since install without asking)
#    * retires files DankMango removed from the repo (backed up, only if ours)
#    * runs any pending idempotent migrations for live-state changes
#      (settings.json / session.json) that a plain file-copy can't express
#    * stamps the new commit into the manifest ONLY after everything succeeds
#
#  Shares all its copy/manifest/package machinery with install.sh via
#  lib/common.sh, so the two never drift.
#
#  Usage:
#     bash update.sh              # apply pending updates (asks before edits it might lose)
#     bash update.sh --dry-run    # show the full plan; change nothing.  RUN THIS FIRST.
#     bash update.sh --manifest F # read/write a different manifest (for testing)
#
#  When it can't safely compute the delta (interrupted last run, rebased/force-
#  pushed history, a dirty repo tree) it says so and tells you to re-run install.sh
#  rather than guessing. A clone that has diverged from GitHub (the state a failed
#  `git pull` leaves behind) gets its own plain-English walkthrough instead.
# =============================================================================

set -uo pipefail

# CMD lines are what docs-hub.sh's command list shows: a real, runnable command
# and a short description, separated by " :: ". They live here, next to the code
# that implements them, so the hub stores no copy of its own. Add a line when you
# add a flag worth showing; the fuller explanation stays in the Usage block above.
# CMD: bash update.sh --dry-run :: show exactly what an update would change - changes nothing. Do this first.
# CMD: bash update.sh :: apply everything that changed since your last update

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_DIR/lib/common.sh"   # pretty output, sys_copy/user_copy, manifest_*, arrays, route_dest, file_hash

DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        --manifest) MANIFEST="${2:-}"; [ -n "$MANIFEST" ] || die "--manifest needs a path"
                    MANIFEST_DIR="$(dirname "$MANIFEST")"; shift 2 ;;
        # Prints the header block above (the only copy of the flag list). Was a
        # hardcoded `sed -n '3,34p'`, which silently started leaking source code
        # into the help as the header grew; this stops at the first non-comment line.
        -h|--help)  awk 'NR>2 && !/^#/{exit} NR>2 && sub(/^#[ ]?/,"")' "$0"; exit 0 ;;
        *)          die "unknown argument: $1  (try --help)" ;;
    esac
done

# Report buckets, printed together at the end (same spirit as install/uninstall).
UPDATED=(); PKGS_ADDED=(); MIGRATED=(); RETIRED=(); LEFT=(); MANUAL=()
# How many file copies FAILED this run. Separate from WARNINGS on purpose: warnings
# are routine here (a Zen profile that doesn't exist yet, a snapshot that couldn't be
# taken) and must not block the run, whereas a failed copy means the delta was NOT
# fully applied. Stage 6 refuses to stamp lastAppliedCommit while this is non-zero,
# so the unapplied files stay in the next run's delta instead of being skipped
# forever — an update only re-copies what changed in ITS commit range, so a file
# written off as applied is never revisited.
COPY_FAILED=0
# The login theme is reinstalled as a WHOLE TREE, so however many of its files changed
# in this delta, the installer runs once. Guards apply_change's dankmango-sddm-theme arm.
SDDM_THEME_REINSTALLED=0
# Same idea, per plugin: a DMS plugin is deployed as a whole DIRECTORY, so a delta that
# touches several of its files is still ONE deployment. Keyed by plugin id (the "id" from
# its plugin.json), set the first time apply_change deploys it. Guards the `plugin` arm.
declare -A PLUGIN_DEPLOYED=()

# Prompts must read the TERMINAL, not stdin: we never loop over a pipe while
# prompting (the git delta is collected into an array first), but be defensive
# anyway — this is the bug that bit uninstall.sh.
ask_tty() {  # ask_tty "question" -> 0=yes
    local ans
    [ "$DRY_RUN" = 1 ] && { info "(dry-run) would ask: $1"; return 1; }
    [ -r /dev/tty ] || { warn "no terminal to ask '$1' — assuming NO"; return 1; }
    printf '    %s [y/N] ' "$1" > /dev/tty; read -r ans < /dev/tty || return 1
    case "$ans" in [yY]*) return 0 ;; *) return 1 ;; esac
}

echo "==================================================================="
echo " DankMango updater   ($STAMP)"
echo " repo: $REPO_DIR"
[ "$DRY_RUN" = 1 ] && echo " MODE: DRY RUN — nothing will be changed"
echo "==================================================================="

# =============================================================================
# Migrations registry — live-state changes a file-copy can't express
# =============================================================================
# Each migration has an id, a one-line description, and a migrate_<id> function that
# is IDEMPOTENT and only ever ADDS/CLEANS what is unambiguously DankMango's, never
# overwriting user customisation. A migration runs iff its id is not already in the
# manifest's migrationsApplied[]. Order matters: list oldest first.
MIGRATIONS=(
    "reseed-pins-installed-only:remove dead taskbar/dock pins whose package isn't installed (the pin-seed fix, for installs made before it)"
    "zen-userchrome-bridge:write the Zen userChrome.css/user.js bridge so matugen's zen.css is actually loaded (Zen theming never worked before this)"
    "strip-dead-floatsize-execonce:remove the dead 'exec-once = .../dp2-floatsize.sh' autostart left in a hand-edited config.conf after the float helper was retired"
    "sddm-dankmango-theme:install DankMango's own login theme (replaces the sddm-astronaut-theme AUR package) — deploys it, does NOT switch the login screen over"
    "register-shipped-plugins:register plugins DankMango has started shipping since your install (e.g. the first-run welcome panel) — only ADDS missing entries, never changes ones you already have"
    "seed-active-preset:activate the 'Default' desktop preset so the new preset switcher has something to mark as current (Default adds nothing, so your desktop does not change)"
)

# v1.x installs got their login screen from the sddm-astronaut-theme AUR package,
# customised through ~/.config/sddm-astronaut-japanese/apply.sh. v2 ships DankMango's
# own theme instead, which is what makes the login screen able to follow the wallpaper.
#
# THIS MIGRATION DELIBERATELY DOES NOT FLIP Current=. That's not timidity, it's the
# one irreversible-ish failure mode in the project: a bad Current= is discovered at the
# next reboot, at a login screen, with no session to fix it from. install.sh gates the
# same step behind DANKMANGO_SDDM_SET_CURRENT for identical reasons. An updater that
# runs semi-unattended, with none of the TTY-escape-hatch briefing a fresh install
# gives you, is the last place that decision should be made for someone.
#
# So this leaves the machine in the one state that is safe and complete: the new theme
# fully installed and syncing, the old one still serving the login screen, and the
# switch a one-liner in the report. Nothing is uninstalled either — the astronaut
# package and its config dir are still what the CURRENT login screen is built from, and
# pulling them out from under an active greeter is how you get a black screen at boot.
#
# Idempotent: the theme's install.sh is `install -o root ...` throughout, so re-running
# it is a no-op-with-the-same-result; and if the tree is already installed AND recorded
# in the manifest (i.e. install.sh got there first), this returns immediately.
migrate_sddm-dankmango-theme() {
    local src="$REPO_DIR/system/sddm/themes/$SDDM_THEME_ID"
    [ -d "$src" ] || { info "  repo ships no login theme at system/sddm/themes/$SDDM_THEME_ID — nothing to do"; return 0; }

    # Already done by an install.sh run? Then there is nothing for the migration to add.
    if [ -d "$SDDM_THEME_DEST" ] && \
       jq -e --arg d "$SDDM_THEME_DEST" '[ .systemChanges[]? | select(.type=="owned-tree" and (.detail.dir // .key)==$d) ] | length > 0' "$MANIFEST" >/dev/null 2>&1; then
        info "  already installed at $SDDM_THEME_DEST and recorded — nothing to do"
        return 0
    fi

    # What is serving the login screen right now? Purely informational, but it is the
    # difference between "you're still on the old theme" and "you have no theme set".
    local cur="" cur_file="" cur_tsv
    if cur_tsv="$(sddm_current_theme)"; then
        IFS=$'\t' read -r cur cur_file <<<"$cur_tsv"
        info "  current login theme: $cur  (from $cur_file)"
    else
        info "  no Current= set anywhere — SDDM is on its built-in default"
    fi
    if pacman -Qi sddm-astronaut-theme >/dev/null 2>&1; then
        info "  sddm-astronaut-theme (AUR) is installed — leaving it alone; it is still serving your login screen"
    fi

    [ "$DRY_RUN" = 1 ] && { info "  (dry-run) would install the theme to $SDDM_THEME_DEST via sudo"; return 0; }

    if ! sddm_theme_install; then
        warn "  theme install failed — re-run by hand: sudo $src/install.sh"
        return 1
    fi
    ok "  installed $SDDM_THEME_DEST (root-owned code, user-owned palette leaves)"

    # Same record install.sh writes, so uninstall.sh treats it identically.
    manifest_add_change owned-tree "$CUR_STAGE" "$SDDM_THEME_DEST" \
        "$(jq -nc --arg d "$SDDM_THEME_DEST" --arg id "$SDDM_THEME_ID" \
            '{dir:$d, scope:"system", themeId:$id, note:"root-owned theme tree; holds the user-writable theme.conf.user + wallpaper-[ab].jpg leaves"}')" \
        "sudo rm -rf $SDDM_THEME_DEST"

    # Prime the palette now rather than waiting for the next wallpaper change.
    local sync="$HOME/.config/mango/scripts/sddm-palette-sync.sh"
    [ -x "$sync" ] && "$sync" >/dev/null 2>&1 && info "  login palette synced from your current wallpaper"

    MANUAL+=("SDDM: the new login theme is installed but NOT active. Preview: sddm-greeter-qt6 --test-mode --theme $SDDM_THEME_DEST — then switch with: sudo sh -c 'printf \"[Theme]\\nCurrent=$SDDM_THEME_ID\\n\" > $SDDM_THEME_CONF' (keep a TTY open on the first reboot)")
    if [ -n "$cur" ]; then
        MANUAL+=("SDDM: once you have switched and rebooted happily, the old theme can go: sudo pacman -Rns sddm-astronaut-theme && rm -rf ~/.config/sddm-astronaut-japanese")
    fi
    return 0
}

# Every install made before this migration existed has a themed zen.css sitting unused
# on disk, because nothing ever wrote the userChrome.css that imports it. This applies
# the bridge to the existing profile. Marker-guarded and idempotent: an existing
# userChrome.css keeps everything outside the managed block. If Zen has never been
# launched there's no profile to write to yet — the migration reports that and returns
# non-zero so it is NOT recorded as applied, and a later update.sh retries it.
migrate_zen-userchrome-bridge() {
    zen_apply_theming
}

# The existing-install analog of the pin-seeding fix. Fresh installs now pin only
# installed apps; an OLDER install may already carry dead pins (e.g. spotify-launcher
# that failed to install). This removes ONLY pins that are BOTH ours (in
# SEED_PINNED_APPS) AND whose backing package is absent — user-added pins and working
# pins are untouched. Idempotent: re-running finds nothing to remove.
migrate_reseed-pins-installed-only() {
    local sess="${XDG_STATE_HOME:-$HOME/.local/state}/DankMaterialShell/session.json"
    [ -f "$sess" ] || { info "  no session.json — nothing to clean"; return 0; }
    have jq || { warn "  jq unavailable — skipping pin cleanup"; return 1; }
    local dead=()
    local a
    for a in "${SEED_PINNED_APPS[@]}"; do
        pacman -Qi "${PIN_PKG[$a]:-$a}" >/dev/null 2>&1 || dead+=("$a")
    done
    if [ "${#dead[@]}" -eq 0 ]; then info "  no dead pins to remove"; return 0; fi
    # Which of those dead apps are ACTUALLY pinned right now? (truly idempotent: if none
    # are present, we neither rewrite the file nor make a backup.)
    local dead_json present
    dead_json="$(printf '%s\n' "${dead[@]}" | jq -R . | jq -s .)"
    present="$(jq -r --argjson d "$dead_json" '
        [ ((.barPinnedApps // []) + (.pinnedApps // []))[] | select(. as $x | $d | index($x)) ] | unique | join(" ")
    ' "$sess" 2>/dev/null)"
    if [ -z "$present" ]; then info "  no dead pins present in session.json — nothing to change"; return 0; fi
    info "  dead pins present (package not installed): $present"
    [ "$DRY_RUN" = 1 ] && return 0
    local tmp; tmp="$(mktemp)"
    if jq --argjson d "$dead_json" '
            .barPinnedApps = ((.barPinnedApps // []) | map(select(. as $x | ($d | index($x)) | not)))
          | .pinnedApps    = ((.pinnedApps    // []) | map(select(. as $x | ($d | index($x)) | not)))
        ' "$sess" > "$tmp" && [ -s "$tmp" ]; then
        cp -a "$sess" "$sess.bak-$STAMP"; cat "$tmp" > "$sess"
        prune_file_backups "$sess"
        ok "  removed dead pins: $present (backup: $sess.bak-$STAMP)"
    else
        warn "  couldn't edit session.json — left as-is"
    fi
    rm -f "$tmp"
}

# Float mode was pulled from the repo: dp2-floatsize.sh is retired by stage 4, but a user
# who hand-edited config.conf keeps their file (edit-detection), so their old
# `exec-once = ~/.config/mango/scripts/dp2-floatsize.sh` autostart survives and now points at
# a removed script. mango just fails to spawn it (fork-and-forget, no error/dialog), so it's
# harmless — but stale. This strips ONLY that active autostart line, leaving all surrounding
# lines/comments/formatting untouched. The regex is anchored to an uncommented `exec-once`
# assignment, so commented refs and the example `spawn` bind elsewhere are never matched.
# Idempotent: if the line isn't there (fresh install, already-migrated, never had float) it
# reports nothing-to-do and returns 0.
migrate_strip-dead-floatsize-execonce() {
    local cfg="$HOME/.config/mango/config.conf"
    [ -f "$cfg" ] || { info "  no config.conf — nothing to do"; return 0; }
    local re='^[[:space:]]*exec-once[[:space:]]*=.*dp2-floatsize\.sh'
    if ! grep -qE "$re" "$cfg"; then
        info "  no dead dp2-floatsize.sh exec-once line — nothing to do"; return 0
    fi
    local n; n="$(grep -cE "$re" "$cfg")"
    info "  found $n dead exec-once autostart line(s) pointing at the retired dp2-floatsize.sh"
    [ "$DRY_RUN" = 1 ] && return 0
    local tmp; tmp="$(mktemp)"
    if grep -vE "$re" "$cfg" > "$tmp" && [ -s "$tmp" ]; then
        cp -a "$cfg" "$cfg.bak-$STAMP"; cat "$tmp" > "$cfg"
        prune_file_backups "$cfg"
        ok "  removed dead dp2-floatsize.sh exec-once line (backup: $cfg.bak-$STAMP)"
    else
        warn "  couldn't rewrite config.conf — left as-is"; rm -f "$tmp"; return 1
    fi
    rm -f "$tmp"
    return 0
}

# A plugin DankMango starts shipping AFTER your install never gets switched on, and the
# failure is completely silent. Stage 4 copies the plugin's files correctly, but the file
# that says "load this plugin" is plugin_settings.json — LIVE STATE, so the `dms-state`
# route refuses to overwrite it and (rightly) says the change belongs in a migration.
# This is that migration. Without it, DMS discovers the plugin and leaves it off, because
# an unregistered id defaults to disabled:
#     PluginService.qml:  isPureDesktop || SettingsData.getPluginSetting(id, "enabled", false)
# and isPureDesktop is false for anything that isn't a pure desktop widget. Found on a
# sandboxed v1.3.0 -> v1.4.0 run, where the welcome panel deployed and then never appeared.
#
# MERGE DIRECTION IS THE WHOLE POINT, and it is NOT install.sh's.
#   install.sh stage 7c uses  jq -s '.[0] * .[1]'  (live * shipped) -> SHIPPED wins.
#   This uses                 jq -s '.[1] * .[0]'  (shipped * live) -> LIVE wins.
# jq's `*` is a recursive merge in which the RIGHT side wins on a conflict, so reusing
# install.sh's order here would walk over the user's own choices — measured, not assumed:
# with live {"monitorMode":{"enabled":false}} and shipped {"monitorMode":{"enabled":true}},
# install.sh's order returns enabled:true and flips a plugin the user deliberately switched
# off back on. An installer setting up a fresh machine may do that; an updater may not.
# Live-wins still registers everything new, because a brand-new id has nothing to collide
# with. (Nested values like audioToggle's machine-specific outputTargets survive either
# way — `*` recurses rather than replacing the object — but the enabled flag is the case
# that actually differs, so the direction is chosen for that.)
#
# Idempotent: it computes the shipped ids that are MISSING from the live file and does
# nothing at all when that set is empty, so a second run is a no-op rather than a rewrite.
migrate_register-shipped-plugins() {
    local tgt="$HOME/.config/DankMaterialShell/plugin_settings.json"
    local src="$REPO_DIR/config/dms/DankMaterialShell/plugin_settings.json"
    [ -f "$src" ] || { info "  the repo ships no plugin_settings.json — nothing to do"; return 0; }
    have jq || { warn "  jq unavailable — can't merge plugin registrations"; return 1; }

    # No live file at all (a DMS config wiped by hand, say): the shipped one IS the answer,
    # and there is nothing of the user's to preserve.
    if [ ! -f "$tgt" ]; then
        [ "$DRY_RUN" = 1 ] && { info "  (dry-run) would install the shipped plugin_settings.json"; return 0; }
        mkdir -p "$(dirname "$tgt")"
        cp -a "$src" "$tgt" && ok "  installed plugin_settings.json (you had none)"
        return 0
    fi
    # Refuse to touch a file we can't parse rather than replacing it with the shipped copy:
    # hand-broken JSON is still the user's settings, and it is recoverable by hand.
    jq -e . "$tgt" >/dev/null 2>&1 || { warn "  $tgt isn't valid JSON — leaving it alone. Fix it, then re-run."; return 1; }
    jq -e . "$src" >/dev/null 2>&1 || { warn "  the repo's plugin_settings.json isn't valid JSON — skipping"; return 1; }

    local missing
    missing="$(jq -r --slurpfile s "$src" '($s[0] | keys) - keys | join(" ")' "$tgt" 2>/dev/null)"
    if [ -z "$missing" ]; then
        info "  every plugin DankMango ships is already registered — nothing to do"; return 0
    fi
    info "  shipped but not registered on this install: $missing"
    [ "$DRY_RUN" = 1 ] && return 0

    local tmp; tmp="$(mktemp)"
    if jq -s '.[1] * .[0]' "$tgt" "$src" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then
        cp -a "$tgt" "$tgt.bak-$STAMP"
        prune_file_backups "$tgt"
        cat "$tmp" > "$tgt"          # cat, not mv: keeps the original file's mode/owner
        rm -f "$tmp"
        ok "  registered: $missing (your existing settings kept; backup: $tgt.bak-$STAMP)"
        MANUAL+=("newly registered plugin(s): $missing — run 'dms restart' to load them")
        return 0
    fi
    rm -f "$tmp"
    warn "  couldn't merge plugin registrations — left $tgt untouched. Add them in DMS Settings -> Plugins."
    return 1
}

# Desktop presets arrived after v1.x. Stage 4 deploys the preset FOLDERS and the new
# Presets plugin correctly, and config.conf grows the source-optional= include — but
# nothing on the copy path creates the ~/.config/mango/active/preset.conf symlink that
# include points at, because a symlink is not a file the repo can ship. install.sh
# seeds it (stage 7f); an existing install never runs that stage again.
#
# Left alone the result is not broken, just half-arrived: the include is OPTIONAL, so
# mango reads a missing target in silence and the desktop behaves exactly as before —
# but the launcher lists the presets with none marked active, and post-update-health.sh
# has a preset to talk about that isn't active. This closes that gap.
#
# It seeds "default", which is an EMPTY fragment. That is the whole reason this is safe
# to do unattended: activating it changes NO setting on the machine. Anything else would
# be an updater altering a running desktop's appearance without being asked.
#
# Idempotent by delegation: seed_active_preset() returns early when the symlink already
# exists, so a user who has already picked a preset (or a second run of this migration)
# is left alone.
migrate_seed-active-preset() {
    [ -d "$HOME/.config/mango/presets/$DEFAULT_PRESET" ] || {
        info "  presets aren't installed on this machine yet — nothing to activate"; return 0; }
    seed_active_preset || return 1
    MANUAL+=("new desktop presets — open the launcher and type 'preset' to switch between them")
    return 0
}

# =============================================================================
# Diverged-branch guard
# =============================================================================
# The one git state that hands a beginner nothing but jargon. `git pull` fetches
# fine, then refuses to merge and prints its wall of pull.rebase / --ff-only hints,
# so the user arrives here with origin/main already downloaded and both sides
# holding commits the other doesn't have. Left alone, update.sh says one of two
# unhelpful things: "already up to date" (HEAD never moved, so the delta is empty),
# or the lastAppliedCommit fallback blaming a force-push and sending them to
# install.sh — which doesn't fix a diverged clone.
#
# Deliberately narrow. It fires ONLY when the branch is both AHEAD of and BEHIND
# its upstream. Ahead-only (local commits, nothing new on GitHub), behind-only (an
# ordinary pending update), detached HEAD, no upstream configured, no remote at
# all — every one of those keeps the existing behaviour untouched. Nothing here
# fetches: it reads the remote-tracking refs already on disk, so the updater stays
# offline-safe and gains no network step. Every git call is silenced, because the
# whole point is that our explanation replaces git's hint-spam rather than joining it.
git_divergence() {  # -> "AHEAD BEHIND UPSTREAM" when diverged; non-zero otherwise
    local up counts ahead behind
    git -C "$REPO_DIR" symbolic-ref -q HEAD >/dev/null 2>&1 || return 1   # detached HEAD
    up="$(git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || return 1
    [ -n "$up" ] || return 1
    counts="$(git -C "$REPO_DIR" rev-list --left-right --count "HEAD...$up" 2>/dev/null)" || return 1
    ahead="${counts%%[[:space:]]*}"; behind="${counts##*[[:space:]]}"
    case "$ahead$behind" in *[!0-9]*|'') return 1 ;; esac
    [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ] || return 1
    printf '%s %s %s\n' "$ahead" "$behind" "$up"
}

# Same contract as post-update-health.sh's failure entries: a complete walkthrough a
# total beginner can follow start to finish, with the optional Claude Code prompt
# clearly secondary. Prints and exits — there's no safe delta to compute from here.
explain_diverged_branch() {  # explain_diverged_branch AHEAD BEHIND UPSTREAM
    local ahead="$1" behind="$2" up="$3" remote branch parent
    remote="${up%%/*}"
    branch="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
    parent="$(dirname "$REPO_DIR")"
    echo
    printf '%s===================================================================%s\n' "$c_red" "$c_off"
    printf ' %sSTOP — your DankMango folder and GitHub have gone out of step%s\n' "$c_red" "$c_off"
    printf '%s===================================================================%s\n' "$c_red" "$c_off"
    cat <<EOF

WHAT HAS HAPPENED

  Your copy of DankMango has $ahead change(s) that GitHub doesn't have, and
  GitHub has $behind change(s) that your copy doesn't. Git calls this a
  "diverged branch": the same project moved on in two directions at once,
  so git stops rather than guess which side wins.

  If you just ran "git pull" and got a block of text mentioning pull.rebase,
  --ff-only, or "Need to specify how to reconcile divergent branches" — that
  was this exact problem, described in git's own language. It was asking you
  to choose a merge strategy. That isn't a decision you need to make here.

  Nothing is broken and nothing has been lost. Your desktop keeps running
  exactly as it is. This is only about the folder you cloned into:
    $REPO_DIR

HOW TO FIX IT YOURSELF

  That folder is only ever meant to be a copy of DankMango, so the fix is to
  throw your side away and take GitHub's. The command for that is
  "git reset --hard", and it cannot be undone: it permanently deletes any
  changes in that folder that aren't on GitHub. So you check what's in there
  FIRST. Steps 1 and 2 are that check, and they are not optional.

  1. Open a terminal (Super+Return — "Super" is the key with the Windows
     logo on it) and go to the folder:
       cd $REPO_DIR

  2. Ask git whether anything of your own is sitting in there:
       git status

     Read the reply before going any further:

     * If it says "nothing to commit, working tree clean", there is nothing
       of yours to lose. Go to step 3.

     * If it lists files under "Changes not staged for commit", "Changes to
       be committed", or "Untracked files", those are YOUR edits and step 4
       WILL DELETE THEM. Do not run step 4 yet. Copy anything you want to
       keep to somewhere outside the folder first, for example:
         cp $REPO_DIR/the-file-you-edited ~/Desktop/
       Then carry on.

     * This only concerns the clone. Your live settings live elsewhere (in
       ~/.config/mango and ~/.config/DankMaterialShell) and nothing in these
       steps touches them.

  3. Only if you have deliberately made your own commits in this folder —
     you would know, because you'd have typed "git commit" yourself — save
     them under a name so they survive:
       git branch my-dankmango-changes
     That leaves a bookmark pointing at your version of the history, so it
     still exists after step 4. Skip this if you've never committed here.

  4. Now download GitHub's latest and make your folder match it exactly:
       git fetch $remote
       git reset --hard $up

     ("fetch" downloads the newest version without applying it. "reset
     --hard" then makes your folder identical to it, discarding the local
     side you just checked in steps 2 and 3.)

  5. Carry on with the update the normal way:
       ./update.sh --dry-run
       ./update.sh

  If any of that goes wrong, downloading a clean copy is always safe —
  nothing about your installed desktop lives in this folder:
    cd $parent
    mv $(basename "$REPO_DIR") $(basename "$REPO_DIR")-old
    git clone https://github.com/AhjinYeri/DankMango.git
  Then run ./update.sh from the new folder, and delete the -old one once
  you're happy.

EOF
    printf '%s═══════════════════════════════════════════════════════════════%s\n' "$c_dim" "$c_off"
    printf ' %sPrefer to use Claude Code instead?%s\n' "$c_dim" "$c_off"
    printf '%s═══════════════════════════════════════════════════════════════%s\n' "$c_dim" "$c_off"
    cat <<EOF
 This part is only useful if you already have Claude Code installed. If you
 don't, ignore it — the steps above are the complete fix and need no AI
 tooling at all. Otherwise, paste this block in.

============ COPY EVERYTHING BELOW TO CLAUDE CODE =============
My DankMango git clone at $REPO_DIR has a diverged branch: local "$branch" is
$ahead commit(s) ahead of and $behind behind "$up", so "git pull" fails and
./update.sh stops before it can work out what to update.

I want the clone to match $up exactly. Before changing anything, please run
"git status" and "git log --oneline $up..HEAD", tell me whether anything in
there is mine and worth keeping, and back it up if so. Only then bring the
clone in line with $up. Tell me what you're going to run before you run it,
and don't discard anything without confirming with me first.
==============================================================
EOF
    echo
}

# =============================================================================
# Pre-update snapshot — the Btrfs safety net, on machines that already have one
# =============================================================================
# README tells you to take a snapshot before updating. This just takes it for you,
# so "I forgot" stops being the only thing between a bad update and a two-minute
# rollback from the boot menu (grub-btrfs lists snapper's snapshots there).
#
# TWO GATES, and missing either is NOT an error: the root filesystem has to be
# Btrfs, and snapper has to be set up with at least one config. Plenty of perfectly
# good installs have neither — ext4, or Btrfs with no snapper — so a miss prints one
# line saying what was skipped and the update carries straight on. Same for a
# `snapper create` that FAILS (no sudo rights, full disk): warn, continue. A safety
# net is not a prerequisite, and an update must never be blocked by tooling that
# only some machines have.

# The description every DankMango snapshot carries, and the ONLY thing that marks a
# snapshot as ours. It lives in one variable because two things depend on it agreeing
# exactly: the create below writes it, and the prune below decides what it is allowed
# to delete by matching it. Two copies of this string that drifted apart would mean
# either dead snapshots nobody tidies, or — far worse — a prefix broad enough to match
# something that isn't ours.
# Also hardcoded in post-update-health.sh's section 7 check (~line 1204), which ships standalone and can't source this — keep the two in sync.
SNAPSHOT_DESC_PREFIX="DankMango pre-update:"

root_is_btrfs() { [ "$(findmnt -no FSTYPE / 2>/dev/null)" = btrfs ]; }

# snapper_config -> prints the config to snapshot, or returns non-zero when snapper
# isn't installed / has no configs / can't be asked.
#
# NOT hardcoded to "root": that's the near-universal name (and what CachyOS's own
# installer sets up), so it wins when present, but a setup that names its root config
# something else is still a setup worth snapshotting — so otherwise take the first
# one listed rather than deciding the user's layout is wrong.
#
# Listing usually works unprivileged (snapperd answers list-configs over D-Bus), but
# not on every setup, so retry once under `sudo -n`. Non-interactive on purpose: a
# gate check should never be the thing that pops a password prompt. If both come back
# empty we treat snapper as "not set up here" and skip, which is the right call either
# way — we couldn't create the snapshot under those conditions anyway.
snapper_config() {
    have snapper || return 1
    local out configs
    out="$(snapper --csvout list-configs 2>/dev/null)"
    [ -n "$out" ] || out="$(sudo -n snapper --csvout list-configs 2>/dev/null)"
    [ -n "$out" ] || return 1
    # Drop the "config,subvolume" header; keep the config name (first field).
    configs="$(printf '%s\n' "$out" | awk -F, 'NR>1 && $1 != "" {print $1}')"
    [ -n "$configs" ] || return 1
    if printf '%s\n' "$configs" | grep -qx root; then printf 'root\n'
    else printf '%s\n' "$configs" | head -1; fi
}

# How many DankMango pre-update snapshots to keep. Tune it here and nowhere else —
# no other line in this file knows the number.
DANKMANGO_SNAPSHOT_RETAIN=10

# prune_dankmango_snapshots CONFIG [PENDING] — never returns non-zero, by design.
#
# One snapshot per update adds up, and each one pins the disk blocks the update
# replaced, so left alone they quietly cost real space. This keeps the most recent
# $DANKMANGO_SNAPSHOT_RETAIN and removes DankMango's older ones. It's housekeeping of
# our own artifacts, so it just happens — no prompt, no report line unless something
# actually got tidied.
#
# THE ONE RULE: a snapshot is ours ONLY if its description starts with
# $SNAPSHOT_DESC_PREFIX. Everything else on the system — snapper's own timeline
# snapshots, pacman-hook snapshots, anything you took by hand before doing something
# risky — has to come out of here untouched, so the prefix is matched literally
# (index(), not a regex, so nothing in the string can be read as a pattern) and only
# ids that are genuinely numeric and non-zero are ever passed to `delete`. Snapshot 0
# is snapper's "current" pseudo-entry and is not a deletable thing.
#
# PENDING counts snapshots that WILL exist but don't yet: a --dry-run hasn't actually
# created this run's snapshot, so it passes 1 and the plan it prints matches what a
# real run would do rather than being off by one.
prune_dankmango_snapshots() {
    local cfg="$1" pending="${2:-0}" list ours keep total cut
    local -a sudo_run=() doomed=()

    if [ "$(id -u)" != 0 ]; then
        have sudo || return 0
        # A dry-run promises to change nothing AND to ask for nothing, so -n makes
        # sudo fail rather than prompt. A real run reaches here having just created a
        # snapshot through sudo, so its credentials are already cached — neither path
        # produces a password prompt that the create step didn't already produce.
        if [ "$DRY_RUN" = 1 ]; then sudo_run=(sudo -n); else sudo_run=(sudo); fi
    fi

    # snapper prints "No permissions." and still EXITS 0, so trust the output, not $?.
    list="$("${sudo_run[@]}" snapper --csvout -c "$cfg" list --columns number,description 2>/dev/null)"
    case "$list" in *"No permissions"*) list="" ;; esac
    if [ -z "$list" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            info "(dry-run) couldn't read the snapshot list without a password, so can't say which older ones would be tidied."
        else
            warn "couldn't list snapshots on config '$cfg' to tidy older ones. Harmless — your new snapshot is there either way; this only means old ones may pile up. Look with: sudo snapper -c $cfg list"
        fi
        return 0
    fi

    # Ours only, oldest first. snapper hands them back in number order already, but
    # sorting is one word and means the retention maths can't depend on that.
    ours="$(printf '%s\n' "$list" | awk -F, -v pfx="$SNAPSHOT_DESC_PREFIX" '
        NR > 1 {
            n = $1
            d = $0; sub(/^[^,]*,/, "", d); gsub(/^"|"$/, "", d)
            if (n ~ /^[0-9]+$/ && n + 0 > 0 && index(d, pfx) == 1) print n
        }' | sort -n)"
    [ -n "$ours" ] || return 0

    mapfile -t doomed <<<"$ours"
    total=${#doomed[@]}
    keep=$(( DANKMANGO_SNAPSHOT_RETAIN - pending ))
    [ "$keep" -lt 0 ] && keep=0
    [ "$total" -gt "$keep" ] || return 0        # nothing over the limit — stay quiet
    cut=$(( total - keep ))
    doomed=( "${doomed[@]:0:cut}" )             # the oldest $cut, and only those

    if [ "$DRY_RUN" = 1 ]; then
        info "(dry-run) would tidy $cut older DankMango snapshot(s), keeping the most recent $DANKMANGO_SNAPSHOT_RETAIN: ${doomed[*]}"
        return 0
    fi
    if "${sudo_run[@]}" snapper -c "$cfg" delete "${doomed[@]}"; then
        info "tidied $cut older DankMango snapshot(s) — the most recent $DANKMANGO_SNAPSHOT_RETAIN are kept."
    else
        warn "couldn't remove $cut older DankMango snapshot(s) — snapper refused. Harmless; they only take up space. By hand: sudo snapper -c $cfg delete ${doomed[*]}"
    fi
    return 0
}

# pre_update_snapshot FROM_COMMIT TO_COMMIT — never returns non-zero, by design.
pre_update_snapshot() {
    local from="$1" to="$2" cfg desc branch
    if ! root_is_btrfs; then
        info "no snapshot taken: your root filesystem isn't Btrfs, so snapper snapshots don't apply here. Nothing's wrong — carrying on."
        return 0
    fi
    if ! cfg="$(snapper_config)"; then
        info "no snapshot taken: snapper isn't set up on this machine. Nothing's wrong — carrying on."
        return 0
    fi

    # The two commits, in the same short form the final report prints, plus the branch
    # so the snapshot still reads clearly months later in the boot menu.
    branch="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    desc="$SNAPSHOT_DESC_PREFIX ${from:0:12} -> ${to:0:12}"
    [ -n "$branch" ] && [ "$branch" != HEAD ] && desc="$desc ($branch)"

    if [ "$DRY_RUN" = 1 ]; then
        info "(dry-run) would take a snapper snapshot on config '$cfg', described: $desc"
        # Pass 1: the snapshot this run WOULD take doesn't exist yet, so count it in
        # and the plan matches what a real run would tidy.
        prune_dankmango_snapshots "$cfg" 1
        return 0
    fi

    info "taking a snapshot first, on snapper config '$cfg' — this may ask for your password."
    local -a as_root=(); [ "$(id -u)" = 0 ] || as_root=(sudo)
    if [ "${#as_root[@]}" -gt 0 ] && ! have sudo; then
        warn "couldn't take the pre-update snapshot: snapper needs administrator rights and sudo isn't available. The update carries on regardless — you just won't have this rollback point."
        return 0
    fi
    if "${as_root[@]}" snapper -c "$cfg" create --description "$desc"; then
        ok "snapshot taken — if this update goes badly you can roll back to it from the boot menu."
        # Only after a snapshot actually landed. A failed create already warned, and
        # there's nothing to tidy around on that path.
        prune_dankmango_snapshots "$cfg"
    else
        warn "couldn't take the pre-update snapshot (snapper refused — usually permissions or a full disk). The update carries on regardless; you just won't have this rollback point. To take one by hand: sudo snapper -c $cfg create --description 'manual pre-update'"
    fi
    return 0
}

# =============================================================================
# 1. Read the manifest and work out the delta
# =============================================================================
stage "1/6  Working out what changed"
have jq  || die "jq is required (sudo pacman -S jq)."
have git || die "git is required."
[ -f "$MANIFEST" ] || die "no manifest at $MANIFEST — this system was never install.sh'd (or pre-manifest). Run install.sh."
jq -e . "$MANIFEST" >/dev/null 2>&1 || die "manifest at $MANIFEST is not valid JSON."

STATUS="$(jq -r '.dankmango.status // "unknown"' "$MANIFEST")"
LAST="$(jq -r '.dankmango.lastAppliedCommit // ""' "$MANIFEST")"
HEAD="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "")"
[ -n "$HEAD" ] || die "couldn't read repo HEAD — is $REPO_DIR a git checkout?"

# Before any delta maths: is this clone even in step with GitHub? A diverged branch has
# to be answered here, in plain English, or every later message is misleading. Checked
# in --dry-run too — the state is just as broken, and this reports rather than changes.
if DIVERGED="$(git_divergence)"; then
    read -r D_AHEAD D_BEHIND D_UP <<<"$DIVERGED"
    warn "your clone and GitHub have diverged ($D_AHEAD local change(s), $D_BEHIND on GitHub) — read the box below."
    explain_diverged_branch "$D_AHEAD" "$D_BEHIND" "$D_UP"
    exit 1
fi

# The fallbacks: anything we can't compute a trustworthy delta from -> re-run install.sh.
fallback() { warn "$1"; echo; die "Can't safely compute the update delta — just re-run install.sh for this update."; }

[ "$STATUS" = complete ] || fallback "last run status is '$STATUS', not 'complete' — the recorded commit may not have been fully applied."
[ -n "$LAST" ] && [ "$LAST" != null ] || fallback "manifest has no lastAppliedCommit (installed before this was tracked, or never finished)."
git -C "$REPO_DIR" cat-file -e "${LAST}^{commit}" 2>/dev/null || fallback "recorded commit $LAST isn't in this repo (shallow clone, or history was rewritten)."
git -C "$REPO_DIR" merge-base --is-ancestor "$LAST" "$HEAD" 2>/dev/null || fallback "recorded commit $LAST is not an ancestor of HEAD (force-push/rebase/branch switch)."

# Dirty tree: working-tree edits wouldn't be reflected by a commit..commit diff. Block a
# real run; allow a dry-run (it changes nothing) so the plan can still be inspected.
DIRTY=0
[ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ] && DIRTY=1
if [ "$DIRTY" = 1 ]; then
    if [ "$DRY_RUN" = 1 ]; then
        warn "repo has uncommitted local changes — the plan below reflects COMMITS only, not your working-tree edits."
    else
        fallback "repo has uncommitted local changes — commit/stash them (or clean the tree) so an update applies a known state."
    fi
fi

ok "manifest OK — last applied: ${LAST:0:12}   HEAD: ${HEAD:0:12}"
if [ "$LAST" = "$HEAD" ]; then
    echo; ok "Already up to date — nothing to apply."; exit 0
fi

# =============================================================================
# 1b. Safety snapshot — before anything is touched
# =============================================================================
# Numbered 1b rather than renumbering the run (install.sh's 10b does the same): this
# is the first point where BOTH commits are known and validated and we know an update
# is actually going to happen, and it is still ahead of every stage that changes
# something — stage 3 installs packages, and nothing before it writes a thing.
stage "1b/6  Safety snapshot"
pre_update_snapshot "$LAST" "$HEAD"

# =============================================================================
# 2. Changelog — show what's new BEFORE doing anything
# =============================================================================
stage "2/6  Changes since your last update"
git -C "$REPO_DIR" log --oneline --no-decorate "$LAST".."$HEAD" | sed 's/^/    /' || true

# Collect the file delta into an ARRAY (not a piped while-loop) so later prompts read
# the terminal cleanly. Rename shows as "R<score>\told\tnew".
mapfile -t DELTA < <(git -C "$REPO_DIR" diff --name-status -M "$LAST".."$HEAD")
echo
info "${#DELTA[@]} changed path(s) between the two commits."

# =============================================================================
# 3. Packages — install newly-added ones (--needed skips the rest)
# =============================================================================
stage "3/6  Packages"
# Snapshot pre-state so manifest_record_pkgs attributes correctly (ours vs preexisting).
declare -A PKG_PRE=()
for p in "${REPO_PKGS[@]}" "${AUR_PKGS[@]}" "${STANDARD_APPS[@]}"; do
    if pacman -Qi "$p" >/dev/null 2>&1; then PKG_PRE[$p]=1; else PKG_PRE[$p]=0; fi
done
# What's genuinely new (not yet installed) — for the report/plan.
new_pkgs=()
for p in "${REPO_PKGS[@]}" "${AUR_PKGS[@]}"; do [ "${PKG_PRE[$p]}" = 0 ] && new_pkgs+=("$p"); done
if [ "${#new_pkgs[@]}" -eq 0 ]; then
    info "all required packages already installed — nothing new."
else
    info "new required packages to install: ${new_pkgs[*]}"
fi
if [ "$DRY_RUN" = 0 ]; then
    ensure_aur_helper
    if "$AUR" -S --needed --noconfirm "${REPO_PKGS[@]}" "${AUR_PKGS[@]}"; then
        [ "${#new_pkgs[@]}" -gt 0 ] && ok "installed: ${new_pkgs[*]}"
    else
        warn "one or more required packages failed — see the manifest's packagesFailed."
    fi
    manifest_record_pkgs repo required "${REPO_PKGS[@]}"
    manifest_record_pkgs aur  required "${AUR_PKGS[@]}"
    [ "${#new_pkgs[@]}" -gt 0 ] && PKGS_ADDED+=("${new_pkgs[@]}")
fi
# Standard apps: only revisit if a decision was ALREADY recorded (installed/skipped/failed).
# If none is recorded, the user declined on install — respect that, don't re-prompt.
std_decided=0
for p in "${STANDARD_APPS[@]}"; do
    jq -e --arg n "$p" '[(.packages[]?, .packagesSkipped[]?, .packagesFailed[]?) | .name] | index($n)' "$MANIFEST" >/dev/null 2>&1 && std_decided=1
done
if [ "$std_decided" = 1 ]; then
    info "standard apps: a prior choice is on record — keeping it (re-run install.sh to change)."
    if [ "$DRY_RUN" = 0 ]; then
        "$AUR" -S --needed --noconfirm "${STANDARD_APPS[@]}" >/dev/null 2>&1 || true
        manifest_record_pkgs repo standard-app "${STANDARD_APPS[@]}"
    fi
else
    info "standard apps: you declined them at install — not revisiting (re-run install.sh to add)."
fi

# =============================================================================
# 4. Changed / added / removed files
# =============================================================================
stage "4/6  Config & script files"

recorded_hash() {  # recorded_hash DST -> hash DankMango last wrote for DST, or ""
    jq -r --arg p "$1" '[ .systemChanges[]? | select((.detail.path // "")==$p) | .detail.hash // empty ] | last // ""' "$MANIFEST" 2>/dev/null
}
is_ours() {  # is_ours DST -> 0 if manifest recorded us installing DST as a NON-preexisting file
    jq -e --arg p "$1" '[ .systemChanges[]? | select((.detail.path // "")==$p and (.detail.preexisting==false)) ] | length > 0' "$MANIFEST" >/dev/null 2>&1
}

# apply one added/modified repo file through the routing table.
apply_change() {  # apply_change REPO_REL
    local rel="$1" route dst scope kind
    if ! route="$(route_dest "$rel")"; then
        info "skip (not an installed path): $rel"; LEFT+=("$rel — not something install.sh copies"); return
    fi
    IFS=$'\t' read -r dst scope kind <<<"$route"
    local src="$REPO_DIR/$rel"
    case "$kind" in
        user_copy|sys_copy)
            # Edit-detection: if we have a recorded hash and the on-disk file no longer
            # matches it, the user changed it since install — don't clobber silently.
            if [ -f "$dst" ]; then
                local rec cur; rec="$(recorded_hash "$dst")"; cur="$(file_hash "$dst")"
                if [ -n "$rec" ] && [ "$rec" != "$cur" ]; then
                    warn "you've edited $dst since install."
                    if [ "$DRY_RUN" = 1 ]; then
                        info "  (dry-run) would ask keep/overwrite/diff — assuming KEEP"
                        LEFT+=("$dst — edited since install (would ask)"); return
                    fi
                    local ans
                    while :; do
                        printf '    [o]verwrite (backs up first) / [k]eep yours / [d]iff ? ' > /dev/tty
                        read -r ans < /dev/tty || ans=k
                        case "$ans" in
                            o*) break ;;
                            d*) diff -u "$dst" "$src" > /dev/tty 2>&1 || true ;;
                            *)  info "  kept your $dst"; LEFT+=("$dst — kept your edited version"); return ;;
                        esac
                    done
                fi
            fi
            [ "$DRY_RUN" = 1 ] && { info "would update ($kind): $dst"; UPDATED+=("$dst"); return; }
            # A failed copy is a FAILED UPDATE, not a line to swallow. The helper has
            # already said why; this makes sure it reaches the end-of-run report and
            # blocks the commit stamp (see COPY_FAILED at stage 6) so the same delta
            # is retried instead of being written off as applied.
            local copied=0
            if [ "$kind" = sys_copy ]; then sys_copy "$src" "$dst" && copied=1
            else                            user_copy "$src" "$dst" && copied=1; fi
            if [ "$copied" = 1 ]; then
                UPDATED+=("$dst")
            else
                COPY_FAILED=$((COPY_FAILED+1))
                LEFT+=("$dst — COPY FAILED; still the old version")
                MANUAL+=("$dst is stale — re-run install.sh (it re-copies every file, not just this delta)")
            fi
            ;;
        wallpaper)
            [ "$DRY_RUN" = 1 ] && { info "would add wallpaper: $dst"; UPDATED+=("$dst"); return; }
            mkdir -p "$(dirname "$dst")"; cp "$src" "$dst" && { ok "wallpaper -> $dst"; UPDATED+=("$dst"); }
            ;;
        plugin)
            # Re-copy the whole plugin tree the file belongs to (mirrors install stage 14).
            #
            # ONCE PER PLUGIN PER RUN, not once per changed file. A plugin is deployed as a
            # whole directory, so a delta touching four of its files is still one
            # deployment — the same reasoning (and the same flag idiom) as
            # SDDM_THEME_REINSTALLED above. Without the guard the tree was re-copied once
            # per file, which printed four identical report lines for one plugin and, worse,
            # made the backup below fire on the SECOND file onward against a directory this
            # very run had just created: `cp -a "$tgt" "$tgt.bak-$STAMP"` with the backup
            # already existing copies INTO it, leaving a nested
            # firstRunPanel.bak-<stamp>/firstRunPanel/. Deduping is what stops that.
            local pdir pid tgt
            pdir="$REPO_DIR/$(printf '%s' "$rel" | cut -d/ -f1-2)"
            [ -f "$pdir/plugin.json" ] || { warn "plugin.json missing for $rel — skipped"; return; }
            pid="$(grep -oP '"id"\s*:\s*"\K[^"]+' "$pdir/plugin.json" | head -1)"
            [ -n "$pid" ] || { warn "couldn't read plugin id from $pdir/plugin.json — skipped"; return; }
            if [ -n "${PLUGIN_DEPLOYED[$pid]:-}" ]; then
                info "plugin '$pid' handled once per run — nothing further for: $rel"
                return
            fi
            PLUGIN_DEPLOYED[$pid]=1
            tgt="$HOME/.config/DankMaterialShell/plugins/$pid"
            [ "$DRY_RUN" = 1 ] && { info "would update plugin '$pid' -> $tgt"; UPDATED+=("plugin:$pid"); return; }
            # Directory backup — prune_file_backups removes these as trees.
            #
            # Only when there is genuinely something to back up: a plugin that is NEW in this
            # delta (firstRunPanel on a v1.3.0 -> v1.4.0 upgrade) has no installed version, and
            # a .bak- of a directory that didn't exist is just litter in the plugins folder.
            # The dedupe above is what makes this test meaningful — it now runs exactly once,
            # BEFORE anything is written, so it reads the pre-update state rather than our own
            # half-finished work.
            #
            # The `! -e` arm is the belt to that braces, and it is not theoretical: `cp -a DIR
            # DEST` copies INTO DEST when DEST already exists, so any second backup of the same
            # tree under the same stamp nests as plugins/foo.bak-<stamp>/foo/ instead of
            # replacing. The dedupe stops that within one run; this also stops it across two
            # runs that start in the same second (rewound manifest, scripted re-run), where
            # STAMP is identical. One backup per path per run — and never delete the existing
            # one to make room, since it is the copy of the state we are about to overwrite.
            if [ -d "$tgt" ] && [ -n "$(ls -A "$tgt" 2>/dev/null)" ] && [ ! -e "$tgt.bak-$STAMP" ]; then
                cp -a "$tgt" "$tgt.bak-$STAMP"; prune_file_backups "$tgt"
            fi
            mkdir -p "$tgt"; cp -a "$pdir/." "$tgt/" && { ok "plugin '$pid' updated"; UPDATED+=("plugin:$pid"); }
            MANUAL+=("plugin '$pid' updated — a DMS reload/restart may be needed to pick it up")
            ;;
        sddm-theme)
            [ "$DRY_RUN" = 1 ] && { info "would refresh SDDM theme file: $dst (then sudo apply.sh)"; UPDATED+=("$dst"); return; }
            mkdir -p "$(dirname "$dst")"; cp "$src" "$dst" && { ok "SDDM theme file -> $dst"; UPDATED+=("$dst"); }
            MANUAL+=("SDDM theme changed — re-run: sudo ~/.config/sddm-astronaut-japanese/apply.sh")
            ;;
        dankmango-sddm-theme)
            # NOT a per-file copy. The destination tree is root-owned with two
            # user-writable leaves, and only the theme's own install.sh reproduces that
            # split correctly — a plain `cp` here would land QML as the wrong owner, in
            # a directory the greeter executes from pre-auth. So any change anywhere in
            # the tree means "re-run the installer", once, no matter how many files moved.
            if [ "$SDDM_THEME_REINSTALLED" = 1 ]; then
                info "login theme handled once per run — nothing further for: $rel"
                return
            fi
            SDDM_THEME_REINSTALLED=1
            # Only refresh what we actually installed. If the tree isn't there, the user
            # is on the old theme and hasn't migrated — the migration owns that case.
            if [ ! -d "$SDDM_THEME_DEST" ]; then
                info "login theme not installed here yet — the sddm-dankmango-theme migration will handle it."
                LEFT+=("$SDDM_THEME_DEST — not installed; left to the migration"); return
            fi
            [ "$DRY_RUN" = 1 ] && { info "would re-run the login theme installer -> $SDDM_THEME_DEST (sudo)"; UPDATED+=("$SDDM_THEME_DEST"); return; }
            if sddm_theme_install; then
                ok "login theme refreshed -> $SDDM_THEME_DEST"; UPDATED+=("$SDDM_THEME_DEST")
                # theme.conf is root-owned and just got overwritten with the new defaults;
                # theme.conf.user (the live palette) is a separate file and is untouched.
                MANUAL+=("SDDM login theme files changed — preview before your next reboot: sddm-greeter-qt6 --test-mode --theme $SDDM_THEME_DEST")
            else
                warn "couldn't refresh the login theme — re-run: sudo $REPO_DIR/system/sddm/themes/$SDDM_THEME_ID/install.sh"
                MANUAL+=("sudo $REPO_DIR/system/sddm/themes/$SDDM_THEME_ID/install.sh")
            fi
            ;;
        dms-state)
            # settings.json / plugin_settings.json are LIVE STATE, not a static copy.
            warn "DMS state file changed in the repo: $rel"
            info "  Not overwritten — it holds your settings. If this update needs a new key,"
            info "  that belongs in a migration (see stage 5). Compare by hand if unsure:"
            info "    diff $dst $src"
            LEFT+=("$dst — live DMS state; not overwritten (see migrations)")
            MANUAL+=("review $rel vs $dst — a settings change shipped; merge by hand if wanted")
            ;;
    esac
}

# retire a file DankMango removed from the repo.
retire_file() {  # retire_file REPO_REL
    local rel="$1" route dst scope kind
    route="$(route_dest "$rel")" || { info "removed from repo, not an installed path: $rel"; return; }
    IFS=$'\t' read -r dst scope kind <<<"$route"
    [ -e "$dst" ] || { info "already gone: $dst"; return; }

    # The login theme tree is never recorded file-by-file (it's one owned-tree record),
    # so the is_ours check below can't see it — and the theme installer only ever adds
    # or overwrites, so a file dropped from the repo would otherwise linger forever in a
    # root-owned directory the greeter loads from. Prune it explicitly.
    if [ "$kind" = dankmango-sddm-theme ]; then
        [ "$DRY_RUN" = 1 ] && { info "would remove stale login-theme file: $dst"; RETIRED+=("$dst"); return; }
        if ask_tty "DankMango dropped $rel. Remove the stale $dst from the installed theme? (needs sudo)"; then
            # NO .bak- copy here, unlike every other retire path, and deliberately:
            # this file came from the repo, so git still has it — a backup would add
            # nothing except a stray file inside a root-owned directory the greeter
            # loads from pre-auth, which is the one place not to leave litter.
            if sudo rm -f "$dst"; then ok "retired $dst (still in git history if you want it back)"; RETIRED+=("$dst")
            else warn "couldn't remove $dst"; MANUAL+=("sudo rm $dst"); fi
        else
            LEFT+=("$dst — stale login-theme file kept, by your choice")
        fi
        return
    fi
    if ! is_ours "$dst"; then
        info "repo dropped $rel, but manifest doesn't show $dst as ours — leaving it."
        LEFT+=("$dst — repo removed it but it isn't recorded as ours"); return
    fi
    [ "$DRY_RUN" = 1 ] && { info "would retire (back up + remove): $dst"; RETIRED+=("$dst"); return; }
    if ask_tty "DankMango removed $rel. Retire the installed $dst (backs it up first)?"; then
        cp -a "$dst" "$dst.bak-$STAMP" 2>/dev/null || sudo cp -a "$dst" "$dst.bak-$STAMP"
        prune_file_backups "$dst" "$( [ "$scope" = system ] && printf 1 || printf 0 )"
        if [ "$scope" = system ]; then sudo rm -f "$dst"; else rm -f "$dst"; fi
        ok "retired $dst (backup: $dst.bak-$STAMP)"; RETIRED+=("$dst")
    else
        LEFT+=("$dst — kept, by your choice")
    fi
}

if [ "${#DELTA[@]}" -eq 0 ]; then
    info "no file changes between the two commits."
else
    for line in "${DELTA[@]}"; do
        status="${line%%$'\t'*}"; rest="${line#*$'\t'}"
        case "$status" in
            A*|M*) apply_change "$rest" ;;
            D*)    retire_file "$rest" ;;
            R*)    old="${rest%%$'\t'*}"; new="${rest#*$'\t'}"; retire_file "$old"; apply_change "$new" ;;
            *)     info "unhandled git status '$status' for: $rest"; MANUAL+=("$rest — git status $status, handle by hand") ;;
        esac
    done
fi

# =============================================================================
# 5. Migrations (live-state changes)
# =============================================================================
stage "5/6  Migrations"
applied_json="$(jq -c '.migrationsApplied // []' "$MANIFEST" 2>/dev/null || echo '[]')"
ran_any=0
for entry in "${MIGRATIONS[@]}"; do
    id="${entry%%:*}"; desc="${entry#*:}"
    if printf '%s' "$applied_json" | jq -e --arg id "$id" 'index($id)' >/dev/null 2>&1; then
        info "already applied: $id"; continue
    fi
    ran_any=1
    info "migration: $id — $desc"
    if "migrate_$id"; then
        MIGRATED+=("$id")
        [ "$DRY_RUN" = 0 ] && manifest_jq '.migrationsApplied = ((.migrationsApplied // []) + [$id] | unique)' --arg id "$id"
    else
        warn "migration $id reported a problem — NOT marking it applied (will retry next update)."
    fi
done
[ "$ran_any" = 0 ] && info "no pending migrations."

# =============================================================================
# 6. Finalize + report
# =============================================================================
stage "6/6  Finalize"
if [ "$DRY_RUN" = 1 ]; then
    echo
    ok "Dry run complete — nothing was changed."
    info "Plan summary:"
    info "  packages to add : ${new_pkgs[*]:-(none)}"
    info "  files to update : ${#UPDATED[@]}"
    info "  files to retire : ${#RETIRED[@]}"
    info "  migrations      : ${MIGRATED[*]:-(none pending)}"
    info "Re-run without --dry-run to apply."
    exit 0
fi

# Refresh commit/run metadata (status -> in-progress) then mark complete, which stamps
# lastAppliedCommit = the now-current HEAD. Done LAST so a mid-update failure leaves
# lastAppliedCommit at the OLD commit and the next run safely retries the same delta.
#
# A file that could not be written is exactly such a failure, so it gets the same
# treatment: NOT stamping the commit is what keeps those files in the next run's
# delta. Stamping anyway would mark them applied when they are still the old
# version, and no later update would ever look at them again — each run only
# re-copies what changed inside ITS OWN commit range. The manifest is left at
# status "in-progress", which the next update.sh reads as "re-run install.sh",
# and install.sh re-copies every file rather than a delta. That is the repair.
if [ "$COPY_FAILED" -gt 0 ]; then
    manifest_init >/dev/null 2>&1
    warn "$COPY_FAILED file(s) could not be written — see below."
    info "  NOT recording this update as applied, on purpose: the files listed under"
    info "  \"LEFT ALONE\" are still the old version, and a recorded update would hide"
    info "  that forever (later updates only re-copy what changed in their own range)."
    info "  Fix the cause, then run install.sh — it re-copies everything, not a delta."
else
    manifest_init >/dev/null 2>&1
    manifest_finalize
fi

print_list() { local t="$1"; shift; echo; info "$t"; if [ "$#" -eq 0 ]; then info "  (none)"; else printf '      - %s\n' "$@"; fi; }
echo; echo "==================================================================="
if [ "$COPY_FAILED" -gt 0 ]; then
    printf ' %sDankMango update INCOMPLETE %s -> %s%s\n' "$c_yel" "${LAST:0:12}" "${HEAD:0:12}" "$c_off"
else
    printf ' %sDankMango updated %s -> %s%s\n' "$c_grn" "${LAST:0:12}" "${HEAD:0:12}" "$c_off"
fi
echo "==================================================================="
print_list "PACKAGES added:"          ${PKGS_ADDED[@]+"${PKGS_ADDED[@]}"}
print_list "FILES updated:"           ${UPDATED[@]+"${UPDATED[@]}"}
print_list "FILES retired (backed up):" ${RETIRED[@]+"${RETIRED[@]}"}
print_list "MIGRATIONS run:"          ${MIGRATED[@]+"${MIGRATED[@]}"}
print_list "LEFT ALONE (and why):"    ${LEFT[@]+"${LEFT[@]}"}
print_list "STILL FOR YOU TO DO:"     ${MANUAL[@]+"${MANUAL[@]}"}
echo
info "Backups of anything overwritten sit beside the originals as .bak-$STAMP."
if [ "$COPY_FAILED" -gt 0 ]; then
    warn "$COPY_FAILED file(s) were NOT updated — this update is unfinished. Run install.sh to complete it."
elif [ "$WARNINGS" -gt 0 ]; then
    warn "finished with $WARNINGS warning(s) — read them above."
else
    ok "update finished cleanly."
fi
info "Log out/in or reload DMS if a plugin, keyd, or a service-level file changed."
[ "$COPY_FAILED" -gt 0 ] && exit 1
exit 0
