# Dispatch sizing: the band metric and the issue header

How many agents a task gets, decided **before** dispatch and recorded on the
issue. This file is the versioned, reviewable copy; the orchestrator role
definition carries the same rubric so it is in context at triage time without a
file read.

**Why this is the headline mechanism here.** Measured on the orchestration
session that produced this branch: **57 workflow dispatches, 200,263 KB of
subagent transcript**. The always-loaded agent-definition payload over the same
period was **24,119 bytes across three definitions** — at roughly 350 dispatches
that is about 8 MB, some 4% of the total. The cost is not the prompt. It is
**how many agents get dispatched, for what**. Recent runs used 20–31 agents for
work that included pure comment corrections.

---

## 1. The five axes

Score 0–3 on each, **before** choosing agents. The anchors below are this
repository's, not generic ones.

### R — Reversibility

**Name the revert, then say what it does not restore.** "It lands on `main`" is
true of every issue in the tracker and therefore separates nothing; what differs
is whether one commit is a complete remedy.

| | Here |
|---|---|
| **0** | `git revert` restores the prior state **and nobody outside this branch has read it yet**: a scratch file, an unpushed commit, a PR body no review has quoted |
| **1** | `git revert` is a complete remedy — the whole effect is inside the tree, and one commit puts it back. Source, tests, tooling, `monkey.jungle`, workflow text and documentation are all R=1 by default, and so is any issue or PR comment, which a later comment corrects **by naming what it corrects**. **This is the normal case, including for most bug fixes.** |
| **2** | the revert restores the tree and **not the world**: the change alters what a *shipped* build writes into a recorded `.fit`, so once it is in a release, files recorded before and after carry different semantics and no commit reconciles them (record-scope fields **latch**, `FACTS.md` §3.3 — the old values stay in files that will never be re-recorded); or `release-build` has already uploaded the artifact; or a workflow has already run with the changed credential or permission |
| **3** | irreversible by construction: a published release tag or asset (six exist, `FACTS.md` §5.5 — the tag can be deleted, a downloaded `.iq` cannot); the store package; a developer field **id** (`FACTS.md` §5.3 — ids are unique per `field_description`, so re-using one silently re-labels that field in **every file already recorded**, which no later commit can undo) |

Two rules that keep this axis from re-inflating:

* **If you cannot name an artifact outside this repository that the revert
  fails to reach, R is 0 or 1.** `main` being protected is a property of the
  branch, not of the change.
* **Score the change the issue commits to, not the most expensive option on the
  table.** An issue that asks for a *decision* scores the decision (R=1); the
  implementation is re-triaged when the decision lands. Breadth of remedy is
  what **S** measures.

### V — Verifiability cost

**0** means an existing automated check would catch the mistake without anyone
thinking about it. **3** means *nothing in this repository can catch it*. That
phrase has four concrete meanings here, all verified in `FACTS.md` §3.2:

| | Here |
|---|---|
| **0** | a `(:test)` already covers the seam, or one of the runner-free checkers derives it (`check_ceiling_notes`, `check_pip_geometry`, `check_step_fields`, `check_mc_literals`, `check_source_refs`, `check_agent_facts`) |
| **1** | a `(:test)` **could** cover it and this change adds one; compile-only coverage across the nineteen devices |
| **2** | only a static check can see it — anything that needs a `Session`, because **no `(:test)` can obtain one**, so `createField` is unreachable from the suite |
| **3** | **no `(:test)` can obtain a graphics `Dc`**, so real font metrics, clipping and rendering are invisible; **a comment cannot be red by any test**, because comments are stripped from the build; **nothing here decodes a file this app actually wrote**; and anything needing a real pod, a real erg or on-water conditions is **field-only** and belongs in a `[Local]` issue |

Three incident anchors for why V is the axis that gets under-scored:

