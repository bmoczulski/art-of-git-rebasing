---
name: rebase-my-story
description: Rewrite a local Git branch's history into a clean, reviewable series of commits and prove the result is correct. Covers reordering, splitting, squashing and rewording commits, absorbing review fixes into the commits they fix (fixup/autosquash), rebasing onto a new base, moving stacked branches together, and resolving rebase conflicts. Verifies with tree equality and range-diff, plus a build of every commit where that's affordable. Use when the user asks to clean up, tidy, reshape, rebase, squash, split, reorder or "prepare for review" a branch or pull request, to fold review fixes into earlier commits, to update a stack of branches, or to fix a rebase that went wrong.
---

# Reshape Git history

You are rewriting commits that a human will review and that people (and agents) will read for years. Rewriting history is surgery: the patient must leave with the same code, a clearer story, and nothing lost. You are judged on three things, in this order:

1. **Nothing is lost or changed by accident.** Every line of code, every author, every trailer survives unless the user asked otherwise. You can prove this with the checks below.
2. **Every commit works.** Each one builds and passes tests, so `git bisect` works, and each commit is one idea that can be reverted cleanly (together with any later commits that depend on it).
3. **The series tells a story.** A reviewer can read it commit by commit and understand what changed and why.

You can be fast because Git keeps everything: with a backup ref nothing is ever truly destroyed. Being fast is never a reason to skip the checks.

## Read before acting

- `reference/commit-craft.md`: what a good commit and a good series look like. Read it before you design a target series.
- `reference/operations.md`: exact non-interactive recipes for every operation (reorder, split, squash, reword, fixup, move a hunk, change base, stacks, merges). Read the section you need before you run it.
- `reference/conflicts.md`: how to resolve conflicts correctly. Read it **the first time a rebase stops on a conflict**, before touching the file.
- `reference/verification.md`: how to read range-diff, what each check proves, semantic review. Read it before reporting.
- `reference/publishing-and-recovery.md`: force-pushing safely, telling reviewers what changed, undoing mistakes.

## Your tools

The `scripts/` directory next to this file holds helpers. Call them by absolute path. They never change the user's Git config: settings are passed per command with `git -c`.

| Script | What it does |
|---|---|
| `preflight.sh <base> [--allow-dirty]` | Refuses to start in an unsafe state, describes the range, finds commits that other branches share, **creates the backup ref** and records a session for `verify.sh`. Exit 1 means warnings to raise with the user. |
| `capture-todo.sh <file> <rebase args>` | Writes the todo list Git *would* run, without running anything. Use it to see what `--autosquash` or `--update-refs` will do, and as the starting point of a plan. |
| `run-plan.sh <todo-file> <rebase args>` | Runs `git rebase -i` with your todo list and never opens an editor. Adds zdiff3 conflict markers, rerere, and `rebase.missingCommitsCheck=error`. Exit 3 means stopped (conflict, `edit`, `break` or a failed `exec`). |
| `continue.sh [--skip]` | Continues a stopped rebase with the same settings. Refuses while conflicts or markers remain. |
| `hunks.py list/show/stage/unstage` | `git add -p` without a terminal. Hunks are split as finely as possible, and IDs change after every stage, so list again. |
| `hunks.py targets <base>` | For each changed hunk, uses blame to find which commit in the range it most likely fixes. This is the evidence for "absorb". |
| `each-commit.sh [--keep-going] <range> -- <cmd>` | Runs a command on every commit in a temporary worktree. Proves every commit builds and passes tests. Use it only with the test plan agreed with the user (step 1). |
| `prove-mechanical.sh <commit> whitespace\|move\|rename\|formatter` | Proves that a commit claiming "no behaviour change" really has none, or shows the lines that break the claim. |
| `verify.sh [--allow-content-change]` | Compares the result with the backup: content equality, range-diff, per-commit hygiene, authors, trailers. Reports signature counts for information. |

## Ground rules (never break these without the user's explicit consent)

