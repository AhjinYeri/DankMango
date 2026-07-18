#!/usr/bin/env bash
#
# =============================================================================
#  DankMango uninstaller
# =============================================================================
#  Walks back a DankMango install using the install manifest
#  (~/.local/state/dankmango/manifest.json) as the source of truth, so you don't
#  have to hunt down every file, package and setting install.sh touched.
#
#  DESIGN RULES (why this script is shaped the way it is):
#
#    1. NOTHING IS EVER `rm`'d. Everything this script "removes" is MOVED into a
#       rescue dir (~/.local/state/dankmango/uninstall-<stamp>/), preserving its
#       full path. Every destructive step is therefore undoable by hand until you
#       delete that dir yourself. This is the single most important property here.
#
#    2. IT ONLY TOUCHES WHAT THE MANIFEST SAYS IS OURS. Packages that were already
#       present before DankMango (packagesSkipped) are never removed. Packages we
#       failed to install (packagesFailed) were never installed, so there is
#       nothing to remove — both lists are report-only.
#
#    3. IT ASKS BEFORE ANYTHING DESTRUCTIVE, and every such prompt defaults to NO.
#       Restores (putting YOUR files back) are the only thing done without asking,
#       because that is the point of uninstalling.
#
#    4. IT DEGRADES GRACEFULLY. An old/partial/hand-edited manifest produces
#       warnings about what couldn't be determined, never a crash and never a
#       guess. Change types it doesn't recognise are reported for you to handle
#       by hand, using the 'reversal' hint install.sh recorded alongside them.
#
#  Usage:
#     bash uninstall.sh                 # interactive; shows a plan, then asks
#     bash uninstall.sh --dry-run       # print the plan and exit; touches nothing
#     bash uninstall.sh --manifest FILE # read a different (e.g. scratch) manifest
#
#  ALWAYS run --dry-run first.
# =============================================================================

# Same rationale as install.sh: NOT `set -e`. Every stage should run and report
# even if an earlier one had a problem — a half-reverted system that tells you
# what it couldn't do beats one that dies silently at step 3.
set -uo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
WARNINGS=0
DRY_RUN=0

MANIFEST_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dankmango"
MANIFEST="$MANIFEST_DIR/manifest.json"

# ---- pretty output (mirrors install.sh) --------------------------------------
c_blu=$'\033[1;34m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
stage() { printf '\n%s==> %s%s\n' "$c_blu" "$1" "$c_off"; }
ok()    { printf '    %s[ ok ]%s %s\n' "$c_grn" "$c_off" "$1"; }
info()  { printf '    %s%s%s\n' "$c_dim" "$1" "$c_off"; }
warn()  { printf '    %s[warn]%s %s\n' "$c_yel" "$c_off" "$1"; WARNINGS=$((WARNINGS+1)); }
die()   { printf '    %s[FAIL]%s %s\n' "$c_red" "$c_off" "$1"; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }

# Every destructive prompt in this script uses this: empty answer == No.
#
# Reads from /dev/tty, NOT stdin, and that is load-bearing: most prompts here fire
# inside `while read ... done < <(jq ...)` loops, whose stdin IS the jq stream. A
# plain `read` would silently eat a line of manifest JSON as your answer and act on
# it. Asking the terminal directly makes the prompt immune to the enclosing loop.
# With no terminal at all (piped/cron), it answers NO rather than guessing.
ask_yn() {
    local ans
    [ "$DRY_RUN" = 1 ] && { info "(dry-run) would ask: $1"; return 1; }
    if [ ! -r /dev/tty ]; then
        warn "no terminal to ask '$1' — assuming NO and continuing."
        return 1
    fi
    printf '    %s [y/N] ' "$1" > /dev/tty
    read -r ans < /dev/tty || return 1
    case "$ans" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ---- final-report buckets ---------------------------------------------------
# Collected as we go, printed in one place at the end (stage 11). A user running a
# destructive script should not have to scroll back through it to find out what it did.
RESTORED=(); REMOVED=(); LEFT=(); MANUAL=(); PKGS_REMOVED=()
# Absolute paths we restored from a backup this run. Used to protect those files
# from the later tree-removal stage — restoring your file and then moving it into
# the rescue dir would be an expensive no-op at best.
RESTORED_PATHS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        --manifest) MANIFEST="${2:-}"; [ -n "$MANIFEST" ] || die "--manifest needs a path"; shift 2 ;;
        -h|--help)  sed -n '3,36p' "$0"; exit 0 ;;
        *)          die "unknown argument: $1  (try --help)" ;;
    esac
