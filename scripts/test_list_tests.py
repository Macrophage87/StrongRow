#!/usr/bin/env python3
"""RED/GREEN tests for scripts/list_tests.py, the (:test) declaration extractor.

The extractor is one of the three legs of test-tooling: the pin cross-check is
only as trustworthy as the name list this script derives from the sources. It
shipped untested for one round, and ad-hoc review batteries immediately found
three lexing defects (annotation arguments, string literals, Char literals) --
each one a deadlock-or-phantom class. This suite exists so the fourth defect
fails in CI instead of in review.

Every case builds a scratch tree, runs the REAL script as a subprocess (same
interface CI uses), and asserts the exact (rc, output) pair -- a failure prints
expected-vs-actual, not a bare FAIL.

HERMETIC ON PURPOSE: this suite proves the TOOL, never the repo. An earlier
last case duplicated the pin cross-check against the real tree, so the single
most common maintainer error -- add a (:test), forget the pin line -- red THIS
suite first, with no diff, no file:line and no remedy, while the step that
explains that error perfectly (check_expected_tests.sh) never ran. The
cross-check owns the real-tree assertion; nothing here touches the repo.

Run: python3 scripts/test_list_tests.py
"""

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "list_tests.py")

CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


def invoke(root=None, where=False, cwd=None):
    """Run the real script. Returns (rc, [lines]) with the scratch-root prefix
    stripped from --where paths, so cases can assert exact output.

    The timeout is load-bearing, not hygiene: two of this suite's guards fail
    by HANGING when deleted (a directory-symlink cycle under followlinks, a
    FIFO reaching open()), and a suite that hangs reports nothing."""
    cmd = [sys.executable, SCRIPT]
    if root is not None:
        cmd += ["--root", root]
    if where:
        cmd.append("--where")
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd,
                          timeout=60)
    prefix = (root + os.sep) if root is not None else ""
    lines = [l.replace(prefix, "") for l in proc.stdout.splitlines() if l.strip()]
    return proc.returncode, lines


