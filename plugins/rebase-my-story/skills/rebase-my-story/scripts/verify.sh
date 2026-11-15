#!/usr/bin/env bash
# Usage: verify.sh [--allow-content-change] [--session <dir>]
#
# Compares the rewritten branch (HEAD) with the backup preflight.sh recorded, and checks
# every new commit. It proves *mechanical* properties only; it does not replace reading
# the range-diff and the commits yourself (see reference/verification.md).
#
#  1. Content: if the base did not move, the final tree must be identical to the old tip.
#     If the base moved, the final tree must equal what Git merges on its own
#     (merge-tree with the old fork point as merge base); only conflicted files may differ.
#     --allow-content-change turns unexplained differences from FAIL into WARN, for when
#     the user asked for code changes. Every difference still has to be explained.
#  2. range-diff old vs new, saved to the session directory and summarised.
#  3. Per commit: leftover fixup!/squash!/amend! subjects, WIP subjects, empty commits,
#     conflict markers, whitespace errors, long subjects, merges.
#  4. Metadata: authors, Signed-off-by and other trailers; signature counts for information.
# Exit code: 0 = no failures, 1 = failures.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

allow_change=no
session=""
while [ $# -gt 0 ]; do
    case $1 in
        --allow-content-change) allow_change=yes; shift ;;
        --session) session=$2; shift 2 ;;
        *) die "unknown argument $1" ;;
    esac
done
load_session "$session"

[ -z "$(operation_in_progress)" ] || die "an operation is still in progress; finish the rebase first"
current=$(git symbolic-ref --quiet --short HEAD || true)
[ "$current" = "$BRANCH" ] || die "expected to be on $BRANCH, but HEAD is '${current:-detached}'"
git rev-parse -q --verify "$BACKUP_REF" >/dev/null || die "backup ref $BACKUP_REF is gone"

NEW_TIP=$(git rev-parse HEAD)
NEW_BASE=$(git merge-base "$BASE_SPEC" "$NEW_TIP")
say "== Comparing"
info "old  $(git rev-parse --short "$OLD_BASE")..$(git rev-parse --short "$OLD_TIP")  ($(git rev-list --count "$OLD_BASE..$OLD_TIP") commits)"
info "new  $(git rev-parse --short "$NEW_BASE")..$(git rev-parse --short "$NEW_TIP")  ($(git rev-list --count "$NEW_BASE..$NEW_TIP") commits)"
if [ "$NEW_TIP" = "$OLD_TIP" ]; then
    info "HEAD is unchanged: nothing was rewritten"
fi

content_problem() { if [ "$allow_change" = yes ]; then warn "$@"; else fail "$@"; fi; }

say "== 1. Content"
if [ "$NEW_BASE" = "$OLD_BASE" ]; then
    if [ "$(git rev-parse "$OLD_TIP^{tree}")" = "$(git rev-parse "$NEW_TIP^{tree}")" ]; then
        pass "same base, identical final tree: the rewrite changed history only, not code"
    else
        git diff --no-color "$OLD_TIP" "$NEW_TIP" > "$SESSION_DIR/content-diff.txt"
        content_problem "same base, but the final tree differs from the old tip:"
        git diff --stat "$OLD_TIP" "$NEW_TIP" | sed 's/^/        /'
        info "full diff: $SESSION_DIR/content-diff.txt (explain every line of it)"
    fi
elif version_ge 2.40; then
    set +e
    merge_out=$(git merge-tree --write-tree --merge-base="$OLD_BASE" "$NEW_BASE" "$OLD_TIP" 2>/dev/null)
    merge_status=$?
    set -e
    ref_tree=$(printf '%s\n' "$merge_out" | head -n1)
    conflicted=$(printf '%s\n' "$merge_out" | sed -n '2,/^$/p' | sed '/^$/d' | cut -f2- | sort -u)
    git diff --no-color "$ref_tree" "$NEW_TIP" > "$SESSION_DIR/content-diff.txt"
    changed=$(git diff --name-only "$ref_tree" "$NEW_TIP" | sort -u)
    if [ "$merge_status" -eq 0 ] && [ -z "$changed" ]; then
        pass "base moved; final tree equals Git's own merge of the old branch onto the new base"
    else
        unexplained=$(comm -23 <(printf '%s\n' "$changed" | sed '/^$/d') <(printf '%s\n' "$conflicted" | sed '/^$/d'))
        if [ -n "$conflicted" ]; then
            info "files Git could not merge on its own (your conflict resolutions; review each):"
            printf '%s\n' "$conflicted" | sed 's/^/        /'
        fi
        if [ -n "$unexplained" ]; then
            content_problem "files that differ from Git's own merge although it merged them cleanly:"
            printf '%s\n' "$unexplained" | sed 's/^/        /'
        else
            pass "outside the conflicted files, the final tree equals Git's own merge"
        fi
        info "diff against Git's own merge: $SESSION_DIR/content-diff.txt"
    fi
