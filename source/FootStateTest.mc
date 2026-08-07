using Toybox.Test;

// Unit tests for issue #74: startSession() could fail and leave the watch
// showing an ordinary recording row for a row that produced no FIT file.
//
// The failure had three parts. startSession()'s outer catch nulled mSession;
// both callers set mStarted = true without observing that; and drawFoot was
// gated on mStarted alone and never consulted mSession. The result was a red
// "REC 12:34 2.10km 240str" footer -- live timer, live distance, live stroke
// count -- over a session that had never started and that stopAndSave()
// structurally could not save.
//
// The decision is extracted into the pure class-scope static
// StrongRowView.footState(), the same seam RateColourTest.mc uses for
// rateColour and CoreFieldGateTest.mc uses for coreFieldsWanted, because
// startSession() itself is not reachable from a (:test) (see
// CoreFieldGateTest.mc:10-12) while this predicate is.
//
// SCOPE, stated rather than implied: these tests pin the PREDICATE, not the
// call site. That drawFoot actually calls footState, and that startSession
// actually returns false on the failure paths, are covered by review only --
// a regression that reverted drawFoot to its `else if (mStarted)` chain would
// leave every test in this file green. Same caveat as RateColourTest.mc.
//
// Execution note: the run-tests CI job runs these headlessly in the simulator
// on every PR (`monkeydo <prg> fr965 -t`, judged by a fail-closed parser),
// with the test names pinned in scripts/expected_tests.txt -- update that file
// in the same commit as any (:test) change here. See docs/CI.md.

// -- The load-bearing case -----------------------------------------------------
// This is the regression #74 is about. If footState ever returns FOOT_REC for a
// failed recording, the app is back to lying about whether it is recording.
// Written first because it is the one case whose failure is not cosmetic.
(:test) function test_foot_failedRecordingNeverRendersAsRecording(logger) {
    // The exact state the bug produced: sensor fine, not paused, the caller
    // would have set started, and the session does not exist.
    var s = StrongRowView.footState(true, false, true, true);
    if (s == $.FOOT_REC) {
        logger.error("a failed recording rendered as FOOT_REC -- this is #74: " +
                     "the watch shows a normal REC row for a row that will " +
                     "produce no FIT file");
        return false;
    }
    if (s != $.FOOT_NO_REC) {
        logger.error("expected FOOT_NO_REC (" + $.FOOT_NO_REC + "), got " + s);
        return false;
    }
    return true;
}

// The failure must also be distinguishable from "you have not pressed START
// yet". Both have mStarted false once the caller stops setting it blindly, so
// only recFailed separates them -- and conflating them would tell the athlete
// to press a button they have already pressed.
(:test) function test_foot_failedIsDistinctFromIdle(logger) {
    var failed = StrongRowView.footState(true, false, false, true);
    var idle   = StrongRowView.footState(true, false, false, false);
    if (failed == idle) {
        logger.error("a failed recording is indistinguishable from never having " +
                     "started; both gave " + failed);
        return false;
    }
    if (failed != $.FOOT_NO_REC || idle != $.FOOT_IDLE) {
        logger.error("expected FOOT_NO_REC/FOOT_IDLE, got " + failed + "/" + idle);
        return false;
    }
    return true;
}

// -- Precedence ----------------------------------------------------------------
// Order is load-bearing, so each boundary gets its own case rather than being
// implied by the happy paths.

// A dead accelerometer outranks everything: nothing downstream is meaningful.
(:test) function test_foot_noAccelOutranksAllOtherStates(logger) {
    var s = StrongRowView.footState(false, true, true, true);
    if (s != $.FOOT_NO_ACCEL) {
        logger.error("NO ACCEL must outrank paused/started/failed; got " + s);
        return false;
    }
    return true;
}

