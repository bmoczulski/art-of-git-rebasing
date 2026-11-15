# Resolving rebase conflicts

A conflict resolution is new code that nobody wrote on purpose and nobody has reviewed. It is the riskiest output of any rewrite. Resolve it like a careful engineer, then report it so a human can check it.

## First: know which side is which

During a rebase, Git is replaying **your commit** onto **the new base**:

| Name | In a rebase it means |
|---|---|
| `HEAD`, "ours", `--ours`, stage 2, the **upper** part of the markers | the new base **plus your commits already replayed** |
| "theirs", `--theirs`, stage 3, the **lower** part of the markers, labelled with the commit's hash and subject | **the commit being replayed** (your change) |
| the middle part (`|||||||`, shown by zdiff3/diff3), stage 1 | the code **before** your commit, i.e. its parent in the old history |

This is the reverse of `git merge`, where "ours" is your branch. Models and humans get it wrong all the time. **Read the labels on the markers, not your memory.**

The scripts set `merge.conflictStyle=zdiff3`, so you always see three parts:
```
<<<<<<< HEAD
    print(double(21))                                   # new base: upstream renamed helper -> double
||||||| parent of 746183e (Print a greeting from main())
    print(helper(21))                                   # what the commit's author started from
=======
    print(helper(21))                                   # what the commit wants: the old line ...
    print(greet("world"))                               # ... plus one new line
>>>>>>> 746183e (Print a greeting from main())
```
Compare middle with lower to see **what the commit changed**: it added `print(greet("world"))`. Compare middle with upper to see **what upstream changed**: it renamed the call. The resolution applies *both* intents: `print(double(21))` and `print(greet("world"))`.

## Protocol for every conflict

1. **Orient yourself.**
   - `git status`: which files conflict, which commit is being replayed.
   - `git log -1 --format='%h %s%n%n%b' REBASE_HEAD`: what this commit intends.
   - `git show REBASE_HEAD -- <file>`: the commit's full change to this file, not only the conflicted part.
2. **Understand what upstream did to the same code.**
   - `git log --oneline <old-base>..<new-base> -- <file>`: which upstream commits touched it.
   - `git log -p <old-base>..<new-base> -- <file>`: read the relevant ones. Was it a rename? A behaviour change? A move to another file? A revert?
3. **Write the resolution.** Apply the replayed commit's intent on top of the new code. Typical cases:
   - Both sides edited nearby lines for different reasons: keep both edits.
   - Upstream renamed or moved something the commit touches: apply the commit's change to the renamed or moved code.
   - Upstream already made the same change: take upstream's version. The commit may become partly or fully redundant.
   - Upstream deleted code that the commit modifies: **stop and ask**. Was the deletion intended to remove that behaviour? Does the commit's change need to move elsewhere?
   - Upstream changed behaviour the commit relied on: the textual resolution is not enough. The code above it may need to change too. Ask if unsure.
4. **Check the whole file, not just the hunk.** Remove every marker line (`<<<<<<<`, `|||||||`, `=======`, `>>>>>>>`). Make sure imports, signatures and call sites agree. Run `git diff --check` for leftovers.
5. **Check that it works,** if feasible at this point: build, or at least syntax-check, the touched files. A resolution that doesn't compile poisons every later commit.
6. **Stage and continue:** `git add <file>`, then `$K/continue.sh`.
7. **Record what you did** for the report: commit, file, what each side changed, what you decided, and how confident you are.

## Never

- `git checkout --ours/--theirs <file>` or `-X ours/theirs` without having read both sides. Either one silently discards a change.
- Concatenating both sides without reading them ("keep both") when they edit the same statement.
- `$K/continue.sh --skip` (or `git rebase --skip`) to "get past" a conflict. It **drops the whole commit**. It's correct only when the new base already contains the commit's change, which you can show with `git range-diff` or `git cherry -v <new-base> <old-tip>` (a `-` prefix means an equivalent patch already exists upstream).
- Editing unrelated code while resolving. A resolution contains the minimum needed to apply the intent.
- Continuing with a resolution you don't understand. `git rebase --abort` is always available, and asking the user is cheaper than shipping a wrong merge.

## Conflicts that come back

If later commits touch the same region, the same conflict reappears in a slightly different form. Resolve each one consistently with your earlier decision.

**rerere** (enabled per command by the scripts) records each resolution and replays it when the identical conflict shows up again. "Resolved using previous resolution" in Git's output means rerere acted. **A replayed resolution is still unreviewed:** look at it (`git diff`), and if it's wrong, run `git rerere forget <file>`, resolve again, and stage. rerere doesn't stage anything for you, because the scripts don't set `rerere.autoUpdate`.

## Conflicts that Git does not report (semantic conflicts)

The most dangerous result of a rebase is a clean one that's broken. Examples:
- Upstream renamed a function, and your commit adds a **new** call to the old name in another file. No textual overlap, so no conflict, but the build fails.
- Upstream changed a function's default argument, units or error handling, and your new code relies on the old behaviour. It builds, but it's wrong.
- Upstream added a required field, a new enum value or a new interface method, and your new code doesn't handle it.
- Both sides added an entry with the same key or ID (migrations, enum values, registry entries, test names). Both merge cleanly, and they collide at runtime.

How to catch them:
1. **Build and test every commit** with `each-commit.sh` after any base move. This catches the first kind.
2. **List what upstream removed or renamed** and search your commits for uses of it:
   ```
   git diff <old-base> <new-base> --stat                     # where upstream changed things
   git diff <old-base> <new-base> | grep -E '^-.*(def|function|class|fn|func) '   # adjust to the language
   git grep -n '<old-name>' HEAD                             # uses left in the rebased branch
   ```
3. **Read upstream's changes to the APIs your branch uses,** especially behaviour changes in their commit messages.
4. **Look for duplicate keys and IDs:** migration numbers, enum values, feature flags, registry names, test names.
5. **When in doubt, say so in the report.** "Upstream changed X; I believe our use is still correct because Y" lets a human check your reasoning instead of re-deriving it.

## Conflicts while reordering or splitting (base unchanged)

These conflicts come from moving commits past each other, not from upstream. The final tree must still be **identical** to the backup (verify.sh checks this). If you reorder A and B and resolve conflicts on the way, the last commit's tree must still match. If it doesn't, one of your intermediate resolutions changed code. Look at `content-diff.txt`.
