using Toybox.Test;
using Toybox.Graphics as Gfx;
using Toybox.System;
using Toybox.Activity;
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

// ===========================================================================
// c1 -- THE NEW DECISIONS, as pure statics, pinned where they stand.
//
// Every case below is GREEN the moment the statics exist. None of them says
// anything about the display or about the FIT: those are call sites, they are
// c2's differentials, and conflating "the function is right" with "the call
// site uses it" is how a repository ends up with a green suite over a broken
// screen.
// ===========================================================================

// joulesPerStroke: watts * 60 / rate, checked against hand-computed values.
//
// 150 W at 18.0 spm is 3.3333 s per stroke, so 500 J. 200 W at 20 spm is 600 J.
// Both are arithmetic anyone can redo from the two numbers in the call.
(:test) function test_erg_c1_joulesPerStrokeIsPowerOverCadence(logger) {
    var a = StrongRowView.joulesPerStroke(150.0, 18.0);
    if (a == null || (a - 500.0).abs() > 0.001) {
        logger.error("150 W at 18 spm is 500 J/stroke; got " + a);
        return false;
    }
    var b = StrongRowView.joulesPerStroke(200.0, 20.0);
    if (b == null || (b - 600.0).abs() > 0.001) {
        logger.error("200 W at 20 spm is 600 J/stroke; got " + b);
        return false;
    }
    return true;
}

// THE PRIMARY RISK OF THE WHOLE FEATURE, at the function that decides it.
//
// A missing power source must be NULL, never 0.0, because dpsPct maps a small
// per-stroke figure to the bottom of the arc and dpsZoneColour paints that RED
// -- "far below benchmark", which on a watch with no power meter at all is an
// instruction to row harder in response to nothing.
//
// The chain is asserted END TO END through the shipping statics rather than
// stopping at the null, because the null on its own is not the harm.
(:test) function test_erg_c1_anAbsentPowerSourceIsNullAndNeverFarBelow(logger) {
    var probes = [ null, -1.0, -0.001 ];
    for (var i = 0; i < probes.size(); i++) {
        var j = StrongRowView.joulesPerStroke(probes[i], 18.0);
        if (j != null) {
            logger.error("watts " + probes[i] + " must give a NULL " +
                         "joules-per-stroke, not " + j);
            return false;
        }
        var pct = StrongRowView.dpsPct(j, 400.0);
        if (pct != null) {
            logger.error("an absent joules-per-stroke must not become a " +
                         "percentage: got " + pct);
            return false;
        }
        var col = StrongRowView.dpsZoneColour(StrongRowView.dpsZone(pct));
        if (col == Gfx.COLOR_RED || col == Gfx.COLOR_ORANGE) {
            logger.error("watts " + probes[i] + " reached the arc as a " +
                         "WARNING colour. A watch with no power meter would " +
                         "be told to row harder in response to nothing -- the " +
                         "#86/#107 class with an instruction attached");
            return false;
        }
    }
    // ... and a missing or impossible RATE is absent too, for the same reason.
    if (StrongRowView.joulesPerStroke(150.0, 0.0)  != null) { logger.error("zero rate"); return false; }
    if (StrongRowView.joulesPerStroke(150.0, null) != null) { logger.error("null rate"); return false; }
    if (StrongRowView.joulesPerStroke(150.0, -5.0) != null) { logger.error("negative rate"); return false; }
    return true;
}

// A REAL ZERO IS NOT ABSENCE, and the two must stay distinguishable at the
// function that produces them. Zero watts is a legal reading on an erg, so
// joulesPerStroke returns a faithful 0.0 for it -- and it is dpsPct's existing
// `<= 0.0` rule, not this function, that turns the arc grey. Pinned so a later
// "simplification" that made 0 W return null could not be mistaken for a
// no-op.
(:test) function test_erg_c1_zeroWattsIsAReadingAndAbsenceIsNot(logger) {
    var z = StrongRowView.joulesPerStroke(0.0, 18.0);
    if (z == null) {
        logger.error("0 W at a real stroke rate is a READING of 0.0 J/stroke, " +
                     "not an absence -- an erg reports zero watts on every " +
                     "recovery");
        return false;
    }
    if (z != 0.0) {
        logger.error("0 W at 18 spm is 0.0 J/stroke; got " + z);
        return false;
    }
    if (StrongRowView.joulesPerStroke(null, 18.0) != null) {
        logger.error("no power source must still be null");
        return false;
    }
    return true;
}

