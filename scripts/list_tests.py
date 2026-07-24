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
# then `function <identifier>`. DOTALL so the annotation may sit on its own
# line above the function.
DECL_RE = re.compile(
    r'\(\s*:[^)]*\btest\b[^)]*\)\s*function\s+([A-Za-z_][A-Za-z0-9_]*)',
    re.S,
)


def strip_comments(text):
    """Remove // and /* */ comments, preserving string contents and newlines
    (newlines kept so line numbers survive for --where)."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':                              # string literal
            out.append(c); i += 1
            while i < n and text[i] != '"':
                if text[i] == '\\':
                    out.append(text[i]); i += 1
                    if i < n:
                        out.append(text[i]); i += 1
                    continue
                out.append(text[i]); i += 1
            if i < n:
                out.append('"'); i += 1
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
    hits = []
    for dirpath, _dirs, files in os.walk(root, followlinks=True):
        for f in sorted(files):
            if f.endswith(".mc"):
                hits.append(os.path.join(dirpath, f))
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
