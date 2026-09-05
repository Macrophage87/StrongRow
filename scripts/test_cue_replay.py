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
      "(theWindows... (c))")
def _():
    # THE MUTANT THIS KILLS: need chosen by the zone being LEFT
    # (`CUE_PERSIST_IN_MS if cur == CUEZ_IN else ...`), which is the rule the
    # superseded analysis replayed. It would adopt here at CUE_PERSIST_IN_MS.
    out = R.CUE_PERSIST_OUT_MS
    early = R.cue_step(25.0, LO, HI, BELOW, ABOVE, 0, out - 1)[0]
    late = R.cue_step(25.0, LO, HI, BELOW, ABOVE, 0, out)[0]
    mid = R.cue_step(25.0, LO, HI, BELOW, ABOVE, 0, R.CUE_PERSIST_IN_MS)[0]
    return [early, late, mid], [BELOW, ABOVE, BELOW]


@case("A10 persistence means CONTINUOUS -- an interrupted spike banks nothing "
      "(theWindows... (d))")
def _():
    brk = R.cue_step(17.0, LO, HI, IN, ABOVE, 0, 3000)
    again = R.cue_step(19.5, LO, HI, brk[0], brk[1], brk[2], 3250)
    still = R.cue_step(19.5, LO, HI, again[0], again[1], again[2], 6000)
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


@case("C1 the calm row's table: FALSE-HIGH 11.8 -> 2.6, flicker 2.87 -> 1.10")
def _():
    f = figures("calm")
    return [tab(f["raw"]), tab(f["cue"])], \
           [("11.8", "7.1", "6.2", "2.87", "0"),
            ("2.6", "1.8", "15.3", "1.10", "1")]


@case("C2 the choppy row's table: FALSE-HIGH UNCHANGED at 6.9, "
      "false-low 18.1 -> 3.0, flicker 2.30 -> 1.17")
def _():
    # The load-bearing correction. The comment advertised choppy FALSE-HIGH
    # 6.9% -> 4.5%; that was a property of a candidate that never shipped. The
    # shipped rule leaves it where it was, and this case is what keeps the
    # retraction honest: a future edit that "restores" 4.5% has to red here.
    f = figures("choppy")
    return [tab(f["raw"]), tab(f["cue"])], \
           [("6.9", "18.1", "1.5", "2.30", "0"),
            ("6.9", "3.0", "2.5", "1.17", "5")]


@case("C3 the choppy FALSE-HIGH count is identical, but not the same seconds")
def _():
    # 28 of 403 truth-IN seconds either way, with 18 in common: the cue
    # RELOCATES the choppy row's false-highs rather than removing them. Stated
    # numerically because "unchanged" alone would read as "does nothing".
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
            f["cue"]["truth_in"]], [28, 28, 18, 403]


@case("C4 smoothing the NUMBER makes the choppy row worse, on the SHIPPED rule")
def _():
    f = figures("choppy")
    return ["%.1f" % f[k]["false_high"] for k in ("cue", "m5", "m9", "hp")], \
           ["6.9", "9.7", "13.2", "6.9"]


@case("C5 smoothing the NUMBER makes the calm row worse too")
def _():
    f = figures("calm")
    return ["%.1f" % f[k]["false_high"] for k in ("cue", "m5", "m9", "hp")], \
           ["2.6", "3.4", "4.7", "2.9"]


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
    return out, [(22, 707, 3053, 3496),
                 (8, 300, 811, 1436),
                 (20, 185, 705, 1420)]


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
