#!/usr/bin/env python3
"""Hunk-level staging without an interactive terminal (a scriptable 'git add -p').

Usage:
  hunks.py list    [--cached] [-- <paths>...]   number the hunks of a diff
  hunks.py show    [--cached] <ids> [-- <paths>...]   print those hunks as a patch
  hunks.py stage   <ids> [-- <paths>...]        stage hunks of the unstaged diff
  hunks.py unstage <ids> [-- <paths>...]        unstage hunks of the staged diff
  hunks.py targets <base> [--cached] [-- <paths>...]
                                                for each hunk, which commit in
                                                <base>..HEAD it most likely fixes

<ids> is a comma-separated list of numbers and ranges, e.g. 1,3-5. Numbers always
refer to the *current* diff: list again after every stage/unstage, because the
numbering changes.

Without --cached the diff is work tree vs index (what 'git add' would stage).
With --cached it is index vs HEAD (what 'git commit' would record).

Hunks are split as finely as possible (like pressing "s" in git add -p): each run of
changed lines is its own hunk. Whole-file changes (new, deleted, binary, mode-only)
are a single hunk that cannot be split. To stage part of a hunk, write it out with 'show', edit the patch (keep
context lines, drop '+' lines, turn unwanted '-' lines into context), and apply it with
'git apply --cached --recount <file>'.
"""
import re
import subprocess
import sys
from collections import Counter

HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
BLAME_RE = re.compile(r"^([0-9a-f]{40,64}) (\d+) (\d+)(?: \d+)?$")


def git(*args, input=None, check=True):
    res = subprocess.run(["git", *args], input=input, capture_output=True)
    if check and res.returncode != 0:
        sys.exit(f"git {' '.join(args)} failed:\n{res.stderr.decode(errors='replace')}")
    return res.stdout


def get_diff(cached, paths):
    args = ["diff", "--no-color", "--no-ext-diff", "--no-renames", "--binary",
            "--src-prefix=a/", "--dst-prefix=b/", "-U3"]
    if cached:
        args.append("--cached")
    return git(*args, "--", *paths)


class Hunk:
    """One selectable piece. Text hunks are one run of changed lines inside a parent hunk."""
    def __init__(self, file_header, path, kind, whole=None, parent=None, run=None):
        self.file_header = file_header  # list of bytes lines
        self.path = path
        self.kind = kind
        self.whole = whole              # complete file section for whole-file changes
        self.parent = parent            # Parent for text hunks
        self.run = run                  # index of this hunk's run inside the parent
        self.whole_file = whole is not None
        self.lines = [] if self.whole_file else parent.render({run})

    def patch(self):
        return b"".join(self.whole)


class Parent:
    """A hunk as Git printed it, split into entries and runs of changed lines."""
    def __init__(self, lines):
        m = HUNK_RE.match(lines[0].decode(errors="replace"))
        old_no, new_no = int(m.group(1)), int(m.group(3))
        # entries: [tag, [lines], old_no, new_no]; "\ No newline" markers stick to the previous line
        self.entries = []
        for l in lines[1:]:
            if l.startswith(b"\\") and self.entries:
                self.entries[-1][1].append(l)
                continue
            tag = l[:1] if l[:1] in (b"+", b"-") else b" "
            self.entries.append([tag, [l], old_no, new_no])
            if tag != b"+":
                old_no += 1
            if tag != b"-":
                new_no += 1
        self.runs, i = [], 0
        while i < len(self.entries):
            if self.entries[i][0] == b" ":
                i += 1
                continue
            j = i
            while j < len(self.entries) and self.entries[j][0] != b" ":
                j += 1
            self.runs.append((i, j))
            i = j

    def render(self, selected):
        """One applicable hunk containing only the selected runs, like the 's' key of
        'git add -p' followed by its merging of the chosen pieces: unselected removals
        become context, unselected additions are left out."""
        first, last = min(selected), max(selected)
        start = self.runs[first - 1][1] if first > 0 else 0
        end = self.runs[last + 1][0] if last + 1 < len(self.runs) else len(self.entries)
        run_of = {}
        for k, (a, b) in enumerate(self.runs):
            for idx in range(a, b):
                run_of[idx] = k
        body = []
        for idx in range(start, end):
            tag, lines = self.entries[idx][0], self.entries[idx][1]
            if tag == b" " or run_of[idx] in selected:
                body.extend(lines)
            elif tag == b"-":
                body.append(b" " + lines[0][1:])
                body.extend(lines[1:])
            # an unselected "+" line is left out
        o_count = sum(1 for l in body if l[:1] in (b" ", b"-"))
        n_count = sum(1 for l in body if l[:1] in (b" ", b"+"))
        head = f"@@ -{self.entries[start][2]},{o_count} +{self.entries[start][3]},{n_count} @@\n".encode()
        return [head] + body


