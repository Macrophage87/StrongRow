#!/usr/bin/env python3
"""Replay StrongRowView.gatedRate against three recorded rows, with and
without #193's harmonic guard.

WHY THIS FILE EXISTS. #193 changes a decision that only field data can settle:
whether refusing to snap to a lock that stands in a near-2:1 or near-3:1 ratio
to the detector's median removes more bad readings than it creates. Every
figure #193 and its pull request quote comes out of this file, from fixtures in
the repository, so a reader can regenerate the lot in one command instead of
taking it on trust:

    python3 scripts/lock_snap_replay.py

That is the rule scripts/cue_replay.py and scripts/speed_witness.py were both
written to enforce after figures shipped that nobody could reproduce. The
ingestion ritual states it as "a recording is not evidence until something
committed can regenerate every figure taken from it".

WHAT MAKES THIS REPLAYABLE AT ALL. The FIT carries BOTH of gatedRate's
non-trivial inputs and its output as developer fields -- rate_raw (23),
lock_rate (20), rate_base (24) and row_stroke_rate (0) -- so the shipped
decision can be re-run offline on exactly the numbers it saw. `reproduce`
below is that check and it runs FIRST: a transcription that does not reproduce
the recorded output is wrong, and scoring a wrong transcription is how this
repository published figures for a machine that never shipped.

WHAT IT IS NOT. This is a PYTHON TRANSCRIPTION of the Monkey C, not the Monkey
C itself; an offline replay cannot call into a .prg. The drift is closed from
both ends, the same way cue_replay.py closes it:

  * the four functions in THE TRANSCRIPTION below are transcribed line for line
    with the Monkey C they mirror quoted beside them (source/StrongRowView.mc,
    fastGate / gatedRate / harmonicOfLock / lockHarmTol);
  * scripts/test_lock_snap_replay.py re-asserts, against THIS transcription,
    the same numeric vectors source/LockGuardTest.mc asserts against the
    shipping Monkey C. Editing either side alone reds one of the two suites.

It is not a proof of equivalence -- two implementations agreeing on a finite
vector set agree on that set. And it says nothing about what a watch displays:
it is a decision function fed recorded numbers.

WHAT THE FIGURES DO NOT SETTLE, stated here rather than left to be inferred:

  * "The snap was correct" has no ground truth in any recording. The
    definition used below (REFUSAL QUALITY) grades a snap against a 31 s
    CENTRED MEDIAN OF THE RAW SERIES -- the same truth definition
    cue_replay.py uses, and the strongest one available -- but that median is
    built from `raw`, so it CANNOT see a raw error sustained for 31 s. The
    case where the median and the lock are both wrong together is #149's, not
    this file's, and no figure here bears on it.
  * A recording tells you what a decoder read out of a file some firmware
    wrote. It does not tell you what this app's setData calls produced.
"""

import argparse
import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cue_replay  # noqa: E402  -- the committed #149 harness, reused whole


# ---------------------------------------------------------------------------
# THE TRANSCRIPTION. Each function mirrors the Monkey C of the same name, and
# the tunables carry the values of the consts they mirror.
MIN_RATE = 6.0
MAX_RATE = 40.0
LOCK_SNAP_K = 0.30
FAST_NEEDS_LOCK = 30.0
LOCK_REL_K = 1.5
LOCK_GATE_FLOOR = 20.0

# StrongRowView.lockHarmTol(). A static function and not a const on either
# side: on the Monkey C side a file-scope const costs a fenix6 `globals`
# member, and the headroom is four. The value is argued in THE SWEEP below.
LOCK_HARM_TOL = 0.10


def fast_gate(base):
    """Mirrors StrongRowView.fastGate."""
    if base is None or base <= 0.0:
        return FAST_NEEDS_LOCK
    g = LOCK_REL_K * base
    if g < LOCK_GATE_FLOOR:
        g = LOCK_GATE_FLOOR
    if g > FAST_NEEDS_LOCK:
        g = FAST_NEEDS_LOCK
    return g


