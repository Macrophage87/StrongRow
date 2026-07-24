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
| `manifest-lint` | no | yes | Fail-closed check that the manifest app id is a real 32-hex id (not a placeholder/template), the app has an entry/name/known type, and at least one device is listed. A bad id still compiles and still passes tests but the store rejects it — the SDK jobs can't catch this class. |
| `compile-unit-test` | yes | yes | Compiles the `--unit-test` build for **every** manifest device in one job (image pulls once). Collects a per-device rc and fails if any device fails. `-w` shows warnings but does not fail the build — this codebase is intentionally untyped, so no `-l` typecheck level is passed. |
| `release-build` | yes | yes | Compiles the shipping (non-unit-test) `.prg` for every device and exports the store `.iq`. A device whose static image exceeds its memory limit makes `monkeyc` exit non-zero, so the compile itself is the budget gate. Uploads the `.prg`/`.iq` as the `strongrow-build` artifact. |
| `ci-required` | no | — | Aggregator. `needs` all required jobs and just echoes success. **This is the single status name to require in branch protection.** |

The CI **device matrix equals the manifest product list** — `scripts/list_devices.sh`
reads it straight from `manifest.xml`, so editing `<iq:products>` re-shapes CI
with no workflow change.

### No `run-tests` job (yet)

The design also specifies a headless-simulator `run-tests` job — but only *if
the repo has `(:test)` functions*. **StrongRow currently has none**, so that job
and its helpers are intentionally omitted rather than shipped as untested,
hang-prone dead code.

**To enable it when you add tests:** add source functions annotated `(:test)`,
then add a `run-tests` job (in a container, separate from `compile-unit-test` so
a sim flake can't mask a compile regression) that:

1. `apt-get install`s `xvfb x11-utils iproute2 procps openssl` (guarded — skip
   if already present);
2. compiles **one** representative device `--unit-test` (pure tests are
   device-independent; `compile-unit-test` already covers every device);
3. runs a `scripts/run_ciq_tests.sh` that pkills any stale simulator, starts
   `Xvfb` on a dedicated `DISPLAY`, launches the sim once, **polls port 1234
   with `ss`/`pgrep` until it's listening**, then runs
   `monkeydo <prg> <device> -t` under a hard `timeout` and tees to `sim-run.log`;
4. runs a `scripts/check_ciq_tests.py` **fail-closed** parser that requires
   `ran == passed == expected`, `failed == 0`, `errors == 0`, and `tests > 0`,
   and **never** trusts the `monkeydo` exit code (the sim can exit 0 on a broken
   run); zero tests run = FAIL;
5. uploads `sim-run.log` as an artifact with `if: always()`;
6. adds `run-tests` to `ci-required.needs`.

Keep any headless free-run "boot smoke" **advisory** (`continue-on-error`, out
of `ci-required.needs`) until it's proven with a RED/GREEN differential.

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
