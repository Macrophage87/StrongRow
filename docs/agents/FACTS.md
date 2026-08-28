# Canonical facts for the agent loop

One copy of every volatile fact the orchestration loop shares. Agent role
definitions hold their identity and their role-specific behaviour; anything
below is **pointed at, never restated**. A paraphrase kept "for convenience"
is a second copy that drifts independently, which is the defect this file
exists to stop — this repository has already shipped a documentation file
asserting an environment fact that was false (#79, open) and a rule enforced by
no job at all (#160, open).

**How to read a fact here.** Every measurement is pinned to the commit it was
taken at. A fact with no pin is not a fact. If a claim below disagrees with the
tree you are working in, the **tree wins** — say so in your report and fix this
file, do not work around it.

**If this file is absent from the checkout you are on**, say so explicitly in
your report rather than reconstructing a fact from memory. It is versioned with
the code precisely so that "which version of the rule applied" is answerable.

Measurements below were taken at **`211f106`** (`origin/main`, the merge of
PR #178) unless a line says otherwise.

Machine-checked by `scripts/check_agent_facts.py`, wired into the required
`test-tooling` job. Five of the figures here are re-derived from the tree on
every CI run; the rest are prose and carry only the pin. §9 says which is which.

---

## 1. Environment contract

### 1.1 The SDK is available locally. Verify, do not assume.

`docs/AGENT_PROMPT.md` still contains an "Environment constraints" section
claiming the execution environment cannot compile Monkey C or run the
simulator. **That claim is under an open issue as false as stated** (#79,
verified open at `211f106`). Do not propagate it, and do not conclude the SDK
is unavailable without looking:

```
ls ~/AppData/Roaming/Garmin/ConnectIQ/Sdks/       # Windows
ls ~/Library/Application\ Support/Garmin/ConnectIQ/Sdks/   # macOS
```

### 1.2 `monkeydo` exit codes are not verdicts

`monkeydo` returns non-zero **even when every test passes**. Read the
`PASSED (passed=N, failed=0, errors=0)` summary line, never the exit code.

Verified at source: `scripts/run_ciq_tests.sh:13-21` states the harness exit
contract ("the VERDICT IS NOT OURS"), and `scripts/run_ciq_tests.sh:219-220`
says it directly — "monkeydo's exit code is NEVER the verdict … upstream
documents it returns non-zero even when tests pass". The harness exits `0`
whenever it reached `monkeydo` at all and `2` only when it failed *before*
`monkeydo` could run.

The verdict belongs to `scripts/check_ciq_tests.py`, invoked with all four of
its inputs (`.github/workflows/ci.yml`, the "Check the test results
(fail-closed)" step).

### 1.3 The digest-pinned CI container

```
ghcr.io/matco/connectiq-tester@sha256:7a6f586cb0e0393ff288da09cf27b6dad40a0058a346c529b99fd0fc19858f0f
```

`# v2.8.0 = SDK 9.2.0`. Verified at source: the `&ciq_image` YAML anchor in
`.github/workflows/ci.yml` (the single in-workflow copy, aliased by
`run-tests` and `release-build`) and the quotation in `docs/CI.md` under
"The SDK container". **The digest is the pin; the tag is a comment.**

Running the authoritative suite locally has **three invocation requirements**,
and dropping any one of them produces a failure that looks like a code defect:

1. **`--entrypoint bash`.** The image ships an `ENTRYPOINT` of its own
   (upstream's `tester.sh`, named as such at `scripts/run_ciq_tests.sh:8-9`),
   which compiles with `-l 3` strict typechecking that this deliberately
   untyped codebase does not pass. `docs/CI.md` overrides it the same way for
   its binary probe (`docker run --rm --entrypoint sh <digest> …`).
2. **`core.autocrlf=false` on the archive.** See §4.1 — a CRLF checkout reds
   suites that are green in CI.
3. **A clean archive, not the working tree.** A worktree carries build output,
   nested checkouts and scratch files; the container must see what the commit
   contains.

```sh
git -c core.autocrlf=false archive --format=tar origin/main | tar -x -C CLEANDIR
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint bash -v "WINPATH:/work" -w /work \
  ghcr.io/matco/connectiq-tester@sha256:7a6f586cb0e0393ff288da09cf27b6dad40a0058a346c529b99fd0fc19858f0f \
  -c "bash scripts/run_ciq_tests.sh fr965"
```

**The daemon is not always up.** Measured 2026-08-28 in this branch:
`docker version` exits 1 with
`failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine`.
When it is down, **say the run did not happen** (§3.1) — and see **§2.6** for
the pipeline trap that has already turned this exact failure into a reported
success.

### 1.4 Devices

`manifest.xml` declares **12** `<iq:product>` entries (`fr970`, `fr965`,
`fenix847mm`, `fenix843mm`, `fenix8pro47mm`, `fenix7`, `fenix7pro`,
`epix2pro47mm`, `fenix6`, `fenix6pro`, `fenix6spro`, `fenix6xpro`).
`scripts/list_devices.sh` **is** the CI device matrix: the compile and release
jobs iterate exactly the manifest's products, and it exits non-zero on an empty
list so a build can never pass having compiled nothing.

`fr965` is the single test device (`run_ciq_tests.sh fr965` in the workflow).
`fenix6` is the family that binds the `globals` ceiling (§5.1).

---

## 2. The command block

Pinned forms. Sweep for bare forms; a bare form is a defect even when it
happens to return the right answer this time.

### 2.1 `gh` — field-selected, with a saturation check

Always `--json <exact fields>`; never a default dump (which carries whole
comment threads).

```sh
gh issue list --state open --limit 200 --json number,title,state,labels
gh issue view N   --json number,title,state,body
gh pr view N      --json number,state,headRefOid,statusCheckRollup
gh api repos/OWNER/REPO/commits/<full-sha>/check-runs \
  --jq '.check_runs[] | "\(.name)\t\(.conclusion)"'
```

**Saturation check: a returned count equal to the limit means TRUNCATED, not
"that is all of them."** Re-query with a higher limit before believing it.

Measured 2026-08-28 in this branch: `gh issue list --state open` with **no
`--limit`** returns **30**; with `--limit 200` it returns **93**. A bare list
silently hides two thirds of this backlog and gives no indication that it did.

### 2.2 Test results — read the verdict, not the log

* The suite verdict is the `PASSED (passed=N, failed=0, errors=0)` line
  (§1.2) plus `scripts/check_ciq_tests.py`'s own fail-closed output.
* The pin check is `bash scripts/check_expected_tests.sh`, which prints one
  line on success.
* **Tail the raw log only on failure**, and only the failing region. A green
  run's log carries zero findings.

### 2.3 Search — exclusions pinned, count before read

Exclude build output and nested checkouts. `.claude/worktrees/` sits **inside**
this repository's root and holds dozens of additional working copies of this
same repository (§4.2), so an unexcluded search reports every hit N times over
against several different commits.

```sh
grep -rn --exclude-dir=bin --exclude-dir=gen --exclude-dir=.git \
         --exclude-dir=.claude --exclude-dir=__pycache__ -c PATTERN .
```

Count first; open only files with hits. `scripts/check_ceiling_notes.py:81-87`
takes the same precaution structurally — it skips **every** dot-directory, and
says why: "a checkout can carry additional working copies of this same
repository underneath a dot-directory, and scanning those would find a second,
older copy of every note and report drift that does not exist."

### 2.4 Logs bounded at the source

Line-cap and filter at the command (`| head -n`, `sed -n 'A,Bp'`, `--jq`), not
after the output has landed. **Never re-paste a region already quoted in this
session — cite it.**

### 2.5 Waiting is not model work

One bounded poll that blocks and returns a single line. Not a sequence of turns
each learning one enum value.

```sh
gh run watch <run-id> --exit-status > /dev/null 2>&1; echo "conclusion=$?"
```

### 2.6 `set -o pipefail` for anything whose result gets quoted

**In a pipeline the exit status is the LAST command's.** A command piped
through `grep` or `head` reports the filter's success, not the command's.

This is not hypothetical. Measured 2026-08-28 in this branch, with the Docker
daemon down:

```
$ docker version --format '{{.Server.Version}}' 2>&1 | head -5 ; echo $?
failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine…
0                      <-- head succeeded; the daemon failure is invisible

$ docker version --format '{{.Server.Version}}' >/dev/null 2>&1 ; echo $?
1

$ set -o pipefail; docker version … 2>&1 | head -1 >/dev/null ; echo $?
1
```

A verification that never ran was reported as in flight on exactly this
mechanism. Use `set -o pipefail`, or check `${PIPESTATUS[0]}`, for any command
whose result you intend to quote. `scripts/run_ciq_tests.sh:28` sets
`-euo pipefail` for this reason, and `:221-222` explains the one place it
deliberately avoids a pipe (`tee` would abort every green run under pipefail,
because `monkeydo` exits non-zero on success).

---

## 3. Measurement and verification rules

### 3.1 Never claim a verification you did not run

If the tool was unavailable, the daemon was down, or the run was cancelled,
**say that**. Retract a wrong claim by name, at the place the claim lives, not
by silently editing it away.

`docs/CODE_REVIEW_AGENT.md` and the reviewer definition both carry the same
incident: a reviewer asserted a CI job had been "observed failing" in a named
run; it was relayed and written into the workflow file; it was false — the job
had been **cancelled mid-pull and the step never executed**. The retraction is
still in the tree at `.github/workflows/ci.yml`, in the `release-build` upload
step's comment ("an earlier claim here citing run 30129516247 attempt 2 was
wrong").

### 3.2 What no `(:test)` in this repository can reach

These bound what a green suite means. All verified at source at `211f106`:

* **No `(:test)` can obtain a `Session`**, so `createField` is unreachable from
  the suite — `scripts/check_step_fields.py:5-6` and `:200-201`,
  `source/StrongRowView.mc:1088`, `:5066`, `:5126`, `:5228`,
  `source/StepMarkTest.mc:363`, `source/ErgUnitsTest.mc:807`. Consequence
  recorded in the workflow: "Gating creation on `mWorkoutEnabled` leaves all
  the `(:test)`s green; it fails here" — which is why
  `scripts/check_step_fields.py` is a **static** check.
* **No `(:test)` can obtain a graphics `Dc`.** What the layout suites run is
  "font-free and needs no `Dc`: the arc's own geometry"
  (`source/HrLayoutTest.mc:33`), and the reachable seams are documented as
  "reachable from a `(:test)` with no `Dc`, no `Session` and no ANT channel"
  (`source/StrongRowView.mc:2621`). Anything that needs real font metrics,
  clipping or a real render is **not** test-visible.
* **A comment cannot be red by any test.** Comments are stripped from the
  build, so the compiler never objects; `scripts/check_source_refs.py` exists
  because `source/CoreTempSensor.mc` named a guard that **was never written**
  and "three reviewers found it by hand across two rounds"
  (`.github/workflows/ci.yml`, the cross-reference step's comment).
* **Nothing here decodes a file this app actually wrote.**
  `scripts/fit_step_marks.py` "proves the QUERY side only"
  (`.github/workflows/ci.yml`, the acceptance-criterion step).
* **A real pod, a real erg or on-water conditions are field-only.** They get a
  `[Local]` issue; see §3.4.

### 3.3 Record-scope FitContributor fields LATCH

Skipping a `setData` **re-emits the previous value** on every subsequent
record. It never produces a gap or an absence. Withholding a write from a live
session therefore *fabricates* data rather than omitting it, so any gate on a
FIT write must fail **open**.

Do not reintroduce a "gap" claim. Open issue #46 is written against exactly
this shape ("`rr_interval` re-emits the previous batch's beats during a
dropout — write an `RR_INVALID` array instead of skipping `setData`", verified
open at `211f106`).

### 3.4 A comment may state what the code CALLS, never what a decoder SEES

Until a `[Local]` simulator or decoder session has measured it. `[Local]`
issues carry: the `[Local]` title prefix, an opening ⚠️ blockquote, the
`local-test` label, and byte-exact pass criteria. Open examples at `211f106`:
#172 (decode `step_type` / `interval_num` from a real file), #173 (measure RR
and GPS label widths on all twelve devices), #81, #82.

### 3.5 `System.getTimer()` counts from device start

A test that synthesises a timestamp from it passes on a simulator that has been
open for hours and reds on CI's, which is seconds old. **Inject clocks through
an overridable method.** A green local run is necessary and never sufficient:
confirm the CI conclusion for the pushed SHA from the run object (§2.1) before
claiming a commit passes.

Open issue #70 records the related unbounded case (rollover behaviour of the
freshness helpers is unspecified).

---

## 4. Version-control hazards

### 4.1 CRLF: this checkout is `core.autocrlf=true` with no `.gitattributes`

Verified at `211f106`: the repository root contains **no** `.gitattributes`,
and `git config core.autocrlf` returns `true` on the maintainer's machine. CI
checks out LF and never sees the difference.

Measured consequence, 2026-08-28 in this branch — `git ls-files --eol
scripts/fixtures/monkeydo-green-run.log` reports `i/lf w/crlf attr/`, i.e. LF
in the index and CRLF on disk, and the on-disk file holds 75 CRLF and 0 bare
LF. Two runner-free suites therefore red **locally on Windows while being green
in CI**:

| Suite | Case that reds locally | Cause |
|---|---|---|
| `scripts/test_check_ciq_tests.py` | `real log with CRLF line endings passes` (51/52) | the fixture is already CRLF on disk, so the case's LF→CRLF conversion produces CR CR LF |
| `scripts/test_list_tests.py` | `symlinked files, symlink cycles and FIFOs are skipped, not followed` (34/35) | `OSError(22, 'A required privilege is not held by the client')` — Windows withholds the symlink-creation privilege |

Both are environmental, not defects: CI on `211f106` reports **`test-tooling
success`** (and `ci-required`, `run-tests`, `compile-unit-test`,
`release-build`, `manifest-lint`, `agent-prompt-guard` all `success`), read
from the check-runs object with the form in §2.1.

**Do not "fix" either locally, and do not report the local red as a
regression.** Use the container form in §1.3, which archives with
`core.autocrlf=false`.

Related and separate: `scripts/check_mc_literals.py` exists because `monkeyc`
**accepts** a raw newline inside a string literal (measured, SDK 9.2.0, fr965
and fenix6, BUILD SUCCESSFUL with no diagnostic), and on a CRLF checkout that
puts a stray CR inside the compiled string constant.

### 4.2 Nested worktrees live inside the repository root, and are not ignored

Verified at `211f106`: `.gitignore` has **no** `.claude/` entry, and
`git worktree list` shows dozens of additional working copies rooted at
`<repo>/.claude/worktrees/`.

**Never `git add .`, `git add -A` or `git commit -a`.** Stage named paths only.
Adding a directory here would commit other agents' in-flight checkouts.

### 4.3 Read `origin/main`, not the working tree

A long-lived local clone's `main` can be far behind. Measured 2026-08-28: the
primary local checkout had `main` at `0d69b83` — an ancestor of `origin/main`
at `211f106`, and **78 commits behind it** (a fourteen-day gap). Reviewing or
citing from it produces findings against code that was replaced two weeks ago.

```sh
git fetch origin main
git show origin/main:path/to/file        # or a fresh worktree
```

### 4.4 Never write a developer key into the workspace

A workspace-relative `openssl genrsa -out developer_key.pem` would silently
destroy a real account-bound key file. `scripts/run_ciq_tests.sh:63-68` puts
the throwaway key in `mktemp -d` for exactly this reason ("found in review").
`.gitignore` covers `developer_key*`, `*.der` and `*.pem`, but a destroyed key
is not recoverable from `.gitignore`.

### 4.5 Never kill shared processes

A simulator on this machine may be serving another agent's run. `monkeydo`
against an **already-running** simulator is the local form; killing one is not
yours to do. `scripts/run_ciq_tests.sh:74-81` kills only the two PIDs it
started itself.

---

## 5. Recorded measurements

### 5.1 The `fenix6` `globals` ceiling, and current headroom

The fenix6 family caps module `globals` at **253** members; a file-scope
`(:test)` costs one member. The limit is **inclusive**: at *F* free, the *F*-th
added still builds and the *(F+1)*-th is the first that reds. Both earlier
copies of this note carried the right count and the wrong consequence, which
is why `scripts/check_ceiling_notes.py` now derives the consequence
arithmetically.

Current headroom, verbatim from the newest anchor in the tree (the
`v08-display-fixes` branch merged at `211f106`; the identical note lives at
`source/GridGateTest.mc:34` and `source/SetGridLayoutTest.mc:79`):

    CEILING v08-display-fixes fenix6: 246 used of 253, 7 free -- the 8th file-scope (:test) added reds

Older anchors are also in the tree. Do not carry a count of them in prose:
`python3 scripts/check_ceiling_notes.py` prints every note line with its
`file:line`, and that enumeration is the only one that cannot go stale.
`check_ceiling_notes.py` enforces that copies sharing an anchor are identical
and that each one's arithmetic closes; **it cannot tell you which anchor is newest**, and a stale-but-coherent
note passes. Re-measure by bisection when the tree changes.

### 5.2 Pinned test count

**374** `(:test)` functions under `source/`, matching
`scripts/expected_tests.txt` exactly (`bash scripts/check_expected_tests.sh`,
run on the `claude/hrv-correctness` branch: "OK: 374 (:test) function(s) under
source/ match scripts/expected_tests.txt exactly."). It was **362** at
`211f106`; epic #59 adds cases in `source/RrHrvTest.mc`.

Any `(:test)` addition, removal or rename edits `scripts/expected_tests.txt`
**in the same commit**. The check closes drift, not coordinated shrink:
deleting a function *and* its pin line together still passes (#52).

### 5.3 The developer-field id map

27 developer fields, ids unique, **none unused**. Parsed from the `createField`
calls in `source/StrongRowView.mc`. The table below was taken at `211f106`,
when there were 26 fields and **id 19 was the one free id**; epic #59 took 19
for `rr_diag`, so the id set is now CONTIGUOUS — 0 to 26 inclusive, no holes —
and the next field added takes 27.

| id | name | type | id | name | type |
|---:|---|---|---:|---|---|
| 0 | `row_stroke_rate` | FLOAT | 14 | `erg_diag` | UINT16 |
| 1 | `dist_per_stroke` | FLOAT | 15 | `erg_work_total` | FLOAT |
| 2 | `rr_interval` | UINT16 | 16 | `erg_cadence` | FLOAT |
| 3 | `rmssd` | FLOAT | 17 | `step_type` | UINT8 |
| 4 | `avg_rmssd` | FLOAT | 18 | `interval_num` | UINT16 |
| 19 | `rr_diag` | UINT16 |
| 5 | `corrective_rate` | FLOAT | 20 | `lock_rate` | FLOAT |
| 6 | `total_corrective_strokes` | UINT16 | 21 | `lock_confidence` | FLOAT |
| 7 | `core_temperature` | FLOAT | 22 | `lock_lowconf_run` | UINT16 |
| 8 | `skin_temperature` | FLOAT | 23 | `rate_raw` | FLOAT |
| 9 | `max_core_temperature` | FLOAT | 24 | `rate_base` | FLOAT |
| 10 | `ct_diag` | UINT16 | 25 | `lap_step_type` | UINT8 |
| 11 | `heat_strain_index` | FLOAT | 26 | `lap_interval_num` | UINT16 |
| 12 | `erg_power` | FLOAT | | | |
| 13 | `erg_joules_per_stroke` | FLOAT | | | |

**A developer field id is unique per `field_description`**, which is why the
lap copies (25, 26) could not reuse 17 and 18 — a collision silently re-labels
a field. `scripts/check_step_fields.py` already pins the count and the
uniqueness (`STEPFIELDS … total_fields=26`); the **id→name** binding above is
pinned by `scripts/check_agent_facts.py` and was not pinned by anything before
this file existed.

**Twenty-six is two different counts, and they are unrelated.** There are 26
developer fields (this table, machine-checked) **and** 26 device parts in the
exported `.iq` (§5.5, prose only) — across **12** manifest products (§1.4).
Three numbers, one coincidence. Say which one you mean; open issue #172's title
uses the field figure. Checking *what a figure is measured against* rather than
just that it is right is this repository's "wrong pair" defect class (§6).

### 5.4 Backlog size

**93** open issues at 2026-08-28 (§2.1). Cited only to make the saturation rule
concrete; it is not otherwise load-bearing and will drift.

### 5.5 Releases

Six published: `v0.8`, `v0.7.1`, `v0.7`, `v0.6`, `v0.5`, `v0.4`.
`v0.7`, `v0.7.1` and `v0.8` are flagged **prerelease**; `v0.6` carries GitHub's
`latest` flag as a consequence. Asset naming carries the version in the
filename — `StrongRow-v0.8.iq`, `StrongRow-v0.8-fr965.prg`.
`v0.7` is titled "SUPERSEDED by v0.7.1"; see the release ritual.

**26 device parts across the 12 manifest products.** Verified from the release
bodies, which are the only place this figure is recorded: v0.8 reads "Built
from `211f106` with the account-bound developer key, **26 of 26 device parts**
across the 12 manifest products, `run-tests` green at **362/362**"; v0.7 and
v0.6 say the same with their own commits and totals. The 362 there is the same
figure as §5.2 — the two agree at `211f106`.

**Nothing in this repository derives the part count.** It comes out of
`monkeyc -e`'s export, and the `.iq` is not a zip archive, so it cannot be
enumerated with ordinary tooling. It is prose with a pin, and it must be
re-read from the export log at each release rather than copied forward.

---

## 6. Defect classes this repository keeps re-learning

Named here once so no definition needs its own copy of the narrative.

* **A claim stronger than its evidence.** The dominant class. An absolute where
  the source had a qualifier; a universal from one observation; a decoder-level
  claim from a byte-level measurement.
* **A number nothing committed can regenerate.** Two harnesses exist because
  this shipped. `scripts/cue_replay.py`: the analysis behind the display-cue
  table "was a scratch script that was never committed, and it replayed a
  DIFFERENT machine from the one that shipped". `scripts/speed_witness.py`:
  the published pair 0.851 / 0.916 "are NOT reproducible from the recordings",
  retracted in the script and at the quotation site, and replaced with figures
  the script prints.
* **A test that re-implements logic instead of calling it pins nothing.**
  `source/StrongRowView.mc:3336-3344` — a case "was in fact exercising a
  private COPY of the comparison inside the test probe, and deleting both real
  clamp lines left all 308 cases green (measured, in the CI container, on
  fr965)". `source/DpsArcTest.mc:266-274` records the same hole being read one
  file over "and repeated anyway".
* **The near neighbour.** The reported defect is fixed and the thing beside it
  survives. When you confirm a fix, look one level out immediately.
* **A pointer that contradicts the file it points at.** Check that the target
  says what the pointer claims, every time you write one.
* **The wrong pair.** A ratio, clearance or contrast computed against the wrong
  reference. Check what a figure is measured *against*.
* **Absence rendered as a value.** A missing reading shown as "below target"
  makes the athlete correct toward a number that was never measured.
* **Fixes that create defects.** A fix round introducing a new defect is the
  norm here, not the exception. Re-gate every fix commit.

---

## 7. Recommended permission allowlist — a PROPOSAL for the maintainer

**Not applied by this branch, and it must not be.** The loop does not widen its
own permissions; that edit belongs to a human. No settings file is touched
here. These are read-only patterns the loop runs constantly, where a missing
permission costs a refused call plus retry variants rather than a prompt.

```
Bash(git status:*)      Bash(git log:*)        Bash(git show:*)
Bash(git diff:*)        Bash(git fetch:*)      Bash(git rev-parse:*)
Bash(git ls-files:*)    Bash(git worktree list) Bash(git merge-base:*)
Bash(gh issue view:*)   Bash(gh issue list:*)  Bash(gh pr view:*)
Bash(gh run view:*)     Bash(gh release view:*) Bash(gh api repos/*/check-runs*)
Bash(python3 scripts/*) Bash(bash scripts/check_expected_tests.sh)
```

Everything state-changing — `git push`, `git commit`, `gh pr merge`,
`gh issue close`, `gh release create`, `docker run`, any write to `.github/` —
stays behind the prompt. `gh api` is allowlisted for the check-runs read path
only, because `gh api` in general can POST.

---

## 8. Rituals and the dispatch metric

Loaded on demand, by verb:

| When you are… | Read |
|---|---|
| landing a branch | `docs/agents/rituals/LANDING.md` |
| cutting a release | `docs/agents/rituals/RELEASE.md` |
| running a fix round | `docs/agents/rituals/FIX_ROUND.md` |
| ingesting field data from a FIT | `docs/agents/rituals/FIELD_DATA.md` |
| sizing a task or filing an issue | `docs/agents/DISPATCH.md` |
| gating, re-gating or writing a verdict | `docs/agents/GATE_PROTOCOL.md` |

---

## 9. Machine-checked lines

`scripts/check_agent_facts.py` re-derives the following from the tree on every
CI run and fails if this file disagrees. The marker lines are the contract; the
prose above is the explanation.

    AGENTFACT ci-container sha256:7a6f586cb0e0393ff288da09cf27b6dad40a0058a346c529b99fd0fc19858f0f
    AGENTFACT manifest-devices 12
    AGENTFACT pinned-tests 374
    AGENTFACT ceiling v08-display-fixes 246 253 7
    AGENTFACT devfield 0 row_stroke_rate
    AGENTFACT devfield 1 dist_per_stroke
    AGENTFACT devfield 2 rr_interval
    AGENTFACT devfield 3 rmssd
    AGENTFACT devfield 4 avg_rmssd
    AGENTFACT devfield 5 corrective_rate
    AGENTFACT devfield 6 total_corrective_strokes
    AGENTFACT devfield 7 core_temperature
    AGENTFACT devfield 8 skin_temperature
    AGENTFACT devfield 9 max_core_temperature
    AGENTFACT devfield 10 ct_diag
    AGENTFACT devfield 11 heat_strain_index
    AGENTFACT devfield 12 erg_power
    AGENTFACT devfield 13 erg_joules_per_stroke
    AGENTFACT devfield 14 erg_diag
    AGENTFACT devfield 15 erg_work_total
    AGENTFACT devfield 16 erg_cadence
    AGENTFACT devfield 17 step_type
    AGENTFACT devfield 18 interval_num
    AGENTFACT devfield 19 rr_diag
    AGENTFACT devfield 20 lock_rate
    AGENTFACT devfield 21 lock_confidence
    AGENTFACT devfield 22 lock_lowconf_run
    AGENTFACT devfield 23 rate_raw
    AGENTFACT devfield 24 rate_base
    AGENTFACT devfield 25 lap_step_type
    AGENTFACT devfield 26 lap_interval_num

The `CEILING` line in §5.1 is additionally checked by
`scripts/check_ceiling_notes.py`, which requires it to be byte-identical to its
two copies in `source/`.

**What is NOT machine-checked**, so nobody reads more into a green run: every
prose claim in §1-§4, §6 and §7, the `[Local]` issue numbers, the backlog and
release figures in §5.4-§5.5, and the `file:line` citations throughout. Those
carry a commit pin and nothing more. Line numbers shift — re-verify before
quoting one.
