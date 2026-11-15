# Publishing rewritten history, and recovering from mistakes

## Publishing (only when the user asks)

Rewritten commits have new hashes, so a branch that was already pushed needs a force push. A force push replaces whatever is on the remote, including commits someone else pushed since you last fetched. Make it safe:

1. **Fetch, and compare with what you started from.**
   ```
   git fetch origin <branch>
   git rev-parse origin/<branch>                         # what the remote has now
   git merge-base --is-ancestor origin/<branch> <backup-ref> && echo "remote has nothing we lack"
   ```
   If the remote tip is **not** contained in the backup, someone pushed commits you haven't seen: `git log --oneline <backup-ref>..origin/<branch>`. **Stop.** Show them to the user. They must be integrated (usually by cherry-picking onto the rewritten branch) before anything is pushed.
2. **Push with an explicit lease, and with `--force-if-includes`:**
   ```
   git push --force-with-lease=<branch>:<sha-you-checked-in-step-1> --force-if-includes origin <branch>
   ```
   - `--force-with-lease=<branch>:<sha>` overwrites only if the remote still points at exactly that hash. Always give the hash: the bare form `--force-with-lease` compares against your remote-tracking ref, and a background fetch (IDEs, cron, other tools) can silently move that ref, which makes the lease worthless.
   - `--force-if-includes` (Git 2.30+) additionally refuses if the remote tip was never integrated into your local branch. This is exactly the "fetched but didn't look" case.
   - Never use plain `--force` or `+refspec`.
3. **Never push to the default, release or protected branches** as part of this skill.

### Tell the reviewers what changed

Force pushes make review tools lose track: line comments can become "outdated", and "what changed since I last looked" is hard to see. Offer the user a short note for the pull request (posting it is their call, or yours only if they ask):
```
Rebased/reshaped: <one line on what and why — e.g. "folded review fixes into their commits, rebased onto main">.
No code changes beyond review fixes: <evidence, e.g. "final tree identical to before the rebase plus the fixups">.
Per-commit changes since the last review:
<git range-diff output, trimmed to the '!' entries, or a summary of it>
```
Split moving the base from reshaping (SKILL.md, step 4) and push them separately if the reviewer is mid-review: then the range-diff of the reshape push shows only your restructuring.

## Recovery

Git almost never loses committed work, but it does hide it. In order of preference:

1. **The backup ref** made by preflight: `git for-each-ref refs/reshape-backup/`. It doesn't expire and isn't garbage-collected.
2. **`ORIG_HEAD`**: the branch's position before the last rebase, reset or merge. It's overwritten by the next such command.
3. **The reflog**: `git reflog show <branch>` (where the branch pointed) and `git reflog` (where HEAD pointed). Entries look like `<branch>@{3}`, and every position the branch had is there. **Entries expire**: by default after 90 days (`gc.reflogExpire`) for entries still reachable, and after 30 days (`gc.reflogExpireUnreachable`) for commits no longer on any branch, which is exactly what a rewrite leaves behind. After that, `git gc` deletes them.
4. **Dangling objects**, the last resort: `git fsck --lost-found` lists unreachable commits (dropped stashes, for example) that `gc` hasn't removed yet.

### Undoing a finished rewrite
```
git status --porcelain                  # must show nothing you'd lose
git branch <branch>-reshaped HEAD       # optional: keep the new version too
git reset --hard <backup-ref>           # only with the user's agreement
```
### Undoing a pushed rewrite
Push the backup back with a lease on the hash you pushed: `git push --force-with-lease=<branch>:<pushed-sha> origin <backup-ref>:refs/heads/<branch>`. Again, only when the user asks.

### Mid-rebase
`git rebase --abort` restores the branch, the index and the work tree to the state before the rebase. It's always safe and always available while a rebase is in progress.

## Cleaning up

Backup refs and session directories (`$(git rev-parse --git-path reshape-history)`) are small. Leave them, and tell the user how to remove them when they're satisfied:
```
git for-each-ref --format='%(refname)' refs/reshape-backup/ | xargs -r -n1 git update-ref -d
```
Never delete them on your own initiative.