* **The display cue was chosen on a figure from a machine that never shipped.**
  The analysis behind the `CUE_*` table "was a scratch script that was never
  committed, and it replayed a DIFFERENT machine from the one that shipped"
  (`scripts/cue_replay.py`). Nothing in the repository could regenerate the
  numbers; that is what V=3 feels like from the inside — it looks verified.
* **A pin that re-implemented the loop instead of calling it.** A case "was in
  fact exercising a private COPY of the comparison inside the test probe, and
  deleting both real clamp lines left all 308 cases green (measured, in the CI
  container, on fr965)" (`source/StrongRowView.mc:3336-3344`). A green suite is
  not V=0 evidence unless the test **calls** the thing. The same hole is
  recorded a second time at `source/DpsArcTest.mc:266-274`, read one file over
  "and repeated anyway".
* **A stale checkout answers with the wrong tree.** Measured 2026-08-28: the
  primary local checkout's `main` was **78 commits behind** `origin/main`
  (`0d69b83` → `211f106`), a fourteen-day gap. Findings taken from it are
  findings about code that was replaced two weeks ago. Read `origin/main`
  (`FACTS.md` §4.3).

### S — Settledness

| | Here |
|---|---|
| **0** | an accepted design comment exists on the issue and nothing has contradicted it |
| **1** | the fix is obvious and uncontested, no design comment needed |
| **2** | the issue names a symptom and more than one remedy is defensible |
| **3** | the premise is contested, or measured behaviour disagrees with the issue's own diagnosis |

### P — Prose surface

Prose is this repository's most defect-prone surface, and it has no compiler.
But "this change touches a comment" is nearly always true here and separates
nothing either. What makes prose expensive is a **second reader who cannot
check it against the code**: a second copy that drifts, or a consumer outside
the diff.

**Name the second reader.** P ≥ 2 requires naming the specific file, issue or
release that would also have to change. If you cannot name one, it is P ≤ 1.

| | Here |
|---|---|
| **0** | no prose changes, or the only prose is a comment restating the line below it: code, tests, fixture data |
| **1** | prose with exactly one reader — the next person to open that file. A source comment stating a **figure**, a **cross-reference** or a claim about runtime behaviour; a commit body; a PR body no review has quoted yet. Wrong here is corrected by editing it. **This is the normal case, and it is where most of this repository's comment work sits.** |
| **2** | prose the repository keeps a **second copy** of, or that another artifact **cites**, so a wrong word has to be fixed in two places or it drifts: a `CEILING` note (`scripts/check_ceiling_notes.py` requires the copies byte-identical); a fact `docs/agents/FACTS.md` also states; a comment a second file quotes or defers to; a `[Local]` issue's byte-exact pass criteria; an issue or PR body another open issue cites **by number** |
| **3** | prose published outside this branch's diff, where the reader cannot check it against the code: `README.md`, a release note, the store description, `docs/CI.md`'s merge-gate contract, `docs/agents/**`, `docs/AGENT_PROMPT.md` / `docs/CODE_REVIEW_AGENT.md`, a `field_description` **name or units string** a FIT consumer decodes |

`agent-prompt-guard` covers the last pair, and it is worth knowing exactly what
it does: it checks **who** may edit `docs/AGENT_PROMPT.md` and
`docs/CODE_REVIEW_AGENT.md` (`.github/workflows/ci.yml:689-691`), never what
any file contains. No job reads the prose. P=3 is a *human* review obligation.

### I — Interaction

**Name the open PR, the pushed branch, or the pinned budget.** An open *issue*
naming the same file is **I=0 evidence**: issues do not merge, branches do. With
91 issues open and `source/StrongRowView.mc` at 7,306 lines (both measured at
`9b2801c`), "another issue touches this file" is true of almost everything.

