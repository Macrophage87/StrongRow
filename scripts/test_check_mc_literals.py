#!/usr/bin/env python3
"""RED/GREEN tests for scripts/check_mc_literals.py.

Every case builds a scratch source tree, runs the REAL checker as a subprocess
with --root, and asserts the exit code plus, for the failures, the file:line it
names. A guard that says "something is wrong somewhere" costs a maintainer the
same hour the defect would have.

HERMETIC: nothing here reads the repository. The repository itself is asserted
by the CI step that runs the checker with no --root.

THE TWO CASES THAT CARRY THE WEIGHT are the shapes that make this a lexer and
not a grep: a `//` comment holding an unbalanced quote (this codebase's comments
quote strings constantly) and a Char literal '"' (which desynchronises a naive
scanner for the rest of the file). Both must stay GREEN, or the check would red
on ordinary source and be turned off.

Run: python3 scripts/test_check_mc_literals.py
"""

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_mc_literals.py")

CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


def run(files, root_sub="source"):
    with tempfile.TemporaryDirectory() as td:
        base = os.path.join(td, root_sub)
        os.makedirs(base, exist_ok=True)
        for name, text in files.items():
            with open(os.path.join(base, name), "w", encoding="utf-8",
                      newline="") as fh:
                fh.write(text)
        proc = subprocess.run([sys.executable, CHECKER, "--root", base],
                              capture_output=True, text=True, timeout=60)
        # NOT a blanket os.sep replacement: on Windows that would rewrite the
        # backslash of the `\n` the message tells the author to use, and the
        # case asserting on it would fail for a reason with nothing to do with
        # the check. The checker already prints its paths with forward slashes.
        out = (proc.stdout + proc.stderr).replace(td, "<root>")
        return proc.returncode, out


GOOD = '''using Toybox.Test;

// A comment holding an unbalanced quote: "Drew: and nothing closing it.
(:test) function test_ok(logger) {
    logger.error("one line, escaped break. Drew:\\n" + log());
    var q = '"';
    logger.error("after a Char literal the lexer must still be in sync");
    return true;
}
'''

BAD = '''using Toybox.Test;

(:test) function test_bad(logger) {
    logger.error("#125: the REST screen must draw the footer for " +
                 "this case to have a subject. Drew:
" + log());
    return false;
}
'''


# ------------------------------------------------------------------ accepted --

@case("ordinary source with escaped breaks passes")
def _():
    rc, out = run({"Ok.mc": GOOD})
    return (rc, "OK:" in out), (0, True)


@case("a comment carrying an unbalanced quote does not red")
def _():
    src = ('// the widest footer is "REC 199:59 12.35km 9999wk\n'
           'function f() { return 1; }\n')
    rc, out = run({"Cmt.mc": src})
    return (rc, "OK:" in out), (0, True)


@case("a Char literal of a double quote does not desynchronise the scan")
def _():
    src = 'function f() { var q = \'"\'; return q; }\n'
    rc, out = run({"Chr.mc": src})
    return (rc, "OK:" in out), (0, True)


@case("a block comment containing a newline inside quotes does not red")
def _():
    src = '/* a "quote\nacross lines" inside a block comment */\nfunction f() {}\n'
    rc, out = run({"Blk.mc": src})
    return (rc, "OK:" in out), (0, True)


# ------------------------------------------------------------------ rejected --

@case("a literal spanning two lines is rejected, with its line number")
def _():
    # THE DEFECT THIS CHECK WAS WRITTEN FOR, reproduced: the exact shape found
    # in source/WorkStrokeTest.mc, where "Drew:\\n" had been flattened to a raw
    # break.
    rc, out = run({"Bad.mc": BAD})
    return (rc, "Bad.mc:5" in out, "\\n" in out), (1, True, True)


@case("two offending literals in one file are both reported")
def _():
    rc, out = run({"Bad.mc": BAD + BAD.replace("test_bad", "test_bad2")})
    return (rc, out.count("a literal is still open") == 2), (1, True)


@case("an offending literal in ANY file is found, not just the first")
def _():
    rc, out = run({"AOk.mc": GOOD, "ZBad.mc": BAD})
    return (rc, "ZBad.mc:5" in out), (1, True)


@case("an empty tree is a failure, not a vacuous pass")
def _():
    rc, out = run({})
    return (rc, "proved nothing" in out), (1, True)


def main():
    failures = 0
    for name, fn in CASES:
        try:
            got, want = fn()
            ok = got == want
        except Exception as exc:
            print("FAIL %s" % name)
            print("      ! raised %r" % (exc,))
            failures += 1
            continue
        print("%-4s %s" % ("OK" if ok else "FAIL", name))
        if not ok:
            failures += 1
            print("      ! expected = %r" % (want,))
            print("      !      got = %r" % (got,))
    print("\n%d/%d Monkey C literal checker tests passed."
          % (len(CASES) - failures, len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
