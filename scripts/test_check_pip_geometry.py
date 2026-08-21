#!/usr/bin/env python3
"""RED/GREEN tests for scripts/check_pip_geometry.py.

Every case builds a scratch source/StrongRowView.mc, runs the REAL checker as a
subprocess with --root (the same interface CI uses), and asserts the exit code
plus, for the failures, that the printed reason names the thing that is wrong.
A guard whose message does not identify the defect costs a maintainer the same
hour the defect would have.

HERMETIC: nothing here reads the repository. The repository's own table is
asserted by the CI step that runs the checker with no --root; if that ever moved
in here, a maintainer editing the real table would red a TOOL suite instead of
the check that prints the offending row.

THE HEADLINE CASE is `the shipped-before figures are rejected`: it feeds the
checker the SIX ROWS AS THEY WERE WRITTEN before #141 and requires the wrong
ones to be named. That is the defect this checker was written for, reproduced
rather than described. (Five are named at this checker's 0.05 px tolerance;
#141's own "four of six" is the count at half-pixel tolerance, which is the
precision the old one-decimal table was written to. The case records both.)

The marker word is assembled rather than written, so this file's fixtures can
never be picked up as real rows.

Run: python3 scripts/test_check_pip_geometry.py
"""

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_pip_geometry.py")

MARK = "PIP" + "GEOM"

CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


# The shipped constants and formulas, verbatim enough for the checker's body
# pins to match. Anything the checker parses lives here; everything else is
# omitted, so a fixture cannot pass by accident on unrelated text.
CONSTS = """
const PIP_ROW_Y_FRAC = 0.045;
const PIP_CT_W_FRAC = 0.09;
const PIP_DOT_R_FRAC = 0.014;
const PIP_DOT_R_MIN  = 3;
const PIP_GAP_FRAC   = 0.009;
const PIP_GAP_MIN    = 2;
"""

BODIES = """
    static function pipChordXMax(w, h, yTop) {
        var r  = (w < h) ? w / 2.0 : h / 2.0;
        var dy = h / 2.0 - yTop;
        if (dy < 0)  { dy = -dy; }
        if (dy >= r) { return w / 2.0; }
        return w / 2.0 + Math.sqrt(r * r - dy * dy);
    }

    static function pipDotR(w) {
        var r = (w * $.PIP_DOT_R_FRAC).toNumber();
        return (r < $.PIP_DOT_R_MIN) ? $.PIP_DOT_R_MIN : r;
    }

    static function pipGap(w) {
        var g = (w * $.PIP_GAP_FRAC).toNumber();
        return (g < $.PIP_GAP_MIN) ? $.PIP_GAP_MIN : g;
    }

    static function pipDotCx(w, h) {
        return pipChordXMax(w, h, $.PIP_ROW_Y_FRAC * h) - 1 - pipDotR(w);
    }

    static function pipCtCx(w, h) {
        return pipDotCx(w, h) - pipDotR(w) - pipGap(w) - (w * $.PIP_CT_W_FRAC) / 2.0;
    }
"""

DRAWGPS = ('        dc.drawText(w * 0.52, h * 0.045, Gfx.FONT_XTINY, "RR", '
           'Gfx.TEXT_JUSTIFY_CENTER);\n')

# The correct rows, as #141 derived them.
GOOD_ROWS = [
    ("454px-family", 454, 39, 39, 24.56, 8.61, 1.98, 17.93),
    ("fenix843mm", 416, 36, 36, 22.24, 9.20, 1.68, 14.72),
    ("epix2pro47mm", 416, 28, 28, 30.24, 17.20, 5.68, 18.72),
    ("fenix7-7pro-6-6pro", 260, 18, 18, 18.40, 10.00, 3.30, 11.70),
    ("fenix6spro", 240, 18, 18, 15.60, 7.15, 2.35, 10.80),
    ("fenix6xpro", 280, 18, 18, 21.20, 12.85, 4.25, 12.60),
]

GOOD_RANGE = (15.60, 30.24, 7.15, 17.20, 1.68, 5.68, 10.80, 18.72)


def row_line(r):
    return ("//   %s %s w=%d ct=%d rr=%d gap_today=%.2f gap_after=%.2f "
            "edge_today=%.2f edge_after=%.2f\n"
            % (MARK, r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]))


def range_line(v=GOOD_RANGE):
    return ("//   %s-RANGE gap_today=%.2f-%.2f gap_after=%.2f-%.2f "
            "edge_today=%.2f-%.2f edge_after=%.2f-%.2f\n"
            % ((MARK,) + v))


def source(rows=None, rng=None, consts=CONSTS, bodies=BODIES, base=0.66,
           drawgps=DRAWGPS, with_range=True):
    rows = GOOD_ROWS if rows is None else rows
    txt = consts + "\n"
    if base is not None:
        txt += "//   %s-BASE ct_today=%s\n" % (MARK, base)
    for r in rows:
        txt += row_line(r)
    txt += "\nclass StrongRowView {\n" + bodies + "\n" + drawgps
    if with_range:
        txt += range_line(GOOD_RANGE if rng is None else rng)
    txt += "}\n"
    return txt


def run(text):
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "source", "StrongRowView.mc")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        proc = subprocess.run([sys.executable, CHECKER, "--root", td],
                              capture_output=True, text=True, timeout=60)
        out = proc.stdout.replace(td, "<root>").replace(os.sep, "/")
        return proc.returncode, out


# ------------------------------------------------------------------ accepted --