1. **Back up first.** Never rewrite without running `preflight.sh`, which creates `refs/reshape-backup/<branch>/<timestamp>`. Never delete backup refs, run `git gc`, `git prune` or `git reflog expire`; the reflog is a safety net that expires (90 days for reachable entries, 30 for unreachable), and the backup ref is yours.
2. **Only rewrite what is yours to rewrite.** Do not rewrite commits that other branches or other people build on (preflight reports them), the default branch, or release branches. If other people's commits are in the range, ask.
3. **Never push unless asked.** When asked, use `--force-with-lease=<branch>:<expected-sha>` together with `--force-if-includes`, never bare `--force` (see `reference/publishing-and-recovery.md`).
4. **Never drop a commit silently.** Removing a line from the todo list is an error (the scripts enforce it). Dropping is an explicit `drop` line that the user agreed to. `continue.sh --skip` also drops a commit; use it only when you have proven that the base already contains the change.
5. **Never resolve conflicts blindly.** No `-X ours`, `-X theirs`, `checkout --ours/--theirs` on whole files, or "take both sides" without reading the code. Resolve by the intent of both changes (see `reference/conflicts.md`). If you are not sure, stop and ask.
6. **Never invent the "why".** Commit messages explain why a change was made. If the reason isn't in the existing messages, the code, the ticket or the conversation, ask the user or leave a clearly marked placeholder. Don't make one up.
7. **Never sweep files in.** No `git add -A`, `git add .` or `commit -a` during a rewrite. Stage exactly the paths and hunks you mean. Untracked files stay untracked.
8. **No interactive programs.** Never run anything that opens an editor or pager and waits: `rebase -i` without `GIT_SEQUENCE_EDITOR`, `commit` without `-m`/`-F`/`-C`/`--no-edit`, `add -p`, `reset -p`, `checkout -p`, `mergetool`. Set `GIT_EDITOR=true` and use `--no-pager` or `| cat`. If a command hangs, an editor has opened.
9. **Don't bypass the project's checks.** No `--no-verify`. If a hook fails, fix the cause or ask.
10. **Leave the user's environment as you found it.** Use per-command `-c` settings, never `git config --global`. Leave no stashes, temporary branches or worktrees behind, except the backup ref.
11. **Do what was asked.** If the user asks to absorb review fixes, don't also reorder the whole branch. Suggest further improvements and let them choose.
12. **One kind of job per run: reshape OR move the base, never both** (step 4). If you're not sure which one the user wants, ask.

## Workflow

### 1. Understand the request and the branch
- What does the user want: a full clean-up, one specific operation, a base update, or a stack update? What is the base (the branch this will merge into)? If no base is given, use the branch's upstream target. Find it with `git rev-parse --abbrev-ref @{upstream}`, then the remote's default branch via `git symbolic-ref refs/remotes/origin/HEAD`. **Confirm with the user if there is any doubt.** Always pass the base explicitly to Git: a bare `git rebase` uses `--fork-point` logic, which can drop commits unexpectedly.
- Is there uncommitted work? If it's the review fixes the user wants absorbed, commit them as `fixup!` commits first (step 5). Otherwise ask whether to commit or stash it.
- Look at the repository's conventions: `git log --format='%s' -30 <base>` (conventional commits? `area: subject` prefixes? ticket IDs? `Signed-off-by` required?).
- **Agree the test plan with the user before running any build or test.** Building and testing every commit is the ideal, but often unrealistic: an embedded project may need a multi-hour build, flashing, and a run on real hardware. Run builds or tests on your own only when they're obviously cheap (seconds to a few minutes, no hardware, no network, no secrets) **and** it's unambiguous what the command is (a `make test` the README or CI names). Otherwise, propose what you could run (a compile-only build, a fast unit-test subset, a host build instead of a target build, or nothing) and let the user choose. Report honestly what was and wasn't checked; the identical-tree proof and the range-diff don't depend on running anything.

### 2. Preflight
Run `scripts/preflight.sh <base>`. Read every line. Stop on errors. Raise warnings (shared commits, merges in range, several authors) with the user before going on. If it reports signed commits, check the project's signing policy (see "Signatures" below) before rewriting.

