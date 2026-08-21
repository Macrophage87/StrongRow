using Toybox.Test;
using Toybox.System;
using Toybox.Lang;

// ---------------------------------------------------------------------------
// #125 -- which strokes the footer's figure counts.
//
// THE DEFECT. mStrokeCount is incremented for every accepted stroke while
// unpaused, whatever step is in force, and the footer renders it. So the number
// on the recording row includes the strokes taken while POSITIONING the boat
// before the first interval and the light paddling during every rest. In the
// maintainer's words on #125: "those strokes are mainly to position the boat
// into a good heading and location for the intervals, and tend to be quicker
// and lower force. The values we want to track are the drive strokes during the
// intervals." They bias a session count UP, and hardest on the short sessions
// where they are the largest fraction of it.
//
// THE BOUNDARY CHOSEN, because #125 asks for it to be settled before
// implementing and lists two defensible readings: WORK ONLY, not WORK+REST. It
// is the boundary the app already uses for every other per-interval aggregate
// (`mSetNum > 0`, bounded by beginWorkAccum / latchWorkAccum, which gates the
// heart-rate fold and the erg work integrator in onTick), so the footer can
// never disagree with the grid about what an interval was. The full argument is
// on the mWorkStrokes declaration and on StrongRowView.strokeCounts.
//
// TWO COUNTERS, NOT ONE RE-GATED COUNTER, and the distinction is load-bearing:
// mLastSetStrokes is a DELTA between two readings of mStrokeCount, so narrowing
// that counter's gate would silently move every per-interval figure #109's grid
// shows. mStrokeCount keeps counting everything; mWorkStrokes is the subset the
// footer reports.
//
// EVERYTHING HERE LIVES IN `module WorkStroke` -- ONE fenix6 globals member for
// the whole file rather than one per case. The simulator prints these as
// `WorkStroke.test_ws_...`, which is what scripts/expected_tests.txt carries.
//
// WHAT THESE CASES DRIVE. The SHIPPING registerStroke, through HrProbe's
// stroke-train seam, and the SHIPPING beginWorkAccum / latchWorkAccum through
// HrProbe.beginWork / latchWork. Nothing here transcribes the counting rule;
// the pure-static case asserts the decision function the call site actually
// calls. Stroke times are RELATIVE seconds handed to registerStroke -- no case
// reads System.getTimer(), so none of them can pass on an hours-old desktop
// simulator and red on CI's seconds-old one.
//
// Execution note: the run-tests CI job runs these headlessly in the simulator
// on fr965. Test names are pinned in scripts/expected_tests.txt -- update that
// file in the same commit as any (:test) change. See docs/CI.md.

