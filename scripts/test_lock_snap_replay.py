#!/usr/bin/env python3
"""RED/GREEN tests for scripts/lock_snap_replay.py -- the #193 replay harness.

THREE JOBS, and the first is the one that matters.

1. THE TRANSCRIPTION IS PINNED AGAINST THE SHIPPING MONKEY C. lock_snap_replay
   is a Python rewrite of StrongRowView.fastGate / gatedRate / harmonicOfLock,
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

    # (A5) test_lock_c2_aSubharmonicLockIsRefused... and
    #      test_lock_c2_aHarmonicLockIsRefused... -- the differentials.
    near(L.gated_rate(18.518518, 9.4, 19.2, L.LOCK_HARM_TOL), 18.518518,
         "A5 guarded, the 2.901 subharmonic is refused")
    near(L.gated_rate(10.416667, 1.8, 19.2, L.LOCK_HARM_TOL), 10.416667,
         "A5 guarded, the 3.200 harmonic is refused")

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
    near(L.gated_rate(20.0 / 3.10, 3.0, 19.2, L.LOCK_HARM_TOL), 20.0 / 3.10,
         "A7 ratio 3.100 is inside the 3 band")
    near(L.gated_rate(20.0 / 3.45, 3.0, 19.2, L.LOCK_HARM_TOL), 20.0,
         "A7 ratio 3.450 is outside it")

    # (A8) The predicate itself, symmetric by construction. A harmonic and its
    #      reciprocal must answer identically -- the asymmetry is the defect a
    #      four-case formulation invites.
    for a, b in ((40.0, 20.0), (20.0, 40.0), (60.0, 20.0), (20.0, 60.0)):
        check(L.harmonic_of_lock(a, b), "A8 %r/%r is a harmonic" % (a, b))
    for a, b in ((28.0, 20.0), (20.0, 28.0), (50.0, 20.0), (20.0, 50.0)):
        check(not L.harmonic_of_lock(a, b),
              "A8 %r/%r is not a harmonic" % (a, b))
    check(not L.harmonic_of_lock(0.0, 20.0), "A8 a zero median is not one")
    check(not L.harmonic_of_lock(20.0, 0.0), "A8 no lock is not one")
    check(not L.harmonic_of_lock(None, 20.0), "A8 null is not arithmetic")

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

    # B7: the alignment the two files promise, checked rather than assumed.
    for row in rows:
        check(len(row.step) == len(row.raw) and len(row.speed) == len(row.raw),
              "B7 %s: the context fixture is line-for-line with the records"
              % row.key)


# ---------------------------------------------------------------------------
# SECTION C -- every figure #193's PR body quotes.
def section_c(rows):
    by = {r.key: r for r in rows}

    # C1: the reported row, before and after, at the shipped tolerance.
    row = by["i183553852"]
    a, b = L.series(row, None), L.series(row, L.LOCK_HARM_TOL)
    check(L.gross(row, a) == 343, "C1 gross divergence before is 343, got %d"
          % L.gross(row, a))
    check(L.gross(row, b) == 185, "C1 gross divergence after is 185, got %d"
          % L.gross(row, b))
    check(L.slow_boat(row, a) == (359, 5),
          "C1 slow boat before is (359, 5 excluded), got %r"
          % (L.slow_boat(row, a),))
    check(L.slow_boat(row, b) == (262, 5),
          "C1 slow boat after is (262, 5 excluded), got %r"
          % (L.slow_boat(row, b),))

    # C2: the refusal quality and the base rate it is judged against.
    tr = L.truth(row)
    fi = L.fires(row)
    check(len(fi) == 643, "C2 the snap fires 643 times, got %d" % len(fi))
    check(L.split(row, tr, fi) == (515, 128),
          "C2 base rate is 515 wrong : 128 correct, got %r"
          % (L.split(row, tr, fi),))
    ref = L.refusals(row, a, b)
    check(len(ref) == 242, "C2 242 snaps refused, got %d" % len(ref))
    check(L.split(row, tr, ref) == (208, 34),
          "C2 refusals are 208 wrong : 34 correct, got %r"
          % (L.split(row, tr, ref),))

    # C3: the reported sequence. Records 2489-2490 and 2493-2499 showed the
    # 2.901 subharmonic and must come out at the median; 2491-2492 carried a
    # 18.750 spm lock that never snapped and must be untouched in both epochs;
    # 2500-2502 must STILL snap (ratio 1.632); 2503-2505 must come out at the
    # median.
    for i in list(range(2489, 2491)) + list(range(2493, 2500)):
        near(a[i], 6.383, "C3 record %d showed 6.383 before" % i)
        near(b[i], 18.518518, "C3 record %d shows the median after" % i)
    for i in (2491, 2492):
        near(a[i], 18.518518, "C3 record %d never snapped before" % i)
        near(b[i], 18.518518, "C3 record %d is untouched after" % i)
    for i in range(2500, 2503):
        near(a[i], 6.383, "C3 record %d showed 6.383 before" % i)
        near(b[i], 6.383, "C3 record %d is a 1.632 ratio and still snaps" % i)
    for i in range(2503, 2506):
        near(a[i], 33.333, "C3 record %d showed 33.333 before" % i)
        near(b[i], 10.416667, "C3 record %d shows the median after" % i)

    # C4: the work-lap medians do not move. This is the #149 guarantee: the
    # guard changes outliers, not the central tendency the cue bands sit on.
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

    # C5: the hold-outs. The gross-divergence reduction reproduces on both,
    # and the refusal SELECTIVITY does not -- which is the honest half of the
    # result and is pinned so it cannot quietly disappear from the PR body.
    for key, before, after in (("i178249719", 202, 127),
                               ("i174014735", 94, 60)):
        r = by[key]
        sa, sb = L.series(r, None), L.series(r, L.LOCK_HARM_TOL)
        check(L.gross(r, sa) == before and L.gross(r, sb) == after,
              "C5 %s gross %d -> %d, got %d -> %d"
              % (key, before, after, L.gross(r, sa), L.gross(r, sb)))
    for key, base, refq in (("i178249719", (278, 78), (78, 33)),
                            ("i174014735", (126, 49), (37, 14))):
        r = by[key]
        sa, sb = L.series(r, None), L.series(r, L.LOCK_HARM_TOL)
        t = L.truth(r)
        check(L.split(r, t, L.fires(r)) == base,
              "C5 %s base rate %r, got %r" % (key, base,
                                              L.split(r, t, L.fires(r))))
        got = L.split(r, t, L.refusals(r, sa, sb))
        check(got == refq, "C5 %s refusal split %r, got %r" % (key, refq, got))
    # The claim the PR body makes from those numbers, asserted as the
    # DIRECTION it actually has on each row rather than as prose. An earlier
    # draft of this suite asserted "at or below the base rate" for both
    # hold-outs; that was WRONG for i174014735, which sits marginally above
    # (2.64 against 2.57). The corrected statement is per row, and the
    # inequality is strict where the measurement is.
    want_dir = {"i183553852": "above", "i178249719": "below",
                "i174014735": "above"}
    for key, r in by.items():
        sa, sb = L.series(r, None), L.series(r, L.LOCK_HARM_TOL)
        t = L.truth(r)
        bw, bc = L.split(r, t, L.fires(r))
        rw, rc = L.split(r, t, L.refusals(r, sa, sb))
        got = "above" if rw / rc > bw / bc else "below"
        check(got == want_dir[key],
              "C5 %s: at tol %.2f the refusal quality (%.2f:1) must be %s the "
              "base rate (%.2f:1); it is %s"
              % (key, L.LOCK_HARM_TOL, rw / rc, want_dir[key], bw / bc, got))
    # And the magnitudes, because "above" carries no weight on its own: the
    # reported row's margin is 6.12 against 4.02 and hold-out B's is 2.64
    # against 2.57, which is not the same finding.
    for key, want in (("i183553852", (6.12, 4.02)),
                      ("i178249719", (2.36, 3.56)),
                      ("i174014735", (2.64, 2.57))):
        r = by[key]
        sa, sb = L.series(r, None), L.series(r, L.LOCK_HARM_TOL)
        t = L.truth(r)
        bw, bc = L.split(r, t, L.fires(r))
        rw, rc = L.split(r, t, L.refusals(r, sa, sb))
        near(rw / rc, want[0], "C5 %s refusal quality" % key, 0.005)
        near(bw / bc, want[1], "C5 %s base rate" % key, 0.005)


def main():
    rows = L.load()
    section_a()
    section_b(rows)
    section_c(rows)
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