// The unit-selection predicate, over its whole truth table. ergPowerUnits
// defaults ON and must mean nothing outside erg mode -- that is the
// maintainer's own shape and it is one AND in one place.
(:test) function test_erg_c1_theUnitToggleOnlyMattersInsideErgMode(logger) {
    if (StrongRowView.useWorkUnits(true, true) != true) {
        logger.error("erg mode + work units must select work units");
        return false;
    }
    if (StrongRowView.useWorkUnits(true, false) != false) {
        logger.error("erg mode with the toggle off must stay in distance units");
        return false;
    }
    if (StrongRowView.useWorkUnits(false, true) != false) {
        logger.error("the toggle defaults ON, so it MUST mean nothing outside " +
                     "erg mode -- otherwise every water row would ship in " +
                     "joules the first time this lands");
        return false;
    }
    if (StrongRowView.useWorkUnits(false, false) != false) {
        logger.error("neither on must be distance units");
        return false;
    }
    return true;
}

// A corrupted property must not be read as a toggle the athlete set. Properties
// survive an app update and a .set file is not re-clamped on load (#21), so a
// non-Boolean arriving in a Boolean setting is a real state.
//
// THIS CASE ALREADY EARNED ITS KEEP. ergFlag was first written as
// `if (v == true) ... if (v == false) ... return dflt`, which READS as an exact
// match and is not one: this case red with "junk 0 must fall back to the TRUE
// default", which is how the repository learned that `0 == false` evaluates
// TRUE in Monkey C (SDK 9.2.0, fr965, in the CI container). The shipping form
// is an `instanceof Lang.Boolean` test.
(:test) function test_erg_c1_aCorruptedToggleFallsBackToItsDefault(logger) {
    var junk = [ null, 0, 1, "true", "false", -1 ];
    for (var i = 0; i < junk.size(); i++) {
        if (StrongRowView.ergFlag(junk[i], false) != false) {
            logger.error("junk " + junk[i] + " must fall back to the FALSE default");
            return false;
        }
        if (StrongRowView.ergFlag(junk[i], true) != true) {
            logger.error("junk " + junk[i] + " must fall back to the TRUE default");
            return false;
        }
        // The predicate must be TOTAL: no input may make it throw.
        if (StrongRowView.useWorkUnits(junk[i], junk[i]) != false) {
            logger.error("a corrupted pair must select distance units, not " +
                         "throw and not select work units");
            return false;
        }
    }
    return true;
}

// The integrator: N ticks at W watts is W * N * TICK_MS/1000 joules.
//
// Keyed on $.TICK_MS rather than on 250, so the arithmetic here and the timer
// onLayout arms (pinned in c0) cannot drift apart into two different beliefs
// about the same clock.
(:test) function test_erg_c1_theWorkIntegratorIsPowerTimesTime(logger) {
    var j = 0.0;
    for (var i = 0; i < 240; i++) {
        j = StrongRowView.workAccumStep(j, 100.0, $.TICK_MS);
    }
    // 240 ticks of 250 ms is 60 s; 100 W for 60 s is 6000 J.
    if ((j - 6000.0).abs() > 0.001) {
        logger.error("100 W integrated over 240 ticks of " + $.TICK_MS +
                     " ms must be 6000 J; got " + j);
        return false;
    }
    if ((StrongRowView.setWorkKJ(j, true) - 6.0).abs() > 0.001) {
        logger.error("6000 J is 6.0 kJ; got " + StrongRowView.setWorkKJ(j, true));
        return false;
    }
    return true;
}

