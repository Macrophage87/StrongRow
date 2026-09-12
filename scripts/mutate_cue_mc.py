#!/usr/bin/env python3
"""Monkey C mutation differentials for the display-cue pins (#210 / #191).

*** THIS SCRIPT HAS NOT BEEN RUN. ***

That sentence is the reason the file is committed. PR #213 added five GREEN
(:test) pins on new symbols -- the preset table, the clamp, the cueStep/cueStepW
identity, the cue_cfg slot map and the guarded cue_cfg write -- and this
repository's own standard is that "a pin that does not red under its own
mutation is decoration". Those five have no mutation run. The environment that
blocked it was a SHARED SIMULATOR: tcp/1234 was held throughout the session that
wrote PR #213 by another agent's `simulator.exe` (13 to 29 established
connections at every check), the SDK simulator takes no alternate port, and
killing a shared process is forbidden (docs/agents/FACTS.md 4.5). Refusing to
kill it is correct behaviour, not a shortcut -- so the gap is disclosed and
given an owner instead of being quietly dropped.

**scripts/mutate_cue_mc.py was committed unrun so that the gap has an artifact
rather than a sentence in a merged pull-request body.** #218 owns running it,
and carries the byte-exact pass criterion for each mutant. Delete this
paragraph when a run is recorded there, and not before.

WHAT IT DOES. Each mutant is applied to a COPY of a tree, compiled --unit-test
for fr965, and run in a simulator this script starts ITSELF. It never attaches
to a simulator that is already listening: `port_busy()` makes it refuse outright,
because a simulator on this machine may be serving another agent's run.

    python3 scripts/mutate_cue_mc.py --tree /path/to/archive
    python3 scripts/mutate_cue_mc.py --tree /path/to/archive M-C1 M-C4

POINT IT AT A `git archive`, NOT AT A WORKING TREE. `--tree` defaults to this
file's own repository root, which is convenient and is NOT what a published
measurement should use: a worktree carries build output, nested checkouts and
scratch files (FACTS.md 1.3), and its path does not identify a commit. For a
figure anyone is going to quote:

    git -c core.autocrlf=false archive --format=tar <sha> | tar -x -C CLEANDIR
    python3 scripts/mutate_cue_mc.py --tree CLEANDIR

THE THROWAWAY KEY IS CREATED IN A TEMP DIR AND DELETED, never in the workspace.
A workspace-relative `openssl genrsa -out developer_key.pem` would silently
destroy a real account-bound key file; scripts/run_ciq_tests.sh takes the same
precaution for the same reason (FACTS.md 4.4).

MONKEYDO'S EXIT CODE IS NOT THE VERDICT -- it returns non-zero even when every
test passes (FACTS.md 1.2). What is read is the summary line and the RESULTS
rows, and for a mutation run the interesting output is the set of NON-PASS
names, not the count.

THE SEVEN MUTANTS, AND THE PIN EACH ONE SHOULD KILL. A mutant that reds nothing
is the finding: it means the pin beside it is decoration.

    M-C1  swap presets 0 and 2 in cuePresetWindows
          -> CueFix.test_cue_c1_thePresetTableIsTheFourMeasuredPairs
    M-C2  cueClampPreset drops its `instanceof Lang.Number` test
          -> CueFix.test_cue_c1_theClampRefusesEverythingButZeroToThree
    M-C3  loadSettings stores the RAW property instead of the clamped one
          -> CueFix.test_cue_c2_aCorruptedResponseSettingLeavesTheDefault
    M-C4  cueStepW reads the constants instead of its two arguments
          -> CueFix.test_cue_c1_theWindowedStepIsTheSameMachineAtTheDefaults
             and CueFix.test_cue_c2_theViewTakesItsWindowsFromTheSetting
    M-C5  drop the deadband in cueTarget
          -> the c0 deadband pins
    M-C6  permute cue_cfg slots 3 and 4
          -> CueFix.test_cue_c1_theCueCfgArrayIsTheSlotMapItDocuments
    M-C7  the draw path calls cueStep instead of cueStepW
          -> CueFix.test_cue_c2_theTwitchiestPresetAdoptsOnTheFirstFrame

EXPECTATIONS ARE NOT PREDICTIONS. The right-hand column is what each mutation
is AIMED at, written before any of them was run. If a mutant kills a different
set, report the set it actually killed -- the expectation was a hypothesis and
the run is the measurement.

WHAT THIS CANNOT SHOW, whatever it prints. It runs the same (:test) suite CI
runs, so it inherits every limit that suite has: no (:test) can obtain a
Session, so `createField` for cue_cfg is unreachable and no mutation here says
anything about what a file contains (#215); and no (:test) can obtain a
graphics Dc beyond the recording stand-in in source/CueZoneTest.mc.
"""

