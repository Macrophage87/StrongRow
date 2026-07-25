#!/usr/bin/env python3
"""Fail-closed verdict for a Connect IQ `monkeydo -t` unit-test run.

THIS SCRIPT IS THE SOLE VERDICT. monkeydo's exit code is deliberately ignored:
upstream's own harness documents it (matco/connectiq-tester tester.sh) --

    #monkeydo exit code is always 1 even when tests succeed!

-- and the simulator can also exit 0 on a broken run. Only the parsed output
decides, and anything ambiguous or missing is a FAILURE, never a pass.

To pass, ALL of the following must hold:
  * exactly one summary line, found in the monkeydo stream specifically;
  * that summary starts with PASSED (not FAILED -- the two are shape-identical);
  * no `FAILED (passed=` appears anywhere (standalone veto);
  * passed == the number of expected tests, failed == 0, errors == 0;
  * `Ran N tests` agrees with the expected count;
  * the RESULTS table lists EXACTLY the expected test names, every one `PASS`;
  * the expected list is non-empty.

Usage:
  check_ciq_tests.py --monkeydo-log FILE [--console-log FILE]
                     [--expected-file scripts/expected_tests.txt]
                     [--harness-status FILE]

Exit 0 = pass, 1 = fail (with reasons printed).
"""

import argparse
import os
import re
import sys

# Anchored to end-of-line so two summaries glued onto one physical line cannot
# hide a FAILED behind a leading PASSED. Never use a bare `$` here.
# [ \t]*, never \s*, in ALL THREE gaps: \s spans newlines, so
# `PASSED\n(passed=...` -- a summary broken across lines -- would otherwise be
# accepted as one. Same doctrine as FAILED_VETO_RE and RESULTS_HEADER_RE below.
SUMMARY_RE = re.compile(
    r'^(PASSED|FAILED)[ \t]*\(passed=(\d+),[ \t]*failed=(\d+),[ \t]*errors=(\d+)\)[ \t]*\r?$',
    re.M,
)
# The standalone veto. Whitespace-tolerant WITHIN a line on purpose: SUMMARY_RE
# already tolerates `FAILED  (passed=`, so a literal substring veto would be the
# weaker of the two. But [ \t]*, never \s* -- \s spans newlines, and prose that
# happens to end one line with FAILED and start the next with (passed= must not
# veto a green run (reproduced in review).
FAILED_VETO_RE = re.compile(r'FAILED[ \t]*\(passed=')
RAN_RE = re.compile(r'^Ran (\d+) tests?\b', re.M)
# The RESULTS table header, e.g. "Test:                    Status:".
# [ \t]+, never \s+: \s spans newlines, so a "Test:" line followed by a
# "Status:" line anywhere in the chatter formed a PHANTOM header earlier than
# the real one, after which arbitrary output became phantom rows.
RESULTS_HEADER_RE = re.compile(r'^Test:[ \t]+Status:[ \t]*\r?$', re.M)
# A row inside the RESULTS table: an identifier-shaped NAME and an ALL-CAPS
# status token, nothing else.
#
# Both halves are deliberately narrow. With the old `(\S+)[ \t]+(\S+)` shape any
# stray two-token line inside the table window became a fake row -- a simulator
# notice like `WARNING: gc-pressure` was read as test `WARNING:` with status
# `gc-pressure` and reddened an otherwise green run. Anchoring the name to an
# identifier and the status to `[A-Z][A-Z0-9_]*` rejects both halves of that.
#
# The status alphabet is NOT pinned to PASS|FAIL|ERROR: an undocumented token
# such as SKIP must still be captured so the "executed but mis-tallied" check
# below can call it out by name. Anything that is not exactly PASS is a failure.
# No \r? here, deliberately: rows are matched per-line after str.splitlines(),
# which consumes the \r\n boundary whole -- so unlike SUMMARY_RE and
# RESULTS_HEADER_RE (which run over the raw text under re.M and DO see the \r
# before each \n), a row line can never end in \r and the anchor would be dead
# code (proven: deleting it changed nothing while the other two anchors are
# each pinned by the CRLF case).
RESULTS_ROW_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)[ \t]+([A-Z][A-Z0-9_]*)[ \t]*$')
# Terminal colour, if the simulator ever emits it, must not turn `PASS` into an
# unparseable token (which would red a green run). Stripped on read.
ANSI_RE = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')


def read(path):
    """Read a log tolerantly -- a stray byte must not turn a required check
    into a traceback instead of a verdict."""
    if not path or not os.path.exists(path):
        return ""
    # newline="" so CRLF actually REACHES the regexes: with default universal
    # newlines Python translates \r\n -> \n before any pattern runs, which made
    # every \r?$ in this file dead code and its CRLF test vacuous.
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as fh:
        return ANSI_RE.sub("", fh.read())