@case("the corrected table passes")
def _():
    rc, out = run(source())
    return (rc, "OK:" in out), (0, True)


# ------------------------------------------------------------------ rejected --

@case("the shipped-before figures are rejected, and the right five are named")
def _():
    # THE DEFECT THIS CHECKER WAS WRITTEN FOR, reproduced. These are the six
    # rows exactly as source/StrongRowView.mc carried them before #141, with
    # the edge columns (which the old table did not have) left correct so only
    # the claimed gaps are under test.
    #
    # FIVE, NOT FOUR, AND THE DIFFERENCE IS THE TOLERANCE -- recorded because
    # #141's own text says four of six. At this checker's 0.05 px tolerance (the
    # precision the corrected rows carry) FIVE rows disagree; at a half-pixel
    # tolerance -- which is the precision the OLD one-decimal table was written
    # to -- four do, and that is #141's figure. The row that moves between the
    # two readings is 454px-family: 25.0 / 9.0 claimed against 24.56 / 8.61
    # derived, out by 0.44 and 0.39. fenix6spro (15.6 / 7.2 against
    # 15.60 / 7.15) is inside both tolerances and must NOT be named.
    old = [
        ("454px-family", 454, 39, 39, 25.0, 9.0, 1.98, 17.93),
        ("fenix843mm", 416, 36, 36, 22.3, 9.9, 1.68, 14.72),
        ("epix2pro47mm", 416, 28, 28, 22.3, 21.9, 5.68, 18.72),
        ("fenix7-7pro-6-6pro", 260, 18, 18, 15.6, 12.7, 3.30, 11.70),
        ("fenix6spro", 240, 18, 18, 15.6, 7.2, 2.35, 10.80),
        ("fenix6xpro", 280, 18, 18, 15.6, 12.9, 4.25, 12.60),
    ]
    rc, out = run(source(rows=old))
    named = [d for d in ("454px-family", "fenix843mm", "epix2pro47mm",
                         "fenix7-7pro-6-6pro", "fenix6spro", "fenix6xpro")
             if (MARK + " " + d) in out]
    return (rc, named), (1, ["454px-family", "fenix843mm", "epix2pro47mm",
                             "fenix7-7pro-6-6pro", "fenix6xpro"])


@case("the headroom row alone is rejected -- 12.7 where the truth is 10.00")
def _():
    # The row that matters most on its own: an author who trusts 12.7 px of
    # headroom and spends it lands the gap under the 5.0 px floor.
    rows = [r if r[0] != "fenix7-7pro-6-6pro"
            else ("fenix7-7pro-6-6pro", 260, 18, 18, 18.40, 12.70, 3.30, 11.70)
            for r in GOOD_ROWS]
    rc, out = run(source(rows=rows))
    return (rc, "gap_after = 12.70" in out, "10.00 px" in out), (1, True, True)


@case("a moved constant reds the table it invalidates")
def _():
    # PIP_GAP_FRAC widens the space between the CT label and the mark, which
    # moves every 'after' figure. The table must follow the code or fail.
    rc, out = run(source(consts=CONSTS.replace("0.009", "0.05")))
    return (rc, out.count(MARK + " ") >= 6), (1, True)


@case("an edited formula reds by name instead of being silently re-mirrored")
def _():
    # The checker cannot execute Monkey C, so it mirrors the five shipped
    # expressions. Editing one must fail loudly: a mirror that quietly stops
    # matching its original is worse than no mirror.
    bad = BODIES.replace("- 1 - pipDotR(w)", "- 2 - pipDotR(w)")
    rc, out = run(source(bodies=bad))
    return (rc, "pipDotCx" in out, "has changed" in out), (1, True, True)


@case("a moved RR pip reds every gap measured to it")
def _():
    rc, out = run(source(drawgps=DRAWGPS.replace("w * 0.52", "w * 0.48")))
    return (rc, out.count(MARK + " ") >= 6), (1, True)


@case("an RR pip on a different row is rejected as a row mismatch")
def _():
    rc, out = run(source(drawgps=DRAWGPS.replace("h * 0.045", "h * 0.055")))
    return (rc, "must be the same row" in out), (1, True)


@case("a missing summary range is rejected")
def _():
    rc, out = run(source(with_range=False))
    return (rc, "-RANGE" in out), (1, True)


@case("a summary range that does not match the rows is rejected")
def _():
    # The OTHER half of #141: both upper bounds of the in-line summary were
    # wrong while the rows it quoted were, at that point, wrong differently.
    bad = (15.60, 25.00, 7.15, 21.90, 1.68, 5.68, 10.80, 18.72)
    rc, out = run(source(rng=bad))
    return (rc, "gap_today = 15.60-25.00" in out,
            "gap_after = 7.15-21.90" in out), (1, True, True)


@case("no rows at all is a failure, not a vacuous pass")
def _():
    rc, out = run(source(rows=[]))
    return (rc, "silently disables it" in out), (1, True)


@case("a missing constant is a failure, not a default")
def _():
    rc, out = run(source(consts=CONSTS.replace(
        "const PIP_GAP_MIN    = 2;", "")))
    return (rc, "PIP_GAP_MIN" in out), (1, True)


@case("a missing -BASE line is rejected: the 'today' column is not in the code")
def _():
    rc, out = run(source(base=None))
    return (rc, "-BASE" in out), (1, True)


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
    print("\n%d/%d pip-geometry checker tests passed."
          % (len(CASES) - failures, len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
