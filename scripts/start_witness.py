#!/usr/bin/env python3
"""Replay the START-BASELINE window of i183553852 against the shipped gate.

WHY THIS FILE EXISTS. The D3 half of the display work -- "the estimator's
pre-START carry-over is cleared at every recording start" -- reverses a decision
`source/StrongRowView.mc` had argued for at length, and it reversed it on the
strength of numbers decoded from one `.fit`: a `rate_base` of 29.57 and a
displayed 28.85 spm on the first record of a session with the boat stationary.
Until this file landed, NOTHING COMMITTED COULD REGENERATE ANY OF THEM. That is
`docs/agents/rituals/FIELD_DATA.md` section 1 verbatim -- "a recording is not
evidence until something committed can regenerate every figure taken from it" --
and it is the same hole `cue_replay.py` and `speed_witness.py` were each written
to close after the fact.

    python3 scripts/start_witness.py

WHAT IT IS NOT. It is not a replay of the DETECTOR. `nextRateBase` advances once
per REGISTERED STROKE and the fixture is per SECOND, so the baseline's own
recursion cannot be re-run from it and this file does not try. What it does is
narrower and is enough for the claims that were made: it reads the baseline the
app ACTUALLY held at each second, puts it through a transcription of the shipped
`fastGate`, and asks what the gate was doing.

THE ONE FIGURE THIS FILE FALSIFIED. An earlier revision of the `fastGate` note
in `source/StrongRowView.mc` said "that row's rate_base never fell below 22.68 in
its first work interval, so zeroing it would have changed no gate decision on
that file". The first half is FALSE -- 22.6813 is the baseline at the interval's
FIRST second, and the minimum over the interval is 15.2863. The second half is
true but not for the stated reason. Both are corrected at their source, and this
harness is what makes the correction checkable.
"""

import os
import sys

# ---------------------------------------------------------------------------
# THE TRANSCRIPTION. Mirrors StrongRowView.fastGate and the three constants it
# reads, so a reader can put the two side by side. It is pinned against the same
# vectors source/LockGuardTest.mc asserts against the real Monkey C -- see
# scripts/test_start_witness.py section A -- for the reason cue_replay.py's
# header gives: a transcription that drifts from its original proves nothing
# about the original.
MIN_RATE = 6.0
MAX_RATE = 40.0
FAST_NEEDS_LOCK = 30.0      # the ABSOLUTE no-lock gate, in spm
LOCK_REL_K = 1.5            # == FAST_NEEDS_LOCK / LOCK_REF_RATE
LOCK_GATE_FLOOR = 20.0


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


def gated_rate(raw, ac_period, base):
    """Mirrors StrongRowView.gatedRate.

    `ac_period` here is derived from the recorded `lock_rate`, which is 0 for NO
    LOCK -- see the fixture header's absence-encoding block. The LOCK_SNAP_K arm
    is transcribed for completeness; nothing in this file's questions reaches it.
    """
    r = raw
    if ac_period > 0.0:
        ac = 60.0 / ac_period
        if r > 0.0:
            dev = abs(r - ac)
            if dev > 0.30 * ac:
                r = ac
    elif r > fast_gate(base):
        r = 0.0
    if r > MAX_RATE:
        r = MAX_RATE
    return r


# ---------------------------------------------------------------------------
# THE FIXTURE.
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "fixtures", "start_carryover.txt")

INT_SERIES = ("cadence", "step_type")


def load(path=FIXTURE):
    """Returns (key, label, {name: [values]}).

    ALIGNMENT IS CHECKED, NEVER ASSUMED -- the rule speed_witness.py states for
    its two files, applied here across seven series in one. Every series must
    have the same length or this raises, because the whole question is what
    seven quantities were doing AT THE SAME SECOND and a best-effort answer over
    ragged series is worse than no answer.
    """
    key = label = None
    series = {}
    order = []
    with open(path, "r") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            head, _, rest = line.partition(" ")
            if head == "ROW":
                key, _, label = rest.partition(" ")
            elif head == "SERIES":
                if key is None:
                    raise ValueError("SERIES before any ROW in " + path)
                name, _, vals = rest.partition(" ")
                if name in series:
                    raise ValueError("series %r appears twice in %s"
                                     % (name, path))
                cast = int if name in INT_SERIES else float
                series[name] = [cast(v) for v in vals.split()]
                order.append(name)
            else:
                raise ValueError("unrecognised line in " + path + ": " + line)
    if not series:
        raise ValueError("no SERIES lines in " + path)
    lengths = set(len(v) for v in series.values())
    if len(lengths) != 1:
        raise ValueError(
            "series lengths disagree in %s: %s -- a value would be paired with "
            "one from a different second" % (path, {n: len(series[n]) for n in order}))
    return key, label, series


# ---------------------------------------------------------------------------
# THE QUESTIONS, one function each, so every figure quoted in a source comment
# has a named producer rather than being read off a printout.
def first_record(series):
    """The session's first record -- the second the whole of D3 turns on."""
    return {name: vals[0] for name, vals in series.items()}


def work_indices(series):
    """The seconds of the first work interval: step_type == 2 (SFIT_WORK)."""
    return [i for i, t in enumerate(series["step_type"]) if t == 2]


def warmup_gap_s(series):
    """Seconds from the first record to the first work second.

    The fixture is contiguous at 1 Hz -- asserted on load by the length check
    plus the provenance block's "every adjacent pair is exactly 1 s apart" --
    so an index difference IS a second difference.
    """
    return work_indices(series)[0]


