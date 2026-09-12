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
    python3 scripts/cue_replay.py --presets

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

THREE FIXTURES, SCORED SEPARATELY AND NEVER POOLED. scripts/fixtures/
cue_work_laps.txt holds the two rows the cue was originally chosen against and
is the source of every figure the CUE_* comment quotes. scripts/fixtures/
cue_reversal_row.txt holds one later row, the one that reported the colour
pointing the OPPOSITE WAY from the number beside it. scripts/fixtures/
cue_latched_row.txt holds the first row recorded ON the shipped 2000/500 latch
(#210). They are separate files with separate provenance because their boundary
conventions differ (the later two have a step_type developer field and the
oldest two do not) and because pooling them would make every published figure
depend on which rows happen to be in the pile.

TWO POPULATIONS, AND THE DIFFERENCE IS NOT COSMETIC. load_all() is the three
rows recorded on the OLD machine and is what every published figure and the
window SELECTION RULE run over. load_every() adds the latched row and is used
for the PRESET COST table only. Letting a row that was rowed under 2000/500
participate in choosing 2000/500 would be circular -- the series is what an
athlete did while reacting to that cue -- so the selection block says which
population it used, every time it prints.

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
import re
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

# The three tunables, same values as the consts they mirror. The two windows are
# the DEFAULT PRESET's pair (#210); they are still constants here because the
# Monkey C still declares them as constants and preset 1 returns them by
# reference.
CUE_DEADBAND = 1.0
CUE_PERSIST_OUT_MS = 2000
CUE_PERSIST_IN_MS = 500

# ---------------------------------------------------------------------------
# THE PRESET TABLE (#210). Same four pairs as StrongRowView.cuePresetWindows,
# in preset order.
#
# THIS IS A SECOND COPY OF A TABLE AND THAT IS THE THING TO WORRY ABOUT. A
# transcription that drifts from its original pins nothing -- the defect this
# whole file exists to close, one level down. So it is not left to review:
# monkeyc_preset_table() below EXTRACTS the table out of source/StrongRowView.mc
# and scripts/test_cue_replay.py E3 asserts the two are equal. Edit either side
# alone and that case reds, naming the pair that moved.
CUE_PRESETS = ((4000, 1000), (2000, 500), (1000, 250), (0, 0))
CUE_PRESET_MIN = 0
CUE_PRESET_MAX = 3
CUE_PRESET_DEF = 1

PRESET_NAMES = ("0 Steady", "1 Balanced", "2 Twitchy", "3 Instant")

# Whether cueStep has the SIGN-REVERSAL fast path: a candidate on the opposite
# side of the band from the zone on screen is adopted without waiting out the
# persistence window. Mirrors the presence of that branch in the Monkey C, so
# the sweep below and the mirror cannot disagree about which rule shipped.
CUE_REVERSAL_FAST = True

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


def cue_step_w(rate, lo, hi, cur, cand, since, now, out_ms, in_ms):
    """Mirrors StrongRowView.cueStepW. Returns [zone, candidate, since].

    THE TWO WINDOWS ARE ARGUMENTS ON BOTH SIDES (#210). They became a setting,
    so the mirror took the same shape rather than keeping a copy of the old one;
    a mirror of a function that no longer exists mirrors nothing.

    Note the three things that separate it from the sample-counting machine the
    superseded analysis replayed:
      * `need` is chosen by the CANDIDATE (`want`), not by the zone being left;
      * the window is MILLISECONDS on the caller's clock, not a run length;
      * a candidate on the OPPOSITE SIDE of the band from the displayed zone is
        adopted with no window at all -- the third branch, mirroring the sign
        -reversal fast path in the Monkey C. CUE_REVERSAL_FAST above records
        that this branch is present, and test_cue_replay.py A14 reds if the
        flag and the branch disagree.
    """
    want = cue_target(rate, lo, hi, cur)
    if want == cur:
        return [cur, cur, now]
    if want == CUEZ_NONE or cur == CUEZ_NONE:
        return [want, want, now]
    if ((want == CUEZ_BELOW and cur == CUEZ_ABOVE)
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


def cue_step(rate, lo, hi, cur, cand, since, now):
    """Mirrors StrongRowView.cueStep: cue_step_w at the DEFAULT preset.

    A ONE-LINE DELEGATION ON BOTH SIDES. The Monkey C wrapper exists because a
    dozen (:test) cases and this mirror are written against the seven-argument
    form, and "the default is exactly today's behaviour" is #210's one promise;
    the mirror is a delegation for the same reason and by the same route.

    This is NOT the function the shipping draw path calls -- that is cue_step_w
    with the windows loadSettings resolved. Every published figure in this file
    is scored through it because every published figure describes the DEFAULT.
    """
    return cue_step_w(rate, lo, hi, cur, cand, since, now,
                      CUE_PERSIST_OUT_MS, CUE_PERSIST_IN_MS)


def cue_preset_windows(preset):
    """Mirrors StrongRowView.cuePresetWindows: the (out, in) pair, in ms.

    An index where the Monkey C is an if-chain, because a four-row table and a
    four-arm chain are the same function and Python has the better spelling.
    What keeps the two honest is not the shape but E3, which reads the Monkey C
    table out of the source and compares it with CUE_PRESETS.
    """
    return CUE_PRESETS[cue_clamp_preset(preset)]


def cue_clamp_preset(v):
    """Mirrors StrongRowView.cueClampPreset.

    THE BOOLEAN ARM IS NOT PYTHON PEDANTRY. In Monkey C `0 == false` evaluates
    TRUE (measured, SDK 9.2.0, fr965 -- see the note at StrongRowView.ergFlag),
    so a clamp written as value comparisons would read a Boolean `false` as
    preset 0, the SLOWEST setting. Python has the same trap wearing different
    clothes -- `True == 1` and `isinstance(True, int)` is True -- so the
    `isinstance(v, bool)` arm mirrors the Monkey C's `instanceof Lang.Number`
    test faithfully rather than by accident.

    The Float arm has no Python equivalent worth writing (a Python float is not
    an int, so it falls out of the isinstance test); the Monkey C side pins that
    case directly, in CueFix.test_cue_c1_theClampRefusesEverythingButZeroToThree.
    """
    if v is None:
        return CUE_PRESET_DEF
    if isinstance(v, bool) or not isinstance(v, int):
        return CUE_PRESET_DEF
    if v < CUE_PRESET_MIN or v > CUE_PRESET_MAX:
        return CUE_PRESET_DEF
    return v


# ---------------------------------------------------------------------------
# THE ANTI-DRIFT READ. The preset table above is a second copy of a table that
# lives in Monkey C, and this is what stops the two diverging silently: the
# Monkey C is the original, so it is read rather than restated.
#
# WHAT IS PARSED, and it is deliberately the FUNCTION BODY and not a comment: a
# comment cannot be red by any test (comments are stripped from the build, so
# the compiler never objects -- this repository has scripts/check_source_refs.py
# because a source comment named a guard that was never written). The `return
# [a, b];` lines of cuePresetWindows, in order, with `$.CUE_PERSIST_*` resolved
# through the `const` declarations in the same file.
MC_SOURCE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "source", "StrongRowView.mc")

_MC_CONST = re.compile(r"^const\s+(CUE_[A-Z_0-9]+)\s*=\s*(-?\d+)\s*;", re.M)
_MC_FN = re.compile(
    r"static function cuePresetWindows\(\s*\w+\s*\)\s*\{(.*?)\n    \}", re.S)
_MC_RET = re.compile(r"return\s*\[\s*([^,\]]+?)\s*,\s*([^,\]]+?)\s*\]\s*;")


def _mc_token(tok, consts):
    tok = tok.strip()
    if tok.startswith("$."):
        tok = tok[2:]
    if tok in consts:
        return consts[tok]
    return int(tok)


def monkeyc_preset_table(path=MC_SOURCE):
    """The preset table AS THE MONKEY C DECLARES IT, as a tuple of pairs."""
    with open(path, "r") as fh:
        src = fh.read()
    consts = dict((m.group(1), int(m.group(2)))
                  for m in _MC_CONST.finditer(src))
    m = _MC_FN.search(src)
    if m is None:
        raise ValueError("cuePresetWindows not found in " + path +
                         " -- the preset table cannot be cross-checked, which "
                         "is a failure and not a reason to skip the check")
    body = "\n".join(line.split("//")[0] for line in m.group(1).splitlines())
    return tuple(tuple(_mc_token(t, consts) for t in (r.group(1), r.group(2)))
                 for r in _MC_RET.finditer(body))


# ---------------------------------------------------------------------------
# THE EXPLORER. cue_step_w above is the MIRROR: its body is the Monkey C's body,
# line for line, and the only knobs it has are the two the Monkey C has. This
# one carries a THIRD knob -- `reversal` -- which no shipping function has, so
# the sweep can ask what the machine WITHOUT the sign-reversal fast path would
# have done.
#
# IT IS STILL A SECOND FUNCTION AND NOT A FLAG ON THE MIRROR, and the reason is
# unchanged by #210: a mirror with a knob the original does not have is no
# longer a mirror, and the whole value of the mirror is that its body can be
# read line for line against the Monkey C. What changed is WHICH knobs count as
# the original's -- the two windows now are, because the Monkey C takes them.
#
# The two are pinned to each other by scripts/test_cue_replay.py D1, which
# sweeps cue_step_tuned(..., out, in, CUE_REVERSAL_FAST) against
# cue_step_w(..., out, in) over a vector set at EVERY window pair in SWEEP, not
# just the shipped one. Change one and that case reds.
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


# The machine that shipped BEFORE the sign-reversal fast path and the retune:
# 4000 / 1000 windows, no fast path. It is no longer in the tree, so it is
# spelled out here ONCE and every "before" figure in main() and in the CUE_*
# comment block comes through this name rather than through a bare tuned(...)
# call at the point of use. Quoting a before figure without saying which machine
# produced it is how the superseded analysis published a table for a rule that
# never shipped.
SHIPPED_BEFORE = (4000, 1000, False)


def zones_before(series, lo, hi):
    return zones_cue_tuned(series, lo, hi, *SHIPPED_BEFORE)


# ---------------------------------------------------------------------------
# THE REJECTED CANDIDATE, implemented so its figures can be printed rather than
# asserted from memory.
#
# WHY A REJECTED DESIGN IS IN THE SHIPPING HARNESS. The choice between this and
# the sign-reversal fast path was published as a table, and for one round that
# table quoted five numbers for a machine that existed nowhere -- the exact
# shape of the defect this file was written to stop, reappearing in the file
# that stops it. Either the numbers come out of committed code or they are not
# evidence. They are cheap to produce, so they are produced.
#
# CANDIDATE (b), "white, then latch": when the candidate is on the OPPOSITE side
# of the band from the displayed zone, drop the display to CUEZ_NONE at once and
# make the new zone earn the ordinary out-of-band window before it appears.
#
# THE SECOND CLAUSE IS LOAD-BEARING AND IS EASY TO GET WRONG. cueStep adopts any
# zone out of CUEZ_NONE without delay, so a naive "return NONE" would show white
# for exactly one tick and then adopt -- which is candidate (a) with a 250 ms
# stutter, not a different design at all. The `cur == CUEZ_NONE` fast path is
# therefore suppressed for precisely the state this branch creates: white on
# screen with the reversal's own zone already pending.
def cue_step_white(rate, lo, hi, cur, cand, since, now,
                   out_ms=None, in_ms=None):
    out_ms = CUE_PERSIST_OUT_MS if out_ms is None else out_ms
    in_ms = CUE_PERSIST_IN_MS if in_ms is None else in_ms
    want = cue_target(rate, lo, hi, cur)
    if want == cur:
        return [cur, cur, now]
    if want == CUEZ_NONE or cur == CUEZ_NONE:
        pending_reversal = (cur == CUEZ_NONE and want != CUEZ_NONE
                            and cand == want and cand != CUEZ_NONE)
        if not pending_reversal:
            return [want, want, now]
    elif ((want == CUEZ_BELOW and cur == CUEZ_ABOVE)
          or (want == CUEZ_ABOVE and cur == CUEZ_BELOW)):
        return [CUEZ_NONE, want, now]
    if want != cand:
        return [cur, want, now]
    if now < since:
        return [cur, want, now]
    need = in_ms if want == CUEZ_IN else out_ms
    if (now - since) >= need:
        return [want, want, now]
    return [cur, cand, since]


def zones_cue_white(series, lo, hi, out_ms=None, in_ms=None, tick_ms=TICK_MS):
    per_sec = max(1, 1000 // tick_ms)
    zone, cand, since = CUEZ_NONE, CUEZ_NONE, 0
    out = []
    for i, v in enumerate(series):
        for k in range(per_sec):
            now = i * 1000 + k * tick_ms
            zone, cand, since = cue_step_white(v, lo, hi, zone, cand, since,
                                               now, out_ms, in_ms)
        out.append(zone)
    return out


# ---------------------------------------------------------------------------
# THE DESIGN COMPARISON, at a FIXED latch.
#
# THE LATCH IS HELD AT THE THEN-SHIPPED 4000 / 1000 ON PURPOSE, and this is the
# methodological point of the whole block: the sign-reversal fast path and the
# window retune are two separate changes that landed together, and scoring one
# design at 4000/1000 against the other at 2000/500 would confound them. What
# the table below answers is "which reversal rule", with the windows held fixed
# at the value both designs were proposed against. The windows are then chosen
# separately, by the sweep, with the reversal rule held fixed -- see SWEEP.
DESIGN_LATCH = SHIPPED_BEFORE[:2]


def design_a(series, lo, hi):
    """Adopt the opposite zone at once -- the design that shipped."""
    return zones_cue_tuned(series, lo, hi, DESIGN_LATCH[0], DESIGN_LATCH[1],
                           True)


def design_b(series, lo, hi):
    """Drop to white, then make the new zone earn the ordinary window."""
    return zones_cue_white(series, lo, hi, DESIGN_LATCH[0], DESIGN_LATCH[1])


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
    # THE MEAN IS OVER THE FOLLOWED CROSSINGS ONLY, and `followed` is returned
    # beside it because the two are not separable afterwards. A FASTER machine
    # follows MORE of the slow crossings, and the ones it newly follows are the
    # slow ones -- which raises its own mean. So two edge-lag means taken at
    # different tunings are over DIFFERENT POPULATIONS and are not directly
    # comparable; comparing them without the denominator is this repository's
    # "wrong pair" defect.
    #
    # THERE IS NO LIKE-FOR-LIKE NUMBER AVAILABLE FROM THIS FUNCTION, and an
    # earlier revision of this comment told the caller to "intersect the
    # followed sets themselves" while returning no per-crossing identity to
    # intersect. Either compare the MAXIMUM, which is a property of one machine
    # at a time, or add that identity here first. Do not publish a difference of
    # two means taken from this function.
    return {
        "crossings": len(lags) + unfollowed,
        "followed": len(lags),
        "unfollowed": unfollowed,
        "mean_s": (sum(lags) / len(lags)) if lags else float("nan"),
        "median_s": statistics.median(lags) if lags else float("nan"),
        "max_s": max(lags) if lags else float("nan"),
    }


# ---------------------------------------------------------------------------
# HOW OFTEN THE DISPLAY JUMPS STRAIGHT ACROSS THE BAND, and how close together.
#
# The sign-reversal fast path is the one branch of cueStep with NO window, so
# "does it oscillate" is a fair question to ask of it. This answers it FROM THE
# MACHINE'S OUTPUT rather than from a copy of the branch's guard: a firing is a
# frame where the DISPLAYED zone goes from one out-of-band side to the other.
# Nothing here re-implements the condition -- if the guard changed this would
# follow it, which a transcribed `if` would not.
#
# It is a differential and not decoration: with the fast path OFF the same
# counts drop -- 5 / 2 / 5 rather than 9 / 2 / 14 -- and the minimum gap doubles
# from one out-of-band window to two, because a crossing then has to outlast the
# latch instead of pre-empting it.
def band_crossings(laps, lo, hi, out_ms=None, in_ms=None, reversal=True,
                   tick_ms=TICK_MS):
    out_ms = CUE_PERSIST_OUT_MS if out_ms is None else out_ms
    in_ms = CUE_PERSIST_IN_MS if in_ms is None else in_ms
    per_sec = max(1, 1000 // tick_ms)
    fired, gaps, consecutive = 0, [], 0
    for series in laps:
        zone, cand, since = CUEZ_NONE, CUEZ_NONE, 0
        last = None
        for i, v in enumerate(series):
            for k in range(per_sec):
                now = i * 1000 + k * tick_ms
                prev = zone
                zone, cand, since = cue_step_tuned(v, lo, hi, zone, cand,
                                                   since, now, out_ms, in_ms,
                                                   reversal)
                if (prev, zone) in OPPOSITE_PAIRS:
                    fired += 1
                    if last is not None:
                        gaps.append(now - last)
                        if now - last <= tick_ms:
                            consecutive += 1
                    last = now
    return {"fired": fired,
            "min_gap_ms": min(gaps) if gaps else None,
            "consecutive": consecutive}


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

# The later row, in its own file. See the "THREE FIXTURES" note in the module
# docstring for why it is not a third ROW in the file above.
REVERSAL_FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "fixtures", "cue_reversal_row.txt")

# #210: the first row recorded ON the shipped 2000/500 latch. Its own file for
# the same reason, and OUTSIDE load_all() for a further one -- see load_every().
LATCHED_FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "fixtures", "cue_latched_row.txt")


def load_all():
    """The three rows recorded on the OLD machine, in a stable order: the two
    chosen-against rows, then the reported row.

    THIS IS THE PUBLISHED POPULATION. Every figure the CUE_* comment block
    quotes, and the window selection rule, run over exactly these three. The
    latched row is deliberately NOT here: see load_every().
    """
    return load_fixture(FIXTURE) + load_fixture(REVERSAL_FIXTURE)


def load_every():
    """Every committed row, the latched one last.

    USED FOR THE PRESET COST TABLE AND NEVER FOR THE SELECTION RULE. The latched
    row was rowed under 2000/500, so it is a record of an athlete reacting to
    that cue; letting it help choose that cue would be circular. What it CAN do
    is say what each preset would have cost on a row rowed under the machine
    that actually ships, which is the question #210 asks.
    """
    return load_all() + load_fixture(LATCHED_FIXTURE)


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

# The admissibility bound of the selection rule, in ONE place so the harness and
# scripts/test_cue_replay.py D6 cannot disagree about it. Its justification is
# in the CUE_* comment block of source/StrongRowView.mc and in D6.
FLICKER_BOUND = 0.70


def preset_row(laps, lo, hi, preset):
    """Every figure the preset table publishes, for one row at one preset.

    ONE FUNCTION, SO THE TABLE AND ITS PIN CANNOT DISAGREE. presets() prints
    what this returns and scripts/test_cue_replay.py E4 asserts what this
    returns; a figure computed twice is a figure that can be published wrong
    once.
    """
    out_ms, in_ms = cue_preset_windows(preset)
    st = tuned(out_ms, in_ms, CUE_REVERSAL_FAST)
    sc = score(laps, lo, hi, st)
    raw = score(laps, lo, hi, zones_raw)
    co = coherence(laps, lo, hi, st)
    el = edge_lag(laps, lo, hi, st)
    al = adopt_lag(laps, lo, hi, out_ms, in_ms, CUE_REVERSAL_FAST)
    return {
        "preset": preset,
        "out_ms": out_ms,
        "in_ms": in_ms,
        "flips_per_min": sc["flips_per_min"],
        "ratio": sc["flips_per_min"] / raw["flips_per_min"],
        "adopt_mean_s": al["mean_s"],
        "adopt_max_s": al["max_s"],
        "edge_mean_s": el["mean_s"],
        "edge_followed": el["followed"],
        "edge_crossings": el["crossings"],
        "opposite": co["opposite"],
        "disagree": co["disagree"],
        "ambiguous_pct": co["ambiguous_pct"],
        "false_high": sc["false_high"],
        "false_low": sc["false_low"],
        "missed_high": sc["missed_high"],
    }


def presets(rows):
    """#210: what each preset would have cost, on every committed row.

    THE TABLE THE SETTING SHIPS WITH. Its figures are quoted at the
    CUE_PRESET_* constants in source/StrongRowView.mc and in the setting's own
    pull request, and they come off this command rather than out of a scratch
    script -- which is the whole reason this harness exists.
    """
    print("PRESET COST -- every committed row, the sign-reversal fast path ON.")
    print("`ratio` is flips/min against the memoryless machine's on THAT row;")
    print("`adopt` is the latch alone (mean, and max = the window itself);")
    print("`edge` is the number crossing a band edge to the colour following")
    print("it, with its denominator, because a faster machine follows MORE of")
    print("the slow crossings and so raises its own mean -- two edge means at")
    print("different presets are over DIFFERENT populations and must not be")
    print("subtracted. `opp` is opposite-side seconds; its target is zero and")
    print("the fast path, not the latch, is what holds it there; the `raw` row")
    print("is 0 there by construction, being the number's own zone.")
    print()
    for key, lo, hi, label, laps in rows:
        print("=== %s: %s -- target %d-%d spm" % (key, label, lo, hi))
        print("    %-12s %-10s %6s %6s %6s %6s %18s %5s %6s %6s"
              % ("preset", "latch ms", "flips", "ratio", "adptM", "adptX",
                 "edge mean/followed", "opp", "dis", "amb%"))
        for p in range(len(CUE_PRESETS)):
            r = preset_row(laps, lo, hi, p)
            print("    %-12s %-10s %6.2f %6.3f %6.2f %6.2f %10.2f/%-7s %5d %6d %6.1f"
                  % (PRESET_NAMES[p], "%d/%d" % (r["out_ms"], r["in_ms"]),
                     r["flips_per_min"], r["ratio"], r["adopt_mean_s"],
                     r["adopt_max_s"], r["edge_mean_s"],
                     "%d/%d" % (r["edge_followed"], r["edge_crossings"]),
                     r["opposite"], r["disagree"], r["ambiguous_pct"]))
        rawsc = score(laps, lo, hi, zones_raw)
        rawco = coherence(laps, lo, hi, zones_raw)
        print("    %-12s %-10s %6.2f %6.3f %6s %6s %18s %5d %6d %6.1f"
              % ("raw", "none", rawsc["flips_per_min"], 1.0, "-", "-", "-",
                 rawco["opposite"], rawco["disagree"],
                 rawco["ambiguous_pct"]))
        print()
    print("THE FLICKER BOUND THE DEFAULT IS CHOSEN BY is %.2f x raw on EVERY"
          % FLICKER_BOUND)
    print("row (see sweep()). Presets outside it are offered, not recommended:")
    for p in range(len(CUE_PRESETS)):
        worst = max(preset_row(laps, lo, hi, p)["ratio"]
                    for _k, lo, hi, _l, laps in rows)
        print("    %-12s worst ratio %.3f  %s"
              % (PRESET_NAMES[p], worst,
                 "within the bound" if worst <= FLICKER_BOUND
                 else "OUTSIDE the bound"))
    return 0


def sweep(rows, select_rows=None):
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
        rawflips = score(laps, lo, hi, zones_raw)["flips_per_min"]
        print("    %-11s %5s %5s %6s %6s %6s %6s %6s %6s %6s %6s %5s"
              % ("latch ms", "opp", "dis", "amb%", "flips", "ratio", "FH%",
                 "fl%", "edgeM", "adptM", "adptX", "1Hz"))
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
            print("    %-11s %5d %5d %6.1f %6.2f %6.3f %6.1f %6.1f %6.2f %6.2f %6.2f %5s"
                  % ("%d/%d" % (out_ms, in_ms), co["opposite"], co["disagree"],
                     co["ambiguous_pct"], sc["flips_per_min"],
                     sc["flips_per_min"] / rawflips,
                     sc["false_high"], sc["false_low"], el["mean_s"],
                     al["mean_s"], al["max_s"], agree))
        raw = score(laps, lo, hi, zones_raw)
        rawc = coherence(laps, lo, hi, zones_raw)
        print("    %-11s %5d %5d %6.1f %6.2f %6.3f %6.1f %6.1f %6s %6s %6s %5s"
              % ("raw", rawc["opposite"], rawc["disagree"],
                 rawc["ambiguous_pct"], raw["flips_per_min"], 1.0,
                 raw["false_high"], raw["false_low"], "0.00", "-", "-", "-"))
        print()

    # THE TWO QUANTITIES THE SELECTION RULE ACTUALLY TURNS ON, printed rather
    # than left inside a test case. `ratio` above is per row; the rule uses the
    # WORST row, and it breaks ties on the mean adopt lag over all three. Both
    # were computed only inside test_cue_replay.py D6 for one round, and a
    # figure derived from the sweep but not printed by it is how "0.665 of raw"
    # -- a division of two ROUNDED numbers -- reached a shipping comment.
    #
    # THE POPULATION IS NAMED EVERY TIME IT PRINTS (#210). The rows scored
    # above are load_every(); the rule below runs over load_all() -- the three
    # rows recorded on the OLD machine -- because a row rowed under 2000/500
    # cannot help choose 2000/500 without circularity. Stating which set a
    # figure was computed over is this repository's "wrong pair" rule applied
    # to a population instead of to a ratio.
    if select_rows is None:
        select_rows = rows
    print("THE SELECTION RULE, over the %d row(s) the windows were CHOSEN"
          % len(select_rows))
    print("against (%s). Admissible = worst ratio"
          % ", ".join(k for k, _lo, _hi, _l, _laps in select_rows))
    print("at or below %.2f; chosen = smallest mean adopt lag among those."
          % FLICKER_BOUND)
    print("    %-11s %11s %11s  %s" % ("latch ms", "worst ratio", "mean adopt",
                                       "admissible"))
    best, best_lag = None, None
    for out_ms, in_ms in SWEEP:
        st = tuned(out_ms, in_ms, True)
        ratios, lags = [], []
        for _k, lo, hi, _l, laps in select_rows:
            ratios.append(score(laps, lo, hi, st)["flips_per_min"]
                          / score(laps, lo, hi, zones_raw)["flips_per_min"])
            lags.append(adopt_lag(laps, lo, hi, out_ms, in_ms, True)["mean_s"])
        worst = max(ratios)
        mean_lag = sum(lags) / len(lags)
        ok = worst <= FLICKER_BOUND
        if ok and (best_lag is None or mean_lag < best_lag):
            best, best_lag = (out_ms, in_ms), mean_lag
        print("    %-11s %11.6f %11.6f  %s"
              % ("%d/%d" % (out_ms, in_ms), worst, mean_lag,
                 "yes" if ok else "no"))
    print("    -> chosen %s; the tree carries %s"
          % (best, (CUE_PERSIST_OUT_MS, CUE_PERSIST_IN_MS)))
    return 0


def main(argv):
    if "--sweep" in argv:
        # Per-row tables over EVERY committed row; the selection rule over the
        # three the windows were chosen against. See load_every().
        return sweep(load_every(), load_all())
    if "--presets" in argv:
        return presets(load_every())
    # The plain run stays on load_all(): every figure it prints is one the
    # CUE_* comment block quotes, and those name three rows. The latched row's
    # figures are on --presets.
    rows = load_all()
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
        # THE PAIR TABLE, over FIVE strategies rather than two. The three
        # added rows are the ones a reader cannot otherwise obtain:
        #   shipped 4000/1000  the machine BEFORE this change. It is the only
        #                      row with a non-zero `opposite` count, and those
        #                      counts -- 22 / 8 / 20 -- ARE THE DEFECT. For one
        #                      round they were quoted in a shipping comment
        #                      under "regenerate with python3
        #                      scripts/cue_replay.py", which printed 0.
        #   design (a) / (b)   the two candidates, BOTH at the then-shipped
        #                      4000/1000 latch, so the design choice is not
        #                      confounded with the later retune.
        print("    %-20s %10s %11s %9s %9s"
              % ("strategy", "opposite", "disagree", "ambig%", "shown"))
        for name, fn in (("raw (memoryless)", zones_raw),
                         ("shipped 4000/1000", zones_before),
                         ("design (a) @4000", design_a),
                         ("design (b) @4000", design_b),
                         ("cueStep (after)", zones_cue)):
            c = coherence(laps, lo, hi, fn)
            sc = score(laps, lo, hi, fn)
            print("    %-20s %10d %11d %8.1f%% %9d   flips %.2f"
                  % (name, c["opposite"], c["disagree"], c["ambiguous_pct"],
                     c["shown"], sc["flips_per_min"]))
        e = edge_lag(laps, lo, hi, zones_cue)
        eb = edge_lag(laps, lo, hi, zones_before)
        a2 = adopt_lag(laps, lo, hi, CUE_PERSIST_OUT_MS, CUE_PERSIST_IN_MS,
                       CUE_REVERSAL_FAST)
        # EDGE LAG CARRIES ITS DENOMINATOR, because the two means are over
        # DIFFERENT crossing sets: a faster machine follows more of the slow
        # crossings and so raises its own mean. Printing "6.93 -> 6.34" without
        # "127 of 165 -> 138 of 165" beside it is the "wrong pair" defect.
        print("    edge lag  before %.2f s over %d of %d crossings"
              "  ->  after %.2f s over %d of %d"
              % (eb["mean_s"], eb["followed"], eb["crossings"],
                 e["mean_s"], e["followed"], e["crossings"]))
        print("    edge lag  median %.0f s, max %.0f s after; adopt lag mean "
              "%.2f s, max %.2f s"
              % (e["median_s"], e["max_s"], a2["mean_s"], a2["max_s"]))
        bc = band_crossings(laps, lo, hi)
        print("    the display jumps straight across the band %d time(s); "
              "closest pair %s ms apart, %d on consecutive ticks"
              % (bc["fired"],
                 "n/a" if bc["min_gap_ms"] is None else bc["min_gap_ms"],
                 bc["consecutive"]))
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