import argparse
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_TREE = os.path.dirname(HERE)

SRV = os.path.join("source", "StrongRowView.mc")

# (tag, file, exactly-once anchor, replacement)
MUTANTS = [
    ("M-C1", SRV,
     "        if (p == 0) { return [4000, 1000]; }",
     "        if (p == 0) { return [1000, 250]; }"),
    ("M-C2", SRV,
     "        if (!(v instanceof Lang.Number)) { return $.CUE_PRESET_DEF; }",
     "        if (false) { return $.CUE_PRESET_DEF; }"),
    ("M-C3", SRV,
     "        mCuePreset = cueClampPreset(getProp(\"cueResponse\", "
     "$.CUE_PRESET_DEF));",
     "        mCuePreset = getProp(\"cueResponse\", $.CUE_PRESET_DEF);"),
    ("M-C4", SRV,
     "        var need = (want == $.CUEZ_IN) ? inMs : outMs;",
     "        var need = (want == $.CUEZ_IN) ? $.CUE_PERSIST_IN_MS\n"
     "                                       : $.CUE_PERSIST_OUT_MS;"),
    ("M-C5", SRV,
     "            return cueBandZone(rate, lo - $.CUE_DEADBAND, "
     "hi + $.CUE_DEADBAND);",
     "            return cueBandZone(rate, lo, hi);"),
    ("M-C6", SRV,
     "        a[3] = cueCfgU16(preset);\n        a[4] = cueCfgU16(outMs);",
     "        a[3] = cueCfgU16(outMs);\n        a[4] = cueCfgU16(preset);"),
    ("M-C7", SRV,
     "            cue = cueStepW(dispRate, mTgtLo, mTgtHi,\n"
     "                           mCueZone, mCueCand, mCueSince, nowMs(),\n"
     "                           mCueOutMs, mCueInMs);",
     "            cue = cueStep(dispRate, mTgtLo, mTgtHi,\n"
     "                          mCueZone, mCueCand, mCueSince, nowMs());"),
]


def sdk_bin():
    """The SDK's bin directory, or None. Verify, do not assume (FACTS.md 1.1)."""
    roots = [os.path.expanduser("~/AppData/Roaming/Garmin/ConnectIQ/Sdks"),
             os.path.expanduser("~/Library/Application Support/Garmin/"
                                "ConnectIQ/Sdks")]
    for root in roots:
        if not os.path.isdir(root):
            continue
        for name in sorted(os.listdir(root), reverse=True):
            cand = os.path.join(root, name, "bin")
            if os.path.isdir(cand):
                return cand
    return None


def port_busy():
    """True if anything is listening on 1234.

    A simulator on this machine may be serving another agent's run, so this is
    a REFUSAL condition and never a reason to kill anything.
    """
    try:
        p = subprocess.run(["netstat", "-ano"], capture_output=True, text=True)
    except OSError:
        p = subprocess.run(["ss", "-ltn"], capture_output=True, text=True)
    return ":1234 " in p.stdout


def make_key(keydir):
    """A throwaway developer key, in a temp dir, NEVER in the workspace."""
    pem = os.path.join(keydir, "dk.pem")
    der = os.path.join(keydir, "developer_key.der")
    subprocess.run(["openssl", "genrsa", "-out", pem, "4096"],
                   check=True, capture_output=True)
    subprocess.run(["openssl", "pkcs8", "-topk8", "-inform", "PEM",
                    "-outform", "DER", "-in", pem, "-out", der, "-nocrypt"],
                   check=True, capture_output=True)
    return der


