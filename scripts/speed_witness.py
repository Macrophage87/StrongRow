#!/usr/bin/env python3
"""Re-derive the INDEPENDENT-WITNESS figure #149 rests its recorded-value change on.

    python3 scripts/speed_witness.py

WHY THIS FILE EXISTS. source/StrongRowView.mc's output-stage block says, in the
paragraph that grants permission to change a RECORDED value, that the over-read
seconds are real detector errors because the hull SLOWS across them -- and
quoted two ratios for it. Nothing in the repository could regenerate those two
numbers: scripts/fixtures/cue_work_laps.txt carries per-second row_stroke_rate
and says so in its own header ("NOTHING BUT STROKE RATE IS HERE"), and
scripts/cue_replay.py has no speed path. That is the same trap -- a figure
nobody can regenerate -- that cue_work_laps.txt was created to close.

RETRACTION, stated here and at the quotation site rather than edited away. The
figures previously published were 0.851x (calm) and 0.916x (choppy). They are
NOT reproducible from the recordings. sweep() below evaluates 48 definitions per
row -- every combination of {per-lap, per-row, mean-of-lap} rate baselines x
{per-lap, per-row} speed baselines x {median, mean} for that baseline x {mean of
per-second ratios, median of them, ratio of means, ratio of medians} -- and
main() prints the range. It is 0.7890-0.8666 for the calm row, which brackets
0.851, and 0.5630-0.7866 for the choppy row, which does NOT reach 0.916 under
any of them. So the published pair cannot have come from one consistent
definition, and 0.916 in particular is unsupported by anything these two
recordings contain. The figures this file prints replace them, and they are
WORSE for the hull, not better: 0.8144 and 0.6919.

WHAT SURVIVES THE RETRACTION, and it is the load-bearing part: the DIRECTION is
robust, and it now has a control the published pair never had. All 96 sweep
values are well below 1.0, while the same statistic over the seconds that are
NOT over-reads sits at 0.9888 (calm) and 0.9969 (choppy) -- so "the hull is
slower here" is a property of the over-read seconds and not of the statistic.
enhanced_speed is recorded independently of the stroke detector, so a genuine
rate rise -- which would push speed up -- is excluded. That is what the
recorded-value change rests on; it never rested on the third decimal place.

THE DEFINITION THIS FILE PUBLISHES, in full, because the earlier figures were
unreproducible mostly for want of one:

  * the unit is a WORK LAP of one of the two recordings, selected exactly as
    scripts/fixtures/cue_work_laps.txt selects them (its header carries the
    rule), and the two fixtures are required to align lap for lap and second
    for second -- checked, not assumed, by rows() below;
  * a READING-SECOND is a second whose row_stroke_rate is > 0. 0 is the app's
    no-data sentinel in the rate fixture; a second without a rate has nothing to
    be an over-read of, so it is not in the population at either end;
  * a lap's RATE BASELINE is the median row_stroke_rate over its
    reading-seconds -- the same statistic cue_replay.lap_medians uses;
  * an OVER-READ SECOND is a reading-second whose rate exceeds MULT (1.25) times
    its own lap's rate baseline. Same multiple and same shape as the 8.7% / 4.0%
    figures cue_replay.py prints;
  * a lap's SPEED BASELINE is the median enhanced_speed over the SAME
    reading-seconds, so both baselines describe one population;
  * the HULL RATIO is the mean, over every over-read second of the row, of that
    second's speed divided by its own lap's speed baseline.

NO SPEED IS DISCARDED. 34 calm and 30 choppy work-lap seconds carry
enhanced_speed exactly 0.000 m/s, and unlike the rate fixture's 0 those are REAL
readings -- enhanced_speed has no in-band sentinel and 0 m/s is a legal value
(#86 / #107's lesson, in the direction that matters here). Dropping them would
be a filter chosen after seeing the answer, so they stay; the sensitivity table
below prints what dropping them would have done, which is to move both rows UP.

WHAT THIS IS NOT. It is a statistic over two recorded rows. It says nothing
about what the detector will do on the next row, nothing about whether the
relative gate is what let these seconds through -- that is what the lock_*
diagnostic fields are for -- and it is not a controlled experiment: the two rows
differ in water, in equipment placement and in the athlete's intent, not only in
chop.
"""

