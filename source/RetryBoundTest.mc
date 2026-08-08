using Toybox.Test;

// The CORE channel's RETRY PATH, and the one property it has to have: no
// sequence of failures, of any length, in any interleaving, may produce
// unbounded recursion.
//
// openChannel()'s catch calls scheduleReopen(), and scheduleReopen() calls
// openChannel() back. That is TWO cycles in one pair of functions, and they are
// not equally safe:
//
//   * the ZERO-DELAY cycle (the burst) terminates, but only arithmetically --
//     mFails rises on every pass and ctBackoffMs stops returning 0 once the
//     burst is spent. Nothing structural stops it. That is what the c0 pin
//     below stands in front of.
//   * the TIMER-CATCH cycle does not terminate at all on the tree this file
//     was added to. Its differentials are in the c2 section.
//
// ---- THE GLOBALS CEILING ---------------------------------------------------
//
// EVERY declaration in this file sits inside `module RetryBound`. A file-scope
// (:test), helper function or class costs one member of module 'globals', which
// the fenix6 family caps at 253; a `module { }` block costs ONE member for
// everything inside it. See the measured ceiling note at the top of
// scripts/list_tests.py -- it is that note, not this comment, that
// scripts/check_ceiling_notes.py checks.
//
// So: declare nothing outside the module block. The simulator prints these as
// `RetryBound.test_rb_...`, and scripts/expected_tests.txt carries that
// qualified name because the pin has to match what the RUNNER prints.
//
// ---- Execution -------------------------------------------------------------
//
// These are (:test) functions: included in the --unit-test build, stripped from
// the shipping build, and EXECUTED on every PR (the run-tests CI job runs them
// headlessly in the simulator, judged by a fail-closed parser). Adding, removing
// or renaming one means editing scripts/expected_tests.txt in the SAME commit.
// See docs/CI.md.
module RetryBound {

// ---- c0: characterization pins on existing symbols --------------------------
// True BOTH before and after the fix in this branch. They exist to prove the
// change is behaviour-preserving where it claims to be, not to describe the
// defect; the differentials are in c2.

// THE ARITHMETIC THE BURST'S RECURSION BOUND RESTS ON, asserted by calling the
// ladder rather than by restating its constants.
//
// Two separate consequences hang on this one function, which is why it is
// pinned here and not left to test_ct_backoffLadder's table:
//
//   * scheduleReopen(0) calls openChannel() directly, from inside
//     openChannel()'s own catch. The chain unwinds ONLY because mFails rises on
//     every pass and this function stops returning 0 -- so the depth is capped
//     at CT_BURST_TRIES frames. An edit that let 0 come back (a "just retry
//     immediately" tidy-up, or a burst count raised without thought) would
//     reintroduce an unbounded recursion, and it would red HERE, in a case that
//     names the consequence.
//   * once the burst is spent the delay NEVER returns to 0 -- it only doubles
//     to a cap. So from that point on scheduleReopen always takes the timer
//     branch, and a timer branch that answered failure with an immediate reopen
//     could never be rescued by the ladder growing. That is the whole reason
//     the c2 cycle below has no bound.
(:test) function test_rb_c0_onlyTheBurstEverAsksForZeroDelay(logger) {
    var ok = true;
    for (var f = 0; f < $.CT_BURST_TRIES; f++) {
        if (CoreTempSensor.ctBackoffMs(f) != 0) {
            logger.error("ctBackoffMs(" + f + ") = " + CoreTempSensor.ctBackoffMs(f) +
                         "; inside the burst the ladder must still reopen immediately");
            ok = false;
        }
    }
    // Past the burst, and far past it: a single 0 anywhere here makes
    // openChannel <-> scheduleReopen recurse for as long as both keep failing.
    for (var f = $.CT_BURST_TRIES; f <= $.CT_BURST_TRIES + 16; f++) {
        if (CoreTempSensor.ctBackoffMs(f) <= 0) {
            logger.error("ctBackoffMs(" + f + ") = " + CoreTempSensor.ctBackoffMs(f) +
                         "; a zero here makes openChannel <-> scheduleReopen recurse without bound");
            ok = false;
        }
    }
    // The cap is a ceiling, not a wrap back to zero.
    if (CoreTempSensor.ctBackoffMs(1000) != $.CT_BACKOFF_MAX_MS) {
        logger.error("ctBackoffMs(1000) = " + CoreTempSensor.ctBackoffMs(1000) +
                     ", expected the cap " + $.CT_BACKOFF_MAX_MS);
        ok = false;
    }
    return ok;
}

}
