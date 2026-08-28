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

| | Here |
|---|---|
| **0** | a scratch file, an unpushed commit, a PR body you can edit again |
| **1** | a pushed-but-unlanded commit on a feature branch (amendable — see the landing ritual) |
| **2** | anything that lands on `main`; any issue or PR comment posted under the owner's account |
| **3** | a published release asset or tag; the store package; a developer field **id** (§5.3 of `FACTS.md` — ids are unique per `field_description` and re-using one silently re-labels a field in every file already recorded) |

`main` is protected and merges go through `ci-required`. Landed history is
never rewritten; its errors are corrected in the next commit's body. That makes
**R ≥ 2 the normal case**, which is why the de-escalation floor below is where
it is.

### V — Verifiability cost

**0** means an existing automated check would catch the mistake without anyone
thinking about it. **3** means *nothing in this repository can catch it*. That
phrase has four concrete meanings here, all verified in `FACTS.md` §3.2:

| | Here |
|---|---|
| **0** | a `(:test)` already covers the seam, or one of the runner-free checkers derives it (`check_ceiling_notes`, `check_pip_geometry`, `check_step_fields`, `check_mc_literals`, `check_source_refs`, `check_agent_facts`) |
| **1** | a `(:test)` **could** cover it and this change adds one; compile-only coverage across the twelve devices |
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

| | Here |
|---|---|
| **0** | no published words change |
| **1** | a code comment that states no number and no cross-reference |
| **2** | a code comment that states a **figure**, a **cross-reference** or a **property**; a commit body; a PR body |
| **3** | `README.md`, `docs/**`, an agent operating prompt (`docs/AGENT_PROMPT.md` and `docs/CODE_REVIEW_AGENT.md` are guarded by a required CI job), a release note, the store description, an issue body that others will cite |

### I — Interaction

| | Here |
|---|---|
| **0** | one file, no shared constant |
| **1** | a shared constant with one consumer |
| **2** | a file another open branch is also editing; anything that adds a file-scope `(:test)` (the `fenix6` `globals` ceiling has **7 free** at `211f106` — `FACTS.md` §5.1); anything touching `scripts/expected_tests.txt` |
| **3** | a manifest device change, a workflow change, a developer field id, `source/StrongRowView.mc`'s `startSession` — several in-flight branches routinely touch it |

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
  small-tier review lens. Since R ≥ 2 is the normal case here (anything landing
  on `main`), in practice **Routine on this repository almost always carries one
  lens**. Say so in the header rather than letting the reader assume.
* **Proposal review is band-governed too.** Trivial and Routine skip it;
  Standard gets a small-tier design review; Heavy and Critical get the full
  reviewer. Otherwise cheap tasks pull expensive design verdicts.
* **Concurrency limits cap how many agents run AT ONCE, never the band.** One
  build slot, one simulator, finite RAM: a Critical task on a loaded machine
  runs its lenses **serially**, not with fewer of them.

### Escalation is automatic, not discretionary

Any of these raises the band mid-task, and the raise is recorded as a comment so
the history is auditable:

* a gate returns blocking findings → **+1** for the fix round;
* a fix round introduces a new false claim → **+1**, and the next round is
  constrained to **subtraction only**;
* the same claim is wrong twice → **delete it**, +1 (do not reword a third
  time);
* measured behaviour contradicts the issue's diagnosis → **re-triage** from
  zero, do not patch forward;
* a test that should have failed did not → **+1**, the check is blind (this is
  the `jouleClampBench` shape: 308 green cases and both real clamp lines
  deleted).

**De-escalate only** after two consecutive clean gates, and **never below
Standard while R ≥ 2**.

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

Example, for a change that adds a developer field:

```
Dispatch: band=Heavy (R3 V3 S1 P2 I3 = 12) | implementer=large/high | reviewers=3×large + consolidator | ultracode=no
```

The same line written `band=Critical` would be **wrong**: 3+3+1+2+3 = 12, and
12 is Heavy. Check the arithmetic every time you read a header — the band, not
the word, decides the dispatch.

---

## 4. Worked examples from this repository's own history

**#141 — "The CT status-row geometry tables in StrongRowView do not reproduce
from the shipped constants"** (closed at `211f106`). Entirely comment prose;
the geometry was fine and the numbers were not.

* *As it stood when filed*: R2 (lands on `main`) V3 (a comment cannot be red by
  any test, and no checker existed) S1 P2 (comment prose stating figures) I1 =
  **9, Standard**.
* *The same change today*, with `scripts/check_pip_geometry.py` in the tree
  deriving every row: R2 **V1** S0 P2 I0 = **5, Routine** — and the P≥2
  guardrail strikes "no gate", so it is Routine **plus one lens**.

Either way the metric asks for **two agents, or three**. The run that carried
it used 31. That is the gap this file exists to close, and it does not depend on
which of the two scorings you prefer.

**#46 — "`rr_interval` re-emits the previous batch's beats during a dropout"**
(open). A change to what a live session records.

R2 V2 (no `(:test)` can obtain a `Session`; only a static check or a `[Local]`
decode sees it) S2 (skip-vs-sentinel is a real design choice) P2 I2 =
**10, Heavy**. Record-scope fields **latch** (`FACTS.md` §3.3), so the naive fix
— skipping the write — fabricates data rather than omitting it. This is the
band where a 3-lens gate earns its cost.

**#172 — "[Local] Decode a StrongRow .fit for `step_type` / `interval_num`"**
(open). V=3 by construction: nothing in the repository decodes a file this app
wrote. It is **field-only**, so it is not an implementation task at all — it is
a `[Local]` issue with byte-exact pass criteria and a human at a decoder. Sizing
it as implementable work is the mis-dispatch; the band is for the *analysis*
that follows the measurement, not for the measurement.

**#160 — "the no-model-identifier rule is enforced by no CI job"** (open). A
tooling change: R2 V0 (a checker would catch it by definition, and a checker is
the deliverable) S1 P1 I3 (`.github/workflows/ci.yml`, which every branch
touches) = **7, Standard**. Note V=0 is only honest **because the change ships
the check**; asserting the rule in a document and calling it enforced is how it
went unenforced for months in the first place.

**Trivial, for contrast**: correcting a `file:line` in a PR body you authored,
before any review has read it. R0 V1 S0 P1 I0 = **2**. The orchestrator does it
inline. Once a reviewer has quoted that body, R rises to 2 and it is no longer
Trivial — the correction now has to name what it corrects.

---

## 5. Backfilling the existing backlog

**Not done on this branch, and it must not be** — it depends on this file
existing first. 93 issues were open at 2026-08-28 (`FACTS.md` §5.4).

The pass, when it is run: batch the open issues (~12 per scorer); small-tier
scorers apply the rubric and **prepend** the header, leaving the original body
byte-preserved; a scorer that cannot score an issue leaves it and says why
rather than guessing. Then one large-tier **calibration pass** re-scores two per
batch at band boundaries, fixes anything off by a band, resolves the unscored,
and sweeps for rule violations — no stall-breaker tier in any header, no
`ultracode=yes` below Critical, every axis sum matching its band.

Expect scorers to run **low**, concentrated on **V** (check which component a
cited line actually lives in before believing a check covers it) and **I**
(collisions a *sibling* issue names, which a scorer reading one issue cannot
see).