import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import cue_replay as R  # noqa: E402

SPEED_FIXTURE = os.path.join(HERE, "fixtures", "lock_guard_speed.txt")

# The over-read multiple. Same one cue_replay.spike_fraction reports at, and the
# same one the output-stage comment quotes.
MULT = 1.25


def load_speed(path=SPEED_FIXTURE):
    """Returns [(key, label, [lap_series, ...]), ...] in file order.

    Format mirrors cue_work_laps.txt minus the target band, which a speed series
    has no use for:  `ROW <key> <label>` then one `LAP <v> <v> ...` per lap.
    """
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
            elif head == "LAP":
                if not rows:
                    raise ValueError("LAP before any ROW in " + path)
                rows[-1][2].append([float(v) for v in rest.split()])
            else:
                raise ValueError("unrecognised line in " + path + ": " + line)
    return rows


def rows():
    """The two fixtures zipped, with alignment CHECKED rather than assumed.

    Returns [(key, label, [(rate_lap, speed_lap), ...]), ...]. Two fixtures that
    have drifted apart by one lap or one second would otherwise pair a rate with
    a speed from a different moment and publish a number quietly.
    """
    rate_rows = R.load_fixture()
    speed_rows = load_speed()
    if len(rate_rows) != len(speed_rows):
        raise ValueError("row count differs: %d rate rows, %d speed rows"
                         % (len(rate_rows), len(speed_rows)))
    out = []
    for (rkey, _lo, _hi, rlabel, rlaps), (skey, slabel, slaps) in zip(
            rate_rows, speed_rows):
        if rkey != skey:
            raise ValueError("row keys differ: %r vs %r" % (rkey, skey))
        if rlabel != slabel:
            raise ValueError("row %s: labels differ: %r vs %r"
                             % (rkey, rlabel, slabel))
        if len(rlaps) != len(slaps):
            raise ValueError("row %s: %d rate laps, %d speed laps"
                             % (rkey, len(rlaps), len(slaps)))
        pairs = []
        for i, (rl, sl) in enumerate(zip(rlaps, slaps)):
            if len(rl) != len(sl):
                raise ValueError("row %s lap %d: %d rate seconds, %d speed "
                                 "seconds" % (rkey, i, len(rl), len(sl)))
            pairs.append((rl, sl))
        out.append((rkey, rlabel, pairs))
    return out


def over_read_seconds(pairs, mult=MULT):
    """[(speed, that lap's speed baseline), ...] for the row's over-read seconds.

    A reading-second is one whose rate is > 0; both baselines are medians over
    that same population, per lap.
    """
    out = []
    for rate_lap, speed_lap in pairs:
        pop = [(r, s) for r, s in zip(rate_lap, speed_lap) if r > 0.0]
        if not pop:
            continue
        rate_base = statistics.median([r for r, _ in pop])
        speed_base = statistics.median([s for _, s in pop])
        for r, s in pop:
            if r > mult * rate_base:
                out.append((s, speed_base))
    return out


def hull_ratio(pairs, mult=MULT, drop_zero_speed=False):
    """The published figure: mean of (speed / its lap's speed baseline)."""
    sel = over_read_seconds(pairs, mult)
    if drop_zero_speed:
        sel = [(s, b) for s, b in sel if s > 0.0]
    if not sel:
        raise ValueError("no over-read seconds at mult %s" % mult)
    return sum(s / b for s, b in sel) / len(sel)