// A MISSING SAMPLE CONTRIBUTES NOTHING AND DOES NOT COUNT AS A SAMPLE. The
// second half is the one that matters: an accumulator that absorbed nulls would
// still read 0.0 J, and 0.0 J with `ever` true is an athlete who did no work,
// which is a different claim from an athlete with no power meter.
(:test) function test_erg_c1_aMissingSampleNeitherAddsNorCounts(logger) {
    var j = 0.0;
    var ever = false;
    var bad = [ null, -1.0 ];
    for (var i = 0; i < bad.size(); i++) {
        j    = StrongRowView.workAccumStep(j, bad[i], $.TICK_MS);
        ever = StrongRowView.workEverAfter(ever, bad[i]);
    }
    if (j != 0.0) {
        logger.error("absent samples must add nothing; got " + j);
        return false;
    }
    if (ever != false) {
        logger.error("absent samples must not make the interval claim a " +
                     "measurement -- that is what turns 0.0 kJ from 'no power " +
                     "meter' into 'no work done'");
        return false;
    }
    if (StrongRowView.setWorkKJ(j, ever) != null) {
        logger.error("an interval with no samples must render as ABSENT, not " +
                     "as 0.0 kJ");
        return false;
    }
    if (StrongRowView.setAvgJps(j, 60, ever) != null) {
        logger.error("an interval with no samples has no average J/stroke");
        return false;
    }
    // And a REAL zero-watt sample DOES count, because it is a measurement.
    var e2 = StrongRowView.workEverAfter(false, 0.0);
    if (e2 != true) {
        logger.error("0 W is a measurement and must set the ever flag");
        return false;
    }
    if (StrongRowView.setWorkKJ(0.0, e2) != 0.0) {
        logger.error("an interval measured at zero work must render 0.0 kJ, " +
                     "not a dash -- that is a claim the file can support");
        return false;
    }
    return true;
}

// The two rest-grid cells, against hand-computed values, and their null rules.
(:test) function test_erg_c1_theRestCellsMatchHandComputedValues(logger) {
    // A 4:00 interval at 125 W is 30 000 J = 30.0 kJ; at 64 strokes that is
    // 468.75 J/stroke.
    var kj = StrongRowView.setWorkKJ(30000.0, true);
    if (kj == null || (kj - 30.0).abs() > 0.0001) {
        logger.error("30 000 J must render 30.0 kJ; got " + kj);
        return false;
    }
    var jps = StrongRowView.setAvgJps(30000.0, 64, true);
    if (jps == null || (jps - 468.75).abs() > 0.0001) {
        logger.error("30 000 J over 64 strokes is 468.75 J/stroke; got " + jps);
        return false;
    }
    if (StrongRowView.setAvgJps(30000.0, 0, true) != null) {
        logger.error("no strokes means no average");
        return false;
    }
    if (StrongRowView.setAvgJps(null, 64, true) != null) {
        logger.error("null joules means no average");
        return false;
    }
    return true;
}

// The pace row's string, including its absence form and its character bound.
//
// CHARACTERS, NOT PIXELS. #121 records that no (:test) running in CI can obtain
// a font metric, so this bound is a character bound and is not a clearance --
// the pixel measurement is a [Local] one.
(:test) function test_erg_c1_thePaceStringSaysDashesAndStaysBounded(logger) {
    var s = StrongRowView.paceWorkStr(null, null);
    if (s.find("--W") == null || s.find("--J/str") == null) {
        logger.error("with no power source the pace row must say '--W  " +
                     "--J/str'; got '" + s + "'");
        return false;
    }
    if (s.find("0W") != null) {
        logger.error("absence must never render as a zero: got '" + s + "'");
        return false;
    }
    var t = StrongRowView.paceWorkStr(149.6, 499.5);
    if (t.find("150W") == null || t.find("500J/str") == null) {
        logger.error("the pace row rounds rather than truncating; got '" + t + "'");
        return false;
    }
    // The widest string the clamps allow: "9999W  9999J/str" -- 16 characters.
    var wide = StrongRowView.paceWorkStr(999999.0, 999999.0);
    if (wide.length() != 16) {
        logger.error("the clamped pace string must be 16 characters; '" +
                     wide + "' is " + wide.length());
        return false;
    }
    return true;
}

