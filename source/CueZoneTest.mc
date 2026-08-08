using Toybox.Test;
using Toybox.Graphics as Gfx;
using Toybox.System;
using Toybox.Lang;

// Suite for the DISPLAY CUE: the stroke-rate colour treated as an instruction
// ("row harder" / "hold" / "ease off") rather than as a rendering of the
// measurement.
//
// THE SPLIT THIS FILE EXISTS TO GUARD, in the maintainer's words:
//
//   "The in row measurement is designed to just tell me whether I should
//    increase or decrease my rate. Have it keep the actual measurement in the
//    file though."
//
// So one number does two jobs and they get different treatment:
//
//   ON THE WATER   the COLOUR is a controller cue. Lag and hysteresis are free
//                  here, because a late instruction is cheaper than a wrong one.
//   IN THE FIT     row_stroke_rate, dist_per_stroke and corrective_rate stay the
//                  UNMODIFIED estimator output. If a recorded value moves, the
//                  change is wrong.
//
// And the displayed NUMBER stays raw too -- only the colour is filtered. That is
// not a stylistic preference, it is a measured result; the numbers are in the
// pull request and the negative result is restated at the constants themselves
// (StrongRowView.mc, the CUE_* block).
//
// -- WHAT THIS FILE CAN SEE --------------------------------------------------
// CueDc below records every drawText the shipping draw path issues together
// with the FOREGROUND COLOUR IN EFFECT AT THAT CALL. So a case here can say
// which string was drawn in which colour. It cannot say anything about how that
// looks on a wrist, and no case here claims to: #121 measured the CI container
// segfaulting the moment a test obtains a real graphics Dc, so no font metric
// and no rendered pixel is available to any (:test) in this repository.
//
// It records what the code CALLS. It says nothing about what a panel shows.
//
// -- COMMIT PARTITION --------------------------------------------------------
// This section is c0: CHARACTERIZATION PINS ON EXISTING SYMBOLS ONLY. Every
// case in it is green on main at 920d4e1, before one line of the cue layer
// exists, and green after the whole thing lands. They are the statements the
// change must NOT falsify -- above all the two FIT-side ones.
//
// Execution note: the run-tests CI job runs these headlessly in the simulator on
// fr965. Test names are pinned in scripts/expected_tests.txt -- update that file
// in the SAME commit as any (:test) change here. See docs/CI.md.

// -- Fixture -----------------------------------------------------------------
// The shipped default band (resources/settings/properties.xml: targetLo 16 /
// targetHi 18), as module consts so no case can disagree with its own band by
// typo. Same convention as RateColourTest.mc's RC_LO / RC_HI.
const CZ_LO = 16;
const CZ_HI = 18;

// A COLOUR-RECORDING Dc.
//
// Duck-typed: onUpdate's `dc` is used only through method calls and the members
// it reaches are untyped, so at runtime only duck typing applies and this needs
// exactly the surface the shipping draw path uses -- measured, not guessed:
// clear, setColor, setPenWidth, getWidth, getHeight, getFontHeight, drawText,
// drawArc, drawLine.
//
// The one thing it adds over HrDc (HrArcTest.mc) is the COLOUR. HrDc's
// setColor is a no-op, which is exactly right for a suite about geometry and
// exactly wrong for a suite about a cue, since the cue's entire output IS the
// colour.
class CueDc {
    var w; var h;
    var fg;         // the foreground colour the last setColor established
    var strings;    // every drawText string, in call order
    var colours;    // the fg in effect at each of those calls
    var fonts;      // the font each was drawn in

    function initialize(width, height) {
        w = width; h = height;
        fg = null;
        strings = []; colours = []; fonts = [];
    }

    function getWidth()  { return w; }
    function getHeight() { return h; }
    // Never consulted by any assertion here: only drawSetGrid calls it, and no
    // case in this file renders the #109 grid. Present so that a future case
    // that does reach it fails on its assertion rather than on a missing method.
    function getFontHeight(f) { return h / 10; }

    function setColor(f, b) { fg = f; }
    function setPenWidth(p) { }
    function clear()        { }
    function drawArc(x, y, r, attr, degStart, degEnd) { }
    function drawLine(x1, y1, x2, y2) { }

