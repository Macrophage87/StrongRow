#!/usr/bin/env python3
"""Offline RED/GREEN tests for scripts/check_ciq_tests.py.

The parser carries ALL the correctness of the run-tests job, and it is pure
Python -- so unlike the simulator harness it can be proven on a stock runner
with no container, no SDK and no Xvfb.

WHAT THIS SUITE ASSERTS, AND WHY IT IS SHAPED THIS WAY
------------------------------------------------------
An earlier version of this file asserted only the checker's EXIT CODE. That is
too weak to be evidence: mutation-testing the parser against it showed most
guards could be deleted outright with the suite still fully green, because a
single malformed transcript trips several guards at once and any one of them is
enough to produce rc=1. A suite that cannot tell a correct parser from a
vacuous one is exactly the failure mode #44 was about.

So every case here declares the EXACT SET OF GUARDS it expects to fire, keyed
off the checker's own diagnostic lines (see GUARDS below). Consequences:

  * deleting any single guard changes some case's fired-set, so the suite goes
    red -- one guard per case wherever a transcript can isolate one;
  * a parser that raises instead of rendering a verdict also goes red, because
    a traceback produces no diagnostic lines to classify (rc=1 alone no longer
    satisfies anything);
  * over-firing is caught too: a guard that reddens a GREEN case shows up as an
    unexpected member of the set.

FIXTURE PROVENANCE
------------------
`scripts/fixtures/monkeydo-green-run.log` is the REAL monkeydo output of the
first green run of the run-tests job -- run 30127716562 on commit 5eb2187,
captured verbatim from the job log (the harness `cat`s monkeydo.log there, and
the same bytes are the `ciq-test-logs` artifact). It is the authoritative shape:
`Executing test X...` and `PASS` on SEPARATE lines, separated by 78-dash rules.

That matters because THREE shapes are in play, and only the real one is real:
issue #44's published transcript puts `Executing test X... PASS` on one line
column-aligned, and this file's synthetic `transcript()` builder puts it on one
line unpadded. #44's transcript is NOT committed anywhere, so no fixture here
should be described as verbatim #44 output. `transcript()` is a SYNTHETIC
builder, used because it can be perturbed one guard at a time; the real fixture
is what pins the parser to observed reality.

Run: python3 scripts/test_check_ciq_tests.py
"""

import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_ciq_tests.py")
EXPECTED = os.path.join(HERE, "expected_tests.txt")
REAL_GREEN_LOG = os.path.join(HERE, "fixtures", "monkeydo-green-run.log")

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

SUMMARY_OK = "PASSED (passed=17, failed=0, errors=0)"

# Guard id -> a predicate on one diagnostic line. Every diagnostic the checker
# can print must classify to exactly one id; an unclassified line fails the
# suite loudly rather than being silently ignored (that is how a renamed
# diagnostic gets noticed instead of quietly disabling a case's assertion).
GUARDS = [
    ("bad_pin",       lambda s: "could not be read" in s),
    ("empty_pin",     lambda s: "is empty -- a zero pin" in s),
    ("empty_log",     lambda s: s.startswith("monkeydo log ")),
    ("failed_veto",   lambda s: "'FAILED (passed=' line is present" in s),
    ("no_summary",    lambda s: s.startswith("no test-summary line")),
    ("multi_summary", lambda s: "summary lines; expected exactly one" in s),
    ("verdict",       lambda s: s.startswith("summary verdict is")),
    ("failed_count",  lambda s: s.startswith("failed=")),
    ("errors_count",  lambda s: s.startswith("errors=")),
    ("passed_count",  lambda s: s.startswith("passed=")),
    ("no_ran",        lambda s: s.startswith("no 'Ran N tests'")),
    ("ran_mismatch",  lambda s: s.startswith("'Ran ")),
    ("no_table",      lambda s: s.startswith("no RESULTS table")),
    ("missing",       lambda s: s.startswith("missing tests")),
    ("unexpected",    lambda s: s.startswith("unexpected tests")),
    ("not_pass",      lambda s: s.startswith("tests not PASS:")),
]


def classify(line):
    for gid, pred in GUARDS:
        if pred(line):
            return gid
    return None


def real_green_log():
    with open(REAL_GREEN_LOG, "r", encoding="utf-8") as fh:
        return fh.read()


