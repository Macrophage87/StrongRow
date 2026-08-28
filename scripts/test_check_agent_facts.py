#!/usr/bin/env python3
"""RED/GREEN tests for scripts/check_agent_facts.py.

Every case builds a scratch tree, runs the REAL checker as a subprocess with
--root (the interface CI uses), and asserts the exit code PLUS that the printed
reason names the thing that is wrong. A checker that reds without naming the
defect costs a maintainer the hour the defect would have.

HERMETIC: nothing here reads the repository. The repository's own FACTS.md is
asserted by the CI step that runs the checker with no --root; if that moved in
here, a maintainer editing a real fact would red a TOOL suite instead of the
check that prints the file and the figure.

The marker word is assembled rather than written, so nothing in this file can
be picked up as a real marker line.

Every RED case perturbs ONE thing away from the shared GREEN fixture, so a case
that reds names exactly its own defect: that is the differential, not a
description of one.

Run: python3 scripts/test_check_agent_facts.py
"""

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_agent_facts.py")

MARK = "AGENT" + "FACT"
CEIL = "CEI" + "LING"

DIGEST = "sha256:" + "a" * 64

# The fixture's fields: a short stand-in for the real twenty-six, including a
# gap in the id sequence (there is one in the real map too, at 19).
FIELDS = [(0, "row_stroke_rate"), (1, "dist_per_stroke"), (3, "rmssd")]

CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


# --------------------------------------------------------------- the fixture --

def ci_yml(digest=DIGEST, anchors=1):
    body = ["name: CI", "jobs:", "  run-tests:", "    container:"]
    for _ in range(anchors):
        body.append("      image: &ciq_image ghcr.io/x/y@%s # v2.8.0" % digest)
    body.append("  release-build:")
    body.append("    container:")
    body.append("      image: *ciq_image")
    return "\n".join(body) + "\n"


def manifest(devices=("fr965", "fenix6")):
    rows = "\n".join('        <iq:product id="%s"/>' % d for d in devices)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<iq:manifest xmlns:iq="http://www.garmin.com/xml/connectiq" '
            'version="3">\n'
            '    <iq:application id="d2b7f4a19c6e4e0a93f5c1802a6b7de3">\n'
            '        <iq:products>\n%s\n        </iq:products>\n'
            '    </iq:application>\n</iq:manifest>\n' % rows)


def expected_tests(names=("test_a", "test_b")):
    return ("# a comment line, ignored\n\n"
            + "".join("%s\n" % n for n in names))


def view(fields=None, extra=""):
    fields = FIELDS if fields is None else fields
    out = ["class StrongRowView {", "    function startSession() {"]
    for fid, name in fields:
        out.append('        mFit%d = mSession.createField(' % fid)
        out.append('            "%s", %d, Fit.DATA_TYPE_FLOAT,' % (name, fid))
        out.append('            { :mesgType => Fit.MESG_TYPE_RECORD });')
    out.append(extra)
    out.append("    }")
    out.append("}")
    return "\n".join(out) + "\n"


def ceiling_note(anchor="v08-display-fixes", used=246, limit=253, free=7,
                 nth=8, suffix="th"):
    return ("// %s %s fenix6: %d used of %d, %d free -- the %d%s file-scope "
            "(:test) added reds\n" % (CEIL, anchor, used, limit, free, nth,
                                      suffix))


def facts(container=DIGEST, devices=2, tests=2,
          ceiling=("v08-display-fixes", 246, 253, 7), fields=None,
          drop=(), extra_lines=()):
    """The marker-line section of a FACTS.md, plus a little prose around it."""
    fields = FIELDS if fields is None else fields
    lines = ["# Canonical facts", "", "Prose the checker never reads.", ""]
    if "ci-container" not in drop:
        lines.append("    %s ci-container %s" % (MARK, container))
    if "manifest-devices" not in drop:
        lines.append("    %s manifest-devices %d" % (MARK, devices))
    if "pinned-tests" not in drop:
        lines.append("    %s pinned-tests %d" % (MARK, tests))
    if "ceiling" not in drop:
        lines.append("    %s ceiling %s %d %d %d" % ((MARK,) + tuple(ceiling)))
    if "devfield" not in drop:
        for fid, name in fields:
            lines.append("    %s devfield %d %s" % (MARK, fid, name))
    lines.extend("    " + x for x in extra_lines)
    return "\n".join(lines) + "\n"


