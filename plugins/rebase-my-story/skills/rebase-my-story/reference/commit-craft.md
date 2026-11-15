# Commit craft: what good history looks like

A pull request is a message to another person, and its commits are the paragraphs. Good history lets a reviewer find the three lines that matter among three hundred that don't. It also lets a future reader, human or agent, learn *why* the code is the way it is, through `git log`, `git blame` and `git log -L`, and lets `git bisect` point to the one small commit that broke something.

## The properties of a good commit

1. **One logical change.** It can be described in one sentence without "and also". A commit that "adds caching and renames the config class" is two commits.
2. **Complete.** It builds, passes tests, and leaves no dangling half-features: a function with its callers, a schema change with its migration, a source change with its regenerated files and lockfile. Completeness **includes the documentation** the change affects: README, user docs, API docs, changelog, code comments that describe the old behaviour.
   Sometimes a complete commit is impossible or unwanted, for example a large change deliberately staged across several commits, or a dependency that has to land first in another repository. Then don't force it. If the exception isn't obvious, warn the user and ask whether it's acceptable, and say in the commit message what's missing and where it follows.
3. **Small enough to review in one sitting,** but not artificially sliced. Ten commits that each add one line of a single function are noise.
4. **Honest.** The message gives the real reason for the change, and that reason covers the whole diff. If part of the diff needs a different reason, it belongs in a different commit.
5. **Revertable as one idea.** Reverting it removes exactly that one idea, and nothing unrelated. That doesn't mean every revert leaves a working tree. Commits that build on it break when it goes: revert the commit that adds an interface, and every class that implements it stops compiling. That's a fact of life, not a flaw in the series. Reverts can also depend on each other textually: in a series A B C D E where E later changes lines that D changed, D's revert won't apply cleanly (it conflicts) until E is reverted first. Reverting in reverse order (E, then D) is normal. The aim is that a revert takes out one idea cleanly, together with its dependents if needed, not that the tree passes validation after reverting any single commit.

## Separate mechanical changes from meaningful ones

This is the single biggest favour you can do a reviewer. Mechanical changes are big, boring and safe to skim *if* they're isolated. Meaningful changes are small and need full attention. Mixed together, the meaningful change drowns.

Mechanical (each in its own commit, with no behaviour change at all):
- renaming a symbol or file, or moving code between files
- reformatting, reindenting, sorting imports, running a formatter
- dependency or tooling bumps with no code changes
- regenerating generated files
- deleting dead code (when it really is dead)

Meaningful: everything that changes behaviour. Put it in commits whose diffs are as small as possible.

Ordering rule: **make the change easy, then make the easy change** (Kent Beck). Preparatory refactoring comes first, in its own commits, and the behaviour change comes last, small and obvious.

Mechanical commits can be **proven** mechanical (see `verification.md`). After the branch lands, formatting-only commits can be listed in `.git-blame-ignore-revs` so `git blame` skips them. Suggest this to the user; the hashes are final only once merged.

## A good series

- **Tells the story in a sensible order:** preparation → core change → its uses → tests and docs, if they aren't already with their code. The order in which things were *written* doesn't matter. The order in which they are best *understood* does.
- **Has no commits that fix earlier commits in the same series.** "Fix typo", "address review", "oops" and "fix tests" belong inside the commit they fix (fixup + autosquash). An exception is when the user wants the review history kept until approval; ask if unsure.
- **Has no pairs that cancel out** (add X, then remove X). Drop both, with consent.
- **Has tests with or next to the code they test.** Each commit passes its own tests. A test that demonstrates a bug goes in the same commit as the fix, not before it, since that commit would fail.
- **Contains no debugging leftovers:** print statements, commented-out code, local config, TODOs that aren't meant to stay.
- **Keeps unrelated drive-by fixes out of feature commits** (a drive-by fix is a small change made "while passing through" code you were editing for another reason: a typo in a nearby comment, an unrelated off-by-one, an unused include, a name that bothered you). Split each one into its own commit, or group trivial ones into one "small cleanups" commit, and suggest a separate pull request if one is big. Put them **at or near the start of the series**: they're preparation, independent of the feature. Placed first, they can be reviewed quickly, merged or cherry-picked (for example backported to a release branch) on their own, and they don't clutter the feature's own commits. One exception: a fix to code the series itself added isn't a drive-by fix. It's a fixup and belongs in the commit that introduced that code.

Don't over-engineer. A ten-line bug fix is one commit. Don't split it into "add test" and "fix" for the look of it.

## Commit messages

Follow the repository's existing conventions first (look at `git log` on the base: prefixes like `area:`, Conventional Commits, ticket IDs, required trailers). Otherwise:

- **Subject:** imperative mood ("Add", "Fix", "Remove", not "Added" or "Adds"), about 50 characters, 72 at most, no trailing period. It says what the commit does to the code base.
- **Blank line, then the body,** wrapped at 72 characters. The body says **why**: the problem, the reason for this approach, the consequences, alternatives that were rejected. It does **not** retell *what* changed or *how*: the diff already shows that, and an experienced engineer reads it there. A body that narrates the diff ("Add function X, call it from Y, update Z") is noise; replace it with the reason X was needed.
- **Trailers** at the end, one per line: `Signed-off-by:`, `Co-authored-by:`, `Fixes:`, `Refs:`, and whatever else the project uses. Never drop existing trailers. Never add `Signed-off-by` for someone else; it is a legal statement (the Developer Certificate of Origin) that only that person can make.
- A trivial change (a typo fix, a version bump) may have a subject only.

### Where the "why" comes from

You know what a diff does. You often do **not** know why it was made. Sources, in order: the existing commit messages, comments in the code, the pull request or issue text if the user gave it to you, and the conversation. If the reason isn't available, ask the user, or write a body with a clearly marked placeholder (`[why? — please fill in]`) and point it out in the report. A plausible invented reason is worse than none, because readers will trust it.

## Authorship and credit

- Keep each change attributed to the person who wrote it. Splits must keep the original author (`--author`/`--date`, or `commit -C`). The committer is a different field: it records who rewrote the commit, and it comes from Git's normal configuration. Don't set or preserve it. Squashing commits by several people needs the user's consent and `Co-authored-by:` trailers.
- Don't rewrite other people's commits on a shared branch without their agreement.
- If the project has a policy on AI assistance (an `Assisted-by:` trailer, a disclosure line), follow it. If unsure, ask.

## When to leave history alone

- Commits already on a shared or protected branch.
- A series that is already clean. Say so, and change nothing.
- When the user wants the review history visible until approval (some teams squash at the end anyway). Offer, don't impose.
- When the project squash-merges every pull request, the series matters only during review. Cleaning it still helps the reviewer, but say that the history won't survive the merge.
