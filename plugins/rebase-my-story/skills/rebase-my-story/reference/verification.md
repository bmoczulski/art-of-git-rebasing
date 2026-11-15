# Verification: proving the rewrite is right

The checks fall into three layers. Do all three before you report, and report what each one showed.

1. **Mechanical** (`verify.sh`): content equality, nothing lost, hygiene. Cheap and decisive.
2. **Executable** (`each-commit.sh`, `prove-mechanical.sh`): every commit builds and passes tests, and mechanical commits really are mechanical.
3. **Judgement** (you, reading): each message matches its diff, the story makes sense, conflict resolutions are right. Only this layer catches a wrong-but-valid result.

## Layer 1: what verify.sh proves

### Content equality, the strongest check
- **Base unchanged** (`--keep-base`): reordering, splitting, squashing, rewording and absorbing fixups all redistribute changes between commits. They never change the sum. So the final tree must be **byte-for-byte identical** to the backup's tree. If it is, you have proven that no code changed, whatever happened in between. If it isn't, `content-diff.txt` shows exactly which lines changed, and each one needs an explanation (usually a wrong conflict resolution during a reorder).
- **Base moved:** the final tree is compared with Git's own merge of the old branch onto the new base (`git merge-tree --write-tree --merge-base=<old-fork-point> <new-base> <old-tip>`). Where Git merged cleanly, your result must be identical. Where Git hit conflicts, your resolutions are the only difference, and you must review them (content-diff.txt). This separates "what upstream changed" from "what you changed", which a plain diff can't do.
- Identical content proves nothing about **semantics** when the base moved: Git's clean merge can still be broken (see conflicts.md, semantic conflicts). That's what layer 2 is for.

### range-diff: how each commit changed
`git range-diff <old-base>..<old-tip> <new-base>..<new-tip>` pairs each old commit with its new version and shows the **diff between the two patches** (an "interdiff" per commit). Reading it:

```
1:  75caa7b = 1:  5c5e98d Add greet() helper          # same patch (only the hash changed)
2:  746183e ! 2:  62620c2 Print a greeting from main() # patch changed: details follow
    @@ app.py: def greet(name):
      def main():
    -     print(helper(21))
    +     print(double(21))
          print(greet("world"))
3:  4fa1429 < -:  ------- Add tests for greeting       # old commit with no new counterpart
-:  ------- > 3:  d9a5a51 Add greeting tests           # new commit with no old counterpart
```
- In a `!` block, the **first column** says which version of the patch a line belongs to (`-` old, `+` new). The rest of the line is the patch line itself, with its own `+`, `-` or space. `-     print(helper(21))` means "the old patch had this context line, the new one doesn't". Read the two columns separately.
- Message changes appear under `## Commit message ##`, and file changes under `## <path> ##`.
- `<` and `>` lines are expected after squashing, splitting or dropping. **Account for every one:** which new commit(s) now contain that change? A `<` you can't account for may be **lost work**.
- Pairing is heuristic. Small commits that changed a little often show as `<` plus `>` instead of `!`. `verify.sh` then also writes a looser pairing (`--creation-factor=100`) to `range-diff-loose.txt`. Use it to read, but confirm each pairing yourself.
- For a reviewer, the range-diff is the honest answer to "what changed since my last review?". Offer it (publishing-and-recovery.md).

Related tools: `git diff <old-tip> <new-tip>` is the whole-branch interdiff (empty for a pure reshape). `git format-patch --range-diff=<old> / --interdiff=<old>` puts the same information into a patch series' cover letter for mailing-list workflows.

### Hygiene
verify.sh flags leftover `fixup!`/`squash!`/`amend!` commits, WIP-like subjects, empty commits, committed conflict markers, whitespace errors, subjects over 72 characters, new merge commits, changed authors and lost trailers. It also reports how many commits were signed before and after, for information only: signatures are not expected to survive a rewrite. Fix the failures. Report the warnings, or explain why they're fine (for example, a whitespace "error" that the project's own style requires).

