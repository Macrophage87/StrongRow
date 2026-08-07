using Toybox.Test;

// Unit tests for issue #109: the rest view's four cells, and the raw totals
// they derive from.
//
// The rest interval is when the athlete reads the interval just finished, so
// the grid IS the screen there -- avg spm, avg m/str, interval m, avg bpm. All
// four come from ONE set of latched raw totals, derived at read time by the
// statics pinned here. Latching the totals rather than the figures is what
// stops two cells on the same screen disagreeing about the interval they
// describe.
//
// THE RULE THESE EXIST TO ENFORCE: "nothing to say" is NULL, never 0.0. This
// repository has already shipped a zero that read as data twice (#86, #107),
// and a rest cell reading 0.0 m/str is a claim about the interval, not an
// absence. drawSetGrid renders a dash for null.
//
// SCOPE: these pin the PREDICATES, not the call site. That drawSetGrid calls
// them, that latchWorkAccum fires at the right boundary, and that
// beginWorkAccum is wired to BOTH startWorkout and advanceStep are covered by
// review only here.
//
// NOT COVERED, WHICH IS NOT THE SAME AS NOT REACHABLE -- and an earlier version
// of this note said the wrong one. HrProbe.runUpdate drives the shipping
// onUpdate against HrGeoDc, a FAKE Dc that records every drawText, and it
// already renders GATE, WARM, COOL and DONE in CI today; #121's segfault is
// about a real graphics Dc and does not apply. The grid branch is simply
// unreached, because HrProbe has no way to latch a set. That is the seam that
// would have caught the two display regressions this PR went through, and it
// is filed rather than left implied.
//
// Execution note: the run-tests CI job runs these headlessly in the simulator
// on every PR, with the names pinned in scripts/expected_tests.txt -- update
// that file in the same commit as any (:test) change here.

// -- The null rule, first, because it is the one with a history ---------------

// No strokes means no answer, for every cell that divides by strokes. A zero
// here would render "0.0 m/str", which reads as a measured value.
(:test) function test_set_noStrokesIsNullNotZero(logger) {
    var dps = StrongRowView.setAvgDps(1042.0, 0);
    var spm = StrongRowView.setAvgSpm(0, 240.0);
    if (dps != null) {
        logger.error("zero strokes must give null m/str, not " + dps +
                     " -- a number here is a claim the interval never made");
        return false;
    }
    if (spm != null) {
        logger.error("zero strokes must give null spm, not " + spm);
        return false;
    }
    return true;
}

// No elapsed time means no answer. Reachable: an interval aborted on its first
// tick, or a step whose clock has not advanced.
(:test) function test_set_zeroDurationIsNull(logger) {
    if (StrongRowView.setAvgSpm(30, 0.0) != null) {
        logger.error("a zero-length interval must give null spm");
        return false;
    }
    return true;
}

// No distance means no answer for the two distance cells -- the podless or
// GPS-less case. The stroke-rate cell is unaffected, which is the point of
// deriving each cell separately rather than gating the whole grid.
(:test) function test_set_noDistanceIsNullButRateSurvives(logger) {
    if (StrongRowView.setDistM(0.0) != null) {
        logger.error("zero distance must render as absent, not as 0 m");
        return false;
    }
    if (StrongRowView.setAvgDps(0.0, 63) != null) {
        logger.error("zero distance must give null m/str");
        return false;
    }
    var spm = StrongRowView.setAvgSpm(63, 240.0);
    if (spm == null) {
        logger.error("a missing distance must not suppress the stroke rate: " +
                     "the cells are derived independently on purpose");
        return false;
    }
    return true;
}

// No heart-rate samples means no answer -- the strap-less row, and the whole
// #110 no-data class applied to an aggregate.
(:test) function test_set_noHrSamplesIsNull(logger) {
    if (StrongRowView.setAvgBpm(0, 0) != null) {
        logger.error("no HR samples must give null, not 0 bpm");
        return false;
    }
    return true;
}

// Null inputs must not throw. latchWorkAccum only ever writes numbers, but a
// caller reading an un-latched set would otherwise pass nulls straight in.
(:test) function test_set_nullInputsAreNullNotAThrow(logger) {
    if (StrongRowView.setAvgSpm(null, null) != null) { logger.error("spm"); return false; }
    if (StrongRowView.setAvgDps(null, null) != null) { logger.error("dps"); return false; }
    if (StrongRowView.setAvgBpm(null, null) != null) { logger.error("bpm"); return false; }
    if (StrongRowView.setDistM(null)        != null) { logger.error("dist"); return false; }
    return true;
}

// -- The arithmetic ----------------------------------------------------------

