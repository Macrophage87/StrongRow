# Continuous Integration

StrongRow's CI is **runner-free**: every job runs on stock GitHub-hosted
`ubuntu-latest`. There is **no self-hosted runner** and **no Garmin SDK
download**. The Connect IQ SDK comes from running a pre-built Docker image as the
job `container`, so the only thing GitHub pulls is that image.

Workflow: [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

## The SDK container

SDK-dependent jobs run inside:

```
ghcr.io/matco/connectiq-tester@sha256:64958e8fd2925d0c4986d72a9aa9d8e2101297a881354aab0118be2f1dc22105   # v2.10.0 = SDK 9.2.0, device files 2026-08-31
```

The image is **pinned by digest** — the digest is the real pin; the `v2.10.0`
tag lives in a trailing comment for humans. In the workflow the digest appears
**once**, as the `&ciq_image` YAML anchor, aliased by every container job. The
only other copy is the one quoted above in this file, and **nothing
cross-checks it** — to move SDKs, change the anchor, update its tag comment,
and update this document, all together.

**When to bump:** if a device in `manifest.xml` is not defined in the current
SDK, the compile job fails with an unknown-device error. Bump to a newer
`connectiq-tester` tag that ships that device and repin the digest.

That is exactly why the pin moved from `v2.8.0` (`sha256:7a6f586c…`) to
`v2.10.0` (`sha256:64958e8f…`). Garmin published the fenix 9 family on
2026-08-25; the v2.8.0 image was built **2026-06-10**, so its device files
predate those devices and `compile-unit-test` could not have found them.
v2.10.0 was built **2026-09-01** from upstream revision `5508cf7`, whose
`Dockerfile` sets `RESOURCES_VERSION=2026-08-31` and `CONNECT_IQ_VERSION=9.2.0`
— **same SDK version, newer device files**. Both digests were read from the
ghcr manifests endpoint's `docker-content-digest` header, not from a client's
tag lookup; the build dates come from each image's own config blob
(`created`, `org.opencontainers.image.version`).

**When you bump, re-verify the three undeclared binaries.** The upstream
Dockerfile's `apt-get install` list is exactly `openjdk-17-jre-headless`,
`libwebkit2gtk-4.0-37`, `libusb-1.0-0`, `libsm6`, `xvfb`. CI additionally relies
on **`openssl`** (throwaway key; it appears only in a Dockerfile *comment*),
**`python3`** (the fail-closed verdict step, which runs `if: ${{ !cancelled() }}`
on a required check), and — advisory only — **`procps`** for `ps`/`pgrep`. All three
are present today as *transitive* packages, frozen by the digest pin, so this is
not a live risk. But nothing declares them, so after changing the digest confirm
in the new image that all three still resolve:

```sh
docker run --rm --entrypoint sh <new-digest> -c 'command -v openssl python3 ps pgrep'
```

`openssl` and `python3` are load-bearing: without them the job cannot produce a
verdict at all. `run_ciq_tests.sh` now aborts with `exit 2` and a named
`harness_error` breadcrumb if the key/compile block fails for any reason
(including a missing `openssl`). Its `pgrep` call carries a `command -v` guard
for the message's honesty, not for behaviour: a `command not found` exit 127
already reads exactly as "pgrep found nothing", so a dropped `procps` degrades
to `kill -0` either way — the guard just stops the log claiming pgrep concurred
when it was never consulted.

**The v2.10.0 bump did NOT run that probe**: the Docker daemon was down on the
machine the bump was authored on, so no `command -v` line exists for this
digest. What stands in for it is the CI run of the bump commit by itself, with
no other change: a green `run-tests` on the new image cannot happen without
`openssl` (the key block aborts `exit 2` without it) or without `python3` (the
verdict step). `procps` is advisory and remains unconfirmed for this digest.

## Signing key

`monkeyc` needs a developer key even for a test build, so each SDK job generates
a **throwaway 4096-bit key in the workspace**:

```sh
openssl genrsa -out developer_key.pem 4096
openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out developer_key.der -nocrypt
```

It is never committed and is **not** a repo secret. A store-submittable `.iq`
must be signed with the account-bound key — that is a manual release step CI
deliberately does not perform.

## Jobs

| Job | Container? | Required? | What it does |
|---|---|---|---|
| `manifest-lint` | no | yes | Fail-closed check that the manifest app id is a real 32-hex id (not a placeholder/template), the app has an entry/name/known type, and at least one device is listed. Also cross-checks `list_devices.sh` against the XML parse (see below). A bad id still compiles and still passes tests but the store rejects it — the SDK jobs can't catch this class. |
| `test-tooling` | no | yes | Runner-free proof of the three things that decide whether `run-tests` can catch anything. (1) `scripts/test_list_tests.py` proves the declaration extractor RED/GREEN. (2) `scripts/check_expected_tests.sh` cross-checks the pin file against the `(:test)` functions actually declared under `source/` (extraction is the comment- and form-aware `scripts/list_tests.py`). (3) `scripts/test_check_ciq_tests.py` runs the parser's RED/GREEN suite and ends with the pin-perturbation meta-check. Its own job rather than a step in `manifest-lint`: a parser-fixture regression reporting under a check named "manifest-lint" misnames its own cause. The job also carries the repository's other runner-free guards, which are about the SOURCE rather than about `run-tests`: `scripts/check_ceiling_notes.py` (the `globals` ceiling arithmetic), `scripts/check_source_refs.py` (every `test_*` named in a `source/` comment resolves to a declared `(:test)`), `scripts/check_agent_facts.py` (the five figures in `docs/agents/FACTS.md` the tree can regenerate), `scripts/dispatch_rescore.py` (the band histogram and median-agents figures published in `docs/agents/DISPATCH.md` §6, re-derived from a committed worksheet of real issues), and the `cue_replay` / `speed_witness` transcription suites — each with its own hermetic RED/GREEN self-test alongside it. |
| `compile-unit-test` | yes | yes | Compiles the `--unit-test` build for **every** manifest device in one job (image pulls once). Enumerates devices fail-closed (zero devices ⇒ the job fails, never a green empty build), collects a per-device rc, and fails if any device fails. `-w` shows warnings but does not fail the build — this codebase is intentionally untyped, so no `-l` typecheck level is passed. |
| `run-tests` | yes | yes | **Executes** the `(:test)` suites headlessly in the simulator on one device (`fr965`), via `scripts/run_ciq_tests.sh`, and judges the output with the fail-closed `scripts/check_ciq_tests.py`. Separate from `compile-unit-test` so a sim flake can't mask a compile regression. Uploads `monkeydo.log` / `sim-console.log` / `xvfb.log` / `harness-status.txt`. |
| `release-build` | yes | yes | Compiles the shipping (non-unit-test) `.prg` for every device and exports the `.iq`. A device whose static image exceeds its memory limit makes `monkeyc` exit non-zero, so the compile itself is the budget gate. Uploads the `.prg`/`.iq` as the `strongrow-build-unsigned` artifact — **throwaway-signed, a build-sanity artifact, not a store upload** (a real submission is re-signed with the account-bound key). |
| `ci-required` | no | — | Aggregator. Runs with `if: always()` and **fails** unless every needed job succeeded. **This is the single status name to require in branch protection.** |

### Why `ci-required` runs `always()` and asserts, instead of just `needs:`

A naive aggregator (`needs: [...]` with the default `if: success()`) is a **footgun**: when an upstream needed job *fails*, the aggregator is *skipped* — and GitHub branch protection treats a **skipped** required check as **satisfied**, so a red build would merge. `ci-required` therefore runs on every outcome (`if: always()`) and its first step fails the job if any dependency's result is `failure`, `cancelled`, or `skipped`. That way the required `ci-required` context reports **failure** (which blocks), not skip (which wouldn't), whenever anything upstream breaks.

