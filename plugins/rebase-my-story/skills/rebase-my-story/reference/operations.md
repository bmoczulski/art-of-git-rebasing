# Operations: non-interactive recipes

Every recipe assumes:
- `preflight.sh <base>` has run (there is a backup ref and a session).
- `$K` is the absolute path of this skill's `scripts/` directory, and `$B` is the base.
- No editor ever opens. Export `GIT_EDITOR=true` for the whole session, or prefix commands with it.
- Message files live **outside the work tree**, e.g. `M=$(git rev-parse --git-path reshape-history)`, then `$M/msg-1.txt`. Use absolute paths, because `exec` lines run from the top of the work tree.

## The plan loop

```
$K/capture-todo.sh $M/todo.txt [--autosquash] [--update-refs] --keep-base $B   # what Git would do
# copy todo.txt to plan.txt and edit it: reorder lines, change verbs, add exec lines
$K/run-plan.sh $M/plan.txt [same flags] --keep-base $B
```
Pass the same flags to both scripts. Lines starting with `#` are ignored.

### Todo verbs you may use

| Verb | Meaning | Notes |
|---|---|---|
| `pick <sha>` | replay the commit | |
| `drop <sha>` | remove the commit | only with the user's consent; deleting the line instead is refused |
| `edit <sha>` | replay, then stop | for splits and amends |
| `fixup <sha>` | meld into the previous commit, keep the previous message | |
| `fixup -C <sha>` | meld into the previous commit, use **this** commit's message | |
| `exec <cmd>` | run a shell command; a failure stops the rebase | builds, tests, setting messages |
| `break` | stop here | to inspect |
| `update-ref refs/heads/<b>` | move branch `<b>` to this point at the end | written by `--update-refs`; you may move these lines |
| `label`, `reset`, `merge` | rebuild merges | only with `--rebase-merges` |

**Never** use `reword`, `squash` or `fixup -c`: they open an editor, and `run-plan.sh` refuses them.

## Reword a commit

```
pick 1a2b3c4 Old subject
exec git commit --amend -F /abs/path/msg-1a2b3c4.txt
```
If the commit is the tip and no rebase is needed: `git commit --amend -F <file>`.

`--amend` keeps the original author and author date. Commit hooks (pre-commit, commit-msg) run during `exec`; if one fails, the rebase stops, so read why.

Don't use `git commit --fixup=reword:<sha>` from a script. It refuses `-m`, and an editor script that rewrites the whole template deletes its `amend!` line, so autosquash can't find the target.

## Squash several commits into one

```
pick  aaa Add parser skeleton
fixup bbb Handle empty input
fixup ccc Parser tests
exec git commit --amend -F /abs/path/msg-parser.txt     # only if none of the three messages fits
```
- Use `fixup -C bbb` when bbb's message is the one to keep.
- The result keeps the author of the **first** commit. If the melded commits had other authors, ask the user and add `Co-authored-by: Name <email>` trailers to the message so nobody's credit disappears.
- Keep all `Signed-off-by:` and other trailers of the melded commits.

## Reorder commits

Move the `pick` lines. Before doing so, find out which commits touch the same files:
```
for c in $(git rev-list --reverse $B..HEAD); do echo "$(git log -1 --format=%h $c): $(git diff-tree --no-commit-id --name-only -r $c | tr '\n' ' ')"; done
```
Swapping two commits that change the same lines **will** conflict, and the resolution is real work. If one commit builds on another (it calls a function the other adds), the order is fixed: moving it earlier breaks the build at that commit. `each-commit.sh` will catch that, but planning is cheaper than recovering.

## Split a commit

1. Plan the pieces: for each new commit, which files or hunks and which message.
2. Mark the commit `edit` in the plan and run it. At the stop:
   ```
   orig=$(git rev-parse REBASE_HEAD)       # the commit being split
   git reset -q HEAD~                      # undo the commit, keep its changes in the work tree
   git diff --name-only --diff-filter=A "$orig~" "$orig" | xargs -r git add -N   # files the commit ADDED are untracked now; make them visible
   python3 $K/hunks.py list
   ```
   If the commit is the tip, you don't need a rebase. Run the same steps directly, with `orig=$(git rev-parse HEAD)` before the reset.
3. For each piece, in order: stage it, then commit it with the original authorship:
   ```
   python3 $K/hunks.py stage 1,3      # or: git add <path> for whole files
   python3 $K/hunks.py list --cached  # check what is staged
   git commit -q -F /abs/msg-piece1.txt --author="$(git log -1 --format='%an <%ae>' $orig)" --date="$(git log -1 --format=%aD $orig)"
   python3 $K/hunks.py list           # numbering has changed
   ```
   If a hunk mixes lines that belong to different pieces, use `hunks.py show N > /abs/p.patch` and edit the patch. Delete `+` lines you don't want yet, and turn unwanted `-` lines into context lines by replacing the `-` with a space. Then run `git apply --cached --recount /abs/p.patch`.
