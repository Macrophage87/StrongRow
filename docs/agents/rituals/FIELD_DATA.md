# Ritual: ingesting field data from a FIT

Read this **when a recording is about to become evidence** — when a `.fit` from
a real row is going to justify a number, a threshold or a display decision.

This is the ritual with the worst track record in the repository. Both of the
harnesses in `scripts/` exist because a figure derived from field data shipped
and could not be regenerated afterwards.

Facts and commands: `docs/agents/FACTS.md`.

---

## 1. The rule

**A recording is not evidence until something committed can regenerate every
figure taken from it.**

`scripts/cue_replay.py` exists because the analysis behind the `CUE_*` table
"was a scratch script that was never committed, and it replayed a DIFFERENT
machine from the one that shipped". `scripts/speed_witness.py` exists because
the published pair 0.851 / 0.916 turned out not to be reproducible from the
recordings at all.

No `.fit` file is committed to this repository (`git ls-files` matches none).
What is committed is a **text fixture plus its provenance**, so a reader with
any FIT decoder can rebuild it from the originals.

## 2. The fixture

One series per file, and `scripts/fixtures/` holds the four that exist:

| File | Series | Read by |
|---|---|---|
| `cue_work_laps.txt` | per-second `row_stroke_rate` for the work laps of two recordings | `cue_replay.py` |
| `lock_guard_speed.txt` | per-second `enhanced_speed` for **the same laps, in the same order, second for second** | `speed_witness.py` |
| `cue_reversal_row.txt` | per-second `row_stroke_rate` for the eight work intervals of `i183553852` | `cue_replay.py` |
| `start_carryover.txt` | seven named series over the first 216 s of `i183553852` — session start through the end of work interval 1 | `start_witness.py` |

**Do not widen a fixture; add a companion.** `cue_replay.py` consumes
`cue_work_laps.txt` positionally and that file's header promises "NOTHING BUT
STROKE RATE IS HERE". Adding a speed column would make every cue figure depend
on a series the cue never sees. The second file states its own reason for
existing in exactly those terms, and the third repeats the promise verbatim —
its header names the `rate_base`, cadence and speed series that another change
wanted and says they are "NOT here and must not be added".

**The fourth file is a stated exception, and the shape of the exception is the
rule.** `start_carryover.txt` carries seven series, because the question it
exists for *is* the relationship between seven quantities **at the same
second** — whether a number on screen came from a baseline established before
START. Splitting them into seven files and re-zipping them would move the
alignment risk without reducing it. What pays for the exception is the two
things this section actually protects:

* **no positional consumption** — every series is on its own `SERIES <name>`
  line and is read by name, so nothing can silently shift by a column;
* **alignment is a refusal, not a best effort** — `start_witness.load()` raises
  if any two series differ in length, and `test_start_witness.py` B2 drives that
  refusal. That is `speed_witness.py`'s rule ("the two fixtures zipped, with
  alignment CHECKED rather than assumed") applied inside one file instead of
  across two.

A multi-series fixture that lacks either property is a widening, not an
exception. Say which you are doing, in the file's own header.

**When two fixtures must stay aligned, the harness enforces it.**
`speed_witness.py`'s `rows()` returns "the two fixtures zipped, with alignment
CHECKED rather than assumed", raising rather than pairing "a rate with a speed
from a different moment". A refusal is the correct behaviour; a best-effort
number over misaligned rows is worse than none.

## 3. The provenance block is not optional

Every fixture header carries enough to reproduce it "from the originals with
any FIT decoder". Copy the shape — this is `cue_work_laps.txt`'s block, with
the precision line's trailing sentence elided into the bullet below it:

```
# PROVENANCE, so this is reproducible from the originals with any FIT decoder:
#   source files   i171679853.fit (calm), i172336333.fit (choppy)
#   values         the 'row_stroke_rate' DEVELOPER FIELD of record messages
#                  (FIT global message 20), in timestamp order
#   lap boundaries lap messages (FIT global 19), start_time (field 2) inclusive
#                  to timestamp (field 253) exclusive
#   work laps      calm  -- total_elapsed_time (field 7) >= 600 s
#                          -> 4 laps, 3522 seconds, 3496 carrying a reading
#                  choppy -- total_elapsed_time within 5 s of 180 s
#                          -> 8 laps, 1442 seconds, 1436 carrying a reading
#   precision      float32 in the file, written here to 4 decimal places with
#                  trailing zeros stripped
```

Every one of those lines is load-bearing:

* **the message and field numbers**, not just the field name;
* **the boundary convention spelled out** — `start_time` *inclusive* to
  `timestamp` *exclusive*. Off by one lap boundary and every median moves;
