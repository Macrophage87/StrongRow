#!/usr/bin/env python3
"""Fail-closed derivation check on the recording footer's width table (#217).

WHY THIS EXISTS. drawFoot's footer shipped on nineteen products with a
CHARACTER bound and no clearance. Its own comment said so -- "a CHARACTER bound
and not a clearance ... nothing here claims a measured margin" -- and the
conclusion drawn from it in practice, that the row was therefore not the
binding constraint, was never checked against a pixel. It was wrong: a field
report on a fenix 9 Pro 51 mm said the red bottom row overflowed the watch, and
the measurement says it overflowed on ALL NINETEEN.

So the replacement claim is not prose either. The per-device widths are
measured once and committed as data (`footDevices()` in
source/FootStateTest.mc); this check re-derives every margin figure in
source/StrongRowView.mc's FOOTGEOM block from:

  * the SHIPPED row position and bezel floor, parsed out of
    StrongRowView.footRowYFrac() and StrongRowView.footBezelPx() rather than
    transcribed;
  * the SHIPPED chord formula, whose BODY IS PINNED here. This checker cannot
    execute Monkey C, so it mirrors footChordPx in Python -- and a mirror
    nothing checks is a copy waiting to drift. Editing the body fails this
    check with a message saying so, which is the honest behaviour: the table
    has to be re-derived by a human, not silently re-run against a formula it
    no longer matches;
  * the SHIPPED CALL SITE, parsed the same way. Pinning footChordPx's body does
    not prove drawFoot CALLS it, and pinning footFit's body would not prove
    drawFoot uses its ANSWER. With both bodies untouched and the one drawText
    changed back to `forms[0]`, every `post` figure below becomes false while
    this check prints nineteen agreeing rows. That hole is the same one
    check_pip_geometry.py's parse_ct_x exists to close;
  * the measured widths themselves, which are read from footDevices() and
    never restated here.

WHAT THIS CANNOT CHECK, stated so nobody reads more into a green run:

  * IT DOES NOT MEASURE A FONT. Every width comes from a local simulator probe
    recorded in footDevices(); no (:test) and no CI job in this repository can
    obtain a text metric (#121). A row whose widths are wrong passes here and
    is wrong everywhere.
  * IT SAYS NOTHING ABOUT INK. Every figure is a font-BOX edge against a chord,
    the convention drawSetGrid, the #110 arc and the PIPGEOM rows all use. A
    negative margin does not by itself prove a lit pixel was lost.
  * IT DOES NOT PIN footFit's BODY, on purpose: which rung the seam selects is
    pinned by the Foot.test_foot_c2_* cases, which call the shipping function.
    What is checked here is that the LADDER AND THE CHORD admit a fitting rung
    at all -- a property of the table, true whatever footFit does.
  * IT SAYS NOTHING ABOUT HOW THE ROW READS ON A WRIST.

Usage:
  check_foot_geometry.py [--root DIR]

Exit 0 = every marked row, the summary range and the overflow counts agree with
the derivation, 1 = a problem, printed with the row, the claim and the figure.
"""

import argparse
import math
import os
import re
import sys

# Assembled so this file's own format examples are not scanned as data.
MARK = "FOOT" + "GEOM"

TOL = 0.005         # px; the rows carry two decimals

VIEW_REL = os.path.join("source", "StrongRowView.mc")
TEST_REL = os.path.join("source", "FootStateTest.mc")

ROW_RE = re.compile(
    MARK + r"\s+(?P<dev>[A-Za-z0-9_.-]+)\s+w=(?P<w>\d+)\s+fh=(?P<fh>\d+)\s+"
    r"avail=(?P<avail>-?[\d.]+)\s+pre=(?P<pre>-?[\d.]+)\s+"
    r"post=(?P<post>-?[\d.]+)\s+floor=(?P<floor>-?[\d.]+)\s+"
    r"notrec=(?P<notrec>-?[\d.]+)\s+noaccel=(?P<noaccel>-?[\d.]+)")

RANGE_KEYS = ("avail", "pre", "post", "floor", "notrec", "noaccel")
RANGE_RE = re.compile(
    MARK + r"-RANGE\s+" + r"\s+".join(
        r"%s_lo=(?P<%s_lo>-?[\d.]+)\s+%s_hi=(?P<%s_hi>-?[\d.]+)" % (k, k, k, k)
        for k in RANGE_KEYS))

