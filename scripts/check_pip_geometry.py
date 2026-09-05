#!/usr/bin/env python3
"""Fail-closed derivation check on the CT status-row geometry tables (#141).

WHY THIS EXISTS. source/StrongRowView.mc carried a "gap today / gap after"
table for the six distinct display widths it then had, and a summary quoting
ranges from it. A reviewer re-derived both from the shipped constants and the
file's own measured font widths: FOUR OF THE SIX ROWS DISAGREED, and both upper
bounds in the summary were wrong. The dangerous row was fenix7/7pro/6/6pro,
where the claimed headroom after the move was 12.7 px against a real 10.00 --
a future author spending that "headroom" lands the gap under the 5.0 px floor
the row works to.

THE SHIPPED GEOMETRY WAS FINE. Only the numbers describing it were wrong, which
is the harder defect to catch: nothing renders differently, and a table of
plausible pixel figures reads as a measurement.

So the consequence is no longer left to prose. The table carries one
machine-readable line per device and this check recomputes every figure from:

  * the SHIPPED constants  PIP_ROW_Y_FRAC, PIP_CT_W_FRAC, PIP_DOT_R_FRAC,
    PIP_DOT_R_MIN, PIP_GAP_FRAC, PIP_GAP_MIN -- parsed, never transcribed;
  * the SHIPPED row position of the RR pip, parsed out of drawGps's own
    drawText call, so moving that pip fails this check instead of silently
    invalidating every gap figure;
  * the SHIPPED CALL SITE OF THE CT LABEL, parsed the same way. Pinning
    pipCtCx's BODY does not prove drawGps CALLS it: with the body untouched and
    that one drawText changed to a fraction, every `after` figure and the whole
    -RANGE line become false while this check prints six agreeing rows.
    Measured by mutation, not supposed -- that hole was open until this line
    existed;
  * the SHIPPED formulas pipChordXMax / pipDotR / pipGap / pipDotCx / pipCtCx,
    whose BODIES ARE PINNED here. This checker cannot execute Monkey C, so it
    mirrors those five expressions in Python -- and a mirror nothing checks is a
    copy waiting to drift. Editing any of the five fails this check with a
    message saying so, which is the honest behaviour: the derivation has to be
    re-made by a human, not silently re-run against a formula it no longer
    matches.

WHAT THIS CANNOT CHECK, stated so nobody reads more into a green run:

  * IT DOES NOT MEASURE A FONT. The per-device "CT" widths come from a local
    simulator measurement recorded at PIP_CT_W_FRAC; no (:test) or CI job in
    this repository can obtain a text metric (#121). A row whose `ct` is wrong
    passes here and is wrong everywhere.
  * THE "RR" WIDTH IS ASSUMED EQUAL TO THE "CT" WIDTH -- two upper-case
    characters in the same face -- because no measurement of it exists in this
    repository at all. Each marked row carries `rr` explicitly so the assumption
    is visible and correctable in one place. If it is ever measured and differs,
    every gap shifts by (rr - ct)/2.
  * IT SAYS NOTHING ABOUT INK. Every figure is a font-BOX edge against a chord,
    the same convention drawSetGrid and the #110 arc use.
  * THE CLAIMED ROWS ARE HISTORY AND ARE NOT DERIVABLE. The -CLAIMED lines
    record what the pre-#141 table asserted. Nothing can check that they are a
    faithful transcript of a deleted table; what IS checked is every statement
    the surrounding prose makes ABOUT them -- how many disagree with the
    derivation at each tolerance, and how many repeat a value the derivation
    forbids them to share.

Usage:
  check_pip_geometry.py [--root DIR]

Exit 0 = every marked row and the summary range agree with the derivation,
1 = a problem, printed with the row, the claim and the derived figure.
"""

import argparse
import math
import os
import re
import sys

# Assembled so this file's own format examples are not scanned as data.
MARK = "PIP" + "GEOM"

TOL = 0.05          # px; the rows carry two decimals

SELF = os.path.abspath(__file__)
SELF_TEST = os.path.join(os.path.dirname(SELF), "test_check_pip_geometry.py")

ROW_RE = re.compile(
    MARK + r"\s+(?P<dev>[A-Za-z0-9_.-]+)\s+w=(?P<w>\d+)\s+ct=(?P<ct>\d+)\s+"
    r"rr=(?P<rr>\d+)\s+gap_today=(?P<gt>-?[\d.]+)\s+gap_after=(?P<ga>-?[\d.]+)\s+"
    r"edge_today=(?P<et>-?[\d.]+)\s+edge_after=(?P<ea>-?[\d.]+)")

