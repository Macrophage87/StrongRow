#!/usr/bin/env python3
"""Fail-closed check: no Monkey C string literal spans a source line.

WHAT IS WRONG WITH ONE. A literal written as

    logger.error("... Drew:
" + SgCase.log(geo));

instead of "... Drew:\\n" is NOT a build error -- monkeyc accepts it, measured
on SDK 9.2.0 for both fr965 and fenix6, BUILD SUCCESSFUL with no diagnostic. It
is wrong for two quieter reasons:

  * WHATEVER THE CHECKOUT'S LINE ENDING IS GOES INTO THE STRING CONSTANT. This
    repository is configured `core.autocrlf=true` and carries no .gitattributes,
    so the maintainer's working tree holds CRLF and the compiled .prg carries a
    stray CR inside the message. CI checks out LF and never sees it, which is
    why it stayed invisible;
  * it is the one construct in this tree that a reflow, a formatter or a
    reviewer reading a diff will mis-join, because the line looks unterminated.

Every other diagnostic in this repository writes the escape. This check makes
that the rule rather than the habit, and it is the whole of the rule: nothing
here says anything about line length, quoting style or message wording.

HOW IT LOOKS, and why it is not a grep. A `//` comment or a `/* */` block may
contain an unbalanced quote (this repository's comments quote strings
constantly), and a Char literal like '"' desynchronises a naive scanner for the
rest of the file. So the scan is the comment- and literal-aware walk in
scripts/list_tests.py -- the repository's ONE Monkey C lexer, already pinned by
scripts/test_list_tests.py -- asked for the line numbers it passes over inside
a literal. There is no second lexer here to drift from that one.

Usage:
  check_mc_literals.py [--root DIR]

Exit 0 = no literal spans a line, 1 = at least one does, printed as file:line.
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from list_tests import mc_files, strip_comments            # noqa: E402


def scan(root):
    """[(path, line)] for every unescaped newline inside a literal."""
    hits = []
    for path in mc_files(root):
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
        lines = []
        strip_comments(raw, lines)
        for ln in lines:
            hits.append((path, ln))
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="source")
    args = ap.parse_args()

    files = mc_files(args.root)
    if not files:
        # Fail closed: an empty scan means the root moved or the tree is gone,
        # and "no offending literal" would then be true for the wrong reason.
        print("FAIL: no .mc file found under %r, so this check proved nothing."
              % args.root)
        return 1

    hits = scan(args.root)
    if hits:
        print("FAIL: %d string literal(s) span a source line." % len(hits))
        for path, ln in hits:
            print("  - %s:%d  a literal is still open at the end of this line. "
                  "Close it and write the break as \\n: on a CRLF checkout the "
                  "raw newline puts a carriage return inside the string "
                  "constant, and monkeyc accepts it silently."
                  % (path.replace(os.sep, "/"), ln))
        return 1

    print("OK: %d .mc file(s) scanned, no string literal spans a source line."
          % len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main())
