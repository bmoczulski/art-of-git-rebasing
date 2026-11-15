#!/usr/bin/env bash
# Usage: each-commit.sh [--keep-going] [--clean] <range> -- <command...>
#
# Checks out every commit of <range> (oldest first) in a temporary worktree and runs
# <command> there, so the user's work tree is never touched. Use it to prove that every
# commit builds and passes tests, or to run linters and formatters per commit.
#   each-commit.sh origin/main..HEAD -- make -j8 test
#   each-commit.sh --keep-going origin/main..HEAD -- sh -c 'npm ci && npm test'
# --clean runs 'git clean -ffdx' in the temporary worktree before each commit
# (slower, but no build output leaks from one commit to the next).
# The temporary worktree's path is exported as EACH_COMMIT_WORKTREE and the commit as
# EACH_COMMIT. Exit code: number of failing commits (capped at 125), 0 = all passed.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

keep_going=no
clean=no
while [ $# -gt 0 ]; do
    case $1 in
        --keep-going) keep_going=yes; shift ;;
        --clean) clean=yes; shift ;;
        *) break ;;
    esac
done
range=${1:-}
[ -n "$range" ] && [ "${2:-}" = "--" ] && [ $# -ge 3 ] || die "usage: each-commit.sh [--keep-going] [--clean] <range> -- <command...>"
shift 2

commits=()
while IFS= read -r c; do commits+=("$c"); done < <(git rev-list --reverse "$range")
[ ${#commits[@]} -gt 0 ] || die "no commits in $range"

wt=$(mktemp -d "${TMPDIR:-/tmp}/each-commit.XXXXXX")
cleanup() { git worktree remove --force "$wt" >/dev/null 2>&1 || info "could not remove temporary worktree $wt"; git worktree prune; }
trap cleanup EXIT
git worktree add --quiet --detach "$wt" "${commits[0]}"
if [ -f "$(git rev-parse --show-toplevel)/.gitmodules" ]; then
    info "note: the repository has submodules; the command must initialise them if it needs them"
fi

failed=0
n=0
for c in "${commits[@]}"; do
    n=$((n + 1))
    label="[$n/${#commits[@]}] $(git log -1 --format='%h %s' "$c")"
    git -C "$wt" checkout --quiet --detach --force "$c"
    [ "$clean" = no ] || git -C "$wt" clean -ffdxq
    log="$wt.log.$n"
    if (cd "$wt" && EACH_COMMIT=$c EACH_COMMIT_WORKTREE=$wt "$@") >"$log" 2>&1; then
        pass "$label"
    else
        fail "$label"
        tail -n 30 "$log" | sed 's/^/        | /'
        failed=$((failed + 1))
        if [ "$keep_going" = no ]; then
            info "stopped at the first failure (use --keep-going to test all commits)"
            break
        fi
    fi
    rm -f "$log"
done
[ "$failed" -eq 0 ] && say "== All ${#commits[@]} commit(s) passed" || say "== $failed commit(s) failed"
exit $(( failed > 125 ? 125 : failed ))
