#!/usr/bin/env python3
"""Runner-free RED/GREEN suite for scripts/dispatch_rescore.py.

Hermetic: every case but the first builds its own worksheet and its own
DISPATCH.md in a scratch directory. The first case runs the shipping pair,
because a harness that only ever sees synthetic input proves nothing about the
artifact it guards.

Fixture files are written with newline="" and explicit "\\n" so the suite is
byte-faithful on Windows too. That is #65 and #120's defect, and re-committing
it in a new harness would be the "near neighbour" class from FACTS.md section 6.
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRIPT = os.path.join(HERE, "dispatch_rescore.py")
REAL_SHEET = os.path.join(HERE, "fixtures", "dispatch_rescore_9b2801c.tsv")
REAL_DOC = os.path.join(ROOT, "docs", "agents", "DISPATCH.md")

CASES = []
FAILURES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


def run(sheet, doc):
    p = subprocess.run([sys.executable, SCRIPT, sheet, doc],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)


def row(num, hdr_scores, after, why="r\tp\ti", stratum="synthetic"):
    """One worksheet row. hdr_scores and after are 5-tuples R V S P I."""
    total = sum(hdr_scores)
    band = ["Trivial"] * 4 + ["Routine"] * 3 + ["Standard"] * 3 + ["Heavy"] * 3 + ["Critical"] * 3
    hdr = ("Dispatch: band=%s (R%d V%d S%d P%d I%d = %d) | implementer=large/high"
           % ((band[total],) + tuple(hdr_scores) + (total,)))
    return "\t".join([str(num), stratum, hdr] + [str(x) for x in after] + why.split("\t"))


# A minimal worksheet that PASSES every guard: R, P and I each take two values,
# and the per-issue delta is not constant.
BASE_ROWS = [
    row(1, (2, 1, 1, 2, 2), (1, 1, 1, 1, 0)),   # 8 Standard -> 4 Routine, delta 4
    row(2, (2, 3, 3, 2, 2), (2, 3, 3, 2, 2)),   # 12 Heavy   -> 12 Heavy,  delta 0
    row(3, (2, 1, 2, 2, 3), (1, 1, 2, 3, 3)),   # 10 Heavy   -> 10 Heavy,  delta 0... see below
]


def sheet_text(rows):
    return "# synthetic worksheet\n" + "\n".join(rows) + "\n"


def doc_text(cal_lines):
    return ("# doc\n\nsome prose\n\n" +
            "".join("    " + line + "\n" for line in cal_lines) + "\nmore prose\n")


def derived_for(tmp, rows):
    """Run the script with a doc that has no markers, to harvest what it derives."""
    sheet = os.path.join(tmp, "w.tsv")
    doc = os.path.join(tmp, "d.md")
    write(sheet, sheet_text(rows))
    write(doc, doc_text([]))
    rc, out = run(sheet, doc)
    assert rc == 1, out
    # Re-run with a deliberately wrong marker so the script prints its derivation.
    write(doc, doc_text(["DISPATCHCAL sample 999"]))
    rc, out = run(sheet, doc)
    assert rc == 1, out
    lines = []
    seen_derived = False
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("derived from"):
            seen_derived = True
            continue
        if s.startswith("published in"):
            break
        if seen_derived and s.startswith("DISPATCHCAL"):
            lines.append(s)
    assert lines, out
    return lines


def green(tmp, rows):
    """Build a passing sheet+doc pair for `rows` and return their paths."""
    cal = derived_for(tmp, rows)
    sheet = os.path.join(tmp, "w.tsv")
    doc = os.path.join(tmp, "d.md")
    write(sheet, sheet_text(rows))
    write(doc, doc_text(cal))
    return sheet, doc


# ---------------------------------------------------------------- cases


@case("the shipping worksheet and the shipping DISPATCH.md agree")
def _(tmp):
    rc, out = run(REAL_SHEET, REAL_DOC)
    return rc == 0 and "DISPATCHCAL sample" in out, out


@case("a synthetic worksheet that satisfies every guard passes")
def _(tmp):
    sheet, doc = green(tmp, BASE_ROWS)
    rc, out = run(sheet, doc)
    return rc == 0, out


@case("a row with the wrong column count is refused")
def _(tmp):
    sheet, doc = green(tmp, BASE_ROWS)
    write(sheet, sheet_text(BASE_ROWS) + "4\tsynthetic\tonly three columns\n")
    rc, out = run(sheet, doc)
    return rc == 1 and "expected 11" in out, out


@case("a header whose own arithmetic does not close is refused")
def _(tmp):
    sheet, doc = green(tmp, BASE_ROWS)
    bad = BASE_ROWS[0].replace("= 8)", "= 9)")
    write(sheet, sheet_text([bad] + BASE_ROWS[1:]))
    rc, out = run(sheet, doc)
    return rc == 1 and "header arithmetic does not close" in out, out


@case("a header whose band word disagrees with its sum is refused")
def _(tmp):
    sheet, doc = green(tmp, BASE_ROWS)
    bad = BASE_ROWS[0].replace("band=Standard", "band=Heavy")
    write(sheet, sheet_text([bad] + BASE_ROWS[1:]))
    rc, out = run(sheet, doc)
    return rc == 1 and "header says band=Heavy but 8 is Standard" in out, out


@case("a header carrying no score group is refused")
def _(tmp):
    sheet, doc = green(tmp, BASE_ROWS)
    bad = row(9, (2, 1, 1, 2, 2), (1, 1, 1, 1, 0)).replace("(R2 V1 S1 P2 I2 = 8)", "(no scores)")
    write(sheet, sheet_text(BASE_ROWS + [bad]))
    rc, out = run(sheet, doc)
    return rc == 1 and "carries no (R# V# S# P# I# = n) group" in out, out


@case("an after-score outside 0-3 is refused")
def _(tmp):
    sheet, doc = green(tmp, BASE_ROWS)
    bad = row(9, (2, 1, 1, 2, 2), (4, 1, 1, 1, 0))
    write(sheet, sheet_text(BASE_ROWS + [bad]))
    rc, out = run(sheet, doc)
    return rc == 1 and "outside 0-3" in out, out


@case("moving V between before and after is refused")
def _(tmp):
    sheet, doc = green(tmp, BASE_ROWS)
    bad = row(9, (2, 1, 1, 2, 2), (1, 0, 1, 1, 0))
    write(sheet, sheet_text(BASE_ROWS + [bad]))
    rc, out = run(sheet, doc)
    return rc == 1 and "moved V or S" in out, out


@case("moving S between before and after is refused")
def _(tmp):
    sheet, doc = green(tmp, BASE_ROWS)
    bad = row(9, (2, 1, 1, 2, 2), (1, 1, 3, 1, 0))
    write(sheet, sheet_text(BASE_ROWS + [bad]))
    rc, out = run(sheet, doc)
    return rc == 1 and "moved V or S" in out, out


@case("a blank per-axis reason is refused")
def _(tmp):
    sheet, doc = green(tmp, BASE_ROWS)
    bad = row(9, (2, 1, 1, 2, 2), (1, 1, 1, 1, 0), why="r\t \ti")
    write(sheet, sheet_text(BASE_ROWS + [bad]))
    rc, out = run(sheet, doc)
    return rc == 1 and "leaves the P reason blank" in out, out


@case("THE NO-OP: a uniform -2 shift on every issue is refused as a rescale")
def _(tmp):
    # Exactly the proposal DISPATCH.md section 6 rejects: drop R from every
    # score. Every delta becomes 2, so the guard must fire.
    rows = [row(1, (2, 1, 1, 2, 2), (0, 1, 1, 2, 2)),
            row(2, (2, 3, 3, 2, 2), (0, 3, 3, 2, 2)),
            row(3, (2, 1, 2, 2, 3), (0, 1, 2, 2, 3))]
    sheet = os.path.join(tmp, "w.tsv")
    doc = os.path.join(tmp, "d.md")
    write(sheet, sheet_text(rows))
    write(doc, doc_text(["DISPATCHCAL sample 3"]))
    rc, out = run(sheet, doc)
    return rc == 1 and "uniform shift is a rescale" in out, out


@case("a constant R across the worksheet is refused")
def _(tmp):
    rows = [row(1, (2, 1, 1, 2, 2), (1, 1, 1, 1, 0)),
            row(2, (2, 3, 3, 2, 2), (1, 3, 3, 2, 2)),
            row(3, (2, 1, 2, 2, 3), (1, 1, 2, 3, 3))]
    sheet = os.path.join(tmp, "w.tsv")
    doc = os.path.join(tmp, "d.md")
    write(sheet, sheet_text(rows))
    write(doc, doc_text(["DISPATCHCAL sample 3"]))
    rc, out = run(sheet, doc)
    return rc == 1 and "axis R takes the single value 1" in out, out


@case("a constant P across the worksheet is refused")
def _(tmp):
    rows = [row(1, (2, 1, 1, 2, 2), (1, 1, 1, 2, 0)),
            row(2, (2, 3, 3, 2, 2), (2, 3, 3, 2, 2)),
            row(3, (2, 1, 2, 2, 3), (1, 1, 2, 2, 3))]
    sheet = os.path.join(tmp, "w.tsv")
    doc = os.path.join(tmp, "d.md")
    write(sheet, sheet_text(rows))
    write(doc, doc_text(["DISPATCHCAL sample 3"]))
    rc, out = run(sheet, doc)
    return rc == 1 and "axis P takes the single value 2" in out, out


@case("a constant I across the worksheet is refused")
def _(tmp):
    rows = [row(1, (2, 1, 1, 2, 2), (1, 1, 1, 1, 2)),
            row(2, (2, 3, 3, 2, 2), (2, 3, 3, 2, 2)),
            row(3, (2, 1, 2, 2, 3), (1, 1, 2, 3, 2))]
    sheet = os.path.join(tmp, "w.tsv")
    doc = os.path.join(tmp, "d.md")
    write(sheet, sheet_text(rows))
    write(doc, doc_text(["DISPATCHCAL sample 3"]))
    rc, out = run(sheet, doc)
    return rc == 1 and "axis I takes the single value 2" in out, out


@case("an empty worksheet is refused")
def _(tmp):
    sheet, doc = green(tmp, BASE_ROWS)
    write(sheet, "# nothing but comments\n")
    rc, out = run(sheet, doc)
    return rc == 1 and "carries no rows" in out, out


@case("a missing doc is refused")
def _(tmp):
    sheet, doc = green(tmp, BASE_ROWS)
    os.remove(doc)
    rc, out = run(sheet, doc)
    return rc == 1 and "is absent" in out, out


@case("a doc with no DISPATCHCAL markers is refused")
def _(tmp):
    sheet, doc = green(tmp, BASE_ROWS)
    write(doc, doc_text([]))
    rc, out = run(sheet, doc)
    return rc == 1 and "carries no DISPATCHCAL marker lines" in out, out


@case("a doc whose markers disagree with the worksheet is refused, and both are printed")
def _(tmp):
    sheet, doc = green(tmp, BASE_ROWS)
    with open(doc, encoding="utf-8") as fh:
        text = fh.read()
    write(doc, text.replace("DISPATCHCAL sample 3", "DISPATCHCAL sample 4"))
    rc, out = run(sheet, doc)
    ok = (rc == 1 and "disagree with the worksheet" in out
          and "sample 4" in out and "sample 3" in out)
    return ok, out


@case("the P>=2 guardrail changes the Routine agent count, so the mean moves")
def _(tmp):
    # Two worksheets differing ONLY in P on the one Routine row. Under section 2
    # a Routine task with P>=2 carries a review lens (2 agents) and one with
    # P<=1 does not (1 agent). If the agent model ignored the guardrail these
    # two would derive the same mean.
    lo = [row(1, (2, 1, 1, 2, 2), (1, 1, 1, 1, 0)),
          row(2, (2, 3, 3, 2, 2), (2, 3, 3, 2, 2)),
          row(3, (2, 1, 2, 2, 3), (1, 1, 2, 3, 3))]
    hi = [row(1, (2, 1, 1, 2, 2), (1, 1, 1, 2, 0)),
          row(2, (2, 3, 3, 2, 2), (2, 3, 3, 2, 2)),
          row(3, (2, 1, 2, 2, 3), (1, 1, 2, 3, 3))]
    a = [x for x in derived_for(tmp, lo) if "agents after" in x]
    b = [x for x in derived_for(tmp, hi) if "agents after" in x]
    return a != b, "lo=%r hi=%r" % (a, b)


@case("a Critical row is counted at six agents, a Heavy row at five")
def _(tmp):
    heavy = [row(1, (2, 1, 1, 2, 2), (1, 1, 1, 1, 0)),
             row(2, (2, 3, 3, 2, 2), (2, 3, 3, 2, 2)),
             row(3, (2, 1, 2, 2, 3), (1, 1, 2, 3, 3))]
    crit = [row(1, (2, 1, 1, 2, 2), (1, 1, 1, 1, 0)),
            row(2, (2, 3, 3, 2, 2), (3, 3, 3, 3, 3)),
            row(3, (2, 1, 2, 2, 3), (1, 1, 2, 3, 3))]
    a = [x for x in derived_for(tmp, heavy) if "agents after" in x]
    b = [x for x in derived_for(tmp, crit) if "agents after" in x]
    # The three rows are Routine(1 agent) + the row under test + Heavy(5).
    # Heavy scores 5 and Critical 6, so the mean must rise by exactly 1/3.
    return a != b and "mean 3.67" in a[0] and "mean 4.00" in b[0], "heavy=%r crit=%r" % (a, b)


def main():
    passed = 0
    for name, fn in CASES:
        tmp = tempfile.mkdtemp(prefix="dispatch_rescore_test_")
        try:
            ok, detail = fn(tmp)
        except Exception as exc:  # a raising case is a failing case
            ok, detail = False, "%s: %s" % (type(exc).__name__, exc)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        if ok:
            passed += 1
        else:
            FAILURES.append(name)
            print("FAIL %s" % name)
            for line in str(detail).splitlines()[:12]:
                print("     | " + line)
    print("%d/%d dispatch-rescore self-tests passed." % (passed, len(CASES)))
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