    function drawText(x, y, font, s, just) {
        strings.add(s);
        colours.add(fg);
        fonts.add(font);
    }
}

// The big stroke-rate numeral, located BY ITS FONT rather than by its position
// or its content.
//
// By font because that is the only identifier that is stable across everything
// these cases vary. The string changes with the rate (and is "--.-" in the
// no-data state, which is one of the states under test), and the y fraction is
// a layout decision this file does not own. drawRate is the ONLY call site that
// uses FONT_NUMBER_THAI_HOT / FONT_NUMBER_HOT -- the countdown beside it uses
// FONT_NUMBER_MILD, a different constant -- so the font selects it exactly.
function czNumeralIdx(d) {
    for (var i = 0; i < d.fonts.size(); i++) {
        var f = d.fonts[i];
        if (f == Gfx.FONT_NUMBER_THAI_HOT || f == Gfx.FONT_NUMBER_HOT) {
            return i;
        }
    }
    return -1;
}

function czNumeralColour(d) {
    var i = czNumeralIdx(d);
    return (i < 0) ? null : d.colours[i];
}

function czNumeralText(d) {
    var i = czNumeralIdx(d);
    return (i < 0) ? null : d.strings[i];
}

// A drawn screen, from a probe. Device dimensions come from the simulator the
// suite is actually running on, exactly as WorkLayoutTest.wlRender does, so
// drawRate's `w >= 300` font choice is the real one for that device rather than
// a number this file picked.
function czRender(p) {
    var ds = System.getDeviceSettings();
    var d = new CueDc(ds.screenWidth, ds.screenHeight);
    p.runUpdate(d);
    return d;
}

// Render at a stated instant on the probe's injected clock.
//
// NEVER System.getTimer(). That counts from DEVICE start, so a case that
// synthesised its stamps from it would depend on how long the simulator had
// been up -- and CI's simulator is seconds old while a desktop one is hours
// old. This repository has already been bitten by that asymmetry (the note at
// StrongRowView.nowMs); every stamp in this file is an absolute number chosen
// by the case.
function czRenderAt(p, tMs) {
    p.setNowMs(tMs);
    return czRender(p);
}

// A FitContributor field stand-in. Records every value written, in order, so a
// case can assert on WHAT WAS HANDED TO setData.
//
// SCOPE, stated because this is precisely the claim this repository keeps
// overreaching on: this observes the ARGUMENT of an in-app call. It says
// nothing about what lands in the file's bytes and nothing about what a decoder
// renders. Those need a simulator session and a decode, not a (:test).
class CueField {
    var vals;
    function initialize() { vals = []; }
    function setData(v) { vals.add(v); }
    function last() { return (vals.size() == 0) ? null : vals[vals.size() - 1]; }
}

// -- Probe -------------------------------------------------------------------
// Extends HrProbe (HrArcTest.mc) rather than re-deriving from StrongRowView:
// the seams this suite needs -- the injected nowMs() clock, enterStep /
// enterStepLive, runUpdate's Dc cast, the neutralised sensor and GPS starts,
// the deterministic currentSpeed/elapsedDist -- already exist there and are
// already exercised by two suites (HrLayoutTest, WorkLayoutTest). Duplicating
// them would be a second copy free to drift.
class CueProbe extends HrProbe {
    function initialize() { HrProbe.initialize(); }

    // Put the ESTIMATOR at a chosen rate.
    //
    // Writes the detector's median (mRate) and clears the autocorrelation lock,
    // which is the state registerStroke/recomputeRate leave behind for a steady
    // cadence below FAST_NEEDS_LOCK. It does NOT bypass outputRate(): every
    // assertion below reads the value through the shipping outputRate(), which
    // for mAcPeriod == 0.0 and 0 < mRate <= 30 returns mRate unchanged. Rates
    // used in this file are 14.0-25.0, well inside that.
    //
    // Direct rather than driveStrokes() because the cases here need the rate to
    // CHANGE at a chosen instant -- a spike, a dip, a return -- and a median of
    // the last five stroke periods cannot be steered to an exact value on a
    // chosen frame.
    function setRate(spm) {
        mRate = spm;
        mAcPeriod = 0.0;
    }

    // The estimator's output, read through the shipping method.
    function rawRate() { return outputRate(); }