def transcript(statuses=None, ran=None, summary=None, extra_rows=(),
               drop_rows=(), drop_header=False, noise=()):
    """SYNTHETIC monkeydo transcript, perturbable one guard at a time.

    Shape is the column-aligned RESULTS table the simulator really emits (see
    the real fixture); the `Executing test` preamble is condensed to one line
    per test, which the parser never reads because it scopes to the table.
    """
    if statuses is None:            # NOT `or`: {} means "a run with no tests"
        statuses = {n: "PASS" for n in NAMES}
    lines = []
    for n in NAMES:
        if n in statuses:
            lines.append("Executing test %s... %s" % (n, statuses[n]))
    lines.append("")
    lines.append("=" * 78)
    lines.append("RESULTS")
    if not drop_header:
        lines.append("%-37s %s" % ("Test:", "Status:"))
    for n in NAMES:
        if n in statuses and n not in drop_rows:
            lines.append("%-37s %s" % (n, statuses[n]))
    lines.extend(noise)
    lines.extend(extra_rows)
    n_ran = len(statuses) if ran is None else ran
    if n_ran is not None:
        lines.append("Ran %d tests" % n_ran)
    lines.append("")
    if summary is None:
        npass = sum(1 for s in statuses.values() if s == "PASS")
        nfail = sum(1 for s in statuses.values() if s == "FAIL")
        nerr = sum(1 for s in statuses.values() if s not in ("PASS", "FAIL"))
        verdict = "PASSED" if (nfail == 0 and nerr == 0) else "FAILED"
        summary = "%s (passed=%d, failed=%d, errors=%d)" % (verdict, npass, nfail, nerr)
    if summary != "":
        lines.append(summary)
    return "\n".join(lines) + "\n"


def run_checker(monkeydo_text, console_text="", expected_file=EXPECTED,
                harness_status=None):
    with tempfile.TemporaryDirectory() as td:
        mlog = os.path.join(td, "monkeydo.log")
        clog = os.path.join(td, "console.log")
        with open(mlog, "w", encoding="utf-8") as fh:
            fh.write(monkeydo_text)
        with open(clog, "w", encoding="utf-8") as fh:
            fh.write(console_text)
        extra = []
        if harness_status is not None:
            spath = os.path.join(td, "harness-status.txt")
            with open(spath, "w", encoding="utf-8") as fh:
                fh.write(harness_status)
            extra = ["--harness-status", spath]
        if expected_file == "<empty>":
            expected_file = os.path.join(td, "empty_pin.txt")
            with open(expected_file, "w", encoding="utf-8") as fh:
                fh.write("# no names at all\n")
        elif expected_file == "<missing>":
            expected_file = os.path.join(td, "does-not-exist.txt")
        proc = subprocess.run(
            [sys.executable, CHECKER, "--monkeydo-log", mlog,
             "--console-log", clog, "--expected-file", expected_file] + extra,
            capture_output=True, text=True)
        return proc.returncode, proc.stdout + proc.stderr


def fired_guards(out):
    """Classify the checker's `  - <diagnostic>` bullets into guard ids."""
    fired, unknown = set(), []
    for line in out.splitlines():
        m = re.match(r'^ {2}- (.*)$', line)
        if not m:
            continue
        gid = classify(m.group(1).strip())
        if gid is None:
            unknown.append(m.group(1).strip())
        else:
            fired.add(gid)
    return fired, unknown


CASES = []


def case(name, guards, mentions=(), forbids=()):
    """guards:   the EXACT set of guard ids this input must trip (empty = green).
    mentions: substrings the diagnostic output must contain (diagnostic quality,
              not just the return code).
    forbids:  substrings the diagnostic must NOT contain (wrong-cause guesses)."""
    def deco(fn):
        CASES.append((name, frozenset(guards), tuple(mentions), tuple(forbids), fn))
        return fn
    return deco


# ---------------------------------------------------------------- GREEN -----

@case("REAL first-green-run monkeydo.log passes", [], ["OK: 17/17"])
def _():
    return real_green_log()


@case("real log with CRLF line endings passes", [])
def _():
    return real_green_log().replace("\n", "\r\n")


@case("real log with a trailing blank-padded table passes", [])
def _():
    return real_green_log().replace("Ran 17 tests", "\nRan 17 tests")


@case("synthetic column-aligned transcript passes", [])
def _():
    return transcript()


@case("RESULTS table only in the console log still passes", [])
def _():
    # The summary must come from monkeydo; the table may be resolved across both.
    t = real_green_log()
    head, sep, tail = t.partition("=" * 78)
    return (head + SUMMARY_OK + "\n", sep + tail)