def run_extractor(files, where=False):
    """files: {relative_path: content} under a scratch source/ tree."""
    with tempfile.TemporaryDirectory() as td:
        root = os.path.join(td, "source")
        for rel, content in files.items():
            path = os.path.join(root, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(content)
        return invoke(root, where)


def decl(name, ann="(:test)"):
    return "%s function %s(logger) {\n    return true;\n}\n" % (ann, name)


# ---------------------------------------------------------------- extracted --

@case("plain column-0 declaration is extracted")
def _():
    return run_extractor({"A.mc": decl("test_plain")}), (0, ["test_plain"])


@case("indented declaration is extracted")
def _():
    return run_extractor({"A.mc": "    " + decl("test_indented")}), \
        (0, ["test_indented"])


@case("annotation on its own line is extracted")
def _():
    return run_extractor(
        {"A.mc": "(:test)\nfunction test_ownLine(logger) {\n}\n"}), \
        (0, ["test_ownLine"])


@case("multi-annotation forms are extracted, either order")
def _():
    return run_extractor(
        {"A.mc": decl("test_a", "(:debug, :test)")
                 + decl("test_b", "(:test, :debug)")}), \
        (0, ["test_a", "test_b"])


@case("double-spaced annotation is extracted")
def _():
    return run_extractor(
        {"A.mc": "(:test)  function  test_twoSpace(logger) {\n}\n"}), \
        (0, ["test_twoSpace"])


@case("parenthesised annotation arguments are extracted (typecheck(false))")
def _():
    # RED before round 4: [^)]* died at the ')' closing 'typecheck(false',
    # making the declaration invisible to the pin while the simulator ran it.
    return run_extractor(
        {"A.mc": decl("test_parenArgs", "(:test, :typecheck(false))")}), \
        (0, ["test_parenArgs"])


@case("recursion: a test in a subdirectory is extracted")
def _():
    return run_extractor({"sub/deep/A.mc": decl("test_deep")}), \
        (0, ["test_deep"])


# ----------------------------------------------------------------- excluded --

@case("declaration inside a block comment is excluded")
def _():
    return run_extractor(
        {"A.mc": "/*\n" + decl("test_commented") + "*/\n"}), (0, [])


@case("declaration behind a line comment is excluded")
def _():
    return run_extractor({"A.mc": "// " + decl("test_lineCommented")}), (0, [])


@case("annotation text inside a string literal is not a declaration")
def _():
    # RED before round 4: string CONTENTS were preserved and then searched,
    # so a string could mint a phantom pinned test whose printed remedy walked
    # a maintainer into the deadlock.
    return run_extractor(
        {"A.mc": 'var s = "(:test) function test_inString(logger)";\n'}), \
        (0, [])


@case("an escaped quote does not end the string literal early")
def _():
    # Pins the escape handling the string-blanking fix depends on: with it
    # deleted, the \" closes the string, the annotation text lands OUTSIDE the
    # literal, and the phantom declaration is extracted -- the suite green-lit
    # exactly that deletion until this case (found in review, round 5).
    src = ('var s = "she said \\"(:test) function test_escPhantom(logger)\\"";\n'
           + decl("test_afterEscape"))
    return run_extractor({"A.mc": src}), (0, ["test_afterEscape"])


@case("a Char literal quote does not desynchronise the comment stripper")
def _():
    # RED before round 4: '"' had no lexer case, so the stripper treated the
    # rest of the file as inside a string, comment-stripping switched off, and
    # commented-out declarations were resurrected.
    src = ("var c = '\"';\n"
           "// " + decl("test_afterChar") +
           decl("test_real"))
    return run_extractor({"A.mc": src}), (0, ["test_real"])


@case("// inside a string literal does not eat the rest of the line")
def _():
    src = 'var url = "http://x";\n' + decl("test_afterUrl")
    return run_extractor({"A.mc": src}), (0, ["test_afterUrl"])


@case("a non-test annotation is not extracted")
def _():
    return run_extractor(
        {"A.mc": decl("helper", "(:debug)") + decl("test_x")}), (0, ["test_x"])


@case("the word test inside an annotation ARGUMENT does not count")
def _():
    return run_extractor({"A.mc": decl("helper", "(:typecheck(test))")}), (0, [])


@case("symlinked files, symlink cycles and FIFOs are skipped, not followed")
def _():
    # Pins all three walk guards this commit's predecessor added, none of which
    # the suite exercised (found in review, round 5). Deleting them fails
    # loudly here: no islink -> the outside declaration appears in the output;
    # followlinks=True -> the cycle walks forever and invoke()'s timeout trips;
    # no isfile -> open() blocks on the FIFO, same timeout. The skipped
    # outward-pointing link is a KNOWN COST pinned as chosen behaviour -- its
    # declaration is compiled and run but invisible to the pin; see mc_files().
    with tempfile.TemporaryDirectory() as td:
        root = os.path.join(td, "source")
        os.makedirs(root)
        with open(os.path.join(td, "outside.mc"), "w", encoding="utf-8") as fh:
            fh.write(decl("test_behindSymlink"))
        with open(os.path.join(root, "Real.mc"), "w", encoding="utf-8") as fh:
            fh.write(decl("test_real"))
        os.symlink(os.path.join(td, "outside.mc"), os.path.join(root, "Link.mc"))
        os.symlink(root, os.path.join(root, "loop"))   # directory cycle
        os.mkfifo(os.path.join(root, "Fifo.mc"))       # open() would block
        return invoke(root), (0, ["test_real"])


# -------------------------------------------------------------------- shape --

@case("--where reports path and the correct line number")
def _():
    src = "// filler\n// filler\n" + decl("test_line3")
    return run_extractor({"A.mc": src}, where=True), (0, ["A.mc:3:test_line3"])


@case("--where line numbers survive an escaped newline inside a string")
def _():
    # The escape branch used to swallow BOTH characters of an escaped newline,
    # emitting neither -- so every declaration after it reported one line low,
    # contradicting the docstring's line-preservation promise (found in
    # review, round 5). The string below spans lines 1-3; the decl is line 4.
    src = 'var s = "a\\\nb\nc";\n' + decl("test_afterMultiline")
    return run_extractor({"A.mc": src}, where=True), \
        (0, ["A.mc:4:test_afterMultiline"])


@case("the default root (bare invocation, the form CI runs) works")
def _():
    # check_expected_tests.sh invokes `python3 scripts/list_tests.py` with NO
    # --root after cd'ing to the repo top; every other case here passes --root
    # explicitly, so the invocation form CI actually uses was never exercised
    # (found in review, round 5).
    with tempfile.TemporaryDirectory() as td:
        root = os.path.join(td, "source")
        os.makedirs(root)
        with open(os.path.join(root, "A.mc"), "w", encoding="utf-8") as fh:
            fh.write(decl("test_defaultRoot"))
        return invoke(cwd=td), (0, ["test_defaultRoot"])


@case("empty tree extracts nothing and still exits 0")
def _():
    # Fail-closed on empty is the CALLER's job (check_expected_tests.sh); the
    # extractor's contract is to report what exists, exit 0.
    return run_extractor({"A.mc": "// nothing here\n"}), (0, [])



# ------------------------------------------------------- module scoping -----
# A (:test) inside `module M { ... }` is compiled and run like any other, but
# the simulator's RESULTS table names it `M.test_foo`. The pin must carry the
# name the RUNNER prints, or check_ciq_tests.py reds with "missing" and
# "unexpected" for the same test and no pin edit makes both green.

@case("a declaration inside a module is qualified with the module name")
def _():
    src = "module Mod {\n" + decl("test_inside") + "}\n"
    return run_extractor({"A.mc": src}), (0, ["Mod.test_inside"])


@case("nested modules qualify with the whole path")
def _():
    src = "module Outer {\nmodule Inner {\n" + decl("test_deep") + "}\n}\n"
    return run_extractor({"A.mc": src}), (0, ["Outer.Inner.test_deep"])


@case("a module that has closed no longer qualifies what follows it")
def _():
    # The brace walk is the whole mechanism, so the CLOSE has to be pinned as
    # well as the open: a scanner that pushed on `module` and never popped
    # would qualify every later declaration in the file with a scope it is not
    # in, and the module-open case above would stay green.
    src = ("module Mod {\n" + decl("test_inside") + "}\n" + decl("test_after"))
    return run_extractor({"A.mc": src}), (0, ["Mod.test_inside", "test_after"])


@case("braces that are not scopes do not disturb qualification")
def _():
    # Function bodies and dictionary literals push and pop anonymous frames.
    # If they were not balanced against each other, the declaration after them
    # would be attributed to the wrong scope -- silently, and in whichever
    # direction the imbalance ran.
    src = ("module Mod {\n"
           "function noise() { var d = { :a => 1, :b => { :c => 2 } }; }\n"
           + decl("test_afterBraces") + "}\n")
    return run_extractor({"A.mc": src}), (0, ["Mod.test_afterBraces"])


@case("a module reopened twice in one file qualifies both halves")
def _():
    # This is the form the source actually uses: each commit appends its own
    # `module Hsi { ... }` block rather than editing an earlier one.
    src = ("module Mod {\n" + decl("test_first") + "}\n"
           "module Mod {\n" + decl("test_second") + "}\n")
    return run_extractor({"A.mc": src}), \
        (0, ["Mod.test_first", "Mod.test_second"])


@case("a class is NOT a qualifying scope")
def _():
    # Deliberate: a (:test) inside a class is not a form the runner supports,
    # so guessing the name it would print would be inventing an answer. Left
    # unqualified, such a declaration surfaces as ordinary pin drift.
    src = "class Thing {\n" + decl("test_inAClass") + "}\n"
    return run_extractor({"A.mc": src}), (0, ["test_inAClass"])


@case("--where line numbers survive module qualification")
def _():
    src = "module Mod {\n" + decl("test_line2") + "}\n"
    return run_extractor({"A.mc": src}, where=True), \
        (0, ["A.mc:2:Mod.test_line2"])


# ------------------------------------------- module scope: depth and lexing --
# The seven cases above pin one and two levels of nesting and the brace walk.
# The five below pin the two things #140's acceptance criteria name that nothing
# yet held: ANY nesting depth, and that a `module` keyword which is only TEXT --
# inside a comment or a string literal -- opens no scope.
#
# THESE WERE GREEN ON ARRIVAL. The behaviour they pin already exists: it falls
# out of running the scope walk over strip_comments' output rather than over the
# raw text, which 3460b27 chose deliberately. So they are pins, not
# differentials, and neither can be shown red against the extractor as it
# stands. What makes them load-bearing is the mutant: point the walk at the raw
# text and the three text-only cases red while every other case in this file
# stays green. Recorded here so a later reader does not mistake a pin for a
# regression test that once failed.

@case("three module levels qualify with the whole path")
def _():
    # MEASURED, not assumed: fr965 / SDK 9.2.0 ran a throwaway probe with one
    # (:test) at file scope and one at each of three nesting depths, and the
    # RESULTS table printed
    #     test_zzp_atFileScope                     PASS
    #     ZzpA.test_zzp_oneDeep                    PASS
    #     ZzpA.ZzpB.test_zzp_twoDeep               PASS
    #     ZzpA.ZzpB.ZzpC.test_zzp_threeDeep        PASS
    # -- so the full dotted path at every depth is the name the runner prints,
    # and the pin has to carry it. Before this the two-level expectation was
    # asserted from the one-level observation.
    src = ("module Aa {\nmodule Bb {\nmodule Cc {\n" + decl("test_deep3")
           + "}\n}\n}\n")
    return run_extractor({"A.mc": src}), (0, ["Aa.Bb.Cc.test_deep3"])


@case("an inner module closes back to the outer one, not to file scope")
def _():
    # An off-by-one in the pop -- popping to empty, or popping one frame too
    # many -- leaves the middle declaration reading `test_outer` instead of
    # `Aa.test_outer` while both the nesting case above and the single-module
    # case stay green. Three declarations, three different depths, one file.
    src = ("module Aa {\nmodule Bb {\n" + decl("test_inner") + "}\n"
           + decl("test_outer") + "}\n" + decl("test_fileScope"))
    return run_extractor({"A.mc": src}), \
        (0, ["Aa.Bb.test_inner", "Aa.test_outer", "test_fileScope"])


@case("a module keyword inside a line comment opens no scope")
def _():
    src = "// module Fake {\n" + decl("test_notInAModule")
    return run_extractor({"A.mc": src}), (0, ["test_notInAModule"])


@case("a module keyword inside a block comment opens no scope")
def _():
    # The unbalanced `{` matters as much as the keyword: a walk that saw this
    # text would both qualify the declaration wrongly AND leave the stack one
    # frame deep for the rest of the file.
    src = "/* module Fake { */\n" + decl("test_notInAModule")
    return run_extractor({"A.mc": src}), (0, ["test_notInAModule"])


@case("a module keyword inside a string literal opens no scope")
def _():
    src = 'var s = "module Fake {";\n' + decl("test_notInAModule")
    return run_extractor({"A.mc": src}), (0, ["test_notInAModule"])


def main():
    failures = 0
    for name, fn in CASES:
        try:
            got, want = fn()
            ok = got == want
        except Exception as exc:              # a traceback (or a hang caught by
            print("FAIL %s" % name)           # the timeout) is a FAIL, not a crash
            print("      ! raised %r" % (exc,))
            failures += 1
            continue
        print("%-4s %s" % ("OK" if ok else "FAIL", name))
        if not ok:
            failures += 1
            print("      ! expected (rc, lines) = %r" % (want,))
            print("      !      got (rc, lines) = %r" % (got,))
    print("\n%d/%d extractor tests passed." % (len(CASES) - failures, len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
