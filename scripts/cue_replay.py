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
    python3 scripts/cue_replay.py --sweep

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

TWO FIXTURES, SCORED SEPARATELY AND NEVER POOLED. scripts/fixtures/
cue_work_laps.txt holds the two rows the cue was originally chosen against and
is the source of every figure the CUE_* comment quotes. scripts/fixtures/
cue_reversal_row.txt holds one later row, the one that reported the colour
pointing the OPPOSITE WAY from the number beside it. They are separate files
with separate provenance because their boundary conventions differ (that row has
a step_type developer field and the older two do not) and because pooling them
would make every published figure depend on which rows happen to be in the pile.

THE THIRD FAMILY OF FIGURES, added with that row: what the athlete sees is a
NUMBER and a COLOUR side by side, and until this harness scored the PAIR it
scored only the colour. score() below grades the colour against a 31 s truth;
coherence() grades the colour against the number printed beside it on the same
frame. Those are different questions and a machine can do well on one and badly
on the other -- which is exactly what the shipped rule does.

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

# Whether cueStep has the SIGN-REVERSAL fast path: a candidate on the opposite
# side of the band from the zone on screen is adopted without waiting out the
# persistence window. Mirrors the presence of that branch in the Monkey C, so
# the sweep below and the mirror cannot disagree about which rule shipped.
CUE_REVERSAL_FAST = False

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
# THE EXPLORER. cue_step above is the MIRROR and takes no options; this takes
# the three settings as arguments so a sweep can ask what a different tuning
# would have done. It is deliberately a SECOND function rather than parameters
# bolted onto the mirror: a mirror with knobs is no longer a mirror, and the
# whole value of the mirror is that its body can be read line for line against
# the Monkey C.
#
# The two are pinned to each other at the SHIPPED POINT by
# scripts/test_cue_replay.py, which sweeps
# cue_step_tuned(..., CUE_PERSIST_OUT_MS, CUE_PERSIST_IN_MS, CUE_REVERSAL_FAST)
# against cue_step(...) over a vector set. Change one and that case reds.
def cue_step_tuned(rate, lo, hi, cur, cand, since, now,
                   out_ms, in_ms, reversal):
    want = cue_target(rate, lo, hi, cur)
    if want == cur:
        return [cur, cur, now]
    if want == CUEZ_NONE or cur == CUEZ_NONE:
        return [want, want, now]
    if reversal and ((want == CUEZ_BELOW and cur == CUEZ_ABOVE)
                     or (want == CUEZ_ABOVE and cur == CUEZ_BELOW)):
        return [want, want, now]
    if want != cand:
        return [cur, want, now]
    if now < since:
        return [cur, want, now]
    need = in_ms if want == CUEZ_IN else out_ms
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