def tree(**over):
    """The GREEN tree. Each RED case overrides exactly one entry."""
    files = {
        ".github/workflows/ci.yml": ci_yml(),
        "manifest.xml": manifest(),
        "scripts/expected_tests.txt": expected_tests(),
        "source/StrongRowView.mc": view(),
        "source/GridGateTest.mc": ceiling_note(),
        "docs/agents/FACTS.md": facts(),
    }
    files.update(over)
    return files


def run(files):
    """Returns (rc, stdout) with the scratch root replaced by <root> and os.sep
    normalised, so a case can assert an exact path on Windows and Linux alike."""
    with tempfile.TemporaryDirectory() as td:
        for rel, content in files.items():
            path = os.path.join(td, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(content)
        proc = subprocess.run(
            [sys.executable, CHECKER, "--root", td],
            capture_output=True, text=True, timeout=120)
        out = proc.stdout.replace(td, "<root>").replace(os.sep, "/")
        return proc.returncode, out


# ------------------------------------------------------------------ accepted --

@case("the coherent fixture passes")
def _():
    rc, out = run(tree())
    return (rc, "OK:" in out), (0, True)


@case("a gap in the developer field id sequence is not a defect")
def _():
    # The real map skips 19. An id set is not required to be contiguous, only
    # to be unique and to match the file.
    rc, out = run(tree())
    return (rc, "devfield" in out), (0, False)


@case("prose, blank lines and indentation around the markers are ignored")
def _():
    body = facts() + "\nMore prose. A sentence mentioning ci-container.\n"
    rc, out = run(tree(**{"docs/agents/FACTS.md": body}))
    return (rc, "OK:" in out), (0, True)


# ------------------------------------------------------- the five derivations --

@case("RED: the container digest moves in the workflow and not in FACTS.md")
def _():
    other = "sha256:" + "b" * 64
    rc, out = run(tree(**{".github/workflows/ci.yml": ci_yml(digest=other)}))
    return (rc, "ci-container" in out and other in out), (1, True)


@case("RED: a device is removed from the manifest")
def _():
    rc, out = run(tree(**{"manifest.xml": manifest(devices=("fr965",))}))
    return (rc, "manifest-devices" in out and "'1'" in out), (1, True)


@case("RED: a (:test) is added to the pin file")
def _():
    rc, out = run(tree(**{"scripts/expected_tests.txt":
                          expected_tests(("test_a", "test_b", "test_c"))}))
    return (rc, "pinned-tests" in out and "'3'" in out), (1, True)


@case("RED: the ceiling anchor FACTS.md quotes no longer exists in the tree")
def _():
    rc, out = run(tree(**{"source/GridGateTest.mc":
                          ceiling_note(anchor="some-later-branch")}))
    return (rc, "v08-display-fixes" in out and "anchor" in out), (1, True)


@case("RED: the ceiling headroom in FACTS.md disagrees with the note")
def _():
    # The note is re-measured in source and FACTS.md keeps the old figures --
    # the exact way a quoted measurement goes stale.
    rc, out = run(tree(**{"source/GridGateTest.mc":
                          ceiling_note(used=245, free=8, nth=9, suffix="th")}))
    return (rc, "ceiling" in out and "245 used" in out), (1, True)


@case("RED: a developer field is renamed in the source")
def _():
    renamed = [(0, "row_stroke_rate"), (1, "dps"), (3, "rmssd")]
    rc, out = run(tree(**{"source/StrongRowView.mc": view(fields=renamed)}))
    return (rc, "devfield 1" in out and "'dps'" in out), (1, True)


@case("RED: a developer field exists in the source and not in FACTS.md")
def _():
    plus = FIELDS + [(7, "core_temperature")]
    rc, out = run(tree(**{"source/StrongRowView.mc": view(fields=plus)}))
    return (rc, "7 (core_temperature)" in out
            and "not listed in FACTS.md" in out), (1, True)


@case("RED: FACTS.md lists a developer field the source does not declare")
def _():
    body = facts(fields=FIELDS + [(9, "max_core_temperature")])
    rc, out = run(tree(**{"docs/agents/FACTS.md": body}))
    return (rc, "9 (max_core_temperature)" in out
            and "no createField call declares" in out), (1, True)


# ------------------------------------------------------------- fail-closed ---

@case("RED: FACTS.md is missing entirely")
def _():
    files = tree()
    del files["docs/agents/FACTS.md"]
    rc, out = run(files)
    return (rc, "docs/agents/FACTS.md" in out
            and "pointers dangle" in out), (1, True)


@case("RED: deleting a marker line does not silently disable its check")
def _():
    rc, out = run(tree(**{"docs/agents/FACTS.md":
                          facts(drop=("ci-container",))}))
    return (rc, "0 " + MARK + " ci-container line(s)" in out
            and "exactly one is required" in out), (1, True)


@case("RED: deleting every devfield line does not silently disable the map")
def _():
    rc, out = run(tree(**{"docs/agents/FACTS.md": facts(drop=("devfield",))}))
    return (rc, "no " + MARK + " devfield line" in out), (1, True)


@case("RED: a duplicated marker line is refused, not last-one-wins")
def _():
    body = facts(extra_lines=["%s pinned-tests 99" % MARK])
    rc, out = run(tree(**{"docs/agents/FACTS.md": body}))
    return (rc, "2 " + MARK + " pinned-tests line(s)" in out), (1, True)


@case("RED: a typo in a key is named, not silently unchecked")
def _():
    body = facts(extra_lines=["%s pinned-test 362" % MARK])
    rc, out = run(tree(**{"docs/agents/FACTS.md": body}))
    return (rc, "unrecognised" in out and "'pinned-test'" in out), (1, True)


@case("RED: two &ciq_image anchor definitions in the workflow are refused")
def _():
    # The digest is the pin and the workflow keeps exactly one definition of
    # it. Two would mean two pins that can drift apart, which is worse than
    # none, so the checker refuses to pick one.
    rc, out = run(tree(**{".github/workflows/ci.yml": ci_yml(anchors=2)}))
    return (rc, "2 `image: &ciq_image" in out), (1, True)


@case("RED: no &ciq_image anchor definition at all is refused")
def _():
    rc, out = run(tree(**{".github/workflows/ci.yml":
                          "name: CI\njobs:\n  x:\n    runs-on: ubuntu-latest\n"}))
    return (rc, "0 `image: &ciq_image" in out), (1, True)


@case("RED: a duplicated developer field id in the source is named")
def _():
    dupe = FIELDS + [(1, "dist_per_stroke_again")]
    rc, out = run(tree(**{"source/StrongRowView.mc": view(fields=dupe)}))
    return (rc, "more than once" in out and "silently re-labels" in out), (1, True)


@case("RED: a createField written inside a comment is refused, not resolved")
def _():
    # The raw read sees it and the comment-stripped read does not. The checker
    # refuses the disagreement rather than picking a winner -- the raw read is
    # the only one that can be fooled, so a silent preference for either is a
    # hole. This is also the case that proves the two reads are really two.
    commented = ('        // was: mSession.createField("ghost", 42, '
                 'Fit.DATA_TYPE_FLOAT,')
    rc, out = run(tree(**{"source/StrongRowView.mc": view(extra=commented)}))
    return (rc, "raw and comment-stripped reads" in out
            and "[42]" in out), (1, True)


@case("RED: source/StrongRowView.mc missing is a failure, not an empty map")
def _():
    files = tree()
    del files["source/StrongRowView.mc"]
    rc, out = run(files)
    return (rc, "StrongRowView.mc is missing" in out), (1, True)


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
    print("\n%d/%d agent-facts checker tests passed."
          % (len(CASES) - failures, len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