def harmonic_of_lock(raw, ac, tol=LOCK_HARM_TOL):
    """Mirrors StrongRowView.harmonicOfLock -- #193's guard predicate.

    True when `raw` and the lock stand in a near-2:1 or near-3:1 ratio in
    EITHER direction. `q` is max/min, so a harmonic (raw is the double) and a
    subharmonic (the lock is the double) are one comparison and one tolerance
    rather than four cases with four chances to be asymmetric.
    """
    if raw is None or ac is None or raw <= 0.0 or ac <= 0.0:
        return False
    q = raw / ac if raw > ac else ac / raw
    d = q - 2.0
    if d < 0.0:
        d = -d
    if d <= tol * 2.0:
        return True
    d = q - 3.0
    if d < 0.0:
        d = -d
    return d <= tol * 3.0


def gated_rate(raw, ac_period, base, tol=None):
    """Mirrors StrongRowView.gatedRate.

    `tol=None` is the rule as it SHIPPED before #193; a number is #193's
    guarded rule at that tolerance. Both are kept, and both are pinned by
    scripts/test_lock_snap_replay.py, so no figure here depends on which epoch
    of the Monkey C happens to be checked out.
    """
    r = raw
    if ac_period > 0.0:
        ac = 60.0 / ac_period
        if r > 0.0:
            dev = r - ac
            if dev < 0.0:
                dev = -dev
            if dev > LOCK_SNAP_K * ac:
                if tol is None or not harmonic_of_lock(r, ac, tol):
                    r = ac
    elif r > fast_gate(base):
        r = 0.0
    if r > MAX_RATE:
        r = MAX_RATE
    return r


def period_of(lock_rate):
    """The recorded lock_rate is a RATE; gatedRate takes a PERIOD.

    StrongRowView.lockRateOf is the inverse the app applies on the way out:
    0.0 is LOCK_RATE_NONE, "no lock", and maps back to a 0.0 period rather
    than to a division by zero.
    """
    return 0.0 if lock_rate <= 0.0 else 60.0 / lock_rate


# ---------------------------------------------------------------------------
# THE FIXTURES.
HERE = os.path.dirname(os.path.abspath(__file__))
RECORDS = os.path.join(HERE, "fixtures", "lock_snap_records.txt")
CONTEXT = os.path.join(HERE, "fixtures", "lock_snap_context.txt")


class Row(object):
    """One recording: the replay columns and the scoring selectors, aligned."""

    def __init__(self, key, label):
        self.key = key
        self.label = label
        self.raw = []
        self.lock = []
        self.base = []
        self.out = []
        self.step = []
        self.speed = []

    def __len__(self):
        return len(self.raw)


def _parse(path, tag, arity):
    """Returns [(key, label, [tuple, ...]), ...] in file order."""
    rows = []
    with open(path, "r") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            head, _, rest = line.partition(" ")
            if head == "ROW":
                key, _, label = rest.partition(" ")
                rows.append((key, label, []))
            elif head == tag:
                if not rows:
                    raise ValueError("%s before any ROW in %s" % (tag, path))
                parts = rest.split()
                if len(parts) != arity:
                    raise ValueError("%s: %s line with %d fields, expected %d"
                                     % (path, tag, len(parts), arity))
                rows[-1][2].append(parts)
            else:
                raise ValueError("unrecognised line in %s: %s" % (path, line))
    return rows


