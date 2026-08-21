using Toybox.Test;
using Toybox.System;
using Toybox.Lang;

// ---------------------------------------------------------------------------
// THE STEP MARKS -- step_type (id 17) and interval_num (id 18).
//
// WHY THEY EXIST. In the FIT this app writes, a lap is just a lap: on activity
// i178249719 there are 17 laps and nothing distinguishes the eight 180 s work
// pieces from the rests, the warm-up or the cool-down. Every consumer has to
// GUESS from duration -- the analyses in #124 and #149 all filtered laps on
// "170 <= duration <= 190" -- and that guess DROPS a piece shortened for chop
// (one ran 820 s of a planned 900) and MISCLASSIFIES a rest that happens to run
// a piece's length, which on a 3'/3' session is every rest.
//
// THE ACCEPTANCE CRITERION, written down so it can be pinned rather than
// admired: FROM THE FIT ALONE, WITH NO DURATION HEURISTIC, A CONSUMER MUST BE
// ABLE TO SELECT EXACTLY THE WORK SECONDS AND GROUP THEM BY INTERVAL.
//
// It is proved in two halves, and neither half is described as the other:
//
//   WRITE SIDE -- this file. What the app HANDS setData, tick by tick, across
//   a scripted workout driven through the shipping step machine. A (:test)
//   cannot obtain a Session (CoreFieldGateTest.mc:10-12), so these cases
//   observe the ARGUMENT of a setData call on a recording stand-in and NOTHING
//   about a field_description message, a record's bytes or a decoder's output.
//
//   QUERY SIDE -- scripts/fit_step_marks.py. A synthetic FIT file carrying
//   these two fields, decoded, with the work seconds selected using ONLY
//   step_type and interval_num and compared against the timeline that produced
//   it -- including the two cases the duration heuristic gets wrong. That
//   harness proves the SELECTION RULE recovers the intended set from a file
//   with this encoding. It does NOT prove this app writes such a file.
//
// WHAT NEITHER HALF ESTABLISHES: that a Session accepts twenty-six developer
// fields, that MESG_TYPE_LAP is accepted at createField time, or what Garmin
// Connect renders for any of it. Those are [Local] questions and the issue
// filed with this change owns them.
//
// EVERYTHING HERE LIVES IN `module StepMark` -- ONE fenix6 globals member for
// the whole file. The simulator prints these as `StepMark.test_sm_...`, which
// is what scripts/expected_tests.txt carries.
//
// Execution note: the run-tests CI job runs these headlessly in the simulator
// on fr965. Test names are pinned in scripts/expected_tests.txt -- update that
// file in the same commit as any (:test) change. See docs/CI.md.

