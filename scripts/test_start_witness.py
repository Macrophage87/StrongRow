#!/usr/bin/env python3
"""RED/GREEN tests for scripts/start_witness.py -- the START-baseline witness.

Same two jobs as scripts/test_cue_replay.py, for the other recording window.

1. THE TRANSCRIPTION IS PINNED AGAINST THE SHIPPING MONKEY C. start_witness.py
   rewrites StrongRowView.fastGate and gatedRate in Python, and a rewrite that
   drifts from its original proves nothing about the original. Every vector in
   section A is a vector source/LockGuardTest.mc ALREADY ASSERTS against the
   real Monkey C -- the same rates, the same floor, the same absolute ceiling.
   Change the rule on one side only and one of the two suites reds.

2. EVERY FIGURE D3 IS ARGUED FROM IS RE-DERIVED FROM THE COMMITTED FIXTURE.
   Section C asserts each number that appears in a source comment or in the pull
   request describing the START-baseline change. Before this file existed, none
   of them was regenerable from anything in the repository -- the one committed
   artefact from that recording, scripts/fixtures/cue_reversal_row.txt, carries
   row_stroke_rate for the WORK intervals only and structurally cannot show a
   pre-work second or a rate_base at all.

THE FIGURE THIS SUITE KILLED ON ITS FIRST RUN, recorded because the point of
building it was to find exactly this. A source comment claimed "that row's
rate_base never fell below 22.68 in its first work interval". C3 below measures
the minimum and it is 15.2863; 22.6813 is the baseline at the interval's FIRST
second. The conclusion drawn from it survived, but for a different reason, which
C4 pins.

Run: python3 scripts/test_start_witness.py
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import start_witness as W  # noqa: E402

CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


def fixture():
    return W.load()[2]


# ===========================================================================
# A. THE TRANSCRIPTION, against the vectors LockGuardTest.mc pins in Monkey C.
# ===========================================================================

@case("A1 the gate saturates at the absolute from 20.0 spm up "
      "(Lock.test_lock_c0_theGateSaturatesForAnyBaselineFromTwentyUp)")
def _():
    # The SAME five inputs the Monkey C case sweeps, and the same identity:
    # every one of them gives the absolute, and the absolute is what NO
    # baseline gives. LOCK_REL_K * 20.0 == FAST_NEEDS_LOCK exactly.
    got = [W.fast_gate(b) for b in (20.0, 22.68, 25.0, 29.57, 40.0)]
    return [got, W.fast_gate(0.0), W.fast_gate(None)], \
           [[30.0] * 5, 30.0, 30.0]


@case("A2 the floor binds below the knee, and the knee is where it says "
      "(Lock.test_lock_theGateHasAFloorAndKeepsTheAbsoluteCeiling)")
def _():
    # 8.0 is a rest paddle: 1.5 x 8.0 = 12.0, under the 20.0 floor.
    # 14.0 is just above the knee (20.0 / 1.5 = 13.33), so the rule is purely
    # relative again -- the floor is a floor and not a second regime.
    return ["%.4f" % W.fast_gate(8.0), "%.4f" % W.fast_gate(14.0),
            "%.4f" % (W.LOCK_GATE_FLOOR / W.LOCK_REL_K)], \
           ["20.0000", "21.0000", "13.3333"]


@case("A3 the absolute gate at its boundary, with no rate established "
      "(Lock.test_lock_c0_theAbsoluteGateIsThirtyWithNoRateEstablished)")
def _():
    # The Monkey C case's four vectors, verbatim. The comparison is STRICT
    # (`r > gate`), so a reading exactly at the gate passes.
    #
    # AN EXPECTATION OF MINE THAT WAS WRONG, kept as a note because the pairing
    # is the whole point of section A: I first wrote 45.0 as clamping to
    # MAX_RATE. It does not -- with no lock it is zeroed by the gate long before
    # the clamp, and the clamp is reachable only through the LOCK arm (A4). The
    # Monkey C case already said so; mirroring its vectors rather than inventing
    # my own is what caught it.
    got = [W.gated_rate(r, 0.0, 0.0) for r in (29.9, 30.0, 30.1, 45.0)]
    return got, [29.9, 30.0, 0.0, 0.0]


@case("A4 a locked reading snaps only when it disagrees, and the survivor is "
      "clamped (Lock.test_lock_c0_aLockedReadingSnapsOnlyWhenItDisagrees)")
def _():
    # A 3.0 s period is a 20.0 spm lock; LOCK_SNAP_K = 0.30 puts the snap
    # threshold at a 6.0 spm deviation, so 25.9 is inside it and 26.1 is not.
    # The same six vectors as the Monkey C case.
    got = [W.gated_rate(r, 3.0, 0.0)
           for r in (20.0, 25.9, 26.1, 14.1, 13.9, 38.0)]
    # And the MAX_RATE clamp, which only the lock arm can reach: a 45 spm lock
    # (period 60/45) agreeing with a 45 spm median is not snapped, and is then
    # clamped to 40.
    clamped = W.gated_rate(45.0, 60.0 / 45.0, 0.0)
    return [["%.4f" % v for v in got], "%.4f" % clamped], \
           [["20.0000", "25.9000", "20.0000", "14.1000", "20.0000", "20.0000"],
            "40.0000"]


# ===========================================================================
# B. THE FIXTURE. Shape, alignment and provenance, so a re-cut or corrupted
#    fixture is named as such instead of quietly moving every figure in C.
# ===========================================================================

@case("B1 the fixture is the window its header claims, with seven named series")
def _():
    key, label, s = W.load()
    return [key, len(s), sorted(s.keys()),
            len(s["step_type"]),
            sum(1 for t in s["step_type"] if t == 1),
            sum(1 for t in s["step_type"] if t == 2)], \
           ["start", 7,
            ["cadence", "enhanced_speed", "lock_rate", "rate_base", "rate_raw",
             "row_stroke_rate", "step_type"],
            216, 35, 181]


@case("B2 alignment is CHECKED on load, not assumed -- a short series raises")
def _():
    # The one structural guarantee this fixture's grammar rests on. Seven series
    # in one file is a deliberate departure from FIELD_DATA.md 2's "one series
    # per file" (the header says so), and this is what pays for it: a ragged
    # file must be a refusal, never a best-effort pairing of a rate with a value
    # from a different second.
    import tempfile
    body = ("ROW start truncated\n"
            "SERIES rate_raw 1 2 3\n"
            "SERIES rate_base 1 2\n")
    fd, p = tempfile.mkstemp(suffix=".txt")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(body)
        try:
            W.load(p)
            return "loaded", "ValueError"
        except ValueError as exc:
            return "different second" in str(exc), True
    finally:
        os.unlink(p)


@case("B3 the step_type series is one warm-up run then one work run, contiguous")
def _():
    # The window's whole shape in one assertion: no interleaving, so an index
    # difference really is a second difference and warmup_gap_s is meaningful.
    s = fixture()
    runs = []
    for t in s["step_type"]:
        if not runs or runs[-1][0] != t:
            runs.append([t, 0])
        runs[-1][1] += 1
    return [tuple(r) for r in runs], [(1, 35), (2, 181)]


# ===========================================================================
# C. THE PUBLISHED FIGURES. Every number D3 is argued from, re-derived here.
# ===========================================================================

@case("C1 the first record: a stationary boat displaying 28.8 spm")
def _():
    # THE FIGURE THE WHOLE OF D3 RESTS ON, and the one that was unregenerable.
    # Quoted at source/StrongRowView.mc in the resetStrokeBaseline note and in
    # the fastGate retraction, and in the pull request's opening table.
    fr = W.first_record(fixture())
    return ["%.4f" % fr["rate_base"], "%.4f" % fr["rate_raw"],
            "%.4f" % fr["row_stroke_rate"], "%.1f" % fr["row_stroke_rate"],
            "%.4g" % fr["enhanced_speed"], fr["cadence"],
            "%.4g" % fr["lock_rate"], fr["step_type"]], \
           ["29.5716", "28.8461", "28.8461", "28.8", "0", 0, "0", 1]


@case("C2 the baseline is NOT what published it -- clearing it changes nothing "
      "on that second")
def _():
    # The half of the reset that is a MECHANISM argument rather than a measured
    # one, made checkable: on the first record the gate passes the reading with
    # the inherited baseline AND with no baseline at all. What published 28.85
    # was the stroke-period ring, which gave mRate a median at all.
    fr = W.first_record(fixture())
    with_base = W.gated_rate(fr["rate_raw"], 0.0, fr["rate_base"])
    cleared = W.gated_rate(fr["rate_raw"], 0.0, 0.0)
    return ["%.4f" % with_base, "%.4f" % cleared, with_base == cleared], \
           ["28.8461", "28.8461", True]


@case("C3 work interval 1's baseline: first 22.6813, MIN 15.2863, max 23.6958")
def _():
    # THE RETRACTION, as a pin. A source comment said this row's rate_base
    # "never fell below 22.68 in its first work interval". 22.6813 is the value
    # at the interval's FIRST second; the minimum is 15.2863, which is 33 %
    # lower and well under the 20.0 spm knee where fastGate stops saturating.
    # The comment is corrected at its source; this is what stops the old form
    # coming back.
    bs = W.baseline_span(fixture())
    return ["%.4f" % bs["first"], "%.4f" % bs["min"], "%.4f" % bs["max"],
            bs["n"]], ["22.6813", "15.2863", "23.6958", 181]


@case("C4 the baseline WAS binding for most of interval 1, and still bit "
      "nothing -- because every binding second had the lock up")
def _():
    # The corrected reason. 148 of 181 seconds had fastGate strictly below the
    # absolute, with the bar as low as 22.93 spm -- so "it changed no gate
    # decision" is NOT the saturation identity, which only covers b >= 20.0.
    # It is that fastGate is read only on gatedRate's NO-LOCK branch and every
    # one of those 148 seconds carried a lock.
    gb = W.gate_bite(fixture())["work1"]
    return [gb["n"], gb["binding"], gb["binding_unlocked"], gb["changed"],
            "%.4f" % gb["lowest_gate"]], [181, 148, 0, 0, "22.9295"]


@case("C5 the stationary prefix: 7 seconds, ONE number and six --.-")
def _():
    # What the rower actually saw, and the exact scope of what D3 changes on
    # this recording. Six of the seven stationary seconds already read "--.-"
    # because the gate zeroed medians of 34-36 spm; only the FIRST displayed a
    # number, and that number is the defect.
    s = fixture()
    n = W.stationary_prefix(s)
    pub = W.published_prefix(s)
    return [n, sum(1 for v in pub if v > 0.0), sum(1 for v in pub if v == 0.0),
            "%.1f" % pub[0],
            ["%.1f" % s["rate_raw"][i] for i in range(1, n)]], \
           [7, 1, 6, "28.8", ["34.1", "36.6", "36.6", "36.6", "36.6", "36.6"]]


@case("C6 the six zeroed seconds are over the ABSOLUTE gate, so the reset does "
      "not change them either")
def _():
    # Named because it bounds the claim in the other direction: D3 removes ONE
    # displayed second on this recording, not seven. Every one of the other six
    # is zeroed with the baseline cleared too.
    s = fixture()
    n = W.stationary_prefix(s)
    both = []
    for i in range(1, n):
        both.append((W.gated_rate(s["rate_raw"][i], 0.0, s["rate_base"][i]),
                     W.gated_rate(s["rate_raw"][i], 0.0, 0.0)))
    return [all(a == 0.0 and b == 0.0 for a, b in both), len(both)], [True, 6]


@case("C7 the gap from the first record to the first work second is 35 s")
def _():
    # The figure behind "D3 does not explain the first work interval's RED":
    # the session had been running for 35 s by then, and the ring held real
    # rowing.
    return W.warmup_gap_s(fixture()), 35


@case("C8 the first work interval opens at 21.7-25.0 spm with native cadence "
      "25 -- the athlete really was above a 16-18 band")
def _():
    # The claim that the opening RED was CORRECT, which is what stops D3 being
    # sold as a fix for it. Both the app's number and the watch's own
    # independent cadence counter are checked, because the app agreeing with
    # itself would prove nothing.
    s = fixture()
    w = W.work_indices(s)[:20]
    rates = [s["row_stroke_rate"][i] for i in w]
    cads = [s["cadence"][i] for i in w]
    return ["%.4f" % min(rates), "%.4f" % max(rates), max(cads), min(cads),
            all(r > 18.0 for r in rates)], \
           ["21.1268", "25.0001", 25, 19, True]


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
            print("      ! expected %r" % (want,))
            print("      !      got %r" % (got,))
    print("\n%d/%d start-witness tests passed." % (len(CASES) - failures,
                                                   len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