    // Hand the view a recording stand-in for the row_stroke_rate field, so a
    // case can see the value onTick writes.
    function installFitRate(f) { mFitRate = f; }

    // The real 250 ms tick, called directly.
    function runTick() { onTick(); }
}

// A probe already in a live, unpaused WORK step with the default band.
// enterStepLive (not enterStep) leaves the step clock running, so stepRemaining()
// is the full interval and onTick's advanceStep() is not triggered -- these
// cases must not advance the workout underneath themselves.
function czWorkProbe() {
    var p = new CueProbe();
    p.enterStepLive(p.kindWork(), false);
    p.setSpeed(0.0);
    p.setDist(0.0);
    return p;
}

// -- c0: characterization pins ------------------------------------------------
// Green before the cue layer exists and green after it.

// THE FILE-SIDE PIN, and the one the maintainer's instruction turns on: the
// value handed to row_stroke_rate is the RAW estimator, never the cue.
//
// Constructed so that it is a real differential once the cue exists: the screen
// is first put in band at 17.0, then the rate jumps to 25.0 and ONE frame is
// drawn 250 ms later. After the change that frame is still showing the in-band
// colour (the jump has not persisted long enough to be believed), so cue and
// measurement genuinely disagree at the moment onTick runs -- and the field
// must still receive 25.0.
//
// Before the change the two agree trivially and the case is a plain
// characterization pin. That is the point of writing it at c0: it is green in
// both epochs and its meaning strengthens rather than changes.
(:test) function test_cue_c0_fitRateIsTheRawEstimatorNotTheCue(logger) {
    var p = czWorkProbe();
    var f = new CueField();
    p.installFitRate(f);

    p.setRate(17.0);
    czRenderAt(p, 0);
    p.setRate(25.0);
    czRenderAt(p, 250);

    p.runTick();

    var got = f.last();
    var want = p.rawRate();
    if (got == null) {
        logger.error("onTick wrote nothing to row_stroke_rate at all");
        return false;
    }
    if (got != want) {
        logger.error("row_stroke_rate must carry the UNMODIFIED estimator: " +
                     "outputRate() is " + want + " but setData got " + got);
        return false;
    }
    if (got != 25.0) {
        logger.error("the estimator was put at 25.0 and the field received " +
                     got + " -- the FIT path has acquired a filter");
        return false;
    }
    return true;
}

// THE OTHER HALF OF THE SPLIT: the displayed NUMBER is the measurement too.
// Only the colour is a cue. Rendered one frame after a jump, i.e. at exactly
// the moment the cue is allowed to disagree with the number.
(:test) function test_cue_c0_numeralStringIsTheRawEstimator(logger) {
    var p = czWorkProbe();
    p.setRate(17.0);
    czRenderAt(p, 0);
    p.setRate(25.0);
    var d = czRenderAt(p, 250);

    var s = czNumeralText(d);
    if (s == null) {
        logger.error("no stroke-rate numeral was drawn at all");
        return false;
    }
    if (!s.equals("25.0")) {
        logger.error("the numeral must show the raw estimator ('25.0'); got '" +
                     s + "' -- the displayed NUMBER has been filtered, which " +
                     "is the one thing the measured result rules out");
        return false;
    }
    return true;
}

// A SUSTAINED out-of-band rate still says so. Lag is free; suppression is not.
// The clock is advanced well past any plausible persistence window, so this
// holds in both epochs and would red if a future edit ever made the cue sticky
// enough to hide a real overshoot.
(:test) function test_cue_c0_sustainedOverspeedStillReadsRed(logger) {
    var p = czWorkProbe();
    p.setRate(25.0);
    // Three frames, not a 250 ms sweep: the frames that matter are the one that
    // starts a pending change and one far past any window it could be waiting
    // on. Rendering the eighty frames in between costs simulator time and pins
    // nothing extra -- the suite is executed headlessly on every pull request.
    czRenderAt(p, 0);
    czRenderAt(p, 250);
    var d = czRenderAt(p, 20000);
    var c = czNumeralColour(d);
    if (c != Gfx.COLOR_RED) {
        logger.error("25.0 spm held for 20 s against a 16-18 band must read " +
                     "red (COLOR_RED = " + Gfx.COLOR_RED + "); got " + c);
        return false;
    }
    return true;
}

