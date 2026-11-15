#!/usr/bin/env bash
# Usage: prove-mechanical.sh <commit> whitespace
#        prove-mechanical.sh <commit> move
#        prove-mechanical.sh <commit> rename
#        prove-mechanical.sh <commit> formatter -- <format command...>
#
# Checks that a commit claiming to be mechanical really changes no behaviour.
#   whitespace  the diff is empty when whitespace and blank lines are ignored
#   move        every removed line reappears as an added line (code moved or reordered,
#               indentation may change); lines that don't match are printed
#   rename      files renamed with 100% similarity, plus a table of every distinct word
#               replacement in the diff, which should show only the renamed symbol(s)
#   formatter   running <format command> on the parent gives exactly this commit's tree
# Exit 0 = proven, 1 = not proven (the output shows why), 2 = usage error.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

c=${1:-}
kind=${2:-}
[ -n "$c" ] && [ -n "$kind" ] || die "usage: prove-mechanical.sh <commit> whitespace|move|rename|formatter [-- cmd...]"
c=$(git rev-parse -q --verify "$c^{commit}") || die "not a commit: ${1}"   # a hash: "HEAD" means something else inside a worktree
label=$(git log -1 --format='%h %s' "$c")

case $kind in
whitespace)
    if git diff --quiet -w --ignore-blank-lines "$c^" "$c"; then
        pass "$label: only whitespace and blank lines change"
    else
        fail "$label: changes beyond whitespace:"
        git diff --stat -w --ignore-blank-lines "$c^" "$c" | sed 's/^/        /'
        exit 1
    fi
    ;;
move)
    lines() { git diff -U0 --no-color --no-renames "$c^" "$c" | grep -E "^\\$1" | grep -vE "^\\$1\\$1\\$1 " |
              sed -E "s/^\\$1[[:space:]]*//; s/[[:space:]]+\$//" | sed '/^$/d' | sort; }
    if out=$(diff <(lines -) <(lines +)); then
        pass "$label: every removed line reappears unchanged (pure move/reorder, indentation aside)"
    else
        fail "$label: lines that were not simply moved ('<' only removed, '>' only added):"
        printf '%s\n' "$out" | grep -E '^[<>]' | sed 's/^/        /'
        exit 1
    fi
    ;;
rename)
    info "$label"
    info "file renames and their similarity (R100 = content unchanged):"
    git diff --name-status --find-renames "$c^" "$c" | sed 's/^/        /'
    info "distinct word replacements (count, [-old-]{+new+}):"
    git diff -U0 --no-color --word-diff=plain --find-renames "$c^" "$c" |
        grep -oE '\[-[^]]*-\]\{\+[^}]*\+\}|\[-[^]]*-\]|\{\+[^}]*\+\}' | sort | uniq -c | sort -rn | sed 's/^/        /' || true
    info "proven only if every replacement above is the rename itself; anything else is a behaviour change"
    ;;
formatter)
    [ "${3:-}" = "--" ] && [ $# -ge 4 ] || die "usage: prove-mechanical.sh <commit> formatter -- <format command...>"
    shift 3
    wt=$(mktemp -d "${TMPDIR:-/tmp}/prove-fmt.XXXXXX")
    trap 'git worktree remove --force "$wt" >/dev/null 2>&1 || info "could not remove temporary worktree $wt"; git worktree prune' EXIT
    git worktree add --quiet --detach "$wt" "$c^"
    (cd "$wt" && "$@") >/dev/null 2>&1 || warn "the format command exited non-zero"
    git -C "$wt" add -A
    if git -C "$wt" diff --cached --quiet "$c"; then
        pass "$label: formatting the parent reproduces this commit exactly"
    else
        fail "$label: differs from the formatted parent:"
        git -C "$wt" diff --cached --stat "$c" | sed 's/^/        /'
        exit 1
    fi
    ;;
*) die "unknown kind '$kind'" ;;
esac