module StepMark {

// -- c1: the two pure encoders --------------------------------------------

// THE MIRROR IS THE SHIPPING CONSTANTS.
//
// stepTypeCode is a static, and a static cannot name a class `hidden const`, so
// the STEP_* ordinals it compares against are mirrored at module scope. A
// mirror nothing checks is a copy waiting to drift -- and drift HERE would not
// show up as a crash or a wrong screen: it would silently re-label seconds
// inside a file, where no consumer can see that it happened.
//
// Read through HrProbe's kind accessors, which return the class constants
// themselves.
(:test) function test_sm_c1_theMirroredOrdinalsAreTheShippingConstants(logger) {
    var k    = new HrProbe();
    var got  = [ k.kindWork(), k.kindRest(), k.kindGate(),
                 k.kindDone(), k.kindWarm(), k.kindCool() ];
    var want = [ $.SFIT_ORD_WORK, $.SFIT_ORD_REST, $.SFIT_ORD_GATE,
                 $.SFIT_ORD_DONE, $.SFIT_ORD_WARM, $.SFIT_ORD_COOL ];
    var name = [ "WORK", "REST", "GATE", "DONE", "WARM", "COOL" ];
    for (var i = 0; i < got.size(); i++) {
        if (got[i] != want[i]) {
            logger.error("the SFIT_ORD_ mirror of STEP_" + name[i] +
                         " is " + want[i] + " but the shipping constant is " +
                         got[i] + ". stepTypeCode reads the mirror, so this " +
                         "drift would re-label every second of that step in " +
                         "every file written from here on.");
            return false;
        }
    }
    return true;
}

// THE WIRE MAPPING IS THE TABLE THE SOURCE DOCUMENTS.
//
// These numbers ARE the format. The case asserts three separate things, and the
// third is the one the acceptance criterion rests on:
//
//   * every step kind maps to its documented code;
//   * no workout at all -- free row, and the pre-START window -- maps to
//     SFIT_NONE, which is a VALUE and not a silence, because record-scope
//     fields latch and a withheld write would re-emit the previous step;
//   * SFIT_WORK is DISTINCT from every other code, so "select the work
//     seconds" is an equality test and never a range or an exclusion list.
(:test) function test_sm_c1_theWireMappingIsTheDocumentedTable(logger) {
    var k    = new HrProbe();
    var kind = [ k.kindWarm(), k.kindWork(), k.kindRest(),
                 k.kindGate(), k.kindCool(), k.kindDone() ];
    var want = [ $.SFIT_WARM, $.SFIT_WORK, $.SFIT_REST,
                 $.SFIT_GATE, $.SFIT_COOL, $.SFIT_DONE ];
    var name = [ "WARM", "WORK", "REST", "GATE", "COOL", "DONE" ];
    for (var i = 0; i < kind.size(); i++) {
        var got = StrongRowView.stepTypeCode(kind[i], true, true);
        if (got != want[i]) {
            logger.error("STEP_" + name[i] + " must encode as " + want[i] +
                         "; got " + got);
            return false;
        }
        if (got == $.SFIT_NONE) {
            logger.error("STEP_" + name[i] + " encoded as SFIT_NONE, which is " +
                         "reserved for 'no workout step at all' -- a real step " +
                         "sharing that code makes a free row and a workout " +
                         "indistinguishable in the file");
            return false;
        }
        if (i > 0 && want[i] == $.SFIT_WORK && got != $.SFIT_WORK) {
            logger.error("the WORK code must be exact");
            return false;
        }
        // Every OTHER kind must differ from the work code, or "select the work
        // seconds" stops being an equality test.
        if (name[i].equals("WORK") == false && got == $.SFIT_WORK) {
            logger.error("STEP_" + name[i] + " encodes as SFIT_WORK, so a " +
                         "consumer selecting on step_type == SFIT_WORK would " +
                         "pick up " + name[i] + " seconds as work");
            return false;
        }
    }
    // No workout in force, by either route.
    if (StrongRowView.stepTypeCode(k.kindWork(), false, true) != $.SFIT_NONE) {
        logger.error("free-row mode must encode as SFIT_NONE whatever the " +
                     "stale step index says");
        return false;
    }
    if (StrongRowView.stepTypeCode(k.kindWork(), true, false) != $.SFIT_NONE) {
        logger.error("before START there is no step in force, so the code " +
                     "must be SFIT_NONE");
        return false;
    }
    // An ordinal no branch names falls to SFIT_NONE rather than to a guess: a
    // step kind added without extending the table must not be mistaken for an
    // existing code, least of all for the work one.
    if (StrongRowView.stepTypeCode(99, true, true) != $.SFIT_NONE) {
        logger.error("an unknown step ordinal must fall to SFIT_NONE");
        return false;
    }
    return true;
}

// INTERVAL_NUM IS THE APP'S OWN INTERVAL NUMBER, OR AN OUT-OF-BAND ZERO.
//
// The grouping half of the acceptance criterion. Three properties:
//
//   * inside a work interval it is mSetNum, the SAME quantity that gates the
//     heart-rate fold, the erg work integrator and the footer's stroke count --
//     so a consumer grouping on this field groups exactly the seconds the app
//     itself counted as interval n;
//   * outside one it is 0, which no real interval can be because buildWorkout
//     numbers them from 1;
//   * it NEVER reaches 0xFFFF, the UINT16 no-data pattern. numIntervals is not
//     re-clamped at the high end on load (#21), so the saturation is reachable
//     by a sideloaded setting rather than merely defensive -- and saturating
//     ONTO 0xFFFF would turn a real interval into an apparent absence.
(:test) function test_sm_c1_intervalNumIsTheIntervalOrAnOutOfBandZero(logger) {
    if (StrongRowView.intervalNumOf(true, true, 1) != 1 ||
        StrongRowView.intervalNumOf(true, true, 8) != 8) {
        logger.error("inside interval n the field must carry n");
        return false;
    }
    if (StrongRowView.intervalNumOf(true, true, 0) != $.IVL_NONE) {
        logger.error("outside a work interval the field must carry IVL_NONE (" +
                     $.IVL_NONE + ")");
        return false;
    }
    if ($.IVL_NONE != 0) {
        logger.error("IVL_NONE must be 0: buildWorkout numbers intervals from " +
                     "1, and that is the whole reason 0 is unambiguous");
        return false;
    }
    if (StrongRowView.intervalNumOf(false, true, 4) != $.IVL_NONE ||
        StrongRowView.intervalNumOf(true, false, 4) != $.IVL_NONE) {
        logger.error("free row and the pre-START window are not work " +
                     "intervals whatever mSetNum happens to hold");
        return false;
    }
    if (StrongRowView.intervalNumOf(true, true, 70000) != $.IVL_MAX) {
        logger.error("a numIntervals beyond the UINT16 range must SATURATE at " +
                     "IVL_MAX (" + $.IVL_MAX + "), got " +
                     StrongRowView.intervalNumOf(true, true, 70000));
        return false;
    }
    if ($.IVL_MAX >= 65535) {
        logger.error("IVL_MAX is " + $.IVL_MAX + ", at or above the UINT16 " +
                     "no-data pattern 0xFFFF -- saturating onto it would turn " +
                     "a real interval into an apparent absence");
        return false;
    }
    return true;
}

// -- c2: the write wiring. RED until the fields are created and written ------

// A recording stand-in for a FitContributor field handle. Keeps the whole write
// HISTORY, not just the last value: a record-scope field that LATCHES is only
// honest if it is written on EVERY tick, which is a claim about the COUNT and
// not only about the value.
class SmField {
    var vals;
    function initialize() { vals = []; }
    function setData(v) { vals.add(v); }
    function last() { return (vals.size() == 0) ? null : vals[vals.size() - 1]; }
    function count() { return vals.size(); }
}

class SmCase {
    // A probe with the four stand-ins installed, on `kind`, with the step clock
    // LIVE -- enterStepLive rather than enterStep, because onTick auto-advances
    // a WORK or REST step whose clock has run out and the scripted walks below
    // must control the transitions themselves.
    static function probe(kind, f) {
        var p = new HrProbe();
        p.setSensorOk(true);
        p.installStepFields(f[0], f[1], f[2], f[3]);
        p.enterStepLive(kind, false);
        return p;
    }

