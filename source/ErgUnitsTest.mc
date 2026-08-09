using Toybox.Test;
using Toybox.Graphics as Gfx;
using Toybox.System;
using Toybox.Lang;

// Erg mode: work and power units.
//
// THE MAINTAINER'S REQUEST, and the correction that supersedes half of it.
// "When used on an erg, have the option (default on) to switch to Joules per
// stroke and average watts per interval as units", then: "let us go for work
// over the session instead of power". So the ACCUMULATED quantity is WORK IN
// KILOJOULES, not average watts -- work is the true analogue of the distance
// figure it replaces, because both accumulate over an interval where power is a
// rate. Joules per stroke is unchanged and still wanted.
//
// THE LOAD-BEARING ASSUMPTION, AND IT IS NOT VERIFIED. Nothing in this
// repository has measured whether Activity.Info.currentPower is populated for a
// WATCH APP when a rowing machine is paired. It is plausible -- a machine that
// pairs is probably broadcasting a standard profile -- and it is not measured.
// So the cases here are shaped around the failure, not around the success: the
// question most of them ask first is what the app renders and records when the
// power source is ABSENT.
//
// ABSENCE MUST NEVER RENDER AS ZERO. That is the #86 / #107 defect class this
// repository has already shipped twice, and on this feature it is worse than
// cosmetic: a joules-per-stroke of 0.0 on the right-edge arc maps to the bottom
// of the display range and renders RED, "far below benchmark" -- an actively
// wrong instruction handed to an athlete who has no power meter at all.
//
// EVERYTHING IS INSIDE `module Erg`, and that is a hard constraint rather than
// a style choice. The four fenix6-family devices cap module `globals` at 253
// members and a file-scope declaration costs one each; a `module { }` block
// costs ONE for everything inside it. Measured by bisection for this branch,
// against origin/main at ccac240 with SDK 9.2.0, on fenix6, fenix6pro,
// fenix6spro and fenix6xpro -- all four agree:
//
//     CEILING ccac240 fenix6-family: 242 used of 253, 11 free -- the 12th file-scope (:test) added reds
//
// (N=11 throwaway file-scope (:test) functions BUILD on all four; N=12 reports
// "Found 254 members in module 'globals', exceeding the limit of 253" on all
// four. The limit is inclusive, which is what makes 11 free and the 12th the
// one that reds.)
//
// The simulator prints a module-qualified name for a (:test) inside a module
// block, so scripts/expected_tests.txt carries `Erg.test_erg_...`.
//
// WHAT THESE CASES CANNOT SEE, stated before anything below leans on it.
// HrGeoDc records x, y, font, string and justification for every drawText, so a
// case here can say WHICH elements a screen draws and at what anchor. It cannot
// see a glyph, a text box, an ink extent or an overlap: no font metric is
// available to a (:test) that runs in CI (#121 records that obtaining a real
// graphics Dc segfaults the container's simulator). Nothing here claims any erg
// string is legible or that it clears its neighbours. Where a width matters it
// is bounded in CHARACTERS and said to be a character bound.
//
// Execution note: the run-tests CI job runs these headlessly in the simulator
// on fr965. Test names are pinned in scripts/expected_tests.txt -- update that
// file in the SAME commit as any (:test) change. See docs/CI.md.
module Erg {

// ---------------------------------------------------------------------------
// Helpers. Statics on one class rather than free functions: inside a module
// both are free of the globals budget, and keeping the shape means this file
// could be lifted out of the module without a member audit.
// ---------------------------------------------------------------------------
class EgCase {

    // Did any string this render drew CONTAIN `needle`? Matches the string
    // field only; x, y and font are asserted explicitly where they are the
    // subject and never smuggled into a presence check.
    static function drew(geo, needle) {
        for (var i = 0; i < geo.texts.size(); i++) {
            if (geo.texts[i][3].find(needle) != null) { return true; }
        }
        return false;
    }

    // A REST render with a completed interval latched, so the grid is up.
    //
    // Drives the SHIPPING latch (HrProbe.latchSet -> latchWorkAccum) rather
    // than assigning the mLastSet* fields, so a change to WHAT the latch
    // freezes reds these cases instead of leaving them asserting against their
    // own copy of the answer.
    static function restGrid(p, sec, dist, strokes) {
        var ok = p.latchSet(1, sec, dist, strokes, 1230, 10);
        p.enterStep(p.kindRest(), false);
        var ds = System.getDeviceSettings();
        var geo = new HrGeoDc(ds.screenWidth, ds.screenHeight);
        p.runUpdate(geo);
        return [ok, geo];
    }

    // A free-row render. Free row is where drawPace still runs on the shipping
    // build (#108 stood the pace row down during WORK), so it is the screen the
    // pace-line cases have to use.
    static function freeRowScreen(p) {
        p.setFreeRow();
        var ds = System.getDeviceSettings();
        var geo = new HrGeoDc(ds.screenWidth, ds.screenHeight);
        p.runUpdate(geo);
        p.setWorkoutEnabled(true);
        return geo;
    }

