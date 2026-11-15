# rebase-my-story

An agent skill that rewrites a Git branch into a clean, reviewable series of commits and proves the result is right. `SKILL.md` is what the agent reads. This file is for humans.

It was written from scratch for the talk "The Art of Git Rebasing: Automated by AI, Still Worth Knowing".

## What it does

- Absorbs review fixes into the commits they fix. The target comes from blame evidence (`hunks.py targets`), followed by `--fixup` and `--autosquash`.
- Reorders, splits, squashes and rewords commits, and drops them when you agree. It never opens an editor.
- Moves a branch or a whole stack of branches onto a new base (`--update-refs`), and resolves conflicts by intent, with zdiff3 markers and rerere.
- Proves the result:
  - **identical final tree** after a reshape
  - after a base move, the tree **equals Git's own merge** everywhere except the conflicts you resolved, and the series is unchanged: same commits, same order, same messages
  - range-diff, old against new, with every commit accounted for
  - **every commit builds and passes tests**, run in a throwaway worktree, when that's affordable. The test plan is agreed with you first, since an embedded build can take hours
  - commits that claim to be mechanical are **proven mechanical** (whitespace, move, rename, formatter)
  - authors and trailers are preserved. Signatures aren't (a rewritten commit is a new commit); signing follows your Git config and the project's policy
- Stays safe: it makes a backup ref before rewriting, never drops a commit silently, never pushes unless asked, and pushes only with an explicit lease plus `--force-if-includes`.

## Layout

```
SKILL.md                        workflow, ground rules, Git facts that trip people up
reference/commit-craft.md       what a good commit and a good series look like
reference/operations.md         non-interactive recipes for every operation
reference/conflicts.md          how to resolve conflicts, including semantic ones
reference/verification.md       what each check proves, how to read range-diff
reference/publishing-and-recovery.md   safe force-push, reviewer notes, undo
scripts/                        preflight, capture-todo, run-plan, continue, hunks.py,
                                each-commit, prove-mechanical, verify
```

## Install

See the [repository's README](../../../../README.md#install-the-skill): as a Claude Code plugin (with updates), or by copying this directory into your agent's skills directory.

Requirements:
- bash 3.2 or newer, and Python 3 (for `hunks.py`)
- Git 2.24 or newer. Git 2.40 or newer is recommended, because `zdiff3`, `--update-refs`, `--force-if-includes` and `merge-tree --merge-base` all need recent versions. Preflight reports what's available.

## Tested

The scripts were exercised against Git 2.43 on Linux, in throwaway repositories. Covered so far:
- absorbing fixups
- splitting a commit with the original author kept, including files the commit added
- a base move with a textual conflict plus a semantic conflict that only the per-commit build caught
- a stacked-branch rebase with `--update-refs`
- a fixup that empties its target
- the mechanical-commit proofs, including a "move" commit with a hidden change

Not yet tested: macOS/BSD userland, Windows, repositories with submodules or LFS, `--rebase-merges`.

## Ideas for later

- A line-level split helper. Splitting inside one run of changed lines still means editing a patch by hand.
- An eval suite: messy branches with known-good target series, scored by the verify checks.
