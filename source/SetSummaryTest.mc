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
// SCOPE, stated rather than implied: these pin the PREDICATES, not the call
// site. That drawSetGrid actually calls them, that latchWorkAccum fires at the
// right boundary, and that beginWorkAccum is wired to BOTH startWorkout and
// advanceStep are covered by review only -- none of those is reachable from a
// (:test). Same caveat RateColourTest.mc and FootStateTest.mc both state.
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

// The three quantities are not independent: distance = spm * minutes * m/str.
// Deriving all of them from ONE set of totals is what guarantees it, and this
// case is what would catch a future edit that latched a derived figure for one
// cell while deriving another.
(:test) function test_set_theCellsAgreeWithEachOther(logger) {
    var strokes = 64;
    var sec     = 240.0;
    var dist    = 400.0;
    var spm = StrongRowView.setAvgSpm(strokes, sec);
    var dps = StrongRowView.setAvgDps(dist, strokes);
    var d   = StrongRowView.setDistM(dist);
    // spm * minutes * m/str must reconstruct the distance.
    var recon = spm * (sec / 60.0) * dps;
    if (recon < d - 0.01 || recon > d + 0.01) {
        logger.error("the cells disagree: " + spm + " spm x " + (sec / 60.0) +
                     " min x " + dps + " m/str = " + recon + ", but the " +
                     "distance cell says " + d + ". All four cells must derive " +
                     "from one set of raw totals");
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
