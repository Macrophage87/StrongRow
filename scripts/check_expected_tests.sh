#!/usr/bin/env bash
# Cross-check scripts/expected_tests.txt against the (:test) functions that
# actually exist in source/*.mc.
#
# WHY THIS EXISTS
#   expected_tests.txt pins the test NAMES that run-tests requires the simulator
#   to report, and the expected COUNT is simply that list's length -- so the two
#   can never disagree with each other. That closes substitution, but on its own
#   it is pinned to a file the same commit may freely edit: delete a (:test)
#   function AND its pin line together and CI stays fully green while coverage
#   silently shrinks. Nothing would notice.
#
#   This is the same cross-check manifest-lint already applies to
#   list_devices.sh vs a real XML parse, for the same reason: a derived list and
#   its source must not be able to drift quietly.
#
# Fail-closed: an empty extraction (source/ moved, declaration syntax changed)
# is a failure, never a vacuous green match of two empty lists.
#
# Runs on a stock runner -- no container, no SDK. Exit 0 = in sync, 1 = drift.
set -euo pipefail

cd "$(dirname "$0")/.."

PIN="scripts/expected_tests.txt"

# The declaration form used throughout this codebase, e.g.
#   (:test) function test_rr_oneValid(logger) as Boolean {
from_source="$(grep -rhoE '^\(:test\) function [a-zA-Z0-9_]+' source/*.mc \
               | sed 's/.*function //' | sort)"
from_pin="$(grep -vE '^\s*(#|$)' "$PIN" | sort)"

n_source="$(printf '%s\n' "$from_source" | grep -c . || true)"
n_pin="$(printf '%s\n' "$from_pin" | grep -c . || true)"

if [ "$n_source" -eq 0 ]; then
    echo "::error::no (:test) functions found in source/*.mc -- the extractor or"
    echo "::error::the declaration syntax changed; refusing to pass green."
    exit 1
fi
if [ "$n_pin" -eq 0 ]; then
    echo "::error::$PIN lists no test names -- a zero pin can never gate anything."
    exit 1
fi

if ! diff -u <(printf '%s\n' "$from_pin") <(printf '%s\n' "$from_source") \
        --label "$PIN (pinned)" --label "source/*.mc (actual)"; then
    echo "::error::$PIN has drifted from the (:test) functions in source/*.mc."
    echo "::error::Lines prefixed '-' are pinned but no longer declared;"
    echo "::error::lines prefixed '+' are declared but not pinned."
    echo "::error::Update $PIN in the SAME commit as any (:test) change."
    exit 1
fi

echo "OK: $n_source (:test) function(s) in source/*.mc match $PIN exactly."
