#!/usr/bin/env bash
# Run the Connect IQ (:test) suites headlessly in the simulator.
#
# MUST be bash, not sh: this uses /dev/tcp, [[ ]] and pipefail. Ubuntu's /bin/sh
# is dash, where all three break at once (and the port wait would then silently
# fail every iteration).
#
# Mechanics follow matco/connectiq-tester's own tester.sh (the image's
# ENTRYPOINT), which is the best available evidence for how this SDK behaves
# headlessly. We deliberately do NOT reuse that script: it compiles with -l 3
# strict typechecking, which this intentionally-untyped codebase will not pass.
#
# EXIT CONTRACT
#   0  -> the harness ran to completion. The VERDICT IS NOT OURS: it belongs to
#         scripts/check_ciq_tests.py. This includes monkeydo timing out or
#         exiting non-zero (it returns non-zero even on success, by design).
#   2  -> the harness failed BEFORE monkeydo could run (X never came up, the
#         simulator died, the compile or key generation failed, the .prg or the
#         device bits are missing). No verdict is possible; the parser will also
#         fail, but this exit code says why, and a `harness_error` breadcrumb is
#         ALWAYS written first so the verdict step can explain itself.
#
# Every pre-monkeydo failure must go through `fail_harness`. A bare command
# aborting on `set -e` would exit with ITS OWN code (1/3/5...), write no
# breadcrumb, and leave the verdict step printing "the simulator produced no
# output (hung, crashed at launch, or never started)" -- all three causes wrong,
# because the simulator was never launched at all.
set -euo pipefail

DEVICE="${1:-fr965}"
OUT_DIR="${OUT_DIR:-bin}"
LOG_DIR="${LOG_DIR:-.}"
PRG="${OUT_DIR}/StrongRow-test-${DEVICE}.prg"     # single source of truth
MONKEYDO_LOG="${LOG_DIR}/monkeydo.log"
CONSOLE_LOG="${LOG_DIR}/sim-console.log"
XVFB_LOG="${LOG_DIR}/xvfb.log"
STATUS_FILE="${LOG_DIR}/harness-status.txt"

DISPLAY_NUM=99                                     # one variable; :99 and X99 can't drift
export DISPLAY=":${DISPLAY_NUM}"
X_SOCKET="/tmp/.X11-unix/X${DISPLAY_NUM}"

# The device bits are hard-coded to /root/.Garmin/ConnectIQ/Devices in both the
# compiler and the simulator (per the image's Dockerfile). The GitHub runner
# starts container jobs with HOME=/github/home, so set it back. This export is
# local to this script's process tree -- sibling workflow steps keep their HOME.
export HOME=/root

mkdir -p "$OUT_DIR" "$LOG_DIR"
: > "$STATUS_FILE"
status() { echo "$1=$2" >> "$STATUS_FILE"; }

# The ONLY way out before monkeydo. Closes the open ::group:: first -- otherwise
# the forensics that explain the failure are folded into a collapsed group,
# exactly where a reader needs them expanded.
fail_harness() {
    echo "::endgroup::"
    echo "::error::$2"
    status harness_error "$1"
    exit 2
}

sim_pid=""
xvfb_pid=""
# Capture the real exit code FIRST: without this, a fully successful run exits
# non-zero simply because the sim had already gone and `kill` returned 1.
cleanup() {
    ec=$?
    [[ -n "$sim_pid" ]]  && kill "$sim_pid"  2>/dev/null || true
    [[ -n "$xvfb_pid" ]] && kill "$xvfb_pid" 2>/dev/null || true
    exit "$ec"
}
trap cleanup EXIT

