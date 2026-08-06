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