def load_expected(path):
    """Return the pinned names, or None if the pin file cannot be read.

    None rather than a traceback: `read()` documents that a required check must
    always render a verdict, and a missing --expected-file is exactly the case
    where a traceback would replace the diagnostic with a stack dump.
    """
    names = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                # POSIX [[:space:]] exactly (" \t\r\n\v\f"), matching
                # check_expected_tests.sh's sed trim character-for-character.
                # Not a bare strip(): that also eats U+00A0 etc., which the
                # shell does not. All three pin readers (this, the shell, the
                # self-suite's _load_pin) must agree byte-for-byte, or a stray
                # VT/FF gives cross-check green while run-tests reports the
                # same name as both missing and unexpected.
                line = line.strip(" \t\r\n\v\f")
                if line and not line.startswith("#"):
                    names.append(line)
    except OSError:
        return None
    return names


def parse_results_table(text):
    """Return {name: status} from the RESULTS table only.

    None  = no table header anywhere (caller may retry a wider stream).
    {}    = header present but no rows under it.

    Why the parse is scoped to the block, corrected against the real transcript:
    an earlier note here claimed a whole-file scan double-counts every test
    (34 rows for a 17-test run) because each name recurs as
    `Executing test <name>... PASS`. Measured against the committed fixture that
    is FALSE -- the simulator puts `Executing test <name>...` and `PASS` on
    SEPARATE lines, and even #44's one-line variant carries four tokens, so no
    row regex matches either. A whole-file scan of the real log yields 18, not
    34: the 17 real rows plus the `Test: Status:` header itself.

    Scoping still earns its place, for the reasons actually observed: it drops
    that header row, and it confines the parse to a window so that row-shaped
    simulator chatter before the table (`SIMULATOR READY`) or after the tally
    (`SHUTDOWN OK`) cannot become a phantom test and red a green run. Both are
    covered by GREEN cases in the self-test suite.
    """
    header = RESULTS_HEADER_RE.search(text)
    if not header:
        return None
    rows = {}
    for line in text[header.end():].splitlines():
        if not line.strip():
            continue
        if RAN_RE.match(line) and rows:
            # End of table -- but only once at least one row has been seen.
            # An unconditional break re-created the split-table false red one
            # level down: parsing the COMBINED text anchored on monkeydo's
            # header stopped at monkeydo's own `Ran N tests` line before ever
            # reaching the console's rows, returning {} for a green run.
            break
        m = RESULTS_ROW_RE.match(line)
        if not m:
            continue
        name, status = m.group(1), m.group(2)
        if name == "Ran":               # defensive: never treat the tally as a row
            break
        if name in rows:
            # Two rows for one test is ambiguity, and ambiguity fails: with a
            # plain overwrite, `x FAIL` then `x PASS` resolved GREEN while the
            # reverse order red -- order-dependent, in the passing direction.
            # The composite is not PASS, so the not-PASS check fails it, and
            # it carries both original statuses so the diagnostic says what
            # the conflicting rows actually claimed.
            rows[name] = "DUPLICATE_ROW(%s,%s)" % (rows[name], status)
        else:
            rows[name] = status
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--monkeydo-log", required=True,
                    help="monkeydo stdout/stderr; the summary MUST come from here")
    ap.add_argument("--console-log", default=None,
                    help="simulator console; searched only as a fallback for the "
                         "RESULTS table and the `Ran N` tally")
    ap.add_argument("--expected-file", default=None,
                    help="one test name per line (default: scripts/expected_tests.txt)")
    ap.add_argument("--harness-status", default=None,
                    help="key=value file from run_ciq_tests.sh, folded into the report")
    args = ap.parse_args()

    expected_file = args.expected_file or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "expected_tests.txt")

    monkeydo = read(args.monkeydo_log)
    console = read(args.console_log)
    combined = monkeydo + "\n" + console

    problems = []

    # Harness breadcrumbs first: on a degraded path this is the only thing that
    # explains WHY there is no summary, so print it before any verdict.
    status = read(args.harness_status).strip()
    harness_error = ""
    if status:
        print("Harness status:")
        for line in status.splitlines():
            print("  " + line)
            key, _, val = line.partition("=")
            if key.strip() == "harness_error":
                harness_error = val.strip()
        print()

    expected = load_expected(expected_file)
    if expected is None:
        problems.append(
            "expected test list %r could not be read -- refusing to pass without a pin"
            % expected_file)
        expected = []
    elif len(expected) == 0:
        problems.append(
            "expected test list %r is empty -- a zero pin can never pass" % expected_file)
    n_expected = len(expected)

    if not monkeydo.strip():
        # Defer to the harness's own breadcrumb when there is one. Guessing
        # "hung / crashed at launch / never started" is actively misleading on a
        # path where the harness aborted before the simulator was ever started
        # (a failed compile, say) -- all three suggested causes would be wrong.
        if harness_error:
            problems.append(
                "monkeydo log %r is empty or missing: the harness aborted before "
                "monkeydo could run (harness_error=%s)"
                % (args.monkeydo_log, harness_error))
        else:
            problems.append(
                "monkeydo log %r is empty or missing: the simulator produced no output "
                "(hung and killed by timeout, crashed at launch, or never started)"
                % args.monkeydo_log)

    # --- Standalone veto -----------------------------------------------------
    if FAILED_VETO_RE.search(monkeydo) or FAILED_VETO_RE.search(console):
        problems.append("a 'FAILED (passed=' line is present -- tests failed")

    # --- Summary line --------------------------------------------------------
    summaries = SUMMARY_RE.findall(monkeydo)
    if len(summaries) == 0:
        problems.append(
            "no test-summary line in %s. Expected a line like "
            "'PASSED (passed=%d, failed=0, errors=0)'. Absence usually means the "
            "run never completed -- check harness status and the console log."
            % (args.monkeydo_log, n_expected))
    elif len(summaries) > 1:
        problems.append(
            "found %d summary lines; expected exactly one. Ambiguous (re-run or "
            "interleaved output), so refusing to pick one: %r"
            % (len(summaries), summaries))
    else:
        verdict, passed, failed, errors = summaries[0]
        passed, failed, errors = int(passed), int(failed), int(errors)
        if verdict != "PASSED":
            problems.append("summary verdict is %s, not PASSED" % verdict)
        if failed != 0:
            problems.append("failed=%d (expected 0)" % failed)
        if errors != 0:
            problems.append("errors=%d (expected 0)" % errors)
        if n_expected and passed != n_expected:
            problems.append(
                "passed=%d but %d tests are expected. If tests were added or removed, "
                "update %s in the same commit." % (passed, n_expected, expected_file))

    # --- `Ran N tests` -------------------------------------------------------
    # Arithmetically implied by the checks above, but it independently catches
    # tests that executed without being tallied into the summary.
    ran = RAN_RE.search(monkeydo) or RAN_RE.search(combined)
    if not ran:
        problems.append("no 'Ran N tests' line found in either log")
    elif n_expected and int(ran.group(1)) != n_expected:
        problems.append(
            "'Ran %s tests' but %d are expected (see %s)"
            % (ran.group(1), n_expected, expected_file))

    # --- Test-name set -------------------------------------------------------
    # The fallback past "header entirely absent": if the header lands in
    # monkeydo.log but the rows land in sim-console.log, the monkeydo-only parse
    # returns an EMPTY dict, not None. Two subtleties, each a reproduced false
    # red on a fully green run:
    #   * `not rows`, never `rows is None`: {} must also trigger the fallback;
    #   * EVERY header position in the combined text is tried, not just the
    #     first: anchoring on the first header parsed monkeydo's header-only
    #     window and returned {} again (see the break condition in
    #     parse_results_table), so the fallback existed without working.
    rows = parse_results_table(monkeydo)
    if not rows:
        for h in RESULTS_HEADER_RE.finditer(combined):
            alt = parse_results_table(combined[h.start():])
            if alt:
                rows = alt
                break
    if rows is None:
        problems.append("no RESULTS table found in either log")
    else:
        got = set(rows)
        want = set(expected)
        missing = sorted(want - got)
        unexpected = sorted(got - want)
        if missing:
            problems.append("missing tests (declared but not run): %s" % ", ".join(missing))
        if unexpected:
            problems.append(
                "unexpected tests (run but not in %s): %s"
                % (expected_file, ", ".join(unexpected)))
        # Any token that is not exactly PASS is a failure. The alphabet of
        # non-PASS tokens (ERROR? SKIP?) is not documented in any transcript we
        # have, so treat anything unrecognised as bad rather than guessing.
        not_pass = sorted("%s=%s" % (n, s) for n, s in rows.items() if s != "PASS")
        if not_pass:
            problems.append("tests not PASS: %s" % ", ".join(not_pass))

    # --- Verdict -------------------------------------------------------------
    if problems:
        print("FAIL: Connect IQ unit-test run did not pass cleanly.")
        for p in problems:
            print("  - %s" % p)
        print("\n(monkeydo's own exit code is ignored by design; it returns "
              "non-zero even on success.)")
        return 1

    print("OK: %d/%d tests passed, names match %s exactly."
          % (n_expected, n_expected, expected_file))
    return 0


if __name__ == "__main__":
    sys.exit(main())
