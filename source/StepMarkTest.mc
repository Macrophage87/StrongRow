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

}
