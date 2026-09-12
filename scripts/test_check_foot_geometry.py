#!/usr/bin/env python3
"""RED/GREEN tests for scripts/check_foot_geometry.py.

Every case builds a scratch source/StrongRowView.mc AND source/FootStateTest.mc,
runs the REAL checker as a subprocess with --root (the same interface CI uses),
and asserts the exit code plus, for the failures, that the printed reason names
the thing that is wrong. A guard whose message does not identify the defect
costs a maintainer the same hour the defect would have.

HERMETIC: nothing here reads the repository. The repository's own table is
asserted by the CI step that runs the checker with no --root; if that ever moved
in here, a maintainer editing the real table would red a TOOL suite instead of
the check that prints the offending row.

THE HEADLINE CASE is `the pre-fix draw call is rejected`. Reverting one line --
`forms[footFit(widths, room)]` back to `forms[0]` -- puts the shipped footer
back to the overflowing string the field report was about while every body the
checker pins is untouched and every derived row still agrees. If that mutation
passed, the whole table would be describing a call the app no longer makes.

The marker word is assembled rather than written, so this file's fixtures can
never be picked up as real rows.

Run: python3 scripts/test_check_foot_geometry.py
"""

import math
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_foot_geometry.py")

MARK = "FOOT" + "GEOM"

CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


# -- the shipped halves the checker parses ------------------------------------

SCALARS = """
    static function footRowYFrac() { return 0.87; }
    static function footBezelPx() { return 2.0; }
"""

CHORD = """
    static function footChordPx(w, h, yFrac, boxH, bezelPx) {
        var r = (w < h) ? w / 2.0 : h / 2.0;
        var dy = yFrac * h + boxH - h / 2.0;
        if (dy < 0) { dy = -dy; }
        if (dy >= r) { return 0.0; }
        return 2.0 * Math.sqrt(r * r - dy * dy) - 2.0 * bezelPx;
    }
"""

CALLSITE = """
        var room = footChordPx(w, h, footRowYFrac(),
                               dc.getFontHeight(Gfx.FONT_XTINY), footBezelPx());
        dc.setColor(footColour(fs), Gfx.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * footRowYFrac(), Gfx.FONT_XTINY,
                    forms[footFit(widths, room)], Gfx.TEXT_JUSTIFY_CENTER);
"""

# The pre-fix draw call: the seam is still asked for the chord and its answer is
# thrown away. This is the mutation the headline case feeds in.
CALLSITE_PREFIX = """
        var room = footChordPx(w, h, footRowYFrac(),
                               dc.getFontHeight(Gfx.FONT_XTINY), footBezelPx());
        dc.setColor(footColour(fs), Gfx.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * footRowYFrac(), Gfx.FONT_XTINY,
                    forms[0], Gfx.TEXT_JUSTIFY_CENTER);
"""

INDICES = """
const FD_NAME = 0;
const FD_W = 1;
const FD_H = 2;
const FD_FH = 3;
const FD_REC_ROW = 4;
const FD_REC_MAX = 5;
const FD_NOKM_MAX = 6;
const FD_NOKM = 7;
const FD_TIME_MAX = 8;
const FD_TIME = 9;
const FD_REC = 10;
const FD_PAUSE_MAX = 11;
const FD_PAUSE = 12;
const FD_NOTREC = 13;
const FD_NOACCEL = 14;
const FD_START_MAX = 15;
const FD_START = 16;
const FOOT_MIN_BEZEL_PX = 2.0;
"""

# Three real measured rows, enough to exercise every column and both sides of
# the notrec overflow. Order: w, h, fh, recRow, recMax, noKmMax, noKm, timeMax,
# time, rec, pauseMax, pause, notRec, noAccel, startMax, start.
GOOD_ROWS = [
    ("fenix9pro51mm", 466, 466, 37, 349, 400, 273, 239, 158, 141, 57, 239,
     116, 238, 146, 226, 95),
    ("fr965", 454, 454, 37, 349, 400, 273, 239, 158, 141, 57, 239, 116, 238,
     146, 226, 95),
    ("fenix7", 260, 260, 19, 165, 189, 128, 112, 74, 66, 26, 111, 53, 110, 67,
     107, 45),
]

REC_LADDER = (4, 7, 9, 10)      # recRow, noKm, time, rec -- widest first