COUNT_RE = re.compile(
    MARK + r"-COUNT\s+pre_over=(?P<pre>\d+)\s+post_over=(?P<post>\d+)\s+"
    r"floor_over=(?P<floor>\d+)\s+notrec_over=(?P<notrec>\d+)\s+"
    r"noaccel_over=(?P<noaccel>\d+)\s+of=(?P<of>\d+)")

# The one shipped expression this checker mirrors, normalised: comments
# stripped, runs of whitespace collapsed. Editing it fails the check by name.
PINNED_BODY = (
    "var r = (w < h) ? w / 2.0 : h / 2.0; "
    "var dy = yFrac * h + boxH - h / 2.0; "
    "if (dy < 0) { dy = -dy; } if (dy >= r) { return 0.0; } "
    "return 2.0 * Math.sqrt(r * r - dy * dy) - 2.0 * bezelPx;")

# Column indices into a footDevices() row. Parsed from the test file's own
# `const FD_* = n;` declarations rather than hard-coded, so reordering the table
# cannot silently re-label every figure below.
FD_NEEDED = ("FD_NAME", "FD_W", "FD_H", "FD_FH", "FD_REC_ROW", "FD_NOKM",
             "FD_TIME", "FD_REC", "FD_PAUSE_MAX", "FD_PAUSE", "FD_NOTREC",
             "FD_NOACCEL", "FD_START_MAX", "FD_START")

# The REC ladder, widest first, as column names. `post` is the margin of the
# longest rung of THIS ladder that fits.
REC_LADDER = ("FD_REC_ROW", "FD_NOKM", "FD_TIME", "FD_REC")


def read(root, rel, problems):
    path = os.path.join(root, rel)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read(), path
    except IOError as exc:
        problems.append("cannot read %s: %s" % (path, exc))
        return None, path


def parse_scalar(text, path, name, problems):
    """A shipped `static function name() { return <float>; }`."""
    m = re.search(r"static\s+function\s+%s\(\)\s*\{\s*return\s+([\d.]+)\s*;\s*\}"
                  % name, text)
    if not m:
        problems.append(
            "%s declares no `static function %s()` returning a literal -- this "
            "check derives the whole table from the shipped value and refuses "
            "to invent one." % (path, name))
        return None
    return float(m.group(1))


def check_body(text, path, problems):
    m = re.search(r"static function footChordPx\([^)]*\)\s*\{(.*?)\n    \}",
                  text, re.S)
    if not m:
        problems.append(
            "%s: no `static function footChordPx` found. This check mirrors "
            "that formula in Python; it cannot verify a mirror of something "
            "that is not there." % path)
        return
    got = re.sub(r"\s+", " ", re.sub(r"//[^\n]*", " ", m.group(1))).strip()
    if got != PINNED_BODY:
        problems.append(
            "%s: the body of footChordPx has changed, so the Python mirror "
            "this check derives the table with may no longer match it.\n"
            "    shipped: %s\n    mirrored: %s\n"
            "  Re-derive the table, then update PINNED_BODY in this file in "
            "the same commit." % (path, got, PINNED_BODY))


def check_call_site(text, path, problems):
    """drawFoot must still ASK the seam and USE its answer.

    Two separate parses, because they fail independently. The first is the
    chord: with it gone, every `avail` figure describes a call nothing makes.
    The second is the selection: with `forms[footFit(...)]` changed back to
    `forms[0]`, every `post` figure is false while the bodies above are
    untouched and every row here still agrees.
    """
    if not re.search(r"footChordPx\(w,\s*h,\s*footRowYFrac\(\),\s*"
                     r"dc\.getFontHeight\(Gfx\.FONT_XTINY\),\s*footBezelPx\(\)\)",
                     text):
        problems.append(
            "%s: drawFoot does not call footChordPx(w, h, footRowYFrac(), "
            "dc.getFontHeight(Gfx.FONT_XTINY), footBezelPx()). Every `avail` "
            "figure in the %s rows is DEFINED as that call's answer, so the "
            "table says nothing once the draw path stops making it." % (path, MARK))
    if not re.search(r"dc\.drawText\(w / 2, h \* footRowYFrac\(\), "
                     r"Gfx\.FONT_XTINY,\s*forms\[footFit\(widths, room\)\],\s*"
                     r"Gfx\.TEXT_JUSTIFY_CENTER\)", text):
        problems.append(
            "%s: the footer is not drawn as forms[footFit(widths, room)] at "
            "h * footRowYFrac() in FONT_XTINY. The `post` column is the margin "
            "of the rung the seam SELECTS; if the draw call stops using that "
            "answer -- `forms[0]` is the whole mutation -- every post figure "
            "becomes false with no row in this table changing." % path)


