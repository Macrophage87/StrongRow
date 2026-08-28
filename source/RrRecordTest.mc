using Toybox.Test;

// Unit tests for rr_interval record building (issue #12): pad unused slots with
// the FIT UINT16 invalid sentinel (0xFFFF) instead of a fake 0 ms, and range-
// validate each interval BEFORE storing it so undecodable/implausible values
// never reach the field.
//
// These are (:test) functions: included in the --unit-test build (the
// compile-unit-test CI job compiles them across all 12 devices) and stripped
// from the shipping build. They EXECUTE on every PR: the run-tests CI job
// runs them headlessly in the simulator (`monkeydo <prg> fr965 -t`) and a
// fail-closed parser judges the output. Their names are pinned in
// scripts/expected_tests.txt -- adding or removing a test here means editing
// that file in the same commit. See docs/CI.md.

// The FIT "no data" sentinel, mirrored from StrongRowView.RR_INVALID (which is
// hidden). Kept in sync by the boundary tests below.
const RR_INV = 0xFFFF;

// Element-wise array compare. NOT (:test)-annotated, so it is reachable only
// from the tests below -- included in the unit-test build and dead-code-
// eliminated from the shipping build.
function rrArrEq(got, exp, logger) {
    if (got.size() != exp.size()) {
        logger.error("size " + got.size() + " != " + exp.size());
        return false;
    }
    for (var i = 0; i < exp.size(); i++) {
        if (got[i] != exp[i]) {
            logger.error("idx " + i + ": got " + got[i] + " exp " + exp[i]);
            return false;
        }
    }
    return true;
}

// End-to-end: ivals -> filtered in-range list -> padded record array, exactly
// as handleRr does before mFitRr.setData().
function buildRr(ivals) {
    return StrongRowView.packRr(StrongRowView.filterRr(ivals));
}

(:test) function test_rr_oneValid(logger) {
    return rrArrEq(buildRr([850]), [850, RR_INV, RR_INV, RR_INV], logger);
}

(:test) function test_rr_twoValid(logger) {
    return rrArrEq(buildRr([850, 810]), [850, 810, RR_INV, RR_INV], logger);
}

(:test) function test_rr_threeValid(logger) {
    return rrArrEq(buildRr([850, 810, 790]), [850, 810, 790, RR_INV], logger);
}

(:test) function test_rr_exactlyFour(logger) {
    return rrArrEq(buildRr([850, 810, 790, 770]), [850, 810, 790, 770], logger);
}

// A 5th valid beat is dropped (the RR_PER_REC cap -- one of the two documented
// rr_interval loss modes; see the #14 note in StrongRowView.handleRr).
(:test) function test_rr_fiveDropsExtra(logger) {
    return rrArrEq(buildRr([850, 810, 790, 770, 750]), [850, 810, 790, 770], logger);
}

// Out-of-range and null are dropped; slots stay at the invalid sentinel, not 0.
(:test) function test_rr_allInvalid(logger) {
    return rrArrEq(buildRr([50, 4000, -100, null]), [RR_INV, RR_INV, RR_INV, RR_INV], logger);
}

// Inclusive boundaries: 250 and 2500 kept, 249 and 2501 dropped -- the exact
// predicate the fix introduces and where an off-by-one would hide.
(:test) function test_rr_boundaryInclusive(logger) {
    return rrArrEq(buildRr([250, 2500, 249, 2501]), [250, 2500, RR_INV, RR_INV], logger);
}

// Valid intervals pack into the low slots with no gap even when interleaved
// with invalid ones.
(:test) function test_rr_interleavedPacksLow(logger) {
    return rrArrEq(buildRr([850, 50, 810, 4000, 790]), [850, 810, 790, RR_INV], logger);
}

(:test) function test_rr_nullIvals(logger) {
    return rrArrEq(buildRr(null), [RR_INV, RR_INV, RR_INV, RR_INV], logger);
}

(:test) function test_rr_emptyIvals(logger) {
    return rrArrEq(buildRr([]), [RR_INV, RR_INV, RR_INV, RR_INV], logger);
}