def load(records=RECORDS, context=CONTEXT):
    """The two fixtures zipped, with alignment CHECKED rather than assumed.

    speed_witness.py's rows() takes the same precaution and states the reason:
    a best-effort pairing of a rate with a selector from a different moment is
    worse than a refusal, because it produces a number that looks fine.
    """
    recs = _parse(records, "REC", 4)
    ctxs = _parse(context, "CTX", 2)
    if len(recs) != len(ctxs):
        raise ValueError("fixtures disagree on the number of rows: %d vs %d"
                         % (len(recs), len(ctxs)))
    out = []
    for (rk, rl, rv), (ck, _cl, cv) in zip(recs, ctxs):
        if rk != ck:
            raise ValueError("fixtures disagree on row order: %s vs %s"
                             % (rk, ck))
        if len(rv) != len(cv):
            raise ValueError("row %s: %d REC lines but %d CTX lines"
                             % (rk, len(rv), len(cv)))
        row = Row(rk, rl)
        for a, b in zip(rv, cv):
            row.raw.append(float(a[0]))
            row.lock.append(float(a[1]))
            row.base.append(float(a[2]))
            row.out.append(float(a[3]))
            row.step.append(None if b[0] == "-" else int(b[0]))
            row.speed.append(None if b[1] == "-" else float(b[1]))
        out.append(row)
    return out


# ---------------------------------------------------------------------------
# SCORING -- the definitions, stated once, in code.
#
#   A SNAP FIRES        the shipped rule replacing the median with the lock:
#                       a lock is up, the median is non-zero, and they differ
#                       by more than LOCK_SNAP_K of the lock.
#   GROSS DIVERGENCE    a record whose OUTPUT differs from `rate_raw` by more
#                       than 2x in either direction, both being non-zero. This
#                       is the displayed number disagreeing with the
#                       detector's own median by a factor, which is what the
#                       athlete saw.
#   SLOW BOAT           a record reading above 25 spm while the RECORDED
#                       enhanced_speed was under 0.3 m/s. Records carrying NO
#                       enhanced_speed are excluded: an absent speed is not a
#                       slow boat, and rendering that absence as a value is one
#                       of this repository's named defect classes. The count of
#                       excluded records is printed beside the figure.
#   TRUTH               a 31 s CENTRED MEDIAN of the non-zero `rate_raw`
#                       around the record (>= 5 samples, else undefined). The
#                       same definition cue_replay.py uses. It is independent
#                       of the lock, which is the point -- but it is built from
#                       `raw`, so it cannot grade a raw error that lasts.
#   REFUSAL QUALITY     of the snaps a guard refuses, how many the truth says
#                       were WRONG (raw nearer the truth than the lock) and how
#                       many CORRECT (lock nearer). Reported against the BASE
#                       RATE, the same wrong:correct split over ALL snaps: a
#                       guard that refuses at the base rate is refusing at
#                       random and has only traded one error for another.
TRUTH_WIN = 31
TRUTH_MIN_SAMPLES = 5
SLOW_SPM = 25.0
SLOW_MS = 0.3
GROSS = 2.0


def series(row, tol):
    return [gated_rate(row.raw[i], period_of(row.lock[i]), row.base[i], tol)
            for i in range(len(row))]


def truth(row, win=TRUTH_WIN):
    half = win // 2
    out = []
    for i in range(len(row)):
        w = [v for v in row.raw[max(0, i - half):i + half + 1] if v > 0.0]
        out.append(statistics.median(w) if len(w) >= TRUTH_MIN_SAMPLES
                   else None)
    return out


def fires(row):
    return [i for i in range(len(row))
            if row.lock[i] > 0.0 and row.raw[i] > 0.0
            and abs(row.raw[i] - row.lock[i]) > LOCK_SNAP_K * row.lock[i]]


def gross(row, out):
    n = 0
    for i in range(len(row)):
        a, b = out[i], row.raw[i]
        if a > 0.0 and b > 0.0 and max(a, b) / min(a, b) > GROSS:
            n += 1
    return n


def slow_boat(row, out):
    """(counted, excluded-for-absent-speed)."""
    hit = miss = 0
    for i in range(len(row)):
        if out[i] <= SLOW_SPM:
            continue
        if row.speed[i] is None:
            miss += 1
        elif row.speed[i] < SLOW_MS:
            hit += 1
    return hit, miss


def split(row, tr, idx):
    """(wrong, correct) over `idx`, by the truth definition above."""
    wrong = right = 0
    for i in idx:
        if tr[i] is None:
            continue
        dr = abs(row.raw[i] - tr[i])
        da = abs(row.lock[i] - tr[i])
        if dr < da:
            wrong += 1
        elif da < dr:
            right += 1
    return wrong, right