RANGE_RE = re.compile(
    MARK + r"-RANGE\s+gap_today=(?P<gt0>-?[\d.]+)-(?P<gt1>-?[\d.]+)\s+"
    r"gap_after=(?P<ga0>-?[\d.]+)-(?P<ga1>-?[\d.]+)\s+"
    r"edge_today=(?P<et0>-?[\d.]+)-(?P<et1>-?[\d.]+)\s+"
    r"edge_after=(?P<ea0>-?[\d.]+)-(?P<ea1>-?[\d.]+)")

BASE_RE = re.compile(MARK + r"-BASE\s+ct_today=(?P<f>[\d.]+)")

# The pre-#141 claims, one line per device, and the paragraph's counts ABOUT
# them. Both halves are needed: the claims alone are unfalsifiable history, and
# the counts alone would be a second copy of prose.
CLAIMED_RE = re.compile(
    MARK + r"-CLAIMED\s+(?P<dev>[A-Za-z0-9_.-]+)\s+"
    r"gap_today=(?P<gt>-?[\d.]+)\s+gap_after=(?P<ga>-?[\d.]+)")

DISAGREE_RE = re.compile(
    MARK + r"-DISAGREE\s+half_px=(?P<half>\d+)\s+tight=(?P<tight>\d+)\s+"
    r"today_dupes=(?P<td>\d+)\s+after_dupes=(?P<ad>\d+)")

# The tolerance the OLD one-decimal table was written to. #141's own "four of
# six" is the count at this precision; the count at TOL is five. Both are
# derived below rather than asserted, because the paragraph states both.
HALF_PX = 0.5

CONSTS = ["PIP_ROW_Y_FRAC", "PIP_CT_W_FRAC", "PIP_DOT_R_FRAC", "PIP_DOT_R_MIN",
          "PIP_GAP_FRAC", "PIP_GAP_MIN"]

# The five shipped expressions this checker mirrors, normalised: comments
# stripped, runs of whitespace collapsed. Editing a formula changes its
# normalised body and fails the check by name.
PINNED_BODIES = {
    "pipChordXMax": (
        "var r = (w < h) ? w / 2.0 : h / 2.0; var dy = h / 2.0 - yTop; "
        "if (dy < 0) { dy = -dy; } if (dy >= r) { return w / 2.0; } "
        "return w / 2.0 + Math.sqrt(r * r - dy * dy);"),
    "pipDotR": (
        "var r = (w * $.PIP_DOT_R_FRAC).toNumber(); "
        "return (r < $.PIP_DOT_R_MIN) ? $.PIP_DOT_R_MIN : r;"),
    "pipGap": (
        "var g = (w * $.PIP_GAP_FRAC).toNumber(); "
        "return (g < $.PIP_GAP_MIN) ? $.PIP_GAP_MIN : g;"),
    "pipDotCx": (
        "return pipChordXMax(w, h, $.PIP_ROW_Y_FRAC * h) - 1 - pipDotR(w);"),
    "pipCtCx": (
        "return pipDotCx(w, h) - pipDotR(w) - pipGap(w) - "
        "(w * $.PIP_CT_W_FRAC) / 2.0;"),
}


def read_source(root):
    path = os.path.join(root, "source", "StrongRowView.mc")
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read(), path


def parse_consts(text, path, problems):
    out = {}
    for name in CONSTS:
        m = re.search(r"^const\s+%s\s*=\s*([\d.]+)\s*;" % name, text, re.M)
        if not m:
            problems.append(
                "%s declares no `const %s` -- this check derives the table from "
                "the shipped constants and refuses to invent one." % (path, name))
            continue
        out[name] = float(m.group(1))
    return out


def parse_rr_x(text, path, problems):
    """The RR pip's x fraction and the row's y fraction, from drawGps itself."""
    m = re.search(r'dc\.drawText\(w \* ([\d.]+), h \* ([\d.]+), '
                  r'Gfx\.FONT_XTINY, "RR"', text)
    if not m:
        problems.append(
            "%s: could not find the RR pip's drawText call. Every gap figure in "
            "the table is measured to that pip, so this check will not guess at "
            "its position." % path)
        return None, None
    return float(m.group(1)), float(m.group(2))


def parse_ct_x(text, path, problems):
    """The CT label's OWN drawText call.

    Separate from the body pin on purpose. `check_bodies` proves pipCtCx still
    computes what this checker mirrors; it proves nothing about whether drawGps
    calls it. With the body untouched and this one call changed to `w * 0.60`,
    every gap_after and edge_after figure and the whole -RANGE line are false
    while the check prints six agreeing rows -- and on the 454 px devices the
    real gap under that mutant is negative, i.e. the two labels overlap. Both
    coordinates are pinned, because the y was unguarded for the same reason.
    """
    m = re.search(r'dc\.drawText\(\s*pipCtCx\(w, h\)\s*,\s*'
                  r'h \* \$\.PIP_ROW_Y_FRAC\s*,\s*Gfx\.FONT_XTINY,\s*"CT"',
                  text)
    if not m:
        problems.append(
            '%s: the "CT" label is not drawn at pipCtCx(w, h), '
            "h * PIP_ROW_Y_FRAC. Every `after` figure in the table is DEFINED "
            "as that label centred there, so a table derived from pipCtCx says "
            "nothing once the call site stops using it. Re-derive the table "
            "against wherever the label now sits, or restore the call." % path)