* **the selection rule** for which laps count, with the resulting counts, so a
  reader knows immediately whether they reproduced the same set;
* **the precision and what it is exact for.** The cue fixture states that 4
  decimal places is exact for every band edge (15, 16, 18, 20) and 1e-4 spm
  elsewhere, "which cannot move a zone decision" — the precision claim is tied
  to the decision it must not perturb, not asserted in the abstract.

## 4. State the absence encoding, always, even when there isn't one

The two fixtures use **opposite** conventions and both say so:

* `cue_work_laps.txt`: "A value of 0 is the app's NO-DATA SENTINEL, not a slow
  stroke: `outputRate()` returns 0.0 when nothing has been measured".
* `lock_guard_speed.txt`: "**0 IS A REAL READING HERE** … `enhanced_speed` has
  no such convention: 0.000 m/s is a legal speed, and 34 calm / 30 choppy
  work-lap seconds carry exactly that. No second of either row is MISSING
  `enhanced_speed`, so this file needs no absence encoding at all -- which is
  stated rather than left to be noticed, because inventing one later would
  silently redefine the 0s already written here."

That last clause is the whole rule. **Absence must be a distinct state, and
which state it is must be written down before anyone needs it.** Absence
rendered as a value is one of this repository's named defect classes: a missing
reading displayed as "below target" makes the athlete correct toward a number
that was never measured.

## 5. Publish a range, not a point, until the definition is pinned

`speed_witness.py`'s `sweep()` "evaluates 48 definitions per row — every
combination of {per-lap, per-row, mean-of-lap} rate baselines × {per-lap,
per-row} speed baselines × {median, mean} for that baseline × {mean of
per-second ratios, median of them, ratio of means, ratio of medians}" and
prints the range.

That is what caught the retracted pair: the calm range brackets 0.851, and the
choppy range "does NOT reach 0.916 under any of them", so the published pair
"cannot have come from one consistent definition". **A single number with no
stated definition is not a measurement.** If the direction is what matters,
report the direction and the range that supports it — the retraction's
surviving claim is that all 96 sweep values sit below 1.0, which is a stronger
statement than either point estimate was.

## 6. Cross-checks a reader can run in two minutes

Every fixture header ends with them, and they are pinned by the suite:

```
#   choppy work-lap medians  16.5, 15.0, 14.2, 15.2, 13.2, 14.3, 16.1, 16.0 (B2)
#   calm   work-lap medians  20.3, 20.3, 19.2, 21.3                         (B3)
#   choppy peak              37.5 spm, six consecutive seconds at a lap start
```

A reader who decodes the originals can confirm in one pass that they have the
same laps. Without them, "I could not reproduce your number" and "I decoded a
different lap set" are indistinguishable.

## 7. What field data cannot settle

* **Nothing in this repository decodes a file this app actually wrote.**
  `scripts/fit_step_marks.py` builds synthetic bytes and "proves the QUERY side
  only" (`.github/workflows/ci.yml`, the acceptance-criterion step's comment —
  the sentence is the workflow's, not the script's). A recording tells you what
  a *decoder* read out of a file some firmware wrote; it does not tell you what
  *this app's* `setData` calls produced.
* **Record-scope developer fields latch** (`FACTS.md` §3.3). A flat run of
  identical values in a recording may be a real steady state **or** a skipped
  write re-emitting. The recording alone cannot distinguish them.
* Anything needing a real pod, a real erg or on-water conditions is
  **field-only** and gets a `[Local]` issue: `[Local]` title prefix, opening
  ⚠️ blockquote, `local-test` label, byte-exact pass criteria
  (`FACTS.md` §3.4). Open examples: #172, #173, #81, #82.

## 8. Retract at the quotation site, not just in the analysis

When a published figure turns out to be wrong, the retraction goes **both**
places: in the harness that now prints the correct one, and at every comment
that quoted the old one, naming the old figure. `speed_witness.py` states its
retraction "here and at the quotation site rather than edited away", and the
replacement figures are noted as being **worse** for the hull rather than
better — because a retraction that only ever moves numbers in the flattering
direction is not a retraction, it is a revision.

---

## Mid-work hazards

* **Never `git add .` / `-A` / `commit -a`** (`FACTS.md` §4.2).
* **`set -o pipefail`** for anything whose result you quote (`FACTS.md` §2.6).
* Fixtures are text and land in the tree under `core.autocrlf=true`
  (`FACTS.md` §4.1) — check what a consumer does with line endings before
  trusting a local run.
