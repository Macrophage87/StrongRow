#!/usr/bin/env python3
"""Replay the SHIPPED display-cue rule against the two recorded rows.

WHY THIS FILE EXISTS. The CUE_* comment block in source/StrongRowView.mc quotes
a table of measured figures, and until this script landed there was no way for a
reader to regenerate any of them: the analysis that produced them was a scratch
script that was never committed, and it replayed a DIFFERENT machine from the one
that shipped (see the RETRACTION note in that comment block). Every figure the
comment now quotes is printed by this file, from a fixture that is in the
repository, so the table can be checked in one command instead of taken on trust.

    python3 scripts/cue_replay.py

WHAT IT IS NOT. This is a PYTHON TRANSCRIPTION of the Monkey C decision, not the
Monkey C itself -- an offline replay cannot call into a .prg. A transcription
that drifts from its original pins nothing, which is the exact trap this
repository has fallen into before, so the drift is closed from both ends:

  * the three functions below are transcribed line for line, with the Monkey C
    they mirror quoted beside them (source/StrongRowView.mc, cueBandZone /
    cueTarget / cueStep);
  * scripts/test_cue_replay.py re-asserts, against THIS transcription, the same
    numeric vectors that source/CueZoneTest.mc asserts against the shipping
    Monkey C -- the same rates, the same 3999/4000 and 999/1000 boundaries, the
    same deadband cases. Editing either side alone reds one of the two suites.

It still says nothing about what a watch displays. It is a decision function fed
recorded numbers.

THE DEFINITIONS EVERY FIGURE DEPENDS ON are in code below rather than in prose,
because the earlier figures were unreproducible mostly for want of them:
work-lap selection, what counts as a reading, what "truth" means, what a flip is
and what the denominators are. See SCORING, below.
"""

import os
import statistics
import sys

# ---------------------------------------------------------------------------
# The vocabulary. Same codes and same names as the module-scope consts in
# source/StrongRowView.mc, so a reader can put the two side by side.
CUEZ_NONE = -1
CUEZ_BELOW = 0
CUEZ_IN = 1
CUEZ_ABOVE = 2

ZNAME = {CUEZ_NONE: "--", CUEZ_BELOW: "BELOW", CUEZ_IN: "IN", CUEZ_ABOVE: "ABOVE"}

# The three tunables, same values as the consts they mirror.
CUE_DEADBAND = 1.0
CUE_PERSIST_OUT_MS = 4000
CUE_PERSIST_IN_MS = 1000

# The display tick the shipping call site runs on (onUpdate).
TICK_MS = 250


# ---------------------------------------------------------------------------
# THE TRANSCRIPTION. Each function mirrors the Monkey C of the same name.
def cue_band_zone(rate, lo, hi):
    """Mirrors StrongRowView.cueBandZone: the memoryless band comparison."""
    if rate <= 0.0:
        return CUEZ_NONE
    if rate < lo:
        return CUEZ_BELOW
    if rate > hi:
        return CUEZ_ABOVE
    return CUEZ_IN


def cue_target(rate, lo, hi, cur):
    """Mirrors StrongRowView.cueTarget.

    THE DEADBAND IS KEYED ON `cur`, THE ZONE ON SCREEN -- never on the pending
    candidate. That is the load-bearing line of the design and the one a
    transcription is most likely to get subtly wrong.
    """
    if cur == CUEZ_IN:
        return cue_band_zone(rate, lo - CUE_DEADBAND, hi + CUE_DEADBAND)
    return cue_band_zone(rate, lo, hi)


def cue_step(rate, lo, hi, cur, cand, since, now):
    """Mirrors StrongRowView.cueStep. Returns [zone, candidate, since].

    Note the two things that separate it from the sample-counting machine the
    superseded analysis replayed:
      * `need` is chosen by the CANDIDATE (`want`), not by the zone being left;
      * the window is MILLISECONDS on the caller's clock, not a run length.
    """
    want = cue_target(rate, lo, hi, cur)
    if want == cur:
        return [cur, cur, now]
    if want == CUEZ_NONE or cur == CUEZ_NONE:
        return [want, want, now]
    if want != cand:
        return [cur, want, now]
    if now < since:
        return [cur, want, now]
    need = CUE_PERSIST_IN_MS if want == CUEZ_IN else CUE_PERSIST_OUT_MS
    if (now - since) >= need:
        return [want, want, now]
    return [cur, cand, since]


# ---------------------------------------------------------------------------
# THE TWO CUES BEING COMPARED, each as a per-second series of displayed zones.
def zones_raw(series, lo, hi):
    """BEFORE: the plain band comparison, which is what shipped before #124.

    Memoryless, so it is simply cue_band_zone per second.
    """
    return [cue_band_zone(v, lo, hi) for v in series]