4. Prove the split lost nothing, then continue:
   ```
   git diff --quiet "$orig" HEAD && test -z "$(git status --porcelain --untracked-files=no)" && echo "split OK"
   $K/continue.sh
   ```
5. Each piece should build on its own. `each-commit.sh` checks this after the rebase.

Copy the original message's trailers (`Signed-off-by`, `Co-authored-by`, ticket refs) into every piece where they apply.

## Absorb review fixes (fixup + autosquash)

The user has review fixes in the work tree, or as commits at the tip like "address review".
1. If they are commits, undo them into the work tree first (`git reset HEAD~N`, after preflight made a backup).
2. Find each hunk's target:
   ```
   python3 $K/hunks.py targets $B
   ```
   - "confident" means every changed line was last written by that commit. It's still a hint: confirm that the fix belongs there by meaning, not just by line ownership.
   - "ambiguous" means the hunk touches lines from several commits. Split it further, or give it its own commit.
   - "pure addition" is weak evidence. Decide by meaning: which commit is incomplete without these lines?
   - "no target in range" means the lines predate the branch. This is a new change: give it its own commit with a real message, placed where it makes sense.
3. For each target commit: stage its hunks, then `git commit -q --fixup=<target-sha>`. This needs no editor; the message becomes `fixup! <subject>`.
4. Run preflight **now**, so the backup includes the fixup commits and verify can prove the tree is identical.
5. Run `capture-todo.sh $M/todo.txt --autosquash --keep-base $B` and check that every `fixup` line sits under the right commit (autosquash matches by subject). Then run the plan with the same flags.
6. If a fixup now conflicts with a commit between its target and its old position, the fix depends on that later commit. Move the fix into the later commit instead, or keep it separate.

Note: `git absorb` is a separate third-party tool, not part of Git. Don't assume it's installed. Steps 2–5 do the same job with evidence you can show.

## Move a hunk from commit A into a later commit B

Combine the recipes: split A into A' plus H (the hunk), then move H's `pick` line directly below B and change it to `fixup`. Check that A' still builds without H.

To move a hunk to an *earlier* commit, use a fixup: split it out, then put it under the earlier commit as `fixup`.

## Drop a commit

Change its line to `drop` (only with consent). Then check that nothing later depends on it: build every commit. Revert pairs (a commit and its revert inside the same series) can be dropped together once the user agrees.

## Change the base (catch up with upstream)

Do this as a separate job, never in the same rebase as reshaping (SKILL.md, step 4). Keep every commit as it is: change a commit only where a conflict forces you to. If the user asked only for a base update, don't tidy anything, however ugly the history is.

```
git fetch origin                      # network access: tell the user first
$K/preflight.sh origin/main           # a new session, because the base is about to move
$K/capture-todo.sh $M/todo.txt origin/main
$K/run-plan.sh $M/todo.txt origin/main
```
- To predict conflicts before starting, run `git merge-tree --write-tree --name-only origin/main HEAD` (Git 2.38+). Exit code 1 means conflicts, and the conflicted files are listed after the first line (the tree id). It's a whole-branch prediction; individual commits may conflict even when the end result doesn't.
- To move to an arbitrary point, stay on the branch and use `--onto`: `capture-todo.sh $M/todo.txt --onto <new-base> <old-base>` replays only the commits after `<old-base>`. Use it when the branch was built on another feature branch that has since been squash-merged into main, so those old commits must not be replayed. Run preflight with `<new-base>`.
- After moving the base, the conflict resolutions are the riskiest part of the result. Report each one.

## Stacked branches

`part1` is based on `main`, and `part2` is based on `part1`:
```
git switch part2                      # the TOPMOST branch
$K/capture-todo.sh $M/todo.txt --update-refs main     # shows "update-ref refs/heads/part1" lines
$K/run-plan.sh $M/todo.txt --update-refs main
```
- `--update-refs` moves only branches that point *inside* the rebased range, and never branches checked out in another worktree.
- If a lower branch was already rebased alone, the upper one still sits on the old commits. Move it with `git switch part2` and then `--onto part1 <old-part1-tip>` through capture-todo/run-plan. The old tip is in the backup ref or in `git reflog part1`.
- To change a commit in the middle of the stack, do it from the top branch, so every branch above it follows.

## Merge commits inside the range

A plain rebase **linearises**: merge commits disappear and their parents' commits get replayed. If the user wants to keep the topology, use `--rebase-merges`. The todo then contains `label`, `reset` and `merge -C <sha> <label>` lines. Conflict resolutions that were recorded inside the old merge commits are **not** replayed automatically; you redo them (rerere may help). If unsure, ask whether to linearise.

## Rewriting from the very first commit

`--root` instead of a base: `capture-todo.sh $M/todo.txt --root`. Rare; confirm with the user.

## Recovering inside a rebase

- `git rebase --abort` always returns to the state before the rebase.
- `git rebase --edit-todo` opens an editor, so don't use it. Instead, abort and run a corrected plan, or use `exec`/`break` lines planned in advance.
- If you finish and dislike the result: `git reset --hard <backup-ref>`, but **only** when the work tree has nothing uncommitted that you would lose. Check `git status` first.
