#!/usr/bin/env python3
"""Fail-closed check that every test named in a source/ comment actually exists.

WHY THIS EXISTS. source/CoreTempSensor.mc carried, for the life of a branch,

    // searchTimeoutLowPriority counts units of 2.5 s, so the pair is
    // nailed together by test_cr_c1_theSearchWindowIsTheOneTheRadioIsTold

and no such (:test) function was ever written. `git log -S` shows the name
entering on a single added line -- the comment itself -- as a forward reference
to a case that landed later under a different name. Three reviewers found it
independently. Nothing automated could: scripts/check_expected_tests.sh scopes
itself to pin-vs-source drift, and a comment is stripped from the build, so the
compiler will never object either.

The cost is not academic. These comments are the file's evidence that a claim is
guarded rather than asserted, and this repository's dominant defect class is a
claim stronger than the thing that supports it. A maintainer who greps a named
guard, finds nothing, and concludes the property is unpinned then either
duplicates a live assertion or edits the constant believing nothing stands in
front of it. In this instance the property WAS pinned, by
CoreRel.test_cr_c1_theDutyArithmeticIsTheOneStatedHere, so the whole cost was
misplaced trust -- which is exactly the cost this check removes.

WHAT IT DOES. Scan every .mc file under source/ for tokens matching

    [Module.]test_<identifier>

and require each to name a (:test) function that the extractor can see. The
extractor is scripts/list_tests.py, IMPORTED rather than re-implemented: a
second scanner would drift from the first, and this repository already records
what a re-implemented rule costs. A reference may be written bare
(`test_cr_c1_...`) or module-qualified the way the simulator's RESULTS table
prints it (`CoreRel.test_cr_c1_...`); a qualified reference must name the module
the declaration is actually in.

THREE THINGS ARE DELIBERATELY NOT ERRORS:

  * a token ending in `_`, e.g. `test_cr_`. That is a prefix used as an
    ellipsis in prose ("the test_cr_ cases"), not a name, and six such spellings
    exist across source/ today.
  * a token naming a Python suite in scripts/, e.g. `test_cue_replay` for
    scripts/test_cue_replay.py. Those references are real and resolve to files,
    not to (:test) functions.
  * a name repeated inside a string literal. String bodies are NOT excluded --
    a logger.error() that names a test is a cross-reference like any other and
    should resolve like one.

WHAT IT CANNOT CHECK, stated so nothing more is read into a green run. It
verifies that a named test EXISTS, never that the target asserts what the
pointer claims of it; that stays a reading job. It says nothing about figures
quoted in comments, which is the other half of the drift this round found and
which no textual check can settle. And its scope is source/ only: scripts/ is
excluded because scripts/list_tests.py and scripts/check_ciq_tests.py carry
illustrative names in their docstrings on purpose (`M.test_foo`,
`ZzpA.test_zzp_oneDeep` -- a probe that was compiled once and never committed),
and rejecting those would be rejecting accurate documentation. That is a known
hole, not an oversight.

Usage:
  check_source_refs.py [--root DIR]

Exit 0 = every reference resolves, 1 = at least one does not, printed with
file:line and the token.
"""

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import list_tests   # noqa: E402  -- the ONE extractor, imported not copied

# `Module.` prefix optional; the name itself must start with the repository's
# test_ convention, which is also what scripts/check_ciq_tests.py keys on.
REF_RE = re.compile(r'\b(?:(?P<mod>[A-Za-z_][A-Za-z0-9_]*)\.)?'
                    r'(?P<name>test_[A-Za-z0-9_]+)')


def declared_names(root):
    """{bare name -> set of qualified names} for every (:test) under `root`."""
    by_bare = {}
    for path in list_tests.mc_files(root):
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            stripped = list_tests.strip_comments(fh.read())
        for _offset, qualified in list_tests.qualified_decls(stripped):
            by_bare.setdefault(qualified.split(".")[-1], set()).add(qualified)
    return by_bare


def python_suites(scripts_dir):
    """Bare names of the scripts/test_*.py suites, which are legitimate targets."""
    try:
        entries = os.listdir(scripts_dir)
    except OSError:
        return set()
    return {f[:-3] for f in entries
            if f.startswith("test_") and f.endswith(".py")}


def unresolved(root, scripts_dir):
    """Yield (path, line, token, why) for every reference that does not resolve."""
    by_bare = declared_names(root)
    suites = python_suites(scripts_dir)
    for path in list_tests.mc_files(root):
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for lineno, line in enumerate(fh, 1):
                for m in REF_RE.finditer(line):
                    name = m.group("name")
                    mod = m.group("mod")
                    token = ("%s.%s" % (mod, name)) if mod else name
                    if name.endswith("_"):
                        continue          # a prefix used as an ellipsis
                    if mod is None and name in suites:
                        continue          # scripts/<name>.py
                    quals = by_bare.get(name)
                    if not quals:
                        yield (path, lineno, token,
                               "no (:test) function of that name exists under " + root)
                        continue
                    if mod is not None and token not in quals:
                        yield (path, lineno, token,
                               "declared as " + " / ".join(sorted(quals)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="source")
    args = ap.parse_args()
    scripts_dir = os.path.dirname(os.path.abspath(__file__))

    bad = list(unresolved(args.root, scripts_dir))
    if bad:
        for path, lineno, token, why in bad:
            print("%s:%d: %s -- %s" % (path, lineno, token, why))
        print("")
        print("%d unresolved test cross-reference(s) in %s/." % (len(bad), args.root))
        print("A comment that names a guard which does not exist is a claim "
              "stronger than its evidence.")
        print("Point it at the case that actually holds the assertion, or write "
              "the case (and pin it in scripts/expected_tests.txt).")
        return 1

    total = sum(len(v) for v in declared_names(args.root).values())
    print("OK: every test cross-reference in %s/ resolves (%d (:test) function(s) "
          "declared)." % (args.root, total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
