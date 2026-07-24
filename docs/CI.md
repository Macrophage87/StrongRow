# Continuous Integration

StrongRow's CI is **runner-free**: every job runs on stock GitHub-hosted
`ubuntu-latest`. There is **no self-hosted runner** and **no Garmin SDK
download**. The Connect IQ SDK comes from running a pre-built Docker image as the
job `container`, so the only thing GitHub pulls is that image.

Workflow: [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

## The SDK container

SDK-dependent jobs run inside:

```
ghcr.io/matco/connectiq-tester@sha256:7a6f586cb0e0393ff288da09cf27b6dad40a0058a346c529b99fd0fc19858f0f   # v2.8.0 = SDK 9.2.0
```

The image is **pinned by digest** — the digest is the real pin; the `v2.8.0`
tag lives in a trailing comment for humans. To move SDKs, change the digest and
update the comment together.

**When to bump:** if a device in `manifest.xml` is not defined in the current
SDK, the compile job fails with an unknown-device error. Bump to a newer
`connectiq-tester` tag that ships that device and repin the digest.

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
12 devices; `run-tests` proves they *pass*. Without it a wrong assertion, or a
real regression, stayed green forever — which was this pipeline's main gap.

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
   under a hard `timeout`, capturing its exit code without ever acting on it;
7. `check_ciq_tests.py` renders the verdict.

**The parser is the sole verdict.** `monkeydo` returns non-zero *even when tests
pass* (documented in the image's own `tester.sh`), and a broken run can exit 0 —
so the exit code is ignored entirely. To pass, every one of these must hold:
exactly one summary line, found in the monkeydo stream; it starts `PASSED`; no
`FAILED (passed=` anywhere; `passed == expected`, `failed == 0`, `errors == 0`;
`Ran N` agrees; and the RESULTS table contains **exactly** the names in
`scripts/expected_tests.txt`, all `PASS`.

**Names are pinned, not just the count** (`scripts/expected_tests.txt`, 17 today).
A count alone cannot see a substitution — delete one test, add a trivial one, and
17 is still 17. The expected count is simply the length of that list, so the two
can never disagree. **Update that file in the same commit as any `(:test)`
change**; the failure message names exactly what is missing and what is extra.

**The parser is proven on every PR without a container.** `manifest-lint` runs
`scripts/test_check_ciq_tests.py`, whose fixtures are the real PASSED and FAILED
transcripts from #44 plus truncated / empty / duplicate / glued-line inputs.

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
| `apt-get install xvfb x11-utils iproute2 procps openssl` | no `apt-get` at all | `xvfb`/`openssl` are already in the image; the other three are avoided by using `/dev/tcp`, `kill -0` and `test -S`. Keeps `archive.ubuntu.com` off a required check's critical path. (It also omitted `apt-get update`, so it would have failed anyway.) |
| poll with `ss`/`pgrep` | bash `/dev/tcp` connect | Tests connectability, strictly stronger than seeing a LISTEN, and needs no package. |
| `pkill` stale simulators at entry | dropped | Meaningless in a fresh container, and returns 1 when nothing matches — an immediate `set -e` abort. |
| launch via the `connectiq` launcher | launch `simulator` directly | There is no such launcher in this image; upstream backgrounds `simulator` itself. Direct launch also makes `$!` the correct PID. |
| one teed `sim-run.log` | separate `monkeydo.log` and `sim-console.log` | Merged streams can produce two RESULTS blocks, which the "exactly one summary" rule would then **refuse on a green run**. |

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