The CI **device matrix equals the manifest product list** — `scripts/list_devices.sh`
reads it straight from `manifest.xml`, so editing `<iq:products>` re-shapes CI
with no workflow change. The list is enumerated **fail-closed** (a manifest that
yields zero devices fails the build instead of passing green), and
`check_manifest_appid.py` **cross-checks the shell extractor against a real XML
parse** in `manifest-lint`, so the two can't silently diverge.

### `run-tests` — the suites are actually executed

Landed for #42. `compile-unit-test` proves the `(:test)` suites *compile* on all
12 devices; `run-tests` proves they *pass*. What that buys, precisely: a test
that fails, errors, is renamed, or is added unpinned now reds CI, where before
it stayed green forever. A test that *disappears* reds CI **only if its pin
line survives** — delete both together and everything passes (the
coordinated-shrinkage caveat below; #52). It also does **not** prove the
assertions are *meaningful* — see "What this does and does not buy" below.

**How it works** (`scripts/run_ciq_tests.sh`, then `scripts/check_ciq_tests.py`):

1. assert `fr965` is still in `manifest.xml`, and that its device bits exist at
   `/root/.Garmin/ConnectIQ/Devices` — the simulator needs per-device assets
   there, and `monkeyc` resolving a device only proves the *compiler*'s
   definitions exist;
2. `export HOME=/root` — the runner starts container jobs with
   `HOME=/github/home`, but that devices path is hard-coded in the SDK;
3. throwaway `openssl` key, then compile **one** device `--unit-test` (the tests
   are device-independent; `compile-unit-test` already covers all 12);
4. `Xvfb :99 -screen 0 1280x1024x24` — the explicit 24-bit depth is required;
   with no `-screen` spec Xvfb defaults to depth 8 and the GTK/WebKit simulator
   dies instantly. Wait for the X socket, **aborting** on timeout;
5. launch `/connectiq/bin/simulator` **directly** and keep its PID;
6. **wait** (not "check") for `tcp/1234`, then run `monkeydo <prg> <device> -t`
   under a hard `timeout`, capturing its exit code without ever acting on it.
   The **degraded** path (port never opened) gets the *longer* leash — 300 s vs
   180 s — because reaching it means a slow or busy runner, which is exactly
   when a short leash converts a slow pass into a false red;
7. `check_ciq_tests.py` renders the verdict.

**Every pre-`monkeydo` failure exits 2 with a breadcrumb.** The key generation,
the compile and the `.prg` check are wrapped so a failure writes
`harness_error=<cause>` to `harness-status.txt`, closes the open `::group::` (so
the forensics aren't folded away exactly where they matter) and exits **2** —
rather than `set -e` aborting on `monkeyc`'s own 1/3/5 with no breadcrumb, which
made the verdict step blame the simulator for a run in which the simulator was
never launched.

**The parser is the sole verdict.** `monkeydo` returns non-zero *even when tests
pass* (documented in the image's own `tester.sh`), and a broken run can exit 0 —
so the exit code is ignored entirely. To pass, every one of these must hold:
exactly one summary line, found in the monkeydo stream; it starts `PASSED`; no
`FAILED (passed=` anywhere; `passed == expected`, `failed == 0`, `errors == 0`;
`Ran N` agrees; and the RESULTS table contains **exactly** the names in
`scripts/expected_tests.txt`, all `PASS`.

**The table invariant, measured:** monkeydo emits the complete RESULTS block —
header + rows + tally — to its **own stdout as one contiguous block**. Every
non-cancelled `run-tests` execution on the introducing PR (14 of 14) produced
exactly that shape in `monkeydo.log`; a table split across the two log files
has never been observed and is structurally implausible (two processes, two
`>`-truncated files, fresh container). monkeydo's table is authoritative. The
parser therefore treats table multiplicity conservatively: identical duplicate
tables are accepted, **disagreeing** tables anywhere in the two logs are
refused as ambiguous — the same fail-closed doctrine as multiple summary lines
and duplicate rows.

**Names are pinned, not just the count** (`scripts/expected_tests.txt`, 21 today).
A count alone cannot see a substitution — delete one test, add a trivial one, and
21 is still 21. The expected count is simply the length of that list, so the two
can never disagree. **Update that file in the same commit as any `(:test)`
change**; the failure message names exactly what is missing and what is extra.

**Adding or removing a test is exactly two edits, and nothing else:**

1. add/remove the `(:test) function …` in the source;
2. add/remove its line in `scripts/expected_tests.txt`.

That is the whole procedure. The parser self-suite derives its name list and
counts from the pin at import, and its fixture-based cases judge the committed
capture against a pin derived *from the fixture itself* — so neither the
self-suite nor `scripts/fixtures/monkeydo-green-run.log` needs touching when
the test set changes.

**That property is enforced mechanically, not by promise.** Twice, a manual
check of this procedure was declared and was wrong (a frozen name list, then a
frozen slice and two frozen name strings — each reddened `test-tooling` on a
legitimate pin edit). So the suite now ends with a **pin-perturbation
meta-check**: it re-runs itself under three synthetic pins — one name added,
two removed, and *all* names replaced — and fails if any rerun reds. The
all-renamed probe exists because it is the only one that can see a hardcoded
*middle-of-the-list* name. (With a real pin of fewer than 5 names the
removed-two probe is skipped, with a printed reason, so it cannot red for a
false cause.)

**And the pin is cross-checked against the source, in CI** —
`scripts/check_expected_tests.sh`, in `test-tooling`. It derives the name set
independently from the `.mc` sources via `scripts/list_tests.py` — a comment-
and form-aware extractor that handles indented, own-line, multi-annotation and
argumented (`:typecheck(false)`) declarations natively, ignores commented-out
and string-quoted text, and has its own RED/GREEN suite
(`scripts/test_list_tests.py`, first step of `test-tooling`) — and diffs it
against the pin, so the two cannot **drift**. The shell refuses a partial or
empty extraction rather than trusting it.

> ⚠️ **What it does *not* close: coordinated shrinkage.** An earlier version of
> this section claimed otherwise, and that was wrong. Both sides of the diff are
> derived from files the *same commit* may edit, so deleting a `(:test)`
> function **and** its pin line together shrinks both lists identically and the
> check passes. Measured: dropping 5 of 17 tests with their pin lines still
> prints `OK: 12 … match … exactly` and `OK: 12/12`, both rc=0.
>
> Closing that needs an anchor **outside** the commit — a count compared against
> `git merge-base`, or a floor that only ratchets upward. Tracked in **#52**;
> not implemented. What catches it today is a human reading the diff, which
> shows both deletions. So the honest summary is: the pin makes a *silent*
> shrink impossible to do *by accident*, not impossible.

**The parser is proven on every PR without a container**, in `test-tooling`.
What `scripts/test_check_ciq_tests.py` establishes, precisely:

- the GREEN fixture is the **real `monkeydo.log`** from the first green
  `run-tests` run (run `30127716562`, commit `5eb2187`), committed at
  `scripts/fixtures/monkeydo-green-run.log`. It is the authoritative shape:
  `Executing test X...` and `PASS` on **separate** lines. Two other shapes exist
  in the record — #44's published transcript (one line, column-aligned) and this
  suite's synthetic builder (one line, unpadded) — and the parser survives all
  three only because it scopes to the RESULTS block. **No verbatim #44
  transcript is committed anywhere**, so no fixture here is described as one;
- every case declares the **exact set of guards** it must trip, keyed off the
  checker's own diagnostic text, and green cases must trip none. Asserting only
  the exit code was too weak to be evidence: mutation-testing the parser against
  the earlier suite left most guards deletable with the suite still fully green,
  because one malformed transcript trips several guards at once and any one of
  them yields rc=1. Guards that no transcript can isolate get a case built to
  isolate them — notably a `SKIP` row under a summary that still reads
  `PASSED (passed=21, failed=0, errors=0)` with `Ran 21`, which is the entire
  reason the not-`PASS` check exists;
- a parser that **raises instead of rendering a verdict** now fails the suite,
  because a traceback produces no diagnostics to classify.

#### What this does and does not buy

It makes **execution** permanent. It does **not** prove the tests are meaningful:
`rrArrEq` is the entire assertion for 11 of the 14 RR tests, so shared-helper rot
would leave both the name set and the pass count untouched. The one-time
non-vacuity proof (mutation testing in #44) was a snapshot, not a standing gate.

#### Superseding the earlier recipe

The recipe previously documented here (and reviewed at the time) was written
before the image's source was available. Several parts of it are now known to be
wrong, and the implementation deliberately reverses them:

| Earlier recipe | Now | Why |
|---|---|---|
| `apt-get install xvfb x11-utils iproute2 procps openssl` | no `apt-get` at all | `xvfb` is in the image's apt list and `openssl` is present transitively; `x11-utils` and `iproute2` are genuinely avoided by using `test -S` and `/dev/tcp`. **`procps` is not avoided** — the script uses `ps -ef` for topology (`\|\| true`) and `pgrep` as a *secondary* liveness opinion. Liveness never decides the verdict, but a both-signals-dead `sim_gone` does select the short 30 s monkeydo leash — load-bearing for the timeout budget only. The `pgrep` call is `command -v`-guarded for message honesty (127 already reads as "no match"). Keeps `archive.ubuntu.com` off a required check's critical path. (The recipe also omitted `apt-get update`, so it would have failed anyway.) |
| poll with `ss`/`pgrep` | bash `/dev/tcp` connect | Tests connectability, strictly stronger than seeing a LISTEN, and needs no package. `pgrep` survives only as an advisory cross-check of `kill -0`, never as the probe. |
| `pkill` stale simulators at entry | dropped | Meaningless in a fresh container, and returns 1 when nothing matches — an immediate `set -e` abort. |
| launch via the `connectiq` launcher | launch `simulator` directly | There is no such launcher in this image; upstream backgrounds `simulator` itself. Direct launch also makes `$!` the correct PID. |
| one teed `sim-run.log` | separate `monkeydo.log` and `sim-console.log` | Merged streams can produce two RESULTS blocks, which the "exactly one summary" rule would then **refuse on a green run**. |

The one deliberate deviation that remains is the `tcp/1234` wait, which
**degrades and proceeds** on timeout rather than aborting, because upstream just
`sleep 5`s and gave no evidence the port is the right readiness signal. Every
green run so far records `port_wait=open` on the first probe, so that premise is
now retired by evidence — converting the wait to a hard abort is tracked in
**#51**, deliberately gated on more than one observation so a required check
doesn't acquire a flake.

The advisory-until-proven rule still stands, but note it refers to a **free-run
"boot smoke"** — an open-ended does-it-launch check — not to this deterministic
suite runner, which is required.

## Hygiene

- **Triggers:** `push` to `main` (with `paths-ignore` for docs/store only) and
  `pull_request` with **no** `paths-ignore` — a required check must post a
  status on every PR, or "require up to date before merging" deadlocks.
- **Concurrency:** one run per ref, `cancel-in-progress: true`.
- **Permissions:** `contents: read` only.
- **Actions are SHA-pinned** with the version in a trailing comment.

## Branch protection (must be set by a repo admin)

CI reports pass/fail, but only **branch protection** turns that into a merge
gate. A repository admin must, on `main`:

1. **Require the `ci-required` status check** (Settings → Branches → branch
   protection rule for `main` → *Require status checks to pass*).
2. Enable **strict / "Require branches to be up to date before merging."**
3. **Do not allow administrators to bypass** the required checks.
4. **Retire any stale previously-required check name.** A required check name
   that no longer posts a status (e.g. an old job name) blocks *all* merges
   forever. `ci-required` is the one stable name to require going forward.

Require **only `ci-required`**, not the individual jobs — new required jobs are
added to `ci-required.needs` in the workflow, so branch protection never needs
to change again.