echo "::group::Environment (run-1 forensics)"
echo "HOME=$HOME  DISPLAY=$DISPLAY  DEVICE=$DEVICE  PWD=$PWD"
command -v monkeyc monkeydo simulator || true
java -version 2>&1 | head -3 || true
echo "--- device bits visible to the SIMULATOR (not just the compiler) ---"
ls -1 /root/.Garmin/ConnectIQ/Devices 2>&1 | head -20 || true
if [[ ! -d "/root/.Garmin/ConnectIQ/Devices/${DEVICE}" ]]; then
    # monkeyc resolving a device proves the COMPILER's definitions exist; the
    # simulator needs per-device assets in this path. Fail here with a precise
    # message rather than letting the sim die mysteriously later.
    fail_harness "device_bits_missing:${DEVICE}" \
        "device '${DEVICE}' is not installed at /root/.Garmin/ConnectIQ/Devices"
fi
echo "::endgroup::"

echo "::group::Compile --unit-test for ${DEVICE}"
# Throwaway key, same as the other CI jobs: monkeyc needs one even for a test
# build. Never committed, never a secret.
#
# Grouped behind `|| rc=$?` so a compile or key failure exits 2 WITH a
# breadcrumb instead of `set -e` aborting on monkeyc's own exit code. Without
# this the `prg_missing` branch below is unreachable dead code, because a failed
# monkeyc kills the script before it is ever evaluated.
# -w warnings on, but NO -l: this codebase is deliberately untyped.
build_rc=0
{
    openssl genrsa -out developer_key.pem 4096 2>/dev/null &&
    openssl pkcs8 -topk8 -inform PEM -outform DER \
        -in developer_key.pem -out developer_key.der -nocrypt &&
    monkeyc -f monkey.jungle -o "$PRG" -y developer_key.der -d "$DEVICE" --unit-test -w
} || build_rc=$?
if [[ "$build_rc" != "0" ]]; then
    fail_harness "compile_failed:${build_rc}" \
        "key generation or monkeyc --unit-test failed (rc=${build_rc}); monkeydo never ran"
fi
if [[ ! -f "$PRG" ]]; then
    fail_harness "prg_missing" "compile reported success but produced no $PRG"
fi
ls -l "$PRG" "${PRG}.debug.xml" 2>/dev/null || true   # debug.xml aids symbolization
echo "::endgroup::"

echo "::group::Start Xvfb and simulator"
# -screen with an explicit 24-bit depth is REQUIRED: with no -screen spec Xvfb
# defaults to depth 8, on which the GTK/WebKit simulator dies instantly.
# Upstream sets exactly this.
Xvfb "$DISPLAY" -screen 0 1280x1024x24 > "$XVFB_LOG" 2>&1 &
xvfb_pid=$!    # captured immediately; any other background job would clobber $!

# X readiness: this premise IS verified (upstream does the same wait), so a
# timeout here is a hard abort. Bounded, and liveness-checked -- the socket file
# persists if Xvfb crashes after creating it, so `test -S` alone can silently
# succeed against a dead server.
x_ready=no
for _ in $(seq 1 30); do
    if ! kill -0 "$xvfb_pid" 2>/dev/null; then
        cat "$XVFB_LOG" 2>/dev/null || true
        fail_harness "xvfb_died" "Xvfb died during startup; see $XVFB_LOG"
    fi
    if [[ -S "$X_SOCKET" ]]; then x_ready=yes; break; fi
    sleep 1
done
if [[ "$x_ready" != "yes" ]]; then
    fail_harness "xvfb_no_socket" "Xvfb socket $X_SOCKET never appeared"
fi
status xvfb ready

# Launch the simulator DIRECTLY (it is on PATH at /connectiq/bin), exactly as
# upstream does. There is no `connectiq` launcher wrapper in this image.
simulator > "$CONSOLE_LOG" 2>&1 &
sim_pid=$!
sleep 1
ps -ef | grep -i -e simulator -e Xvfb | grep -v grep || true   # topology, run-1 forensics
echo "::endgroup::"

