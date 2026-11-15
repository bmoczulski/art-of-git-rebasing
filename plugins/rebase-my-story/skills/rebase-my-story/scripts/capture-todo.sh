#!/usr/bin/env bash
# Usage: capture-todo.sh <output-file> <git rebase arguments...>
#
# Shows the todo list Git *would* run for an interactive rebase, without running it.
# The sequence editor saves the list and then fails, which makes Git abort the rebase
# before touching anything. Example:
#   capture-todo.sh /tmp/todo.txt --autosquash --keep-base origin/main
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

out=${1:-}
[ -n "$out" ] && [ $# -ge 2 ] || die "usage: capture-todo.sh <output-file> <git rebase arguments...>"
shift
[ -z "$(operation_in_progress)" ] || die "an operation is already in progress"

before=$(git rev-parse HEAD)
out_abs=$(cd "$(dirname "$out")" && pwd)/$(basename "$out")
export CAPTURE_TODO_OUT=$out_abs
err=$(mktemp)
trap 'rm -f "$err"' EXIT
rm -f "$out_abs"
# Git runs the editor as '<editor> <todo-file>'; the function receives that path.
# shellcheck disable=SC2016
GIT_SEQUENCE_EDITOR='capture() { cp "$1" "$CAPTURE_TODO_OUT"; exit 1; }; capture' GIT_EDITOR=true \
    git -c rebase.abbreviateCommands=false rebase -i "$@" >/dev/null 2>"$err" || true

[ "$(git rev-parse HEAD)" = "$before" ] || die "HEAD moved while capturing; inspect 'git reflog' now"
[ -z "$(operation_in_progress)" ] || die "a rebase was left in progress; run 'git rebase --abort'"
if [ ! -s "$out_abs" ]; then
    grep -v 'problem with the editor' "$err" >&2 || true
    die "no todo captured; Git's message is above"
fi
grep -v '^#' "$out_abs" | sed '/^$/d'
