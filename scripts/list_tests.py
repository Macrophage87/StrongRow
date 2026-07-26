#!/usr/bin/env python3
"""List the (:test) function names declared under source/, comment-aware.

This replaces a column-0 `grep` whose blind spots were measured one by one:
an indented declaration, the annotation on its own line, a multi-annotation
form like `(:debug, :test)`, and extra spaces were all INVISIBLE to it -- while
the simulator still compiles and runs every one of them. An invisible-but-run
declaration deadlocks CI: unpinned, the parser reds with "unexpected tests";
pinned, the pin cross-check reds with "no longer declared"; and no edit to the
pin file makes both green. Conversely, a declaration inside a /* */ block
comment is NOT run, and the old guard false-red'd on it -- with a printed
remedy that would have promoted commented-out code into a phantom pinned test.

So: strip // and /* */ comments first (string literals respected), then match
any `(: ... )` annotation group containing the token `test`, followed by
`function <name>` -- across newlines, at any indent, with any annotation
spelling. That is deliberately broader than the style the codebase uses today;
style enforcement is not this script's job, correctness of the pin is.

Usage:
  list_tests.py            -> names, one per line, in file/position order
  list_tests.py --where    -> "path:line:name" instead (for diagnostics)

Exit 0 always (an empty result is the CALLER's fail-closed decision to make,
with its own message -- this script just reports what exists).
"""

import argparse
import os
import re
import sys

# An annotation group containing :test (alone or among others, any order),
# then `function <identifier>`. No re.S: the pattern contains no `.` -- \s and
# the annotation-body classes match newlines on their own, and THAT is what
# lets the annotation sit on its own line above the function. (An earlier
# version passed re.S anyway and credited it with the cross-line behaviour;
# it was dead code and a misattribution, found in review.)
#
# The annotation body admits ONE level of balanced parens -- `[^()]` with an
# optional `\([^()]*\)` -- because annotations take arguments:
# `(:test, :typecheck(false))` is legal Monkey C, and the previous `[^)]*`
# body died at the `)` closing `typecheck(false`, making that declaration
# invisible to the pin while the simulator still ran it (the deadlock this
# script exists to prevent, reintroduced through its own regex). One level,
# not a depth counter: two-level nesting has no known legal Monkey C form. If
# one ever appears it is loud, not silent -- pinned, the cross-check reds on
# a name "no longer declared"; unpinned, run-tests reds on "unexpected
# tests" -- and this is the comment to widen when that happens.
_ANN_BODY = r'(?:[^()]|\([^()]*\))*'
DECL_RE = re.compile(
    r'\(\s*:' + _ANN_BODY + r'\btest\b' + _ANN_BODY + r'\)\s*function\s+([A-Za-z_][A-Za-z0-9_]*)',
)


def strip_comments(text):
    """Remove // and /* */ comments AND blank out string/Char literal BODIES,
    keeping delimiters and newlines (so line numbers survive for --where).

    Blanking literal bodies matters twice over:
      * a string containing the annotation text would otherwise be extracted as
        a phantom pinned test, and the drift diff's printed remedy would walk a
        maintainer straight into pinning it;
      * a Char literal like '"' would otherwise desynchronise the string lexer,
        turning comment-stripping off for the rest of the file and resurrecting
        commented-out declarations."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"' or c == "'":                  # string or Char literal
            quote = c
            out.append(c); i += 1
            while i < n and text[i] != quote:
                if text[i] == '\\' and i + 1 < n:
                    if text[i + 1] == '\n':
                        out.append('\n')          # an escaped NEWLINE still ends
                    i += 2                        # a line: swallowing it shifted
                    continue                      # every later --where line by one
                if text[i] == '\n':
                    out.append('\n')              # keep line numbers
                i += 1
            if i < n:
                out.append(quote); i += 1
        elif text.startswith('//', i):            # line comment
            while i < n and text[i] != '\n':
                i += 1
        elif text.startswith('/*', i):            # block comment
            end = text.find('*/', i + 2)
            end = n if end == -1 else end + 2
            out.append('\n' * text.count('\n', i, end))   # keep line numbers
            i = end
        else:
            out.append(c); i += 1
    return ''.join(out)


def mc_files(root="source"):
    # No followlinks: it bought nothing (the tree has no symlinks) and cost
    # termination -- a directory-symlink cycle loops forever, in a job that runs
    # on every PR. Symlinked files are skipped too, and that is a TRADEOFF, not
    # a free win: a link pointing INSIDE source/ would duplicate a name into an
    # unfixable drift diff (the case the skip serves), but a link pointing
    # OUTSIDE source/ holds a declaration the compiler builds and the simulator
    # runs while this extractor cannot see it -- accepted while no symlink of
    # either kind exists, and pinned by the extractor suite either way.
    # Anything that is not a regular file is skipped too (a FIFO named *.mc
    # would block open() indefinitely).
    hits = []
    for dirpath, _dirs, files in os.walk(root):
        for f in sorted(files):
            p = os.path.join(dirpath, f)
            if f.endswith(".mc") and os.path.isfile(p) and not os.path.islink(p):
                hits.append(p)
    return sorted(hits)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--where", action="store_true",
                    help="print path:line:name instead of bare names")
    ap.add_argument("--root", default="source")
    args = ap.parse_args()

    for path in mc_files(args.root):
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
        stripped = strip_comments(raw)
        for m in DECL_RE.finditer(stripped):
            name = m.group(1)
            line = stripped.count("\n", 0, m.start()) + 1
            if args.where:
                print("%s:%d:%s" % (path, line, name))
            else:
                print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
