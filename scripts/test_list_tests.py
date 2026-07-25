#!/usr/bin/env python3
"""RED/GREEN tests for scripts/list_tests.py, the (:test) declaration extractor.

The extractor is the third leg of test-tooling: the pin cross-check is only as
trustworthy as the name list this script derives from the sources. It shipped
untested for one round, and ad-hoc review batteries immediately found three
lexing defects (annotation arguments, string literals, Char literals) -- each
one a deadlock-or-phantom class. This suite exists so the fourth defect fails
in CI instead of in review.

Every case builds a scratch tree, runs the REAL script as a subprocess (same
interface CI uses), and asserts the exact extracted name set -- and, where it
matters, the --where file:line output and the exit code.

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


def run_extractor(files, where=False):
    """files: {relative_path: content}. Returns (rc, [lines])."""
    with tempfile.TemporaryDirectory() as td:
        root = os.path.join(td, "source")
        for rel, content in files.items():
            path = os.path.join(root, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(content)
        cmd = [sys.executable, SCRIPT, "--root", root]
        if where:
            cmd.append("--where")
        proc = subprocess.run(cmd, capture_output=True, text=True)
        return proc.returncode, [l for l in proc.stdout.splitlines() if l.strip()]


def decl(name, ann="(:test)"):
    return "%s function %s(logger) {\n    return true;\n}\n" % (ann, name)


# ---------------------------------------------------------------- extracted --

@case("plain column-0 declaration is extracted")
def _():
    rc, out = run_extractor({"A.mc": decl("test_plain")})
    return rc == 0 and out == ["test_plain"]


@case("indented declaration is extracted")
def _():
    rc, out = run_extractor({"A.mc": "    " + decl("test_indented")})
    return rc == 0 and out == ["test_indented"]


@case("annotation on its own line is extracted")
def _():
    rc, out = run_extractor({"A.mc": "(:test)\nfunction test_ownLine(logger) {\n}\n"})
    return rc == 0 and out == ["test_ownLine"]


@case("multi-annotation forms are extracted, either order")
def _():
    rc, out = run_extractor({
        "A.mc": decl("test_a", "(:debug, :test)") + decl("test_b", "(:test, :debug)")})
    return rc == 0 and out == ["test_a", "test_b"]


@case("double-spaced annotation is extracted")
def _():
    rc, out = run_extractor({"A.mc": "(:test)  function  test_twoSpace(logger) {\n}\n"})
    return rc == 0 and out == ["test_twoSpace"]


@case("parenthesised annotation arguments are extracted (typecheck(false))")
def _():
    # RED before this round: [^)]* died at the ')' closing 'typecheck(false',
    # making the declaration invisible to the pin while the simulator ran it.
    rc, out = run_extractor({"A.mc": decl("test_parenArgs", "(:test, :typecheck(false))")})
    return rc == 0 and out == ["test_parenArgs"]


@case("recursion: a test in a subdirectory is extracted")
def _():
    rc, out = run_extractor({"sub/deep/A.mc": decl("test_deep")})
    return rc == 0 and out == ["test_deep"]


# ----------------------------------------------------------------- excluded --

@case("declaration inside a block comment is excluded")
def _():
    rc, out = run_extractor({"A.mc": "/*\n" + decl("test_commented") + "*/\n"})
    return rc == 0 and out == []


@case("declaration behind a line comment is excluded")
def _():
    rc, out = run_extractor({"A.mc": "// " + decl("test_lineCommented")})
    return rc == 0 and out == []


@case("annotation text inside a string literal is not a declaration")
def _():
    # RED before this round: string CONTENTS were preserved and then searched,
    # so a string could mint a phantom pinned test whose printed remedy walked
    # a maintainer into the deadlock.
    rc, out = run_extractor(
        {"A.mc": 'var s = "(:test) function test_inString(logger)";\n'})
    return rc == 0 and out == []


@case("a Char literal quote does not desynchronise the comment stripper")
def _():
    # RED before this round: '"' had no lexer case, so the stripper treated the
    # rest of the file as inside a string, comment-stripping switched off, and
    # commented-out declarations were resurrected.
    src = ("var c = '\"';\n"
           "// " + decl("test_afterChar") +
           decl("test_real"))
    rc, out = run_extractor({"A.mc": src})
    return rc == 0 and out == ["test_real"]


@case("// inside a string literal does not eat the rest of the line")
def _():
    src = 'var url = "http://x";\n' + decl("test_afterUrl")
    rc, out = run_extractor({"A.mc": src})
    return rc == 0 and out == ["test_afterUrl"]


@case("a non-test annotation is not extracted")
def _():
    rc, out = run_extractor({"A.mc": decl("helper", "(:debug)") + decl("test_x")})
    return rc == 0 and out == ["test_x"]


@case("the word test inside an annotation ARGUMENT does not count")
def _():
    rc, out = run_extractor({"A.mc": decl("helper", "(:typecheck(test))")})
    return rc == 0 and out == []


# -------------------------------------------------------------------- shape --

@case("--where reports path and the correct line number")
def _():
    src = "// filler\n// filler\n" + decl("test_line3")
    rc, out = run_extractor({"A.mc": src}, where=True)
    return rc == 0 and len(out) == 1 and out[0].endswith("A.mc:3:test_line3")


@case("empty tree extracts nothing and still exits 0")
def _():
    # Fail-closed on empty is the CALLER's job (check_expected_tests.sh); the
    # extractor's contract is to report what exists, exit 0.
    rc, out = run_extractor({"A.mc": "// nothing here\n"})
    return rc == 0 and out == []


@case("the real tree matches the pin exactly")
def _():
    proc = subprocess.run([sys.executable, SCRIPT, "--root",
                           os.path.join(HERE, "..", "source")],
                          capture_output=True, text=True)
    got = sorted(l for l in proc.stdout.splitlines() if l.strip())
    with open(os.path.join(HERE, "expected_tests.txt"), encoding="utf-8") as fh:
        want = sorted(l.strip(" \t\r\n\v\f") for l in fh
                      if l.strip() and not l.strip().startswith("#"))
    return proc.returncode == 0 and got == want


def main():
    failures = 0
    for name, fn in CASES:
        try:
            ok = fn()
        except Exception as exc:                      # a traceback is a FAIL, not a crash
            ok = False
            print("FAIL %s\n      ! raised %r" % (name, exc))
        else:
            print("%-4s %s" % ("OK" if ok else "FAIL", name))
        if not ok:
            failures += 1
    print("\n%d/%d extractor tests passed." % (len(CASES) - failures, len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