def derive(row, y_frac=0.87, bezel=2.0):
    w, h, fh = row[1], row[2], row[3]
    r = (w / 2.0) if w < h else (h / 2.0)
    dy = abs(y_frac * h + fh - h / 2.0)
    avail = 0.0 if dy >= r else 2.0 * math.sqrt(r * r - dy * dy) - 2.0 * bezel
    post = None
    for col in REC_LADDER:
        if row[col] <= avail:
            post = avail - row[col]
            break
    if post is None:
        post = avail - row[REC_LADDER[-1]]
    return {"w": w, "fh": fh, "avail": avail, "pre": avail - row[4],
            "post": post, "floor": avail - row[10],
            "notrec": avail - row[13], "noaccel": avail - row[14]}


KEYS = ("avail", "pre", "post", "floor", "notrec", "noaccel")


def row_line(row, override=None):
    d = derive(row)
    if override:
        d.update(override)
    return ("//   %s %s w=%d fh=%d avail=%.2f pre=%.2f post=%.2f floor=%.2f "
            "notrec=%.2f noaccel=%.2f\n"
            % (MARK, row[0], d["w"], d["fh"], d["avail"], d["pre"], d["post"],
               d["floor"], d["notrec"], d["noaccel"]))


def range_line(rows, override=None):
    ds = [derive(r) for r in rows]
    vals = {}
    for k in KEYS:
        vals[k + "_lo"] = min(d[k] for d in ds)
        vals[k + "_hi"] = max(d[k] for d in ds)
    if override:
        vals.update(override)
    return ("//   %s-RANGE " % MARK) + " ".join(
        "%s=%.2f" % (k, vals[k]) for k in
        [k + s for k in KEYS for s in ("_lo", "_hi")]) + "\n"


def count_line(rows, override=None):
    ds = [derive(r) for r in rows]
    vals = dict((k, sum(1 for d in ds if d[k] < 0)) for k in
                ("pre", "post", "floor", "notrec", "noaccel"))
    vals["of"] = len(rows)
    if override:
        vals.update(override)
    return ("//   %s-COUNT pre_over=%d post_over=%d floor_over=%d "
            "notrec_over=%d noaccel_over=%d of=%d\n"
            % (MARK, vals["pre"], vals["post"], vals["floor"], vals["notrec"],
               vals["noaccel"], vals["of"]))


def view(rows=None, scalars=SCALARS, chord=CHORD, callsite=CALLSITE,
         row_over=None, range_over=None, count_over=None, with_range=True,
         with_count=True):
    rows = GOOD_ROWS if rows is None else rows
    txt = "class StrongRowView {\n"
    for r in rows:
        txt += row_line(r, (row_over or {}).get(r[0]))
    # With no rows there is nothing to summarise; the checker must reject the
    # block on the missing rows, not on a summary the fixture invented.
    if with_range and rows:
        txt += range_line(rows, range_over)
    if with_count and rows:
        txt += count_line(rows, count_over)
    txt += scalars + chord
    txt += "    hidden function drawFoot(dc, w, h, dist, fs) {\n"
    txt += callsite
    txt += "    }\n}\n"
    return txt


def test_file(rows=None, indices=INDICES):
    rows = GOOD_ROWS if rows is None else rows
    txt = "module Foot {\n" + indices + "\nfunction footDevices() {\n    return [\n"
    txt += ",\n".join(
        '        [ "%s", %s ]' % (r[0], ", ".join(str(v) for v in r[1:]))
        for r in rows)
    txt += "\n    ];\n}\n}\n"
    return txt


def run(view_text, test_text):
    with tempfile.TemporaryDirectory() as td:
        os.makedirs(os.path.join(td, "source"), exist_ok=True)
        with open(os.path.join(td, "source", "StrongRowView.mc"), "w",
                  encoding="utf-8") as fh:
            fh.write(view_text)
        with open(os.path.join(td, "source", "FootStateTest.mc"), "w",
                  encoding="utf-8") as fh:
            fh.write(test_text)
        proc = subprocess.run([sys.executable, CHECKER, "--root", td],
                              capture_output=True, text=True, timeout=60)
        out = proc.stdout.replace(td, "<root>").replace(os.sep, "/")
        return proc.returncode, out


# ------------------------------------------------------------------ accepted --

@case("the derived table passes")
def _():
    rc, out = run(view(), test_file())
    return (rc, "OK:" in out), (0, True)


# ------------------------------------------------------------------ rejected --