// The FIT encodings. A field that LATCHES cannot express absence by silence, so
// absence has to be a VALUE -- and the value has to be one a real reading can
// never take. Zero watts is a real reading on an erg, so the sentinel is
// negative; this is lock_confidence's argument, not lock_rate's.
(:test) function test_erg_c1_absenceIsEncodedOutOfBandNotAsZero(logger) {
    if (StrongRowView.ergPowerOf(null) != $.ERG_POWER_NONE) {
        logger.error("no power source must encode as ERG_POWER_NONE");
        return false;
    }
    if ($.ERG_POWER_NONE >= 0.0) {
        logger.error("the power sentinel must be OUT OF BAND. Power is " +
                     "non-negative by construction, so only a negative value " +
                     "cannot collide with a reading");
        return false;
    }
    if (StrongRowView.ergPowerOf(0.0) != 0.0) {
        logger.error("0 W is a reading and must be recorded verbatim, not as " +
                     "the sentinel -- an erg reports zero on every recovery");
        return false;
    }
    if (StrongRowView.ergJpsOf(null) != $.ERG_JPS_NONE) {
        logger.error("no joules-per-stroke must encode as ERG_JPS_NONE");
        return false;
    }
    if ($.ERG_JPS_NONE >= 0.0) {
        logger.error("the joules sentinel must be out of band for the same " +
                     "reason: 0 W at a real rate is 0.0 J/stroke");
        return false;
    }
    if (StrongRowView.ergJpsOf(0.0) != 0.0) {
        logger.error("0.0 J/stroke is a reading");
        return false;
    }
    return true;
}

// The instrumentation word. Two bits per source, because "populated and zero"
// and "not populated" are exactly the two states this field exists to separate.
(:test) function test_erg_c1_theDiagnosticSeparatesZeroFromAbsent(logger) {
    var absent  = StrongRowView.ergDiagBits([null, null, null, null], false, false);
    var zeroes  = StrongRowView.ergDiagBits([0.0, 0.0, 0.0, 0], false, false);
    var live    = StrongRowView.ergDiagBits([150.0, 4.2, 900.0, 22], true, true);

    if (absent != $.ERGD_ALIVE) {
        logger.error("with nothing populated the word must be ALIVE alone; " +
                     "got " + absent);
        return false;
    }
    if ((zeroes & $.ERGD_PWR_OK) == 0) {
        logger.error("a broadcast ZERO is populated and must set the OK bit -- " +
                     "otherwise the first session cannot tell a machine that " +
                     "reports 0 W from one that reports nothing");
        return false;
    }
    if ((zeroes & $.ERGD_PWR_POS) != 0) {
        logger.error("a broadcast zero must not set the POSITIVE bit");
        return false;
    }
    if ((absent & $.ERGD_PWR_OK) != 0) {
        logger.error("an absent power must not set the OK bit");
        return false;
    }
    var want = $.ERGD_ALIVE | $.ERGD_PWR_OK | $.ERGD_PWR_POS |
               $.ERGD_SPD_OK | $.ERGD_SPD_POS | $.ERGD_DST_OK | $.ERGD_DST_POS |
               $.ERGD_CAD_OK | $.ERGD_CAD_POS | $.ERGD_ERGMODE | $.ERGD_WORKUNI;
    if (live != want) {
        logger.error("a fully populated erg tick must be " + want +
                     "; got " + live);
        return false;
    }
    return true;
}

