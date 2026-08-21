#!/usr/bin/env python3
"""RED/GREEN tests for scripts/check_source_refs.py.

Every case builds a scratch source/ tree, runs the REAL checker as a subprocess
with --root (the interface CI uses), and asserts the exit code plus, for the
failures, that the printed reason names the token that is wrong. A guard whose
message does not identify the defect costs a maintainer the hour the defect
would have.

HERMETIC: nothing here reads the repository. The repository's own comments are
asserted by the CI step that runs the checker with no --root; if that moved in
here, a maintainer adding a genuine cross-reference would red a TOOL suite with
no file:line instead of the check that prints one -- the same split
test_check_ceiling_notes.py keeps for the same reason.

The three ACCEPTED shapes below are not politeness. Each is a spelling that
exists in source/ today, and a checker that rejected any of them would be
rejecting accurate documentation and would be turned off within a week.

Run: python3 scripts/test_check_source_refs.py
"""

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_source_refs.py")

CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


def run(files):
    """files: {relative path under the scratch root: content}. Returns
    (rc, stdout) with the root replaced by <root> and os.sep normalised, so a
    case can assert an exact file:line on Windows and on the Linux runner."""
    with tempfile.TemporaryDirectory() as td:
        for rel, content in files.items():
            path = os.path.join(td, rel)
            os.makedirs(os.path.dirname(path) or td, exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(content)
        proc = subprocess.run(
            [sys.executable, CHECKER, "--root", td],
            capture_output=True, text=True, timeout=60)
        out = proc.stdout.replace(td, "<root>").replace(os.sep, "/")
        return proc.returncode, out


# ------------------------------------------------------------------ accepted --

@case("a reference to a declared file-scope test resolves")
def _():
    rc, out = run({"A.mc": "// see test_zz_theThing\n"
                           "(:test) function test_zz_theThing(logger) { return true; }\n"})
    return (rc, "OK:" in out), (0, True)


@case("a MODULE-QUALIFIED reference resolves to the module it is in")
def _():
    # The form the simulator's RESULTS table prints, and the form
    # scripts/expected_tests.txt pins.
    rc, out = run({"A.mc": "module Zz {\n"
                           "// see Zz.test_zz_theThing\n"
                           "(:test) function test_zz_theThing(logger) { return true; }\n"
                           "}\n"})
    return (rc, "OK:" in out), (0, True)


@case("a BARE reference to a test declared inside a module resolves")
def _():
    # Most of the cross-references in source/ are written bare even where the
    # declaration is module-scoped. Requiring the qualifier would red dozens of
    # accurate comments on the day this landed.
    rc, out = run({"A.mc": "// see test_zz_theThing\n"
                           "module Zz {\n"
                           "(:test) function test_zz_theThing(logger) { return true; }\n"
                           "}\n"})
    return (rc, "OK:" in out), (0, True)


@case("a reference across files resolves")
def _():
    rc, out = run({"A.mc": "// pinned by test_zz_theThing\n",
                   "B.mc": "(:test) function test_zz_theThing(logger) { return true; }\n"})
    return (rc, "OK:" in out), (0, True)


@case("a PREFIX used as an ellipsis is not a reference")
def _():
    # `test_cr_`, `test_rb_`, `test_erg_` and `test_ctw_` all appear in source/
    # as prose shorthand for a family of cases.
    rc, out = run({"A.mc": "// the test_zz_ cases live here\n"})
    return (rc, "OK:" in out), (0, True)


@case("a reference to a scripts/test_*.py suite is not a (:test) reference")
def _():
    # source/StrongRowView.mc names scripts/test_cue_replay.py and
    # scripts/test_speed_witness.py. Both are real files; neither is a (:test).
    name = os.path.basename(CHECKER).replace("check_", "test_check_")[:-3]
    return (run({"A.mc": "// re-derived by %s\n" % name})[0],), (0,)


@case("a tree with no references at all passes")
def _():
    rc, out = run({"A.mc": "function ordinary() { return 1; }\n"})
    return (rc, "OK:" in out), (0, True)


@case("a declaration inside a BLOCK COMMENT does not satisfy a reference")
def _():
    # The extractor strips comments, so a commented-out declaration is not a
    # test -- and must not be able to resolve a pointer either. Without this the
    # checker could be silenced by commenting the target back in.
    rc, out = run({"A.mc": "// see test_zz_theThing\n"
                           "/* (:test) function test_zz_theThing(logger) { return true; } */\n"})
    return (rc, "test_zz_theThing" in out), (1, True)


# -------------------------------------------------------------------- reject --

@case("a reference to a test that does not exist FAILS, naming file:line")
def _():
    # The shape found in review: a forward reference to a case never written.
    rc, out = run({"A.mc": "// nailed together by test_zz_theOneThatWasNeverWritten\n"
                           "(:test) function test_zz_somethingElse(logger) { return true; }\n"})
    return (rc,
            "<root>/A.mc:1:" in out,
            "test_zz_theOneThatWasNeverWritten" in out), (1, True, True)


@case("a QUALIFIED reference naming the WRONG module fails and prints the right one")
def _():
    rc, out = run({"A.mc": "// see Yy.test_zz_theThing\n"
                           "module Zz {\n"
                           "(:test) function test_zz_theThing(logger) { return true; }\n"
                           "}\n"})
    return (rc, "Yy.test_zz_theThing" in out, "Zz.test_zz_theThing" in out), \
           (1, True, True)


@case("a reference to a plain (non-test) function of that name fails")
def _():
    # A helper named test_* is not a (:test). Resolving against every function
    # would let a pointer aim at something the runner never executes.
    rc, out = run({"A.mc": "// see test_zz_theThing\n"
                           "function test_zz_theThing(logger) { return true; }\n"})
    return (rc, "test_zz_theThing" in out), (1, True)


@case("a name inside a STRING LITERAL is checked like any other reference")
def _():
    # logger.error() messages name sibling cases in source/; a wrong name there
    # misdirects exactly as a wrong name in a comment does.
    rc, out = run({"A.mc": 'function f() { return "see test_zz_ghost"; }\n'})
    return (rc, "test_zz_ghost" in out), (1, True)


@case("every unresolved reference is reported, not just the first")
def _():
    rc, out = run({"A.mc": "// test_zz_ghostOne\n// test_zz_ghostTwo\n"})
    return (rc,
            "test_zz_ghostOne" in out,
            "test_zz_ghostTwo" in out,
            "2 unresolved" in out), (1, True, True, True)


@case("an EMPTY tree passes rather than erroring")
def _():
    # Deliberate and stated: this checker's job is resolution, not existence.
    # scripts/check_expected_tests.sh is the check that fails closed on an
    # empty extraction, and duplicating that here would give two guards one
    # message between them.
    rc, out = run({"notes.txt": "test_zz_ghost\n"})
    return (rc, "OK:" in out), (0, True)


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
    print("\n%d/%d source cross-reference checker tests passed."
          % (len(CASES) - failures, len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