def parse_fd_indices(text, path, problems):
    idx = {}
    for name in FD_NEEDED:
        m = re.search(r"^const\s+%s\s*=\s*(\d+)\s*;" % name, text, re.M)
        if not m:
            problems.append("%s declares no `const %s`" % (path, name))
        else:
            idx[name] = int(m.group(1))
    return idx


def parse_foot_devices(text, path, problems):
    m = re.search(r"function footDevices\(\)\s*\{\s*return\s*\[(.*?)\];",
                  text, re.S)
    if not m:
        problems.append(
            "%s: no `function footDevices()` returning a literal table. The "
            "measured widths live there and nowhere else; this check will not "
            "carry a second copy of them." % path)
        return []
    rows = []
    for line in m.group(1).split("\n"):
        line = line.split("//")[0].strip()
        rm = re.match(r'\[\s*"([A-Za-z0-9_.-]+)"\s*,\s*([\d,\s]+?)\s*\]', line)
        if not rm:
            continue
        nums = [int(v) for v in rm.group(2).split(",") if v.strip() != ""]
        rows.append([rm.group(1)] + nums)
    return rows


def parse_bezel_copy(text, path, problems):
    m = re.search(r"^const\s+FOOT_MIN_BEZEL_PX\s*=\s*([\d.]+)\s*;", text, re.M)
    if not m:
        problems.append(
            "%s declares no `const FOOT_MIN_BEZEL_PX`. The suite holds the "
            "rows to a bezel floor of its own and the two copies must be "
            "checkable against each other." % path)
        return None
    return float(m.group(1))


def chord(w, h, y_frac, box_h, bezel):
    """The mirror of footChordPx, pinned above."""
    r = (w / 2.0) if w < h else (h / 2.0)
    dy = y_frac * h + box_h - h / 2.0
    if dy < 0:
        dy = -dy
    if dy >= r:
        return 0.0
    return 2.0 * math.sqrt(r * r - dy * dy) - 2.0 * bezel


