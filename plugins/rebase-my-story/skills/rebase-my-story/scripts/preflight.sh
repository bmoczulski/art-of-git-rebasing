#!/usr/bin/env bash
# Usage: preflight.sh <base> [--allow-dirty]
#
# Checks that the repository is safe to rewrite, describes the range <base>..HEAD,
# creates a backup ref and records a session that verify.sh compares against.
# Exit codes: 0 = ready, 1 = ready with warnings that need the user's attention, 2 = stop.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

base_spec=${1:-}
allow_dirty=no
[ "${2:-}" = "--allow-dirty" ] && allow_dirty=yes
[ -n "$base_spec" ] || die "usage: preflight.sh <base> [--allow-dirty]"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree"

say "== Git"
info "version $(git_version)"
for f in "2.24 rebase --keep-base" "2.30 push --force-if-includes" "2.32 commit --fixup=amend:/reword:" \
         "2.35 merge.conflictStyle=zdiff3" "2.38 rebase --update-refs" "2.40 merge-tree --merge-base"; do
    v=${f%% *}; name=${f#* }
    if version_ge "$v"; then info "yes  $name"; else info "NO   $name (needs $v)"; fi
done

say "== State"
op=$(operation_in_progress)
[ -z "$op" ] || die "an operation is in progress ($op). Finish or abort it first; do not guess which."

branch=$(git symbolic-ref --quiet --short HEAD || true)
if [ -z "$branch" ]; then
    die "HEAD is detached. Check out the branch to rewrite (rewriting a detached HEAD leaves no branch pointing at the result)."
fi
info "branch $branch"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    if [ "$allow_dirty" = yes ]; then
        warn "uncommitted changes to tracked files; they stay in the work tree and are NOT part of the backup"
    else
        die "uncommitted changes to tracked files. Ask the user: commit them, stash them, or rerun with --allow-dirty if they are the review fixes to absorb."
    fi
fi
untracked=$(git status --porcelain --untracked-files=normal | grep -c '^??' || true)
[ "$untracked" -eq 0 ] || info "$untracked untracked path(s) present; never 'git add -A' or 'git add .' during the rewrite"

say "== Range"
base_commit=$(git rev-parse --verify --quiet "$base_spec^{commit}") || die "cannot resolve base '$base_spec'"
merge_base=$(git merge-base "$base_commit" HEAD) || die "'$base_spec' and HEAD share no history"
tip=$(git rev-parse HEAD)
count=$(git rev-list --count "$merge_base..$tip")
[ "$count" -gt 0 ] || die "no commits in $base_spec..HEAD"
info "base     $base_spec ($(git rev-parse --short "$base_commit"))"
info "fork at  $(git log -1 --format='%h %s' "$merge_base")"
if [ "$merge_base" != "$base_commit" ]; then
    behind=$(git rev-list --count "$merge_base..$base_commit")
    info "the base has moved on by $behind commit(s) since the branch forked"
fi
info "$count commit(s) to consider:"
git log --reverse --format='    %h %<(20,trunc)%an %s' "$merge_base..$tip"

merges=$(git rev-list --merges --count "$merge_base..$tip")
[ "$merges" -eq 0 ] || warn "$merges merge commit(s) in range. A plain rebase flattens them. Ask: linearise, or keep them with --rebase-merges?"

authors=$(git log --format='%an <%ae>' "$merge_base..$tip" | sort -u)
if [ "$(printf '%s\n' "$authors" | wc -l)" -gt 1 ]; then
    warn "commits by more than one author. Rewriting other people's commits needs their consent:"
    printf '%s\n' "$authors" | sed 's/^/        /'
fi

signed=0
for c in $(git rev-list "$merge_base..$tip"); do
    git cat-file commit "$c" | sed '/^$/q' | grep -q '^gpgsig' && signed=$((signed + 1))
done
if [ "$signed" -gt 0 ]; then
    if [ "$(git config --bool commit.gpgSign || true)" = true ]; then
        sign_note="commit.gpgSign is on, so Git signs the rewritten commits with the user's key"
    else
        sign_note="commit.gpgSign is off, so the rewritten commits will be unsigned"
    fi
    warn "$signed signed commit(s): signatures never survive a rewrite ($sign_note)."
    warn "check the project's signing policy (CONTRIBUTING, developer docs, CI); ask if unclear. Never add -S or --no-gpg-sign yourself."
fi

say "== Who else has these commits"
upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
if [ -n "$upstream" ]; then
    pushed=$(git rev-list --count "$merge_base..$tip" ^"$(git merge-base "$tip" "$upstream")" 2>/dev/null || echo 0)
    on_upstream=$((count - pushed))
    if [ "$on_upstream" -gt 0 ]; then
        info "$on_upstream commit(s) already on $upstream: publishing the result will need a force push"
    else
        info "upstream $upstream does not have these commits yet"
    fi
else
    info "no upstream configured"
fi

others=$(git for-each-ref --format='%(refname)' refs/heads refs/remotes refs/tags |
    grep -v -x -F -e "refs/heads/$branch" ${upstream:+-e "refs/remotes/$upstream"} || true)
shared=0
if [ -n "$others" ]; then
    oldest_shared=""
    for c in $(git rev-list --reverse "$merge_base..$tip"); do
        holders=$(git for-each-ref --contains "$c" --format='%(refname:short)' $others | grep -v -x 'origin/HEAD' || true)
        if [ -n "$holders" ]; then
            shared=$((shared + 1))
            [ -n "$oldest_shared" ] || oldest_shared="$c"$'\n'"$holders"
        fi
    done
    if [ "$shared" -gt 0 ]; then
        warn "$shared commit(s) are also reachable from other branches or tags. Someone may have built on them."
        warn "first such commit $(git log -1 --format='%h %s' "${oldest_shared%%$'\n'*}"), held by:"
        printf '%s\n' "${oldest_shared#*$'\n'}" | sed 's/^/        /'
        info "if those are the user's own stacked branches, rebase the TOPMOST branch with --update-refs"
        info "(it only moves branches that point inside the rebased range); otherwise ask before rewriting"
    fi
fi
[ "$shared" -gt 0 ] || pass "no other branch or tag contains these commits"

say "== Backup"
ts=$(date +%Y%m%d-%H%M%S)
backup_ref="refs/reshape-backup/$branch/$ts"
git update-ref "$backup_ref" "$tip"
session_dir="$(session_root)/$ts"
mkdir -p "$session_dir"
{
    printf 'OLD_TIP=%q\n' "$tip"
    printf 'OLD_BASE=%q\n' "$merge_base"
    printf 'BASE_SPEC=%q\n' "$base_spec"
    printf 'BRANCH=%q\n' "$branch"
    printf 'BACKUP_REF=%q\n' "$backup_ref"
} > "$session_dir/session.env"
git log --reverse --format='%H %s' "$merge_base..$tip" > "$session_dir/old-commits.txt"
printf '%s\n' "$session_dir" > "$(session_root)/latest"
info "backup ref  $backup_ref"
info "session     $session_dir"
info "restore     git reset --hard $backup_ref   (only with the user's agreement)"

if [ "${WARNINGS:-0}" -gt 0 ]; then
    say "== Ready, with ${WARNINGS} warning(s): raise them with the user before rewriting"
    exit 1
fi
say "== Ready"