| | Here |
|---|---|
| **0** | one file, no shared constant, no pinned budget, and nothing in flight touches it |
| **1** | a shared constant, helper, probe or fixture with a named consumer in the tree — change it and you have to read the consumer — but nothing in flight |
| **2** | the change spends a **pinned shared budget** or edits one half of a **hand-synced pair**: a file-scope `(:test)` (it spends `fenix6` `globals` headroom — current figure in `FACTS.md` §5.1, never copied here); `scripts/expected_tests.txt`; a fixture two suites read; either copy of anything `scripts/check_ceiling_notes.py` or `scripts/check_source_refs.py` requires to agree; either of the two files `agent-prompt-guard` restricts the authorship of. **Or** an open PR or a pushed-unmerged branch edits the same *function or table* |
| **3** | a contract every branch inherits, so a conflict is with all of them at once: `manifest.xml`'s product list, `.github/workflows/ci.yml`, `monkey.jungle`, `scripts/list_devices.sh` (it **is** the CI device matrix, `FACTS.md` §1.4, called at `ci.yml:353`, `:436`, `:550`), `scripts/run_ciq_tests.sh`, a developer field id, or `source/StrongRowView.mc`'s `startSession` |

I=2 for a collision is **checked, not assumed**, with two commands:

```sh
gh pr list --state open --limit 50 --json number,headRefName,title
git fetch origin && git branch -r --no-merged origin/main
```

Measured at `9b2801c` on 2026-08-28: **zero** open PRs, and **one** pushed
unmerged branch — `origin/claude/core-p1-bundle`, touching
`scripts/expected_tests.txt`, `source/CoreP1Test.mc`, `source/CoreTempSensor.mc`
and `source/StrongRowView.mc`. The figure is not the point and will be stale
within the day; running the two commands is.

---

## 2. The band

| Band | Score | Dispatch |
|---|---|---|
| **Trivial** | 0–3 | no agent — the orchestrator does it inline |
| **Routine** | 4–6 | one small-tier implementer, no gate *(but see the guardrail)* |
| **Standard** | 7–9 | one large-tier implementer + one large-tier reviewer |
| **Heavy** | 10–12 | implementer + 3-lens gate + consolidating verdict |
| **Critical** | 13–15 | implementer + 4–5 lens gate, **re-gate after every fix round** |

### The tier ladder, and what is not on it

`implementer=` runs **small → medium → large**. Exhaustive multi-agent mode
(`ultracode`) is a **flag on top of Critical, never a rung on the implementer
ladder**: it adds parallel lens fleets and adversarial verification *over* the
band's dispatch, and it never changes which model implements. It appears only
at Critical, or when the owner names it. A premium stall-breaker model, if one
is kept, stays **off the ladder entirely** — reached by escalation (four failed
rounds on one task), never by triage.

### Guardrails

* **A pure-prose change to a published contract is Standard minimum**, whatever
  the line count. P=3 alone floors the band at Standard.
* **Strike "no gate" from Routine whenever P ≥ 2 or R ≥ 2** — minimum one
  small-tier review lens. Under the re-anchored R (§1), R ≥ 2 is **no longer**
  the normal case, so this now bites on the work it was written for — prose with
  a second reader, and changes to what a shipped build records — rather than on
  everything. Say in the header which of the two triggered it, or that neither
  did. The gate that never depends on the band is `ci-required`: every landed
  change passes the **six** jobs its `needs:` list names, on a protected `main`,
  whatever its score.
* **Proposal review is band-governed too.** Trivial and Routine skip it;
  Standard gets a small-tier design review; Heavy and Critical get the full
  reviewer. Otherwise cheap tasks pull expensive design verdicts.
* **Concurrency limits cap how many agents run AT ONCE, never the band.** One
  build slot, one simulator, finite RAM: a Critical task on a loaded machine
  runs its lenses **serially**, not with fewer of them.

### Escalation is automatic, not discretionary

Any of these raises the band **by one step** mid-task — Trivial → Routine →
Standard → Heavy → Critical, and Critical is the ceiling. The raise is recorded
as a comment so the history is auditable:

* a gate returns blocking findings → **+1 band** for the fix round;
* a fix round introduces a new false claim → **+1 band**, and the next round is
  constrained to **subtraction only**;
* the same claim is wrong twice → **delete it**, **+1 band** (do not reword a
  third time);
* measured behaviour contradicts the issue's diagnosis → **re-triage** from
  zero, do not patch forward;
* a test that should have failed did not → **+1 band**, the check is blind (this
  is the `jouleClampBench` shape: 308 green cases and both real clamp lines
  deleted).

The unit is a **band, not a point**. A point would leave most escalations inside
the band they started in, which is not a raise at all.

An escalated band is recorded in the escalation comment, not by rewriting the
header's axis line — the header keeps its triage scores, and the axis-sum rule
at §3 governs headers at filing and triage only. Re-score the axes only if the
issue changed materially.

**De-escalate only** after two consecutive clean gates, and **never below
Standard while R ≥ 2**. That floor used to apply to everything, because R ≥ 2
used to be universal; under §1 it applies to the two cases it was meant for —
a change to what a shipped build records, and anything already published.

---

## 3. The header

One line near the top of every issue, set at filing or triage:

```
Dispatch: band=<Trivial|Routine|Standard|Heavy|Critical> (R# V# S# P# I# = total) | implementer=<tier>/<low|medium|high> | reviewers=<n>×<tier>[ + consolidator] | ultracode=<yes|no>
```

Rules:

* The header is the **opening guess**. Escalation still raises it mid-task.
* The dispatcher **reads the header instead of re-scoring**; re-score only if
  the issue changed materially.
* `ultracode=yes` appears only at Critical, or when the owner names it.
* No stall-breaker tier appears in any header.
* The axis sum must match the band. A header whose arithmetic does not close is
  a defect in the header, not a judgement call.

Example, for a change that **adds a developer field** — re-derived under the
re-anchored axes, and it is the one shape that reaches Critical on its own:

```
Dispatch: band=Critical (R3 V3 S1 P3 I3 = 13) | implementer=large/high | reviewers=4×large + consolidator | ultracode=no
```

R3 and I3 are the same fact counted on two axes on purpose — an **id** is
irreversible once a file is recorded with it (§5.3 of `FACTS.md`) *and* it is a
contract every branch shares. P3 is the `field_description` name and units
string, which a decoder reads and no job here checks. V3 because no `(:test)`
can obtain a `Session`, so `createField` is unreachable from the suite.

The arithmetic lesson, on a different line — #175's re-scored header:

```
Dispatch: band=Heavy (R2 V3 S3 P2 I2 = 12) | implementer=large/high | reviewers=3×large + consolidator | ultracode=no
```

Written `band=Critical` that would be **wrong**: 2+3+3+2+2 = 12, and 12 is
Heavy. Check the arithmetic every time you read a header — the band, not the
word, decides the dispatch.

---

## 4. Worked examples from this repository's own history

All five are re-derived under the re-anchored R, P and I of §1. Where a score
changed, the reason is named; where it did not, that is said too, because a
re-anchoring that moved every example by the same amount would be a rescale and
not a re-anchoring.

**#141 — "The CT status-row geometry tables in StrongRowView do not reproduce
from the shipped constants"** (closed at `211f106`). Entirely comment prose;
the geometry was fine and the numbers were not.

* *As it stood when filed*: **R1** (a revert is a complete remedy — a comment
  block, nothing outside the tree) V3 (a comment cannot be red by any test, and
  no checker existed) S1 **P2** (the tables were a **second copy** of the
  shipped constants — that is precisely what the title reports, so the second
  reader has a name) **I1** (shared layout constants with named consumers,
  nothing in flight) = **8, Standard**.
* *The same change today*, with `scripts/check_pip_geometry.py` in the tree
  deriving every row: R1 **V0** S0 P2 I1 = **4, Routine** — and the P≥2
  guardrail strikes "no gate", so it is Routine **plus one lens**. V=0 because
  an existing runner-free checker derives it, which is the §1 V=0 cell
  verbatim; `check_pip_geometry.py` runs at `.github/workflows/ci.yml:167`.