// A 4-minute set at a true 16 spm. Uses the count registerStroke actually
// produces (63, not 64 -- the first stroke after the rest gap is rejected),
// so the expected value is the one the watch will really show.
(:test) function test_set_avgSpmIsStrokesOverMinutes(logger) {
    var spm = StrongRowView.setAvgSpm(63, 240.0);
    if (spm < 15.7 || spm > 15.8) {
        logger.error("63 strokes in 240 s must be ~15.75 spm; got " + spm);
        return false;
    }
    return true;
}

// Metres per stroke is interval distance over interval strokes -- a ratio of
// two totals, NOT an average of the live distPerStroke() estimator, which is
// an instantaneous ratio of two smoothed values and a different quantity.
(:test) function test_set_avgDpsIsDistanceOverStrokes(logger) {
    var dps = StrongRowView.setAvgDps(400.0, 64);
    if (dps < 6.24 || dps > 6.26) {
        logger.error("400 m in 64 strokes must be 6.25 m/str; got " + dps);
        return false;
    }
    return true;
}

(:test) function test_set_avgBpmIsSumOverCount(logger) {
    var bpm = StrongRowView.setAvgBpm(14800, 100);
    if (bpm < 147.9 || bpm > 148.1) {
        logger.error("14800 over 100 samples must be 148 bpm; got " + bpm);
        return false;
    }
    return true;
}

// -- Coherence ---------------------------------------------------------------

// The three quantities are not independent, but a RECONSTRUCTION test cannot
// see that -- an earlier version of this case computed spm * minutes * m/str
// and compared it to the distance, which is (S*60/T) * (T/60) * (D/S) == D
// identically. Every term cancels. It passed for any inputs, including the
// paused case that was live when it was written, and the commit message
// claimed it pinned cell coherence. It pinned algebra.
//
// Pinned instead against values computed by hand, so a wrong denominator in
// any one cell reds it: a 240 s interval covering 400 m in 63 strokes.
(:test) function test_set_theCellsMatchHandComputedValues(logger) {
    var spm = StrongRowView.setAvgSpm(63, 240.0);   // 63 * 60 / 240 = 15.75
    var dps = StrongRowView.setAvgDps(400.0, 63);   // 400 / 63      = 6.349...
    var d   = StrongRowView.setDistM(400.0);
    if (spm < 15.74 || spm > 15.76) {
        logger.error("expected 15.75 spm, got " + spm);
        return false;
    }
    if (dps < 6.34 || dps > 6.36) {
        logger.error("expected 6.35 m/str, got " + dps);
        return false;
    }
    if (d < 399.99 || d > 400.01) {
        logger.error("expected 400 m, got " + d);
        return false;
    }
    return true;
}

// The denominators must be DIFFERENT quantities. spm divides by seconds and
// m/str divides by strokes; an edit that fed the same denominator to both
// would keep every case above green if the numbers happened to line up, so
// this drives each one against its own denominator deliberately.
//
// An earlier version of this case compared setAvgDps(400,60) with
// setAvgDps(400,60) -- identical arguments to a pure static, so that half could
// never fail. In the file whose whole point was removing a tautology.
(:test) function test_set_rateAndDpsUseDifferentDenominators(logger) {
    // Duration moves spm and must not move m/str; strokes must move m/str.
    var spmA = StrongRowView.setAvgSpm(60, 240.0);
    var spmB = StrongRowView.setAvgSpm(60, 480.0);
    var dpsA = StrongRowView.setAvgDps(400.0, 60);
    var dpsB = StrongRowView.setAvgDps(400.0, 63);
    if (spmA <= spmB) {
        logger.error("doubling the duration must halve the stroke rate; got " +
                     spmA + " then " + spmB);
        return false;
    }
    if (dpsA <= dpsB) {
        logger.error("more strokes over the same distance must LOWER m/stroke " +
                     "-- the stroke count is its denominator; got " + dpsA +
                     " then " + dpsB);
        return false;
    }
    return true;
}

// Negative inputs cannot arise from latchWorkAccum, which floors the distance
// at zero -- but a negative reaching a cell would render as a plausible
// number, so it is rejected as absence rather than displayed.
(:test) function test_set_negativeInputsAreAbsent(logger) {
    if (StrongRowView.setDistM(-5.0) != null) {
        logger.error("a negative distance must render as absent, not as -5 m");
        return false;
    }
    if (StrongRowView.setAvgDps(-5.0, 10) != null) {
        logger.error("a negative distance must give null m/str");
        return false;
    }
    if (StrongRowView.setAvgSpm(-3, 240.0) != null) {
        logger.error("a negative stroke count must give null spm");
        return false;
    }
    return true;
}