echo "::group::Wait for the simulator to accept connections"
# NOTE: this is a WAIT, not a verification. That the simulator listens on
# tcp/1234 is the one premise we could not confirm from upstream source
# (upstream just sleeps 5s). So on timeout we LOG LOUDLY AND PROCEED: monkeydo
# itself is ground truth, and no connection => no summary => the parser already
# fails closed. Gating on an unconfirmed proxy could only add false reds.
port_state=timeout
for _ in $(seq 1 25); do
    # Must sit in an if/|| context: a bare (exec 3<>/dev/tcp/...) would abort
    # the script under `set -e` on the very first refused connection.
    if (exec 3<>/dev/tcp/127.0.0.1/1234) 2>/dev/null; then
        port_state=open; break
    fi
    # Liveness is ADVISORY only. `ps -ef` above now shows `simulator` really is
    # a single long-lived process, so `$!` is the right PID -- but this stays
    # advisory until the degrade-on-timeout path itself becomes a hard abort
    # (tracked in #51 -- gated on more than one green run, not just run 1).
    #
    # pgrep comes from `procps`, which the image installs only TRANSITIVELY (it
    # is not in the upstream Dockerfile's apt list). Guard the call so an SDK
    # bump that drops it degrades to kill -0 alone rather than having a
    # `command not found` 127 silently read as "process is gone".
    if ! kill -0 "$sim_pid" 2>/dev/null \
       && ! { command -v pgrep >/dev/null 2>&1 && pgrep -f simulator >/dev/null 2>&1; }; then
        echo "simulator appears to have exited (both kill -0 and pgrep agree)"
        port_state=sim_gone; break
    fi
    sleep 1
done
status port_wait "$port_state"
if [[ "$port_state" != "open" ]]; then
    echo "::error::simulator not reachable on tcp/1234 (state=$port_state); proceeding anyway -- monkeydo decides"
    # Decode LISTENING ports with no packages. `$4=="0A"` is TCP_LISTEN --
    # without it this prints every socket's local port under a "listening"
    # label, which is worse than no diagnostic. (IPv4 only; /proc/net/tcp6
    # would need the same treatment if the simulator ever binds v6-only.)
    echo "--- listening TCP ports (local_address hex -> decimal) ---"
    awk 'NR>1 && $4=="0A" {split($2,a,":"); print a[2]}' /proc/net/tcp 2>/dev/null \
        | sort -u | while read -r hexport; do
              [[ -n "$hexport" ]] && printf '  0x%s = %d\n' "$hexport" "$((16#$hexport))"
          done || true
fi
echo "::endgroup::"

echo "::group::Run monkeydo"
# monkeydo's exit code is NEVER the verdict -- upstream documents it returns
# non-zero even when tests pass. Capture it for diagnostics only, and never let
# it kill this script (which is why there is no `tee` here either: with
# pipefail, upstream's own bug would abort every green run).
#
# The degraded path gets MORE patience, not less. It was the other way round,
# which is backwards: a port that never opened means a slow or busy runner --
# precisely the case where a short leash converts a slow pass into a false red.
# (Observed: the whole job took 46 s with the port open on the first probe, so
# 180 s is already ~17x headroom on the happy path; the job timeout is 20 min.)
if [[ "$port_state" == "open" ]]; then md_timeout=180; else md_timeout=300; fi
rc=0
timeout -k 10 "$md_timeout" monkeydo "$PRG" "$DEVICE" -t > "$MONKEYDO_LOG" 2>&1 || rc=$?
status monkeydo_rc "$rc"
# 124 = TERM took effect; 137 = 128+SIGKILL, i.e. `-k 10` had to escalate. Both
# are timeouts, and recording only 124 lets an escalated kill look like a plain
# non-zero exit.
if [[ "$rc" == "124" || "$rc" == "137" ]]; then status monkeydo timed_out; fi
if kill -0 "$sim_pid" 2>/dev/null; then status sim_alive yes; else status sim_alive no; fi
echo "--- monkeydo output (also uploaded as an artifact) ---"
cat "$MONKEYDO_LOG" || true
echo "::endgroup::"

echo "Harness completed; verdict deferred to scripts/check_ciq_tests.py"
exit 0