else
    warn "base moved and git < 2.40 has no 'merge-tree --merge-base'; compare content by reading the range-diff"
fi

say "== 2. range-diff"
git range-diff --no-color "$OLD_BASE..$OLD_TIP" "$NEW_BASE..$NEW_TIP" > "$SESSION_DIR/range-diff.txt" || true
pairs=$(grep -E '^ *([0-9]+|-): +[0-9a-f-]+ [=!<>] +([0-9]+|-): ' "$SESSION_DIR/range-diff.txt" || true)
same=$(printf '%s\n' "$pairs" | grep -c ' = ' || true)
changed_c=$(printf '%s\n' "$pairs" | grep -c ' ! ' || true)
old_only=$(printf '%s\n' "$pairs" | grep ' < ' || true)
new_only=$(printf '%s\n' "$pairs" | grep ' > ' || true)
info "$same unchanged, $changed_c changed, $(printf '%s' "$old_only" | grep -c . || true) only in old, $(printf '%s' "$new_only" | grep -c . || true) only in new"
info "full output: $SESSION_DIR/range-diff.txt (read every '!' entry)"
if [ -n "$old_only" ] && [ -n "$new_only" ]; then
    git range-diff --no-color --creation-factor=100 "$OLD_BASE..$OLD_TIP" "$NEW_BASE..$NEW_TIP" \
        > "$SESSION_DIR/range-diff-loose.txt" || true
    info "unpaired commits on both sides; looser pairing (--creation-factor=100, small commits pair badly by default):"
    grep -E '^ *([0-9]+|-): +[0-9a-f-]+ [=!<>] +([0-9]+|-): ' "$SESSION_DIR/range-diff-loose.txt" | sed 's/^/        /'
    info "loose output: $SESSION_DIR/range-diff-loose.txt (a pairing is a guess: confirm it by reading)"
fi
if [ -n "$old_only" ]; then
    warn "commits that no longer exist as such (squashed, split, dropped?). Each must be accounted for:"
    printf '%s\n' "$old_only" | sed 's/^/        /'
fi
if [ -n "$new_only" ]; then
    warn "commits with no counterpart in the old series (from splits or new work?):"
    printf '%s\n' "$new_only" | sed 's/^/        /'
fi