    // A probe with strokes driven through the shipping detector, so
    // outputRate() is non-zero (18.0 spm -- see HrProbe.driveStrokes). Without
    // it every joules-per-stroke case would divide by a zero rate and hold for
    // the wrong reason.
    static function rowing() {
        var p = new HrProbe();
        p.driveStrokes();
        return p;
    }
}

// A probe whose only job is to hand onLayout a stub timer and no ANT channel.
// ViewLifecycleTest's own probe is deliberately not reused: it is a file-scope
// class whose shape belongs to #11, and depending on it would couple this
// suite's correctness to that one's refactors.
class ErgLifeProbe extends StrongRowView {
    hidden var mNext;
    function initialize() { StrongRowView.initialize(); }
    hidden function startSensor() { }
    hidden function startGps()    { }
    function setNextTimer(t) { mNext = t; }
    hidden function makeTimer()      { return mNext; }
    // Null rather than a stub sensor: onLayout only assigns the handle, and
    // nothing these cases drive ever reads it.
    hidden function makeCoreSensor() { return null; }
}

// A stub Timer that records the interval it was armed with. Records FIRST so
// "never called" and "called and threw" stay distinguishable, the rule
// LifeTimer states for the same reason.
class ErgTimer {
    var starts;
    var lastMs;
    var lastRepeat;
    function initialize() { starts = 0; lastMs = 0; lastRepeat = false; }
    function start(cb, ms, repeat) { starts++; lastMs = ms; lastRepeat = repeat; }
    function stop() { }
}

// ===========================================================================
// c0 -- CHARACTERIZATION PINS on symbols that already exist.
//
// Green before this change and green after it. Their job is to record what the
// distance-unit path does TODAY, so that adding a second unit system cannot
// quietly move it.
// ===========================================================================

// The REST grid speaks in metres today, and it says so in its labels. A number
// whose label still says metres is worse than no number, so the LABELS are what
// is pinned rather than the values.
(:test) function test_erg_c0_theRestGridIsLabelledInMetres(logger) {
    var p = EgCase.rowing();
    var r = EgCase.restGrid(p, 240.0, 900.0, 60);
    if (!r[0]) {
        logger.error("the latch did not take, so every assertion below would " +
                     "be vacuous");
        return false;
    }
    var geo = r[1];
    if (!EgCase.drew(geo, "avg m/str")) {
        logger.error("the REST grid must be labelled 'avg m/str' on the " +
                     "shipping distance path");
        return false;
    }
    if (!EgCase.drew(geo, "interval m")) {
        logger.error("the REST grid must be labelled 'interval m' on the " +
                     "shipping distance path");
        return false;
    }
    return true;
}

// The pace line speaks in metres today. Free row is the screen that still
// draws it (#108 stood it down during WORK).
(:test) function test_erg_c0_thePaceLineIsLabelledInMetres(logger) {
    var p = EgCase.rowing();
    p.setSpeed(4.0);
    var geo = EgCase.freeRowScreen(p);
    if (!EgCase.drew(geo, "/500m")) {
        logger.error("free row must draw the /500 m split on the shipping " +
                     "distance path");
        return false;
    }
    if (!EgCase.drew(geo, "m/str")) {
        logger.error("free row must draw the metres-per-stroke term when the " +
                     "speed and the rate are both real");
        return false;
    }
    return true;
}

// THE INVARIANT THE ERG PATH INHERITS, pinned on the arc's existing statics
// before anything new reuses them. A no-data percentage must reach the arc as
// DPSZ_NONE and must not be coloured as a warning: absence is a different KIND
// of answer, not a position at the bottom of the scale.
//
// Recorded at the seam the erg path will be reused THROUGH, rather than only at
// the new code that will call it, because this is the property the feature is
// most likely to break.
(:test) function test_erg_c0_theArcTreatsAbsenceAsItsOwnKind(logger) {
    if (StrongRowView.dpsPct(null, 6.0) != null) {
        logger.error("a null per-stroke figure must stay null");
        return false;
    }
    if (StrongRowView.dpsZone(null) != $.DPSZ_NONE) {
        logger.error("a null percentage must be DPSZ_NONE");
        return false;
    }
    var c = StrongRowView.dpsZoneColour($.DPSZ_NONE);
    if (c == Gfx.COLOR_RED || c == Gfx.COLOR_ORANGE) {
        logger.error("no data must not be coloured as a warning: it is a " +
                     "different KIND of answer, not a reading at the bottom " +
                     "of the range");
        return false;
    }
    return true;
}

// THE TICK PERIOD, because the work accumulator integrates against it and an
// accumulator keyed on the wrong period is wrong by exactly that ratio with
// nothing on screen to say so. Pinned at the CALL SITE -- what onLayout arms
// the timer with -- and not at a constant, so a change to either one reds.
(:test) function test_erg_c0_theTickPeriodIsTwoHundredAndFiftyMs(logger) {
    var p = new ErgLifeProbe();
    var t = new ErgTimer();
    p.setNextTimer(t);
    p.onLayout(null as Gfx.Dc);
    if (t.starts != 1) {
        logger.error("onLayout must arm exactly one timer; it armed " + t.starts);
        return false;
    }
    if (t.lastMs != 250) {
        logger.error("the tick period is the divisor of every time-integrated " +
                     "quantity in this app. onLayout armed the timer at " +
                     t.lastMs + " ms, not 250");
        return false;
    }
    if (!t.lastRepeat) {
        logger.error("the tick timer must repeat");
        return false;
    }
    return true;
}

} // module Erg
