# The gate protocol

Read this when gating, re-gating, or writing a verdict. It governs where a
verdict lives, what a round records, what a re-gate is allowed to read, who is
allowed to write the verdict, and how many times the suite is measured.

Facts and canonical commands: `docs/agents/FACTS.md`. Sizing: `DISPATCH.md`.

---

## 1. Verdicts are files

The reviewer or consolidator **writes the verdict to a file** and returns a
one-paragraph summary plus the path. The fix agent is handed the **path**, not
a re-narration.

This kills the pattern of one verdict being retold in full three times per
round — dispatcher to reviewer to fixer to PR comment. It also survives an
agent that dies at its reporting step, because the verdict is already on disk;
that failure mode is a general property of report-shaped hand-offs and is not
an incident recorded in this repository.

**Where.** An absolute scratch path **outside the repository**, the same
constraint the reviewer already gives its lenses. Verdicts are not committed:
they are working artifacts about a commit, and a repository that accumulates
them starts inviting agents to read stale ones. The **record** is the branch,
the PR body and the issue thread.

### 1.1 Findings

Each finding carries four fields. `file:line` is **optional** — an
absence-finding has no line, and a schema that requires one quietly deletes the
most valuable finding class this repository produces.

| Field | |
|---|---|
| **claim** | what the artifact asserts, quoted |
| **required fix** | the smallest change that clears it, written as a **verbatim substitution** where possible |
| **verifying command** | the command that proves the finding, runnable as written |
| **rationale** | why the claim is wrong — distinguish *false* from *imprecise* from *unsupported* |
| *(optional)* **file:line** | pinned to the SHA reviewed |

A blocking finding without a verifying command is not blocking yet. Run it
first.

Substitutions are applied **verbatim from the verdict**; a fresh paraphrase is
how the same claim goes wrong a third way. But **any number in a substitution
is re-measured, never copied** — verdicts have carried wrong figures, and this
repository's whole `check_ceiling_notes.py` mechanism exists because two copies
of a correct number drew the wrong consequence from it.

### 1.2 Required top-level sections

A findings array alone silently deletes these. All three are mandatory, and the
first one is mandatory **in those words**:

1. **WHAT WAS NOT VERIFIED.** Literally that heading. "No simulator was run",
   "the Docker daemon was down so the container suite did not execute", "the
   `file:line` references were read from the diff and not from a checkout" —
   whichever applies. A reviewer that cannot distinguish *checked* from
   *assumed* is not reviewing.
2. **Items only field or manual testing can answer.** Everything needing a real
   pod, a real erg, on-water conditions, a human-driven simulator or a decoder.
   Each becomes a `[Local]` issue (`FACTS.md` §3.4) rather than a line in a
   verdict nobody can act on.
3. **What holds up.** Specific, with evidence. A review that only lists defects
   is not calibrated and reads as noise; the author then treats every finding
   as negotiable.

Then: the tally and the one overall verdict up front, the blocking findings,
the non-blocking items clearly marked, and the SHA reviewed — named, always.

---

## 2. The rounds ledger

One **append-only** file per PR or issue under gate. One row per round.

| Column | |
|---|---|
| **round** | 1, 2, 3 … |
| **commit** | the full SHA gated |
| **what that round believed** | the claim the round was built on, in one sentence |
| **what the gate found** | blocking count and the shape of it |
| **verdict path** | absolute path to §1's file |

Append only. A round is never edited after the fact; a correction is a new row
saying what the earlier row got wrong.

The ledger exists so any later agent — especially an expensive one brought in
to break a stall — reconstructs the history by **reading a file** instead of
doing archaeology across a comment thread. It is also the input that makes §3
possible.

**Rounds are the honest count.** A non-trivial fix takes three to seven rounds
here, and rounds 3+ are usually fixing the previous fix rather than the original
defect. Report the number; it is what the owner needs to decide whether to keep
going or ship.

---

## 3. Re-gates run on the delta

A fix-round closure lens gets exactly three inputs:

1. the **scoped diff** since the last gated commit,
2. the **prior verdict file**,
3. the **ledger**.

Not the whole branch.

**Never scope down two lenses**, because scoping them down removes the thing
they are for:

