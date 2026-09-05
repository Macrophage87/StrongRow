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

  * the three functions in THE TRANSCRIPTION below are transcribed line for
    line with the Monkey C they mirror quoted beside them
    (source/StrongRowView.mc, fastGate / gatedRate / harmonicOfLock), and the
    tunable beside them carries the value of the const it mirrors;
  * scripts/test_lock_snap_replay.py re-asserts, against THIS transcription,
    the same numeric vectors source/LockGuardTest.mc asserts against the
    shipping Monkey C. Editing either side alone reds one of the two suites.

It is not a proof of equivalence -- two implementations agreeing on a finite
vector set agree on that set. And it says nothing about what a watch displays:
it is a decision function fed recorded numbers.

TWO TRUTHS, AND THE BODY MUST SAY WHICH IS WHICH.

  * THE WITNESS (primary, since round 1 of #196). The FIT native `cadence`
    field, a SECOND DETECTOR present in all three recordings, independent of
    both candidates the snap chooses between. See
    scripts/fixtures/lock_snap_witness.txt for what it is, what it is not, and
    how it is calibrated. Every selectivity figure is graded against it.

  * THE 31 s CENTRED MEDIAN OF `rate_raw` (secondary, and BIASED). Kept and
    still printed, because round 1 published from it and a figure that quietly
    stops being regenerable is the defect this file exists to stop. It is
    BUILT FROM `raw`, which is one of the two parties to the dispute it is
    asked to referee, so it systematically favours `raw` and therefore
    systematically flatters a rule whose action is "publish `raw`". Measured:
    it calls the shipped snap wrong 4.02 / 3.56 / 2.57 times as often as right;
    the independent counter says 1.62:1 pooled. It also cannot see a `raw`
    error sustained for 31 s at all -- the case where the median and the lock
    are wrong TOGETHER, which is #149's and not this file's.

  RETRACTION (round 1). An earlier revision of this docstring called the 31 s
  median "the strongest one available". That was false: the native cadence
  field and the per-lap total_cycles were in the same three files the whole
  time, and no committed thing had looked at them. Retracted here rather than
  edited away; scripts/check_source_refs.py exists because a comment named a
  guard nobody wrote, and a falsifiable superlative is the same class.

WHAT NEITHER TRUTH SETTLES:

  * A recording tells you what a decoder read out of a file some firmware
    wrote. It does not tell you what this app's setData calls produced.
  * Metric (a), the record count where the output differs from `rate_raw` by
    more than 2x, is an AGREEMENT metric and not a correctness metric. Any
    rule whose action is "publish `rate_raw`" reduces it by construction. It
    bounds REACH, never quality, and nothing here ranks two rules by it.
"""

import argparse
import math
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

# Mirrors the module-scope const $.LOCK_HARM_TOL. The value is argued in THE
# SWEEP below, and is MEASURED rather than chosen.
#
# RETRACTION, this branch, c2c. An earlier revision of this line said the
# Monkey C side had to be a class static because "a file-scope const costs a
# fenix6 `globals` member, and the headroom is four". That is FALSE, and the
# refutation was already in the tree when it was written: the measured ceiling
# note at scripts/list_tests.py:78-87 states "Every file-scope (:test), helper
# function and test class costs one member; A MODULE-SCOPE CONST COSTS NONE
# (it is inlined)", and source/StrongRowView.mc:119-138 moved four consts to
# module scope for exactly that reason. So the shipping side is a plain const
# beside MIN_RATE / MAX_RATE / LOCK_SNAP_K / FAST_NEEDS_LOCK, as this file's
# other tunables are.
LOCK_HARM_TOL = 0.10

# WHICH INTEGER RATIOS THE GUARD REFUSES. Round 1 of #196 shipped both 2 and 3;
# the round-1 review scored them separately against the independent witness
# below and found 40:8 for the 2:1 band (p=0.00003, robust across the whole
# +-25% calibration sweep) against 10:16 for the 3:1 band (p=0.33, adverse
# point estimate). BANDS is the rule that ships; BANDS_R1 is kept so the
# superseded epoch stays replayable and every figure this branch has published
# can still be regenerated rather than becoming unreproducible history.
BANDS = (2.0,)
BANDS_R1 = (2.0, 3.0)


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


def harmonic_of_lock(raw, ac, tol=LOCK_HARM_TOL, bands=BANDS):
    """Mirrors StrongRowView.harmonicOfLock -- #193's guard predicate.

    True when `raw` and the lock stand in a near-integer ratio, from `bands`,
    in EITHER direction. `q` is max/min, so a harmonic (raw is the double) and
    a subharmonic (the lock is the double) are one comparison and one tolerance
    rather than four cases with four chances to be asymmetric.

    `bands` exists so BOTH epochs of this branch stay replayable from one
    transcription: BANDS is what ships, BANDS_R1 is what round 1 shipped. The
    Monkey C has no such parameter -- it hard-codes the shipping set, and which
    set that is on any given commit is pinned by source/LockGuardTest.mc, not
    by this file.
    """
    if raw is None or ac is None or raw <= 0.0 or ac <= 0.0:
        return False
    q = raw / ac if raw > ac else ac / raw
    for n in bands:
        d = q - n
        if d < 0.0:
            d = -d
        if d <= tol * n:
            return True
    return False


def gated_rate(raw, ac_period, base, tol=None, bands=BANDS):
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
                if tol is None or not harmonic_of_lock(r, ac, tol, bands):
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
WITNESS = os.path.join(HERE, "fixtures", "lock_snap_witness.txt")


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
        self.cad = []          # the watch's own counter, integer spm; 0 is real
        self.laps = []         # (index, lap_step_type, total_cycles, seconds)

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


def _parse_witness(path):
    """Returns [(key, [cad, ...], [lap, ...]), ...] in file order."""
    rows = []
    with open(path, "r") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            head, _, rest = line.partition(" ")
            if head == "ROW":
                key, _, _label = rest.partition(" ")
                rows.append((key, [], []))
            elif head == "CAD":
                if not rows:
                    raise ValueError("CAD before any ROW in " + path)
                rows[-1][1].append(None if rest.strip() == "-"
                                   else float(rest))
            elif head == "LAP":
                if not rows:
                    raise ValueError("LAP before any ROW in " + path)
                p = rest.split()
                if len(p) != 4:
                    raise ValueError("%s: LAP line with %d fields, expected 4"
                                     % (path, len(p)))
                rows[-1][2].append((int(p[0]),
                                    None if p[1] == "-" else int(p[1]),
                                    None if p[2] == "-" else int(p[2]),
                                    None if p[3] == "-" else float(p[3])))
            else:
                raise ValueError("unrecognised line in %s: %s" % (path, line))
    return rows


def load(records=RECORDS, context=CONTEXT, witness=WITNESS):
    """The two fixtures zipped, with alignment CHECKED rather than assumed.

    speed_witness.py's rows() takes the same precaution and states the reason:
    a best-effort pairing of a rate with a selector from a different moment is
    worse than a refusal, because it produces a number that looks fine.
    """
    recs = _parse(records, "REC", 4)
    ctxs = _parse(context, "CTX", 2)
    wits = _parse_witness(witness)
    if not (len(recs) == len(ctxs) == len(wits)):
        raise ValueError("fixtures disagree on the number of rows: %d, %d, %d"
                         % (len(recs), len(ctxs), len(wits)))
    out = []
    for (rk, rl, rv), (ck, _cl, cv), (wk, wv, wl) in zip(recs, ctxs, wits):
        if not (rk == ck == wk):
            raise ValueError("fixtures disagree on row order: %s, %s, %s"
                             % (rk, ck, wk))
        if len(rv) != len(cv):
            raise ValueError("row %s: %d REC lines but %d CTX lines"
                             % (rk, len(rv), len(cv)))
        if len(rv) != len(wv):
            raise ValueError("row %s: %d REC lines but %d CAD lines"
                             % (rk, len(rv), len(wv)))
        row = Row(rk, rl)
        for a, b in zip(rv, cv):
            row.raw.append(float(a[0]))
            row.lock.append(float(a[1]))
            row.base.append(float(a[2]))
            row.out.append(float(a[3]))
            row.step.append(None if b[0] == "-" else int(b[0]))
            row.speed.append(None if b[1] == "-" else float(b[1]))
        row.cad = list(wv)
        row.laps = list(wl)
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
#   GROSS DIVERGENCE    is an AGREEMENT metric. It falls by construction for
#                       any rule that publishes `rate_raw`, so it bounds how
#                       much divergence a guard REACHES and cannot rank two
#                       guards. It is reported first because it is the
#                       athlete-visible quantity, not because it is the score.
#   TRUTH (secondary)   a 31 s CENTRED MEDIAN of the non-zero `rate_raw`
#                       around the record (>= 5 samples, else undefined). The
#                       same definition cue_replay.py uses -- and BIASED here,
#                       because `raw` is one of the two parties to the dispute.
#                       Retained only so round 1's published figures stay
#                       regenerable.
#   REFUSAL QUALITY     of the snaps a guard refuses, how many the witness says
#                       were WRONG (raw nearer the witness than the lock) and
#                       how many RIGHT (lock nearer), in RATIO space. Reported
#                       against the BASE RATE, the same split over ALL snaps: a
#                       guard that refuses at the base rate is refusing at
#                       random and has only traded one error for another.
TRUTH_WIN = 31
TRUTH_MIN_SAMPLES = 5
SLOW_SPM = 25.0
SLOW_MS = 0.3
GROSS = 2.0


def series(row, tol, bands=BANDS):
    return [gated_rate(row.raw[i], period_of(row.lock[i]), row.base[i], tol,
                       bands)
            for i in range(len(row))]


# ---------------------------------------------------------------------------
# THE INDEPENDENT WITNESS (#196 round 1).
#
#   k                 one scalar per row, median(cadence / rate_raw) over the
#                     records where the snap does NOT fire and both are
#                     non-zero. The native counter counts BLADE MOVEMENTS, not
#                     drives (source/StrongRowView.mc:710-712), so it is right
#                     in RATIO and wrong in LEVEL; k removes the level.
#   the decision      made in RATIO SPACE: the snap was RIGHT when the lock is
#                     nearer cadence/k than `raw` is, measured as
#                     |log(candidate / witness)|. Absolute spm is the WRONG
#                     space here and it is not a stylistic preference: the two
#                     candidates differ by a factor, so the point at which the
#                     verdict flips is their GEOMETRIC mean, and an
#                     absolute-difference rule puts it at their arithmetic
#                     mean instead. Measured, on the 3:1 band of these three
#                     rows: absolute distance gives 14:12 and ratio distance
#                     gives 10:16, on the identical 26 records.
#   scored records    only those with cadence > 0. A counter reading zero
#                     cannot say which of two non-zero candidates is right, and
#                     scoring it as "0 spm was rowed" would be absence rendered
#                     as a value. The skipped count is reported beside every
#                     figure, and it is large: contested records cluster where
#                     little is being rowed, which is exactly where this
#                     witness is absent.
#   the base rate     the same wrong:right split over ALL snaps. A guard whose
#                     refusals sit at the base rate is refusing at random.
K_SWEEP = (0.75, 0.90, 1.00, 1.10, 1.25)


def witness_scale(row):
    """k for one row, or None when nothing scores."""
    fired = set(fires(row))
    v = [row.cad[i] / row.raw[i] for i in range(len(row))
         if i not in fired and row.raw[i] > 0.0
         and row.cad[i] is not None and row.cad[i] > 0.0]
    return statistics.median(v) if v else None


def witness_split(row, idx, k):
    """(snap-was-WRONG, snap-was-RIGHT, skipped) over `idx`, in ratio space."""
    wrong = right = skipped = 0
    for i in idx:
        c = row.cad[i]
        if c is None or c <= 0.0 or row.raw[i] <= 0.0 or row.lock[i] <= 0.0:
            skipped += 1
            continue
        w = c / k
        dr = abs(math.log(row.raw[i] / w))
        da = abs(math.log(row.lock[i] / w))
        if dr < da:
            wrong += 1
        elif da < dr:
            right += 1
        else:
            skipped += 1
    return wrong, right, skipped


def band_of(row, i, tol=LOCK_HARM_TOL):
    """Which integer band a record's ratio falls in, or None."""
    raw, ac = row.raw[i], row.lock[i]
    if raw <= 0.0 or ac <= 0.0:
        return None
    q = raw / ac if raw > ac else ac / raw
    for n in (2.0, 3.0):
        if abs(q - n) <= tol * n:
            return int(n)
    return None


def binom_p(w, r):
    """Two-sided exact binomial against 0.5. Serial correlation between
    adjacent seconds is real and unmodelled, so this OVERSTATES significance;
    it is here to separate 40:8 from 10:16, not to certify either."""
    n = w + r
    if n == 0:
        return float("nan")
    obs = max(w, r)
    tail = sum(math.comb(n, i) for i in range(obs, n + 1)) / 2.0 ** n
    return min(1.0, 2.0 * tail)


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


def second_order(row, shipped, out):
    """(changed, up, no_lock, near_gate) -- the exposure this replay CANNOT see.

    THE LIMITATION THIS QUANTIFIES. gatedRate is pure, so the guard's decision
    on a record depends on nothing but that record's three inputs, and the
    replay is exact for it. But `rate_base` is a RECURSION: nextRateBase folds
    in what the output stage PUBLISHED, so on a live watch a refused snap feeds
    a different baseline forward, and the baseline sets fastGate on later
    strokes. This replay uses the RECORDED rate_base -- the one the unguarded
    code produced -- so every figure here is FIRST-ORDER.

    It cannot be closed offline. nextRateBase runs once per STROKE, from
    registerStroke, and this fixture is per RECORD (about three records per
    stroke at these cadences), so iterating the recursion here would be
    replaying a machine that never ran -- the exact trap scripts/cue_replay.py
    exists because of.

    What CAN be bounded is the exposure, and it is small: rate_base is read
    only by fastGate, which gatedRate consults only on the NO-LOCK arm, and
    only records whose median sits near their own gate could flip if the
    baseline moved. #199 is the field check.
    """
    n = len(row)
    changed = [i for i in range(n) if abs(shipped[i] - out[i]) > 1e-9]
    up = sum(1 for i in changed if out[i] > shipped[i])
    no_lock = [i for i in range(n) if row.lock[i] <= 0.0 and row.raw[i] > 0.0]
    near = sum(1 for i in no_lock
               if abs(row.raw[i] - fast_gate(row.base[i]))
               <= 0.20 * fast_gate(row.base[i]))
    return len(changed), up, len(no_lock), near


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
    a, b = series(row, None), series(row, args.tol, args.bands)
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
        b = series(row, args.tol, args.bands)
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
        print("    (a) GROSS DIVERGENCE (output more than %.0fx from "
              "rate_raw) -- an AGREEMENT metric, minimised by construction by "
              "any rule that publishes rate_raw. It bounds REACH, not quality."
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
        k = witness_scale(row)
        bw, br, bs = witness_split(row, fi, k)
        rrw, rrr, rrs = witness_split(row, ref, k)
        print("    (e) REFUSAL QUALITY at tol %.2f, bands %s -- graded against "
              "the INDEPENDENT witness (k = %.3f)"
              % (args.tol, "/".join("%g" % x for x in args.bands), k))
        print("        %d snaps refused. Witness: %d WRONG : %d RIGHT (%.2f:1)"
              " against a base rate of %d:%d over all %d snaps (%.2f:1). "
              "%d of the refusals and %d of the snaps score on no witness "
              "(cadence 0)."
              % (len(ref), rrw, rrr, rrw / max(1, rrr), bw, br, len(fi),
                 bw / max(1, br), rrs, bs))
        for n in (2, 3):
            idx = [i for i in ref if band_of(row, i) == n]
            if not idx:
                continue
            w, r, sk = witness_split(row, idx, k)
            print("          the %d:1 band alone: %d refusals, witness %d:%d "
                  "(%.2f:1), %d unscored" % (n, len(idx), w, r,
                                             w / max(1, r), sk))
        print("        SECONDARY, and BIASED toward raw: the 31 s centred "
              "median of raw calls the same refusals %d WRONG : %d CORRECT "
              "(%.2f:1) against its own base rate %d:%d (%.2f:1). It is built "
              "from raw, which is one of the two parties."
              % (rw, rc, rw / max(1, rc), fw, fc, fw / max(1, fc)))
        ch, up, nl, near = second_order(row, a, b)
        print("    (f) SECOND-ORDER EXPOSURE -- what this replay cannot see")
        print("        the guard moves the published value on %d records, %d "
              "UP and %d down. rate_base is a recursion over what was "
              "published and this replay uses the RECORDED one, so every "
              "figure above is FIRST-ORDER." % (ch, up, ch - up))
        print("        the exposure is bounded: rate_base is read only by "
              "fastGate, which gatedRate consults only on the NO-LOCK arm -- "
              "%d records, %.1f%% -- and only %d of them (%.1f%% of all "
              "records) sit within 20%% of their own gate, where a moved "
              "baseline could flip the decision. #199 is the field check."
              % (nl, 100.0 * nl / len(row), near, 100.0 * near / len(row)))
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


def cmd_witness(rows, args):
    """The band split against the independent counter, and the k sweep.

    THIS IS THE COMMAND THE BAND SET IS ARGUED FROM. Round 1 of #196 shipped
    the 2:1 and 3:1 bands together on the strength of a raw-derived truth that
    could not tell them apart. This one can.
    """
    print("Every figure below grades a SNAP against the watch's own counter, "
          "in ratio space, per scripts/fixtures/lock_snap_witness.txt.")
    print("WRONG means the median was nearer the witness (so the snap "
          "discarded the better candidate); RIGHT means the lock was.")
    print()
    for mult in K_SWEEP:
        tot = {}
        for key in ("all", "ref", 2, 3):
            tot[key] = [0, 0, 0]
        for row in rows:
            k = witness_scale(row) * mult
            a = series(row, None)
            b = series(row, LOCK_HARM_TOL, BANDS_R1)
            fi = fires(row)
            ref = refusals(row, a, b)
            groups = {"all": fi, "ref": ref,
                      2: [i for i in ref if band_of(row, i) == 2],
                      3: [i for i in ref if band_of(row, i) == 3]}
            for key, idx in groups.items():
                w, r, sk = witness_split(row, idx, k)
                tot[key][0] += w
                tot[key][1] += r
                tot[key][2] += sk
        line = "k x %.2f " % mult
        for key, lab in (("all", "all snaps"), ("ref", "refused"),
                         (2, "2:1 band"), (3, "3:1 band")):
            w, r, _ = tot[key]
            line += "  %s %d:%d" % (lab, w, r)
        print(line)
        if mult == 1.00:
            keep = dict(tot)
    print()
    print("At k x 1.00, with exact two-sided binomial p against 0.5:")
    for key, lab in (("all", "all snaps (the base rate)"),
                     ("ref", "what round 1's guard refuses"),
                     (2, "  ... of those, the 2:1 band"),
                     (3, "  ... of those, the 3:1 band")):
        w, r, sk = keep[key]
        print("   %-32s %3d : %-3d  %5.2f:1  p=%.5f  (%d unscored, cadence 0)"
              % (lab, w, r, w / max(1, r), binom_p(w, r), sk))
    print()
    print("PER ROW, at k x 1.00:")
    for row in rows:
        k = witness_scale(row)
        a = series(row, None)
        b = series(row, LOCK_HARM_TOL, BANDS_R1)
        ref = refusals(row, a, b)
        parts = []
        for n in (2, 3):
            idx = [i for i in ref if band_of(row, i) == n]
            w, r, _ = witness_split(row, idx, k)
            parts.append("%d:1 band %d:%d" % (n, w, r))
        w, r, _ = witness_split(row, fires(row), k)
        print("   %-12s k=%.3f  base %d:%d   %s"
              % (row.key, k, w, r, "   ".join(parts)))
    print()
    print("WORK SECONDS ONLY (step_type 2), the regime the 38-vs-20 question "
          "is about:")
    for row in rows:
        if not any(v == 2 for v in row.step):
            print("   %-12s no step_type in this recording" % row.key)
            continue
        k = witness_scale(row)
        a = series(row, None)
        b = series(row, LOCK_HARM_TOL, BANDS_R1)
        ref = refusals(row, a, b)
        work = [i for i in ref if row.step[i] == 2]
        w2 = [i for i in work if band_of(row, i) == 2]
        ww, wr, _ = witness_split(row, work, k)
        b2w, b2r, _ = witness_split(row, w2, k)
        print("   %-12s %d of %d refusals are on work seconds; witness %d:%d "
              "over all of them, %d:%d in the 2:1 band alone"
              % (row.key, len(work), len(ref), ww, wr, b2w, b2r))
    print()
    print("THE CONCLUSION THIS COMMAND EXISTS TO SUPPORT. The 2:1 band and the "
          "3:1 band are not the same finding and must not ship as though they "
          "were. The 2:1 split holds its direction and its significance at "
          "EVERY k in the sweep; the 3:1 split does not reach significance at "
          "any of them and its point estimate is adverse at k x 1.00. n is "
          "small (48 and 26 scored records pooled) and the p-values ignore the "
          "serial correlation between adjacent seconds, which is certainly "
          "present and inflates them -- so the defensible statement is not "
          "'the 3:1 band is harmful' but 'the 3:1 band has no support while "
          "the 2:1 band's support is strong and calibration-robust'.")
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
            b = series(row, tol, args.bands)
            ref = refusals(row, a, b)
            rw, rc = split(row, tr, ref)
            print("    %-6.2f %8d %9d %11d %8.2f %8d %8d"
                  % (tol, len(ref), rw, rc, rw / max(1, rc), gross(row, b),
                     slow_boat(row, b)[0]))
        print()
    print("READ THIS TABLE WITH `witness` BESIDE IT. The (a) column is an "
          "AGREEMENT metric and falls monotonically as the tolerance widens "
          "for any rule that publishes rate_raw, so on its own it argues for "
          "the widest band anyone will accept. The refWRONG:refCORRECT column "
          "is the SECONDARY, raw-derived truth and is biased the same way. "
          "The band set was NOT chosen from either -- see `witness`.")
    print()
    print("THE CHOICE. LOCK_HARM_TOL = %.2f, bands %s."
          % (LOCK_HARM_TOL, "/".join("%g" % x for x in BANDS)))
    print("  THE BAND SET, decided by the independent witness. Round 1 "
          "refused both a near-2:1 and a near-3:1 ratio. Scored against the "
          "watch's own counter the two are not the same finding: the 2:1 band "
          "is 40 wrong-snaps to 8 right (p=0.00003) and holds its direction "
          "at every k in the +-25%% sweep; the 3:1 band is 10 to 16 (p=0.33) "
          "and reaches significance at none of them. The 3:1 band is dropped. "
          "Run `witness` for the table.")
    print("  LOWER BOUND on the tolerance, measured. At 0.10 the 2:1 band is "
          "[1.80, 2.20]. A textbook double-count sits at exactly 2.00 and the "
          "38-against-20 pair at 1.90, so the band must be at least 0.05 wide "
          "to catch what it exists for.")
    print("  UPPER BOUND, structural. The 2:1 band must not reach the snap "
          "threshold itself, which fires from a ratio of 1.30; at 0.10 the "
          "band's lower edge is 1.80, half a ratio clear of it. With the 3:1 "
          "band gone the disjointness constraint that capped the tolerance at "
          "0.20 no longer binds, and the tolerance is NOT re-widened to take "
          "advantage: nothing measured supports a wider one.")
    print("  WHY NOT NARROWER. Round 1 asked whether 0.05 was safer. It is "
          "not: pooled against the witness, tol 0.05 scores 23:15 (p=0.26) "
          "against 50:24 at 0.10, and on hold-out B every scored change is "
          "wrong. Narrowing made it worse, measured.")
    print("  WHAT IS STILL A SINGLE-ROW FIT. The third digit. 0.10 is a round "
          "number, not an argmax, and no attempt is made to defend 0.10 over "
          "0.09 or 0.11 -- the witness has 48 scored records in this band "
          "pooled across three rows and cannot resolve that. What the witness "
          "DOES support, on all three rows and at every calibration, is the "
          "2:1 band's direction. #199 is the field check.")
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
    # The guard, at the SHIPPING band set -- 2:1 only.
    eq(gated_rate(38.0, 3.0, 0.0, LOCK_HARM_TOL), 38.0,
       "guarded: the 1.90 ratio is refused")
    eq(gated_rate(18.518518, 9.4, 19.2, LOCK_HARM_TOL), 60.0 / 9.4,
       "guarded: the 2.901 subharmonic STILL snaps (no 3:1 band)")
    eq(gated_rate(10.416667, 1.8, 19.2, LOCK_HARM_TOL), 60.0 / 1.8,
       "guarded: the 3.200 harmonic STILL snaps (no 3:1 band)")
    # And under ROUND 1's band set, which this branch superseded.
    eq(gated_rate(18.518518, 9.4, 19.2, LOCK_HARM_TOL, BANDS_R1), 18.518518,
       "round 1's bands: the 2.901 subharmonic was refused")
    eq(gated_rate(10.416667, 1.8, 19.2, LOCK_HARM_TOL, BANDS_R1), 10.416667,
       "round 1's bands: the 3.200 harmonic was refused")
    eq(gated_rate(28.0, 3.0, 0.0, LOCK_HARM_TOL), 20.0,
       "guarded: #10's 1.40 surge still snaps")
    eq(gated_rate(10.416667, 9.4, 19.2, LOCK_HARM_TOL), 60.0 / 9.4,
       "guarded: a 1.632 disagreement still snaps")
    eq(gated_rate(36.5, 3.0, 0.0, LOCK_HARM_TOL), 36.5,
       "guarded: ratio 1.825 is inside the band")
    eq(gated_rate(34.0, 3.0, 0.0, LOCK_HARM_TOL), 20.0,
       "guarded: ratio 1.70 is outside it")
    eq(gated_rate(20.0 / 3.1, 3.0, 0.0, LOCK_HARM_TOL), 20.0,
       "guarded: ratio 3.10 snaps -- there is no 3:1 band")
    eq(gated_rate(20.0 / 3.45, 3.0, 0.0, LOCK_HARM_TOL), 20.0,
       "guarded: ratio 3.45 snaps in either band set")
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
    print("selftest: %d checks, %d failed" % (22 + len(rows), len(fails)))
    return 1 if fails else 0


def main(argv):
    p = argparse.ArgumentParser(
        description=__doc__.split("\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--records", default=RECORDS)
    p.add_argument("--context", default=CONTEXT)
    sub = p.add_subparsers(dest="cmd")

    p.add_argument("--witness", default=WITNESS)
    sub.add_parser("reproduce", help="prove the transcription first")
    sub.add_parser("witness", help="the band split against the watch counter")
    s = sub.add_parser("score", help="the before/after table")
    s.add_argument("--tol", type=float, default=LOCK_HARM_TOL)
    s.add_argument("--bands", type=float, nargs="+", default=list(BANDS))
    s = sub.add_parser("sweep", help="the tolerance sweep")
    s.add_argument("--bands", type=float, nargs="+", default=list(BANDS))
    s.add_argument("--tols", type=float, nargs="+",
                   default=[0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.10, 0.11,
                            0.12, 0.13, 0.15, 0.20])
    s = sub.add_parser("sequence", help="one record range, before and after")
    s.add_argument("--row", default="i183553852")
    s.add_argument("--start", type=int, default=2486)
    s.add_argument("--end", type=int, default=2506)
    s.add_argument("--tol", type=float, default=LOCK_HARM_TOL)
    s.add_argument("--bands", type=float, nargs="+", default=list(BANDS))
    sub.add_parser("selftest", help="the vectors, no fixtures needed to read")

    args = p.parse_args(argv)
    rows = load(args.records, args.context, args.witness)
    if args.cmd is None:
        rc = 0
        for name, fn, extra in (("reproduce", cmd_reproduce, {}),
                                ("witness", cmd_witness, {}),
                                ("sequence", cmd_sequence,
                                 {"row": "i183553852", "start": 2486,
                                  "end": 2506, "tol": LOCK_HARM_TOL,
                                  "bands": list(BANDS)}),
                                ("score", cmd_score,
                                 {"tol": LOCK_HARM_TOL,
                                  "bands": list(BANDS)}),
                                ("sweep", cmd_sweep,
                                 {"bands": list(BANDS),
                                  "tols": [0.04, 0.05, 0.06, 0.07, 0.08, 0.09,
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
    return {"reproduce": cmd_reproduce, "score": cmd_score,
            "sweep": cmd_sweep, "sequence": cmd_sequence,
            "witness": cmd_witness, "selftest": cmd_selftest}[args.cmd](
                rows, args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