def zones_cue(series, lo, hi, tick_ms=TICK_MS):
    """AFTER: the shipped cue_step, driven at the real display tick.

    Each recorded second is presented as (1000 / tick_ms) consecutive frames
    carrying that second's rate, and the zone credited to the second is the one
    on screen after the LAST of them. At 1 Hz the machine is identical (the
    windows are wall-clock), which the harness checks rather than asserts --
    see main().
    """
    per_sec = max(1, 1000 // tick_ms)
    zone, cand, since = CUEZ_NONE, CUEZ_NONE, 0
    out = []
    for i, v in enumerate(series):
        for k in range(per_sec):
            now = i * 1000 + k * tick_ms
            zone, cand, since = cue_step(v, lo, hi, zone, cand, since, now)
        out.append(zone)
    return out


# ---------------------------------------------------------------------------
# THE NEGATIVE RESULT: pre-smoothing the NUMBER and taking the zone from the
# smoothed value. Kept in the harness because the CUE_* comment quotes it as the
# reason the displayed number is left raw, and a quoted figure nobody can
# regenerate is what this file exists to stop.
#
# CAUSAL, trailing windows only. A display filter cannot see the future, so a
# centred median would be scoring a machine that could not ship. (Truth above is
# centred BECAUSE it is not a machine -- it is the after-the-fact answer the
# machine is graded against.)
#
# No-reading seconds pass through untouched: a filter must not invent a reading
# where the estimator had none.
def smooth_median(series, k):
    out, hist = [], []
    for v in series:
        if v <= 0.0:
            out.append(v)
            continue
        hist.append(v)
        if len(hist) > k:
            hist.pop(0)
        out.append(statistics.median(hist))
    return out


def smooth_hampel(series, k=7, nsig=3.0):
    """Trailing Hampel: a reading more than nsig scaled-MADs from the window
    median is replaced by that median, otherwise it is passed through."""
    out, hist = [], []
    for v in series:
        if v <= 0.0:
            out.append(v)
            continue
        hist.append(v)
        if len(hist) > k:
            hist.pop(0)
        med = statistics.median(hist)
        mad = statistics.median([abs(x - med) for x in hist])
        sigma = 1.4826 * mad
        out.append(med if (sigma > 0.0 and abs(v - med) > nsig * sigma) else v)
    return out


def zones_cue_smoothed(pre):
    """A strategy: pre-smooth the number, then run the shipped cue on it."""
    return lambda series, lo, hi: zones_cue(pre(series), lo, hi)


# ---------------------------------------------------------------------------
# SCORING -- the definitions, stated once, in code.
#
#   A READING            a recorded second whose row_stroke_rate is > 0. The app
#                        writes 0.0 for "nothing measured" and renders it "--.-",
#                        so a zero is an absence, not a slow stroke.
#   TRUTH                a 31 s CENTRED MEDIAN of the readings around the second
#                        (>= 5 needed, else undefined), put through the plain
#                        band. It is a property of the MEASUREMENT and is the
#                        same for every strategy scored against it.
#   A SCORED SECOND      truth defined AND the strategy showing a zone (i.e. the
#                        second carried a reading). Both strategies here go to
#                        CUEZ_NONE on exactly the no-reading seconds, so the two
#                        columns of the table are scored over the SAME seconds.
#   FALSE-HIGH           truth IN, cue ABOVE -- told to ease off while in band.
#                        Denominator: scored seconds whose truth is IN.
#   false-low            truth IN, cue BELOW. Same denominator.
#   missed-HIGH          truth ABOVE, cue not ABOVE. Denominator: ALL scored
#                        seconds (this is the denominator the superseded
#                        analysis used, kept so the one figure that survives
#                        comparison -- calm 6.3% before -- still compares).
#   A FLIP               a change of displayed zone between CONSECUTIVE SCORED
#                        seconds. No-reading seconds are skipped rather than
#                        counted, and state is NOT carried across a lap
#                        boundary. flips/min = flips / (scored seconds / 60),
#                        pooled over the laps of a row.
#   LAG                  at each second where truth changes, the seconds until
#                        the cue first shows the new truth zone (searched 90 s);
#                        the figure is the MEDIAN over those changes.
TRUTH_WIN = 31
TRUTH_MIN_SAMPLES = 5
LAG_SEARCH_S = 90


def truth_zones(series, lo, hi, win=TRUTH_WIN):
    half = win // 2
    out = []
    for i in range(len(series)):
        w = [v for v in series[max(0, i - half):i + half + 1] if v > 0.0]
        if len(w) < TRUTH_MIN_SAMPLES:
            out.append(None)
        else:
            out.append(cue_band_zone(statistics.median(w), lo, hi))
    return out


def score(laps, lo, hi, strategy):
    fh = fl = missed = scored = truth_in = flips = 0
    lags = []
    for series in laps:
        zt = truth_zones(series, lo, hi)
        zc = strategy(series, lo, hi)
        prev = None
        for i in range(len(series)):
            if zt[i] is None or zc[i] == CUEZ_NONE:
                continue
            scored += 1
            if zt[i] == CUEZ_IN:
                truth_in += 1
                if zc[i] == CUEZ_ABOVE:
                    fh += 1
                elif zc[i] == CUEZ_BELOW:
                    fl += 1
            elif zt[i] == CUEZ_ABOVE and zc[i] != CUEZ_ABOVE:
                missed += 1
            if prev is not None and zc[i] != prev:
                flips += 1
            prev = zc[i]
        for i in range(1, len(zt)):
            if zt[i] is None or zt[i - 1] is None or zt[i] == zt[i - 1]:
                continue
            for j in range(i, min(i + LAG_SEARCH_S, len(zc))):
                if zc[j] == zt[i]:
                    lags.append(j - i)
                    break
    return {
        "scored": scored,
        "truth_in": truth_in,
        "false_high": 100.0 * fh / max(1, truth_in),
        "false_low": 100.0 * fl / max(1, truth_in),
        "missed_high": 100.0 * missed / max(1, scored),
        "flips_per_min": flips / (scored / 60.0) if scored else 0.0,
        "lag_s": statistics.median(lags) if lags else float("nan"),
    }


# ---------------------------------------------------------------------------
# THE FIXTURE.
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "fixtures", "cue_work_laps.txt")