## Layer 2: executable checks

### Every commit builds and passes tests (as far as the agreed plan allows)
**Agree the plan with the user first** (SKILL.md, step 1). Run things on your own only when they're obviously cheap and the command is unambiguous. For an embedded project, a full test can mean hours of building plus flashing and running on hardware. There, the realistic plan may be a compile-only host build per commit, or nothing per commit and the user's own test at the tip.
```
$K/each-commit.sh --keep-going <base>..HEAD -- <build-and-test command>
```
- This is what makes `git bisect` work. A rebase creates snapshots nobody has built; this builds them. (It doesn't promise that reverting any single commit leaves a working tree: reverting a commit that later commits depend on breaks them, and that's expected.)
- Use the project's real commands (see CI config). Use `--clean` if build artifacts could hide a missing file.
- Whatever the plan, say in the report exactly what was run on which commits, and what wasn't run at all.
- **After a base move,** also run the tests on the new base itself. Failures that exist upstream aren't the branch's fault: report them separately, and don't "fix" them inside the branch's commits.
- A failure in the middle of the series that disappears later usually means the order is wrong (a commit uses something introduced later), or a piece of a split landed in the wrong commit.

### Mechanical commits are really mechanical
For every commit whose message claims no behaviour change (rename, move, format, reorder, "refactor: no functional change"):
```
$K/prove-mechanical.sh <commit> whitespace            # only whitespace changed
$K/prove-mechanical.sh <commit> move                  # every removed line reappears (moved/reordered)
$K/prove-mechanical.sh <commit> rename                # R100 file renames + table of word replacements
$K/prove-mechanical.sh <commit> formatter -- <cmd>    # formatting the parent reproduces the commit
```
If the proof fails, the commit hides a real change: split it out into its own commit with an honest message. This is exactly the problem clean history exists to prevent.

Other quick checks:
- A dependency bump should touch only manifests and lockfiles: `git diff --name-only <c>^ <c>`.
- A pure deletion of dead code: `git grep` for every removed symbol at that commit must find nothing.
- Generated files must match their generator: re-run the generator at that commit, if possible, and compare.

## Layer 3: judgement (read every commit)

For each new commit, read `git show --stat --patch <c>` and ask:
- **Does the message say why?** The body should give the reason (problem, motivation, trade-off), not retell what and how, which the diff shows. Does that reason cover everything in the diff? Anything it doesn't cover probably belongs in another commit.
- **Is it one logical change?** Could a reviewer describe it in one sentence?
- **Do tests change in a commit that claims not to change behaviour?** Changed expected values, weakened or deleted assertions, or skipped tests in a "refactor" commit are a red flag. They're the classic way a behaviour change hides.
- **Public interfaces:** do API, CLI, config, schema, wire format or file format changes appear, and does the message call them out?
- **Is the "why" true?** Messages you wrote or edited must not state reasons you invented (commit-craft.md).
- **Authorship:** is each change still credited to whoever wrote it?

For the series as a whole:
- Read it top to bottom as a reviewer would. Does each step make sense given the previous ones?
- Does each commit build on the previous ones, rather than fix them?
- Is anything from the old series missing? (Check the range-diff `<` lines again.)

## What to put in the report

| Check | Result | Evidence |
|---|---|---|
| Content | identical / differs only in resolved conflicts / differs (explained) | verify.sh, content-diff.txt |
| Commits accounted for | all old commits mapped to new ones | range-diff (+ loose pairing) |
| Every commit builds/tests | N/N passed, with which command | each-commit.sh output |
| Mechanical commits | proven / not proven, per commit | prove-mechanical.sh |
| Hygiene and metadata | failures fixed, warnings explained | verify.sh |
| Conflict resolutions | listed, each with confidence | your notes |
| Not checked | anything you could not run, and why | |

Never write "all checks pass" without the evidence. If a check couldn't run (no test command, tests need network or secrets, Git too old), say so plainly.
