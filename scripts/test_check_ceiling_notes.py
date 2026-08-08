#!/usr/bin/env python3
"""RED/GREEN tests for scripts/check_ceiling_notes.py.

Every case builds a scratch tree, runs the REAL checker as a subprocess with
--root (the same interface CI uses), and asserts the exit code plus, for the
failures, that the printed reason names the thing that is wrong. A guard whose
message does not identify the defect costs a maintainer the same hour the
defect would have.

HERMETIC: nothing here reads the repository. The repository's own notes are
asserted by the CI step that runs the checker with no --root; if that ever
moved in here, a maintainer editing a real note would red a TOOL suite with no
file:line instead of the check that prints one.

The marker word is assembled rather than written, so this file's fixtures can
never be picked up as real notes if the checker's skip list is ever wrong.

Run: python3 scripts/test_check_ceiling_notes.py
"""

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_ceiling_notes.py")

MARK = "CEI" + "LING"

CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


def note(anchor="2b23b03", family="fenix6-family", used=252, limit=253,
         free=1, nth=2, suffix="nd"):
    return ("%s %s %s: %d used of %d, %d free -- the %d%s file-scope "
            "(:test) added reds" % (MARK, anchor, family, used, limit, free,
                                    nth, suffix))


def run(files):
    """files: {relative_path: content}. Returns (rc, stdout) with the scratch
    root replaced by <root> and os.sep normalised to '/', so a case can assert
    an exact file:line on Windows and on the Linux runner alike."""
    with tempfile.TemporaryDirectory() as td:
        for rel, content in files.items():
            path = os.path.join(td, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(content)
        proc = subprocess.run(
            [sys.executable, CHECKER, "--root", td],
            capture_output=True, text=True, timeout=60)
        out = proc.stdout.replace(td, "<root>").replace(os.sep, "/")
        return proc.returncode, out


# ------------------------------------------------------------------ accepted --

@case("a coherent note passes")
def _():
    rc, out = run({"scripts/x.py": "# " + note() + "\n"})
    return (rc, "OK:" in out), (0, True)


@case("two identical copies in different languages both parse and agree")
def _():
    # The two real notes live in a Python comment and a Monkey C comment; the
    # marker has to be findable behind either, and the copies have to compare
    # equal despite the different comment leader.
    rc, out = run({"scripts/x.py": "# " + note() + "\n",
                   "source/A.mc": "// " + note() + "\n"})
    return (rc, out.count(MARK + " 2b23b03")), (0, 2)


@case("different anchors may carry different figures without being drift")
def _():
    # before/after is the whole point of the note: two measurements of two
    # different trees are not two copies of one measurement.
    rc, out = run({"scripts/x.py": "# " + note() + "\n"
                   + "# " + note(anchor="post-move", used=238, free=15,
                                 nth=16, suffix="th") + "\n"})
    return (rc, "OK:" in out), (0, True)


# ------------------------------------------------------------------ rejected --

@case("slot arithmetic that does not close is rejected")
def _():
    rc, out = run({"scripts/x.py": "# " + note(used=252, free=0, nth=1,
                                               suffix="st") + "\n"})
    return (rc, "does not close" in out, "scripts/x.py:1" in out), \
        (1, True, True)


@case("the off-by-one consequence -- 'the NEXT one reds' at one free -- is rejected")
def _():
    # THE DEFECT THIS CHECKER WAS WRITTEN FOR. Both real notes carried the
    # correct count (252 of 253, one slot) and then claimed the next file-scope
    # (:test) red the build. The limit is inclusive: measured on fenix6,
    # fenix6pro, fenix6spro and fenix6xpro at 2b23b03, N=1 BUILD SUCCESSFUL and
    # N=2 "Found 254 members in module 'globals'". With one free slot the
    # SECOND is the one that reds, and the arithmetic says so without a compile.
    rc, out = run({"scripts/x.py": "# " + note(free=1, nth=1, suffix="st")
                   + "\n"})
    return (rc, "still BUILDS" in out), (1, True)


@case("a mis-spelled ordinal is rejected")
def _():
    rc, out = run({"scripts/x.py": "# " + note(used=238, free=15, nth=16,
                                               suffix="nd") + "\n"})
    return (rc, "16th" in out), (1, True)


@case("two copies of ONE measurement that disagree are rejected")
def _():
    # The anti-drift half: this is what correcting one copy and forgetting the
    # other looks like, and it is how the repository shipped two files that
    # asserted opposite things about the same commit.
    rc, out = run({"scripts/x.py": "# " + note() + "\n",
                   "source/A.mc": "// " + note(used=246, free=7, nth=8,
                                               suffix="th") + "\n"})
    return (rc, "disagree" in out,
            "scripts/x.py:1" in out and "source/A.mc:1" in out), \
        (1, True, True)


@case("a tree with no note at all is rejected, not quietly passed")
def _():
    # Fail-closed: renaming the marker or deleting the notes must not turn this
    # check into a green no-op. That failure mode is exactly how a documented
    # rule survives unenforced for months.
    rc, out = run({"scripts/x.py": "# nothing to see\n"})
    return (rc, "no %s note found" % MARK in out), (1, True)


@case("a note in a non-text file extension is not scanned")
def _():
    # Bounds the scan honestly: the walk reads a fixed extension set, so a note
    # in, say, a .prg or a .bin is invisible. Pinned so the limitation is a
    # decision rather than a surprise.
    rc, out = run({"scripts/x.py": "# " + note() + "\n",
                   "x.bin": note(used=1, free=1, nth=99, suffix="th") + "\n"})
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
    print("\n%d/%d ceiling-note checker tests passed."
          % (len(CASES) - failures, len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