def build(sdk, tree, out_prg, key):
    p = subprocess.run([os.path.join(sdk, "monkeyc.bat"),
                        "-f", os.path.join(tree, "monkey.jungle"),
                        "-o", out_prg, "-y", key, "-d", "fr965",
                        "--unit-test"],
                       capture_output=True, text=True, cwd=tree)
    return p.returncode, p.stdout + p.stderr


def run_suite(sdk, prg):
    if port_busy():
        return None, ["REFUSED: tcp/1234 is in use -- not ours to disturb"]
    sim = subprocess.Popen([os.path.join(sdk, "simulator.exe")],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            if port_busy():
                break
            time.sleep(1)
        env = dict(os.environ, MSYS_NO_PATHCONV="1")
        p = subprocess.run([os.path.join(sdk, "monkeydo.bat"),
                            os.path.basename(prg), "fr965", "/t"],
                           capture_output=True, text=True, timeout=1800,
                           cwd=os.path.dirname(prg), env=env)
        out = p.stdout + p.stderr
        # monkeydo's exit code is NEVER the verdict (FACTS.md 1.2).
        m = re.search(r"(PASSED|FAILED) \(passed=\d+, failed=\d+, errors=\d+",
                      out)
        fails = sorted(set(re.findall(r"^(\S+)\s+(?:FAIL|ERROR)\s*$", out,
                                      re.M)))
        return (m.group(0) if m else "NO SUMMARY LINE"), fails
    finally:
        # Only the pid this function started. Never a shared one.
        sim.terminate()
        time.sleep(2)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tree", default=DEFAULT_TREE,
                    help="tree to mutate; point it at a `git archive` "
                         "extraction, not at a working tree")
    ap.add_argument("only", nargs="*", help="mutant tags, e.g. M-C1 M-C4")
    args = ap.parse_args(argv)

    sdk = sdk_bin()
    if sdk is None:
        print("No Connect IQ SDK found. This script measures nothing without "
              "one; it does not guess.")
        return 2
    if port_busy():
        print("REFUSING: tcp/1234 is already in use. A simulator on this "
              "machine may be serving another agent's run, and killing a "
              "shared process is not ours to do (FACTS.md 4.5). Nothing was "
              "run and nothing is claimed.")
        return 3

    keydir = tempfile.mkdtemp(prefix="cuemut-key-")
    try:
        key = make_key(keydir)
        for tag, path, old, new in MUTANTS:
            if args.only and tag not in args.only:
                continue
            tmp = tempfile.mkdtemp(prefix="cuemut-")
            for d in ("source", "resources", "scripts"):
                shutil.copytree(os.path.join(args.tree, d),
                                os.path.join(tmp, d))
            for f in ("monkey.jungle", "manifest.xml"):
                shutil.copy(os.path.join(args.tree, f), os.path.join(tmp, f))
            target = os.path.join(tmp, path)
            s = io.open(target, encoding="utf-8").read()
            if s.count(old) != 1:
                # A mutation that did not apply is a SKIP and never a pass:
                # reporting it as "nothing red" would be a false negative.
                print("%-6s SKIPPED -- anchor matched %d times, expected 1"
                      % (tag, s.count(old)))
                continue
            io.open(target, "w", encoding="utf-8", newline="\n").write(
                s.replace(old, new))
            prgdir = tempfile.mkdtemp(prefix="cuemut-prg-")
            prg = os.path.join(prgdir, "mutant-%s.prg" % tag)
            rc, log = build(sdk, tmp, prg, key)
            if rc != 0:
                print("%-6s BUILD FAILED rc=%s" % (tag, rc))
                print("       " + "\n       ".join(log.splitlines()[-4:]))
                continue
            summary, fails = run_suite(sdk, prg)
            print("%-6s %s" % (tag, summary))
            print("       reds: %s"
                  % (", ".join(fails) if fails
                     else "NONE -- the pin it aims at is decoration"))
    finally:
        shutil.rmtree(keydir, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