done

# Rescue lives beside the manifest ACTUALLY in use, not beside the default one — so a
# --manifest pointed at a scratch copy keeps its rescue tree there too, and testing can
# never scatter files into the real state dir.
RESCUE="$(cd "$(dirname "$MANIFEST")" && pwd)/uninstall-$STAMP"

echo "==================================================================="
echo " DankMango uninstaller   ($STAMP)"
echo " manifest: $MANIFEST"
[ "$DRY_RUN" = 1 ] && echo " MODE: DRY RUN — nothing will be changed"
echo "==================================================================="

# A --manifest pointed somewhere unusual is almost always a test against a scratch
# copy. Be blunt that this sandboxes FILES only: packages and systemd services are
# system-global, and no manifest path can make `pacman -Rs` or `systemctl disable`
# affect a fake root. Answer No to those prompts when testing.
if [ "$DRY_RUN" != 1 ] && [ "$MANIFEST" != "$MANIFEST_DIR/manifest.json" ]; then
    warn "using a non-default manifest: $MANIFEST"
    warn "File operations follow the paths IN THAT FILE, but package removal and"
    warn "service changes always hit the REAL system. If this is a test, answer No"
    warn "to every package/service prompt (No is the default — just press Enter)."
fi

# =============================================================================
# Rescue helpers — the "we never delete" guarantee lives here
# =============================================================================
# Mirror an absolute path under $RESCUE, e.g. /etc/keyd/default.conf ->
# $RESCUE/etc/keyd/default.conf. Keeps collisions impossible and makes manual
# recovery obvious (the rescue tree looks exactly like the paths it came from).
rescue_path() { printf '%s%s' "$RESCUE" "$1"; }

# Move PATH into the rescue tree instead of deleting it. sudo only when needed.
# Returns non-zero (and warns) if the move fails, so callers don't report success.
rescue_move() {
    local src="$1" need_sudo="${2:-0}" dst; dst="$(rescue_path "$src")"
    if [ ! -e "$src" ]; then info "already gone: $src"; return 1; fi
    if [ "$DRY_RUN" = 1 ]; then info "would move to rescue: $src"; return 0; fi
    if [ "$need_sudo" = 1 ]; then
        sudo mkdir -p "$(dirname "$dst")" && sudo mv "$src" "$dst"
    else
        mkdir -p "$(dirname "$dst")" && mv "$src" "$dst"
    fi || { warn "couldn't move $src into the rescue dir — left it in place"; return 1; }
    return 0
}

# =============================================================================
# 1. Preflight — can we trust the manifest at all?
# =============================================================================
stage "1/11  Reading the install manifest"

have jq || die "jq is required to read the manifest (sudo pacman -S jq)."

if [ ! -f "$MANIFEST" ]; then
    warn "no manifest at $MANIFEST"
    info "Either DankMango was never installed on this user, or it was installed"
    info "before the manifest existed. Without it this script cannot know what is"
    info "yours vs. ours, and GUESSING is exactly what it refuses to do."
    info ""
    info "To walk back an unmanifested install by hand, look for:"
    info "  *.bak-<timestamp> files under ~/.config/mango, ~/.config/DankMaterialShell,"
    info "  /etc/keyd, /etc/sddm.conf.d — each sits beside the file it backs up."
    die "nothing to do without a manifest."
fi

jq -e . "$MANIFEST" >/dev/null 2>&1 || die "manifest at $MANIFEST is not valid JSON — refusing to act on it."

MV="$(jq -r '.manifestVersion // "unknown"' "$MANIFEST")"
STATUS="$(jq -r '.dankmango.status // "unknown"' "$MANIFEST")"
DM_VER="$(jq -r '.dankmango.version // "unknown"' "$MANIFEST")"
FIRST="$(jq -r '.dankmango.firstInstall.at // "unknown"' "$MANIFEST")"
LAST="$(jq -r '.dankmango.lastRunAt // "unknown"' "$MANIFEST")"