def refusals(row, shipped, out):
    return [i for i in fires(row) if abs(out[i] - shipped[i]) > 1e-9]


def work_laps(row, out):
    """Maximal contiguous runs of step_type == 2. Empty when step_type is
    absent from the recording, which is not the same thing as a row with no
    work in it -- see the fixture's absence note."""
    laps, cur = [], []
    for i in range(len(row)):
        if row.step[i] == 2:
            cur.append(out[i])
        elif cur:
            laps.append(cur)
            cur = []
    if cur:
        laps.append(cur)
    return laps


# ---------------------------------------------------------------------------
# THE COMMANDS.
def cmd_reproduce(rows, args):
    """The check that has to pass before any other figure means anything."""
    total = ok = 0
    for row in rows:
        s = series(row, None)
        good = [i for i in range(len(row)) if abs(s[i] - row.out[i]) <= 1e-4]
        bad = [i for i in range(len(row)) if abs(s[i] - row.out[i]) > 1e-4]
        total += len(row)
        ok += len(good)
        print("%s: the SHIPPED gatedRate replayed from rate_raw / lock_rate / "
              "rate_base reproduces row_stroke_rate on %d of %d records"
              % (row.key, len(good), len(row)))
        for i in bad:
            nxt = ("lock_rate of the next record reproduces it"
                   if i + 1 < len(row)
                   and abs(gated_rate(row.raw[i], period_of(row.lock[i + 1]),
                                      row.base[i]) - row.out[i]) <= 1e-4
                   else "no neighbouring input reproduces it")
            print("    record %d: replayed %.4f, recorded %.4f "
                  "(raw %.4f, lock %.4f) -- %s"
                  % (i, series(row, None)[i], row.out[i], row.raw[i],
                     row.lock[i], nxt))
    print()
    print("TOTAL %d of %d records reproduce (%.2f%%). The residuals are an "
          "UNEXPLAINED RESIDUAL, filed as #194 and NOT attributed here: the "
          "within-tick explanation is ruled out at source, because onTick "
          "writes row_stroke_rate and the diagnostics inside ONE "
          "`mStarted && !mPaused` block. Every figure below is computed from "
          "the REPLAYED series, never the recorded one, so the residual "
          "cannot land on one side of a before/after pair."
          % (ok, total, 100.0 * ok / total))
    return 0


def cmd_sequence(rows, args):
    """The reported sequence, before and after, record by record."""
    row = [r for r in rows if r.key == args.row][0]
    a, b = series(row, None), series(row, args.tol)
    print("%s records %d-%d -- %s" % (row.key, args.start, args.end - 1,
                                      row.label))
    print("%6s %9s %9s %9s %9s %7s %6s %7s"
          % ("record", "recorded", "before", "after", "rate_raw", "lock",
             "ratio", "speed"))
    for i in range(args.start, args.end):
        q = (max(row.raw[i], row.lock[i]) / min(row.raw[i], row.lock[i])
             if row.lock[i] > 0.0 and row.raw[i] > 0.0 else 0.0)
        print("%6d %9.3f %9.3f %9.3f %9.3f %7.3f %6.3f %7s"
              % (i, row.out[i], a[i], b[i], row.raw[i], row.lock[i], q,
                 "-" if row.speed[i] is None else "%.3f" % row.speed[i]))
    return 0