def check_claims(text, path, derived, problems):
    """The counts the prose makes about the pre-#141 claimed column.

    Derives, from the -CLAIMED rows and this checker's own derivation:
      * how many rows disagree at half a pixel, and how many at TOL;
      * how many rows share a claimed gap_today (or gap_after) with another
        row -- a repeat the derivation forbids, since gap_today is strictly
        increasing in w at a fixed ct and no two rows share both.
    and compares all four against the -DISAGREE line.
    """
    claims = list(CLAIMED_RE.finditer(text))
    md = DISAGREE_RE.search(text)
    if not claims and not md:
        return                      # the block carries no claims paragraph
    if not claims:
        problems.append(
            "%s carries a %s-DISAGREE line and no %s-CLAIMED rows. The counts "
            "are derived FROM those rows; with none present the line asserts "
            "something nothing can check." % (path, MARK, MARK))
        return
    if not md:
        problems.append(
            "%s carries %d %s-CLAIMED row(s) and no %s-DISAGREE line. The "
            "paragraph beside them states how many disagree and how many "
            "repeat; unchecked, those are the same kind of asserted figure "
            "#141 was opened for." % (path, len(claims), MARK, MARK))
        return

    half = tight = 0
    gts, gas = [], []
    for m in claims:
        dev = m.group("dev")
        if dev not in derived:
            problems.append(
                "%s-CLAIMED %s has no %s row to be compared against -- a claim "
                "about a device this table does not derive cannot be checked."
                % (MARK, dev, MARK))
            continue
        gt, ga = float(m.group("gt")), float(m.group("ga"))
        gts.append(gt)
        gas.append(ga)
        d = derived[dev]
        worst = max(abs(gt - d["gap_today"]), abs(ga - d["gap_after"]))
        if worst > HALF_PX:
            half += 1
        if worst > TOL:
            tight += 1

    def dupes(vals):
        return sum(1 for v in vals if vals.count(v) > 1)

    got = (half, tight, dupes(gts), dupes(gas))
    want = (int(md.group("half")), int(md.group("tight")),
            int(md.group("td")), int(md.group("ad")))
    names = ("half_px", "tight", "today_dupes", "after_dupes")
    for i in range(4):
        if got[i] != want[i]:
            problems.append(
                "%s-DISAGREE says %s=%d; the %s-CLAIMED rows against this "
                "check's own derivation give %d"
                % (MARK, names[i], want[i], MARK, got[i]))


def normalise_body(body):
    body = re.sub(r"//[^\n]*", " ", body)
    return re.sub(r"\s+", " ", body).strip()


def check_bodies(text, path, problems):
    for name, want in PINNED_BODIES.items():
        m = re.search(r"static function %s\([^)]*\)\s*\{(.*?)\n    \}"
                      % name, text, re.S)
        if not m:
            problems.append(
                "%s: no `static function %s` found. This check mirrors that "
                "formula in Python; it cannot verify a mirror of something that "
                "is not there." % (path, name))
            continue
        got = normalise_body(m.group(1))
        if got != want:
            problems.append(
                "%s: the body of %s has changed, so the Python mirror this "
                "check derives the table with may no longer match it.\n"
                "    shipped: %s\n    mirrored: %s\n"
                "  Re-derive the table, then update PINNED_BODIES in this file "
                "in the same commit." % (path, name, got, want))


