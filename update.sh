#!/usr/bin/env bash
#
# =============================================================================
#  DankMango updater
# =============================================================================
#  Applies ONLY what changed since your last update, instead of re-running the
#  whole installer. It works out the delta from the install manifest's recorded
#  lastAppliedCommit -> the repo's current HEAD, then:
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
#  rather than guessing.
# =============================================================================

set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_DIR/lib/common.sh"   # pretty output, sys_copy/user_copy, manifest_*, arrays, route_dest, file_hash

DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        --manifest) MANIFEST="${2:-}"; [ -n "$MANIFEST" ] || die "--manifest needs a path"
                    MANIFEST_DIR="$(dirname "$MANIFEST")"; shift 2 ;;
        -h|--help)  sed -n '3,34p' "$0"; exit 0 ;;
        *)          die "unknown argument: $1  (try --help)" ;;
    esac
done

# Report buckets, printed together at the end (same spirit as install/uninstall).
UPDATED=(); PKGS_ADDED=(); MIGRATED=(); RETIRED=(); LEFT=(); MANUAL=()

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
)

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
        ok "  removed dead pins: $present (backup: $sess.bak-$STAMP)"
    else
        warn "  couldn't edit session.json — left as-is"
    fi
    rm -f "$tmp"
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
            if [ "$kind" = sys_copy ]; then sys_copy "$src" "$dst"; else user_copy "$src" "$dst"; fi \
                && UPDATED+=("$dst")
            ;;
        wallpaper)
            [ "$DRY_RUN" = 1 ] && { info "would add wallpaper: $dst"; UPDATED+=("$dst"); return; }
            mkdir -p "$(dirname "$dst")"; cp "$src" "$dst" && { ok "wallpaper -> $dst"; UPDATED+=("$dst"); }
            ;;
        plugin)
            # Re-copy the whole plugin tree the file belongs to (mirrors install stage 14).
            local pdir pid tgt
            pdir="$REPO_DIR/$(printf '%s' "$rel" | cut -d/ -f1-2)"
            [ -f "$pdir/plugin.json" ] || { warn "plugin.json missing for $rel — skipped"; return; }
            pid="$(grep -oP '"id"\s*:\s*"\K[^"]+' "$pdir/plugin.json" | head -1)"
            tgt="$HOME/.config/DankMaterialShell/plugins/$pid"
            [ "$DRY_RUN" = 1 ] && { info "would update plugin '$pid' -> $tgt"; UPDATED+=("plugin:$pid"); return; }
            [ -d "$tgt" ] && cp -a "$tgt" "$tgt.bak-$STAMP"
            mkdir -p "$tgt"; cp -a "$pdir/." "$tgt/" && { ok "plugin '$pid' updated"; UPDATED+=("plugin:$pid"); }
            MANUAL+=("plugin '$pid' updated — a DMS reload/restart may be needed to pick it up")
            ;;
        sddm-theme)
            [ "$DRY_RUN" = 1 ] && { info "would refresh SDDM theme file: $dst (then sudo apply.sh)"; UPDATED+=("$dst"); return; }
            mkdir -p "$(dirname "$dst")"; cp "$src" "$dst" && { ok "SDDM theme file -> $dst"; UPDATED+=("$dst"); }
            MANUAL+=("SDDM theme changed — re-run: sudo ~/.config/sddm-astronaut-japanese/apply.sh")
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
    if ! is_ours "$dst"; then
        info "repo dropped $rel, but manifest doesn't show $dst as ours — leaving it."
        LEFT+=("$dst — repo removed it but it isn't recorded as ours"); return
    fi
    [ "$DRY_RUN" = 1 ] && { info "would retire (back up + remove): $dst"; RETIRED+=("$dst"); return; }
    if ask_tty "DankMango removed $rel. Retire the installed $dst (backs it up first)?"; then
        cp -a "$dst" "$dst.bak-$STAMP" 2>/dev/null || sudo cp -a "$dst" "$dst.bak-$STAMP"
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
manifest_init >/dev/null 2>&1
manifest_finalize

print_list() { local t="$1"; shift; echo; info "$t"; if [ "$#" -eq 0 ]; then info "  (none)"; else printf '      - %s\n' "$@"; fi; }
echo; echo "==================================================================="
printf ' %sDankMango updated %s -> %s%s\n' "$c_grn" "${LAST:0:12}" "${HEAD:0:12}" "$c_off"
echo "==================================================================="
print_list "PACKAGES added:"          ${PKGS_ADDED[@]+"${PKGS_ADDED[@]}"}
print_list "FILES updated:"           ${UPDATED[@]+"${UPDATED[@]}"}
print_list "FILES retired (backed up):" ${RETIRED[@]+"${RETIRED[@]}"}
print_list "MIGRATIONS run:"          ${MIGRATED[@]+"${MIGRATED[@]}"}
print_list "LEFT ALONE (and why):"    ${LEFT[@]+"${LEFT[@]}"}
print_list "STILL FOR YOU TO DO:"     ${MANUAL[@]+"${MANUAL[@]}"}
echo
info "Backups of anything overwritten sit beside the originals as .bak-$STAMP."
if [ "$WARNINGS" -gt 0 ]; then
    warn "finished with $WARNINGS warning(s) — read them above."
else
    ok "update finished cleanly."
fi
info "Log out/in or reload DMS if a plugin, keyd, or a service-level file changed."
