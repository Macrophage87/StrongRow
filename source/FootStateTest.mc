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
// with the test names pinned in scripts/expected_tests.txt -- the names are
// `Foot.test_...`, see below. Update that file in the same commit as any
// (:test) change here. See docs/CI.md.

// ---------------------------------------------------------------------------
// THIS SUITE LIVES IN `module Foot`, and the reason is a measured ceiling, not
// taste. MEASURED, SDK 9.2.0, by bisecting throwaway file-scope (:test)
// functions against `monkeyc -d fenix6 --unit-test` (the compiler prints the
// count only once it is already over):
//
//     CEILING 2b23b03 fenix6-family: 252 used of 253, 1 free -- the 2nd file-scope (:test) added reds
//     CEILING post-move fenix6-family: 238 used of 253, 15 free -- the 16th file-scope (:test) added reds
//
// Those two lines are the machine-readable record; scripts/list_tests.py
// carries the same two verbatim and scripts/check_ceiling_notes.py fails if
// the copies drift apart or if the arithmetic stops closing.
//
// THE LIMIT IS INCLUSIVE. An earlier version of this comment said the NEXT
// (:test) added at file scope red the check; that is RETRACTED -- 253 members
// builds. Bisected on base 2b23b03 against all four devices, SDK 9.2.0:
// N=1 is BUILD SUCCESSFUL on fenix6, fenix6pro, fenix6spro and fenix6xpro, and
// N=2 reports "Found 254 members in module 'globals'" on all four. So the one
// free slot was spendable and the SECOND added file-scope (:test) is what reds
// the compile-unit-test check, with an error naming neither the test nor the
// file. release-build was unaffected (tests are stripped) and run-tests uses
// fr965, which compiles clean -- so a green local run proved nothing.
//
// Every file-scope function and class costs one member. A `module { }` block
// costs ONE, and everything inside it leaves 'globals' entirely. These fifteen
// cases therefore cost one member between them instead of fifteen: fourteen
// slots freed.
//
// The declarations below are NOT re-indented, matching the `module Hsi` blocks
// in CoreTempSensorTest.mc and PipLayoutTest.mc: the win is the brace, and
// re-indenting 250 lines would bury a two-line change in a whole-file diff.
//
// The simulator names these cases `Foot.test_...` -- MEASURED on fr965, see the
// depth note in scripts/list_tests.py -- and scripts/list_tests.py emits that
// qualified name so the pin matches what the runner prints.
// ---------------------------------------------------------------------------
module Foot {

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


// ===========================================================================
// #217: THE FOOTER'S WIDTH, MEASURED. c0 -- characterization only.
// ===========================================================================
//
// THE FIELD REPORT, 2026-09-12, fenix 9 Pro 51 mm (466 px AMOLED), first row
// on that watch: "some of the text on the bottom (in red) overflowed the
// watch." The only red text on the bottom of this app is drawFoot's recording
// footer. On the reported row it would have read "REC 43:45 0.03km 400wk".
//
// WHAT WAS NEVER MEASURED, and is measured here. drawFoot's own comment said
// the widest form is "REC 199:59 12.35km 9999wk" and that this is "a CHARACTER
// bound and not a clearance ... nothing here claims a measured margin". It did
// not, and nothing else did either: the string's PIXEL width had never been put
// beside the round chord at the row's y on any device.
//
// THE PROBE. dc.getTextWidthInPixels, dc.getTextDimensions, dc.getFontHeight,
// Gfx.getFontAscent and Gfx.getFontDescent, called from a throwaway app under
// SDK 9.2.0, once per device, on all NINETEEN products in manifest.xml -- the
// same procedure that produced Hsi.pipDevices() (issue #209 states it step by
// step). getTextWidthInPixels and getTextDimensions[0] agreed on every string
// on every device. The run also re-read the five columns pipDevices() already
// carries and reproduced all nineteen rows EXACTLY, and reproduced the 277 px
// this repository records for "-:--/500m  12.5m/str" on the 454 px family.
// That agreement is what makes these rows comparable to the committed ones;
// test_foot_c0_theMeasuredFooterTableAgreesWithPipDevices re-checks it here.
//
// A SIZE-MATE IS NOT A FONT-MATE, and it cut both ways this time. The two
// fenix 9 Pro Solar devices share a width with an older device and do NOT
// share its metrics (260 px: fh 21 against 19; 280 px: fh 22 against 19), so
// no row here is copied from a size-mate. The 466 px fenix9pro51mm DOES turn
// out to be a font-mate of the 454 px family -- every string measures the same
// number of pixels on both -- but that is MEASURED here, not assumed, and it
// is why the 466 device is NOT the worst device in this table: it has 200.28
// px of usable chord where the 454 family has 191.06.
//
// -- The measured table -------------------------------------------------------
// [ name, w, h, FONT_XTINY height,
//   then the FONT_XTINY pixel width of each footer form, in px:
//   recRow   "REC 43:45 0.03km 400wk"      the reported row's own footer
//   recMax   "REC 199:59 12.35km 9999wk"   the widest form drawFoot can build
//   noKmMax  "REC 199:59 9999wk"           rung 2, widest
//   noKm     "REC 43:45 400wk"             rung 2, the reported row
//   timeMax  "REC 199:59"                  rung 3, widest
//   time     "REC 43:45"                   rung 3, the reported row
//   rec      "REC"                         rung 4, the floor
//   pauseMax "PAUSED  9999wk"              paused rung 1, widest
//   pause    "PAUSED"                      paused rung 2, the floor
//   notRec   "NOT RECORDING"               safety state, never shortened
//   noAccel  "NO ACCEL"                    safety state, never shortened
//   startMax "START to record"             idle rung 1
//   start    "START"                       idle rung 2, the floor
// All values in pixels, SDK 9.2.0. Rows are kept per device, never collapsed
// by width, for the reason pipDevices() gives.
function footDevices() {
    return [
        [ "fr970",                454,  454,   37,  349,  400,  273,  239,  158,  141,   57,  239,  116,  238,  146,  226,   95 ],
        [ "fr965",                454,  454,   37,  349,  400,  273,  239,  158,  141,   57,  239,  116,  238,  146,  226,   95 ],
        [ "fenix847mm",           454,  454,   37,  349,  400,  273,  239,  158,  141,   57,  239,  116,  238,  146,  226,   95 ],
        [ "fenix843mm",           416,  416,   34,  326,  374,  255,  223,  147,  131,   53,  223,  108,  224,  137,  211,   88 ],
        [ "fenix8pro47mm",        454,  454,   37,  349,  400,  273,  239,  158,  141,   57,  239,  116,  238,  146,  226,   95 ],
        [ "fenix7",               260,  260,   19,  165,  189,  128,  112,   74,   66,   26,  111,   53,  110,   67,  107,   45 ],
        [ "fenix7pro",            260,  260,   19,  165,  189,  128,  112,   74,   66,   26,  111,   53,  110,   67,  107,   45 ],
        [ "epix2pro47mm",         416,  416,   31,  261,  300,  204,  178,  118,  105,   40,  175,   83,  170,  103,  169,   71 ],
        [ "fenix6",               260,  260,   19,  165,  189,  128,  112,   74,   66,   26,  111,   53,  110,   67,  107,   45 ],
        [ "fenix6pro",            260,  260,   19,  165,  189,  128,  112,   74,   66,   26,  111,   53,  110,   67,  107,   45 ],
        [ "fenix6spro",           240,  240,   19,  165,  189,  128,  112,   74,   66,   26,  111,   53,  110,   67,  107,   45 ],
        [ "fenix6xpro",           280,  280,   19,  165,  189,  128,  112,   74,   66,   26,  111,   53,  110,   67,  107,   45 ],
        // fenix 9 family, same probe run, same SDK.
        [ "fenix943mm",           416,  416,   34,  326,  374,  255,  223,  147,  131,   53,  223,  108,  224,  137,  211,   88 ],
        [ "fenix947mm",           454,  454,   37,  349,  400,  273,  239,  158,  141,   57,  239,  116,  238,  146,  226,   95 ],
        [ "fenix9pro43mm",        416,  416,   34,  326,  374,  255,  223,  147,  131,   53,  223,  108,  224,  137,  211,   88 ],
        [ "fenix9pro47mm",        454,  454,   37,  349,  400,  273,  239,  158,  141,   57,  239,  116,  238,  146,  226,   95 ],
        [ "fenix9pro51mm",        466,  466,   37,  349,  400,  273,  239,  158,  141,   57,  239,  116,  238,  146,  226,   95 ],
        [ "fenix9prosolar47mm",   260,  260,   21,  183,  210,  143,  125,   83,   74,   29,  124,   60,  123,   75,  121,   51 ],
        [ "fenix9prosolar51mm",   280,  280,   22,  198,  228,  155,  135,   90,   80,   31,  132,   63,  129,   78,  123,   52 ]
    ];
}

// Column indices into a footDevices() row, so no case counts commas.
const FD_NAME = 0;
const FD_W = 1;
const FD_H = 2;
const FD_FH = 3;
const FD_REC_ROW = 4;
const FD_REC_MAX = 5;
const FD_NOKM_MAX = 6;
const FD_NOKM = 7;
const FD_TIME_MAX = 8;
const FD_TIME = 9;
const FD_REC = 10;
const FD_PAUSE_MAX = 11;
const FD_PAUSE = 12;
const FD_NOTREC = 13;
const FD_NOACCEL = 14;
const FD_START_MAX = 15;
const FD_START = 16;

// The bezel floor these rows are held to, per side. THE SAME 2.0 px the
// status-row suite works to (Hsi.PIP_MIN_BEZEL_PX). scripts/check_foot_geometry.py
// fails if this copy and the shipped StrongRowView.FOOT_BEZEL_PX drift apart.
const FOOT_MIN_BEZEL_PX = 2.0;

// -- c0: pins on symbols that already exist ----------------------------------

// The distance cell of the reported row, through the SHIPPING formatter.
// "0.03km" is what footDistStr produces for the 30 m the reported row had
// covered, and it is the string whose width the table above records.
(:test) function test_foot_c0_footDistStrRendersTheReportedFieldRow(logger) {
    var got = StrongRowView.footDistStr(30.0, false);
    if (!got.equals("0.03km")) {
        logger.error("footDistStr(30.0, false) = " + got + ", expected " +
                     "0.03km -- the measured width of the reported row's " +
                     "footer is the width of the string containing THIS cell, " +
                     "so if the cell changed the table no longer describes it");
        return false;
    }
    if (!StrongRowView.footDistStr(12345.0, false).equals("12.35km")) {
        logger.error("footDistStr(12345.0, false) = " +
                     StrongRowView.footDistStr(12345.0, false) +
                     ", expected 12.35km (the widest form's cell)");
        return false;
    }
    if (!StrongRowView.footDistStr(null, false).equals("--")) {
        logger.error("footDistStr(null, false) should be --");
        return false;
    }
    if (!StrongRowView.footDistStr(0.0, true).equals("--")) {
        logger.error("footDistStr(0.0, true) should be -- (the erg gate)");
        return false;
    }
    return true;
}

// The two tables must have come from the same probe run, or the new rows are
// not comparable to the committed ones. Checked here rather than asserted in
// prose: every device in footDevices() must appear in Hsi.pipDevices() with
// the SAME width, height and FONT_XTINY height, and both must cover all 19.
(:test) function test_foot_c0_theMeasuredFooterTableAgreesWithPipDevices(logger) {
    var fd = footDevices();
    var pd = Hsi.pipDevices();
    if (fd.size() != 19 || pd.size() != 19) {
        logger.error("footDevices has " + fd.size() + " rows and pipDevices " +
                     pd.size() + "; manifest.xml declares 19 products and both " +
                     "tables are per-product");
        return false;
    }
    for (var i = 0; i < fd.size(); i++) {
        var name = fd[i][FD_NAME];
        var found = false;
        for (var j = 0; j < pd.size(); j++) {
            if (pd[j][0].equals(name)) {
                found = true;
                if (pd[j][1] != fd[i][FD_W] || pd[j][2] != fd[i][FD_H] ||
                        pd[j][3] != fd[i][FD_FH]) {
                    logger.error(name + ": footDevices says w/h/fh = " +
                                 fd[i][FD_W] + "/" + fd[i][FD_H] + "/" +
                                 fd[i][FD_FH] + ", pipDevices says " +
                                 pd[j][1] + "/" + pd[j][2] + "/" + pd[j][3] +
                                 " -- the two tables are then measurements of " +
                                 "different things and neither can be read " +
                                 "against the other");
                    return false;
                }
            }
        }
        if (!found) {
            logger.error(name + " is in footDevices and not in pipDevices");
            return false;
        }
        if (fd[i][FD_W] != fd[i][FD_H]) {
            logger.error(name + ": w != h. Every chord figure in this suite " +
                         "takes the display as the circle inscribed in w x h " +
                         "with w == h, which the probe measured on all 19.");
            return false;
        }
    }
    return true;
}

// The ladder must be a LADDER: each rung strictly narrower than the one above
// it, on every device. A rung no narrower than its predecessor could never be
// selected, and everything below is built on the ordering being real.
(:test) function test_foot_c0_theFooterLadderWidthsDecreaseOnEveryDevice(logger) {
    var fd = footDevices();
    var sets = [ [ FD_REC_MAX, FD_NOKM_MAX, FD_TIME_MAX, FD_REC ],
                 [ FD_REC_ROW, FD_NOKM, FD_TIME, FD_REC ],
                 [ FD_PAUSE_MAX, FD_PAUSE ],
                 [ FD_START_MAX, FD_START ] ];
    var names = [ "REC widest", "REC reported row", "PAUSED", "idle" ];
    for (var i = 0; i < fd.size(); i++) {
        for (var s = 0; s < sets.size(); s++) {
            for (var k = 1; k < sets[s].size(); k++) {
                var prev = fd[i][sets[s][k - 1]];
                var cur  = fd[i][sets[s][k]];
                if (cur >= prev) {
                    logger.error(fd[i][FD_NAME] + ": the " + names[s] +
                                 " ladder is not decreasing -- rung " + k +
                                 " measures " + cur + " px against " + prev +
                                 " px above it, so it could never be reached");
                    return false;
                }
            }
        }
    }
    return true;
}

}   // module Foot