// THE WRITTEN VALUE CAN NEVER BE MISTAKEN FOR AN UNWRITTEN ONE. A UINT16 field
// that was never set carries 0xFFFF; the ALIVE bit keeps every written value
// away from 0x0000, and the reserved band 0x0400..0x4000 keeps it away from
// 0xFFFF. Both halves are asserted over the whole reachable value set, so
// widening the bit set into the reserved band reds here rather than in a decode
// six months later.
(:test) function test_erg_c1_theDiagnosticWordIsNeverTheInvalidPattern(logger) {
    var srcs = [ [null, null, null, null], [0.0, 0.0, 0.0, 0],
                 [1.0, 1.0, 1.0, 1] ];
    for (var i = 0; i < srcs.size(); i++) {
        for (var m = 0; m < 4; m++) {
            var b = StrongRowView.ergDiagBits(srcs[i], (m & 1) != 0, (m & 2) != 0);
            if (b == 0) {
                logger.error("a written diagnostic word must never be 0x0000");
                return false;
            }
            if (b == 0xFFFF) {
                logger.error("a written diagnostic word must never be 0xFFFF -- " +
                             "that is the UINT16 never-set invalid pattern");
                return false;
            }
            if (b > $.ERGD_MAX) {
                logger.error("the word " + b + " has escaped the reserved band; " +
                             "ERGD_MAX is " + $.ERGD_MAX + " and the argument " +
                             "that a written value cannot be 0xFFFF rests on it");
                return false;
            }
            if ((b & $.ERGD_ALIVE) == 0) {
                logger.error("the ALIVE bit must be set on every written word");
                return false;
            }
        }
    }
    return true;
}

// The sub-sport VALUE. Whether startSession passes it to Rec.createSession is
// review-only -- no (:test) can obtain a Session -- and what a decoder renders
// is a [Local] question. This case is about the value alone and says so.
(:test) function test_erg_c1_ergModeChoosesTheIndoorRowingSubSport(logger) {
    if (StrongRowView.subSportFor(true) != Activity.SUB_SPORT_INDOOR_ROWING) {
        logger.error("erg mode must declare SUB_SPORT_INDOOR_ROWING");
        return false;
    }
    if (StrongRowView.subSportFor(false) != Activity.SUB_SPORT_GENERIC) {
        logger.error("off the erg the sub-sport must be unchanged");
        return false;
    }
    if (Activity.SUB_SPORT_INDOOR_ROWING == Activity.SUB_SPORT_GENERIC) {
        logger.error("the two sub-sports must be distinct, or the case above " +
                     "is vacuous");
        return false;
    }
    return true;
}

// The benchmark's clamp, applied IN CODE and not only in settings.xml (#21).
// Driven through the shipping loadSettings clamp by way of the probe seam, so
// a case can never assert against a value loadSettings would have refused.
(:test) function test_erg_c1_theJouleBenchmarkIsClampedInCode(logger) {
    var p = new HrProbe();
    p.setJouleBench(0.0);
    if (p.jouleBench() != $.JOULE_BENCH_MIN) {
        logger.error("a zero benchmark must clamp to " + $.JOULE_BENCH_MIN +
                     "; got " + p.jouleBench());
        return false;
    }
    p.setJouleBench(999999.0);
    if (p.jouleBench() != $.JOULE_BENCH_MAX) {
        logger.error("an absurd benchmark must clamp to " + $.JOULE_BENCH_MAX +
                     "; got " + p.jouleBench());
        return false;
    }
    p.setJouleBench($.JOULE_BENCH_DEF);
    if (p.jouleBench() != $.JOULE_BENCH_DEF) {
        logger.error("the shipped default must survive the clamp untouched");
        return false;
    }
    // A benchmark of zero would make dpsPct return null for EVERY reading, so
    // the low clamp is what keeps the arc from silently going dark.
    if (StrongRowView.dpsPct(400.0, $.JOULE_BENCH_MIN) == null) {
        logger.error("the clamped low end must still produce a percentage");
        return false;
    }
    return true;
}

} // module Erg