@case("table header in monkeydo but rows in console still passes", [])
def _():
    # Regression: the old fallback only fired when the header was ENTIRELY
    # absent, so a split table returned {} and reddened a green run.
    t = real_green_log()
    head, _sep, tail = t.partition("%-37s %s\n" % ("Test:", "Status:"))
    return (head + "%-37s %s\n" % ("Test:", "Status:") + SUMMARY_OK + "\n", tail)


@case("a non-row simulator notice inside the table does not red a green run", [])
def _():
    # Regression: `(\S+) (\S+)` read this as test `WARNING:` status `gc-pressure`.
    return transcript(noise=["WARNING: gc-pressure", "-- 3 warnings --"])


@case("ANSI-coloured status tokens do not red a green run", [])
def _():
    return real_green_log().replace("PASS", "\x1b[32mPASS\x1b[0m")


@case("simulator chatter BEFORE the table header is not read as a row", [])
def _():
    # Why the parse is scoped to the table at all: anything row-shaped that the
    # simulator prints on its way up would otherwise become a phantom test.
    return "SIMULATOR READY\nDEVICE FR965\n" + real_green_log()


@case("output AFTER the 'Ran N' tally is not read as a row", [])
def _():
    # Why the parse stops at the tally: trailing shutdown chatter is row-shaped.
    return real_green_log() + "SHUTDOWN OK\nSIMULATOR EXIT\n"


# ----------------------------------------------------- RED, one guard -------

@case("a SKIP row with a clean 17/17 summary is caught", ["not_pass"],
      ["test_rr_nullIvals=SKIP"])
def _():
    # The "executed but mis-tallied" case: the summary and the tally both still
    # claim a clean 17/17, and ONLY the per-test status disagrees. This is the
    # entire reason the not-PASS check exists, and nothing used to test it.
    st = {n: "PASS" for n in NAMES}
    st["test_rr_nullIvals"] = "SKIP"
    return transcript(st, ran=17, summary=SUMMARY_OK)


@case("a non-PASS ERROR row with a clean summary is caught", ["not_pass"],
      ["test_rr_emptyIvals=ERROR"])
def _():
    st = {n: "PASS" for n in NAMES}
    st["test_rr_emptyIvals"] = "ERROR"
    return transcript(st, ran=17, summary=SUMMARY_OK)


@case("a stray FAILED line in the CONSOLE log vetoes a green monkeydo run",
      ["failed_veto"])
def _():
    return (real_green_log(), "FAILED (passed=15, failed=2, errors=0)\n")


@case("the FAILED veto is whitespace-tolerant, not a literal substring",
      ["failed_veto"])
def _():
    # `FAILED  (passed=` with two spaces used to slip past the literal veto
    # even though SUMMARY_RE itself tolerates the extra space.
    return (real_green_log(), "FAILED  (passed=15, failed=2, errors=0)\n")


@case("missing summary line, everything else intact", ["no_summary"],
      ["Expected a line like"])
def _():
    return transcript(summary="")


@case("summary with leading text on the line is not accepted", ["no_summary"])
def _():
    return transcript(summary="sim: " + SUMMARY_OK)


@case("duplicate summary lines are refused as ambiguous", ["multi_summary"])
def _():
    return transcript() + SUMMARY_OK + "\n"


@case("summary reporting failed>0 is caught", ["failed_count"], ["failed=2"])
def _():
    return transcript(ran=17, summary="PASSED (passed=17, failed=2, errors=0)")


@case("summary reporting errors>0 is caught", ["errors_count"], ["errors=2"])
def _():
    return transcript(ran=17, summary="PASSED (passed=17, failed=0, errors=2)")


@case("summary passed count below the pin is caught", ["passed_count"],
      ["passed=16 but 17 tests are expected"])
def _():
    return transcript(ran=17, summary="PASSED (passed=16, failed=0, errors=0)")


@case("missing 'Ran N tests' line is caught", ["no_ran"])
def _():
    return transcript(ran=None, summary=SUMMARY_OK).replace("Ran 17 tests\n", "")


@case("'Ran N' disagreeing with the pin is caught", ["ran_mismatch"],
      ["'Ran 16 tests' but 17 are expected"])
def _():
    return transcript(ran=16, summary=SUMMARY_OK)


@case("missing RESULTS table header is caught", ["no_table"])
def _():
    return transcript(drop_header=True, ran=17, summary=SUMMARY_OK)


@case("a test in the pin but absent from the table is caught", ["missing"],
      ["test_rr_allInvalid"])
