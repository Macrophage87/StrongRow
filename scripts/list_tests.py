#!/usr/bin/env python3
"""List the (:test) function names declared under source/, comment-aware.

This replaces a column-0 `grep` whose blind spots were measured one by one:
an indented declaration, the annotation on its own line, a multi-annotation
form like `(:debug, :test)`, and extra spaces were all INVISIBLE to it -- while
the simulator still compiles and runs every one of them. An invisible-but-run
declaration deadlocks CI: unpinned, the parser reds with "unexpected tests";
pinned, the pin cross-check reds with "no longer declared"; and no edit to the
pin file makes both green. Conversely, a declaration inside a /* */ block
comment is NOT run, and the old guard false-red'd on it -- with a printed
remedy that would have promoted commented-out code into a phantom pinned test.

So: strip // and /* */ comments first (string literals respected), then match
any `(: ... )` annotation group containing the token `test`, followed by
`function <name>` -- across newlines, at any indent, with any annotation
spelling. That is deliberately broader than the style the codebase uses today;
style enforcement is not this script's job, correctness of the pin is.

Usage:
  list_tests.py            -> names, one per line, in file/position order
  list_tests.py --where    -> "path:line:name" instead (for diagnostics)

Exit 0 always (an empty result is the CALLER's fail-closed decision to make,
with its own message -- this script just reports what exists).
"""

import argparse
import os
import re
import sys

# An annotation group containing :test (alone or among others, any order),
# then `function <identifier>`. No re.S: the pattern contains no `.` -- \s and
# the annotation-body classes match newlines on their own, and THAT is what
# lets the annotation sit on its own line above the function. (An earlier
# version passed re.S anyway and credited it with the cross-line behaviour;
# it was dead code and a misattribution, found in review.)
#
# The annotation body admits ONE level of balanced parens -- `[^()]` with an
# optional `\([^()]*\)` -- because annotations take arguments:
# `(:test, :typecheck(false))` is legal Monkey C, and the previous `[^)]*`
# body died at the `)` closing `typecheck(false`, making that declaration
# invisible to the pin while the simulator still ran it (the deadlock this
# script exists to prevent, reintroduced through its own regex). One level,
# not a depth counter: two-level nesting has no known legal Monkey C form. If
# one ever appears it is loud, not silent -- pinned, the cross-check reds on
# a name "no longer declared"; unpinned, run-tests reds on "unexpected
# tests" -- and this is the comment to widen when that happens.
_ANN_BODY = r'(?:[^()]|\([^()]*\))*'
_DECL_SRC = (r'\(\s*:' + _ANN_BODY + r'\btest\b' + _ANN_BODY +
             r'\)\s*function\s+(?P<dname>[A-Za-z_][A-Za-z0-9_]*)')
DECL_RE = re.compile(_DECL_SRC)

# MODULE SCOPE, and why the extractor has to care.
#
# A (:test) declared inside `module M { ... }` is compiled and RUN exactly like
# one at file scope -- but the simulator's RESULTS table names it `M.test_foo`,
# not `test_foo`. So an extractor that reported the bare name would pin a name
# the runner never prints, and check_ciq_tests.py would red with "expected but
# missing" AND "unexpected" for the same test. That is the same unfixable
# deadlock the module docstring above describes, reached from a new direction.
#
# DEPTH IS MEASURED, not extrapolated. The dotted path was first confirmed at
# ONE level only, and the two-level expectation was then asserted from it. On
# fr965 / SDK 9.2.0 a throwaway probe carrying one (:test) at file scope and one
# at each of three depths printed
#
#     test_zzp_atFileScope                                 PASS
#     ZzpA.test_zzp_oneDeep                                PASS
#     ZzpA.ZzpB.test_zzp_twoDeep                           PASS
#     ZzpA.ZzpB.ZzpC.test_zzp_threeDeep                    PASS
#
# so the FULL path, every segment, at every depth, is what the runner prints --
# which is what the brace walk below builds. Pinned in test_list_tests.py by
# "three module levels qualify with the whole path".
#
# WHY ANY OF THIS MATTERS RATHER THAN BEING A STYLE OPTION. MEASURED, SDK 9.2.0:
# a --unit-test build of this repository for the fenix6 family (fenix6, 6pro,
# 6spro, 6xpro) fails with
#
#     Found N members in module 'globals', exceeding the limit of 253
#
# Every file-scope (:test), helper function and test class costs one member; a
# module-scope const costs none (it is inlined); a `module { }` block costs one,
# and everything declared inside it leaves 'globals' entirely.
#
# The count is only printed once it is ALREADY over, so it has to be probed:
# drop N throwaway file-scope (:test) functions into source/, compile for
# fenix6 --unit-test, and read N back out of the reported total. Measured that
# way, and both figures are of the whole repository, not of one file. The two
# lines below are the machine-readable form scripts/check_ceiling_notes.py
# checks -- its arithmetic, and that source/FootStateTest.mc's copies of them
# are identical, so the two records can no longer drift apart:
#
#     CEILING 2b23b03 fenix6-family: 252 used of 253, 1 free -- the 1st file-scope (:test) added reds
#     CEILING post-move fenix6-family: 238 used of 253, 15 free -- the 16th file-scope (:test) added reds
#
# (`2b23b03` is main before this work; `post-move` is this branch with
# FootStateTest inside `module Foot`.)
#
# At 252 the next (:test) added anywhere at file scope red the required
# compile-unit-test check on four devices with an error naming neither the test
# nor the file, while fr965 (which run-tests uses) and release-build stayed
# green -- so a green local run proved nothing. Tests inside a module cost ONE
# member between them, which is what makes further testing possible on those
# four devices at all.
#
# The scanner is deliberately crude: a balanced-brace walk over the
# comment-stripped, literal-blanked text. `module NAME {` pushes NAME, any other
# `{` pushes an anonymous frame, `}` pops. Dictionary literals and function
# bodies therefore push and pop harmlessly, and a `{` inside a string or comment
# cannot be seen at all because strip_comments has already blanked it.
#
# `class` is NOT treated as a named scope. A (:test) inside a class is not a
# form the runner supports, so guessing at the name it would print would be
# inventing an answer; left anonymous, such a declaration surfaces as ordinary
# pin drift rather than silently.
_SCOPE_RE = re.compile(
    r'(?P<mod>\bmodule\s+(?P<mname>[A-Za-z_][A-Za-z0-9_]*))'
    r'|(?P<open>\{)'
    r'|(?P<close>\})'
    r'|(?P<decl>' + _DECL_SRC + r')'
)