* the **near-neighbour lens** — its value comes from looking *outside* the
  diff. "Every round, the reported defect gets fixed and the thing beside it
  survives" is this repository's most-repeated finding;
* the **final pre-land consolidator** — it is the last reader of the whole
  change, and the landing checklist depends on it.

### 3.1 Reviewer continuation — direction matters

A **continued** reviewer (one carrying context from the previous round) is
permitted **only as the diff-holder**: round-over-round body comparisons
genuinely need the prior text.

**The verdict on any round that touched prose goes to a FRESH lens.** The
recurring defect class here is prose, and a continued reviewer re-gating
substitutions it authored is reviewing its own sentences.

**An author of a substitution never re-gates it.** Not the agent that wrote the
wording, not the lens that proposed it. This is the one rule in this file with
no exception, because the failure it prevents — a wrong claim confirmed by the
agent that wrote it — is silent by construction.

---

## 4. One shared suite measurement per gate

**One** designated agent runs the suite **once** per gate and publishes:

* the **commit** it was measured at, in full;
* the **exact command**, runnable as written;
* the result — the `PASSED (passed=N, failed=0, errors=0)` line plus
  `scripts/check_ciq_tests.py`'s verdict (`FACTS.md` §1.2, §2.2);
* **evidence the tests actually executed** — a count that *can fail*. Here that
  is `bash scripts/check_expected_tests.sh` against
  `scripts/expected_tests.txt`, which reds when the executed set and the pin
  disagree. Never a quiet mode that suppresses the evidence;
* the raw result files, at a path every lens can read.

**No lens accepts a relayed number.** If a lens needs the total, it reads the
published files.

**Exemption: mutation runs stay per-mutation.** They are the spine of the
evidence and cannot share a measurement — "reverting X reds exactly case Y,
N−1/N" is a claim about one specific run, and a shared total cannot make it.

### 4.1 Local greens are not the measurement

Two of the runner-free suites red on a Windows `core.autocrlf=true` checkout
for environmental reasons and are green in CI (`FACTS.md` §4.1). A local run is
necessary and never sufficient. The measurement of record is the container form
in `FACTS.md` §1.3, or the CI run object for the exact commit. **If the Docker
daemon is down, the run did not happen** — and mind the pipeline trap in
`FACTS.md` §2.6 that has already reported a run that never started.

---

## 5. Gate actions

**Merging a PR and closing an issue are gate actions.** They are taken only on
explicit direction, and only when *both* approval and CI hold. When directed to
"merge on accept and CI", say plainly which of the two failed if either does.

Filing issues, posting comments and editing issue text you authored are **not**
gate actions.

Landing itself has its own checklist: `docs/agents/rituals/LANDING.md`.

---

## 6. When rounds stop converging

* **Three rounds running finding a defect in the previous fix** → stop
  patching. The function has a structural problem, not a sequence of typos.
  Either **extract a pure seam and pin it** (a `static` taking plain values,
  with cases pinning each transition — but see the re-implementation trap in
  `FACTS.md` §6: the pin must **call** the shipping code), or **split the
  issue** so adjacent code does not hold a P0 hostage.
* **Body rewrites cap at three rounds.** At the cap, whatever is still
  contested is **deleted** and the remainder is filed as its own issue.
* **After the second wrong framing of a claim, the claim goes.** Delete, do not
  reword.
* **Remainders live in the tracker.** A leftover named only in a commit body or
  a report does not exist. Non-blocking findings accumulate into one periodic
  sweep issue rather than interrupting each round.

---

## 7. Reports are claims; the branch is the record

Gates verify at source — run objects, file contents, the actual commit message
— never the narration. A report that a commit says X is not evidence that it
does; read the commit. The verified local instance of this class is the
"observed failing" CI job that had in fact been cancelled mid-pull with the
step never executing: it was relayed on a report rather than a run object, and
the retraction is still in `.github/workflows/ci.yml` (`FACTS.md` §3.1).

Correct forward. Pushed-but-unlanded history may be amended, with the tree-hash
identity verified commit-for-commit when only messages move and the superseded
CI run ids cited so the red evidence survives. **Landed history is never
rewritten**; its errors are corrected in the next commit's body, naming the
error plainly.
