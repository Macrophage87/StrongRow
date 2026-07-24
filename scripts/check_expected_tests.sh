#!/usr/bin/env bash
# Cross-check scripts/expected_tests.txt against the (:test) functions that
# actually exist in the Monkey C sources.
#
# WHAT THIS DOES AND DOES NOT BUY  -- read before trusting it
#
#   It closes DRIFT: the pin and the sources disagreeing. That is worth having,
#   and it is what makes a stale pin a loud failure instead of a confusing
#   parser diagnostic.
#
#   It does NOT close SHRINKAGE. Both sides are derived from files the SAME
#   commit may edit, so a coordinated deletion -- drop a (:test) function AND
#   its pin line together -- shrinks both lists identically, the diff is empty,
#   and this exits 0. Measured: deleting 5 of 17 tests with their pin lines
#   leaves this printing "OK: 12 ... match ... exactly", rc=0. Catching that
#   needs an anchor OUTSIDE the commit (a merge-base count or a ratcheting
#   floor) -- tracked in #52, not implemented. What does catch it today is a
#   human reading the diff, which shows both deletions.
#
# Extraction is scripts/list_tests.py: comment-aware (a /* */-commented
# declaration is not a test) and form-aware (indented, own-line and
# multi-annotation declarations ARE tests -- the simulator runs them, so an
# extractor blind to them deadlocks this check against check_ciq_tests.py).
#
# Fail-closed: an empty extraction is a failure, never a vacuous green match of
# two empty lists. Runs on a stock runner -- no container, no SDK.
set -euo pipefail

cd "$(dirname "$0")/.."

PIN="scripts/expected_tests.txt"

# `|| true` is load-bearing on every substitution below: grep exits 1 on no
# match and pipefail propagates it, so without this `set -e` kills the script
# AT THE ASSIGNMENT and the diagnostics never print -- a red step with a blank
# log, reproduced in review.
from_source="$(python3 scripts/list_tests.py | sort || true)"
# Trim surrounding ASCII whitespace to match load_expected() in
# check_ciq_tests.py (which strips exactly " \t\r\n" for the same reason).
# Without this a pin line with a trailing space reds here with a diff whose two
# sides look identical on screen, while the parser passes.
from_pin="$(grep -vE '^[[:space:]]*(#|$)' "$PIN" \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort || true)"

n_source="$(printf '%s\n' "$from_source" | grep -c . || true)"
n_pin="$(printf '%s\n' "$from_pin" | grep -c . || true)"

if [ "$n_source" -eq 0 ]; then
    echo "::error::no (:test) functions found under source/ -- the extractor or"
    echo "::error::the declaration syntax changed; refusing to pass green."
    exit 1
fi
if [ "$n_pin" -eq 0 ]; then
    echo "::error::$PIN lists no test names -- a zero pin can never gate anything."
    exit 1
fi

if ! diff -u <(printf '%s\n' "$from_pin") <(printf '%s\n' "$from_source") \
        --label "$PIN (pinned)" --label "source/**.mc (actual)"; then
    echo "::error::$PIN has drifted from the (:test) functions under source/."
    echo "::error::Lines prefixed '-' are pinned but no longer declared;"
    echo "::error::lines prefixed '+' are declared but not pinned."
    echo "::error::Declaration locations:"
    python3 scripts/list_tests.py --where | sed 's/^/::error::  /' || true
    echo "::error::Update $PIN in the SAME commit as any (:test) change."
    exit 1
fi

echo "OK: $n_source (:test) function(s) under source/ match $PIN exactly."