if [ "$NEW_BASE" != "$OLD_BASE" ]; then
    say "== 2b. Base move kept the series"
    # A base move must not reshape: same commits, same order, same messages. The only
    # allowed difference: commits Git dropped because the new base already contains them.
    upstreamed=$(git cherry "$NEW_BASE" "$OLD_TIP" "$OLD_BASE" | sed -n 's/^- //p')
    expected=()
    for c in $(git rev-list --reverse "$OLD_BASE..$OLD_TIP"); do
        printf '%s\n' "$upstreamed" | grep -qx "$c" && continue
        expected+=("$c")
    done
    actual=()
    while IFS= read -r c; do actual+=("$c"); done < <(git rev-list --reverse "$NEW_BASE..$NEW_TIP")
    n_up=$(printf '%s' "$upstreamed" | grep -c . || true)
    [ "$n_up" -eq 0 ] || info "$n_up commit(s) dropped because the new base already contains an equivalent patch"
    if [ ${#expected[@]} -ne ${#actual[@]} ]; then
        fail "expected ${#expected[@]} commit(s) after the base move, found ${#actual[@]}: a base move must not add, drop, split or squash commits"
    else
        i=0; mismatch=0
        while [ $i -lt ${#expected[@]} ]; do
            if [ "$(git log -1 --format=%B "${expected[$i]}")" != "$(git log -1 --format=%B "${actual[$i]}")" ]; then
                fail "commit $((i + 1)) changed its message or moved: '$(git log -1 --format=%s "${expected[$i]}")' became '$(git log -1 --format=%s "${actual[$i]}")'"
                mismatch=1
            fi
            i=$((i + 1))
        done
        [ "$mismatch" -eq 1 ] || pass "same ${#actual[@]} commit(s), same order, same messages"
    fi
    info "each '!' in the range-diff must be explained by a conflict you resolved; any other change to a commit is a mistake"
fi

say "== 3. Commits"
problems_before=$(( ${FAILURES:-0} + ${WARNINGS:-0} ))
old_merges=$(git rev-list --merges --count "$OLD_BASE..$OLD_TIP")
new_merges=$(git rev-list --merges --count "$NEW_BASE..$NEW_TIP")
[ "$new_merges" -le "$old_merges" ] || fail "the new series has $new_merges merge commit(s), the old one had $old_merges"
for c in $(git rev-list --reverse --no-merges "$NEW_BASE..$NEW_TIP"); do
    subject=$(git log -1 --format=%s "$c")
    label="$(git rev-parse --short "$c") $subject"
    case $subject in
        fixup!*|squash!*|amend!*) fail "leftover autosquash commit: $label" ;;
    esac
    if printf '%s' "$subject" | grep -Eiq '^(wip|tmp|temp|todo|xxx)\b|^fix(es)? (review|comments?|typo)s?$'; then
        warn "subject reads like a work-in-progress note: $label"
    fi
    [ "${#subject}" -le 72 ] || warn "subject longer than 72 characters: $label"
    if [ "$(git rev-parse "$c^{tree}")" = "$(git rev-parse "$c^^{tree}")" ]; then
        warn "empty commit (changes nothing): $label"
    fi
    if git diff-tree -p --no-color --no-ext-diff -U0 "$c^" "$c" | grep -Eq '^\+(<<<<<<<|\|\|\|\|\|\|\||>>>>>>>)( |$)'; then
        fail "adds conflict markers: $label"
    fi
    if ! git diff --check "$c^" "$c" >/dev/null 2>&1; then
        warn "whitespace errors (git diff --check $(git rev-parse --short "$c")^ $(git rev-parse --short "$c")): $label"
    fi
done
[ $(( ${FAILURES:-0} + ${WARNINGS:-0} )) -ne "$problems_before" ] || pass "no problems found in individual commits"

say "== 4. Metadata"
# Authors must survive a rewrite; committers are expected to change (whoever Git's config says), so they aren't compared.
old_authors=$(git log --format='%an <%ae>' "$OLD_BASE..$OLD_TIP" | sort -u)
new_authors=$(git log --format='%an <%ae>' "$NEW_BASE..$NEW_TIP" | sort -u)
added_authors=$(comm -13 <(printf '%s\n' "$old_authors") <(printf '%s\n' "$new_authors"))
lost_authors=$(comm -23 <(printf '%s\n' "$old_authors") <(printf '%s\n' "$new_authors"))
[ -z "$added_authors" ] || fail "author(s) not in the old series (split commits must keep the original author: commit -C/--author/--date): $(printf '%s' "$added_authors" | tr '\n' ';')"
[ -z "$lost_authors" ] || warn "author(s) whose commits no longer appear (squashed into someone else's commit?): $(printf '%s' "$lost_authors" | tr '\n' ';')"
[ -n "$added_authors$lost_authors" ] || pass "same set of authors"

trailers() { git log --format='%(trailers:only,unfold)' "$1" | sed '/^$/d' | sort -u; }
lost_trailers=$(comm -23 <(trailers "$OLD_BASE..$OLD_TIP") <(trailers "$NEW_BASE..$NEW_TIP"))
if [ -n "$lost_trailers" ]; then
    warn "trailers present before but missing now (Signed-off-by, Co-authored-by, ...):"
    printf '%s\n' "$lost_trailers" | sed 's/^/        /'
else
    pass "no trailers lost"
fi

count_signed() {
    local n=0 c
    for c in $(git rev-list "$1"); do
        git cat-file commit "$c" | sed '/^$/q' | grep -q '^gpgsig' && n=$((n + 1))
    done
    printf '%s' "$n"
}
old_signed=$(count_signed "$OLD_BASE..$OLD_TIP")
new_signed=$(count_signed "$NEW_BASE..$NEW_TIP")
# Signatures are not expected to survive a rewrite; signing follows the user's Git config.
info "signatures (information only): $old_signed signed before, $new_signed signed now; signing follows the user's Git config and the project's policy"

say "== Summary"
info "failures: ${FAILURES:-0}, warnings: ${WARNINGS:-0}"
info "still to do yourself: read range-diff.txt, run each-commit.sh with the project's build and tests,"
info "and review each commit's message against its diff (reference/verification.md)"
info "backup: $BACKUP_REF"
[ "${FAILURES:-0}" -eq 0 ]
