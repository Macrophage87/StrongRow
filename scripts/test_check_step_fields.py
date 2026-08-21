#!/usr/bin/env python3
"""RED/GREEN tests for scripts/check_step_fields.py.

Every case builds a scratch source/StrongRowView.mc, runs the REAL checker as a
subprocess with --root (the same interface CI uses), and asserts the exit code
plus, for the failures, that the printed reason names the thing that is wrong.
A guard whose message does not identify the defect costs a maintainer the same
hour the defect would have.

HERMETIC: nothing here reads the repository. The repository's own figures are
asserted by the CI step that runs the checker with no --root; if that ever moved
in here, a maintainer editing the real block would red a TOOL suite instead of
the check that prints the offending figure.

THE HEADLINE CASES are the three defects review found in the shipped block,
reproduced rather than described: a marked line saying TWO field_descriptions
where the code creates four; the creation block moved inside a
`mWorkoutEnabled` branch, which is the one edit here that no (:test) could see;
and the tick's pair write with `mSetNum` read at the call instead of hoisted,
which is the shape the "ONE READ" comment described but the code did not have.

The marker word is assembled rather than written, so this file's fixtures can
never be picked up as a real line.

Run: python3 scripts/test_check_step_fields.py
"""

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_step_fields.py")

MARK = "STEP" + "FIELDS"

CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


# The tick's pair write, exactly as shipped: every input of BOTH fields taken
# into a local ABOVE the first setData.
PAIR = """    hidden function onTick() {
        if (mStarted && !mPaused) {
            var stepT = curStepType();
            var setN  = mSetNum;
            var wEn   = mWorkoutEnabled;
            var sted  = mStarted;
            if (mFitStepType != null) {
                mFitStepType.setData(stepTypeCode(stepT, wEn, sted));
            }
            if (mFitIvlNum != null) {
                mFitIvlNum.setData(intervalNumOf(wEn, sted, setN));
            }
        }
    }
"""

# One field from another group, so `total_fields` is a count of the whole file
# and not a restatement of `descs`.
OTHER_FIELD = """            try {
                mFitRate = mSession.createField(
                    "row_stroke_rate", 0, Fit.DATA_TYPE_FLOAT,
                    { :mesgType => Fit.MESG_TYPE_RECORD, :units => "spm" });
            } catch (e) {
                mFitRate = null;
            }
"""

STEP_BLOCK = """            try {
                mFitStepType = mSession.createField(
                    "step_type", 17, Fit.DATA_TYPE_UINT8,
                    { :mesgType => Fit.MESG_TYPE_RECORD, :units => "n" });
                mFitIvlNum = mSession.createField(
                    "interval_num", 18, Fit.DATA_TYPE_UINT16,
                    { :mesgType => Fit.MESG_TYPE_RECORD, :units => "n" });
            } catch (e) {
                mFitStepType = null;
                mFitIvlNum   = null;
            }
            try {
                mFitLapStep = mSession.createField(
                    "lap_step_type", 25, Fit.DATA_TYPE_UINT8,
                    { :mesgType => Fit.MESG_TYPE_LAP, :units => "n" });
                mFitLapIvl = mSession.createField(
                    "lap_interval_num", 26, Fit.DATA_TYPE_UINT16,
                    { :mesgType => Fit.MESG_TYPE_LAP, :units => "n" });
            } catch (e) {
                mFitLapStep = null;
                mFitLapIvl  = null;
            }
"""

GOOD_LINE = "descs=4 rec_bytes=3 lap_bytes=3 total_fields=5"


def source(line=GOOD_LINE, pair=PAIR, step_block=STEP_BLOCK,
           other=OTHER_FIELD, gate=None, with_line=True):
    """`gate`, when given, wraps the step block in `if (<gate>) { ... }` --
    the edit the whole suite would stay green under."""
    block = step_block
    if gate is not None:
        block = ("            if (%s) {\n" % gate) + block + "            }\n"
    txt = "using Toybox.FitContributor as Fit;\n\nclass StrongRowView {\n\n"
    txt += pair + "\n"
    if with_line:
        txt += "    //   %s %s\n" % (MARK, line)
    txt += "    hidden function startSession() {\n"
    txt += "        if (mSession == null) {\n"
    txt += other
    txt += block
    txt += "        }\n    }\n}\n"
    return txt


def run(text):
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "source", "StrongRowView.mc")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        proc = subprocess.run([sys.executable, CHECKER, "--root", td],
                              capture_output=True, text=True, timeout=60)
        out = (proc.stdout + proc.stderr).replace(td, "<root>")
        return proc.returncode, out.replace(os.sep, "/")


# ------------------------------------------------------------------ accepted --

@case("the shipped shape passes")
def _():
    rc, out = run(source())
    return (rc, "OK:" in out), (0, True)


# ------------------------------------------------------------------ rejected --