def control_ratio(pairs, mult=MULT):
    """The same statistic over the seconds that are NOT over-reads.

    The control the published pair never had. Without it "0.81x of baseline"
    could be an artefact of the statistic rather than a property of the over-read
    seconds -- a mean of per-second ratios about a median baseline is not
    centred on 1.0 for a skewed distribution.
    """
    tot, n = 0.0, 0
    for rate_lap, speed_lap in pairs:
        pop = [(r, s) for r, s in zip(rate_lap, speed_lap) if r > 0.0]
        if not pop:
            continue
        rate_base = statistics.median([r for r, _ in pop])
        speed_base = statistics.median([s for _, s in pop])
        for r, s in pop:
            if r <= mult * rate_base:
                tot += s / speed_base
                n += 1
    return tot / n


def sweep(pairs, mult=MULT):
    """Every definition the retraction note quotes a range over.

    Returns {name: value}. Three rate baselines x two speed baselines x two
    baseline statistics x four aggregations = 48 per row.
    """
    rate_laps = [rl for rl, _ in pairs]
    speed_laps = [sl for _, sl in pairs]
    pooled_r = [r for rl in rate_laps for r in rl if r > 0.0]
    row_rate_med = statistics.median(pooled_r)
    lap_rate_med = [statistics.median([r for r in rl if r > 0.0])
                    for rl in rate_laps]
    mean_lap_rate_med = sum(lap_rate_med) / len(lap_rate_med)
    pooled_s = [s for rl, sl in pairs for r, s in zip(rl, sl) if r > 0.0]

    out = {}
    for rb_name in ("lap", "row", "meanlap"):
        for sb_scope in ("lap", "row"):
            for sb_stat in ("median", "mean"):
                sel = []
                for i, (rl, sl) in enumerate(pairs):
                    pop = [(r, s) for r, s in zip(rl, sl) if r > 0.0]
                    if not pop:
                        continue
                    thr = mult * {"lap": lap_rate_med[i],
                                  "row": row_rate_med,
                                  "meanlap": mean_lap_rate_med}[rb_name]
                    vals = [s for _, s in pop] if sb_scope == "lap" else pooled_s
                    base = (statistics.median(vals) if sb_stat == "median"
                            else sum(vals) / len(vals))
                    for r, s in pop:
                        if r > thr:
                            sel.append((s, base))
                if not sel:
                    continue
                key = "%s/%s-%s" % (rb_name, sb_scope, sb_stat)
                out[key + "/meanOfRatios"] = sum(s / b for s, b in sel) / len(sel)
                out[key + "/medOfRatios"] = statistics.median(
                    [s / b for s, b in sel])
                out[key + "/ratioOfMeans"] = (
                    sum(s for s, _ in sel) / sum(b for _, b in sel))
                out[key + "/ratioOfMedians"] = (
                    statistics.median([s for s, _ in sel])
                    / statistics.median([b for _, b in sel]))
    return out


def main(argv):
    for key, label, pairs in rows():
        sel = over_read_seconds(pairs)
        reading = sum(1 for rl, _ in pairs for r in rl if r > 0.0)
        zeros = sum(1 for s, _ in sel if s == 0.0)
        print("=== %s: %s" % (key, label))
        print("    %d work laps, %d seconds, %d carrying a rate reading"
              % (len(pairs), sum(len(rl) for rl, _ in pairs), reading))
        print("    %d over-read seconds (rate above %.2fx the lap's own "
              "median), %d of them at exactly 0.000 m/s" % (len(sel), MULT, zeros))
        print("    HULL RATIO across the over-read seconds   %.4f"
              % hull_ratio(pairs))
        print("      the same statistic, zero speeds dropped %.4f"
              % hull_ratio(pairs, drop_zero_speed=True))
        print("      CONTROL, the seconds that are not over-reads %.4f"
              % control_ratio(pairs))
        sw = sweep(pairs)
        lo = min(sw.values())
        hi = max(sw.values())
        print("    48-definition sweep: %.4f .. %.4f  (all below 1.0: %s)"
              % (lo, hi, hi < 1.0))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