// recFailed outranks paused. In the failure state mPaused holds whatever the
// previous session left behind, and a stale "PAUSED" would hide the failure
// behind a state that looks deliberate.
(:test) function test_foot_failedOutranksStalePaused(logger) {
    var s = StrongRowView.footState(true, true, false, true);
    if (s == $.FOOT_PAUSED) {
        logger.error("a stale paused flag masked the recording failure");
        return false;
    }
    if (s != $.FOOT_NO_REC) {
        logger.error("expected FOOT_NO_REC (" + $.FOOT_NO_REC + "), got " + s);
        return false;
    }
    return true;
}

// -- The three ordinary states -------------------------------------------------
// Epoch-invariant pins: green before and after #74. They exist to prove the new
// FOOT_NO_REC branch does not disturb the states that were already correct.

(:test) function test_foot_recordingWhenStartedAndHealthy(logger) {
    var s = StrongRowView.footState(true, false, true, false);
    if (s != $.FOOT_REC) {
        logger.error("a healthy started session must read FOOT_REC (" +
                     $.FOOT_REC + "); got " + s);
        return false;
    }
    return true;
}

(:test) function test_foot_pausedWhenStartedAndPaused(logger) {
    var s = StrongRowView.footState(true, true, true, false);
    if (s != $.FOOT_PAUSED) {
        logger.error("expected FOOT_PAUSED (" + $.FOOT_PAUSED + "), got " + s);
        return false;
    }
    return true;
}

(:test) function test_foot_idleBeforeStart(logger) {
    var s = StrongRowView.footState(true, false, false, false);
    if (s != $.FOOT_IDLE) {
        logger.error("expected FOOT_IDLE (" + $.FOOT_IDLE + "), got " + s);
        return false;
    }
    return true;
}

// -- Structural ----------------------------------------------------------------
// The five states must be five distinct values. A duplicated constant would
// make two footer states render identically while every case above still
// passed, because each case only ever compares against its own expected value.
(:test) function test_foot_theFiveStatesAreDistinct(logger) {
    var all = [ $.FOOT_NO_ACCEL, $.FOOT_NO_REC, $.FOOT_PAUSED,
                $.FOOT_REC, $.FOOT_IDLE ];
    for (var i = 0; i < all.size(); i++) {
        for (var j = i + 1; j < all.size(); j++) {
            if (all[i] == all[j]) {
                logger.error("footer state constants " + i + " and " + j +
                             " share the value " + all[i]);
                return false;
            }
        }
    }
    return true;
}

// -- The pause truth-mapping ----------------------------------------------------
// pauseFlags has regressed THREE times under review, every time because a flag
// was moved to the wrong side of a distinction. These pin the two rules that
// came out of it:
//
//   mPaused drives the FIT write gate and the step machine -> NEVER fail closed
//   mRecFailed drives the footer claim                      -> ALWAYS fail closed
//
// And the one that is easiest to lose: `live` comes from a fail-closed probe,
// so live == true is evidence and live == false is not.

// REGRESSION 1. A resume whose confirmation fails must still OPEN the write
// gate, because the session may in fact have resumed and record-scope fields
// latch: withholding writes from a live session re-emits stale values as real
// data for the rest of the piece.
(:test) function test_pause_unconfirmedResumeStillOpensTheWriteGate(logger) {
    var f = StrongRowView.pauseFlags(true, false, false);
    if (f[0] != false) {
        logger.error("an unconfirmed resume must leave paused FALSE so onTick " +
                     "keeps writing; got paused=" + f[0] + ". A live session " +
                     "would latch stale values for the rest of the row");
        return false;
    }
    if (f[1] != true) {
        logger.error("an unconfirmed resume must raise recFailed so the footer " +
                     "stays honest; got recFailed=" + f[1]);
        return false;
    }
    return true;
}

(:test) function test_pause_confirmedResumeClearsBothFlags(logger) {
    var f = StrongRowView.pauseFlags(true, true, true);
    if (f[0] != false || f[1] != false) {
        logger.error("a confirmed resume must clear both flags even if the " +
                     "previous attempt had failed; got paused=" + f[0] +
                     ", recFailed=" + f[1]);
        return false;
    }
    return true;
}

