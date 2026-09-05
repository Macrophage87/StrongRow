#!/usr/bin/env python3
"""RED/GREEN tests for scripts/cue_replay.py -- the display-cue replay harness.

TWO JOBS, and the first is the one that matters.

1. THE TRANSCRIPTION IS PINNED AGAINST THE SHIPPING MONKEY C. cue_replay.py is
   a Python rewrite of StrongRowView.cueBandZone / cueTarget / cueStep, and a
   rewrite that drifts from its original proves nothing about the original --
   that is exactly how the superseded analysis came to publish figures for a
   machine that never shipped. So every vector in section A below is a vector
   source/CueZoneTest.mc ALREADY ASSERTS against the real Monkey C: the same
   rates, the same one-millisecond-either-side-of-a-window boundaries (read
   from the constants on both sides, never restated), the same deadband cases,
   the same backwards clock. Change the rule on one side only and one of the two
   suites reds. The pairing is stated case by case, so the correspondence can be
   checked by reading rather than assumed.

   It is NOT a proof of equivalence -- two implementations agreeing on a finite
   vector set is agreement on that set. It is the strongest check available
   without running Monkey C offline, and it closes the specific drift that
   already happened (window keyed on the zone being LEFT rather than on the
   candidate; a run length counted in samples rather than milliseconds).

2. THE EXPLORER IS PINNED TO THE MIRROR AT THE SHIPPED POINT. cue_replay.py
   carries two implementations on purpose: cue_step, which is the line-for-line
   mirror of the Monkey C and takes no options, and cue_step_tuned, which takes
   the three settings as arguments so the latch sweep can ask what-if. Section D
   sweeps them against each other at (CUE_PERSIST_OUT_MS, CUE_PERSIST_IN_MS,
   CUE_REVERSAL_FAST) and reds if they part company -- otherwise the sweep could
   be exploring a machine the mirror does not describe, which is the same defect
   as the transcription drifting from the Monkey C, one level down.

3. THE PUBLISHED FIGURES ARE PINNED. Section C re-derives every number quoted in
   the CUE_* comment block of source/StrongRowView.mc from the committed
   fixture. If the rule, the fixture or the scoring changes, the figures move
   and this reds, naming the one that moved -- so the comment can never drift
   away from the data again.

Run: python3 scripts/test_cue_replay.py
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import cue_replay as R  # noqa: E402

NONE, BELOW, IN, ABOVE = (R.CUEZ_NONE, R.CUEZ_BELOW, R.CUEZ_IN, R.CUEZ_ABOVE)
LO, HI = 16, 18                      # the shipped default band, as CueFix.LO/HI

CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


def drive(rate, lo, hi, zone, cand, since, t_from, t_to, step=250):
    """Feed cue_step its own output back, exactly as the call site does."""
    t = t_from
    while t <= t_to:
        zone, cand, since = R.cue_step(rate, lo, hi, zone, cand, since, t)
        t += step
    return zone, cand, since


# ===========================================================================
# A. THE TRANSCRIPTION, against the vectors CueZoneTest.mc pins in Monkey C.
# ===========================================================================

@case("A1 band edges belong to the band "
      "(CueZoneTest theSeamAgreesWithRateColourAndStartsClean (c))")
def _():
    got = [R.cue_band_zone(r, LO, HI)
           for r in (16.0, 18.0, 15.9, 18.1, 0.0)]
    return got, [IN, IN, BELOW, ABOVE, NONE]


@case("A2 a frame back at the displayed zone clears the pending candidate "
      "(theSeamAgrees... (d))")
def _():
    return R.cue_step(17.0, LO, HI, IN, ABOVE, 1000, 2000)[:2], [IN, IN]


@case("A3 no-data is adopted at once in both directions "
      "(theSeamAgrees... (e))")
def _():
    gone = R.cue_step(0.0, LO, HI, IN, IN, 5000, 5000)[0]
    first = R.cue_step(25.0, LO, HI, NONE, NONE, 5000, 5000)[0]
    return [gone, first], [NONE, ABOVE]


@case("A4 a sub-deadband excursion never changes the cue, either side "
      "(theDeadbandIsPaidOnExitOnly (a)/(b))")
def _():
    above = drive(18.5, LO, HI, IN, IN, 0, 0, 10000)[0]
    below = drive(15.5, LO, HI, IN, IN, 0, 0, 10000)[0]
    return [above, below], [IN, IN]


@case("A5 re-entry pays no deadband and costs CUE_PERSIST_IN_MS "
      "(theDeadbandIsPaidOnExitOnly (c) -- now (d))")
def _():
    inw = R.CUE_PERSIST_IN_MS
    early = R.cue_step(16.0, LO, HI, BELOW, IN, 0, inw - 1)[0]
    late = R.cue_step(16.0, LO, HI, BELOW, IN, 0, inw)[0]
    return [early, late], [BELOW, IN]


@case("A6 the deadband keys on the DISPLAYED zone, not the pending candidate "
      "(theDeadbandIsPaidOnExitOnly (c))")
def _():
    # THE MUTANT THIS KILLS: cue_target(rate, lo, hi, cand) in cue_step. One
    # frame past hi + DEADBAND forms a pending ABOVE while IN is still on
    # screen; 18.5 is inside the deadband around a displayed IN, so it must not
    # license the change. Under the mutant the widened band belongs to the
    # pending ABOVE, 18.5 is plainly above 18, and the cue flips at 4 s.
    spike = R.cue_step(20.0, LO, HI, IN, IN, 0, 0)
    held = drive(18.5, LO, HI, spike[0], spike[1], spike[2], 250, 10000)[0]
    dip = R.cue_step(14.0, LO, HI, IN, IN, 0, 0)
    lifted = drive(15.5, LO, HI, dip[0], dip[1], dip[2], 250, 10000)[0]
    return [spike[0], spike[1], held, dip[0], dip[1], lifted], \
           [IN, ABOVE, IN, IN, BELOW, IN]


@case("A7 leaving the band takes CUE_PERSIST_OUT_MS, to the millisecond "
      "(theWindowsAreTheTwoConstantsOnAClock (a))")
def _():
    out = R.CUE_PERSIST_OUT_MS
    early = R.cue_step(19.5, LO, HI, IN, ABOVE, 0, out - 1)[0]
    late = R.cue_step(19.5, LO, HI, IN, ABOVE, 0, out)[0]
    return [early, late], [IN, ABOVE]


@case("A8 returning to the band takes CUE_PERSIST_IN_MS, the shorter window "
      "(theWindows... (b))")
def _():
    inw = R.CUE_PERSIST_IN_MS
    early = R.cue_step(17.0, LO, HI, ABOVE, IN, 0, inw - 1)[0]
    late = R.cue_step(17.0, LO, HI, ABOVE, IN, 0, inw)[0]
    return [early, late], [ABOVE, IN]


@case("A9 the window is chosen by the CANDIDATE, not by the zone being left "
      "(theWindowsAreTheTwoConstantsOnAClock (a))")
def _():
    # THE MUTANT THIS KILLS: need chosen by the zone being LEFT
    # (`CUE_PERSIST_IN_MS if cur == CUEZ_IN else ...`), which is the rule the
    # superseded analysis replayed. Leaving IN for ABOVE, that mutant adopts at
    # CUE_PERSIST_IN_MS; the shipped rule keys on the candidate and waits
    # CUE_PERSIST_OUT_MS.
    #
    # RETARGETED FROM BELOW -> ABOVE, and the reason is not cosmetic: that
    # vector is now the one transition that bypasses the window entirely (A13),
    # so it can no longer say anything about which window applies. IN -> ABOVE
    # kills the identical mutant and is not a sign reversal.
    out = R.CUE_PERSIST_OUT_MS
    early = R.cue_step(19.5, LO, HI, IN, ABOVE, 0, out - 1)[0]
    late = R.cue_step(19.5, LO, HI, IN, ABOVE, 0, out)[0]
    mid = R.cue_step(19.5, LO, HI, IN, ABOVE, 0, R.CUE_PERSIST_IN_MS)[0]
    return [early, late, mid], [IN, ABOVE, IN]


@case("A10 persistence means CONTINUOUS -- an interrupted spike banks nothing "
      "(theWindows... (d))")
def _():
    # Stamps relative to the window, for the reason the Monkey C twin's (d)
    # states: as absolutes (3000 / 3250 / 6000) this case stops testing banking
    # the moment the window falls below 2750 ms.
    out = R.CUE_PERSIST_OUT_MS
    brk = R.cue_step(17.0, LO, HI, IN, ABOVE, 0, out)
    again = R.cue_step(19.5, LO, HI, brk[0], brk[1], brk[2], out + 250)
    still = R.cue_step(19.5, LO, HI, again[0], again[1], again[2], 2 * out)
    return still[0], IN


@case("A11 the window is TIME, not calls: 40 calls at one instant move nothing "
      "(theWindows... (e))")
def _():
    z, c, s = IN, IN, 5000
    for _i in range(40):
        z, c, s = R.cue_step(19.5, LO, HI, z, c, s, 5000)
    return z, IN


@case("A12 a backwards clock restarts the timer "
      "(theWindows... (f))")
def _():
    back = R.cue_step(19.5, LO, HI, IN, ABOVE, 5000, 1000)
    return [back[0], back[2]], [IN, 1000]


@case("A13 a candidate on the OPPOSITE side of the band bypasses the window "
      "(c2_anOppositeZoneIsAdoptedWithoutTheLatch (a)/(b))")
def _():
    # RED before the sign-reversal fix, and the transcription's half of it. The
    # Monkey C case of the same name asserts the same two vectors against the
    # shipping cueStep.
    down = R.cue_step(7.0, LO, HI, ABOVE, ABOVE, 0, 0)
    up = R.cue_step(25.0, LO, HI, BELOW, BELOW, 0, 0)
    return [down[0], down[1], down[2], up[0]], [BELOW, BELOW, 0, ABOVE]


@case("A14 CUE_REVERSAL_FAST records which rule the mirror is mirroring")
def _():
    # The transcription's statement of WHICH machine it is. cue_replay.py's
    # sweep and the CUE_* comment both key off this flag, and a flag that
    # disagreed with the branch beside it would be the transcription drifting
    # from the Monkey C in the one place a reader would not look.
    got = R.cue_step(7.0, LO, HI, ABOVE, ABOVE, 0, 0)[0] == BELOW
    return [R.CUE_REVERSAL_FAST, got], [True, True]


# ===========================================================================
# B. THE FIXTURE. Shape and provenance, so a corrupted or re-cut fixture is
#    named as such instead of quietly moving every figure in section C.
# ===========================================================================

@case("B1 the fixture holds the two rows the comment describes")
def _():
    rows = R.load_fixture()
    got = [(k, lo, hi, len(laps), sum(len(s) for s in laps))
           for k, lo, hi, _label, laps in rows]
    return got, [("calm", 18, 20, 4, 3522), ("choppy", 16, 18, 8, 1442)]


@case("B2 the choppy work-lap medians are the full eight, in order")
def _():
    # The series the CUE_* comment quotes. Pinned as a whole BECAUSE a
    # subsequence of it was quoted once as evidence of a monotone drift it does
    # not show: laps 4 and 6-8 were absent. Quoting all eight is the fix, and
    # this is what stops the short form coming back.
    _k, _lo, _hi, _l, laps = [r for r in R.load_fixture() if r[0] == "choppy"][0]
    return ["%.1f" % m for m in R.lap_medians(laps)], \
           ["16.5", "15.0", "14.2", "15.2", "13.2", "14.3", "16.1", "16.0"]


@case("B3 the calm work-lap medians are all four, three of them above band")
def _():
    _k, _lo, _hi, _l, laps = [r for r in R.load_fixture() if r[0] == "calm"][0]
    return ["%.1f" % m for m in R.lap_medians(laps)], \
           ["20.3", "20.3", "19.2", "21.3"]


# ===========================================================================
# C. THE PUBLISHED FIGURES. Every number quoted in the CUE_* comment block of
#    source/StrongRowView.mc, re-derived here from the fixture.
# ===========================================================================

def figures(key):
    row = [r for r in R.load_fixture() if r[0] == key][0]
    _k, lo, hi, _label, laps = row
    out = {}
    for name, fn in (
            ("raw", R.zones_raw),
            ("cue", R.zones_cue),
            ("m5", R.zones_cue_smoothed(lambda s: R.smooth_median(s, 5))),
            ("m9", R.zones_cue_smoothed(lambda s: R.smooth_median(s, 9))),
            ("hp", R.zones_cue_smoothed(R.smooth_hampel))):
        out[name] = R.score(laps, lo, hi, fn)
    out["laps"] = laps
    out["band"] = (lo, hi)
    return out


def tab(s):
    return ("%.1f" % s["false_high"], "%.1f" % s["false_low"],
            "%.1f" % s["missed_high"], "%.2f" % s["flips_per_min"],
            "%.0f" % s["lag_s"])


@case("C1 the calm row's table: FALSE-HIGH 11.8 -> 2.3, flicker 2.87 -> 1.37")
def _():
    # MOVED BY THIS BRANCH, from (2.6, 1.8, 15.3, 1.10, 1). The sign-reversal
    # fast path and the 4000/1000 -> 2000/500 retune both land in the same
    # commit, so the "after" column is the new machine's. Every component of
    # the movement is reported rather than only the flattering ones:
    # FALSE-HIGH 2.6 -> 2.3 and missed-HIGH 15.3 -> 13.7 improve, false-low
    # 1.8 -> 2.4 and flicker 1.10 -> 1.37 get worse, median lag 1 s -> 0 s.
    f = figures("calm")
    return [tab(f["raw"]), tab(f["cue"])], \
           [("11.8", "7.1", "6.2", "2.87", "0"),
            ("2.3", "2.4", "13.7", "1.37", "0")]


@case("C2 the choppy row's table: FALSE-HIGH 6.9 -> 4.5 on the RETUNED rule, "
      "false-low 18.1 -> 4.5, flicker 2.30 -> 1.25")
def _():
    # 4.5 IS BACK, AND THE COINCIDENCE HAS TO BE ADDRESSED HEAD ON, because the
    # previous revision of this case said in as many words that "a future edit
    # that 'restores' 4.5% has to red here". It has. Read what that sentence
    # was protecting:
    #
    #   * the retracted 4.5% was a figure quoted for a machine that NEVER
    #     SHIPPED -- a two-stage replay whose deadband ran free on every
    #     sample, whose window was keyed on the zone being LEFT, and which
    #     counted samples rather than milliseconds. It was not reproducible
    #     from anything committed.
    #   * this 4.5% is what `python3 scripts/cue_replay.py` prints today, from
    #     the committed fixture, for the rule in StrongRowView.mc as of this
    #     commit: the sign-reversal fast path plus CUE_PERSIST_OUT_MS = 2000
    #     and CUE_PERSIST_IN_MS = 500. Halving the RE-ENTRY window is what
    #     moves it -- at 2000/1000 it is still 6.0 -- because a spike's colour
    #     is withdrawn sooner.
    #
    # The retraction is NOT being quietly reversed. What was withdrawn was the
    # claim that the SHIPPED 4000/1000 rule reduced this figure; it did not,
    # and C2's previous expectation (6.9 -> 6.9) is what said so. That claim
    # stays withdrawn and is stated in the CUE_* block as history.
    #
    # AND THIS IS NOT A FIX FOR #149. #149's substance is that a design was
    # chosen on a figure nobody could regenerate. One replay of a retuned
    # machine over the same two rows is the same class of evidence, and the
    # honest report of it is "the number moved", not "the defect is closed".
    #
    # The movement in full, including the part that is worse: FALSE-HIGH
    # 6.9 -> 4.5, false-low 3.0 -> 4.5, missed-HIGH 2.5 -> 2.1, flicker
    # 1.17 -> 1.25, median lag 5 s -> 4 s.
    f = figures("choppy")
    return [tab(f["raw"]), tab(f["cue"])], \
           [("6.9", "18.1", "1.5", "2.30", "0"),
            ("4.5", "4.5", "2.1", "1.25", "4")]


@case("C3 the choppy false-highs are now a strict SUBSET of the raw ones")
def _():
    # MOVED. The shipped 4000/1000 rule gave 28 against 28 with 18 in common --
    # it RELOCATED the choppy row's false-highs rather than removing them, and
    # that relocation is what C2's retracted 4.5% had obscured. The retuned rule
    # gives 18 against the raw 28, all 18 of them among the raw 28: nothing new
    # is invented, ten are removed. Stated as a set relation and not as a count,
    # because two equal counts over different seconds is what happened last
    # time.
    f = figures("choppy")
    lo, hi = f["band"]
    sets = []
    for fn in (R.zones_raw, R.zones_cue):
        acc = set()
        for li, series in enumerate(f["laps"]):
            zt = R.truth_zones(series, lo, hi)
            zc = fn(series, lo, hi)
            for i in range(len(series)):
                if zt[i] == IN and zc[i] == ABOVE:
                    acc.add((li, i))
        sets.append(acc)
    return [len(sets[0]), len(sets[1]), len(sets[0] & sets[1]),
            f["cue"]["truth_in"]], [28, 18, 18, 403]


@case("C4 smoothing the NUMBER makes the choppy row worse, on the SHIPPED rule")
def _():
    f = figures("choppy")
    # Re-measured on the RETUNED rule. The negative result survives the retune,
    # which is the point of re-running it rather than assuming: 4.5 unfiltered
    # against 7.9 (median-5) and 11.4 (median-9), with Hampel unable to move it.
    return ["%.1f" % f[k]["false_high"] for k in ("cue", "m5", "m9", "hp")], \
           ["4.5", "7.9", "11.4", "4.5"]


@case("C5 smoothing the NUMBER makes the calm row worse too")
def _():
    f = figures("calm")
    # Re-measured on the RETUNED rule: 2.3 unfiltered against 3.3, 4.1 and 2.4.
    return ["%.1f" % f[k]["false_high"] for k in ("cue", "m5", "m9", "hp")], \
           ["2.3", "3.3", "4.1", "2.4"]


@case("C6 neither filter touches the 37.5 spm spike, which is 6 s long "
      "at a lap's first second")
def _():
    # The comment's claim, made checkable -- including the shape of the spike,
    # since that is WHY neither filter touches it: a trailing window that starts
    # inside the spike contains nothing else, so its own median IS 37.5 and its
    # MAD is zero. An outlier rejector cannot reject what it has only ever seen.
    _k, _lo, _hi, _l, laps = [r for r in R.load_fixture() if r[0] == "choppy"][0]
    series = max(laps, key=lambda s: max(s))
    peak = max(series)
    j = series.index(peak)
    run = 0
    while j + run < len(series) and series[j + run] == peak:
        run += 1
    return [j, run, "%.1f" % peak, "%.1f" % R.smooth_median(series, 5)[j],
            "%.1f" % R.smooth_hampel(series)[j]], [0, 6, "37.5", "37.5", "37.5"]


@case("C7 the spike statistics the comment opens with")
def _():
    out = []
    for key in ("calm", "choppy"):
        _k, _lo, _hi, _l, laps = [r for r in R.load_fixture()
                                  if r[0] == key][0]
        f125, base = R.spike_fraction(laps, 1.25)
        f150, _ = R.spike_fraction(laps, 1.50)
        peak = max(v for s in laps for v in s)
        out.append(("%.1f" % f125, "%.1f" % f150, "%.1f" % peak,
                    "%.2f" % (peak / base)))
    # calm: 4.0% over 1.25x and a NON-ZERO 0.1% over 1.50x -- the comment used
    # to say the calm row never exceeded 1.5x. It does, twice.
    return out, [("4.0", "0.1", "31.9", "1.60"),
                 ("8.7", "2.8", "37.5", "2.43")]


@case("C8 the per-lap spike fractions, all four calm laps")
def _():
    # Quoted in full for the same reason as B2: the trio 3.5 / 1.0 / 1.3 was
    # once offered as "the chop lap spikes more than its calm neighbours", with
    # the 5.5% lap left out -- and that lap is spikier than the chop one.
    _k, _lo, _hi, _l, laps = [r for r in R.load_fixture() if r[0] == "calm"][0]
    import statistics
    out = []
    for s in laps:
        r = [v for v in s if v > 0.0]
        med = statistics.median(r)
        out.append("%.1f" % (100.0 * sum(1 for v in r if v > 1.25 * med)
                             / len(r)))
    return out, ["1.0", "5.5", "1.3", "3.5"]


# ===========================================================================
# D. THE SECOND FIXTURE, THE EXPLORER, AND THE NUMBER/COLOUR PAIR.
#
#    Section letter D and not C2 because these are pinned against the ROW THAT
#    REPORTED THE DEFECT, not against the two rows the cue was chosen from. The
#    two sets of figures must not be mixed: C's are what the CUE_* comment
#    quotes.
# ===========================================================================

@case("D1 the explorer reproduces the mirror exactly at the shipped setting")
def _():
    # THE DEFECT THIS KILLS: cue_step_tuned drifting from cue_step, which would
    # let the sweep publish a table for a machine the mirror does not describe.
    # Swept over every ordered pair of zones and a rate on each side of the
    # band, at stamps either side of both windows.
    zs = (NONE, BELOW, IN, ABOVE)
    got, want = [], []
    for rate in (0.0, 7.0, 14.5, 16.0, 17.0, 18.0, 19.5, 25.0):
        for cur in zs:
            for cand in zs:
                for now in (0, 1, R.CUE_PERSIST_IN_MS - 1, R.CUE_PERSIST_IN_MS,
                            R.CUE_PERSIST_OUT_MS - 1, R.CUE_PERSIST_OUT_MS,
                            R.CUE_PERSIST_OUT_MS + 1):
                    want.append(R.cue_step(rate, LO, HI, cur, cand, 0, now))
                    got.append(R.cue_step_tuned(
                        rate, LO, HI, cur, cand, 0, now,
                        R.CUE_PERSIST_OUT_MS, R.CUE_PERSIST_IN_MS,
                        R.CUE_REVERSAL_FAST))
    return got, want


@case("D2 the reversal fixture is the eight work intervals its header claims")
def _():
    rows = R.load_fixture(R.REVERSAL_FIXTURE)
    got = [(k, lo, hi, len(laps), sum(len(s) for s in laps),
            [len(s) for s in laps])
           for k, lo, hi, _label, laps in rows]
    return got, [("reversal", 16, 18, 8, 1443,
                  [181, 180, 181, 180, 181, 180, 180, 180])]


@case("D3 the reversal row's interval medians and no-data counts")
def _():
    # The two cross-checks its header offers a reader with a FIT decoder.
    _k, _lo, _hi, _l, laps = R.load_fixture(R.REVERSAL_FIXTURE)[0]
    meds = ["%.1f" % m for m in R.lap_medians(laps)]
    zeros = [sum(1 for v in s if v == 0.0) for s in laps]
    return [meds, zeros], \
           [["17.6", "18.3", "17.6", "17.9", "18.7", "22.7", "23.8", "23.4"],
            [0, 0, 5, 2, 0, 5, 11, 0]]


@case("D4 the shipped cue puts the colour OPPOSITE the number on all three rows")
def _():
    # The defect, as a number, on every row this repository holds. `opposite`
    # is the count that must reach zero; `disagree` and `ambiguous` are
    # reported beside it because they are the sizes of the DELIBERATE
    # disagreement and must be watched rather than minimised.
    out = []
    for _k, lo, hi, _l, laps in R.load_all():
        c = R.coherence(laps, lo, hi, R.zones_cue)
        out.append((c["opposite"], c["disagree"], c["ambiguous"], c["shown"]))
    # AFTER: opposite-side seconds are ZERO on every row, which is the whole
    # acceptance criterion -- a displayed instruction never points the opposite
    # way from the number beside it. Disagreement and ambiguity fall too, but
    # they are not targets: the residue is the deadband and the latch, which
    # are the feature.
    #
    #   row       opposite    disagree     ambiguous of seconds carrying a value
    #   calm       22 -> 0    707 -> 562   3053 -> 1636 of 3496 (87.3 -> 46.8 %)
    #   choppy      8 -> 0    300 -> 216    811 ->  450 of 1436 (56.5 -> 31.3 %)
    #   reversal   20 -> 0    185 -> 127    705 ->  379 of 1420 (49.6 -> 26.7 %)
    return out, [(0, 562, 1636, 3496),
                 (0, 216, 450, 1436),
                 (0, 127, 379, 1420)]


@case("D5 a 125 ms drive gives the same table as the 250 ms tick, every row")
def _():
    # C9's 1 Hz probe, at a tick that DIVIDES every window this file has
    # carried. A 1 Hz drive cannot observe a sub-second window expiring, so
    # once CUE_PERSIST_IN_MS goes below 1000 a 1 Hz disagreement would be a
    # fact about the probe. 125 ms is not.
    same = []
    for _k, lo, hi, _l, laps in R.load_all():
        a = R.score(laps, lo, hi, R.zones_cue)
        b = R.score(laps, lo, hi, lambda s, l, h: R.zones_cue(s, l, h, 125))
        same.append(tab(a) == tab(b))
    return same, [True, True, True]


@case("D6 the two windows are the sweep's own choice, by a stated rule")
def _():
    # THE SELECTION RULE, in code rather than in prose, so the retune can be
    # re-derived instead of taken on trust -- which is exactly what #149 says
    # was missing the first time these constants were chosen.
    #
    #   ADMISSIBLE   flips/min at or below R.FLICKER_BOUND (0.70) x the
    #                memoryless machine's, read from the harness rather than
    #                restated here so the two cannot disagree, on
    #                EVERY row. The sign-reversal fast path alone already costs
    #                the reversal row 1.18 -> 1.77 flips/min, which is 0.667 of
    #                raw, so 0.70 is the nearest round bound above what the fix
    #                spends before any retune: the retune is allowed at most
    #                3.3 further points of the flicker suppression the cue was
    #                introduced for.
    #   CHOSEN       of the admissible settings, the one with the smallest MEAN
    #                ADOPT LAG over the three rows -- the latch alone, with the
    #                deadband already spent. Responsiveness is the objective;
    #                the flicker bound is the constraint.
    #
    # STATED PLAINLY: 0.70 was fixed after reading the sweep, so it is a
    # selection rule and not a prediction. What it is not is arbitrary -- it is
    # pinned to a quantity the fix had already spent before any tuning
    # happened, and the sweep it selects from is printed by
    # `python3 scripts/cue_replay.py --sweep`.
    rows = R.load_all()
    best, best_lag = None, None
    for out_ms, in_ms in R.SWEEP:
        st = R.tuned(out_ms, in_ms, True)
        ratios, lags = [], []
        for _k, lo, hi, _l, laps in rows:
            ratios.append(R.score(laps, lo, hi, st)["flips_per_min"]
                          / R.score(laps, lo, hi, R.zones_raw)["flips_per_min"])
            lags.append(R.adopt_lag(laps, lo, hi, out_ms, in_ms, True)["mean_s"])
        if max(ratios) > R.FLICKER_BOUND:
            continue
        mean_lag = sum(lags) / len(lags)
        if best_lag is None or mean_lag < best_lag:
            best, best_lag = (out_ms, in_ms), mean_lag
    return [best, (R.CUE_PERSIST_OUT_MS, R.CUE_PERSIST_IN_MS)], \
           [(2000, 500), (2000, 500)]


@case("D7 the reversal row's own table, which the CUE_* block now quotes")
def _():
    # c3's comment block quotes this row beside calm and choppy. Pinned here
    # for the reason section C exists at all: a figure in a comment that
    # nothing regenerates is the defect this whole harness was written to stop,
    # and it does not stop being that defect because the row is new.
    _k, lo, hi, _l, laps = R.load_fixture(R.REVERSAL_FIXTURE)[0]
    return [tab(R.score(laps, lo, hi, R.zones_raw)),
            tab(R.score(laps, lo, hi, R.zones_cue))], \
           [("9.8", "10.3", "4.6", "2.66", "0"),
            ("3.3", "3.3", "8.0", "1.86", "2")]


@case("D8 the two lags the CUE_* block quotes, before and after")
def _():
    # ADOPT LAG is the latch alone; EDGE LAG is the number crossing a band edge
    # to the colour following it, deadband included. The comment's point is that
    # the change moves the first and barely moves the second, and that the
    # second's MAXIMUM does not move at all -- so the pin has to cover both or
    # the interesting half is unguarded.
    #
    # EACH EDGE-LAG MEAN CARRIES ITS DENOMINATOR, and that is not decoration.
    # edge_lag() averages only the crossings THAT machine followed within 90 s.
    # The faster machine follows MORE of them -- calm 127 -> 138 of 165,
    # reversal 45 -> 53 of 60 -- and the ones it newly follows are the SLOW
    # ones, which raises its own mean. So "6.93 -> 6.34" is not a like-for-like
    # comparison and must never be quoted as one. Pinning the denominators is
    # what stops the bare pair being read as a measurement of improvement --
    # this repository's "wrong pair" class.
    #
    # THE LIKE-FOR-LIKE FIGURE IS NOT AVAILABLE AND IS NOT QUOTED. An earlier
    # revision of this comment gave the two means recomputed over only the
    # crossings both machines follow. That number was true when measured and
    # NOTHING COMMITTED CAN PRODUCE IT: edge_lag() returns aggregates and no
    # per-crossing identity, so the two followed sets cannot be intersected.
    # It is deleted from here and from the CUE_* block rather than hedged, and
    # its digits are not restated, because a retraction that repeats the number
    # leaves the unregenerable figure in the tree. Add the per-crossing key to
    # edge_lag() and pin it before quoting such a comparison again.
    before, after = [], []
    for _k, lo, hi, _l, laps in R.load_all():
        b = R.adopt_lag(laps, lo, hi, *R.SHIPPED_BEFORE)
        a = R.adopt_lag(laps, lo, hi, R.CUE_PERSIST_OUT_MS,
                        R.CUE_PERSIST_IN_MS, R.CUE_REVERSAL_FAST)
        eb = R.edge_lag(laps, lo, hi, R.zones_before)
        ea = R.edge_lag(laps, lo, hi, R.zones_cue)
        before.append(("%.2f" % b["mean_s"], "%.2f" % b["max_s"],
                       "%.2f" % eb["mean_s"], "%.0f" % eb["max_s"],
                       "%d/%d" % (eb["followed"], eb["crossings"])))
        after.append(("%.2f" % a["mean_s"], "%.2f" % a["max_s"],
                      "%.2f" % ea["mean_s"], "%.0f" % ea["max_s"],
                      "%d/%d" % (ea["followed"], ea["crossings"])))
    # and the edge-lag maximum on calm with NO latch at all, which is what
    # shows the residue is the deadband rather than the windows
    _k, lo, hi, _l, calm = R.load_fixture()[0]
    nolatch = "%.0f" % R.edge_lag(calm, lo, hi, R.tuned(0, 0, True))["max_s"]
    return [before, after, nolatch], \
           [[("2.01", "4.00", "6.93", "84", "127/165"),
             ("1.86", "4.00", "10.16", "84", "49/54"),
             ("1.29", "4.00", "4.36", "56", "45/60")],
            [("0.91", "2.00", "6.34", "85", "138/165"),
             ("0.85", "2.00", "7.73", "82", "49/54"),
             ("0.52", "2.00", "2.91", "54", "53/60")],
            "89"]


@case("D9 most of the reversal row's extra flicker is the FAST PATH, not the "
      "retune")
def _():
    # The comment says "0.59 of the 0.68". Both halves pinned, because a
    # sentence that attributes a cost to the right cause is exactly the kind of
    # claim this repository has got wrong before by not checking the split.
    _k, lo, hi, _l, laps = R.load_fixture(R.REVERSAL_FIXTURE)[0]
    def flips(o, i, rev):
        return R.score(laps, lo, hi, R.tuned(o, i, rev))["flips_per_min"]
    shipped = flips(4000, 1000, False)
    fast_only = flips(4000, 1000, True)
    now = flips(R.CUE_PERSIST_OUT_MS, R.CUE_PERSIST_IN_MS, R.CUE_REVERSAL_FAST)
    return ["%.2f" % shipped, "%.2f" % fast_only, "%.2f" % now,
            "%.2f" % (fast_only - shipped), "%.2f" % (now - shipped)], \
           ["1.18", "1.77", "1.86", "0.59", "0.68"]


@case("D10 the BEFORE column, which is the defect itself, comes off the tool")
def _():
    # 22 / 8 / 20 is what the sign-reversal fix removes, and for one round a
    # shipping comment quoted it under "regenerate with python3
    # scripts/cue_replay.py" -- a command whose every `opposite` column read 0,
    # because the machine that produced 22/8/20 was no longer in the tree.
    # R.zones_before IS that machine, named once, and main() now prints its row.
    out = []
    for _k, lo, hi, _l, laps in R.load_all():
        c = R.coherence(laps, lo, hi, R.zones_before)
        out.append((c["opposite"], c["disagree"], c["ambiguous"], c["shown"]))
    return [R.SHIPPED_BEFORE, out], \
           [(4000, 1000, False),
            [(22, 707, 3053, 3496), (8, 300, 811, 1436), (20, 185, 705, 1420)]]


@case("D11 the design table: (a) and (b), both at the then-shipped latch")
def _():
    # THE TABLE THE SHIPPED DESIGN WAS CHOSEN ON. For one round three of its
    # rows described a machine that existed nowhere -- candidate (b) had no
    # implementation at all -- which is the same defect as #149's, in the
    # artifact that argues #149's numbers moved. R.design_b is that
    # implementation.
    #
    # BOTH AT 4000/1000 ON PURPOSE. The reversal rule and the window retune
    # landed together; scoring one design at the old latch and the other at the
    # new one would confound them. The windows are chosen separately, by D6,
    # with the reversal rule held fixed.
    out = []
    for _k, lo, hi, _l, laps in R.load_all():
        for fn in (R.design_a, R.design_b):
            c = R.coherence(laps, lo, hi, fn)
            sc = R.score(laps, lo, hi, fn)
            out.append((c["opposite"], c["disagree"],
                        "%.1f" % c["ambiguous_pct"],
                        "%.2f" % sc["flips_per_min"], sc["scored"]))
    return [R.DESIGN_LATCH, out], \
           [(4000, 1000),
            [(0, 685, "87.2", "1.20", 3496), (0, 706, "87.3", "1.11", 3474),
             (0, 292, "55.3", "1.17", 1436), (0, 300, "56.5", "1.18", 1428),
             (0, 165, "48.8", "1.77", 1420), (0, 185, "49.6", "1.20", 1400)]]


@case("D12 (b)'s lower flicker is partly a SCORING ARTEFACT, and the arithmetic "
      "says so exactly")
def _():
    # The argument the design table rests on, made checkable rather than
    # asserted. score() skips seconds where the strategy shows no zone -- see
    # its `zc[i] == CUEZ_NONE: continue`, which runs BEFORE `scored += 1` and
    # before `prev` is updated -- so under (b) a RED -> white -> BLUE sequence
    # counts as ONE flip and the white seconds leave the denominator entirely.
    #
    # The drop in (b)'s scored count is EXACTLY the opposite-side count the
    # shipped machine had: 3496-3474 = 22, 1436-1428 = 8, 1420-1400 = 20. That
    # is not a coincidence, and it is why (b)'s flips/min is not comparable with
    # (a)'s.
    out = []
    for _k, lo, hi, _l, laps in R.load_all():
        a_scored = R.score(laps, lo, hi, R.design_a)["scored"]
        b_scored = R.score(laps, lo, hi, R.design_b)["scored"]
        opp_before = R.coherence(laps, lo, hi, R.zones_before)["opposite"]
        out.append((a_scored - b_scored, opp_before,
                    a_scored - b_scored == opp_before))
    return out, [(22, 22, True), (8, 8, True), (20, 20, True)]


@case("D13 the fast path's firing rate, which a shipped comment quotes")
def _():
    # N1. source/StrongRowView.mc's fast-path comment states "the branch fires
    # 9 / 2 / 14 times, never on consecutive ticks, minimum gap 2000 ms" as the
    # anti-oscillation evidence for the one branch of cueStep with no window.
    # It was measured for that comment and pinned by nothing -- a new figure in
    # exactly the class this round was convened to remove, added by the round.
    #
    # A DIFFERENTIAL, not decoration: with the fast path OFF the same counts are
    # 5 / 2 / 5 and the minimum gap doubles to 4000 ms, because a crossing then
    # has to outlast the latch instead of pre-empting it. Both halves are
    # asserted, so a machine that stopped crossing at all would red too.
    on, off = [], []
    for _k, lo, hi, _l, laps in R.load_all():
        a = R.band_crossings(laps, lo, hi)
        b = R.band_crossings(laps, lo, hi, reversal=False)
        on.append((a["fired"], a["min_gap_ms"], a["consecutive"]))
        off.append((b["fired"], b["min_gap_ms"], b["consecutive"]))
    return [on, off], \
           [[(9, 2000, 0), (2, None, 0), (14, 2000, 0)],
            [(5, 4000, 0), (2, None, 0), (5, 4000, 0)]]


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
    print("\n%d/%d cue-replay tests passed." % (len(CASES) - failures,
                                                len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