@case("THE HEADLINE: the pre-fix draw call is rejected, and named")
def _():
    rc, out = run(view(callsite=CALLSITE_PREFIX), test_file())
    return (rc, "forms[0]" in out and "post" in out), (1, True)


@case("dropping the footChordPx call from drawFoot is rejected")
def _():
    bad = CALLSITE.replace("footChordPx(w, h, footRowYFrac(),\n"
                           "                               "
                           "dc.getFontHeight(Gfx.FONT_XTINY), footBezelPx())",
                           "191.06")
    rc, out = run(view(callsite=bad), test_file())
    return (rc, "footChordPx" in out), (1, True)


@case("an edited chord formula is rejected by body pin, not silently re-derived")
def _():
    bad = CHORD.replace("boxH - h / 2.0", "- h / 2.0")
    rc, out = run(view(chord=bad), test_file())
    return (rc, "footChordPx has changed" in out), (1, True)


@case("taking the chord at the box TOP instead of the bottom is rejected")
def _():
    # The trap this table exists to avoid: at the box top the 454 px row reads
    # 301.36 px of chord instead of 191.06, which turns the reported overflow
    # into a comfortable fit. The body pin catches it before any figure moves.
    bad = CHORD.replace("yFrac * h + boxH - h / 2.0", "yFrac * h - h / 2.0")
    rc, out = run(view(chord=bad), test_file())
    return (rc, "footChordPx has changed" in out), (1, True)


@case("a moved row position re-derives, and a stale table is rejected")
def _():
    # The rows stay as they are and only the shipped fraction moves. Every
    # figure in the block is then wrong, and the checker must say so per row
    # rather than accept the block because it is internally consistent.
    bad = SCALARS.replace("return 0.87;", "return 0.80;")
    rc, out = run(view(scalars=bad), test_file())
    return (rc, "avail" in out and "fr965" in out), (1, True)


@case("the two bezel copies disagreeing is rejected")
def _():
    rc, out = run(view(), test_file(
        indices=INDICES.replace("FOOT_MIN_BEZEL_PX = 2.0",
                                "FOOT_MIN_BEZEL_PX = 5.0")))
    return (rc, "bezel" in out.lower()), (1, True)


@case("a single wrong margin figure is named with its device")
def _():
    rc, out = run(view(row_over={"fr965": {"post": 99.99}}), test_file())
    return (rc, "fr965" in out and "post" in out), (1, True)


@case("a wrong overflow count is rejected")
def _():
    rc, out = run(view(count_over={"notrec": 0}), test_file())
    return (rc, "notrec_over" in out), (1, True)


@case("a wrong summary range is rejected")
def _():
    rc, out = run(view(range_over={"avail_lo": 1.0}), test_file())
    return (rc, "-RANGE" in out), (1, True)


@case("a ladder floor that does not fit is rejected")
def _():
    # fenix6spro-sized display with a floor string nobody measured against it.
    wide = [("fenix6spro", 240, 240, 19, 165, 189, 128, 112, 74, 66, 260, 111,
             53, 110, 67, 107, 45)]
    rc, out = run(view(rows=wide), test_file(rows=wide))
    return (rc, "ladder floor" in out), (1, True)


@case("a marked row with no measured row is rejected")
def _():
    extra = GOOD_ROWS + [("venu3", 454, 454, 37, 349, 400, 273, 239, 158, 141,
                          57, 239, 116, 238, 146, 226, 95)]
    rc, out = run(view(rows=extra), test_file())
    return (rc, "venu3" in out or "footDevices() row" in out), (1, True)


@case("no marked rows at all is rejected, not silently passed")
def _():
    rc, out = run(view(rows=[]), test_file(rows=[]))
    return (rc, "no %s row found" % MARK in out), (1, True)


@case("a missing RANGE line is rejected")
def _():
    rc, out = run(view(with_range=False), test_file())
    return (rc, "-RANGE line" in out), (1, True)


@case("a missing COUNT line is rejected")
def _():
    rc, out = run(view(with_count=False), test_file())
    return (rc, "-COUNT line" in out), (1, True)


@case("a missing footDevices() table is rejected")
def _():
    rc, out = run(view(), "module Foot {\n" + INDICES + "\n}\n")
    return (rc, "footDevices" in out), (1, True)


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
    print("\n%d/%d foot-geometry checker tests passed."
          % (len(CASES) - failures, len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
