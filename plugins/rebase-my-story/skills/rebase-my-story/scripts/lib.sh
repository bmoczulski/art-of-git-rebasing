# Shared helpers for the rebase-my-story scripts. Source, don't execute.

say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
pass() { printf '  PASS  %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; WARNINGS=$((${WARNINGS:-0} + 1)); }
fail() { printf '  FAIL  %s\n' "$*"; FAILURES=$((${FAILURES:-0} + 1)); }
die()  { printf 'error: %s\n' "$*" >&2; exit 2; }

git_version() { git --version | sed -E 's/^git version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/'; }

# version_ge 2.38 -> true when the installed git is at least that version
version_ge() {
    local have_major have_minor want_major want_minor
    IFS=. read -r have_major have_minor _ <<VERSION
$(git_version)
VERSION
    IFS=. read -r want_major want_minor _ <<VERSION
$1
VERSION
    [ "$have_major" -gt "$want_major" ] || { [ "$have_major" -eq "$want_major" ] && [ "${have_minor:-0}" -ge "${want_minor:-0}" ]; }
}

# Prints the name of any operation in progress (rebase, merge, ...) or nothing.
operation_in_progress() {
    local p
    for p in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
        if [ -e "$(git rev-parse --git-path "$p")" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 0
}

session_root() { git rev-parse --git-path reshape-history; }

# Loads the newest session (or the one given) into OLD_TIP, OLD_BASE, BASE_SPEC, BRANCH, BACKUP_REF.
load_session() {
    local dir=${1:-}
    if [ -z "$dir" ]; then
        [ -f "$(session_root)/latest" ] || die "no session found; run preflight.sh first"
        dir=$(cat "$(session_root)/latest")
    fi
    [ -f "$dir/session.env" ] || die "not a session directory: $dir"
    # shellcheck disable=SC1091
    . "$dir/session.env"
    SESSION_DIR=$dir
}

# Settings (key=value) passed with -c to every rewrite: better conflict markers, reuse of recorded
# resolutions, refuse silently dropped commits. Never written to the user's config.
rewrite_config_args() {
    printf '%s\n' rerere.enabled=true rebase.missingCommitsCheck=error \
        rebase.abbreviateCommands=false advice.detachedHead=false
    if version_ge 2.35; then
        printf '%s\n' merge.conflictStyle=zdiff3
    else
        printf '%s\n' merge.conflictStyle=diff3
    fi
}

# After a rebase command: explains where it stopped (exit 3) or confirms it finished.
report_rebase_state() {
    local status=$1 conflicted
    if [ -n "$(operation_in_progress)" ]; then
        say ""
        say "== Rebase stopped (exit $status). It is NOT finished."
        if git rev-parse -q --verify REBASE_HEAD >/dev/null; then
            info "replaying: $(git log -1 --format='%h %s' REBASE_HEAD)"
        fi
        conflicted=$(git diff --name-only --diff-filter=U)
        if [ -n "$conflicted" ]; then
            info "conflicted paths:"
            printf '%s\n' "$conflicted" | sed 's/^/    /'
            info "resolve by intent (reference/conflicts.md), 'git add' each path, then run continue.sh"
        elif git rev-parse -q --verify HEAD~1 >/dev/null && git diff --cached --quiet HEAD~1 && ! git diff --cached --quiet HEAD; then
            info "the fixup/squash would leave '$(git log -1 --format=%s HEAD)' EMPTY: together they change nothing."
            info "to drop both (usual choice):  git reset --soft HEAD~1   then run continue.sh"
            info "continuing as is would record an empty commit"
        else
            info "stopped at an 'edit', 'break' or failed 'exec' line, or a commit became empty."
            info "read the message above, do the work, then run continue.sh"
        fi
        info "to give up and restore the starting point: git rebase --abort"
        exit 3
    fi
    [ "$status" -eq 0 ] || die "git rebase failed (exit $status); read its message above"
    say "== Rebase finished. Run verify.sh next."
}
