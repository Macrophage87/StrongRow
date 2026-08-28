# Ritual: cutting a release

Read this **when you are cutting a release**. Publishing a release asset is the
highest-reversibility-cost action in this repository (`DISPATCH.md`, R=3): a
downloaded `.iq` cannot be recalled, only superseded.

Facts and canonical command forms: `docs/agents/FACTS.md`.

---

## 1. What CI does NOT do

`release-build` compiles a release `.prg` for every manifest device and exports
`bin/StrongRow.iq`, and both are signed with a **throwaway per-job key**. The
workflow says so in its own comment: the artifact "is a structurally valid
package that proves the export path compiles — it is **NOT** store-submittable."

**A real release is signed with the account-bound developer key. That is a
manual step CI deliberately does not perform.** Every published release body
records it — v0.8: "Built from `211f106` with the account-bound developer key".

## 2. Build from a clean archive, never the working tree

```sh
git -c core.autocrlf=false archive --format=tar <tag-or-sha> | tar -x -C CLEANDIR
```

Three reasons, all of them things that have cost time here:

* **`core.autocrlf=false`.** This repository is configured `autocrlf=true` with
  no `.gitattributes`, so the maintainer's working tree holds CRLF while the
  index and CI hold LF (`FACTS.md` §4.1). `monkeyc` **accepts** a raw newline
  inside a string literal, so a stray CR lands inside a compiled string
  constant with no diagnostic.
* **The working tree is not the commit.** It carries build output, and
  `.claude/worktrees/` holds dozens of other checkouts of this same repository
  inside the repository root (`FACTS.md` §4.2).
* **Archive the tag, not `HEAD`.** The release body names a commit; that commit
  must be what was built.

## 3. Sign with the account-bound key, and never near the workspace

**Never run `openssl genrsa -out developer_key.pem` with a workspace-relative
path.** It would silently destroy a real account-bound key. `run_ciq_tests.sh`
puts its throwaway key in `mktemp -d` for exactly this reason, found in review.

## 4. Export and read the part count off the export

```sh
monkeyc -e -f monkey.jungle -o "bin/StrongRow-v<X.Y>.iq" -y <account-key>.der -w
```

**26 of 26 device parts across the 12 manifest products** at `211f106`
(`FACTS.md` §5.5). **Re-read that number from this export's own output; do not
copy it forward from the previous release body.** Nothing in this repository
derives it — the `.iq` is not a zip archive and cannot be enumerated with
ordinary tooling — so a copied figure is a figure nothing can regenerate, which
is the defect class that put two harnesses in `scripts/`.

`n of m` with `n < m` is a **failed** export, not a partial success. Stop.

## 5. Asset naming carries the version in the filename

```
StrongRow-v0.8.iq
StrongRow-v0.8-fr965.prg
```

Not `StrongRow.iq`. A downloaded asset must say what it is without its
surrounding page.

## 6. The suite total in the release body is a measurement, not a memory

v0.8: "`run-tests` green at **362/362** in the Connect IQ 9.2.0 simulator".
That figure is the shared gate measurement (`GATE_PROTOCOL.md` §4) — the
`PASSED (passed=N, failed=0, errors=0)` line plus `scripts/check_ciq_tests.py`'s
verdict, which is the part that reds if the simulator died before any test ran,
at the exact commit being tagged. It agrees with `FACTS.md` §5.2's pinned count
at `211f106`; if the two disagree, one of them is stale and the release stops
until you know which.

## 7. Tag, publish, and label honestly

* Tag the exact commit the body names.
* `v0.7`, `v0.7.1` and `v0.8` are flagged **prerelease**; `v0.4`, `v0.5` and
  `v0.6` are not — verified with
  `gh release list --json tagName,isPrerelease,isLatest` (re-run 2026-08-28:
  six releases returned against `--limit 30`, so not truncated). Flag a new
  private-distribution release **prerelease**, as every release from `v0.7`
  onward has been. Note the consequence: `v0.6` is the newest release *not*
  flagged prerelease, so GitHub's `latest` flag points at it while `v0.8`
  exists. That is correct behaviour, not a mistake to "fix" by un-flagging a
  prerelease — and not a mistake to "fix" by flagging `v0.5`/`v0.6`, which
  would move `latest` off `v0.6` onto nothing. The bodies of `v0.5` and `v0.6`
  both open "Beta release for private dashboard distribution", so purpose does
  not predict the flag; only the flag does.
* The body opens with the build provenance sentence — commit, key, device
  parts, product count, suite total — before any feature prose.

---

## Superseding a bad release

The established form, verified on `v0.7`:

1. **Do not delete the release and do not move the tag.** People have already
   downloaded it, and a moved tag makes their copy unidentifiable.
2. **Prepend a ⚠️ blockquote to the superseded release body**, linking the
   replacement, in the imperative. `v0.7`'s reads:

   > ## ⚠️ Superseded by [v0.7.1](…) — do not upload this build.
   >
   > This release contains an unbounded `openChannel`/`scheduleReopen`
   > recursion that can stack-overflow and kill the app mid-row, taking the
   > whole recording with it.

3. **Edit the release title** to carry it too, so a list view shows it:
   `v0.7 — SUPERSEDED by v0.7.1 (stack-overflow crash on the ANT retry path)`.
   A warning only in the body is invisible from `gh release list`.
4. **Say what would have to happen for it to fire, and what it costs when it
   does.** `v0.7`'s note names both conditions and states plainly that
   "neither of which has been observed in the field — but the cost when it
   fires is the entire row." A supersede notice that overstates the risk trains
   readers to ignore the next one; one that understates it is why they upload
   the bad build.
5. **Cut the replacement from a fresh archive.** Do not patch the tree that
   produced the bad build.

---

## Mid-work hazards that fire during a release

* **Never `git add .` / `-A` / `commit -a`** — nested worktrees inside the repo
  root (`FACTS.md` §4.2).
* **Never write a key into the workspace** (§3 above, `FACTS.md` §4.4).
* **`set -o pipefail`** for anything whose result you quote — a `monkeyc`
  failure piped through `grep` reports the grep's success (`FACTS.md` §2.6).
* **Never kill a shared simulator** (`FACTS.md` §4.5).