ok "manifest v$MV — DankMango $DM_VER"
info "first installed: $FIRST"
info "last install run: $LAST"

if [ "$MV" != "1" ]; then
    warn "this uninstaller understands manifest v1; found v$MV."
    warn "Continuing best-effort: anything it doesn't recognise is REPORTED, not acted on."
fi
if [ "$STATUS" != "complete" ]; then
    warn "the last install run has status '$STATUS' (not 'complete')."
    warn "That install may have been interrupted, so this record may be missing entries."
    warn "Anything it doesn't know about will be left in place — check the manual list at the end."
fi

# =============================================================================
# 2. The plan — say everything BEFORE doing anything
# =============================================================================
stage "2/11  What this would do"

n_backups="$(jq -r '(.backups // []) | length' "$MANIFEST")"
n_pkgs="$(jq -r '(.packages // []) | length' "$MANIFEST")"
n_skip="$(jq -r '(.packagesSkipped // []) | length' "$MANIFEST")"
n_fail="$(jq -r '(.packagesFailed // []) | length' "$MANIFEST")"
n_chg="$(jq -r '(.systemChanges // []) | length' "$MANIFEST")"

echo
info "RESTORE — files DankMango overwrote, put back from its backups ($n_backups):"
if [ "$n_backups" = 0 ]; then
    info "  (none — DankMango didn't overwrite any pre-existing file)"
else
    while IFS=$'\t' read -r orig bak scope _; do
        [ -n "${orig:-}" ] || continue
        if [ -f "$bak" ]; then info "  $orig  <-  $bak  [$scope]"
        else info "  $orig  <-  ${c_yel}MISSING BACKUP${c_off} $bak  [$scope]"; fi
    done < <(jq -r '(.backups // [])[] | [.original, .backup, (.scope // "user"), (.stage // "?")] | @tsv' "$MANIFEST")
fi

echo
info "OFFER TO REMOVE — packages DankMango installed ($n_pkgs) — default is to KEEP:"
if [ "$n_pkgs" = 0 ]; then info "  (none)"; else
    while IFS=$'\t' read -r name src cat; do
        info "  $name  [$src/$cat]"
    done < <(jq -r '(.packages // [])[] | [.name, (.source // "?"), (.category // "?")] | @tsv' "$MANIFEST")
fi

echo
info "NEVER TOUCHED — already on this system before DankMango ($n_skip):"
if [ "$n_skip" = 0 ]; then info "  (none)"; else
    info "  $(jq -r '[(.packagesSkipped // [])[] | .name] | join(" ")' "$MANIFEST")"
fi
if [ "$n_fail" != 0 ]; then
    echo
    info "NEVER INSTALLED — these failed during install, so there is nothing to remove ($n_fail):"
    info "  $(jq -r '[(.packagesFailed // [])[] | .name] | join(" ")' "$MANIFEST")"
fi

echo
info "SYSTEM CHANGES recorded ($n_chg) — each handled individually below:"
if [ "$n_chg" = 0 ]; then info "  (none)"; else
    while IFS=$'\t' read -r type key; do info "  $type  ->  $key"; done \
        < <(jq -r '(.systemChanges // [])[] | [.type, (.key // "?")] | @tsv' "$MANIFEST")
fi

echo
info "Nothing is deleted. Everything removed is MOVED to:"
info "  $RESCUE"
info "Delete that dir yourself once you're happy — until then, every step is reversible."

if [ "$DRY_RUN" = 1 ]; then
    echo
    ok "dry run complete — nothing was changed."
    info "Re-run without --dry-run to act on this plan."
    exit 0
fi

echo
if ! ask_yn "Proceed with the uninstall described above?"; then
    info "Aborted — nothing was changed."
    exit 0
fi
mkdir -p "$RESCUE" || die "couldn't create the rescue dir at $RESCUE — refusing to remove anything without it."

# =============================================================================
# 3. Restore backed-up files
# =============================================================================
# Done FIRST and without asking: these are YOUR files, and putting them back is
# the whole point. Note manifest_add_backup keeps the FIRST backup per original,
# which is the true pre-DankMango content (a re-run would only have backed up our
# own copy) — so restoring the recorded backup is always correct.
stage "3/11  Restoring files DankMango backed up"