def qualified_decls(stripped):
    """Yield (offset, qualified_name) for every (:test) declaration, prefixing
    the enclosing module path the way the simulator's RESULTS table does."""
    stack = []       # innermost last; None for an anonymous brace frame
    pending = None   # a module name whose `{` has not arrived yet
    for m in _SCOPE_RE.finditer(stripped):
        if m.group('mod') is not None:
            pending = m.group('mname')
        elif m.group('open') is not None:
            stack.append(pending)
            pending = None
        elif m.group('close') is not None:
            if stack:
                stack.pop()
        else:
            path = [s for s in stack if s is not None]
            name = m.group('dname')
            yield m.start(), (".".join(path + [name]) if path else name)


def strip_comments(text):
    """Remove // and /* */ comments AND blank out string/Char literal BODIES,
    keeping delimiters and newlines (so line numbers survive for --where).

    Blanking literal bodies matters twice over:
      * a string containing the annotation text would otherwise be extracted as
        a phantom pinned test, and the drift diff's printed remedy would walk a
        maintainer straight into pinning it;
      * a Char literal like '"' would otherwise desynchronise the string lexer,
        turning comment-stripping off for the rest of the file and resurrecting
        commented-out declarations."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"' or c == "'":                  # string or Char literal
            quote = c
            out.append(c); i += 1
            while i < n and text[i] != quote:
                if text[i] == '\\' and i + 1 < n:
                    if text[i + 1] == '\n':
                        out.append('\n')          # an escaped NEWLINE still ends
                    i += 2                        # a line: swallowing it shifted
                    continue                      # every later --where line by one
                if text[i] == '\n':
                    out.append('\n')              # keep line numbers
                i += 1
            if i < n:
                out.append(quote); i += 1
        elif text.startswith('//', i):            # line comment
            while i < n and text[i] != '\n':
                i += 1
        elif text.startswith('/*', i):            # block comment
            end = text.find('*/', i + 2)
            end = n if end == -1 else end + 2
            out.append('\n' * text.count('\n', i, end))   # keep line numbers
            i = end
        else:
            out.append(c); i += 1
    return ''.join(out)


def mc_files(root="source"):
    # No followlinks: it bought nothing (the tree has no symlinks) and cost
    # termination -- a directory-symlink cycle loops forever, in a job that runs
    # on every PR. Symlinked files are skipped too, and that is a TRADEOFF, not
    # a free win: a link pointing INSIDE source/ would duplicate a name into an
    # unfixable drift diff (the case the skip serves), but a link pointing
    # OUTSIDE source/ holds a declaration the compiler builds and the simulator
    # runs while this extractor cannot see it -- accepted while no symlink of
    # either kind exists, and pinned by the extractor suite either way.
    # Anything that is not a regular file is skipped too (a FIFO named *.mc
    # would block open() indefinitely).
    hits = []
    for dirpath, _dirs, files in os.walk(root):
        for f in sorted(files):
            p = os.path.join(dirpath, f)
            if f.endswith(".mc") and os.path.isfile(p) and not os.path.islink(p):
                hits.append(p)
    return sorted(hits)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--where", action="store_true",
                    help="print path:line:name instead of bare names")
    ap.add_argument("--root", default="source")
    args = ap.parse_args()

    for path in mc_files(args.root):
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
        stripped = strip_comments(raw)
        for offset, name in qualified_decls(stripped):
            line = stripped.count("\n", 0, offset) + 1
            if args.where:
                print("%s:%d:%s" % (path, line, name))
            else:
                print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