def cmd_score(rows, args):
    """The before/after table every figure in #193's PR body comes from."""
    for row in rows:
        a = series(row, None)
        b = series(row, args.tol)
        tr = truth(row)
        fi = fires(row)
        fw, fc = split(row, tr, fi)
        ref = refusals(row, a, b)
        rw, rc = split(row, tr, ref)
        ga, gb = gross(row, a), gross(row, b)
        sa, sam = slow_boat(row, a)
        sb, sbm = slow_boat(row, b)
        print("=== %s -- %s" % (row.key, row.label))
        print("    %d records; the snap fires on %d of them" % (len(row), len(fi)))
        print("    (a) GROSS DIVERGENCE (output more than %.0fx from rate_raw)"
              % GROSS)
        print("        before %d, after %d -- %d removed (%.1f%%), %d left "
              "(%.1f%%)"
              % (ga, gb, ga - gb, 100.0 * (ga - gb) / max(1, ga), gb,
                 100.0 * gb / max(1, ga)))
        print("    (c) SLOW BOAT (> %.0f spm at < %.1f m/s)" % (SLOW_SPM, SLOW_MS))
        print("        before %d, after %d -- %d removed (%.1f%%), %d left "
              "(%.1f%%). Records reading above %.0f spm whose enhanced_speed "
              "is ABSENT are excluded from both: %d before, %d after"
              % (sa, sb, sa - sb, 100.0 * (sa - sb) / max(1, sa), sb,
                 100.0 * sb / max(1, sa), SLOW_SPM, sam, sbm))
        print("    (e) REFUSAL QUALITY at tol %.2f" % args.tol)
        print("        %d snaps refused: %d the truth calls WRONG, %d CORRECT "
              "(%.2f:1) against a base rate of %d:%d over all %d snaps "
              "(%.2f:1)"
              % (len(ref), rw, rc, rw / max(1, rc), fw, fc, len(fi),
                 fw / max(1, fc)))
        laps_a = work_laps(row, a)
        if not laps_a:
            print("    (d) no step_type in this recording, so it has no work "
                  "laps here and no cue metric is computed for it")
            print()
            continue
        laps_b = work_laps(row, b)
        print("    (d) #149 CUE METRICS on %d work laps, %d seconds, scored by "
              "scripts/cue_replay.py" % (len(laps_a), sum(len(l) for l in laps_a)))
        print("        lap medians before %s"
              % ", ".join("%.1f" % m for m in cue_replay.lap_medians(laps_a)))
        print("        lap medians after  %s"
              % ", ".join("%.1f" % m for m in cue_replay.lap_medians(laps_b)))
        for lo, hi in ((16, 18), (18, 20)):
            print("        target band %d-%d spm  %-15s %11s %10s %10s"
                  % (lo, hi, "", "FALSE-HIGH", "false-low", "flips/min"))
            for name, laps in (("before", laps_a), ("after", laps_b)):
                for sname, fn in (("raw", cue_replay.zones_raw),
                                  ("cueStep", cue_replay.zones_cue)):
                    sc = cue_replay.score(laps, lo, hi, fn)
                    print("                              %-6s %-8s %10.1f%% "
                          "%9.1f%% %10.2f"
                          % (name, sname, sc["false_high"], sc["false_low"],
                             sc["flips_per_min"]))
        print()
    print("The target band is NOT recorded in the FIT (#191), so the two bands "
          "above are a SCORING CHOICE: they are the two #149 published against, "
          "quoted so the definitions match. Neither is this row's actual band.")
    return 0