if [ "$n_backups" = 0 ]; then
    info "no backups recorded — DankMango didn't overwrite any pre-existing file."
else
    while IFS=$'\t' read -r orig bak scope _; do
        [ -n "${orig:-}" ] || continue
        if [ ! -f "$bak" ]; then
            warn "backup missing, can't restore $orig"
            info "  expected it at: $bak"
            MANUAL+=("restore $orig by hand — its backup ($bak) is gone")
            continue
        fi
        # Keep whatever is there now (our installed version) in the rescue tree
        # rather than letting the restore clobber it unrecoverably.
        if [ "$scope" = system ]; then
            have sudo || { warn "need sudo to restore $orig — skipped"; MANUAL+=("sudo cp $bak $orig"); continue; }
            [ -e "$orig" ] && rescue_move "$orig" 1 >/dev/null
            if sudo cp -a "$bak" "$orig"; then
                ok "restored $orig  (system)"; RESTORED+=("$orig"); RESTORED_PATHS+=("$orig")
            else warn "failed to restore $orig"; MANUAL+=("sudo cp $bak $orig"); fi
        else
            [ -e "$orig" ] && rescue_move "$orig" 0 >/dev/null
            if cp -a "$bak" "$orig"; then
                ok "restored $orig"; RESTORED+=("$orig"); RESTORED_PATHS+=("$orig")
            else warn "failed to restore $orig"; MANUAL+=("cp $bak $orig"); fi
        fi
    done < <(jq -r '(.backups // [])[] | [.original, .backup, (.scope // "user"), (.stage // "?")] | @tsv' "$MANIFEST")
fi

