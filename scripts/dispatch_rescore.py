#!/usr/bin/env python3
"""Re-derive every published figure in docs/agents/DISPATCH.md section 6.

The band metric in DISPATCH.md was re-anchored on the R, P and I axes. The
claim that the re-anchoring WORKS is a distribution claim, and a distribution
claim asserted in prose is the defect class this repository keeps re-learning
("a number nothing committed can regenerate" -- FACTS.md section 6, and the two
harnesses that exist because it shipped twice: scripts/cue_replay.py and
scripts/speed_witness.py).

So the histogram is not written into DISPATCH.md and left there. It is derived
here, from a committed worksheet of real issues, and DISPATCH.md carries
DISPATCHCAL marker lines that this script requires to match what it computes.
Edit one without the other and the required test-tooling job reds.

Three guards beyond the arithmetic, because the arithmetic closing is not what
was in doubt:

  1. V and S must be IDENTICAL before and after. This branch re-anchored R, P
     and I; holding the other two is what isolates the effect. A worksheet that
     quietly moved V would make the histogram unattributable.

  2. NO-OP GUARD. The previous proposal for this metric was "make R a gate and
     drop every cut-point by 2" -- a pure translation, which cannot move a
     single issue across a band. Any change of that shape produces a CONSTANT
     per-issue delta. If every issue moved by the same amount, this fails.

  3. ZERO-VARIANCE GUARD. R scored 2 on 89 of 89 headed issues under the old
     anchors: an axis with one value contributes a constant and measures
     nothing. If R, P or I takes only one value across the worksheet, this
     fails, whatever the histogram looks like.

Pure Python. No container, no SDK, no network.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_SHEET = os.path.join(HERE, "fixtures", "dispatch_rescore_9b2801c.tsv")
DEFAULT_DOC = os.path.join(ROOT, "docs", "agents", "DISPATCH.md")

# The band table, DISPATCH.md section 2. Upper bound of each band, inclusive.
BANDS = [(3, "Trivial"), (6, "Routine"), (9, "Standard"), (12, "Heavy"), (15, "Critical")]
BAND_ORDER = [name for _, name in BANDS]

HEADER_RE = re.compile(r"\(R(\d) V(\d) S(\d) P(\d) I(\d) = (\d+)\)")
BAND_WORD_RE = re.compile(r"band=(\w+)")
CAL_RE = re.compile(r"^\s*DISPATCHCAL .*$", re.M)


def band_of(total):
    for hi, name in BANDS:
        if total <= hi:
            return name
    raise ValueError("total %d is outside 0-15" % total)


def agents(band, r, p):
    """Agents dispatched, from DISPATCH.md section 2.

    Trivial is the orchestrator inline: zero dispatched agents. Routine is one
    implementer, plus one review lens when the P>=2-or-R>=2 guardrail strikes
    "no gate". Standard is implementer + reviewer. Heavy is implementer +
    3-lens gate + consolidator. Critical is implementer + 4-5 lenses +
    consolidator; the LOW end (4 lenses) is used, so this figure is a floor for
    Critical and exact everywhere else.
    """
    if band == "Trivial":
        return 0
    if band == "Routine":
        return 2 if (p >= 2 or r >= 2) else 1
    if band == "Standard":
        return 2
    if band == "Heavy":
        return 5
    if band == "Critical":
        return 6
    raise ValueError(band)


def median(xs):
    s = sorted(xs)
    n = len(s)
    if n == 0:
        raise ValueError("no rows")
    if n % 2:
        return float(s[n // 2])
    return (s[n // 2 - 1] + s[n // 2]) / 2.0


def fmt(x):
    """Render a median as an integer when it is one, else to 2 dp."""
    return str(int(x)) if float(x).is_integer() else "%.2f" % x


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def load(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 11:
                fail("%s:%d has %d tab-separated columns, expected 11"
                     % (path, lineno, len(cols)))
            num, stratum, header = cols[0], cols[1], cols[2]
            m = HEADER_RE.search(header)
            if m is None:
                fail("%s:%d header column carries no (R# V# S# P# I# = n) group: %r"
                     % (path, lineno, header))
            before = [int(m.group(i)) for i in range(1, 6)]
            declared = int(m.group(6))
            if sum(before) != declared:
                fail("#%s header arithmetic does not close: %s sums to %d, not %d"
                     % (num, before, sum(before), declared))
            bw = BAND_WORD_RE.search(header)
            if bw is None:
                fail("#%s header carries no band= word" % num)
            if bw.group(1) != band_of(declared):
                fail("#%s header says band=%s but %d is %s"
                     % (num, bw.group(1), declared, band_of(declared)))
            try:
                after = [int(c) for c in cols[3:8]]
            except ValueError:
                fail("%s:%d after-scores are not integers: %r" % (path, lineno, cols[3:8]))
            for v in before + after:
                if not 0 <= v <= 3:
                    fail("#%s carries an axis score outside 0-3" % num)
            if before[1] != after[1] or before[2] != after[2]:
                fail("#%s moved V or S. This worksheet re-anchors R, P and I only; "
                     "holding V and S is what makes the histogram attributable." % num)
            for i, why in enumerate(cols[8:11]):
                if not why.strip():
                    fail("#%s leaves the %s reason blank" % (num, "RPI"[i]))
            rows.append({"n": num, "stratum": stratum, "before": before, "after": after})
    if not rows:
        fail("%s carries no rows" % path)
    return rows


def derive(rows):
    out = []
    hb = dict((b, 0) for b in BAND_ORDER)
    ha = dict((b, 0) for b in BAND_ORDER)
    ab, aa, deltas, rpib, rpia = [], [], set(), [], []
    for r in rows:
        tb, ta = sum(r["before"]), sum(r["after"])
        bb, ba = band_of(tb), band_of(ta)
        hb[bb] += 1
        ha[ba] += 1
        ab.append(agents(bb, r["before"][0], r["before"][3]))
        aa.append(agents(ba, r["after"][0], r["after"][3]))
        deltas.add(tb - ta)
        rpib.append(r["before"][0] + r["before"][3] + r["before"][4])
        rpia.append(r["after"][0] + r["after"][3] + r["after"][4])

    if len(deltas) == 1:
        fail("every issue moved by exactly %d points. A uniform shift is a rescale, "
             "not a re-anchoring: it cannot move an issue across a band unless the "
             "cut-points move too, and then it cannot move one at all." % deltas.pop())

    for i, axis in ((0, "R"), (3, "P"), (4, "I")):
        seen = set(r["after"][i] for r in rows)
        if len(seen) == 1:
            fail("axis %s takes the single value %d across the whole worksheet. An axis "
                 "with no variance is a constant added to every score, which is what the "
                 "old R cell was (2 on 89 of 89)." % (axis, seen.pop()))

    out.append("DISPATCHCAL sample %d" % len(rows))
    out.append("DISPATCHCAL before " + " ".join("%s %d" % (b, hb[b]) for b in BAND_ORDER))
    out.append("DISPATCHCAL after " + " ".join("%s %d" % (b, ha[b]) for b in BAND_ORDER))
    out.append("DISPATCHCAL agents before median %s mean %.2f"
               % (fmt(median(ab)), sum(ab) / float(len(ab))))
    out.append("DISPATCHCAL agents after median %s mean %.2f"
               % (fmt(median(aa)), sum(aa) / float(len(aa))))
    out.append("DISPATCHCAL rpi before mean %.2f" % (sum(rpib) / float(len(rpib))))
    out.append("DISPATCHCAL rpi after mean %.2f" % (sum(rpia) / float(len(rpia))))
    return out


def main(argv):
    sheet = argv[1] if len(argv) > 1 else DEFAULT_SHEET
    doc = argv[2] if len(argv) > 2 else DEFAULT_DOC
    rows = load(sheet)
    derived = derive(rows)

    if not os.path.exists(doc):
        fail("%s is absent; the DISPATCHCAL markers cannot be cross-checked" % doc)
    with open(doc, encoding="utf-8") as fh:
        text = fh.read()
    published = [m.group(0).strip() for m in CAL_RE.finditer(text)]

    if not published:
        fail("%s carries no DISPATCHCAL marker lines. The figures in section 6 must be "
             "the ones this script derives, or they are prose nothing can regenerate."
             % doc)

    if published != derived:
        print("The DISPATCHCAL markers in %s disagree with the worksheet." % doc)
        print("  derived from %s:" % os.path.basename(sheet))
        for line in derived:
            print("    " + line)
        print("  published in DISPATCH.md:")
        for line in published:
            print("    " + line)
        fail("re-run this script and paste its output into DISPATCH.md section 6")

    print("OK: %d re-scored issues; DISPATCH.md's %d DISPATCHCAL lines match the worksheet."
          % (len(rows), len(derived)))
    for line in derived:
        print("  " + line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