def cmd_sweep(rows, args):
    """The tolerance sweep the chosen value is argued from."""
    for row in rows:
        a = series(row, None)
        tr = truth(row)
        fi = fires(row)
        fw, fc = split(row, tr, fi)
        print("=== %s: %d snaps, base rate %d wrong : %d correct (%.2f:1)"
              % (row.key, len(fi), fw, fc, fw / max(1, fc)))
        print("    %-6s %8s %9s %11s %8s %8s %8s"
              % ("tol", "refused", "refWRONG", "refCORRECT", "ratio",
                 "(a)gross", "(c)slow"))
        print("    %-6s %8d %9s %11s %8s %8d %8d"
              % ("--", 0, "-", "-", "-", gross(row, a), slow_boat(row, a)[0]))
        for tol in args.tols:
            b = series(row, tol)
            ref = refusals(row, a, b)
            rw, rc = split(row, tr, ref)
            print("    %-6.2f %8d %9d %11d %8.2f %8d %8d"
                  % (tol, len(ref), rw, rc, rw / max(1, rc), gross(row, b),
                     slow_boat(row, b)[0]))
        print()
    print("THE CHOICE. LOCK_HARM_TOL = %.2f." % LOCK_HARM_TOL)
    print("  LOWER BOUND, measured. The two records the defect was reported "
          "from sit at ratios 2.901 and 3.200, which need 0.033 and 0.067. "
          "Anything under 0.067 leaves the reported sequence unfixed.")
    print("  UPPER BOUND, structural. The band around 2 and the band around 3 "
          "must stay disjoint, which needs tol < 0.20. At 0.10 they are "
          "[1.80, 2.20] and [2.70, 3.30], and the snap still FIRES on 401 of "
          "643, 245 of 356 and 124 of 175 disagreements of the three rows "
          "(62%, 69%, 71%) -- the guard NARROWS the snap; it is not "
          "deleting it.")
    print("  INSIDE THAT INTERVAL, what the sweep does and does NOT show.")
    print("    The reported row's refusal quality is FLAT at 6.0-6.4:1 across "
          "0.08-0.12, against its 4.02:1 base rate, with its argmax at 0.11.")
    print("    That selectivity does NOT reproduce on the hold-outs. Hold-out "
          "A is BELOW its own 3.56:1 base rate at every tolerance swept -- "
          "2.36:1 at 0.10 -- so on that row the guard's refusals are WORSE "
          "than refusing at random. Hold-out B is above its 2.57:1 base rate "
          "from 0.04 to 0.11 but only just at 0.10 (2.64:1), and below it "
          "from 0.12 on. Three rows, three different answers: strong, "
          "negative, and a margin too small to call.")
    print("    What DOES reproduce on all three is the gross-divergence "
          "reduction: -46%, -37% and -36% at 0.10, non-increasing in tol "
          "on every row.")
    print("  So 0.10 is a ROUND NUMBER IN THE PLATEAU, not the reported row's "
          "argmax of 0.11: fitting a third digit to one recording is not a "
          "measurement, and the hold-outs do not corroborate the peak. The "
          "figure is a SINGLE-ROW FIT -- one hold-out contradicts its "
          "selectivity and the other is too close to call -- and it is "
          "published as such rather than as a validated constant. What is "
          "NOT single-row is the direction: all three rows lose gross "
          "divergences at every tolerance swept.")
    return 0