# True if $1 is a path we restored from backup this run (exact match).
was_restored() {
    local p; for p in ${RESTORED_PATHS[@]+"${RESTORED_PATHS[@]}"}; do [ "$p" = "$1" ] && return 0; done; return 1
}
# True if any backup ORIGINAL lives inside directory $1. Such a tree is not purely
# ours — it holds files that predate DankMango — so it must never be removed wholesale.
tree_holds_backup() {
    local d="$1" o
    while IFS= read -r o; do
        [ -n "$o" ] || continue
        case "$o" in "$d"/*) return 0 ;; esac
    done < <(jq -r '(.backups // [])[] | .original' "$MANIFEST")
    return 1
}

# =============================================================================
# 4. Revert the DMS package-file patch (before any tree moves)
# =============================================================================
# Ordering matters: the patch's own backups live under ~/.config/mango/backups,
# and stage 6 may move ~/.config/mango into the rescue tree. Restore from them
# while they're still where the patch script left them.
stage "4/11  Reverting patched package files"

patch_n=0
while IFS=$'\t' read -r target backups_dir; do
    [ -n "${target:-}" ] || continue
    patch_n=$((patch_n+1))
    bdir="${backups_dir/#\~/$HOME}"
    newest=""
    [ -d "$bdir" ] && newest="$(ls -1t "$bdir"/"$(basename "$target")".* 2>/dev/null | head -1)"
    info "patched: $target"
    if [ -z "$newest" ]; then
        warn "no saved original found under $bdir — can't revert this patch automatically."
        MANUAL+=("reinstall the owning package to undo the patch on $target (e.g. sudo pacman -S dms-shell)")
        continue
    fi
    info "  original available: $newest"
    if ask_yn "Restore the unpatched $(basename "$target")? (needs sudo)"; then
        if sudo cp -a "$newest" "$target"; then
            ok "restored unpatched $target"; RESTORED+=("$target (unpatched)")
        else
            warn "restore failed"; MANUAL+=("sudo cp $newest $target")
        fi
    else
        LEFT+=("$target — still patched, by your choice")
    fi
done < <(jq -r '(.systemChanges // [])[] | select(.type=="patch-applied")
                | [(.detail.target // .key), (.detail.backupsDir // "")] | @tsv' "$MANIFEST")
[ "$patch_n" = 0 ] && info "no patched package files recorded."

# =============================================================================
# 5. Remove files DankMango generated or copied in
# =============================================================================
# These are unambiguously ours: generated by our scripts, or copied from the repo
# into a path that did NOT previously exist (preexisting:false). Still moved to
# rescue, never deleted.
stage "5/11  Removing files DankMango created"

gen_n=0
# 5a. files-generated (e.g. tagrules.conf) — created by our generators, never yours.
while IFS= read -r f; do
    [ -n "$f" ] || continue
    gen_n=$((gen_n+1))
    if rescue_move "$f" 0; then ok "removed generated file: $f"; REMOVED+=("$f (generated)"); fi
done < <(jq -r '(.systemChanges // [])[] | select(.type=="files-generated") | (.detail.file // .key)' "$MANIFEST")

# 5b. files-copied (e.g. wallpapers) — remove ONLY the exact files we copied, so
#     anything you added to the same dir yourself stays.
while IFS=$'\t' read -r dst file; do
    [ -n "${dst:-}" ] && [ -n "${file:-}" ] || continue
    gen_n=$((gen_n+1))
    if rescue_move "$dst/$file" 0; then ok "removed copied file: $dst/$file"; REMOVED+=("$dst/$file"); fi
done < <(jq -r '(.systemChanges // [])[] | select(.type=="files-copied")
                | (.detail.dst // .key) as $d | (.detail.files // [])[] | [$d, .] | @tsv' "$MANIFEST")

# 5c. *-file-installed where the target did NOT pre-exist. If it DID pre-exist,
#     stage 3 already restored your version and this must be left alone.
while IFS=$'\t' read -r path pre scope; do
    [ -n "${path:-}" ] || continue
    if [ "$pre" = "true" ]; then
        was_restored "$path" || LEFT+=("$path — existed before DankMango; no backup was recorded (we never changed it)")
        continue
    fi
    was_restored "$path" && continue
    gen_n=$((gen_n+1))
    need_sudo=0; [ "$scope" = system ] && need_sudo=1
    if [ "$need_sudo" = 1 ] && ! have sudo; then
        warn "need sudo to remove $path — skipped"; MANUAL+=("sudo rm $path"); continue
    fi
    if rescue_move "$path" "$need_sudo"; then ok "removed $path"; REMOVED+=("$path"); fi
done < <(jq -r '(.systemChanges // [])[]
                | select(.type=="system-file-installed" or .type=="user-file-installed")
                | [(.detail.path // .key), ((.detail.preexisting // false)|tostring), (.detail.scope // "user")] | @tsv' "$MANIFEST")
[ "$gen_n" = 0 ] && info "no generated/copied files recorded."

# =============================================================================
# 6. Directory trees DankMango owns
# =============================================================================
# Opt-in, one prompt per tree, default NO. A tree is NOT offered for removal if it
# holds a file we restored in stage 3 — that means it predates DankMango in part,
# and removing it would take your file with it.
stage "6/11  Directories DankMango created"

tree_n=0
while IFS=$'\t' read -r dir note; do
    [ -n "${dir:-}" ] || continue
    tree_n=$((tree_n+1))
    echo
    info "tree: $dir"
    [ -n "${note:-}" ] && info "  install.sh noted: $note"
    if [ ! -d "$dir" ]; then info "  already gone."; continue; fi
    if tree_holds_backup "$dir"; then
        warn "NOT removing $dir — it contains files that existed before DankMango"
        warn "  (restored in stage 3). Remove leftovers by hand if you want it gone."
        LEFT+=("$dir — holds pre-DankMango files; not removed")
        continue
    fi
    sz="$(du -sh "$dir" 2>/dev/null | cut -f1)"
    info "  size: ${sz:-?}   contents stay recoverable under $RESCUE"
    if ask_yn "Remove $dir?"; then
        if rescue_move "$dir" 0; then ok "removed $dir"; REMOVED+=("$dir/"); fi
    else
        LEFT+=("$dir — kept, by your choice")
    fi
done < <(jq -r '(.systemChanges // [])[] | select(.type=="owned-tree")
                | [(.detail.dir // .key), (.detail.note // "")] | @tsv' "$MANIFEST")
[ "$tree_n" = 0 ] && info "no owned directories recorded."

# =============================================================================
# 7. session.json — the seeded pins / wallpaper
# =============================================================================
# The nuance: session.json is DMS's own live state file. DankMango only SEEDED it
# (pins + wallpaper, and only where the keys were empty), and DMS has been writing
# to it ever since. Anything you pinned or changed after install is in there too and
# is NOT ours to remove. So: only offer to clear a key if it still EXACTLY matches
# what we seeded. If it differs, you changed it — hands off, just say so.
stage "7/11  DMS session state (pins / wallpaper)"

seed_n=0
while IFS=$'\t' read -r sfile pins_seeded; do
    [ -n "${sfile:-}" ] || continue
    seed_n=$((seed_n+1))
    if was_restored "$sfile"; then
        ok "$sfile was restored from its pre-install backup — seeded pins went with it."
        continue
    fi
    if [ ! -f "$sfile" ]; then info "$sfile no longer exists — nothing to do."; continue; fi

    cur_bar="$(jq -c '(.barPinnedApps // [])' "$sfile" 2>/dev/null)"
    cur_dock="$(jq -c '(.pinnedApps // [])' "$sfile" 2>/dev/null)"
    seeded="$(printf '%s' "$pins_seeded" | jq -c 'sort' 2>/dev/null)"
    info "pins we seeded : $pins_seeded"
    info "taskbar now    : $cur_bar"
    info "dock now       : $cur_dock"

    bar_same=0; dock_same=0
    [ "$(printf '%s' "$cur_bar"  | jq -c 'sort' 2>/dev/null)" = "$seeded" ] && bar_same=1
    [ "$(printf '%s' "$cur_dock" | jq -c 'sort' 2>/dev/null)" = "$seeded" ] && dock_same=1

    if [ "$bar_same" = 1 ] && [ "$dock_same" = 1 ]; then
        info "Both lists still match what DankMango seeded — you haven't customised them."
        if ask_yn "Clear the seeded pins from session.json?"; then
            cp -a "$sfile" "$(rescue_path "$sfile")".pre-clear 2>/dev/null || \
                { mkdir -p "$(dirname "$(rescue_path "$sfile")")"; cp -a "$sfile" "$(rescue_path "$sfile")".pre-clear; }
            tmp="$(mktemp)"
            if jq '.barPinnedApps = [] | .pinnedApps = []' "$sfile" > "$tmp" && [ -s "$tmp" ]; then
                cat "$tmp" > "$sfile"; ok "cleared seeded pins (a copy of the old file is in the rescue dir)"
                REMOVED+=("seeded pins in $sfile")
            else warn "couldn't edit $sfile — left as-is"; fi
            rm -f "$tmp"
        else
            LEFT+=("$sfile pins — kept, by your choice")
        fi
    else
        warn "your pins no longer match what DankMango seeded — NOT touching them."
        info "  You've pinned/unpinned apps since install, so this is your state now, not ours."
        info "  Remove any leftovers via DMS: right-click the icon -> Unpin."
        LEFT+=("$sfile pins — customised since install; not touched")
    fi

    # The wallpaper seed points into ~/Pictures/Wallpapers, which stage 5b may have
    # emptied. Report rather than act: picking a wallpaper for you is not uninstalling.
    cur_wp="$(jq -r '(.wallpaperPath // "")' "$sfile" 2>/dev/null)"
    if [ -n "$cur_wp" ] && [ ! -f "$cur_wp" ]; then
        warn "session.json still points at a wallpaper that no longer exists:"
        info "  $cur_wp"
        MANUAL+=("pick a new wallpaper in DMS — the seeded one was removed with DankMango's files")
    fi
done < <(jq -r '(.systemChanges // [])[] | select(.type=="session-seed")
                | [(.detail.file // ""), ((.detail.pinsSeeded // []) | tostring)] | @tsv' "$MANIFEST")
[ "$seed_n" = 0 ] && info "no session seeding recorded."

# =============================================================================
# 8. Services, themes and settings
# =============================================================================
stage "8/11  Services, login theme and settings"

# 8a. Services we enabled. Opt-in: keyd in particular may now be carrying keybinds
# you rely on well beyond DankMango.
svc_n=0
while IFS=$'\t' read -r svc profile; do
    [ -n "${svc:-}" ] || continue
    svc_n=$((svc_n+1))
    echo
    info "service enabled by DankMango: $svc"
    [ -n "${profile:-}" ] && info "  (it also set the '$profile' power profile)"
    case "$svc" in
        keyd) info "  Note: keyd remaps your keyboard. If you've added your own binds, keep it." ;;
    esac
    if ask_yn "Disable and stop $svc?"; then
        if sudo systemctl disable --now "$svc"; then ok "disabled $svc"; REMOVED+=("service $svc (disabled)")
        else warn "couldn't disable $svc"; MANUAL+=("sudo systemctl disable --now $svc"); fi
    else
        LEFT+=("service $svc — still enabled, by your choice")
    fi
    if [ "$svc" = power-profiles-daemon ] && [ -n "${profile:-}" ] && have powerprofilesctl; then
        ask_yn "Reset the power profile to 'balanced'?" && \
            { powerprofilesctl set balanced && ok "power profile -> balanced"; } || true
    fi
done < <(jq -r '(.systemChanges // [])[] | select(.type=="service-enabled")
                | [(.detail.service // .key), (.detail.profile // "")] | @tsv' "$MANIFEST")
[ "$svc_n" = 0 ] && info "no services recorded."

# 8b. SDDM theme. The file it writes is /etc/sddm.conf.d/theme.conf; if that had a
# previous version, stage 3 already restored it and there's nothing to remove.
sddm_n=0
while IFS= read -r w; do
    [ -n "$w" ] || continue
    sddm_n=$((sddm_n+1))
    if was_restored "$w"; then ok "$w restored to its pre-DankMango version."; continue; fi
    [ -f "$w" ] || { info "$w already gone."; continue; }
    echo
    info "SDDM login theme is set by: $w"
    info "  Removing it reverts the login screen to SDDM's default."
    if ask_yn "Remove $w? (needs sudo)"; then
        if rescue_move "$w" 1; then ok "removed $w"; REMOVED+=("$w"); fi
    else
        LEFT+=("$w — login theme kept, by your choice")
    fi
done < <(jq -r '(.systemChanges // [])[] | select(.type=="sddm-theme-applied") | (.detail.writes // [])[]' "$MANIFEST")
[ "$sddm_n" = 0 ] && info "no SDDM theme changes recorded."

# 8c. config-edit / default-app: things with no safe automatic reversal. install.sh
# recorded a 'reversal' hint for each — surface it verbatim rather than acting.
while IFS=$'\t' read -r type key rev; do
    [ -n "${key:-}" ] || continue
    echo
    info "$type: $key"
    if [ -n "${rev:-}" ]; then
        info "  install.sh's recorded reversal: $rev"
        MANUAL+=("$key — $rev")
    else
        MANUAL+=("$key — no reversal recorded; check this by hand")
    fi
done < <(jq -r '(.systemChanges // [])[] | select(.type=="config-edit" or .type=="default-app")
                | [.type, (.key // "?"), (.reversal // "")] | @tsv' "$MANIFEST")

# 8d. Forward-compat: anything this script has no handler for. A manifest written by
# a NEWER install.sh must not be silently ignored.
while IFS=$'\t' read -r type key rev; do
    [ -n "${type:-}" ] || continue
    warn "unrecognised change type '$type' ($key) — not touched."
    [ -n "${rev:-}" ] && info "  recorded reversal: $rev"
    MANUAL+=("$type / $key — ${rev:-no reversal recorded} (this uninstaller is older than your manifest)")
done < <(jq -r '(.systemChanges // [])[]
                | select(.type | IN("system-file-installed","user-file-installed","owned-tree",
                                    "files-generated","files-copied","config-edit","default-app",
                                    "service-enabled","sddm-theme-applied","patch-applied","session-seed") | not)
                | [.type, (.key // "?"), (.reversal // "")] | @tsv' "$MANIFEST")

# =============================================================================
# 9. Packages
# =============================================================================
# Deliberately last and deliberately opt-in, per category, default NO. Only
# .packages is offered — packagesSkipped predate us and packagesFailed never
# installed. Anything another installed package depends on is filtered out first.
stage "9/11  Packages DankMango installed"

if [ "$n_pkgs" = 0 ]; then
    info "no packages recorded as installed by DankMango."
else
    info "These were installed BY DankMango. Many are useful on their own —"
    info "the default for every prompt below is to KEEP them."
    [ "$n_skip" != 0 ] && info "($n_skip package(s) you already had are not listed and will never be touched.)"

    for cat in required standard-app optional-feature; do
        mapfile -t grp < <(jq -r --arg c "$cat" '(.packages // [])[] | select(.category==$c) | .name' "$MANIFEST")
        [ "${#grp[@]}" -gt 0 ] || continue
        echo
        case "$cat" in
            required)         info "REQUIRED — DankMango's own dependencies. Some are general-purpose"
                              info "tools (jq, rsync, matugen...) that other things on this system may use." ;;
            standard-app)     info "STANDARD APPS — the optional everyday apps (stage 3's opt-in prompt)." ;;
            optional-feature) info "OPTIONAL FEATURES — installed for an extra you opted into." ;;
        esac
        info "  ${grp[*]}"
        ask_yn "Remove the $cat packages?" || { LEFT+=("$cat packages (${#grp[@]}) — kept"); continue; }

        # Filter out anything still depended on. pacman would refuse the whole
        # transaction over one such package; checking first means the rest still go.
        keep=(); rm_list=()
        for p in "${grp[@]}"; do
            pacman -Qi "$p" >/dev/null 2>&1 || { info "  $p is not installed — skipping"; continue; }
            reqby="$(pacman -Qi "$p" 2>/dev/null | awk -F': ' '/^Required By/{print $2}')"
            if [ -n "$reqby" ] && [ "$reqby" != "None" ]; then
                warn "  keeping $p — still required by: $reqby"; keep+=("$p")
            else
                rm_list+=("$p")
            fi
        done
        [ "${#keep[@]}" -gt 0 ] && LEFT+=("${keep[*]} — kept: other packages depend on them")
        if [ "${#rm_list[@]}" -eq 0 ]; then info "  nothing removable in this group."; continue; fi
        echo
        info "  Will run: sudo pacman -Rs ${rm_list[*]}"
        info "  (-Rs also removes dependencies nothing else needs; your configs are kept as .pacsave)"
        if ask_yn "Run that now?"; then
            if sudo pacman -Rs "${rm_list[@]}"; then
                ok "removed: ${rm_list[*]}"; PKGS_REMOVED+=("${rm_list[@]}")
            else
                warn "pacman removal failed or was cancelled — packages left installed."
                MANUAL+=("sudo pacman -Rs ${rm_list[*]}")
            fi
        else
            LEFT+=("${rm_list[*]} — kept")
        fi
    done
fi

# =============================================================================
# 10. The manifest itself
# =============================================================================
stage "10/11  The manifest"

info "The manifest is the only record of what DankMango did here."
info "Keep it if you might reinstall or still want to check something."
if ask_yn "Archive the manifest into the rescue dir? (it stops being the live record)"; then
    if rescue_move "$MANIFEST" 0; then ok "archived -> $(rescue_path "$MANIFEST")"; fi
else
    info "kept at $MANIFEST"
fi

# =============================================================================
# 11. Summary
# =============================================================================
stage "11/11  Summary"

print_list() {
    local title="$1"; shift
    echo; info "$title"
    if [ "$#" -eq 0 ]; then info "  (none)"; else printf '      - %s\n' "$@"; fi
}

print_list "RESTORED to their pre-DankMango state:" ${RESTORED[@]+"${RESTORED[@]}"}
print_list "REMOVED (moved to the rescue dir, not deleted):" ${REMOVED[@]+"${REMOVED[@]}"}
print_list "PACKAGES removed:" ${PKGS_REMOVED[@]+"${PKGS_REMOVED[@]}"}
print_list "LEFT ALONE (and why):" ${LEFT[@]+"${LEFT[@]}"}
print_list "STILL FOR YOU TO DO:" ${MANUAL[@]+"${MANUAL[@]}"}

echo
info "Packages you already had before DankMango were never touched."
[ "$n_fail" != 0 ] && info "Packages that failed to install were never on this system to begin with."

echo
if [ -d "$RESCUE" ]; then
    ok "Everything removed is recoverable here:"
    info "  $RESCUE"
    info "It mirrors the original paths, so you can copy anything back by hand."
    info "Delete it when you're happy: rm -rf $RESCUE"
else
    info "Nothing was removed, so no rescue dir was created."
fi

echo
info "Log out / reboot to leave the DankMango session cleanly."
if [ "$WARNINGS" -gt 0 ]; then
    warn "finished with $WARNINGS warning(s) — read them above before deleting the rescue dir."
else
    ok "uninstall finished with no warnings."
fi