// filterRr in isolation: only in-range values, in arrival order, as the shared
// gate for both the FIT record and the rMSSD input.
(:test) function test_rr_filterInRangeOnly(logger) {
    var f = StrongRowView.filterRr([249, 250, 2500, 2501, null, 900]);
    if (!(f.size() == 3)) { logger.error("filter size " + f.size() + " != 3"); return false; }
    return rrArrEq(f, [250, 2500, 900], logger);
}

// -------- #15 rMSSD-freshness / #16 gap-reset predicates (issue #32) --------
// rrIsFresh(now, ts, thresh): strict `<`; never-seen (ts==0) is not fresh.
//
// #54: THE NEVER-SEEN CASE USED TO ASSERT ITS PROPERTY WITHOUT TESTING IT, and
// the asymmetry with rrGapExceeded below is why it slipped past review twice.
// The old case was rrIsFresh(10000, 0, 5000) != false. With now = 10000 and
// thresh = 5000, `now - 0 = 10000` already fails the `< threshMs` test, so the
// assertion held WITH OR WITHOUT the `tsMs > 0` guard -- measured: deleting the
// guard outright left the suite green. now = 3000 puts the never-seen stamp
// INSIDE the window, so the guard is the only thing that can produce false:
// guard present -> false; guard deleted -> 3000 - 0 < 5000 -> true, and the
// mutant dies.
//
// THE TWO CASES LOOK SYMMETRICAL AND ARE NOT. Do not "simplify" this one back
// to a large `now` to match the rrGapExceeded case below. That one works with
// any now because its comparison is `>`, so a zero stamp pushes the result the
// WRONG way and the guard is load-bearing for the expected value; for `<` a
// zero stamp pushes the SAME way as the guard, which makes the guard invisible.
//
// This matters beyond tidiness: rrIsFresh's never-seen behaviour is what
// decides what rr_interval and rmssd emit before the first beat of a session
// (#46, #68), so it has to be a tested property rather than a stated one.
(:test) function test_rr_isFresh_states(logger) {
    var ok = true;
    if (StrongRowView.rrIsFresh(10000, 9000, 5000) != true)  { logger.error("fresh 1s should be true");  ok = false; }
    if (StrongRowView.rrIsFresh(10000, 4000, 5000) != false) { logger.error("stale 6s should be false"); ok = false; }
    if (StrongRowView.rrIsFresh(10000, 5000, 5000) != false) { logger.error("boundary == thresh must be false (strict <)"); ok = false; }
    if (StrongRowView.rrIsFresh(10000, 5001, 5000) != true)  { logger.error("just inside thresh should be true"); ok = false; }
    if (StrongRowView.rrIsFresh(3000,  0,    5000) != false) { logger.error("never-seen (ts=0) must be false EVEN INSIDE the window -- the tsMs > 0 guard is the only thing that can produce it here"); ok = false; }
    return ok;
}

// The display RR pip was refactored from a hardcoded `< 5000` to
// rrIsFresh(..., RR_FRESH_MS). Pin the const so that refactor stays
// behavior-preserving: if someone retunes RR_FRESH_MS, this test flags that the
// UI pip's timing changed too (they are deliberately coupled today).
(:test) function test_rr_freshConstUnchanged(logger) {
    if ($.RR_FRESH_MS != 5000) {
        logger.error("RR_FRESH_MS changed to " + $.RR_FRESH_MS + "; display pip timing no longer matches the pre-refactor < 5000 test");
        return false;
    }
    return true;
}

// rrGapExceeded(now, lastBeat, thresh): strict `>`; never-seen (lastBeat==0)
// is not a gap (first beat just seeds mRrLast, no diff).
(:test) function test_rr_gapExceeded_states(logger) {
    var ok = true;
    if (StrongRowView.rrGapExceeded(10000, 9000, 2500) != false) { logger.error("gap 1s within bound should be false"); ok = false; }
    if (StrongRowView.rrGapExceeded(10000, 7400, 2500) != true)  { logger.error("gap 2.6s should be true");  ok = false; }
    if (StrongRowView.rrGapExceeded(10000, 7500, 2500) != false) { logger.error("boundary == thresh must be false (strict >)"); ok = false; }
    if (StrongRowView.rrGapExceeded(10000, 0,    2500) != false) { logger.error("never-seen (lastBeat=0) must be false"); ok = false; }
    return ok;
}