def parse(diff):
    """Split a unified diff into the finest selectable hunks, keeping file headers attached."""
    hunks = []
    files = re.split(rb"(?m)^(?=diff --git )", diff)
    for chunk in files:
        if not chunk.startswith(b"diff --git "):
            continue
        lines = chunk.splitlines(keepends=True)
        first_hunk = next((i for i, l in enumerate(lines) if l.startswith(b"@@")), len(lines))
        header, body = lines[:first_hunk], lines[first_hunk:]
        head_text = b"".join(header)
        m = re.match(rb"diff --git a/(.*) b/(.*)\n", lines[0])
        path = m.group(2).decode(errors="replace") if m else "?"
        if b"\nnew file mode" in head_text:
            kind = "new file"
        elif b"\ndeleted file mode" in head_text:
            kind = "deleted file"
        elif b"GIT binary patch" in chunk or b"\nBinary files" in head_text:
            kind = "binary"
        elif not body:
            kind = "mode change"
        else:
            kind = None
        if kind:
            hunks.append(Hunk(header, path, kind, whole=lines))
            continue
        raw = []
        for l in body:
            if l.startswith(b"@@"):
                raw.append([l])
            else:
                raw[-1].append(l)
        for r in raw:
            parent = Parent(r)
            for k in range(len(parent.runs)):
                hunks.append(Hunk(header, path, "hunk", parent=parent, run=k))
    return hunks


def parse_ids(spec, total):
    ids = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            ids.extend(range(int(a), int(b) + 1))
        else:
            ids.append(int(part))
    for i in ids:
        if i < 1 or i > total:
            sys.exit(f"hunk {i} does not exist (there are {total}); run 'list' again")
    return sorted(set(ids))


def build_patch(hunks, ids):
    """Patch with the selected hunks: file headers written once, and pieces of the same
    parent hunk merged back into one hunk (overlapping hunks would not apply)."""
    out, last_header, i = [], None, 0
    chosen = [hunks[n - 1] for n in ids]
    while i < len(chosen):
        h = chosen[i]
        if h.whole_file:
            out.append(h.patch())
            last_header = None
            i += 1
            continue
        runs = {h.run}
        while i + 1 < len(chosen) and chosen[i + 1].parent is h.parent:
            i += 1
            runs.add(chosen[i].run)
        if h.file_header is not last_header:
            out.append(b"".join(h.file_header))
            last_header = h.file_header
        out.append(b"".join(h.parent.render(runs)))
        i += 1
    return b"".join(out)


def describe(i, h):
    if h.whole_file:
        return f"{i:>3}  {h.path}  [{h.kind}, whole file]"
    added = sum(1 for l in h.lines[1:] if l.startswith(b"+"))
    removed = sum(1 for l in h.lines[1:] if l.startswith(b"-"))
    head = h.lines[0].decode(errors="replace").rstrip("\n")
    return f"{i:>3}  {h.path}  {head}  (+{added} -{removed})"


def preview(h, width=100, max_lines=6):
    if h.whole_file:
        return []
    changed = [l.decode(errors="replace").rstrip("\n") for l in h.lines[1:] if l[:1] in (b"+", b"-")]
    shown = [("       " + l)[:width] for l in changed[:max_lines]]
    if len(changed) > max_lines:
        shown.append(f"       ... {len(changed) - max_lines} more changed line(s)")
    return shown


def split_args(argv):
    if "--" in argv:
        i = argv.index("--")
        return argv[:i], argv[i + 1:]
    return argv, []


def blame_map(path, rev="HEAD"):
    """Map line number in <rev>:<path> -> commit that last changed it."""
    out = git("blame", "--porcelain", rev, "--", path, check=False)
    result = {}
    for line in out.splitlines():
        m = BLAME_RE.match(line.decode(errors="replace"))
        if m:
            result[int(m.group(3))] = m.group(1)
    return result


def touched_old_lines(h):
    """Old-side line numbers a hunk removes (exact) and lines next to its insertions (approximate)."""
    m = HUNK_RE.match(h.lines[0].decode(errors="replace"))
    old_line = int(m.group(1))
    removed, neighbours = [], []
    for l in h.lines[1:]:
        tag = l[:1]
        if tag == b"-":
            removed.append(old_line)
            old_line += 1
        elif tag == b"+":
            neighbours.extend([old_line - 1, old_line])  # lines around the insertion point
        elif tag == b" ":
            old_line += 1
    return removed, neighbours


