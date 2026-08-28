# Ritual: landing a branch

Read this **when you are landing**, not when you think you might need it. The
rounds that most need a checklist are rounds already going wrong, so this
pointer binds to the verb, not to your assessment of whether it applies.

The orchestrator lands. Landing is a **gate action**: taken only on explicit
direction, never on your own initiative however green the PR.

Facts and canonical command forms: `docs/agents/FACTS.md`.

---

## The checklist

Run all seven. A landing that skips one is not a landing that went faster.

### 1. Fresh fetch

```sh
git fetch origin main
```

Not the local `main`. Measured 2026-08-28: the primary local checkout's `main`
was **78 commits behind** `origin/main` — `0d69b83` against `211f106`, a
fourteen-day gap (`FACTS.md` §4.3). Everything below is against
`origin/main`.

### 2. The base has not moved under you

```sh
git rev-parse origin/main
git merge-base --is-ancestor origin/main <head-sha> ; echo "ff=$?"
```

`ff=0` means `main` is an ancestor of your head — the merge is a
fast-forward and nothing landed under you since the gate. `ff=1` means
something did: **re-gate**, do not merge. A defect that exists only in the
combination of two independently-correct PRs is a real category here — one PR
clearing a handle before teardown silently dropped another PR's diagnostic
data, with a green build and every test passing.

If the base moved, check out and build the **merged result** and run the full
suite on it before merging.

### 3. CI verified from the run object, on the exact commit

Not from a report, not from a green checkmark you remember, not from a
different SHA.

```sh
gh api repos/Macrophage87/StrongRow/commits/<full-sha>/check-runs \
  --jq '.check_runs[] | "\(.name)\t\(.conclusion)"'
```

Seven checks must read `success`: `ci-required`, `manifest-lint`,
`test-tooling`, `compile-unit-test`, `run-tests`, `release-build`,
`agent-prompt-guard`. **Use the full SHA**, and use the one you are about to
push.

`ci-required` is the aggregate and the only name branch protection requires. It
runs `if: always()` and asserts every dependency succeeded, precisely because
branch protection treats a **skipped** required check as satisfied.

Two attempts of one run on the same runner pool is a **flake check, not
independent evidence** — phrase it that way in the PR body, because it is what
it is.

### 4. The scope diff is explicable file by file

```sh
git diff --stat origin/main...<head-sha>
```

Read every path. A file you cannot explain in one sentence is either scope
creep to be split out or a mistake to be reverted — decide which now, not after
it lands. Adjacent defects get **filed**, not folded in silently.

### 5. A delta read of all changed prose

Every changed comment, doc line, commit body and PR paragraph, read as prose,
against the code it describes.

```sh
# doc prose: read every changed line
git diff origin/main...<head-sha> -- '*.md'

# code comments: the comment lines only
git diff origin/main...<head-sha> -- 'source/*.mc' | grep -n '^[+-].*//'
```

The two commands are separate on purpose. A `//` filter over `'*.md'` discards
markdown, which contains no `//`: measured on this branch, `git diff
origin/main...af880ea -- '*.md' 'source/*.mc'` has **1685** changed lines and
the same pipeline filtered on `'^[+-].*//'` leaves **3**, all of them the
`npipe:////` string or the quoted command itself. Prose is read whole.

This is the step that catches this repository's dominant defect class. Ask of
each changed sentence:

* does the **cross-reference resolve**, and does the target say what the
  pointer claims? (`FACTS.md` §6 — a pointer contradicting its target is a
  named failure here.)
* is every **figure** reproducible from something committed? Two harnesses
  exist because published numbers were not.
* does it state what the code **calls**, or what a decoder **sees**? Only the
  first is allowed without a `[Local]` measurement.
* does it assert a **gap** where a record-scope field **latches**? Skipping a
  write re-emits; it never produces absence.
* does the change make a statement **elsewhere in the file** false?

### 6. Commit prose says why it is known to be correct

Not just what changed. Name the differentials, the review round, and the
retractions. A retraction names the wrong claim.

**No internal model or vendor identifiers** in anything pushed — commit
messages, PR bodies, code comments, docs. **No CI job scans for this** (#160,
open at `211f106`); the `agent-prompt-guard` job only checks *who* may edit two
named prompt files, not what any file contains. A rule stated in a document and
enforced by no job is violated silently for months, so check it yourself. The
pattern is deliberately not written out here — writing it would put the
identifiers in a versioned file, which is the thing the rule forbids. Build it
at the shell from the strings you were told not to publish:

```sh
git log origin/main..<head-sha> --format='%B' | grep -in -f /dev/stdin <<'EOF'
…one identifier per line, typed at the terminal, never committed…
EOF
git diff origin/main...<head-sha> | grep '^+' | grep -in -f <same list>
```

Until #160 lands a checker, this step is the only thing standing between the
rule and another silent violation.

### 7. Push the verified hash, not the branch name

```sh
git push origin <full-sha>:refs/heads/<branch>
```

The hash is what you verified. A branch name resolves at push time and can have
moved since step 3 — pushing it means pushing something you did not gate.

---

## Merge method

If the shared feature branch **continues into a follow-up PR**, use a **merge
commit**. A squash or rebase rewrites the commits, leaves the branch diverged
from `main`, and makes the next PR's diff re-present everything already merged.

Use a closing keyword (`Fixes #N`) in the PR body. Whole bundles of merged work
sit open for months when one PR omits it.

---

## After landing

* **Restart the branch from the new `main`.** A merged PR is finished history:
  `git fetch origin main && git checkout -B <branch> origin/main`. Never stack
  commits on merged history.
* **Landed history is never rewritten.** Its errors are corrected in the next
  commit's body, naming the error plainly.
* **Partial resolution**: close the parent as resolved, file a follow-up
  capturing the remainder, note the split on both, and triage the follow-up on
  its own merits. The close comment states plainly what was **not** done.
* Every comment you author ends with a `---` rule and the attribution line.

---

## Mid-work hazards that fire during a landing

* **Never `git add .`, `git add -A` or `git commit -a`.** `.claude/worktrees/`
  sits inside this repository's root and is not in `.gitignore`; it holds other
  agents' in-flight checkouts (`FACTS.md` §4.2). Stage named paths.
* **Never kill a shared simulator.** It may be serving another run
  (`FACTS.md` §4.5).
* **`set -o pipefail`** for anything whose result you quote. In a pipeline the
  exit status is the last command's (`FACTS.md` §2.6).