// The steady in-band state, which is what the athlete should be looking at for
// most of an interval.
(:test) function test_cue_c0_steadyInBandReadsGreen(logger) {
    var p = czWorkProbe();
    p.setRate(17.0);
    czRenderAt(p, 0);
    czRenderAt(p, 250);
    var d = czRenderAt(p, 20000);
    var c = czNumeralColour(d);
    if (c != Gfx.COLOR_GREEN) {
        logger.error("17.0 spm held inside a 16-18 band must read green " +
                     "(COLOR_GREEN = " + Gfx.COLOR_GREEN + "); got " + c);
        return false;
    }
    return true;
}

// rateColour STAYS MEMORYLESS. The cue is a NEW layer in front of it, not an
// edit to it -- and this is the case that stops the next reader from "simplify-
// ing" the two back together. A Monkey C module-scope var would let a static
// carry state between calls, so this is a reachable regression rather than a
// theoretical one, and it would break every existing RateColourTest case's
// premise at once.
(:test) function test_cue_c0_rateColourIsMemoryless(logger) {
    // Same input, asked twice, with a contradicting input in between.
    var a = StrongRowView.rateColour(true, 25.0, $.CZ_LO, $.CZ_HI);
    for (var i = 0; i < 10; i++) {
        StrongRowView.rateColour(true, 17.0, $.CZ_LO, $.CZ_HI);
    }
    var b = StrongRowView.rateColour(true, 25.0, $.CZ_LO, $.CZ_HI);
    if (a != b) {
        logger.error("rateColour answered " + a + " then " + b + " for the " +
                     "same input -- it has acquired state, and every case in " +
                     "RateColourTest.mc silently depends on it not having any");
        return false;
    }
    return true;
}

// OFF THE WORK STEP THERE IS NO CUE. A rest screen's numeral is white whatever
// the estimator says, and that is unchanged: the instruction only exists while
// there is a target to hold.
(:test) function test_cue_c0_restStepNumeralStaysWhite(logger) {
    var p = new CueProbe();
    p.enterStepLive(p.kindRest(), false);
    p.setSpeed(0.0);
    p.setDist(0.0);
    p.setRate(25.0);
    var d = czRenderAt(p, 0);
    var c = czNumeralColour(d);
    if (c != Gfx.COLOR_WHITE) {
        logger.error("a REST step draws the numeral white whatever the rate " +
                     "(COLOR_WHITE = " + Gfx.COLOR_WHITE + "); got " + c);
        return false;
    }
    return true;
}

// Free row has no band at all, so it has no instruction to give.
(:test) function test_cue_c0_freeRowNumeralStaysWhite(logger) {
    var p = new CueProbe();
    p.setFreeRow();
    p.setSpeed(0.0);
    p.setDist(0.0);
    p.setRate(25.0);
    var d = czRenderAt(p, 0);
    var c = czNumeralColour(d);
    if (c != Gfx.COLOR_WHITE) {
        logger.error("free row draws the numeral white (COLOR_WHITE = " +
                     Gfx.COLOR_WHITE + "); got " + c);
        return false;
    }
    return true;
}

// The no-data state survives. outputRate() returns 0.0 when nothing has been
// measured, drawRate renders that as "--.-", and a dash must never be given an
// instruction colour -- the #86 / #107 defect class (a sentinel rendered as a
// reading), which a cue layer holding a previous zone is a fresh way to
// reintroduce.
(:test) function test_cue_c0_noDataIsADashAndWhite(logger) {
    var p = czWorkProbe();
    p.setRate(17.0);
    czRenderAt(p, 0);
    p.setRate(0.0);
    var d = czRenderAt(p, 250);

    var s = czNumeralText(d);
    var c = czNumeralColour(d);
    if (s == null || !s.equals("--.-")) {
        logger.error("a zero estimator is the no-data state and must render " +
                     "'--.-'; got '" + s + "'");
        return false;
    }
    if (c != Gfx.COLOR_WHITE) {
        logger.error("'--.-' must be white (COLOR_WHITE = " + Gfx.COLOR_WHITE +
                     "), never carrying a colour from the last real reading; " +
                     "got " + c);
        return false;
    }
    return true;
}