def cmd_selftest(rows, args):
    """Vectors that must hold for the transcription to be worth reading.

    The same vectors source/LockGuardTest.mc asserts against the shipping
    Monkey C. scripts/test_lock_snap_replay.py is the full suite; this is the
    subset a reader running the tool gets for free.
    """
    fails = []

    def eq(got, want, what):
        if abs(got - want) > 5e-4:
            fails.append("%s: got %r, want %r" % (what, got, want))

    # The shipped rule.
    eq(gated_rate(29.9, 0.0, 0.0), 29.9, "no lock, 29.9 at the absolute gate")
    eq(gated_rate(30.1, 0.0, 0.0), 0.0, "no lock, 30.1 over the absolute gate")
    eq(gated_rate(25.9, 3.0, 0.0), 25.9, "20 spm lock, 25.9 inside the snap")
    eq(gated_rate(26.1, 3.0, 0.0), 20.0, "20 spm lock, 26.1 outside it")
    eq(gated_rate(45.0, 1.5, 0.0), 40.0, "MAX_RATE clamp through the lock arm")
    eq(gated_rate(0.0, 3.0, 0.0), 0.0, "a zero median is not filled in")
    # The shipped rule at a harmonic -- the defect.
    eq(gated_rate(18.518518, 9.4, 19.2), 60.0 / 9.4, "shipped: subharmonic")
    eq(gated_rate(10.416667, 1.8, 19.2), 60.0 / 1.8, "shipped: harmonic")
    # The guard.
    eq(gated_rate(18.518518, 9.4, 19.2, LOCK_HARM_TOL), 18.518518,
       "guarded: subharmonic refused")
    eq(gated_rate(10.416667, 1.8, 19.2, LOCK_HARM_TOL), 10.416667,
       "guarded: harmonic refused")
    eq(gated_rate(28.0, 3.0, 0.0, LOCK_HARM_TOL), 20.0,
       "guarded: #10's 1.40 surge still snaps")
    eq(gated_rate(10.416667, 9.4, 19.2, LOCK_HARM_TOL), 60.0 / 9.4,
       "guarded: a 1.632 disagreement still snaps")
    eq(gated_rate(36.5, 3.0, 0.0, LOCK_HARM_TOL), 36.5,
       "guarded: ratio 1.825 is inside the band")
    eq(gated_rate(34.0, 3.0, 0.0, LOCK_HARM_TOL), 20.0,
       "guarded: ratio 1.70 is outside it")
    eq(gated_rate(20.0 / 3.1, 3.0, 0.0, LOCK_HARM_TOL), 20.0 / 3.1,
       "guarded: ratio 3.10 is inside the band")
    eq(gated_rate(20.0 / 3.45, 3.0, 0.0, LOCK_HARM_TOL), 20.0,
       "guarded: ratio 3.45 is outside it")
    # The fixtures load and stay aligned.
    if len(rows) != 3:
        fails.append("expected 3 rows in the fixtures, got %d" % len(rows))
    for row in rows:
        s = series(row, None)
        ok = sum(1 for i in range(len(row)) if abs(s[i] - row.out[i]) <= 1e-4)
        if ok < len(row) - 5:
            fails.append("%s reproduces only %d of %d" % (row.key, ok, len(row)))
    for f in fails:
        print("FAIL " + f)
    print("selftest: %d checks, %d failed" % (17 + len(rows), len(fails)))
    return 1 if fails else 0


def main(argv):
    p = argparse.ArgumentParser(
        description=__doc__.split("\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--records", default=RECORDS)
    p.add_argument("--context", default=CONTEXT)
    sub = p.add_subparsers(dest="cmd")

    sub.add_parser("reproduce", help="prove the transcription first")
    s = sub.add_parser("score", help="the before/after table")
    s.add_argument("--tol", type=float, default=LOCK_HARM_TOL)
    s = sub.add_parser("sweep", help="the tolerance sweep")
    s.add_argument("--tols", type=float, nargs="+",
                   default=[0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.10, 0.11,
                            0.12, 0.13, 0.15, 0.20])
    s = sub.add_parser("sequence", help="one record range, before and after")
    s.add_argument("--row", default="i183553852")
    s.add_argument("--start", type=int, default=2486)
    s.add_argument("--end", type=int, default=2506)
    s.add_argument("--tol", type=float, default=LOCK_HARM_TOL)
    sub.add_parser("selftest", help="the vectors, no fixtures needed to read")

    args = p.parse_args(argv)
    rows = load(args.records, args.context)
    if args.cmd is None:
        rc = 0
        for name, fn, extra in (("reproduce", cmd_reproduce, {}),
                                ("sequence", cmd_sequence,
                                 {"row": "i183553852", "start": 2486,
                                  "end": 2506, "tol": LOCK_HARM_TOL}),
                                ("score", cmd_score, {"tol": LOCK_HARM_TOL}),
                                ("sweep", cmd_sweep,
                                 {"tols": [0.04, 0.05, 0.06, 0.07, 0.08, 0.09,
                                           0.10, 0.11, 0.12, 0.13, 0.15,
                                           0.20]}),
                                ("selftest", cmd_selftest, {})):
            print("#" * 74)
            print("# " + name)
            print("#" * 74)
            ns = argparse.Namespace(**extra)
            rc |= fn(rows, ns)
            print()
        return rc
    return {"reproduce": cmd_reproduce, "score": cmd_score, "sweep": cmd_sweep,
            "sequence": cmd_sequence, "selftest": cmd_selftest}[args.cmd](
                rows, args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