Both scorings land in the band they landed in before the re-anchoring
(Standard, then Routine): P was already carrying its weight here, because the
comment really did have a second reader. The metric asks for **two agents, or
three**. The run that carried it used 31. That is the gap this file exists to
close, and it does not depend on which scoring you prefer.

**#46 — "`rr_interval` re-emits the previous batch's beats during a dropout"**
(open). A change to what a live session records — the canonical **R=2**.

**R2** (a revert restores the tree; it does not un-record the `.fit` files a
released build already wrote, and record-scope fields **latch**, `FACTS.md`
§3.3, so the naive fix — skipping the write — fabricates data rather than
omitting it) V2 (no `(:test)` can obtain a `Session`; only a static check or a
`[Local]` decode sees it) S2 (skip-vs-sentinel is a real design choice) **P2**
(the issue names *two* comment corrections the evidence forces, one of them in
the #14 note — a second copy by its own account) **I2** (the fix adds `(:test)`
cases, so `scripts/expected_tests.txt` moves in the same commit) = **10,
Heavy** — unchanged in every axis. This is the band where a 3-lens gate earns
its cost, and the re-anchoring leaves it exactly where it was.

**#172 — "[Local] Decode a StrongRow .fit for `step_type` / `interval_num`"**
(open). **R1** (the deliverable is a decoded byte pattern written back as a
comment) V3 by construction — nothing in the repository decodes a file this app
wrote — S1 **P2** (byte-exact pass criteria, cited by #154 and #171) **I0** (no
source change at all) = **7, Standard**, down from 12/Heavy. It is **field-only**,
so it is not an implementation task: a `[Local]` issue with a human at a decoder.
Sizing it as implementable work is the mis-dispatch; the band is for the
*analysis* that follows the measurement, not for the measurement. The old score
was asking for a 3-lens gate and a consolidator to supervise somebody plugging
in a watch.

**#160 — "the no-model-identifier rule is enforced by no CI job"** (open). The
example that goes **up**. **R1** (a revert removes the job) **V1** (no check
exists yet and this change **adds** one — the §1 V=1 cell, not V=0, which
requires a checker already in the tree) S1 **P3** (a new **required** job has to
be added to `docs/CI.md`'s job table, or it recreates #100 — `docs/CI.md` is the
named second reader, and it is a `docs/**` file) **I3**
(`.github/workflows/ci.yml`, which every branch inherits) = **9, Standard** —
one point *higher* than the 8 it scored before, same band. Asserting the rule in
a document and calling it enforced is how it went unenforced for months in the
first place.

For the record, both #141-today and #160 were also corrected once **under the
old anchors** — #141-today 5 → 4, Routine either way; #160 7 → 8, Standard
either way — and that correction is separate from this re-derivation. It is
recorded because §5 calibrates on these examples and the error ran in the exact
direction §5 warns about: an axis score that does not match its own anchor cell.

**Trivial, for contrast**: correcting a `file:line` in a PR body you authored,
**before any review has read it**. R0 V1 S0 P1 I0 = **2**. The orchestrator does
it inline. Once a reviewer has quoted that body it is no longer Trivial, and the
axis that moves is **P, not R**: the body now has a second reader, so P rises to
2 while R stays 1 — R1 V1 S0 P2 I0 = **4, Routine**, plus one lens from the P≥2
guardrail. The correction now has to name what it corrects.

---

## 5. Backfilling the existing backlog

**Not done on this branch, and it must not be** — it depends on the anchors in
§1 being settled first. `FACTS.md` §5.4 records **93** open at 2026-08-28,
pinned at `211f106`; re-measured on the same date at `9b2801c` the figure is
**91**, of which **89** carry a `Dispatch:` header. Both are right for their
pin; the number drifts daily and neither is load-bearing.