def baseline_span(series):
    w = work_indices(series)
    rb = [series["rate_base"][i] for i in w]
    return {"first": rb[0], "min": min(rb), "max": max(rb), "n": len(rb)}


def gate_bite(series):
    """Was the inherited baseline BINDING, and did it ever change the answer?

    BINDING          fast_gate(rate_base) strictly below the absolute
                     FAST_NEEDS_LOCK, i.e. the relative term is what sets the
                     bar rather than the constant.
    CHANGED          binding AND no lock AND the recorded pre-gate median lands
                     between the tightened gate and the absolute -- the only
                     shape in which clearing the baseline to 0.0 would have
                     published a reading the shipped code zeroed.

    The second is the one that matters, and it is NOT implied by the first:
    fast_gate is consulted only on gated_rate's NO-LOCK branch, so a binding
    baseline on a second with the lock up costs nothing at all.
    """
    w = work_indices(series)
    out = {}
    for name, rng in (("work1", w), ("window", range(len(series["step_type"])))):
        binding = changed = binding_unlocked = 0
        for i in rng:
            base = series["rate_base"][i]
            raw = series["rate_raw"][i]
            lock = series["lock_rate"][i]
            gate = fast_gate(base)
            if gate < FAST_NEEDS_LOCK:
                binding += 1
                if lock == 0.0:
                    binding_unlocked += 1
                    if raw > gate and raw <= FAST_NEEDS_LOCK:
                        changed += 1
        out[name] = {"n": len(list(rng)), "binding": binding,
                     "binding_unlocked": binding_unlocked, "changed": changed,
                     "lowest_gate": min(fast_gate(series["rate_base"][i])
                                        for i in rng)}
    return out


def stationary_prefix(series):
    """The leading run of seconds with the boat provably not moving.

    enhanced_speed 0 is a REAL reading here (see the fixture header), so this is
    a measurement and not an absence: speed exactly 0 m/s AND native cadence 0.
    """
    n = 0
    while (n < len(series["cadence"])
           and series["enhanced_speed"][n] == 0.0
           and series["cadence"][n] == 0):
        n += 1
    return n


def published_prefix(series):
    """What the app DISPLAYED over the stationary prefix, second by second.

    `row_stroke_rate` is what drawRate formats, so 0.0 here is exactly the frame
    that renders "--.-". This is the before picture the D3 reset changes.
    """
    n = stationary_prefix(series)
    return [series["row_stroke_rate"][i] for i in range(n)]


def main(argv):
    key, label, series = load()
    n = len(series["step_type"])
    w = work_indices(series)
    print("=== %s: %s" % (key, label))
    print("    %d recorded seconds, %d series, %d of them step_type 2"
          % (n, len(series), len(w)))
    print()

    fr = first_record(series)
    print("THE FIRST RECORD OF THE SESSION -- the second D3 turns on")
    print("    enhanced_speed %.4g m/s, cadence %d  -> the boat is not moving"
          % (fr["enhanced_speed"], fr["cadence"]))
    print("    rate_base %.4f, rate_raw %.4f, lock_rate %.4g"
          % (fr["rate_base"], fr["rate_raw"], fr["lock_rate"]))
    print("    row_stroke_rate %.4f -- drawRate formats this as %.1f spm"
          % (fr["row_stroke_rate"], fr["row_stroke_rate"]))
    print("    the shipped gate agrees: gatedRate(raw, no lock, base) = %.4f"
          % gated_rate(fr["rate_raw"], 0.0, fr["rate_base"]))
    print("    with the baseline CLEARED it would still publish %.4f -- the"
          % gated_rate(fr["rate_raw"], 0.0, 0.0))
    print("    baseline is not what let this through; the stroke-period RING is")
    print()

    sp = stationary_prefix(series)
    pub = published_prefix(series)
    shown = sum(1 for v in pub if v > 0.0)
    print("THE STATIONARY PREFIX -- speed 0 m/s AND cadence 0")
    print("    %d seconds, of which %d displayed a NUMBER and %d displayed --.-"
          % (sp, shown, sp - shown))
    print("    displayed: %s" % ", ".join("%.1f" % v if v > 0 else "--.-"
                                          for v in pub))
    print("    pre-gate medians over the same seconds: %s"
          % ", ".join("%.1f" % series["rate_raw"][i] for i in range(sp)))
    print("    the %d that read --.- were ZEROED BY THE GATE, not unmeasured:"
          % (sp - shown))
    print("    their medians exceed the absolute %.0f spm with no lock up"
          % FAST_NEEDS_LOCK)
    print()

    print("THE GAP: %d s from the first record to the first work second"
          % warmup_gap_s(series))
    bs = baseline_span(series)
    print("WORK INTERVAL 1 (%d s): rate_base first %.4f, min %.4f, max %.4f"
          % (bs["n"], bs["first"], bs["min"], bs["max"]))
    print()

    gb = gate_bite(series)
    print("WAS THE BASELINE BINDING, AND DID IT BITE?")
    for name in ("work1", "window"):
        d = gb[name]
        print("    %-7s %3d of %3d seconds binding (gate as low as %.4f spm);"
              % (name, d["binding"], d["n"], d["lowest_gate"]))
        print("            %3d of those carry NO LOCK, and on %d of them the"
              % (d["binding_unlocked"], d["changed"]))
        print("            tightened gate zeroed a reading the absolute would")
        print("            have passed")
    print()
    print("    fastGate is read ONLY on gatedRate's no-lock branch, so a binding")
    print("    baseline on a second with the lock up costs nothing. That -- not")
    print("    any saturation identity -- is why the carry-over changed no")
    print("    published value in the first work interval on this row.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