@case("'two field_description messages' is rejected where the code creates 4")
def _():
    # THE DEFECT THIS CHECKER WAS WRITTEN FOR, reproduced. The block's own note
    # said two; it creates four, because the lap copies are in the same ungated
    # block and were not counted.
    rc, out = run(source(line="descs=2 rec_bytes=3 lap_bytes=3 total_fields=5"))
    return (rc, "descs=2" in out, "code gives 4" in out), (1, True, True)


@case("a wrong per-record byte figure is rejected")
def _():
    rc, out = run(source(line="descs=4 rec_bytes=2 lap_bytes=3 total_fields=5"))
    return (rc, "rec_bytes=2" in out, "code gives 3" in out), (1, True, True)


@case("widening interval_num to UINT32 moves rec_bytes and reds the line")
def _():
    # The figure has to follow the DECLARED type, not a remembered one: this is
    # the same table scripts/fit_step_marks.py encodes with.
    bad = STEP_BLOCK.replace('"interval_num", 18, Fit.DATA_TYPE_UINT16',
                             '"interval_num", 18, Fit.DATA_TYPE_UINT32')
    rc, out = run(source(step_block=bad))
    return (rc, "rec_bytes=3" in out, "code gives 5" in out), (1, True, True)


@case("a wrong total field count is rejected")
def _():
    rc, out = run(source(line="descs=4 rec_bytes=3 lap_bytes=3 total_fields=26"))
    return (rc, "total_fields=26" in out, "code gives 5" in out), (1, True, True)


@case("gating creation on mWorkoutEnabled is rejected")
def _():
    # THE EDIT NO (:test) CAN SEE. Every step-mark case injects recording
    # stand-ins straight into the handles, so createField is never reached and
    # the whole suite stays green under this.
    rc, out = run(source(gate="mWorkoutEnabled"))
    return (rc, "must NOT be gated on a mode flag" in out,
            "mWorkoutEnabled" in out), (1, True, True)


@case("gating creation on mErgMode is rejected too")
def _():
    rc, out = run(source(gate="mErgMode"))
    return (rc, "must NOT be gated on a mode flag" in out), (1, True)


@case("`if (mSession == null)` is a lifecycle test and is NOT rejected")
def _():
    # The non-vacuity witness for the gate check: it must reject MODE branches
    # and only mode branches, or it would be rejecting the block's real home.
    rc, out = run(source(gate="mSession != null"))
    return (rc, "OK:" in out), (0, True)


@case("reading mSetNum at the call instead of hoisting it reds the pair")
def _():
    # The shape the "ONE READ of the step type for both fields" comment
    # described while the code did not have it: stepT hoisted, mSetNum read at
    # the call site, nothing shared between the two writes.
    bad = PAIR.replace("            var setN  = mSetNum;\n", "")
    bad = bad.replace("intervalNumOf(wEn, sted, setN)",
                      "intervalNumOf(wEn, sted, mSetNum)")
    rc, out = run(source(pair=bad))
    return (rc, "pair write has changed" in out,
            "adjacency is a weaker guarantee" in out), (1, True, True)


@case("swapping the two writes' order reds the pair")
def _():
    bad = PAIR.replace("stepTypeCode(stepT, wEn, sted)",
                       "stepTypeCode(curStepType(), wEn, sted)")
    rc, out = run(source(pair=bad))
    return (rc, "pair write has changed" in out), (1, True)


@case("a duplicate developer field id is rejected")
def _():
    bad = STEP_BLOCK.replace('"lap_step_type", 25,', '"lap_step_type", 17,')
    rc, out = run(source(step_block=bad))
    return (rc, "created twice" in out, "id 17" in out), (1, True, True)


@case("a missing marked line is rejected")
def _():
    rc, out = run(source(with_line=False))
    return (rc, MARK + " line" in out), (1, True)


@case("no createField at all is a failure, not a vacuous pass")
def _():
    rc, out = run(source(step_block="", other=""))
    return (rc, "vacuous pass" in out), (1, True)


@case("a deleted step-mark field fails closed")
def _():
    bad = STEP_BLOCK.replace(
        '                mFitLapIvl = mSession.createField(\n'
        '                    "lap_interval_num", 26, Fit.DATA_TYPE_UINT16,\n'
        '                    { :mesgType => Fit.MESG_TYPE_LAP, :units => "n" });\n',
        "")
    rc, out = run(source(step_block=bad))
    return (rc, "mFitLapIvl" in out or "lap_interval_num" in out), (1, True)


@case("a missing pair write is rejected")
def _():
    rc, out = run(source(pair="    hidden function onTick() {\n    }\n"))
    return (rc, "pair write was not found" in out), (1, True)


def main():
    failures = 0
    for name, fn in CASES:
        try:
            got, want = fn()
            ok = got == want
        except Exception as exc:
            print("FAIL %s" % name)
            print("      ! raised %r" % (exc,))
            failures += 1
            continue
        print("%-4s %s" % ("OK" if ok else "FAIL", name))
        if not ok:
            failures += 1
            print("      ! expected = %r" % (want,))
            print("      !      got = %r" % (got,))
    print("\n%d/%d step-field checker tests passed."
          % (len(CASES) - failures, len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