module WorkStroke {

class WsCase {
    // A probe on `kind`, recording and unpaused, with both counters at zero.
    // A freshly constructed view has run beginSessionAccum, so no seam is
    // needed to zero them -- and taking them from the constructor rather than
    // assigning them is what keeps this a test of the shipping reset.
    static function probeAt(kind) {
        var p = new HrProbe();
        p.setSensorOk(true);
        p.enterStep(kind, false);
        return p;
    }
}

// -- c1: the counter itself. Green before the footer moves and after ---------

// THE RULE, over every input it can be given.
//
// Four rows, and the free-row one is the one a naive `mSetNum > 0` gate gets
// wrong: free-row mode has no steps at all, never opens an interval and so
// leaves mSetNum at 0 for the whole row -- a counter gated on the interval
// alone would report 0 strokes for every free row ever taken.
(:test) function test_ws_c1_theCountingRuleIsTheIntervalOrTheWholeFreeRow(logger) {
    var got  = [ StrongRowView.strokeCounts(true,  0),
                 StrongRowView.strokeCounts(true,  1),
                 StrongRowView.strokeCounts(true,  7),
                 StrongRowView.strokeCounts(false, 0),
                 StrongRowView.strokeCounts(false, 3) ];
    var want = [ false, true, true, true, true ];
    var name = [ "workout mode, outside any interval (positioning, rest, warm, gate, cool, done)",
                 "workout mode, inside interval 1",
                 "workout mode, inside interval 7",
                 "free row (no steps at all, so no 'before the interval')",
                 "free row, mSetNum irrelevant" ];
    for (var i = 0; i < got.size(); i++) {
        if (got[i] != want[i]) {
            logger.error("#125: strokeCounts must return " + want[i] + " for " +
                         name[i] + "; got " + got[i]);
            return false;
        }
    }
    return true;
}

// POSITIONING AND REST STROKES REACH THE SESSION COUNTER AND NOT THE WORK ONE.
//
// The whole of #125 as one sequence, driven through the SHIPPING detector and
// the SHIPPING interval boundary:
//
//   1. six strokes on a REST step        -- positioning / rest paddling
//   2. beginWorkAccum(2), seven strokes  -- the piece
//   3. latchWorkAccum(), seven strokes   -- the rest that follows it
//
// After each stage BOTH counters are asserted, so "the work counter did not
// move" can never hold because no stroke registered at all: the session counter
// is the witness that the train was accepted every time.
//
// Six from seven calls in stage 1 is the shipping detector's own arithmetic and
// not an off-by-one here: registerStroke needs a PERIOD, so the first stroke of
// a train has nothing to measure against and is rejected. Stages 2 and 3
// continue the same stroke clock at a valid spacing, so all seven of each are
// accepted -- which is also why this uses one probe and one clock rather than
// three trains from zero.
(:test) function test_ws_c1_onlyIntervalStrokesReachTheWorkCounter(logger) {
    var k = new HrProbe();
    var p = WsCase.probeAt(k.kindRest());

    p.strokeTrainFrom(0.0, 7);
    if (p.sessionStrokes() != 6 || p.workStrokes() != 0) {
        logger.error("#125: six strokes taken on a REST step must reach the " +
                     "SESSION counter and not the work counter; session=" +
                     p.sessionStrokes() + " work=" + p.workStrokes() +
                     " (want 6 and 0). A zero session count here would mean " +
                     "no stroke registered at all and the work assertion " +
                     "would be holding for the wrong reason.");
        return false;
    }

    p.beginWork(2);
    p.strokeTrainFrom(23.3333333, 7);
    if (p.sessionStrokes() != 13 || p.workStrokes() != 7) {
        logger.error("#125: seven strokes taken INSIDE work interval 2 must " +
                     "reach both counters; session=" + p.sessionStrokes() +
                     " work=" + p.workStrokes() + " (want 13 and 7)");
        return false;
    }

    p.latchWork();
    p.strokeTrainFrom(46.6666666, 7);
    if (p.sessionStrokes() != 20 || p.workStrokes() != 7) {
        logger.error("#125: strokes taken AFTER latchWorkAccum -- the rest " +
                     "between pieces -- must not reach the work counter; " +
                     "session=" + p.sessionStrokes() + " work=" +
                     p.workStrokes() + " (want 20 and 7). latchWorkAccum " +
                     "returns mSetNum to 0, which is the same boundary the " +
                     "heart-rate fold and the erg work integrator use.");
        return false;
    }
    return true;
}

// FREE ROW COUNTS EVERY STROKE, because there is no interval to be outside of.
//
// This is the arm a bare `mSetNum > 0` gate gets wrong, and it would be wrong
// SILENTLY and in the safe-looking direction: free-row mode never calls
// beginWorkAccum, so mSetNum is 0 for the life of the row and the footer would
// read 0 strokes from the first stroke to the last.
(:test) function test_ws_c1_freeRowCountsEveryStroke(logger) {
    var k = new HrProbe();
    var p = WsCase.probeAt(k.kindWork());
    // mStarted has to be raised before the mode is switched -- the same
    // ordering SgCase.enter and WorkLayoutTest.mc:96-99 use.
    p.setFreeRow();
    p.strokeTrainFrom(0.0, 7);
    if (p.sessionStrokes() != 6 || p.workStrokes() != 6) {
        logger.error("#125: in free-row mode every stroke is the piece -- both " +
                     "counters must read 6; session=" + p.sessionStrokes() +
                     " work=" + p.workStrokes());
        return false;
    }
    return true;
}

// A PAUSE STOPS BOTH COUNTERS.
//
// Not a new rule -- the `!mPaused` gate has been on mStrokeCount since #109 --
// but the new counter sits INSIDE that gate rather than beside it, and this is
// what pins that. #109's own note records why it matters: the accelerometer
// listener runs independently of recording, so drinking, wiping down or
// gesturing during a pause registers as strokes.
//
// The un-paused train at the end is the non-vacuity witness: without it, "the
// counters did not move" would hold just as well if the train never registered.
(:test) function test_ws_c1_pausedStrokesReachNeitherCounter(logger) {
    var k = new HrProbe();
    var p = WsCase.probeAt(k.kindWork());
    p.beginWork(1);
    p.enterStep(k.kindWork(), true);        // paused, still inside interval 1
    p.strokeTrainFrom(0.0, 7);
    if (p.sessionStrokes() != 0 || p.workStrokes() != 0) {
        logger.error("#125/#109: strokes registered while PAUSED must reach " +
                     "neither counter; session=" + p.sessionStrokes() +
                     " work=" + p.workStrokes());
        return false;
    }
    p.enterStep(k.kindWork(), false);       // resumed, same interval
    p.strokeTrainFrom(23.3333333, 7);
    // SEVEN, not six, and the difference is a MEASURED property of the shipping
    // detector rather than an arithmetic slip here. registerStroke updates
    // mLastStrokeT on EVERY call, paused or not -- only the counters and the
    // period ring sit behind gates -- so the first stroke after the resume has
    // the last PAUSED stroke to measure its period against and is accepted.
    // The first train got six from seven for the opposite reason: it had no
    // predecessor at all.
    //
    // That is the same fact #109's own note records from the other side ("mRate
    // and the DSP ring above are left running because clearing them would blank
    // the numeral for NPER strokes after every resume"), and it is pinned here
    // rather than asserted in prose: if a later change clears mLastStrokeT on a
    // pause, this number becomes 6 and the case reds instead of the behaviour
    // moving unnoticed.
    if (p.sessionStrokes() != 7 || p.workStrokes() != 7) {
        logger.error("#125: after the resume the same train must reach BOTH " +
                     "counters -- otherwise the paused assertion above holds " +
                     "because nothing registered at all; session=" +
                     p.sessionStrokes() + " work=" + p.workStrokes() +
                     " (want 7 and 7: registerStroke keeps mLastStrokeT " +
                     "current through a pause, so the first stroke after the " +
                     "resume DOES have a period to measure against)");
        return false;
    }
    return true;
}

}