def derive(row, idx, y_frac, bezel):
    g = lambda k: row[idx[k]]
    avail = chord(g("FD_W"), g("FD_H"), y_frac, g("FD_FH"), bezel)
    post = None
    for name in REC_LADDER:
        if g(name) <= avail:
            post = avail - g(name)
            break
    if post is None:
        post = avail - g(REC_LADDER[-1])
    return {
        "w": g("FD_W"),
        "fh": g("FD_FH"),
        "avail": avail,
        "pre": avail - g("FD_REC_ROW"),
        "post": post,
        "floor": avail - g("FD_REC"),
        "notrec": avail - g("FD_NOTREC"),
        "noaccel": avail - g("FD_NOACCEL"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    args = ap.parse_args()

    problems = []
    view, view_path = read(args.root, VIEW_REL, problems)
    test, test_path = read(args.root, TEST_REL, problems)
    if problems:
        return report(problems)

    y_frac = parse_scalar(view, view_path, "footRowYFrac", problems)
    bezel = parse_scalar(view, view_path, "footBezelPx", problems)
    check_body(view, view_path, problems)
    check_call_site(view, view_path, problems)
    idx = parse_fd_indices(test, test_path, problems)
    rows = parse_foot_devices(test, test_path, problems)
    copy = parse_bezel_copy(test, test_path, problems)
    if problems:
        return report(problems)

    if abs(copy - bezel) > 1e-9:
        problems.append(
            "the suite's Foot.FOOT_MIN_BEZEL_PX is %s and the shipped "
            "StrongRowView.footBezelPx() is %s. Both are the per-side bezel "
            "floor this row works to; two copies that disagree mean one of the "
            "two sets of margins is measured against the wrong reference."
            % (copy, bezel))

    marked = list(ROW_RE.finditer(view))
    if not marked:
        problems.append(
            "no %s row found under %r. This check is only worth its runtime "
            "while the block carries the marker; an empty scan means the rows "
            "were deleted or the marker renamed, either of which silently "
            "disables it." % (MARK, args.root))
        return report(problems)
    if len(marked) != len(rows):
        problems.append(
            "%d %s row(s) in %s against %d footDevices() row(s) in %s -- every "
            "marked row is derived FROM a measured row and there is no such "
            "thing as one without the other."
            % (len(marked), MARK, VIEW_REL, len(rows), TEST_REL))
        return report(problems)

    by_name = {}
    for row in rows:
        by_name[row[idx["FD_NAME"]]] = row

    derived = {}
    for m in marked:
        dev = m.group("dev")
        if dev not in by_name:
            problems.append(
                "%s %s has no footDevices() row -- a margin for a device "
                "nothing measured cannot be checked." % (MARK, dev))
            continue
        d = derive(by_name[dev], idx, y_frac, bezel)
        derived[dev] = d
        if int(m.group("w")) != d["w"] or int(m.group("fh")) != d["fh"]:
            problems.append(
                "%s %s says w=%s fh=%s, footDevices() measured w=%d fh=%d"
                % (MARK, dev, m.group("w"), m.group("fh"), d["w"], d["fh"]))
        for key in ("avail", "pre", "post", "floor", "notrec", "noaccel"):
            claimed = float(m.group(key))
            if abs(claimed - d[key]) > TOL:
                problems.append(
                    "%s %s: the block says %s = %.2f px, the shipped constants, "
                    "the shipped chord formula and the measured widths give "
                    "%.2f px" % (MARK, dev, key, claimed, d[key]))

    mr = RANGE_RE.search(view)
    if not mr:
        problems.append(
            "%s carries no %s-RANGE line. The block quotes ranges from the "
            "rows, and an unchecked summary is the half of #141 that was wrong "
            "in both of its bounds." % (view_path, MARK))
    elif derived:
        for key in RANGE_KEYS:
            lo = min(d[key] for d in derived.values())
            hi = max(d[key] for d in derived.values())
            if abs(float(mr.group(key + "_lo")) - lo) > TOL or \
               abs(float(mr.group(key + "_hi")) - hi) > TOL:
                problems.append(
                    "%s-RANGE says %s = %s to %s px; the rows give %.2f to "
                    "%.2f px" % (MARK, key, mr.group(key + "_lo"),
                                 mr.group(key + "_hi"), lo, hi))

    mc = COUNT_RE.search(view)
    if not mc:
        problems.append(
            "%s carries no %s-COUNT line. How many devices each string "
            "overflows is the whole claim this block makes; asserted, it is "
            "prose." % (view_path, MARK))
    elif derived:
        for key in ("pre", "post", "floor", "notrec", "noaccel"):
            got = sum(1 for d in derived.values() if d[key] < 0)
            want = int(mc.group(key))
            if got != want:
                problems.append(
                    "%s-COUNT says %s_over=%d; the derived rows give %d"
                    % (MARK, key, want, got))
        if int(mc.group("of")) != len(derived):
            problems.append(
                "%s-COUNT says of=%s; %d rows were derived"
                % (MARK, mc.group("of"), len(derived)))

    # The claim the fix rests on, checked independently of any count line: the
    # floor of the REC ladder must fit on EVERY device, or there is a display
    # on which the footer has no form it can legally draw.
    for dev, d in sorted(derived.items()):
        if d["floor"] < 0:
            problems.append(
                "%s: the ladder floor overflows by %.2f px. #217's fix is "
                "'never draw a string wider than the chord', and that is only "
                "achievable while the last rung fits everywhere."
                % (dev, -d["floor"]))

    if not problems:
        print("OK: %d %s row(s), the summary range and the overflow counts "
              "agree with the derivation from the shipped constants, the "
              "pinned chord formula and the measured widths."
              % (len(marked), MARK))
        for m in marked:
            d = derived[m.group("dev")]
            print("  %-20s w=%-4s avail %6.2f   pre %8.2f -> post %6.2f   "
                  "floor %6.2f   notrec %7.2f   noaccel %6.2f"
                  % (m.group("dev"), m.group("w"), d["avail"], d["pre"],
                     d["post"], d["floor"], d["notrec"], d["noaccel"]))
        return 0
    return report(problems)


def report(problems):
    print("FAIL: %d problem(s) in the %s table." % (len(problems), MARK))
    for p in problems:
        print("  - %s" % p)
    return 1


if __name__ == "__main__":
    sys.exit(main())
