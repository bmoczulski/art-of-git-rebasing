#!/usr/bin/env bash
# Usage: run-plan.sh <todo-file> <git rebase arguments...>
#
# Runs an interactive rebase with the given todo list instead of opening an editor.
# Adds safe per-command settings (zdiff3 markers, rerere, refuse silently dropped
# commits) without changing the user's config. No editor is ever opened: squash and
# reword lines would keep the default message, so use fixup / fixup -C / exec instead.
# Example:
#   run-plan.sh /tmp/plan.txt --keep-base origin/main
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

plan=${1:-}
[ -n "$plan" ] && [ -f "$plan" ] && [ $# -ge 2 ] || die "usage: run-plan.sh <todo-file> <git rebase arguments...>"
shift
[ -z "$(operation_in_progress)" ] || die "an operation is already in progress"
if grep -Eq '^(r|reword|s|squash)[[:space:]]' "$plan"; then
    die "the plan uses reword/squash, which need an editor. Use 'pick' + 'exec git commit --amend -F <file>', or 'fixup -C'."
fi

plan_abs=$(cd "$(dirname "$plan")" && pwd)/$(basename "$plan")
cfg_args=()
while IFS= read -r kv; do cfg_args+=(-c "$kv"); done < <(rewrite_config_args)

export RUN_PLAN_FILE=$plan_abs
set +e
# Git runs the editor as '<editor> <todo-file>', so this copies the plan over the todo.
# shellcheck disable=SC2016
GIT_SEQUENCE_EDITOR='cp "$RUN_PLAN_FILE"' GIT_EDITOR=true \
    git "${cfg_args[@]}" rebase -i "$@"
status=$?
set -e

report_rebase_state "$status"
