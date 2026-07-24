#!/usr/bin/env python3
"""Offline RED/GREEN tests for scripts/check_ciq_tests.py.

The parser carries ALL the correctness of the run-tests job, and it is pure
Python -- so unlike the simulator harness it can be proven on a stock runner
with no container, no SDK and no Xvfb. This is the half of the differential
that is available immediately.

Fixtures are the REAL transcripts published in issue #44 (a genuine 17/17 green
run and a genuine mutation-induced red run), plus the degenerate inputs a
fail-closed parser must reject.

Run: python3 scripts/test_check_ciq_tests.py
"""

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_ciq_tests.py")
EXPECTED = os.path.join(HERE, "expected_tests.txt")

NAMES = [
    "test_dsp_timeBaseInvariantToBatchSize",
    "test_dsp_timeBaseIs25Hz",
    "test_dsp_timeBaseSetAtInit",
    "test_rr_oneValid",
    "test_rr_twoValid",
    "test_rr_threeValid",
    "test_rr_exactlyFour",
    "test_rr_fiveDropsExtra",
    "test_rr_allInvalid",
    "test_rr_boundaryInclusive",
    "test_rr_interleavedPacksLow",
    "test_rr_nullIvals",
    "test_rr_emptyIvals",
    "test_rr_filterInRangeOnly",
    "test_rr_isFresh_states",
    "test_rr_freshConstUnchanged",
    "test_rr_gapExceeded_states",
]


def transcript(statuses=None, ran=None, summary=None):
    """Rebuild a monkeydo transcript in the exact shape issue #44 published:
    'Executing test X... PASS' lines, then a RESULTS table, then the tally."""
    statuses = statuses or {n: "PASS" for n in NAMES}
    lines = []
    for n in NAMES:
        if n in statuses:
            lines.append("Executing test %s... %s" % (n, statuses[n]))
    lines.append("")
    lines.append("=" * 78)
    lines.append("RESULTS")
    lines.append("Test:                                 Status:")
    for n in NAMES:
        if n in statuses:
            lines.append("%-37s %s" % (n, statuses[n]))
    n_ran = len(statuses) if ran is None else ran
    lines.append("Ran %d tests" % n_ran)
    lines.append("")
    if summary is None:
        npass = sum(1 for s in statuses.values() if s == "PASS")
        nfail = sum(1 for s in statuses.values() if s == "FAIL")
        nerr = sum(1 for s in statuses.values() if s not in ("PASS", "FAIL"))
        verdict = "PASSED" if (nfail == 0 and nerr == 0) else "FAILED"
        summary = "%s (passed=%d, failed=%d, errors=%d)" % (verdict, npass, nfail, nerr)
    lines.append(summary)
    return "\n".join(lines) + "\n"


def run_checker(monkeydo_text, console_text=""):
    with tempfile.TemporaryDirectory() as td:
        mlog = os.path.join(td, "monkeydo.log")
        clog = os.path.join(td, "console.log")
        with open(mlog, "w", encoding="utf-8") as fh:
            fh.write(monkeydo_text)
        with open(clog, "w", encoding="utf-8") as fh:
            fh.write(console_text)
        proc = subprocess.run(
            [sys.executable, CHECKER, "--monkeydo-log", mlog,
             "--console-log", clog, "--expected-file", EXPECTED],
            capture_output=True, text=True)
        return proc.returncode, proc.stdout + proc.stderr


CASES = []


def case(name, expect_rc):
    def deco(fn):
        CASES.append((name, expect_rc, fn))
        return fn
    return deco


# ---------------------------------------------------------------- GREEN -----

@case("real 17/17 green run passes", 0)
def _():
    return transcript()


@case("green run with CRLF line endings passes", 0)
def _():
    return transcript().replace("\n", "\r\n")


@case("RESULTS table only in console log still passes", 0)
def _():
    # Summary must be in monkeydo; the table may be resolved across both.
    t = transcript()
    head, sep, _tail = t.partition("=" * 78)
    summary = [l for l in t.splitlines() if l.startswith("PASSED")][0]
    return (head + summary + "\n", sep + _tail)


# ------------------------------------------------------------------ RED -----

@case("genuine mutation red run fails", 1)
def _():
    st = {n: "PASS" for n in NAMES}
    st["test_dsp_timeBaseInvariantToBatchSize"] = "FAIL"
    st["test_dsp_timeBaseIs25Hz"] = "FAIL"
    return transcript(st)


@case("empty log fails (sim never produced output)", 1)
def _():
    return ""


@case("truncated mid-run fails (no summary)", 1)
def _():
    return "\n".join(transcript().splitlines()[:8]) + "\n"


@case("missing summary but full table fails", 1)
def _():
    return "\n".join(l for l in transcript().splitlines()
                     if not l.startswith("PASSED")) + "\n"


@case("duplicate summary lines fail (ambiguous)", 1)
def _():
    t = transcript()
    return t + "PASSED (passed=17, failed=0, errors=0)\n"


@case("FAILED glued after PASSED on one line fails", 1)
def _():
    # The anchored tail is what stops a leading PASSED masking a trailing FAILED.
    t = transcript()
    return t.replace(
        "PASSED (passed=17, failed=0, errors=0)",
        "PASSED (passed=17, failed=0, errors=0) FAILED (passed=15, failed=2, errors=0)")


@case("summary with leading text on the line fails", 1)
def _():
    return transcript().replace("PASSED (passed=", "sim: PASSED (passed=")


@case("fewer tests run than pinned fails", 1)
def _():
    st = {n: "PASS" for n in NAMES[:15]}
    return transcript(st)


@case("a renamed/substituted test fails", 1)
def _():
    t = transcript()
    return t.replace("test_rr_boundaryInclusive", "test_rr_somethingElse")


@case("an extra unpinned test fails", 1)
def _():
    t = transcript()
    return t.replace("Ran 17 tests",
                     "test_rr_brandNew                      PASS\nRan 18 tests")


@case("non-PASS status token fails", 1)
def _():
    st = {n: "PASS" for n in NAMES}
    st["test_rr_nullIvals"] = "ERROR"
    return transcript(st)


@case("Ran count disagreeing with summary fails", 1)
def _():
    return transcript(ran=16)


@case("summary claiming errors fails", 1)
def _():
    return transcript(summary="PASSED (passed=17, failed=0, errors=2)")


def main():
    failures = 0
    for name, expect_rc, fn in CASES:
        produced = fn()
        if isinstance(produced, tuple):
            rc, out = run_checker(produced[0], produced[1])
        else:
            rc, out = run_checker(produced)
        ok = (rc == expect_rc)
        print("%-4s %s" % ("OK" if ok else "FAIL", name))
        if not ok:
            failures += 1
            print("      expected rc=%d got rc=%d" % (expect_rc, rc))
            for line in out.splitlines():
                print("      | " + line)
    print("\n%d/%d parser self-tests passed." % (len(CASES) - failures, len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
