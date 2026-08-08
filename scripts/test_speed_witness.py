#!/usr/bin/env python3
"""RED/GREEN tests for scripts/speed_witness.py -- the independent-witness harness.

TWO JOBS, and they are the same two scripts/test_cue_replay.py has, for the same
reason: a figure quoted in source/StrongRowView.mc must be re-derivable from
something in the repository, and it must not be able to drift away from the data
again.

1. THE PUBLISHED FIGURES ARE PINNED. Section B re-derives every number the
   output-stage comment block quotes, from the two committed fixtures. If the
   fixture, the definition or the arithmetic changes, the figures move and this
   reds, naming the one that moved.

2. THE TWO FIXTURES ARE PINNED TOGETHER. speed_witness.rows() refuses to publish
   anything unless cue_work_laps.txt and lock_guard_speed.txt agree lap for lap
   and second for second, and section A drives that refusal with deliberately
   misaligned inputs rather than trusting that it works. A harness that paired a
   rate with a speed from a different moment would print a plausible number and
   say nothing.

EVERY CASE CALLS THE HARNESS. Nothing here recomputes a ratio: a test that
re-implements the thing it guards pins nothing, which is a defect this
repository has shipped twice.

Run: python3 scripts/test_speed_witness.py
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import speed_witness as W  # noqa: E402

CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


def rounded(x, n=4):
    return round(x, n)


def by_key():
    return {key: (label, pairs) for key, label, pairs in W.rows()}


# ===========================================================================
# A. THE ALIGNMENT GUARD. Each case perturbs one thing and requires the refusal.
# ===========================================================================

@case("A1 the two fixtures as committed align, so rows() returns both rows")
def _():
    got = [(key, len(pairs)) for key, _label, pairs in W.rows()]
    return got, [("calm", 4), ("choppy", 8)]


def _refuses(perturb):
    """Run rows() over a PERTURBED speed fixture; return the failure message.

    `perturb` takes the real load_speed() output and returns a damaged copy. The
    real loader is captured before the patch goes on, so the substitute never
    calls itself.
    """
    real = W.load_speed
    damaged = perturb(real())
    W.load_speed = lambda *a, **k: damaged
    try:
        W.rows()
        return "NO ERROR RAISED"
    except ValueError as exc:
        return str(exc)
    finally:
        W.load_speed = real


@case("A2 a dropped LAP line is refused, naming the row and the counts")
def _():
    def short(rows):
        key, label, laps = rows[0]
        return [(key, label, laps[:-1])] + rows[1:]
    msg = _refuses(short)
    return ("4 rate laps, 3 speed laps" in msg), True


@case("A3 a dropped SECOND is refused, naming the row, the lap and the counts")
def _():
    def short(rows):
        key, label, laps = rows[0]
        return [(key, label, [laps[0][:-1]] + laps[1:])] + rows[1:]
    msg = _refuses(short)
    return ("lap 0: 900 rate seconds, 899 speed seconds" in msg), True


@case("A4 rows in the wrong order are refused on the KEY, not silently paired")
def _():
    msg = _refuses(lambda rows: list(reversed(rows)))
    return ("row keys differ" in msg), True


@case("A5 a relabelled row is refused -- the label is the human-readable half "
      "of the identity and a mismatch means one fixture was regenerated alone")
def _():
    def relabel(rows):
        key, _label, laps = rows[0]
        return [(key, "something else", laps)] + rows[1:]
    msg = _refuses(relabel)
    return ("labels differ" in msg), True


# ===========================================================================
# B. THE PUBLISHED FIGURES, re-derived from the committed fixtures.
# ===========================================================================

@case("B1 the over-read populations: 98 calm seconds and 155 choppy, at 1.25x")
def _():
    d = by_key()
    return [len(W.over_read_seconds(d[k][1])) for k in ("calm", "choppy")], \
           [98, 155]


@case("B2 THE PUBLISHED HULL RATIOS -- 0.8144 calm, 0.6919 choppy. These are "
      "the two numbers the output-stage comment quotes, and the two that "
      "replace the retracted 0.851 / 0.916")
def _():
    d = by_key()
    return [rounded(W.hull_ratio(d[k][1])) for k in ("calm", "choppy")], \
           [0.8144, 0.6919]


@case("B3 THE CONTROL -- the same statistic over the seconds that are NOT "
      "over-reads sits at 1.0 to within 1.2%, so the figure in B2 is a "
      "property of the over-read seconds and not of the statistic")
def _():
    d = by_key()
    got = [rounded(W.control_ratio(d[k][1])) for k in ("calm", "choppy")]
    return [got, [v > 0.98 and v < 1.02 for v in got]], \
           [[0.9888, 0.9969], [True, True]]


@case("B4 the zero-speed sensitivity: dropping the 0.000 m/s seconds moves "
      "both rows UP, so keeping them is the conservative choice and not a "
      "filter chosen for the answer")
def _():
    d = by_key()
    kept = [W.hull_ratio(d[k][1]) for k in ("calm", "choppy")]
    dropped = [W.hull_ratio(d[k][1], drop_zero_speed=True)
               for k in ("calm", "choppy")]
    return [[rounded(v) for v in dropped], [d > k for d, k in zip(dropped, kept)]], \
           [[0.8402, 0.7771], [True, True]]


@case("B5 THE RETRACTION, as arithmetic: the sweep is 48 definitions per row, "
      "the calm range brackets the retracted 0.851 and the choppy range does "
      "not reach the retracted 0.916 -- which is why the pair is withdrawn")
def _():
    d = by_key()
    out = []
    for k in ("calm", "choppy"):
        sw = W.sweep(d[k][1])
        out.append((len(sw), rounded(min(sw.values())), rounded(max(sw.values()))))
    calm, choppy = out
    brackets_851 = calm[1] <= 0.851 <= calm[2]
    reaches_916 = choppy[2] >= 0.916
    return [out, brackets_851, reaches_916], \
           [[(48, 0.7890, 0.8666), (48, 0.5630, 0.7866)], True, False]


@case("B6 EVERY definition in both sweeps is below 1.0 -- the direction, which "
      "is the part of the claim the recorded-value change actually rests on")
def _():
    d = by_key()
    worst = max(max(W.sweep(d[k][1]).values()) for k in ("calm", "choppy"))
    return [rounded(worst), worst < 1.0], [0.8666, True]


# ===========================================================================

def main():
    bad = 0
    for name, fn in CASES:
        try:
            got, want = fn()
            ok = got == want
        except Exception as exc:  # noqa: BLE001 -- a raising case is a failure
            got, want, ok = "%s: %s" % (type(exc).__name__, exc), "no exception", False
        print("%-4s %s" % ("ok" if ok else "FAIL", name))
        if not ok:
            bad += 1
            print("       got  %r" % (got,))
            print("       want %r" % (want,))
    print("\n%d case(s), %d failed" % (len(CASES), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
