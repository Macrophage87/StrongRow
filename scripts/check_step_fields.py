#!/usr/bin/env python3
"""Fail-closed derivation check on the step-mark developer fields (#130 / #154).

WHY THIS EXISTS. The step marks are the one group of developer fields in this
app that NO (:test) can watch being created: a (:test) cannot obtain a Session,
so `createField` itself is unreachable from the suite, and every step-mark case
injects recording stand-ins straight into the handles. Three consequences were
found by review, and all three are the same shape -- a comment stating a number
or a condition that the code alone decides:

  * the block's own note said "the cost is two field_description messages on a
    free row". It creates FOUR, and the term that dominates is not the messages
    at all but the 3 bytes the record pair costs on EVERY record;
  * the note that justifies creating them on a free row depends on the block
    staying UNGATED. Gating creation on `mWorkoutEnabled` is the one edit here
    that would leave the whole suite green, because no case reaches createField;
  * the tick write claimed "ONE READ of the step type for both fields" while
    interval_num read `mSetNum` straight from the field and shared nothing with
    that read. The pair was protected by ADJACENCY, which is a different and
    weaker guarantee than the one the comment named.

So the numbers and the shape are derived here instead of asserted there.

WHAT IS DERIVED, all of it out of source/StrongRowView.mc:

  * descs        the number of createField calls that assign one of the four
                 step-mark handles;
  * rec_bytes    the per-RECORD cost of the pair, summed from the FIT base types
                 the calls DECLARE (UINT8 + UINT16 = 3), through the same table
                 scripts/fit_step_marks.py encodes with -- one copy, not two;
  * lap_bytes    the same for the lap-scope copies;
  * total_fields every createField call in the file, which is the "TWENTY-SIX
                 fields" the block's #154 paragraph rests on;
  * every developer field id in the file, checked for UNIQUENESS. A developer
    field id is unique per field_description, which is why the lap copies could
    not reuse 17 and 18; a collision would silently re-label a field.

and compared against one machine-readable line:

    STEPFIELDS descs=4 rec_bytes=3 lap_bytes=3 total_fields=26

WHAT IS PINNED RATHER THAN DERIVED:

  * THE CREATION SITE IS NOT INSIDE A MODE BRANCH. The enclosing `{` headers
    between the file and the first step-mark createField are walked, and none of
    them may test `mWorkoutEnabled` or `mErgMode`. That is the free-row property
    the block's note claims, expressed as the only thing about it a static check
    can see;
  * THE TICK'S PAIR WRITE. Its body is mirrored here verbatim-normalised, the
    way scripts/check_pip_geometry.py mirrors the five pip formulas. Un-hoisting
    either input, or moving a read below a write, changes the normalised body
    and fails by name -- which is the point, since the comment beside it states
    a property of the hoist.

WHAT THIS CANNOT CHECK, stated so nobody reads more into a green run. It does
not compile, run or decode anything. It cannot tell you that a Session accepts
twenty-six fields, that MESG_TYPE_LAP is accepted at createField time, that a
field_description reaches a file, or what any decoder renders -- those are
[Local] questions and the issue filed with the step marks owns them. The
"34 bytes per field_description" figure quoted in the source is the layout
scripts/fit_step_marks.py's own synthetic encoder uses; the device's encoder
chooses its own string sizes and has not been measured, so this check does not
assert a byte count for the messages and neither does the comment.

Usage:
  check_step_fields.py [--root DIR]

Exit 0 = the marked line and the shape agree with the code, 1 = a problem,
printed with the figure that disagrees.
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

# The repository's ONE Monkey C lexer, reused rather than copied: a second
# comment/string stripper is a second thing to get wrong, and this one is
# already pinned by scripts/test_list_tests.py.
from list_tests import strip_comments                    # noqa: E402
# The FIT base-type sizes and the four field declarations, read through the
# harness that ENCODES with them, so a size table cannot drift between the
# checker and the file it describes.
from fit_step_marks import read_fields, BT_SIZE, MESG_RECORD, MESG_LAP  # noqa: E402

# Assembled so this file's own format example is not scanned as data.
MARK = "STEP" + "FIELDS"

LINE_RE = re.compile(
    MARK + r"\s+descs=(?P<descs>\d+)\s+rec_bytes=(?P<rec>\d+)\s+"
    r"lap_bytes=(?P<lap>\d+)\s+total_fields=(?P<total>\d+)")

STEP_HANDLES = ("mFitStepType", "mFitIvlNum", "mFitLapStep", "mFitLapIvl")

# The two mode flags whose branches this block must stay OUT of. Named
# explicitly rather than "any identifier beginning with m": the block IS inside
# `if (mSession == null)`, which is a lifecycle test and not a mode test.
MODE_FLAGS = ("mWorkoutEnabled", "mErgMode")

# Matched against the COMMENT-STRIPPED text, where strip_comments has blanked
# the field NAME to an empty literal -- so the handle is what identifies a call
# here, and the names come from read_fields, which parses the raw source. Two
# readings of the same calls, and they have to agree on the four step marks or
# read_fields fails closed.
CREATE_RE = re.compile(
    r"(?P<handle>\bm[A-Za-z0-9_]*)\s*=\s*mSession\.createField\(\s*"
    r'"[^"]*"\s*,\s*(?P<id>\d+)\s*,')

# The tick's pair write, normalised: comments stripped, whitespace collapsed.
# Both inputs of BOTH fields are read into locals ABOVE the first setData, so
# the pair cannot straddle a state change however the block is later rearranged.
PINNED_PAIR = (
    "var stepT = curStepType(); var setN = mSetNum; var wEn = mWorkoutEnabled; "
    "var sted = mStarted; if (mFitStepType != null) { "
    "mFitStepType.setData(stepTypeCode(stepT, wEn, sted)); } "
    "if (mFitIvlNum != null) { "
    "mFitIvlNum.setData(intervalNumOf(wEn, sted, setN)); }")

PAIR_RE = re.compile(
    r"var stepT = curStepType\(\);"
    r".*?mFitIvlNum\.setData\([^;]*\);\s*\}", re.S)


def read_source(root):
    path = os.path.join(root, "source", "StrongRowView.mc")
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read(), path


def normalise(body):
    return re.sub(r"\s+", " ", body).strip()


def enclosing_headers(stripped, target):
    """The control-flow headers of every `{` still open at `target`.

    A header is the text between the previous statement boundary and the brace
    -- `if (mSession == null)`, `try`, `hidden function startSession()`. The
    walk is over COMMENT- AND STRING-STRIPPED text, so a brace inside either
    cannot desynchronise it.
    """
    stack = []
    for i, c in enumerate(stripped[:target]):
        if c == "{":
            j = i - 1
            while j >= 0 and stripped[j] not in ";{}":
                j -= 1
            stack.append(normalise(stripped[j + 1:i]))
        elif c == "}":
            if stack:
                stack.pop()
    return stack


def check_creation(stripped, path, problems):
    """Every createField call, its id, and where the step-mark block sits."""
    calls = list(CREATE_RE.finditer(stripped))
    if not calls:
        problems.append(
            "%s: no `mSession.createField(\"name\", id, ...)` call found at "
            "all. This check derives every figure from those calls and will "
            "not report a vacuous pass." % path)
        return None, None

    ids = {}
    for m in calls:
        fid = int(m.group("id"))
        ids.setdefault(fid, []).append(m.group("handle"))
    for fid in sorted(ids):
        if len(ids[fid]) > 1:
            problems.append(
                "%s: developer field id %d is created twice, for %s. An id is "
                "unique per field_description -- that is exactly why the lap "
                "copies could not reuse 17 and 18 -- so a collision re-labels "
                "one of them in every file written from here on."
                % (path, fid, " and ".join(sorted(ids[fid]))))

    step_calls = [m for m in calls if m.group("handle") in STEP_HANDLES]
    missing = set(STEP_HANDLES) - {m.group("handle") for m in step_calls}
    if missing:
        problems.append(
            "%s: no createField assigns %s. This check cannot report the cost "
            "of a field the app does not create."
            % (path, ", ".join(sorted(missing))))
        return None, len(calls)

    first = min(m.start() for m in step_calls)
    for header in enclosing_headers(stripped, first):
        for flag in MODE_FLAGS:
            if re.search(r"\b%s\b" % flag, header):
                problems.append(
                    "%s: the step-mark createField block sits inside `%s`. It "
                    "must NOT be gated on a mode flag: a free row records "
                    "step_type = SFIT_NONE on every record precisely so a "
                    "consumer can tell a free row from a workout row FROM THE "
                    "FILE, and no (:test) can obtain a Session, so gating "
                    "creation is the one edit here the suite cannot see."
                    % (path, header))
    return len(step_calls), len(calls)


def check_pair(stripped, path, problems):
    m = PAIR_RE.search(stripped)
    if not m:
        problems.append(
            "%s: the tick's step-mark pair write was not found. It is mirrored "
            "in this check because the comment beside it states a property of "
            "the hoist; a mirror of something that is not there checks "
            "nothing." % path)
        return
    got = normalise(m.group(0))
    if got != PINNED_PAIR:
        problems.append(
            "%s: the tick's step-mark pair write has changed.\n"
            "    shipped: %s\n    mirrored: %s\n"
            "  Both fields must take EVERY input from a local read above the "
            "first setData -- the comment there claims exactly that, and "
            "adjacency is a weaker guarantee than the one it names. Re-read "
            "that note, then update PINNED_PAIR in this file in the same "
            "commit." % (path, got, PINNED_PAIR))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    args = ap.parse_args()

    problems = []
    text, path = read_source(args.root)
    stripped = strip_comments(text)

    descs, total = check_creation(stripped, path, problems)
    check_pair(stripped, path, problems)

    rec_bytes = lap_bytes = None
    try:
        fields = read_fields(args.root)
        rec_bytes = sum(BT_SIZE[f["base_type"]]
                        for f in fields if f["mesg"] == MESG_RECORD)
        lap_bytes = sum(BT_SIZE[f["base_type"]]
                        for f in fields if f["mesg"] == MESG_LAP)
    except SystemExit as exc:
        # read_fields fails closed with its own message; carry it rather than
        # exiting straight out, so every other problem is reported in one pass.
        problems.append(str(exc))

    m = LINE_RE.search(text)
    if not m:
        problems.append(
            "%s carries no %s line. The free-row cost paragraph states a field "
            "count and a per-record byte figure; unchecked, those are the same "
            "kind of asserted number that made it say 'two' where the code "
            "creates four." % (path, MARK))
    elif None not in (descs, total, rec_bytes, lap_bytes):
        got = (descs, rec_bytes, lap_bytes, total)
        want = (int(m.group("descs")), int(m.group("rec")),
                int(m.group("lap")), int(m.group("total")))
        names = ("descs", "rec_bytes", "lap_bytes", "total_fields")
        for i in range(4):
            if got[i] != want[i]:
                problems.append(
                    "%s says %s=%d; the code gives %d"
                    % (MARK, names[i], want[i], got[i]))

    if problems:
        print("FAIL: %d problem(s) in the %s derivation." % (len(problems), MARK))
        for p in problems:
            print("  - %s" % p)
        return 1

    print("OK: %s agrees with the code -- %d step-mark field_description(s), "
          "%d byte(s) per record and %d per lap, %d developer field(s) in the "
          "file with no id collision, creation ungated, pair write hoisted."
          % (MARK, descs, rec_bytes, lap_bytes, total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