    static function fields() {
        return [ new SmField(), new SmField(), new SmField(), new SmField() ];
    }
}

// EVERY TICK WRITES BOTH MARKS, AND A PAUSED TICK WRITES NEITHER.
//
// The COUNT is asserted as hard as the value, and that is the point rather than
// thoroughness: record-scope fields LATCH (#36, byte level on fr965 / SDK
// 9.2.0), so a field written on some ticks and not others does not leave a gap
// on the others -- it RE-EMITS the last step, which would report work seconds
// that did not happen. That is the exact defect these fields exist to remove,
// so "written every tick" is part of the design and not an implementation
// detail.
//
// A PAUSED TICK IS DIFFERENT AND IS NOT A HOLE. togglePause stops the session,
// so no record commits while paused and there is nothing for a value to attach
// to; the whole tick write block is behind the same mStarted && !mPaused gate
// every other record field uses.
(:test) function test_sm_c2_everyTickWritesBothMarksAndAPausedTickWritesNeither(logger) {
    var k = new HrProbe();
    var f = SmCase.fields();
    var p = SmCase.probe(k.kindRest(), f);

    p.runTick();
    if (f[0].count() != 1 || f[1].count() != 1) {
        logger.error("both record marks must be written on EVERY tick -- a " +
                     "skipped write re-emits the previous step rather than " +
                     "leaving a gap; step writes=" + f[0].count() +
                     " interval writes=" + f[1].count() + " after one tick");
        return false;
    }
    if (f[0].last() != $.SFIT_REST || f[1].last() != $.IVL_NONE) {
        logger.error("a tick on REST must write (SFIT_REST, IVL_NONE); wrote (" +
                     f[0].last() + ", " + f[1].last() + ")");
        return false;
    }

    p.beginWork(3);
    p.enterStepLive(k.kindWork(), false);
    p.runTick();
    if (f[0].count() != 2 || f[0].last() != $.SFIT_WORK || f[1].last() != 3) {
        logger.error("a tick inside work interval 3 must write (SFIT_WORK, 3); " +
                     "wrote (" + f[0].last() + ", " + f[1].last() + ") on " +
                     "write number " + f[0].count());
        return false;
    }

    p.enterStepLive(k.kindWork(), true);       // paused, same interval
    p.runTick();
    if (f[0].count() != 2 || f[1].count() != 2) {
        logger.error("a PAUSED tick must write neither mark -- the session is " +
                     "stopped and no record commits; step writes=" +
                     f[0].count() + " interval writes=" + f[1].count());
        return false;
    }

    p.enterStepLive(k.kindWork(), false);
    p.setFreeRow();
    p.runTick();
    if (f[0].last() != $.SFIT_NONE || f[1].last() != $.IVL_NONE) {
        logger.error("a free row has no workout step, and that is a VALUE " +
                     "rather than a withheld write: expected (SFIT_NONE, " +
                     "IVL_NONE), wrote (" + f[0].last() + ", " + f[1].last() +
                     "). A withheld write would re-emit the previous row's " +
                     "step for the whole free row.");
        return false;
    }
    return true;
}

// A SCRIPTED WORKOUT WRITES THE DOCUMENTED SEQUENCE.
//
// THE ACCEPTANCE CRITERION ON THE WRITE SIDE. The walk goes through the
// SHIPPING advanceStep -- the same call that latches the interval, opens the
// lap and moves the step clock -- and one tick is taken in each step. The
// expected pairs are written out from the DOCUMENTED table, not by calling the
// encoders a second time: a case that computed its expectation from
// stepTypeCode would pass whatever that function returned.
//
// THE STEP LIST IS THE ONE buildWorkout REALLY EMITS, and an earlier revision
// of this case got it wrong: it assumed WARM / WORK1 / REST1 / WORK2. With the
// shipped defaults (5 intervals, 4 min work, 2 min rest, warm-up and cool-down
// on, AND pressToContinue on) buildWorkout adds a GATE after every rest as well
// -- WARM, WORK1, REST1, GATE1, WORK2. The case reported "at WORK2 the record
// marks must be (2, 2); wrote (4, 0)", which is the gate's own code, and the
// expectation was corrected to the code rather than the other way round.
//
// That mistake improved the case. The walk now crosses THREE boundaries that
// matter: work into rest, rest into the gate, and the gate into the NEXT work
// interval, where the interval number must advance -- and the gate is the step
// that opens no lap, which is exactly the limit the lap case below pins.
//
// WHAT IT SHOWS, exactly: selecting the ticks whose step mark is SFIT_WORK
// recovers the work steps and no others, and the interval number partitions
// them by piece. WHAT IT DOES NOT SHOW: that any of this reaches a file. No
// (:test) can obtain a Session; scripts/fit_step_marks.py carries the query
// side against a real FIT byte stream, and the [Local] issue carries the rest.
(:test) function test_sm_c2_aScriptedWorkoutWritesTheDocumentedSequence(logger) {
    var k = new HrProbe();
    var f = SmCase.fields();
    var p = SmCase.probe(k.kindWarm(), f);

    // WARM, then four advances: WORK1, REST1, GATE1, WORK2.
    var wantStep = [ $.SFIT_WARM, $.SFIT_WORK, $.SFIT_REST,
                     $.SFIT_GATE, $.SFIT_WORK ];
    var wantIvl  = [ 0,           1,           0,
                     0,           2 ];
    var names    = [ "WARM", "WORK1", "REST1", "GATE1", "WORK2" ];

    for (var i = 0; i < wantStep.size(); i++) {
        if (i > 0) { p.advance(); }
        p.runTick();
        if (f[0].last() != wantStep[i] || f[1].last() != wantIvl[i]) {
            logger.error("at " + names[i] + " the record marks must be (" +
                         wantStep[i] + ", " + wantIvl[i] + "); wrote (" +
                         f[0].last() + ", " + f[1].last() + "). This is the " +
                         "acceptance criterion on the write side: the work " +
                         "seconds and their interval number must be readable " +
                         "with no duration heuristic.");
            return false;
        }
        if (f[0].count() != i + 1) {
            logger.error("one write per tick, and no more: after " + (i + 1) +
                         " ticks the step field carries " + f[0].count() +
                         " writes");
            return false;
        }
    }

    // The selection, performed exactly as a consumer would: equality on the
    // step mark, then grouping on the interval number. Nothing here looks at a
    // duration.
    var picked = [];
    for (var j = 0; j < f[0].count(); j++) {
        if (f[0].vals[j] == $.SFIT_WORK) { picked.add(f[1].vals[j]); }
    }
    if (picked.size() != 2 || picked[0] != 1 || picked[1] != 2) {
        logger.error("selecting step_type == SFIT_WORK must recover exactly " +
                     "the two work ticks, in intervals 1 and 2; got " +
                     picked.size() + " ticks");
        return false;
    }
    return true;
}

// THE LAP MARK NAMES THE STEP THAT OPENED THE LAP -- AND THE GATE OPENS NONE.
//
// One write per lap OPENED, and none otherwise. advanceStep opens a lap for
// WORK, REST and COOL only, so the walk WARM, WORK1, REST1, GATE1, WORK2 opens
// exactly THREE laps -- the gate opens none -- and stamps each with the step it
// started in.
//
// THE LIMIT IS PINNED HERE RATHER THAN DESCRIBED. The gate's seconds fall
// inside the REST lap that precedes it, and that lap still reads SFIT_REST. So
// a lap-level consumer reading lap_step_type gets the step the lap STARTED in,
// which is not always all of what the lap contains. That is exactly why the
// RECORD marks are the primary half of this feature and the lap copies are the
// convenience half: per-record marks do not depend on lap boundaries aligning
// with steps, and here they demonstrably do not always align.
//
// (With pressToContinue OFF and a rest configured, every step gets its own lap
// and the alignment is exact. With restMinutes = 0 the gate follows a WORK and
// the same non-alignment lands on the work lap instead. Neither variant is
// reachable from this case, which drives the shipped defaults; both are stated
// so the limit is not read as narrower than it is.)
(:test) function test_sm_c2_theLapMarkNamesTheStepThatOpenedTheLap(logger) {
    var k = new HrProbe();
    var f = SmCase.fields();
    var p = SmCase.probe(k.kindWarm(), f);

    // No lap is opened by entering WARM through the seam: the session's first
    // lap is stamped in startWorkout, which needs a real Session and is out of
    // reach of a (:test).
    if (f[2].count() != 0) {
        logger.error("entering WARM through the probe seam opens no lap, so " +
                     "no lap mark should have been written yet; got " +
                     f[2].count());
        return false;
    }
    // The walk, with the number of laps OPEN after each advance. The gate is
    // the row that matters: it advances the step machine and opens no lap, so
    // the count does not move and the mark still describes the rest.
    var wantStep = [ $.SFIT_WORK, $.SFIT_REST, $.SFIT_REST, $.SFIT_WORK ];
    var wantIvl  = [ 1,           0,           0,           2 ];
    var wantN    = [ 1,           2,           2,           3 ];
    var names    = [ "WORK1", "REST1", "GATE1", "WORK2" ];
    for (var i = 0; i < wantStep.size(); i++) {
        p.advance();
        if (f[2].count() != wantN[i] || f[3].count() != wantN[i]) {
            logger.error("after advancing into " + names[i] + " there must be " +
                         wantN[i] + " lap mark(s) -- a lap is opened for WORK, " +
                         "REST and COOL only, and a GATE opens none; step " +
                         "marks=" + f[2].count() + " interval marks=" +
                         f[3].count());
            return false;
        }
        if (f[2].last() != wantStep[i] || f[3].last() != wantIvl[i]) {
            logger.error("the lap in force at " + names[i] + " must be marked (" +
                         wantStep[i] + ", " + wantIvl[i] + "); wrote (" +
                         f[2].last() + ", " + f[3].last() + "). The mark is " +
                         "written AFTER addLap (which closes the outgoing lap) " +
                         "and AFTER beginWorkAccum (which sets the interval " +
                         "number), or it would describe the wrong lap.");
            return false;
        }
    }
    return true;
}

}