**89 headers written under the *old* anchors are now stale.** Re-scoring them is
the follow-up pass described here, not a task for the branch that changes the
anchors — a bulk rewrite would land 89 unreviewed judgements on top of a rubric
change that had itself only been checked against 28 of them (§6).

The pass, when it is run: batch the open issues (~12 per scorer); small-tier
scorers apply the rubric and **prepend** the header, leaving the original body
byte-preserved; a scorer that cannot score an issue leaves it and says why
rather than guessing. Then one large-tier **calibration pass** re-scores two per
batch at band boundaries, fixes anything off by a band, resolves the unscored,
and sweeps for rule violations — no stall-breaker tier in any header, no
`ultracode=yes` below Critical, every axis sum matching its band, and every
axis *score* matching its own anchor cell in §1 rather than only the sum
matching.

Expect scorers to run **low on V** — check which component a cited line actually
lives in before believing a check covers it.

Expect them to run **high on R, P and I**, which is the direction §1 was
re-anchored to stop, and the three failures have three different shapes:

* **R** — scoring 2 because the change lands on `main`. Everything lands on
  `main`. Name the artifact the revert does not reach, or score 1.
* **P** — scoring 2 because a comment states a figure. Name the second reader,
  or score 1.
* **I** — scoring 2 because a *sibling issue* names the same file. That is the
  inverse of the old advice on this line, and it is the correction: issues do
  not merge. Run `gh pr list` and `git branch -r --no-merged origin/main`, and
  score what those return.

---

## 6. What the re-anchoring of R, P and I did, measured

The R, P and I cells in §1 were rewritten because all three had gone constant.
Measured over the whole backlog at `9b2801c` on 2026-08-28 — 91 open, **89**
carrying a `Dispatch:` header:

| axis | 0 | 1 | 2 | 3 |
|---|---:|---:|---:|---:|
| **R** | 0 | 0 | **89** | 0 |
| V | 0 | 35 | 10 | 44 |
| S | 6 | 36 | 34 | 13 |
| **P** | 0 | 5 | **56** | 28 |
| **I** | 0 | 2 | **71** | 16 |

R contributed the same 2 to every issue in the tracker: zero variance, so zero
information. P was ≥2 on 94%, I on 98%. Before V or S was read at all the floor
was 2+2+2 = **6 of 15** — already Routine, with Standard one V=3 away. The
resulting bands were Trivial 0, Routine 1, Standard 30, Heavy 54, Critical 4:
**61% of the backlog asking for a 3-lens gate plus a consolidator**, in a file
whose opening paragraph names over-dispatch as the defect it exists to fix.

### The fix that was proposed, and not taken

Make R a gate rather than a summand and re-baseline every cut-point down by 2.
It moves **zero** issues, and that is arithmetic rather than opinion: R is
exactly 2 on all 89, so every total falls by exactly 2 while every threshold
falls by exactly 2. Run over the 89 headers it returns Trivial 0, Routine 1,
Standard 30, Heavy 54, Critical 4 — identical, with **0** issues changing band.
The diagnosis (R was doing no work) was right; the remedy was a translation and
could not act on it. `scripts/dispatch_rescore.py` now **fails** on any change
of that shape, so it cannot be re-proposed and shipped unnoticed.

### The re-scored sample

28 real issues, re-scored under the §1 cells with **V and S held at their header
values**, so whatever moves is attributable to R, P and I alone. The worksheet
is `scripts/fixtures/dispatch_rescore_9b2801c.tsv`: one row per issue carrying
the original `Dispatch:` header verbatim and a **named reason** for each new R,
P and I, so each judgement can be disagreed with individually. 24 were drawn by
a deterministic stratified rule over the current bands; 4 more were added
deliberately, marked `supplementary`, to reach the P=3 documentation cell the
draw missed.