def derive(w, ct, rr, consts, rr_x, ct_today):
    """The five shipped formulas, mirrored. h == w on every manifest device --
    all nineteen report SCREEN_SHAPE_ROUND with w == h, which is the measured
    premise pipChordXMax's own comment records (re-measured device by device
    when the seven fenix 9 products were added, not extrapolated)."""
    h = w
    r = min(w, h) / 2.0
    y_top = consts["PIP_ROW_Y_FRAC"] * h
    dy = abs(h / 2.0 - y_top)
    chord = w / 2.0 if dy >= r else w / 2.0 + math.sqrt(r * r - dy * dy)
    dot_r = max(int(consts["PIP_DOT_R_MIN"]),
                int(w * consts["PIP_DOT_R_FRAC"]))
    gap = max(int(consts["PIP_GAP_MIN"]), int(w * consts["PIP_GAP_FRAC"]))
    dot_cx = chord - 1 - dot_r
    ct_cx = dot_cx - dot_r - gap - (w * consts["PIP_CT_W_FRAC"]) / 2.0
    rr_right = rr_x * w + rr / 2.0
    return {
        "gap_today": (ct_today * w - ct / 2.0) - rr_right,
        "gap_after": (ct_cx - ct / 2.0) - rr_right,
        "edge_today": chord - (ct_today * w + ct / 2.0),
        "edge_after": chord - (ct_cx + ct / 2.0),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    args = ap.parse_args()

    problems = []
    text, path = read_source(args.root)
    consts = parse_consts(text, path, problems)
    rr_x, row_y = parse_rr_x(text, path, problems)
    parse_ct_x(text, path, problems)
    check_bodies(text, path, problems)

    if problems:
        return report(problems)

    if abs(row_y - consts["PIP_ROW_Y_FRAC"]) > 1e-9:
        problems.append(
            "the RR pip is drawn at h * %s but PIP_ROW_Y_FRAC is %s -- the "
            "chord limit every figure in the table is measured to is taken at "
            "PIP_ROW_Y_FRAC, so the two rows must be the same row."
            % (row_y, consts["PIP_ROW_Y_FRAC"]))

    mb = BASE_RE.search(text)
    if not mb:
        problems.append(
            "%s carries no %s-BASE line. The 'today' column is the PRE-#80 "
            "layout, whose CT position is no longer in the code at all, so it "
            "has to be declared to be checkable." % (path, MARK))
        return report(problems)
    ct_today = float(mb.group("f"))

    rows = list(ROW_RE.finditer(text))
    if not rows:
        problems.append(
            "no %s row found under %r. This check is only worth its runtime "
            "while the table carries the marker; an empty scan means the rows "
            "were deleted or the marker renamed, either of which silently "
            "disables it." % (MARK, args.root))
        return report(problems)

    derived = {}
    for m in rows:
        dev = m.group("dev")
        w, ct, rr = int(m.group("w")), int(m.group("ct")), int(m.group("rr"))
        d = derive(w, ct, rr, consts, rr_x, ct_today)
        derived[dev] = d
        claimed = {"gap_today": float(m.group("gt")),
                   "gap_after": float(m.group("ga")),
                   "edge_today": float(m.group("et")),
                   "edge_after": float(m.group("ea"))}
        for key in sorted(claimed):
            if abs(claimed[key] - d[key]) > TOL:
                problems.append(
                    "%s %s: the table says %s = %.2f px, the shipped constants "
                    "and formulas give %.2f px (w=%d, ct=%d, rr=%d)"
                    % (MARK, dev, key, claimed[key], d[key], w, ct, rr))

    check_claims(text, path, derived, problems)

    mr = RANGE_RE.search(text)
    if not mr:
        problems.append(
            "%s carries no %s-RANGE line. The in-line summary in drawGps quotes "
            "ranges from the table, and an unchecked summary is exactly the "
            "half of #141 that was wrong in both of its bounds." % (path, MARK))
    else:
        for key, lo_g, hi_g in (("gap_today", "gt0", "gt1"),
                                ("gap_after", "ga0", "ga1"),
                                ("edge_today", "et0", "et1"),
                                ("edge_after", "ea0", "ea1")):
            lo = min(d[key] for d in derived.values())
            hi = max(d[key] for d in derived.values())
            if abs(float(mr.group(lo_g)) - lo) > TOL or \
               abs(float(mr.group(hi_g)) - hi) > TOL:
                problems.append(
                    "%s-RANGE says %s = %s-%s px; the rows give %.2f-%.2f px"
                    % (MARK, key, mr.group(lo_g), mr.group(hi_g), lo, hi))

    if not problems:
        print("OK: %d %s row(s) and the summary range agree with the "
              "derivation from the shipped constants." % (len(rows), MARK))
        claimed = {m.group("dev"): (float(m.group("gt")), float(m.group("ga")))
                   for m in CLAIMED_RE.finditer(text)}
        for m in rows:
            dev = m.group("dev")
            d = derived[dev]
            # Claimed beside derived, so the two live in ONE place and a reader
            # never has to hold a second table in their head to compare them.
            c = claimed.get(dev)
            was = ("  (claimed %5.2f / %5.2f)" % c) if c else ""
            print("  %-20s w=%-4s gap %6.2f -> %6.2f   edge %6.2f -> %6.2f%s"
                  % (dev, m.group("w"), d["gap_today"],
                     d["gap_after"], d["edge_today"], d["edge_after"], was))
        return 0
    return report(problems)


def report(problems):
    print("FAIL: %d problem(s) in the %s tables." % (len(problems), MARK))
    for p in problems:
        print("  - %s" % p)
    return 1


if __name__ == "__main__":
    sys.exit(main())
