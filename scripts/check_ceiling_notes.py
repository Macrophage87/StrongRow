#!/usr/bin/env python3
"""Fail-closed arithmetic check on the repository's `globals` CEILING notes.

WHY THIS EXISTS. monkeyc caps module `globals` at 253 members on the fenix6
family, and it prints the count only once the build is ALREADY over -- so the
number can only be learned by bisecting throwaway declarations against a real
compile. That makes the note recording it a MEASUREMENT, and this repository
kept two copies of it (scripts/list_tests.py and source/FootStateTest.mc). Both
copies carried the correct figure "252 of 253, one slot" and then drew the
wrong consequence from it in the next clause -- "so the next (:test) added
anywhere at file scope red the check". The limit is INCLUSIVE: at 252 the next
one lands on 253 and BUILDS (measured on fenix6, fenix6pro, fenix6spro and
fenix6xpro), and it is the SECOND that reds. Seven review findings across two
rounds were spent on that one word, because prose has no arithmetic and two
copies of prose have no agreement.

So the consequence is no longer left to prose. Every ceiling note carries one
machine-readable line, and this check enforces what prose cannot:

  * used + free == limit                     -- the slot arithmetic closes
  * the "Nth reds" ordinal == free + 1       -- the INCLUSIVE-limit consequence,
                                                which is the clause that was
                                                wrong in both copies
  * the ordinal SUFFIX matches its number    -- 2nd, 16th, not 2th
  * copies sharing an anchor are IDENTICAL   -- the anti-drift half: correcting
                                                one copy and not the other now
                                                fails here instead of shipping
  * at least one note exists                 -- deleting the markers must not
                                                silently disable this check

THE LINE FORMAT (anywhere in any text file, behind // or # or bare):

    <MARKER> <anchor> <family>: <used> used of <limit>, <free> free -- the <N>th file-scope (:test) added reds

where <MARKER> is the literal word this module's CEILING_WORD holds, <anchor>
is any whitespace-free label naming WHAT was measured (a commit sha, or a name
like `post-move`), and <family> names the device family the count is for.

WHAT THIS CANNOT CHECK, stated so nobody reads more into a green run. It does
not compile anything: it cannot tell you whether 252 was ever the true count,
only that the note's own arithmetic closes and that the copies agree. The
figures still have to be re-measured by bisection when the tree changes, and a
note that is internally consistent but stale passes here. It also only sees
notes that carry the marker: source/SetGridLayoutTest.mc holds an older,
unmarked member-count table measured against a pre-2b23b03 tree, which this
check does not read -- a known, deliberate hole, filed as #147.

Usage:
  check_ceiling_notes.py [--root DIR]

Exit 0 = every note is coherent and the copies agree, 1 = a problem, printed
with file:line and the arithmetic that failed.
"""

import argparse
import os
import re
import sys

# Assembled rather than written literally so this file's own format example and
# error strings are not themselves scanned as notes. The scan skips this file
# and its test suite by path anyway; this makes the intent obvious at the point
# it matters instead of relying on the skip list being right.
CEILING_WORD = "CEI" + "LING"

NOTE_RE = re.compile(
    CEILING_WORD + r"\s+(?P<anchor>\S+)\s+(?P<family>[^:]+):\s+"
    r"(?P<used>\d+)\s+used\s+of\s+(?P<limit>\d+),\s+"
    r"(?P<free>\d+)\s+free\s+--\s+the\s+"
    r"(?P<nth>\d+)(?P<suffix>st|nd|rd|th)\s+"
    r"file-scope\s+\(:test\)\s+added\s+reds"
)

TEXT_EXTS = {".mc", ".py", ".md", ".sh", ".yml", ".yaml", ".txt", ".xml",
             ".jungle", ".json"}

# Build output and dependency trees, plus EVERY dot-directory. The dot rule is
# load-bearing rather than tidiness: a checkout can carry additional working
# copies of this same repository underneath a dot-directory, and scanning those
# would find a second, older copy of every note and report drift that does not
# exist in the tree being checked. No note is expected to live in a
# dot-directory, so the rule costs nothing.
SKIP_DIRS = {"bin", "gen", "node_modules", "__pycache__"}


def skipped_dir(name):
    return name.startswith(".") or name in SKIP_DIRS

SELF = os.path.abspath(__file__)
SELF_TEST = os.path.join(os.path.dirname(SELF), "test_check_ceiling_notes.py")


def ordinal_suffix(n):
    if 10 <= (n % 100) <= 20:
        return "th"
    return {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")


def ordinal(n):
    return "%d%s" % (n, ordinal_suffix(n))


def scan(root):
    """Yield (path, lineno, match, raw_line) for every marked note under root."""
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if not skipped_dir(d))
        for f in sorted(files):
            if os.path.splitext(f)[1] not in TEXT_EXTS:
                continue
            path = os.path.join(dirpath, f)
            if os.path.abspath(path) in (SELF, SELF_TEST):
                continue                      # this checker and its own suite
            if not os.path.isfile(path) or os.path.islink(path):
                continue
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for i, line in enumerate(fh, 1):
                    m = NOTE_RE.search(line)
                    if m:
                        yield path, i, m, line.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    args = ap.parse_args()

    notes = list(scan(args.root))
    problems = []

    for path, lineno, m, raw in notes:
        used, limit = int(m.group("used")), int(m.group("limit"))
        free, nth = int(m.group("free")), int(m.group("nth"))
        where = "%s:%d" % (path, lineno)
        if used + free != limit:
            problems.append(
                "%s: %d used + %d free = %d, but the limit is %d -- the slot "
                "arithmetic does not close" % (where, used, free,
                                               used + free, limit))
        if nth != free + 1:
            problems.append(
                "%s: %d free, so the %s added file-scope (:test) still BUILDS "
                "(the limit is inclusive) and the %s is the first that reds -- "
                "the note says the %s" % (where, free, ordinal(free),
                                          ordinal(free + 1), ordinal(nth)))
        want = ordinal_suffix(nth)
        if m.group("suffix") != want:
            problems.append(
                "%s: %d%s should be written %d%s"
                % (where, nth, m.group("suffix"), nth, want))

    # Anti-drift: two notes measuring the same thing must say the same thing.
    by_anchor = {}
    for path, lineno, m, raw in notes:
        key = (m.group("anchor"), m.group("family").strip())
        by_anchor.setdefault(key, []).append((path, lineno, m.group(0)))
    for key, group in sorted(by_anchor.items()):
        texts = {g[2] for g in group}
        if len(texts) > 1:
            problems.append(
                "copies of the %s %s note disagree -- correcting one copy and "
                "not the other is the drift this check exists to stop:\n%s"
                % (key[0], key[1],
                   "\n".join("    %s:%d  %s" % g for g in sorted(group))))

    if not notes:
        problems.append(
            "no %s note found under %r. This check is only worth its runtime "
            "while at least one note carries the marker; an empty scan means "
            "the notes were deleted or the marker was renamed, either of which "
            "silently disables it." % (CEILING_WORD, args.root))

    if problems:
        print("FAIL: %d problem(s) in the %s notes."
              % (len(problems), CEILING_WORD))
        for p in problems:
            print("  - %s" % p)
        return 1

    print("OK: %d %s note line(s), arithmetic closed, copies agree."
          % (len(notes), CEILING_WORD))
    for path, lineno, m, raw in notes:
        print("  %s:%d  %s" % (path, lineno, m.group(0)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