Every figure below is derived by `python3 scripts/dispatch_rescore.py`, which
runs in `test-tooling` and reds if these lines and the worksheet disagree:

    DISPATCHCAL sample 28
    DISPATCHCAL before Trivial 0 Routine 1 Standard 9 Heavy 14 Critical 4
    DISPATCHCAL after Trivial 2 Routine 4 Standard 12 Heavy 10 Critical 0
    DISPATCHCAL agents before median 5 mean 4.07
    DISPATCHCAL agents after median 2 mean 2.82
    DISPATCHCAL rpi before mean 6.46
    DISPATCHCAL rpi after mean 4.25

**Cost.** Median agents per issue **5 → 2**; mean **4.07 → 2.82**. The R+P+I
subtotal, the only part this branch touched, falls from a mean of 6.46 to 4.25,
and its floor from 6 to 1. Critical empties, 4 → 0. Work at Heavy or above falls
from 18 of 28 (64%) to 10 of 28 (36%). 16 of the 28 changed band.

**It is not a rescale.** The per-issue drop is not constant. Counting
`before − after`: **−1** on one issue (#160 went *up* — a new required job has
to be documented in `docs/CI.md`), **0** on one (#46, unmoved on all five axes),
then 1 on eight, 2 on seven, 3 on four, 4 on six and 5 on one. A translation
would put all 28 in a single column.

**Every re-anchored axis now varies.** Across the 28: R takes 1 (×23) and 2
(×5); P takes 1 (×10), 2 (×15) and 3 (×3); I takes 0 (×10), 1 (×2), 2 (×13) and
3 (×3).

### The half of the acceptance test that failed

The test this section had to pass was *"if the distribution is still crowded
into one or two bands, the re-anchoring failed"*. **It is still crowded, and
saying so is the point of writing it down.**

* Two adjacent bands held 23 of 28 (82%) before — Standard and Heavy. They hold
  22 of 28 (**79%**) after — Standard and Heavy. Essentially unchanged.
* The largest single band was 50% (Heavy) and is 43% (Standard).
* Four of five bands were populated before and four of five after; the empty one
  moved from Trivial to Critical.

So the re-anchoring is a **real reduction in dispatch cost and not a cosmetic
edit** — median agents halved and Critical emptied, which no rescale could have
done — and it is **not sufficient** to make the metric discriminate.

The reason is nameable, and it is no longer R, P or I: **V is now the binding
axis.** V=3 on 44 of 89 (49%), because its 3 cell — "a comment cannot be red by
any test", "nothing here decodes a file this app wrote" — is reachable by almost
every issue in a repository that can verify almost nothing end to end. #100 is
the demonstration: adding one row to a table in `docs/CI.md` scores
R1 V3 S1 P3 I2 = **10, Heavy** — a 3-lens gate and a consolidator, for a table
row — and R, P and I are not why.

**The next calibration pass is V, and it must be run the same way**: rewrite the
cells, re-score a sample of real issues, publish the histogram from a committed
worksheet, and refuse to ship on assertion. A rubric change validated by
argument is the failure this section exists to stop repeating. Filed as **#184**
— not folded in here, because a second axis re-anchored in the same branch could
not be attributed to either.

Note that `scripts/dispatch_rescore.py` currently **enforces** that V and S are
held between the before- and after-scores, which is what made this section
attributable. The V pass has to relax that guard deliberately and update the
self-test with it, rather than discovering it as an obstacle.

### What this section is not

* It is **28 of 89 (31%)**, stratified across the current bands but not a random
  draw, and four of the rows were picked to reach a cell.
* The 28 after-scores are **one scorer's judgement** applied to issue bodies,
  not a measurement. The per-row reasons in the worksheet are the only defence
  offered, and they are offered so each can be attacked separately.
* No CI job has network. The harness checks the before-scores against the
  **committed** header strings, never against the live issues; re-read the
  issues before quoting any of this.
* The 89 headers themselves are **not** re-scored here. That is §5's follow-up
  pass, and it should run only once these anchors are agreed.