def load_fixture(path=FIXTURE):
    """Returns [(key, lo, hi, label, [lap_series, ...]), ...] in file order."""
    rows = []
    with open(path, "r") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            head, _, rest = line.partition(" ")
            if head == "ROW":
                key, lo, hi, label = rest.split(" ", 3)
                rows.append((key, int(lo), int(hi), label, []))
            elif head == "LAP":
                if not rows:
                    raise ValueError("LAP before any ROW in " + path)
                rows[-1][4].append([float(v) for v in rest.split()])
            else:
                raise ValueError("unrecognised line in " + path + ": " + line)
    return rows


def lap_medians(laps):
    """Median of the seconds that CARRIED A READING, per lap."""
    return [statistics.median([v for v in s if v > 0.0]) for s in laps]


def spike_fraction(laps, mult):
    """Fraction of reading-seconds above `mult` x the row's own median."""
    all_r = [v for s in laps for v in s if v > 0.0]
    base = statistics.median(all_r)
    over = sum(1 for v in all_r if v > mult * base)
    return 100.0 * over / max(1, len(all_r)), base


def main(argv):
    rows = load_fixture()
    for key, lo, hi, label, laps in rows:
        secs = sum(len(s) for s in laps)
        print("=== %s: %s -- target %d-%d spm" % (key, label, lo, hi))
        print("    %d work laps, %d recorded seconds" % (len(laps), secs))
        print("    lap medians (seconds carrying a reading): %s"
              % ", ".join("%.1f" % m for m in lap_medians(laps)))
        f125, base = spike_fraction(laps, 1.25)
        f150, _ = spike_fraction(laps, 1.50)
        allr = [v for s in laps for v in s if v > 0.0]
        print("    row median %.2f spm; above 1.25x %.1f%% of reading-seconds, "
              "above 1.50x %.1f%%; peak %.1f spm (%.2fx)"
              % (base, f125, f150, max(allr), max(allr) / base))
        print("    %-14s %11s %10s %12s %10s %7s"
              % ("strategy", "FALSE-HIGH", "false-low", "missed-HIGH",
                 "flips/min", "lag s"))
        for name, fn in (
                ("raw (before)", zones_raw),
                ("cueStep (after)", zones_cue),
                ("+median-5", zones_cue_smoothed(lambda s: smooth_median(s, 5))),
                ("+median-9", zones_cue_smoothed(lambda s: smooth_median(s, 9))),
                ("+Hampel", zones_cue_smoothed(smooth_hampel))):
            s = score(laps, lo, hi, fn)
            print("    %-14s %10.1f%% %9.1f%% %11.1f%% %10.2f %7.0f"
                  % (name, s["false_high"], s["false_low"], s["missed_high"],
                     s["flips_per_min"], s["lag_s"]))
        # Cross-check, printed rather than asserted: the windows are wall-clock,
        # so driving the same series at 1 Hz must give the same answer as the
        # 250 ms tick. A difference means the transcription has acquired a
        # per-call term -- the "measured in calls, not in time" defect.
        a = score(laps, lo, hi, zones_cue)
        b = score(laps, lo, hi, lambda s, l, h: zones_cue(s, l, h, 1000))
        same = all(abs(a[k] - b[k]) < 1e-9 for k in
                   ("false_high", "false_low", "missed_high", "flips_per_min"))
        print("    1 Hz drive agrees with the 250 ms tick: %s" % same)
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
