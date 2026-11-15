#!/usr/bin/env bash
# Usage: continue.sh [--skip]
#
# Continues a stopped rebase with the same per-command settings run-plan.sh used
# (zdiff3, rerere), never opening an editor. Refuses while conflicts are unresolved
# or conflict markers are still staged. --skip drops the current commit: use it only
# when you have proven the commit is already contained in the new base.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

action=--continue
[ "${1:-}" = "--skip" ] && action=--skip
[ -n "$(operation_in_progress)" ] || die "no rebase in progress"

if [ "$action" = --continue ]; then
    [ -z "$(git diff --name-only --diff-filter=U)" ] || die "unresolved paths remain: $(git diff --name-only --diff-filter=U | tr '\n' ' ')"
    if git diff --cached -U0 | grep -Eq '^\+(<<<<<<<|\|\|\|\|\|\|\||>>>>>>>)( |$)'; then
        die "staged content still contains conflict markers; finish resolving"
    fi
fi

cfg_args=()
while IFS= read -r kv; do cfg_args+=(-c "$kv"); done < <(rewrite_config_args)
set +e
GIT_EDITOR=true git "${cfg_args[@]}" rebase "$action"
status=$?
set -e
report_rebase_state "$status"
