# Agent loop documentation

The versioned half of the orchestration loop. The agent **role definitions**
live outside the repository (they are the maintainer's local configuration);
everything they would otherwise carry as duplicated prose lives here, so it is
reviewable in a pull request and checkable by CI.

| File | Read it when |
|---|---|
| [`FACTS.md`](FACTS.md) | **always the first stop.** One copy of every volatile shared fact: environment contract, canonical command forms, measurement rules, VCS hazards, recorded measurements, defect classes. Every measurement pinned to the commit it was taken at. |
| [`DISPATCH.md`](DISPATCH.md) | sizing a task, filing an issue, or triaging — the five-axis band metric with this repository's own anchors, and the `Dispatch:` header format |
| [`GATE_PROTOCOL.md`](GATE_PROTOCOL.md) | gating, re-gating, or writing a verdict |
| [`rituals/LANDING.md`](rituals/LANDING.md) | landing a branch |
| [`rituals/RELEASE.md`](rituals/RELEASE.md) | cutting a release |
| [`rituals/FIX_ROUND.md`](rituals/FIX_ROUND.md) | addressing a verdict |
| [`rituals/FIELD_DATA.md`](rituals/FIELD_DATA.md) | turning a recording into evidence |

Two rules govern how these files relate to the definitions that point at them.

**Cut and point, never summarize and keep.** A definition holds its identity,
its role-specific behaviour, and a one-line pointer per topic. A paraphrase
kept "for convenience" is a second copy that drifts independently — the exact
failure this split exists to prevent, and one this repository has already
shipped twice (#79, #160, both open).

**Pointers bind to the verb, not to self-assessment.** "When landing, read the
landing ritual" — not "read it if the landing looks tricky". The rounds that
most need a ritual's constraints are rounds already going wrong, so recognition
must not depend on the agent noticing it is in one.

**Mid-work hazards stay inline** in every definition — never `git add` a
directory, never kill a shared process, pin the device target,
`set -o pipefail`. They fire mid-task rather than at ritual time, so an
on-demand file cannot deliver them in time.

## What CI checks here

`scripts/check_agent_facts.py` re-derives five figures in `FACTS.md` from the
tree on every run of the required `test-tooling` job — the container digest,
the manifest device count, the pinned `(:test)` count, the quoted `globals`
ceiling note and the whole developer-field id→name map. Its self-test is
`scripts/test_check_agent_facts.py`. Everything else in these files is prose
with a commit pin and nothing more; `FACTS.md` §9 says so in its own words.
