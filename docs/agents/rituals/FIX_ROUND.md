# Ritual: a fix round

Read this **when you are addressing a verdict**. Not "if it seems like a big
one" — the rounds that most need these constraints are the ones already going
wrong.

Verdict format, ledger and re-gate rules: `docs/agents/GATE_PROTOCOL.md`.
Facts and commands: `docs/agents/FACTS.md`.

**A fix round introducing a new defect is the norm here, not the exception.**
A non-trivial fix takes three to seven rounds, and rounds 3+ are usually fixing
your own fixes rather than the original defect. Budget for it; report the count
honestly.

---

## 1. Before you change anything

1. **Read the verdict file at its path.** Do not work from a summary of it.
2. **Re-run every blocking finding's verifying command** and record the output.
   A finding is a hypothesis until you have reproduced it — including the ones
   that would make the reviewer right. A reviewer once argued a comment
   over-generalised; a two-minute check showed the comment was correct as
   scoped, and the claim was dropped rather than relayed.
3. **Re-verify every `file:line`.** Line numbers shift; re-check them every
   round, against `origin/main` or the head SHA, never a stale working tree
   (`FACTS.md` §4.3).
4. **Append the ledger row** before you start: commit, what this round
   believes, verdict path.

## 2. While you fix

* **Address findings point by point, in the reviewer's numbering.** Where a
  finding is wrong, push back with evidence. Where your earlier claim was
  wrong, say so plainly and correct it **at its source** — the issue body, the
  PR body, the comment — not only in new text.
* **Apply substitutions verbatim from the verdict.** A fresh paraphrase is how
  the same claim goes wrong a third way.
* **Re-measure every number in a substitution.** Never copy one. Verdicts have
  carried wrong figures, and a suggested mutation has turned out not to
  compile.
* **Scope discipline.** Fix the findings. Name adjacent defects and **file**
  them; do not fold them in silently. A behaviour change beyond the verdict is
  a listed decision, never a smuggled one.
* **Auto-apply review-requested *minor* changes** without waiting. Genuine
  scope changes, or reversals of a review directive, go back for review rather
  than being landed quietly.

## 3. Red before green

Every new test guarding a behaviour change must be **shown failing before the
fix**. The commit partition:

| | |
|---|---|
| **c0** | characterization pins on existing symbols (green) |
| **c1** | behaviour-preserving refactor + new symbols + green pins on them |
| **c2** | **red differentials ONLY** — every added test named in the red run's failure list |
| **c3** | the fix. Touches **no** test file, **no** pin, **no** `scripts/`, **no** `.github/` |

**Open the PR at c1 and let each run complete before the next push, or the red
evidence never exists.** CI fires on `pull_request` for feature branches and
`cancel-in-progress: true` kills in-flight runs, so a fast second push deletes
the red run you were relying on.

## 4. The pin must call the thing it pins

A test that re-implements logic instead of calling it **pins nothing**. This
repository has the receipt twice:

* a case "was in fact exercising a private COPY of the comparison inside the
  test probe, and deleting both real clamp lines left all 308 cases green
  (measured, in the CI container, on fr965)" —
  `source/StrongRowView.mc:3336-3344`;
* the same hole, read one file over while writing the mirror, **and repeated
  anyway** — `source/DpsArcTest.mc:266-274`.

So: **mutation-test every pin you add.** Break the thing it guards, run the
suite, report the numbers — *"reverting X reds exactly case Y, N−1/N."* If it
does not red, the test is decoration, and decoration is worse than nothing
because it reads as coverage. Mutation runs are **exempt** from the shared
suite measurement (`GATE_PROTOCOL.md` §4) — they are per-mutation by nature.

## 5. Pins and the ceiling

* Any `(:test)` **addition, removal or rename** edits
  `scripts/expected_tests.txt` **in the same commit**. New names must not
  collide with the parser suite's synthetic literals.
* A **file-scope** `(:test)` costs one `globals` member on the fenix6 family.
  Check the current headroom in `FACTS.md` §5.1 before you add several — the
  figure is deliberately not repeated here, because a second copy of it is
  invisible to `check_ceiling_notes.py` and would drift silently.
* Two runner-free suites red locally on a Windows CRLF checkout and are green
  in CI (`FACTS.md` §4.1). **Do not "fix" them and do not report them as
  regressions.**

## 6. When to stop patching

* **Three rounds running finding a defect in the previous fix** → the function
  has a structural problem, not a sequence of typos. Extract a pure seam and
  pin it (calling the shipping code, per §4), or split the issue so adjacent
  code does not hold a P0 hostage.
* **After the second wrong framing of a claim, delete the claim.** Do not
  reword it a third time.
* **Body rewrites cap at three rounds.** At the cap, what is still contested is
  deleted and filed as its own issue.
* **Five rounds on one function**: ask whether you are converging or circling.
  Do not run a sixth of the same shape.

## 7. Closing the round

* **Post one reply comment per round addressed**, in the reviewer's numbering.
* **Update the PR body in place.** It is the record: counts, evidence, and any
  claim a review falsified, corrected where it lives.
* **Append the ledger row**: what the gate found, verdict path.
* **Do not start the next round until a new verdict exists.**
* **You do not gate your own fix.** The verdict on any round that touched prose
  goes to a fresh lens, and an author of a substitution never re-gates it
  (`GATE_PROTOCOL.md` §3.1).
* Every comment ends with a `---` rule and the attribution line.

---

## Mid-work hazards

* **Never `git add .` / `-A` / `commit -a`** (`FACTS.md` §4.2).
* **Never kill a shared simulator** (`FACTS.md` §4.5).
* **Never write a developer key into the workspace** (`FACTS.md` §4.4).
* **`set -o pipefail`** for anything whose result you quote (`FACTS.md` §2.6).
* **Device target**: `fr965` for the suite; the release build compiles all 19.
