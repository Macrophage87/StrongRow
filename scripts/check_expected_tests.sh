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
#   It does NOT close SHRINKAGE, and an earlier version of this header claimed
#   it did. Both sides are derived from files the SAME commit may edit, so a
#   coordinated deletion -- drop a (:test) function AND its pin line together --
#   shrinks both lists identically, the diff is empty, and this exits 0.
#   Measured: deleting 5 of 17 tests with their pin lines leaves this script
#   printing "OK: 12 ... match ... exactly" and check_ciq_tests.py printing
#   "OK: 12/12", both rc=0.
#
#   Catching that needs an anchor OUTSIDE the commit -- a count compared against
#   git merge-base, or a floor that only ratchets upward. That is not
#   implemented here; see the follow-up issue referenced in docs/CI.md. What
#   does catch it today is a human reading the diff, which shows both deletions.
#
# Fail-closed: an empty extraction (sources moved, declaration syntax changed)
# is a failure, never a vacuous green match of two empty lists.
#
# Runs on a stock runner -- no container, no SDK. Exit 0 = in sync, 1 = drift.
set -euo pipefail

cd "$(dirname "$0")/.."

PIN="scripts/expected_tests.txt"

# Recurse: `source/*.mc` would silently ignore any test placed in a
# subdirectory, and monkey.jungle does not restrict the source tree either.
mapfile -t MC_FILES < <(find source -name '*.mc' -type f | sort)
if [ "${#MC_FILES[@]}" -eq 0 ]; then
    echo "::error::no .mc files found under source/ -- refusing to pass green."
    exit 1
fi

# The declaration form used throughout this codebase, e.g.
#   (:test) function test_rr_oneValid(logger) as Boolean {
#
# `|| true` on BOTH substitutions is load-bearing: grep exits 1 on no match and
# `set -o pipefail` propagates it, so without this `set -e` kills the script AT
# THE ASSIGNMENT and the zero-match guards below never print. That produced a
# red step with a completely blank log -- a silent failure on a required check,
# which is precisely what this job exists to prevent.
from_source="$(grep -hoE '^\(:test\) function [a-zA-Z0-9_]+' "${MC_FILES[@]}" \
               | sed 's/.*function //' | sort || true)"
# Trim surrounding whitespace to match load_expected() in check_ciq_tests.py,
# which strip()s every pin line. Without this the two disagree about a pin file
# with a trailing space: the parser passes while this diff reds with two sides
# that look identical on screen -- a false red with an invisible cause.
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

# Declarations the column-0 extractor cannot see (indented, or the annotation on
# its own line) are still COMPILED AND RUN by the simulator. Left undetected they
# deadlock CI: unpinned, the parser reds with "unexpected tests"; pinned, the
# diff below reds with "pinned but no longer declared" -- and no edit to the pin
# makes both green. Name them here instead, so the fix is obvious.
missed="$(grep -hnE '^[[:space:]]+\(:test\)[[:space:]]+function' "${MC_FILES[@]}" || true)"
if [ -n "$missed" ]; then
    echo "::error::(:test) declaration(s) are indented, so the column-0 extractor"
    echo "::error::cannot see them -- but the simulator still runs them, which"
    echo "::error::deadlocks this check against check_ciq_tests.py."
    printf '%s\n' "$missed" | sed 's/^/::error::  /'
    echo "::error::Move each declaration to column 0."
    exit 1
fi

if ! diff -u <(printf '%s\n' "$from_pin") <(printf '%s\n' "$from_source") \
        --label "$PIN (pinned)" --label "source/**.mc (actual)"; then
    echo "::error::$PIN has drifted from the (:test) functions under source/."
    echo "::error::Lines prefixed '-' are pinned but no longer declared;"
    echo "::error::lines prefixed '+' are declared but not pinned."
    echo "::error::Update $PIN in the SAME commit as any (:test) change."
    exit 1
fi

echo "OK: $n_source (:test) function(s) under source/ match $PIN exactly."