def cmd_targets(base, cached, paths):
    if cached:
        diff = get_diff(True, paths)
    else:
        # work tree vs HEAD, so the line numbers refer to HEAD, which blame reads
        diff = git("diff", "--no-color", "--no-ext-diff", "--no-renames", "--binary",
                   "--src-prefix=a/", "--dst-prefix=b/", "-U3", "HEAD", "--", *paths)
    hunks = parse(diff)
    if not hunks:
        print("no changes")
        return
    in_range = set(git("rev-list", f"{base}..HEAD").decode().split())
    subjects = {}

    def name(sha):
        if sha not in subjects:
            subjects[sha] = git("log", "-1", "--format=%h %s", sha).decode().strip()
        return subjects[sha]

    blames = {}
    if not cached:
        print("note: numbering is for the diff against HEAD (staged + unstaged), which can differ from 'list'")
    for i, h in enumerate(hunks, 1):
        print(describe(i, h))
        if h.whole_file:
            verdict = "no target: whole-file change; decide by meaning (a new file usually starts a new commit or belongs with the commit that first uses it)"
            print(f"       -> {verdict}")
            continue
        if h.path not in blames:
            blames[h.path] = blame_map(h.path)
        bl = blames[h.path]
        removed, neighbours = touched_old_lines(h)
        exact = Counter(bl[n] for n in removed if n in bl)
        near = Counter(bl[n] for n in neighbours if n in bl)
        exact_in = {s: c for s, c in exact.items() if s in in_range}
        near_in = {s: c for s, c in near.items() if s in in_range}
        if exact:
            if len(exact_in) == 1 and len(exact) == 1:
                sha = next(iter(exact_in))
                print(f"       -> {name(sha)}   [confident: every changed line was last written by it]")
            elif exact_in:
                print("       -> ambiguous, changed lines come from several commits:")
                for sha, c in exact.most_common():
                    where = "in range" if sha in in_range else "before the base"
                    print(f"          {c} line(s) {name(sha)} ({where})")
                print("          split the hunk (see the module help) or keep it as its own commit")
            else:
                print("       -> no target in range: the changed lines predate the base. This is a new change, not a fixup.")
        elif near_in:
            best = sorted(near_in.items(), key=lambda kv: -kv[1])
            print("       -> pure addition; neighbouring lines come from:")
            for sha, c in best:
                print(f"          {name(sha)}")
            print("          [weak evidence: check by meaning which commit this addition completes]")
        else:
            print("       -> pure addition next to code from before the base: probably a new change, not a fixup")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return
    cmd, rest = argv[0], argv[1:]
    opts, paths = split_args(rest)
    cached = "--cached" in opts
    opts = [o for o in opts if o != "--cached"]

    if cmd == "targets":
        if not opts:
            sys.exit("usage: hunks.py targets <base> [--cached] [-- <paths>...]")
        cmd_targets(opts[0], cached, paths)
        return

    if cmd == "stage":
        cached = False
    elif cmd == "unstage":
        cached = True
    hunks = parse(get_diff(cached, paths))

    if cmd == "list":
        if not cached:
            untracked = git("ls-files", "--others", "--exclude-standard", "--", *paths).decode().split("\n")
            untracked = [u for u in untracked if u]
            if untracked:
                print(f"note: {len(untracked)} untracked file(s) are not listed. If they belong here (a split after")
                print("      'git reset HEAD~' turns added files into untracked ones), run 'git add -N <file>' first:")
                for u in untracked[:10]:
                    print(f"        {u}")
        if not hunks:
            print("no changes")
        for i, h in enumerate(hunks, 1):
            print(describe(i, h))
            for p in preview(h):
                print(p)
        return
    if cmd not in ("show", "stage", "unstage") or not opts:
        sys.exit(__doc__)
    ids = parse_ids(opts[0], len(hunks))
    patch = build_patch(hunks, ids)
    if cmd == "show":
        sys.stdout.buffer.write(patch)
        return
    apply_args = ["apply", "--cached", "--recount"]
    if cmd == "unstage":
        apply_args.append("--reverse")
    git(*apply_args, "--check", "-", input=patch)
    git(*apply_args, "-", input=patch)
    print(f"{cmd}d hunk(s) {','.join(map(str, ids))}. Numbering has changed: run 'list' again.")


if __name__ == "__main__":
    main(sys.argv[1:])