def _():
    return transcript(drop_rows=("test_rr_allInvalid",), ran=17, summary=SUMMARY_OK)


@case("a test in the table but not in the pin is caught", ["unexpected"],
      ["test_rr_brandNew"])
def _():
    return transcript(extra_rows=["%-37s %s" % ("test_rr_brandNew", "PASS")],
                      ran=17, summary=SUMMARY_OK)


@case("a renamed/substituted test is caught as both missing and extra",
      ["missing", "unexpected"],
      ["test_rr_boundaryInclusive", "test_rr_somethingElse"])
def _():
    return transcript(ran=17, summary=SUMMARY_OK).replace(
        "test_rr_boundaryInclusive", "test_rr_somethingElse  ")


@case("an empty pin file can never reach a pass", ["empty_pin"])
def _():
    # No rows either, so the name-set checks stay silent and the zero-pin guard
    # is the only thing standing between an empty pin and a green run.
    return (transcript(statuses={}, ran=0, summary="PASSED (passed=0, failed=0, errors=0)"),
            "", "<empty>")


@case("an unreadable pin file fails closed instead of tracebacking",
      ["bad_pin", "unexpected"], ["could not be read"])
def _():
    return (real_green_log(), "", "<missing>")


# --------------------------------------------- RED, deliberately compound ---

@case("empty monkeydo log (sim produced no output at all)",
      ["empty_log", "no_summary", "no_ran", "no_table"],
      ["hung and killed by timeout"])
def _():
    return ""


@case("a harness breadcrumb replaces the guessed cause, it does not add to it",
      ["empty_log", "no_summary", "no_ran", "no_table"],
      mentions=["harness_error=compile_failed:3", "aborted before"],
      forbids=["hung and killed by timeout", "crashed at launch"])
def _():
    # The pre-monkeydo abort paths. Guessing "hung / crashed at launch / never
    # started" here names three causes that are all wrong, because on this path
    # the simulator was never launched at all.
    return ("", "", EXPECTED, "harness_error=compile_failed:3\n")


@case("truncated mid-run", ["no_summary", "no_ran", "no_table"])
def _():
    return "\n".join(real_green_log().splitlines()[:8]) + "\n"


@case("FAILED glued onto the end of a PASSED line",
      ["no_summary", "failed_veto"])
def _():
    # SUMMARY_RE is anchored to end-of-line, so NEITHER summary matches and the
    # run cannot pass on the strength of the leading PASSED.
    return transcript(summary=SUMMARY_OK + " FAILED (passed=15, failed=2, errors=0)")


@case("a genuine two-test failure run",
      ["failed_veto", "verdict", "failed_count", "passed_count", "not_pass"],
      ["test_dsp_timeBaseInvariantToBatchSize=FAIL",
       "test_dsp_timeBaseIs25Hz=FAIL",
       "summary verdict is FAILED"])
def _():
    st = {n: "PASS" for n in NAMES}
    st["test_dsp_timeBaseInvariantToBatchSize"] = "FAIL"
    st["test_dsp_timeBaseIs25Hz"] = "FAIL"
    return transcript(st)


@case("fewer tests run than pinned",
      ["passed_count", "ran_mismatch", "missing"])
def _():
    return transcript({n: "PASS" for n in NAMES[:15]})


def main():
    failures = 0
    for name, want_guards, mentions, forbids, fn in CASES:
        produced = fn()
        if isinstance(produced, tuple):
            rc, out = run_checker(*produced)
        else:
            rc, out = run_checker(produced)

        got_guards, unknown = fired_guards(out)
        want_rc = 1 if want_guards else 0
        errs = []
        if rc != want_rc:
            errs.append("expected rc=%d got rc=%d" % (want_rc, rc))
        if got_guards != set(want_guards):
            errs.append("guards fired %s, expected %s"
                        % (sorted(got_guards) or "{}", sorted(want_guards) or "{}"))
        if unknown:
            errs.append("unclassified diagnostic(s) -- add them to GUARDS: %s" % unknown)
        for frag in mentions:
            if frag not in out:
                errs.append("diagnostic never mentions %r" % frag)
        for frag in forbids:
            if frag in out:
                errs.append("diagnostic wrongly claims %r" % frag)

        print("%-4s %s" % ("OK" if not errs else "FAIL", name))
        if errs:
            failures += 1
            for e in errs:
                print("      ! " + e)
            for line in out.splitlines():
                print("      | " + line)

    print("\n%d/%d parser self-tests passed." % (len(CASES) - failures, len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
