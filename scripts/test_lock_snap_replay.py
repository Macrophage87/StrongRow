#!/usr/bin/env python3
"""RED/GREEN tests for scripts/lock_snap_replay.py -- the #193 replay harness.

THREE JOBS, and the first is the one that matters.

1. THE TRANSCRIPTION IS PINNED AGAINST THE SHIPPING MONKEY C. lock_snap_replay
   is a Python rewrite of StrongRowView.fastGate / gatedRate / harmonicOfLock
   and a rewrite that drifts from its original proves nothing about the
   original. So every vector in section A is a vector source/LockGuardTest.mc
   ALREADY ASSERTS against the real Monkey C -- the same medians, the same lock
   periods, the same band edges -- and the pairing is named case by case so the
   correspondence can be checked by reading rather than assumed. Change the
   rule on one side only and one of the two suites reds.

   It is NOT a proof of equivalence: two implementations agreeing on a finite
   vector set agree on that set. It is the strongest check available without
   running Monkey C offline.

   Section A pins BOTH epochs -- the rule as it shipped (`tol=None`) and the
   guarded rule -- so this suite is green on every commit of the branch and
   does not have to be edited in the commit that lands the fix. A tooling suite
   that had to change in c3 would make c3 touch scripts/, which the fix-round
   partition forbids.

2. THE FIXTURES ARE PINNED. Section B re-derives the counts the fixture headers
   quote as cross-checks -- record counts, reproduction counts, snaps fired --
   from the fixtures themselves. A header that drifts from its own file is a
   provenance block that cannot be trusted, and the ingestion ritual makes
   those cross-checks the reader's two-minute confirmation that they decoded
   the same rows.

3. THE PUBLISHED FIGURES ARE PINNED. Section C re-derives every number #193's
   pull request body quotes. If the rule, the tolerance, the fixtures or the
   scoring changes, the figures move and this reds, naming the one that moved.

MUTATION MATRIX, so "this suite pins the harness" is a measurement and not a
claim. Each row is ONE edit to scripts/lock_snap_replay.py (or to a fixture),
applied to a scratch copy of scripts/, after which this suite is run. A pin
that does not red under the mutation it claims to guard is decoration, and
decoration reads as coverage. Reproduce any row with one substitution:

  #   the edit                                          named failures
  M1  delete the guard: `r = ac` unconditionally             33
  M2  `q = raw / ac` (drop the max/min swap)                 20
  M3  `d <= tol` (absolute, not relative to the ratio)       13
  M4  LOCK_HARM_TOL 0.10 -> 0.30                             22
  M5  `return False` for the 3:1 band                        29
  M6  drop `raw <= 0.0 or ac <= 0.0` from the predicate       2
  M7  LOCK_SNAP_K 0.30 -> 0.25                               19
  M8  count an absent enhanced_speed as a slow boat           2

  baseline (unmutated): 0 failures.

Eight of eight are killed, and all eight by NAMED checks. That was not true
when the matrix was first run: M1, M2 and M6 killed the suite with an unhandled
ZeroDivisionError instead, which is a kill that names no check and stops every
later assertion from running. `ratio()` below and the try/except in section A8
exist because of that measurement, not in anticipation of it.

Note M7: mutating LOCK_SNAP_K rather than anything #193 added still reds
nineteen checks, including the fixture cross-checks in section B. That is the
point of section B -- the published figures depend on the WHOLE output-stage
rule, not only on the part this branch changed.

Run: python3 scripts/test_lock_snap_replay.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lock_snap_replay as L  # noqa: E402

FAILS = []


def check(cond, what):
    if not cond:
        FAILS.append(what)


def near(got, want, what, eps=5e-4):
    check(abs(got - want) <= eps, "%s: got %r, want %r" % (what, got, want))


def ratio(a, b):
    """a:b as a float, with b == 0 answering infinity rather than raising.

    A GUARD AGAINST THE SUITE FAILING BY TRACEBACK. Measured, on the mutation
    matrix for this branch: three mutants of scripts/lock_snap_replay.py --
    deleting the guard, dropping the max/min swap, and dropping the predicate's
    non-positive clause -- killed this suite with an unhandled
    ZeroDivisionError from `wrong / correct` where a mutant left no refusals to
    split. A traceback IS a kill, but it is not a diagnosis: it names no check,
    so the mutation report cannot say WHICH pin caught it, and every assertion
    after the raise never ran. `check` below turns the same three into named
    failures.
    """
    if b == 0:
        return float("inf") if a else float("nan")
    return float(a) / float(b)


# ---------------------------------------------------------------------------
# SECTION A -- the transcription, against the vectors the Monkey C asserts.
def section_a():
    # (A1) test_lock_c0_theAbsoluteGateIsThirtyWithNoRateEstablished, all four
    #      cases. The comparison is STRICT, so 30.0 passes and 30.1 does not.
    for raw, want in ((29.9, 29.9), (30.0, 30.0), (30.1, 0.0), (45.0, 0.0)):
        near(L.gated_rate(raw, 0.0, 0.0), want,
             "A1 no lock, no baseline, %r" % raw)

    # (A2) test_lock_c0_aLockedReadingSnapsOnlyWhenItDisagrees, against a
    #      3.0 s (20.0 spm) lock. LOCK_SNAP_K = 0.30 puts the threshold at a
    #      6.0 spm deviation. The 38.0 entry is the one whose EXPECTATION the
    #      Monkey C changes in c2, so it is pinned in both epochs here.
    for raw, want in ((20.0, 20.0), (25.9, 25.9), (26.1, 20.0), (14.1, 14.1),
                      (13.9, 20.0)):
        near(L.gated_rate(raw, 3.0, 0.0), want, "A2 shipped, 20 spm lock, %r"
             % raw)
        near(L.gated_rate(raw, 3.0, 0.0, L.LOCK_HARM_TOL), want,
             "A2 guarded, 20 spm lock, %r" % raw)
    near(L.gated_rate(38.0, 3.0, 0.0), 20.0, "A2 shipped, 38.0 snaps to 20.0")
    near(L.gated_rate(38.0, 3.0, 0.0, L.LOCK_HARM_TOL), 38.0,
         "A2 guarded, 38.0 is a 1.90 ratio and is refused")
    near(L.gated_rate(0.0, 3.0, 0.0), 0.0,
         "A2 a zero median is the no-data state and is never filled in")
    near(L.gated_rate(0.0, 3.0, 0.0, L.LOCK_HARM_TOL), 0.0,
         "A2 guarded, a zero median is still never filled in")

    # (A3) test_lock_c0_theSurvivingRateIsClampedToFortySpm. A 1.5 s lock is
    #      40.0 spm; 45.0 deviates by 5.0, inside the 12.0 threshold, so it is
    #      NOT snapped and must then be clamped. 39.0 is the mirror.
    near(L.gated_rate(45.0, 1.5, 0.0), 40.0, "A3 shipped clamp")
    near(L.gated_rate(45.0, 1.5, 0.0, L.LOCK_HARM_TOL), 40.0, "A3 guarded clamp")
    near(L.gated_rate(39.0, 1.5, 0.0), 39.0, "A3 shipped, under the ceiling")

    # (A4) test_lock_c0_theSnapSubstitutesAHarmonicLockAtRatioTwoAndThree --
    #      the c0 characterization, retired in c2. Ratios 2.901 and 3.200 off
    #      recording i183553852.
    near(L.gated_rate(18.518518, 9.4, 19.2), 60.0 / 9.4,
         "A4 shipped, the 2.901 subharmonic substitutes")
    near(L.gated_rate(10.416667, 1.8, 19.2), 60.0 / 1.8,
         "A4 shipped, the 3.200 harmonic substitutes")
    near(L.gated_rate(39.0, 3.0, 19.2), 20.0, "A4 shipped, the 1.95 harmonic")
    near(L.gated_rate(10.0, 3.0, 19.2), 20.0, "A4 shipped, the 2.00 subharmonic")

    # (A5) THE 3:1 CASES, in both band sets. These are the two records the
    #      branch was named after, and the shipping rule leaves them ALONE:
    #      the independent witness says the lock was the better candidate
    #      there (section E5). test_lock_c2_aThreeToOneSubharmonicLockStill-
    #      Snaps and its harmonic mirror assert the same thing against the
    #      Monkey C.
    near(L.gated_rate(18.518518, 9.4, 19.2, L.LOCK_HARM_TOL), 60.0 / 9.4,
         "A5 shipping bands, the 2.901 subharmonic STILL snaps")
    near(L.gated_rate(10.416667, 1.8, 19.2, L.LOCK_HARM_TOL), 60.0 / 1.8,
         "A5 shipping bands, the 3.200 harmonic STILL snaps")
    #      And under ROUND 1's bands they were refused. Kept so the superseded
    #      behaviour stays checkable rather than becoming unverifiable history.
    near(L.gated_rate(18.518518, 9.4, 19.2, L.LOCK_HARM_TOL, L.BANDS_R1),
         18.518518, "A5 round 1's bands refused the 2.901 subharmonic")
    near(L.gated_rate(10.416667, 1.8, 19.2, L.LOCK_HARM_TOL, L.BANDS_R1),
         10.416667, "A5 round 1's bands refused the 3.200 harmonic")

    # (A6) test_lock_c0_aNonHarmonicDisagreementSnapsInEveryEpoch. Ratios
    #      1.40 (#10's worked surge), 1.305, 1.439, 1.70 and 1.632.
    for raw, period, want in ((28.0, 3.0, 20.0), (26.1, 3.0, 20.0),
                              (13.9, 3.0, 20.0), (34.0, 3.0, 20.0),
                              (10.416667, 9.4, 60.0 / 9.4)):
        near(L.gated_rate(raw, period, 19.2), want,
             "A6 shipped, %r against %r s" % (raw, period))
        near(L.gated_rate(raw, period, 19.2, L.LOCK_HARM_TOL), want,
             "A6 guarded, %r against %r s" % (raw, period))

    # (A7) test_lock_c2_theRefusalBandEdges... The band around 2 is
    #      [1.80, 2.20] and around 3 is [2.70, 3.30] at tol 0.10. Pinned
    #      INSIDE and OUTSIDE with margin, never AT the edge: 1.8 and 0.2 are
    #      both inexact in binary, and float32 on the watch need not round a
    #      boundary comparison the way float64 does here.
    near(L.gated_rate(36.5, 3.0, 19.2, L.LOCK_HARM_TOL), 36.5,
         "A7 ratio 1.825 is inside the 2 band")
    near(L.gated_rate(34.0, 3.0, 19.2, L.LOCK_HARM_TOL), 20.0,
         "A7 ratio 1.700 is outside it")
    near(L.gated_rate(20.0 / 3.10, 3.0, 19.2, L.LOCK_HARM_TOL), 20.0,
         "A7 ratio 3.100 SNAPS -- the shipping rule has no 3:1 band")
    near(L.gated_rate(20.0 / 3.00, 3.0, 19.2, L.LOCK_HARM_TOL), 20.0,
         "A7 an EXACT 3:1 ratio snaps too, so the band is gone and not merely "
         "narrowed")
    near(L.gated_rate(20.0 / 3.45, 3.0, 19.2, L.LOCK_HARM_TOL), 20.0,
         "A7 ratio 3.450 snaps in either band set")
    near(L.gated_rate(20.0 / 3.10, 3.0, 19.2, L.LOCK_HARM_TOL, L.BANDS_R1),
         20.0 / 3.10, "A7 round 1's bands refused ratio 3.100")

    # (A8) The predicate itself, symmetric by construction. A harmonic and its
    #      reciprocal must answer identically -- the asymmetry is the defect a
    #      four-case formulation invites.
    for a, b in ((40.0, 20.0), (20.0, 40.0)):
        check(L.harmonic_of_lock(a, b), "A8 %r/%r is a 2:1 harmonic" % (a, b))
    for a, b in ((28.0, 20.0), (20.0, 28.0), (50.0, 20.0), (20.0, 50.0),
                 (60.0, 20.0), (20.0, 60.0)):
        check(not L.harmonic_of_lock(a, b),
              "A8 %r/%r is not a harmonic under the shipping bands" % (a, b))
    for a, b in ((60.0, 20.0), (20.0, 60.0)):
        check(L.harmonic_of_lock(a, b, L.LOCK_HARM_TOL, L.BANDS_R1),
              "A8 %r/%r WAS a harmonic under round 1's bands" % (a, b))
    # The degenerate inputs are called through a CATCH, not bare. Without it a
    # predicate that dropped its non-positive clause would divide by zero and
    # kill the suite by traceback -- a kill that names no check and stops every
    # later assertion. Measured on this branch's mutation matrix: that mutant
    # went from "CRASH: ZeroDivisionError" to the three named failures below.
    for a, b, what in ((0.0, 20.0, "a zero median"), (20.0, 0.0, "no lock"),
                       (None, 20.0, "a null median"),
                       (20.0, None, "a null lock"),
                       (-5.0, 20.0, "a negative median")):
        try:
            check(not L.harmonic_of_lock(a, b), "A8 %s is not a harmonic" % what)
        except Exception as e:
            check(False, "A8 %s must ANSWER, not raise: harmonic_of_lock(%r, "
                         "%r) raised %s. An absent or non-positive value must "
                         "not be arithmetic." % (what, a, b, type(e).__name__))

    # (A9) The guard cannot reach the NO-LOCK arm. Every figure in this file
    #      rests on the fix being confined to the snap.
    for base in (0.0, 8.0, 15.0, 20.0, 30.0):
        for raw in (0.0, 6.0, 14.0, 20.0, 29.9, 30.0, 30.1, 45.0):
            near(L.gated_rate(raw, 0.0, base, L.LOCK_HARM_TOL),
                 L.gated_rate(raw, 0.0, base),
                 "A9 no lock, raw %r base %r, the guard must be a no-op"
                 % (raw, base))


# ---------------------------------------------------------------------------
# SECTION B -- the fixtures and their headers' cross-checks.
def section_b(rows):
    check([r.key for r in rows] ==
          ["i183553852", "i178249719", "i174014735"],
          "B1 the fixtures carry the three rows, in order")

    want = {"i183553852": (3385, 3382, 643),
            "i178249719": (3002, 2997, 356),
            "i174014735": (2276, 2274, 175)}
    for row in rows:
        n, rep, fires = want[row.key]
        check(len(row) == n, "B2 %s has %d records, header says %d"
              % (row.key, len(row), n))
        s = L.series(row, None)
        ok = sum(1 for i in range(len(row)) if abs(s[i] - row.out[i]) <= 1e-4)
        check(ok == rep, "B3 %s reproduces %d, header says %d"
              % (row.key, ok, rep))
        check(len(L.fires(row)) == fires, "B4 %s fires %d snaps, header says %d"
              % (row.key, len(L.fires(row)), fires))

    # B5: the header's two named records. These are the defect itself, so a
    # fixture that no longer carries them would silently un-evidence #193.
    row = rows[0]
    near(row.raw[2489], 18.518518, "B5 record 2489 rate_raw")
    near(row.lock[2489], 6.383, "B5 record 2489 lock_rate")
    near(row.out[2489], 6.383, "B5 record 2489 row_stroke_rate")
    near(row.raw[2503], 10.416667, "B5 record 2503 rate_raw")
    near(row.lock[2503], 33.333, "B5 record 2503 lock_rate")
    near(row.out[2503], 33.333, "B5 record 2503 row_stroke_rate")

    # B6: the absence encodings the context fixture states. step_type is not
    # merely zero on the hold-outs, it is ABSENT, and the two are different
    # states -- rendering one as the other is a named defect class here.
    check(all(v is None for v in rows[1].step),
          "B6 hold-out A carries no step_type at all")
    check(all(v is None for v in rows[2].step),
          "B6 hold-out B carries no step_type at all")
    check(sum(1 for v in rows[0].speed if v is None) == 24,
          "B6 the reported row has 24 records with no enhanced_speed")
    check(sum(1 for v in rows[0].speed if v == 0.0) > 0,
          "B6 and 0.000 m/s is a real reading on it, not an absence")

    # B7: the alignment the three files promise, checked rather than assumed.
    for row in rows:
        check(len(row.step) == len(row.raw) and len(row.speed) == len(row.raw),
              "B7 %s: the context fixture is line-for-line with the records"
              % row.key)
        check(len(row.cad) == len(row.raw),
              "B7 %s: the witness fixture is line-for-line with the records"
              % row.key)

    # B8: the witness fixture's own header cross-checks.
    for key, nz, nlaps in (("i183553852", 1608, 17), ("i178249719", 1734, 17),
                           ("i174014735", 1875, 5)):
        row = [r for r in rows if r.key == key][0]
        got = sum(1 for c in row.cad if c is not None and c > 0.0)
        check(got == nz, "B8 %s: cadence non-zero on %d records, header says "
                         "%d" % (key, got, nz))
        check(len(row.laps) == nlaps, "B8 %s: %d lap messages, header says %d"
              % (key, len(row.laps), nlaps))
        check(all(c is not None for c in row.cad),
              "B8 %s: no record is MISSING cadence, which is what lets the "
              "fixture carry no absence marker on a CAD line" % key)
        check(all(c == int(c) for c in row.cad),
              "B8 %s: cadence is an INTEGER on every record, which is the "
              "header's claim that omitting fractional_cadence loses no "
              "resolution" % key)
    # lap_step_type is present on the reported row and ABSENT on both
    # hold-outs -- a different state from zero, and the reason those two rows
    # get no work-lap figure anywhere in this harness.
    check(all(l[1] is not None for l in rows[0].laps),
          "B8 the reported row carries lap_step_type on all 17 laps")
    for r in rows[1:]:
        check(all(l[1] is None for l in r.laps),
              "B8 %s carries lap_step_type on NO lap; it predates field 25"
              % r.key)


# ---------------------------------------------------------------------------
# SECTION C -- every figure #196's PR body quotes, for the rule that SHIPS
# (2:1 band only) and for the rule ROUND 1 shipped (2:1 + 3:1). Both are
# pinned: round 1 published from the second, and a figure that quietly stops
# being regenerable is exactly what this harness exists to prevent.
def section_c(rows):
    by = {r.key: r for r in rows}

    # C1: the reported row, before and after, at the shipping band set.
    row = by["i183553852"]
    a = L.series(row, None)
    b = L.series(row, L.LOCK_HARM_TOL)                    # BANDS = (2.0,)
    b1 = L.series(row, L.LOCK_HARM_TOL, L.BANDS_R1)       # (2.0, 3.0)
    check(L.gross(row, a) == 343, "C1 gross before is 343, got %d"
          % L.gross(row, a))
    check(L.gross(row, b) == 289, "C1 gross after (2:1 only) is 289, got %d"
          % L.gross(row, b))
    check(L.gross(row, b1) == 185,
          "C1 gross after ROUND 1's bands is 185, got %d" % L.gross(row, b1))
    check(L.slow_boat(row, a) == (359, 5),
          "C1 slow boat before is (359, 5 excluded), got %r"
          % (L.slow_boat(row, a),))
    check(L.slow_boat(row, b) == (328, 5),
          "C1 slow boat after is (328, 5 excluded), got %r"
          % (L.slow_boat(row, b),))

    # C2: refusal counts, and the biased secondary truth's split.
    tr = L.truth(row)
    fi = L.fires(row)
    check(len(fi) == 643, "C2 the snap fires 643 times, got %d" % len(fi))
    check(L.split(row, tr, fi) == (515, 128),
          "C2 the SECONDARY truth's base rate is 515:128, got %r"
          % (L.split(row, tr, fi),))
    ref = L.refusals(row, a, b)
    check(len(ref) == 138, "C2 138 snaps refused at 2:1 only, got %d"
          % len(ref))
    check(len(L.refusals(row, a, b1)) == 242,
          "C2 242 snaps refused under round 1's bands, got %d"
          % len(L.refusals(row, a, b1)))
    check(L.split(row, tr, ref) == (118, 20),
          "C2 the SECONDARY truth calls the 2:1 refusals 118:20, got %r"
          % (L.split(row, tr, ref),))

    # C3: THE MOTIVATING SEQUENCE IS NO LONGER CHANGED AT ALL.
    #
    # This is the most important pin in the file and it asserts a NEGATIVE.
    # Round 1 named this branch after records 2489-2505 and published them as
    # the defect. The independent witness says the opposite: the window is the
    # cool-down, the lap's own native rate is 6.49 spm, and the lock's 6.383
    # was the better of the two candidates. Both ratios there are 3:1, so
    # dropping the 3:1 band leaves every one of these records exactly as it
    # shipped -- and the suite says so out loud rather than letting the
    # sequence quietly vanish from the body.
    for i in range(2486, 2506):
        near(b[i], a[i], "C3 record %d must be UNCHANGED by the shipping "
                         "rule (both ratios in this window are 3:1)" % i)
    for i in list(range(2489, 2491)) + list(range(2493, 2500)):
        near(a[i], 6.383, "C3 record %d publishes the lock, 6.383" % i)
    for i in range(2503, 2506):
        near(a[i], 33.333, "C3 record %d publishes the lock, 33.333" % i)
    # And under ROUND 1's bands it WAS changed -- kept so the superseded
    # claim stays checkable rather than becoming unverifiable history.
    for i in list(range(2489, 2491)) + list(range(2493, 2500)):
        near(b1[i], 18.518518,
             "C3 record %d was changed to the median by round 1's bands" % i)

    # C4: the work-lap medians do not move. The #149 guarantee.
    laps_a = L.work_laps(row, a)
    laps_b = L.work_laps(row, b)
    check(len(laps_a) == 8 and sum(len(l) for l in laps_a) == 1443,
          "C4 8 work laps, 1443 seconds, got %d laps and %d seconds"
          % (len(laps_a), sum(len(l) for l in laps_a)))
    import cue_replay
    ma = ["%.1f" % m for m in cue_replay.lap_medians(laps_a)]
    mb = ["%.1f" % m for m in cue_replay.lap_medians(laps_b)]
    check(ma == ["17.6", "18.3", "17.6", "17.9", "18.7", "22.7", "23.8",
                 "23.4"], "C4 lap medians before, got %r" % ma)
    check(ma == mb, "C4 the lap medians must not move; %r -> %r" % (ma, mb))

    # C5: the hold-outs, at the shipping band set.
    for key, before, after, nref in (("i178249719", 202, 166, 72),
                                     ("i174014735", 94, 79, 32)):
        r = by[key]
        sa, sb = L.series(r, None), L.series(r, L.LOCK_HARM_TOL)
        check(L.gross(r, sa) == before and L.gross(r, sb) == after,
              "C5 %s gross %d -> %d, got %d -> %d"
              % (key, before, after, L.gross(r, sa), L.gross(r, sb)))
        check(len(L.refusals(r, sa, sb)) == nref,
              "C5 %s refuses %d snaps, got %d"
              % (key, nref, len(L.refusals(r, sa, sb))))


# ---------------------------------------------------------------------------
# SECTION D -- the LIMITATION's own figures. A caveat with a number in it is a
# measurement; a caveat without one is an apology. These are the numbers the
# PR body and #199 quote for what the replay cannot see.
def section_d(rows):
    want = {"i183553852": (138, 44, 382, 67),
            "i178249719": (72, 15, 189, 39),
            "i174014735": (32, 17, 77, 4)}
    for row in rows:
        a, b = L.series(row, None), L.series(row, L.LOCK_HARM_TOL)
        got = L.second_order(row, a, b)
        check(got == want[row.key],
              "D1 %s second-order exposure (changed, up, no-lock, near-gate) "
              "%r, got %r" % (row.key, want[row.key], got))
    # The direction claim, per row, because it is NOT the same on all three:
    # the reported row and hold-out A move the published rate down on balance,
    # hold-out B is close to even. Round 1 stated the reported row's split as
    # if it were a property of the guard; it is a property of that row.
    for key, want_down in (("i183553852", True), ("i178249719", True),
                           ("i174014735", False)):
        r = [x for x in rows if x.key == key][0]
        ch, up, _, _ = L.second_order(r, L.series(r, None),
                                      L.series(r, L.LOCK_HARM_TOL))
        check(((ch - up) > up) == want_down,
              "D2 %s: 'most changes move the rate DOWN' must be %r; it is "
              "%d down against %d up" % (key, want_down, ch - up, up))


# ---------------------------------------------------------------------------
# SECTION E -- THE INDEPENDENT WITNESS. The figures the band set is chosen
# from, and the ones round 1 had no way to compute.
#
# These pin a CONCLUSION ABOUT EVIDENCE, not a behaviour: that the 2:1 and the
# 3:1 bands are different findings. If a future edit to the witness, the
# calibration or the decision rule makes them look alike again, this reds and
# names which one moved.
def section_e(rows):
    by = {r.key: r for r in rows}

    # E1: the calibration constants, from the fixture header's cross-check.
    for key, want in (("i183553852", 1.077), ("i178249719", 1.303),
                      ("i174014735", 0.988)):
        near(L.witness_scale(by[key]), want, "E1 %s k" % key, 0.0005)

    # E2: the pooled split, by band, under ROUND 1's band set -- which is the
    # comparison that decides the band set. Scored at k x 1.00.
    tot = {"all": [0, 0], "ref": [0, 0], 2: [0, 0], 3: [0, 0]}
    for row in rows:
        k = L.witness_scale(row)
        a = L.series(row, None)
        b1 = L.series(row, L.LOCK_HARM_TOL, L.BANDS_R1)
        ref = L.refusals(row, a, b1)
        groups = {"all": L.fires(row), "ref": ref,
                  2: [i for i in ref if L.band_of(row, i) == 2],
                  3: [i for i in ref if L.band_of(row, i) == 3]}
        for g, idx in groups.items():
            w, r, _ = L.witness_split(row, idx, k)
            tot[g][0] += w
            tot[g][1] += r
    for g, want in (("all", [118, 73]), ("ref", [50, 24]), (2, [40, 8]),
                    (3, [10, 16])):
        check(tot[g] == want, "E2 pooled witness split for %r is %r, got %r"
              % (g, want, tot[g]))

    # E3: the split is a property of the DATA, not of the calibration. The 2:1
    # band must keep its direction at every k in the sweep and the 3:1 band
    # must never reach significance at any of them. This is the claim the band
    # decision rests on, so it is asserted rather than described.
    for mult in L.K_SWEEP:
        b2 = [0, 0]
        b3 = [0, 0]
        for row in rows:
            k = L.witness_scale(row) * mult
            a = L.series(row, None)
            b1 = L.series(row, L.LOCK_HARM_TOL, L.BANDS_R1)
            ref = L.refusals(row, a, b1)
            for n, acc in ((2, b2), (3, b3)):
                w, r, _ = L.witness_split(
                    row, [i for i in ref if L.band_of(row, i) == n], k)
                acc[0] += w
                acc[1] += r
        check(b2[0] > b2[1] and L.binom_p(*b2) < 0.001,
              "E3 at k x %.2f the 2:1 band must stay wrong-snap-dominant and "
              "significant; it is %d:%d, p=%.5f"
              % (mult, b2[0], b2[1], L.binom_p(*b2)))
        check(L.binom_p(*b3) > 0.05,
              "E3 at k x %.2f the 3:1 band must NOT reach significance; it is "
              "%d:%d, p=%.5f" % (mult, b3[0], b3[1], L.binom_p(*b3)))

    # E4: the shipping rule's refusals, per row, against each row's OWN base
    # rate. Round 1's headline weakness was that two of three rows failed this
    # under the biased truth. Under the witness all three pass it -- which is
    # a change in the EVIDENCE, not in the rows, and is pinned so it cannot be
    # asserted without being checked.
    for key, want_ref, want_base in (("i183553852", (22, 2), (63, 37)),
                                     ("i178249719", (11, 4), (43, 19)),
                                     ("i174014735", (7, 2), (12, 17))):
        r = by[key]
        k = L.witness_scale(r)
        a, b = L.series(r, None), L.series(r, L.LOCK_HARM_TOL)
        gw, gr, _ = L.witness_split(r, L.refusals(r, a, b), k)
        bw, br, _ = L.witness_split(r, L.fires(r), k)
        check((gw, gr) == want_ref, "E4 %s refusal split %r, got %r"
              % (key, want_ref, (gw, gr)))
        check((bw, br) == want_base, "E4 %s base split %r, got %r"
              % (key, want_base, (bw, br)))
        check(gw / max(1, gr) > bw / max(1, br),
              "E4 %s: the shipping rule's refusals (%d:%d) must beat that "
              "row's own base rate (%d:%d); this is the claim round 1 could "
              "not make on two of three rows" % (key, gw, gr, bw, br))

    # E5: the work-lap answer to the 38-vs-20 question, and the cool-down
    # finding that moved the band set.
    row = by["i183553852"]
    k = L.witness_scale(row)
    a, b1 = L.series(row, None), L.series(row, L.LOCK_HARM_TOL, L.BANDS_R1)
    ref = L.refusals(row, a, b1)
    work = [i for i in ref if row.step[i] == 2]
    check(len(work) == 28 and len(ref) - len(work) == 214,
          "E5 28 of 242 round-1 refusals are on work seconds, 214 outside; "
          "got %d and %d" % (len(work), len(ref) - len(work)))
    w2 = [i for i in work if L.band_of(row, i) == 2]
    check(L.witness_split(row, w2, k)[:2] == (12, 0),
          "E5 the 2:1 band on work seconds must be 12:0 -- not one scored "
          "work-lap 2:1 refusal was a double-count; got %r"
          % (L.witness_split(row, w2, k)[:2],))
    # The cool-down lap, from the fixture's LAP lines: this is what makes the
    # motivating sequence's lock the better candidate.
    lap16 = [l for l in row.laps if l[0] == 16][0]
    check(lap16[1] == 5, "E5 lap 16 must be step_type 5 (cool-down), got %r"
          % (lap16[1],))
    near(60.0 * lap16[2] / lap16[3], 6.494,
         "E5 lap 16's native rate (97 cycles / 896.247 s)", 0.001)
    check(all(row.cad[i] == 0.0 for i in range(2488, 2675)),
          "E5 native cadence must read 0 for the 187 records 2488-2674")
    check(row.cad[2675] == 10.0,
          "E5 the first non-zero cadence after that run is record 2675 at 10 "
          "spm; got %r" % (row.cad[2675],))


def main():

    rows = L.load()
    section_a()
    section_b(rows)
    section_c(rows)
    section_d(rows)
    section_e(rows)
    for f in FAILS:
        print("FAIL " + f)
    if FAILS:
        print("%d failure(s)" % len(FAILS))
        return 1
    print("OK: scripts/lock_snap_replay.py -- transcription, fixtures and "
          "published figures all pinned.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