def zones_cue_tuned(series, lo, hi, out_ms, in_ms, reversal, tick_ms=TICK_MS):
    """zones_cue, on the explorer, at a stated tuning."""
    per_sec = max(1, 1000 // tick_ms)
    zone, cand, since = CUEZ_NONE, CUEZ_NONE, 0
    out = []
    for i, v in enumerate(series):
        for k in range(per_sec):
            now = i * 1000 + k * tick_ms
            zone, cand, since = cue_step_tuned(v, lo, hi, zone, cand, since,
                                               now, out_ms, in_ms, reversal)
        out.append(zone)
    return out


def tuned(out_ms, in_ms, reversal, tick_ms=TICK_MS):
    """A strategy, in the shape score()/coherence() consume."""
    return lambda s, lo, hi: zones_cue_tuned(s, lo, hi, out_ms, in_ms,
                                             reversal, tick_ms)


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

# ---------------------------------------------------------------------------
# COHERENCE -- the NUMBER and the COLOUR as a pair, which is what is on the
# wrist. Everything in SCORING above grades the colour against a 31 s truth the
# athlete cannot see. These three grade it against the number printed beside it
# on the same frame, which the athlete can.
#
#   THE NUMBER'S OWN ZONE   cue_band_zone(v, lo, hi): the memoryless band
#                           comparison of the value drawRate is formatting. No
#                           deadband and no memory -- it is what the numeral
#                           SAYS, not what any machine decided.
#   AN OPPOSITE-SIDE SECOND the colour is BELOW and the number's own zone is
#                           ABOVE, or the mirror. The displayed instruction
#                           points the OPPOSITE WAY from the number beside it:
#                           "ease off" printed next to a 7. This is the defect,
#                           and its target is ZERO.
#   A DISAGREEMENT SECOND   the colour is anything other than the number's own
#                           zone. STRICTLY WIDER than opposite-side, and it is
#                           NOT a defect on its own: hysteresis and the deadband
#                           are disagreements by construction and are the whole
#                           point of the cue. Reported so the size of the
#                           deliberate disagreement is visible, never as a
#                           target.
#   AN AMBIGUOUS VALUE      a NUMERAL STRING -- the value at drawRate's own
#                           "%.1f" precision, not the float -- that this row
#                           rendered in more than one colour. The fraction is of
#                           seconds, not of distinct values: the question is how
#                           often the athlete saw a number whose colour they
#                           could not have predicted from the number.
#
# Seconds with NO READING are excluded from all three: the numeral is "--.-",
# there is no value to be coloured, and counting them would put the app's
# no-data sentinel into a statistic about numbers.
OPPOSITE_PAIRS = ((CUEZ_BELOW, CUEZ_ABOVE), (CUEZ_ABOVE, CUEZ_BELOW))


def coherence(laps, lo, hi, strategy):
    opp = dis = 0
    by_value = {}
    for series in laps:
        zc = strategy(series, lo, hi)
        for i, v in enumerate(series):
            nz = cue_band_zone(v, lo, hi)
            if nz == CUEZ_NONE:
                continue
            if (zc[i], nz) in OPPOSITE_PAIRS:
                opp += 1
            if zc[i] != nz:
                dis += 1
            key = "%.1f" % v
            by_value.setdefault(key, {})
            by_value[key][zc[i]] = by_value[key].get(zc[i], 0) + 1
    shown = sum(sum(d.values()) for d in by_value.values())
    amb = sum(sum(d.values()) for d in by_value.values() if len(d) > 1)
    return {
        "shown": shown,
        "opposite": opp,
        "disagree": dis,
        "ambiguous": amb,
        "opposite_pct": 100.0 * opp / max(1, shown),
        "disagree_pct": 100.0 * dis / max(1, shown),
        "ambiguous_pct": 100.0 * amb / max(1, shown),
        "values": len(by_value),
        "values_ambiguous": sum(1 for d in by_value.values() if len(d) > 1),
    }


# ---------------------------------------------------------------------------
# THE TWO LAGS, which are not the same quantity and are reported separately
# because conflating them is how "the cue is slow" gets blamed on the wrong
# term.
#
#   EDGE LAG    the number crosses a band edge; how long until the colour shows
#               that side. This is what the athlete experiences, and it
#               includes the DEADBAND -- a number one tenth over hi does not
#               move a colour that is showing IN, by design, and may never.
#               Crossings the colour never follows within LAG_SEARCH_S are
#               counted separately rather than dropped or scored as zero.
#   ADOPT LAG   cueTarget's answer changes; how long until the display adopts
#               it. This is the LATCH ALONE, with the deadband already spent,
#               so it is bounded by the persistence window by construction and
#               is the term a retune of the windows actually moves.
def edge_lag(laps, lo, hi, strategy):
    lags, unfollowed = [], 0
    for series in laps:
        zc = strategy(series, lo, hi)
        nz = [cue_band_zone(v, lo, hi) for v in series]
        for i in range(1, len(series)):
            if nz[i] == CUEZ_NONE or nz[i - 1] == CUEZ_NONE or nz[i] == nz[i - 1]:
                continue
            hit = None
            for j in range(i, min(i + LAG_SEARCH_S, len(series))):
                if zc[j] == nz[i]:
                    hit = j - i
                    break
            if hit is None:
                unfollowed += 1
            else:
                lags.append(hit)
    return {
        "crossings": len(lags) + unfollowed,
        "unfollowed": unfollowed,
        "mean_s": (sum(lags) / len(lags)) if lags else float("nan"),
        "median_s": statistics.median(lags) if lags else float("nan"),
        "max_s": max(lags) if lags else float("nan"),
    }


def adopt_lag(laps, lo, hi, out_ms, in_ms, reversal, tick_ms=TICK_MS):
    per_sec = max(1, 1000 // tick_ms)
    lags = []
    for series in laps:
        zone, cand, since = CUEZ_NONE, CUEZ_NONE, 0
        pending, t0 = None, None
        for i, v in enumerate(series):
            for k in range(per_sec):
                now = i * 1000 + k * tick_ms
                want = cue_target(v, lo, hi, zone)
                if want != zone:
                    if pending != want:
                        pending, t0 = want, now
                else:
                    pending, t0 = None, None
                zone, cand, since = cue_step_tuned(v, lo, hi, zone, cand,
                                                   since, now, out_ms, in_ms,
                                                   reversal)
                if pending is not None and zone == pending:
                    lags.append((now - t0) / 1000.0)
                    pending, t0 = None, None
    return {
        "n": len(lags),
        "mean_s": (sum(lags) / len(lags)) if lags else float("nan"),
        "max_s": max(lags) if lags else float("nan"),
    }


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

# The later row, in its own file. See the "TWO FIXTURES" note in the module
# docstring for why it is not a third ROW in the file above.
REVERSAL_FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "fixtures", "cue_reversal_row.txt")


def load_all():
    """Both fixtures, in a stable order: the two chosen-against rows, then the
    reported row. Every consumer here iterates this rather than reaching for a
    path, so adding a fixture is one edit."""
    return load_fixture(FIXTURE) + load_fixture(REVERSAL_FIXTURE)


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


# ---------------------------------------------------------------------------
# THE SWEEP. What a different tuning of the two persistence windows would have
# done, on every row, with the sign-reversal fast path in.
#
# WHY IT IS IN THE HARNESS RATHER THAN IN A SCRATCH SCRIPT: the last time a
# tuning decision was made here, the table justifying it came from a script
# nobody committed and the figures turned out to describe a machine that never
# shipped. Any future retune of these two constants has to be able to reprint
# this table in one command.
SWEEP = ((4000, 1000), (3000, 1000), (3000, 750), (2000, 1000), (2000, 500),
         (1500, 500), (1000, 1000), (1000, 500), (1000, 250), (0, 0))


def sweep(rows):
    print("LATCH SWEEP -- design (a), the sign-reversal fast path ON in every")
    print("row below. `opp` is opposite-side seconds, `dis` disagreement")
    print("seconds, `amb%` the ambiguous-value fraction; `edge` is the number")
    print("crossing a band edge, `adopt` is the latch alone (see the two-lags")
    print("note). `1Hz` is the drive-rate cross-check: FALSE means a 1 Hz drive")
    print("cannot resolve the shorter window, NOT that the machine counts")
    print("calls -- the 125/250/500 ms comparison in test_cue_replay.py is what")
    print("pins the wall-clock property once a window drops below 1 s.")
    print()
    for key, lo, hi, label, laps in rows:
        print("=== %s -- target %d-%d spm" % (key, lo, hi))
        print("    %-11s %5s %5s %6s %6s %6s %6s %6s %6s %6s %5s"
              % ("latch ms", "opp", "dis", "amb%", "flips", "FH%", "fl%",
                 "edgeM", "adptM", "adptX", "1Hz"))
        for out_ms, in_ms in SWEEP:
            st = tuned(out_ms, in_ms, True)
            sc = score(laps, lo, hi, st)
            co = coherence(laps, lo, hi, st)
            el = edge_lag(laps, lo, hi, st)
            al = adopt_lag(laps, lo, hi, out_ms, in_ms, True)
            hz = tuned(out_ms, in_ms, True, 1000)
            agree = all(abs(sc[k] - score(laps, lo, hi, hz)[k]) < 1e-9
                        for k in ("false_high", "false_low", "missed_high",
                                  "flips_per_min"))
            print("    %-11s %5d %5d %6.1f %6.2f %6.1f %6.1f %6.2f %6.2f %6.2f %5s"
                  % ("%d/%d" % (out_ms, in_ms), co["opposite"], co["disagree"],
                     co["ambiguous_pct"], sc["flips_per_min"],
                     sc["false_high"], sc["false_low"], el["mean_s"],
                     al["mean_s"], al["max_s"], agree))
        raw = score(laps, lo, hi, zones_raw)
        rawc = coherence(laps, lo, hi, zones_raw)
        print("    %-11s %5d %5d %6.1f %6.2f %6.1f %6.1f %6s %6s %6s %5s"
              % ("raw", rawc["opposite"], rawc["disagree"],
                 rawc["ambiguous_pct"], raw["flips_per_min"],
                 raw["false_high"], raw["false_low"], "0.00", "-", "-", "-"))
        print()
    return 0


def main(argv):
    rows = load_all()
    if "--sweep" in argv:
        return sweep(rows)
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
        # THE NUMBER AND THE COLOUR AS A PAIR. Printed for the same strategies
        # the table above scores, because a machine can be good at one and bad
        # at the other -- and the reported defect lives entirely here.
        print("    %-14s %10s %11s %9s %9s"
              % ("strategy", "opposite", "disagree", "ambig%", "shown"))
        for name, fn in (("raw (before)", zones_raw),
                         ("cueStep (after)", zones_cue)):
            c = coherence(laps, lo, hi, fn)
            print("    %-14s %10d %11d %8.1f%% %9d"
                  % (name, c["opposite"], c["disagree"], c["ambiguous_pct"],
                     c["shown"]))
        e = edge_lag(laps, lo, hi, zones_cue)
        a2 = adopt_lag(laps, lo, hi, CUE_PERSIST_OUT_MS, CUE_PERSIST_IN_MS,
                       CUE_REVERSAL_FAST)
        print("    edge lag mean %.2f s, median %.0f s, max %.0f s, %d of %d "
              "crossings never followed; adopt lag mean %.2f s, max %.2f s"
              % (e["mean_s"], e["median_s"], e["max_s"], e["unfollowed"],
                 e["crossings"], a2["mean_s"], a2["max_s"]))
        # Cross-check, printed rather than asserted: the windows are wall-clock,
        # so driving the same series at a DIFFERENT tick must give the same
        # answer as the 250 ms one. A difference means the transcription has
        # acquired a per-call term -- the "measured in calls, not in time"
        # defect.
        #
        # THE COMPARISON TICK MUST DIVIDE THE SHORTER WINDOW. A 1 Hz drive
        # cannot observe a window shorter than 1000 ms expiring, so once
        # CUE_PERSIST_IN_MS drops below a second, a 1 Hz disagreement says
        # something about the PROBE and nothing about the machine. 125 ms
        # divides every window this file has ever carried.
        a = score(laps, lo, hi, zones_cue)
        b = score(laps, lo, hi, lambda s, l, h: zones_cue(s, l, h, 125))
        same = all(abs(a[k] - b[k]) < 1e-9 for k in
                   ("false_high", "false_low", "missed_high", "flips_per_min"))
        print("    125 ms drive agrees with the 250 ms tick: %s" % same)
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