### 3. Read the history
Read **every** commit in the range: `git log --reverse -p --stat <base>..HEAD` (page through it for big ranges). For each commit, note what it really does, not what its message says it does. Look for:
- commits that do two things (a rename plus a behaviour change, a formatting change mixed with logic, a dependency bump mixed with code)
- changes that belong together but are spread out (a fix three commits after the bug, tests far from their code)
- commits that undo or fix earlier commits in the same series ("fix typo", "oops", "address review")
- order problems (a commit uses something introduced later, so an earlier commit cannot build)
- debugging leftovers, commented-out code, unrelated drive-by changes (small fixes made "in passing" to code that isn't part of the feature; they become their own commits near the start of the series, see `reference/commit-craft.md`)
- generated files or lockfiles that should change together with their source

### 4. Decide the kind of job: reshape OR move the base, never both at once
Every rewrite is exactly one of two kinds. Each has its own proof, and mixing them destroys both:

| | Reshape | Move the base (catch up with upstream) |
|---|---|---|
| What changes | the commits: order, splits, squashes, messages, absorbed fixups | only the base the commits sit on |
| Base | stays put (`--keep-base`) | moves |
| Commits | rewritten as planned | **kept as they are**, changed only where a conflict forces it |
| Proof | final tree **identical** to the backup: a complete proof that no code changed | range-diff shows `=` for every commit, except commits touched by a conflict resolution, which show `!` with exactly that resolution |

- If the user asks only for a base update, **do only that, and keep the history as it is, however ugly.** Don't tidy it unasked. Mention what you'd improve and let them decide.
- If the user asks only for a clean-up, don't move the base.
- If they want both, do two separate runs: reshape first (and verify), then move the base (and verify), each with its own preflight.
- If it's unclear which one the user wants, **ask**.

### 5. Design the target series and the plan (reshape only)
Use `reference/commit-craft.md`. Write the target series as a list: for each new commit give its subject, what goes into it (which old commits or hunks), and why it is a separate step. Then translate it into a todo list (start from `capture-todo.sh`) plus the manual steps (splits at `edit` stops, message files for rewording).

Prefer the smallest sequence of operations that gets there, all with `--keep-base`:
1. **Absorb fixes first.** Commit each fix as `git commit --fixup=<target>`, chosen by `hunks.py targets` evidence plus your own reading of what the fix belongs to. Then run one `--autosquash --keep-base` rebase.
2. **Then reorder, split, squash and reword.** The final tree must be **identical** to the backup: proof that only history changed.

A base move, if the user wants one too, is a separate job afterwards (step 4).

### 6. Get approval
Unless the user has already approved this kind of change, show them: the current series, the target series, and the todo list. Point out anything that is a judgement call. A todo list is a plan a human can read in ten seconds; use it.

### 7. Execute
Run `run-plan.sh`. At each stop:
- **conflict**: follow `reference/conflicts.md`, then `continue.sh`.
- **edit stop**: do the split or amend (`reference/operations.md`), check that the tree at this point equals the original commit's tree (`git diff --quiet REBASE_HEAD HEAD` for a pure split), then `continue.sh`.
- **failed exec**: read the output. A failing build or test at this commit means the plan is wrong (wrong order, a missing piece). Fix the plan; don't force it through.
- **anything unexpected**: `git status`, `git log --oneline -5`, read Git's message. If you can't explain the state, run `git rebase --abort` and rethink. Aborting is always safe.

### 8. Verify
1. `verify.sh`. After a reshape, a FAIL on content means you changed code. Find out how: `content-diff.txt` shows exactly what. Use `--allow-content-change` only when the user asked for code changes, and account for every line.
2. Read `range-diff.txt` in full, especially every `!` entry, and account for every `<` and `>` (see `reference/verification.md`).
3. Run the build and test plan agreed in step 1, e.g. `each-commit.sh <base>..HEAD -- <command>`. Every commit that was tested must pass. After a base move, building is the check that catches a textually clean rebase that breaks code (a renamed function, a changed signature upstream). If the agreed plan doesn't include building, say plainly in the report that this risk is unchecked.
4. For every commit that claims to be mechanical (rename, move, format, "no functional change"), run `prove-mechanical.sh`. A failed proof means a hidden behaviour change: split it out.
5. Review each new commit's message against its diff. The body should explain **why** the change was made: the problem, the reason, the trade-off. It shouldn't retell what and how, which an experienced engineer reads from the diff. Is there anything in the diff that the stated reason doesn't cover? Then it probably belongs in another commit. Do tests change in a commit that claims not to change behaviour?
6. Run the project's linters and formatters on every commit if the project uses them and they're cheap (`each-commit.sh`).

### 9. Report
Tell the user:
- the old series and the new series (subjects, short hashes), and how each old commit maps to the new ones
- the check results, with evidence (verify output, each-commit summary), and anything you could not check
- every conflict you resolved: file, commit, what you decided and why. Flag the ones you are least sure of.
- judgement calls and suggestions you didn't act on
- the backup ref and the exact command to go back
- whether anything is published, and the push command you would run, without running it

## Git facts that trip people up (and models)

- **A rebase is a loop of cherry-picks.** Each commit is re-applied as a patch on a new parent, which creates a **new commit with a new hash**, even if the content is identical. The old commits still exist (backup ref, reflog) until garbage collection.
- **Rebased commits are untested.** Each new commit is a snapshot nobody ever built before. That's why `each-commit.sh` exists, and why, when building every commit isn't affordable, the report must say so.
- **ours and theirs are swapped in a rebase.** During a rebase, "ours" / `HEAD` / the upper side of conflict markers is the **new base plus the commits already replayed**. "theirs" / the lower side is **the commit being replayed** (your change). `git checkout --ours` therefore picks upstream's version, not yours.
- **Author and committer differ.** A rebase keeps the author and author date and makes you the committer, with the current date. A new commit made during a split is authored by **you** unless you use `git commit -C <original>` (or `--author` and `--date`). **Preserve the author (name, email, date). Leave the committer alone:** it's whoever Git's normal configuration says (repository config, then global and system config), with the current date. Never set `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` or `GIT_COMMITTER_DATE`, never pass `-c user.name=`/`-c user.email=`, and don't use `--committer-date-is-author-date` unless the user asks. A changed committer is expected, not a problem.
- **Signatures don't survive, and they shouldn't.** A signature vouches for one exact commit, and a rewritten commit is a new one. Git signs the new commits only if the user's configuration says so (`commit.gpgSign`), and then with the user's key. Leave that to the configuration: never add `-S` or `--no-gpg-sign` yourself. If the range contains signed commits, find out what the project expects (CONTRIBUTING, the developer docs, CI checks for signatures). If it's still unclear, **ask**. Don't sign blindly, and don't strip signing blindly.
- **`ORIG_HEAD`** points to where the branch was before the last rebase, reset or merge. It's useful, but it gets overwritten. The backup ref doesn't.
- **`REBASE_HEAD`** is the commit being replayed while a rebase is stopped.
- **`--autosquash` matches by subject, not by hash.** `git commit --fixup=<sha>` writes only `fixup! <subject>`. Git attaches it to an earlier commit with that exact subject, falling back to a subject that merely starts with it. With duplicate subjects it can pick the wrong commit. Always check the captured todo.
- **`--update-refs` moves only branches that point inside the rebased range** (and not branches checked out in another worktree). To move a stack, rebase the **topmost** branch.
- **Merge commits in the range are flattened** by a plain rebase. Use `--rebase-merges` to keep them, or ask.
- **A fixup can empty its target** (the fix undoes the whole commit). Git stops there. `git reset --soft HEAD~1` followed by `continue.sh` drops the pair. Continuing directly records an empty commit.

## Version notes

Preflight prints which features the installed Git supports. Fallbacks:
- No `--keep-base` (Git < 2.24): `git rebase -i $(git merge-base <base> HEAD)`.
- No `--update-refs` (< 2.38): move each branch of the stack with `git rebase --onto <new-parent> <old-parent-tip> <branch>`.
- No `zdiff3` (< 2.35): `diff3` (the scripts choose this automatically).
- No `--force-if-includes` (< 2.30): fetch, compare the remote tip with the session's old tip yourself, then push with an explicit lease.
- No `merge-tree --merge-base` (< 2.40): verify.sh can't check content after a base move; rely on range-diff and each-commit.

## Out of scope

- Removing secrets or large files from all history: use `git filter-repo`, which is a different, more dangerous operation. Explain that and stop.
- Rewriting shared or protected branches: refuse unless the user confirms they own the consequences (everyone must re-sync).
- Deciding merge strategy policy for a team: give facts, not a ruling.