// REGRESSION 2. A refused stop has PROVED the recorder live, so it must clear a
// stale failure. Leaving it set stranded the footer on NOT RECORDING over a
// healthy row, with no way out but a press that stopped the healthy row.
(:test) function test_pause_refusedStopClearsAStaleFailure(logger) {
    var f = StrongRowView.pauseFlags(false, true, true);
    if (f[1] != false) {
        logger.error("a stop the session refused proves it is recording, so " +
                     "recFailed must clear; got recFailed=" + f[1] + " -- the " +
                     "footer would read NOT RECORDING over a live row");
        return false;
    }
    if (f[0] != false) {
        logger.error("a refused stop must stay UNPAUSED so onTick keeps " +
                     "writing into records that are still being emitted; got " +
                     "paused=" + f[0]);
        return false;
    }
    return true;
}

// REGRESSION 3, and the subtlest. The taken-pause arm is reached on a
// FAIL-CLOSED false, which cannot distinguish "my stop took" from "the session
// was already dead". An earlier revision cleared recFailed here on the reading
// that a deliberate pause is not a failure. Because the flag is only ever true
// after a real failure, that clear was a no-op on every healthy path and a lie
// on the one unhealthy path: from an honest NOT RECORDING, a single press
// bought a reassuring PAUSED over a dead recorder.
(:test) function test_pause_takenPausePreservesAnExistingFailure(logger) {
    var f = StrongRowView.pauseFlags(false, false, true);
    if (f[1] != true) {
        logger.error("a pause taken on a fail-closed probe must PRESERVE an " +
                     "existing failure, not clear it -- live==false is not " +
                     "evidence the stop was honoured; got recFailed=" + f[1] +
                     ", which would show PAUSED over a dead recorder");
        return false;
    }
    if (f[0] != true) {
        logger.error("a stop that took must pause; got paused=" + f[0]);
        return false;
    }
    return true;
}

// The ordinary pause, from a healthy row: paused, and still no failure.
(:test) function test_pause_healthyPauseRaisesNoFailure(logger) {
    var f = StrongRowView.pauseFlags(false, false, false);
    if (f[0] != true || f[1] != false) {
        logger.error("pausing a healthy row must give paused=true, " +
                     "recFailed=false; got " + f[0] + ", " + f[1]);
        return false;
    }
    return true;
}

// The invariant behind all of them, stated once so a future edit cannot satisfy
// the cases individually while breaking the rule: paused may only be set when
// the athlete asked to pause, never as a consequence of doubt about the
// recorder.
(:test) function test_pause_pausedNeverFailsClosed(logger) {
    var cfgs = [ [true, true], [true, false], [false, true], [false, false] ];
    for (var i = 0; i < cfgs.size(); i++) {
        for (var k = 0; k < 2; k++) {
            var prior = (k == 1);
            var f = StrongRowView.pauseFlags(cfgs[i][0], cfgs[i][1], prior);
            var mayPause = (cfgs[i][0] == false) && (cfgs[i][1] == false);
            if (f[0] == true && !mayPause) {
                logger.error("pauseFlags(" + cfgs[i][0] + "," + cfgs[i][1] +
                             "," + prior + ") set paused=true, which closes " +
                             "the FIT write gate and the step machine over a " +
                             "possibly-live session");
                return false;
            }
        }
    }
    return true;
}

// recFailed must never be cleared without evidence. The ONLY input that may
// clear a prior failure is one where the probe answered live == true.
(:test) function test_pause_failureClearedOnlyOnPositiveEvidence(logger) {
    var cfgs = [ [true, true], [true, false], [false, true], [false, false] ];
    for (var i = 0; i < cfgs.size(); i++) {
        var f = StrongRowView.pauseFlags(cfgs[i][0], cfgs[i][1], true);
        if (f[1] == false && cfgs[i][1] != true) {
            logger.error("pauseFlags(" + cfgs[i][0] + "," + cfgs[i][1] +
                         ",true) cleared an existing failure without the probe " +
                         "reporting live -- a fail-closed false is not evidence");
            return false;
        }
    }
    return true;
}
