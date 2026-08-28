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
// AND WITH THIS FILE IN THE TREE, re-bisected on fenix6 the same way -- N=10
// BUILDS, N=11 reports 254:
//
//     CEILING erg-branch fenix6: 243 used of 253, 10 free -- the 11th file-scope (:test) added reds
//
// RE-BISECTED AGAIN after the review revision, which added eight (:test)
// functions to this file and four file-scope `const` declarations to
// source/StrongRowView.mc. N=10 BUILDS, N=11 reports 254 -- the SAME figures:
//
//     CEILING erg-r5 fenix6: 243 used of 253, 10 free -- the 11th file-scope (:test) added reds
//
// That the number did not move is itself the measurement, and it is worth
// stating because it is not obvious: nothing was REMOVED at file scope, so the
// four new `const`s cost ZERO `globals` members on SDK 9.2.0. Consts are not
// what this budget counts; functions, classes and modules at file scope are.
// The eight new cases cost nothing because they are inside the module block.
//
// ONE member for THIRTY-EIGHT (:test) functions plus five classes, which is the
// module's whole justification stated as arithmetic rather than as a principle:
// 243 - 242 = 1. At file scope the same declarations would need 43 and the
// build would fail on all four fenix6-family devices with an error naming
// neither the test nor the file, while fr965 (which run-tests uses) and
// release-build stayed green -- so a green local run would prove nothing.
//
// AN EARLIER REVISION OF THIS PARAGRAPH SAID TWENTY-NINE, FOUR AND 33. All
// three were wrong on the day they were written, in the commit whose stated
// purpose was to make "one member" arithmetic rather than a claim: the file has
// held 30 tests and 5 classes since f70110f. Reproduce both counts rather than
// trusting this sentence:
//
//     python3 scripts/list_tests.py | grep -c '^Erg\.'      -> 38
//     grep -c '^class ' source/ErgUnitsTest.mc              -> 5
//     242 + 43 = 285 > 253
//
// scripts/check_ceiling_notes.py cannot catch this class of error -- it parses
// only the two CEILING lines above, whose own arithmetic closes and always did.
// That gap is the one its docstring describes.
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

    // The same, already in erg mode with work units selected and the shipped
    // default benchmark.
    static function onErg() {
        var p = rowing();
        p.setErgMode(true);
        p.setErgUnits(true);
        p.setJouleBench($.JOULE_BENCH_DEF);
        return p;
    }

    // Did any string this render drew EQUAL `s`? Used for cell VALUES, where
    // "contains" would match a substring of a neighbouring number and a dash
    // check would match any dash on the screen.
    static function drewExact(geo, s) { return countExact(geo, s) > 0; }

    static function countExact(geo, s) {
        var n = 0;
        for (var i = 0; i < geo.texts.size(); i++) {
            if (geo.texts[i][3].equals(s)) { n++; }
        }
        return n;
    }

    // A COMPLETED WORK INTERVAL, driven through the SHIPPING tick.
    //
    // The whole point is that the interval's joules come from onTick and not
    // from an assignment: `ticks` calls to the real onTick at `watts`, inside a
    // live WORK step opened by the real beginWorkAccum, then the real
    // latchWorkAccum by way of HrProbe.latchSet. Nothing here transcribes the
    // accumulator's arithmetic.
    //
    // latchSet does not touch the work accumulator, so the joules that
    // accumulated above survive into the latch -- which is exactly the shipping
    // order of events (the interval accumulates, then it is frozen).
    //
    // Returns [latchTook, geo] with the view left on the REST screen, so the
    // grid is up.
    static function ergInterval(p, watts, ticks, sec, dist, strokes) {
        p.enterStepLive(p.kindWork(), false);
        p.beginWork(1);
        p.setPower(watts);
        for (var i = 0; i < ticks; i++) { p.runTick(); }
        var ok = p.latchSet(1, sec, dist, strokes, 1230, 10);
        p.enterStep(p.kindRest(), false);
        var ds = System.getDeviceSettings();
        var geo = new HrGeoDc(ds.screenWidth, ds.screenHeight);
        p.runUpdate(geo);
        return [ok, geo];
    }

    // The same, but with the power source DROPPING IN AND OUT -- the state no
    // case in this suite could previously reach. ergInterval sets the power
    // once before the loop, so every interval it builds is 0% or 100% covered,
    // and the whole band between them was untested while being the band an
    // unmeasured ANT link is most likely to occupy.
    //
    // INTERLEAVED IN BLOCKS OF FOUR rather than one long live run followed by
    // one long dead one, so nothing can pass because the samples happened to be
    // contiguous.
    static function ergIntervalPartial(p, watts, onTicks, offTicks, sec, dist,
                                       strokes) {
        p.enterStepLive(p.kindWork(), false);
        p.beginWork(1);
        var on = onTicks;
        var off = offTicks;
        while (on > 0 || off > 0) {
            for (var i = 0; i < 4 && on > 0; i++) {
                p.setPower(watts); p.runTick(); on--;
            }
            for (var k = 0; k < 4 && off > 0; k++) {
                p.setPower(null); p.runTick(); off--;
            }
        }
        var ok = p.latchSet(1, sec, dist, strokes, 1230, 10);
        p.enterStep(p.kindRest(), false);
        var ds = System.getDeviceSettings();
        var geo = new HrGeoDc(ds.screenWidth, ds.screenHeight);
        p.runUpdate(geo);
        return [ok, geo];
    }

    // The REC footer's string, or null if the footer is not in that state.
    // Named by its prefix rather than taken as "the last text drawn", so a
    // later element added after drawFoot cannot silently turn this into an
    // assertion about something else.
    static function recFoot(geo) {
        for (var i = 0; i < geo.texts.size(); i++) {
            var s = geo.texts[i][3];
            if (s.length() >= 4 && s.substring(0, 4).equals("REC ")) {
                return s;
            }
        }
        return null;
    }

    // A re-render of whatever state the probe is already in.
    static function reRender(p) {
        var ds = System.getDeviceSettings();
        var geo = new HrGeoDc(ds.screenWidth, ds.screenHeight);
        p.runUpdate(geo);
        return geo;
    }
}

// A recording stand-in for a FitContributor field handle. CueFix.Field has the
// same shape and is deliberately not reused here: this suite also needs the
// full write HISTORY (a record-scope field that LATCHES is only honest if it is
// written on every tick, which is a claim about the count and not only about
// the last value), and widening another suite's stub to carry it would make
// that suite's cases noisier for something they never read.
class ErgField {
    var vals;
    function initialize() { vals = []; }
    function setData(v) { vals.add(v); }
    function last() { return (vals.size() == 0) ? null : vals[vals.size() - 1]; }
    function count() { return vals.size(); }
}

// A duck-typed stand-in for an ActivityRecording.Session. stopAndSave calls
// exactly these three on the handle; nothing else is needed and nothing else is
// provided, so a future call to a fourth surfaces as a missing member rather
// than as a silent pass.
class ErgSession {
    var saves;
    var stops;
    function initialize() { saves = 0; stops = 0; }
    function isRecording() { return true; }
    function stop() { stops++; }
    function save() { saves++; }
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
// still read 0.0 J, and 0.0 J with a non-zero count is an athlete who did no
// work, which is a different claim from an athlete with no power meter.
(:test) function test_erg_c1_aMissingSampleNeitherAddsNorCounts(logger) {
    var j = 0.0;
    var n = 0;
    var bad = [ null, -1.0 ];
    for (var i = 0; i < bad.size(); i++) {
        j = StrongRowView.workAccumStep(j, bad[i], $.TICK_MS);
        n = StrongRowView.workCountAfter(n, bad[i]);
    }
    if (j != 0.0) {
        logger.error("absent samples must add nothing; got " + j);
        return false;
    }
    if (n != 0) {
        logger.error("absent samples must not make the interval claim a " +
                     "measurement -- that is what turns 0.0 kJ from 'no power " +
                     "meter' into 'no work done'. The count is " + n);
        return false;
    }
    if (StrongRowView.setWorkKJ(j, n > 0) != null) {
        logger.error("an interval with no samples must render as ABSENT, not " +
                     "as 0.0 kJ");
        return false;
    }
    if (StrongRowView.setAvgJps(j, 60, n > 0) != null) {
        logger.error("an interval with no samples has no average J/stroke");
        return false;
    }
    // And a REAL zero-watt sample DOES count, because it is a measurement.
    var n2 = StrongRowView.workCountAfter(0, 0.0);
    if (n2 != 1) {
        logger.error("0 W is a measurement and must be counted; got " + n2);
        return false;
    }
    // MONOTONIC: a later absence never lowers the count, which is the property
    // the boolean's "latches true" used to carry.
    if (StrongRowView.workCountAfter(n2, null) != 1) {
        logger.error("a later absence must not lower the sample count");
        return false;
    }
    if (StrongRowView.setWorkKJ(0.0, n2 > 0) != 0.0) {
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
//
// DRIVEN THROUGH THE SHIPPING jouleClampBench, WHICH loadSettings CALLS. The
// header here used to say "driven through the shipping loadSettings clamp by
// way of the probe seam", and that route did not exist: HrProbe.setJouleBench
// re-implemented the comparison inline, so this case pinned the probe's private
// copy. MEASURED: deleting both clamp lines from loadSettings left all 308
// cases green (CI container, fr965). Extracting the static and routing both
// callers through it is what turned that mutant red.
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

// THE COVERAGE FLOOR, AND THE DERIVATION OF ITS VALUE.
//
// An integral of instantaneous samples is under-reported by exactly the
// fraction of the interval its source was down, and nothing about the number
// says so. workCoverOk is what refuses to show such a total; WORK_COVER_MIN is
// where the threshold comes from, and this case pins the DERIVATION rather than
// the digits: 0.85 is DPS_FAR_PCT / 100, so an interval that clears the floor
// can be under-reported by at most 15% and a reading that was AT the benchmark
// cannot be pushed into FAR. That last sentence is asserted through the
// shipping dpsZone rather than restated.
(:test) function test_erg_c1_theCoverageFloorIsTheArcsOwnFarBoundary(logger) {
    // 240 s at a 250 ms tick is 960 samples for full coverage.
    if (!StrongRowView.workCoverOk(960, 240.0, $.TICK_MS)) {
        logger.error("an interval every one of whose ticks carried a sample " +
                     "must be covered");
        return false;
    }
    // 85% of 960 is 816 -- the boundary, which is INSIDE the floor.
    if (!StrongRowView.workCoverOk(816, 240.0, $.TICK_MS)) {
        logger.error("coverage exactly at the floor must be accepted");
        return false;
    }
    if (StrongRowView.workCoverOk(815, 240.0, $.TICK_MS)) {
        logger.error("coverage below the floor must be refused -- the total " +
                     "is under-reported and nothing on screen says so");
        return false;
    }
    // 75%, the case the finding named: 720 of 960 samples.
    if (StrongRowView.workCoverOk(720, 240.0, $.TICK_MS)) {
        logger.error("a quarter of the interval with no power sample must " +
                     "NOT be presented as the interval's work");
        return false;
    }
    // Absence, and an unanswerable question, are both refusals.
    if (StrongRowView.workCoverOk(0, 240.0, $.TICK_MS)
            || StrongRowView.workCoverOk(null, 240.0, $.TICK_MS)
            || StrongRowView.workCoverOk(960, 0.0, $.TICK_MS)
            || StrongRowView.workCoverOk(960, null, $.TICK_MS)) {
        logger.error("no samples, or no duration to judge them against, must " +
                     "never be 'covered'");
        return false;
    }
    // THE DERIVATION, through the shipping zone decision. At the floor an
    // athlete exactly on benchmark reads DPS_FAR_PCT, and dpsZone's boundaries
    // are inclusive upward -- so that is UNDER, not FAR. This is the whole
    // reason the number is 0.85 and not a round guess.
    var worst = 100.0 * $.WORK_COVER_MIN;
    if (StrongRowView.dpsZone(worst) != $.DPSZ_UNDER) {
        logger.error("the worst under-report a covered interval allows is " +
                     worst + "% of benchmark, which must NOT be the FAR zone " +
                     "-- otherwise the floor does not buy what it claims");
        return false;
    }
    if (StrongRowView.dpsZone(worst - 0.01) != $.DPSZ_FAR) {
        logger.error("just below the floor's worst case must be FAR, or the " +
                     "assertion above is vacuous");
        return false;
    }
    return true;
}

// THE KILOJOULE CELL'S WIDTH IS ENFORCED, NOT ASSUMED.
//
// The grid's format table claimed this cell was never wider than the "18000"
// it replaces, on an assumed maximum of "999.9". settings.xml allows a
// 60-minute work interval, and 60 minutes at 278 W is 1 000 800 J -- "1000.8",
// six characters. gridKjStr drops the tenth at 1000 kJ instead, which is where
// it stops being useful resolution, so the bound is five characters and is
// enforced rather than hoped for.
//
// CHARACTERS, NOT PIXELS (#121). This is a character bound.
(:test) function test_erg_c1_theKilojouleCellIsBoundedToFiveCharacters(logger) {
    if (!StrongRowView.gridKjStr(1.2).equals("1.2")) {
        logger.error("an ordinary interval keeps its tenth; got '" +
                     StrongRowView.gridKjStr(1.2) + "'");
        return false;
    }
    if (!StrongRowView.gridKjStr(999.9).equals("999.9")) {
        logger.error("the widest tenths form must be '999.9'; got '" +
                     StrongRowView.gridKjStr(999.9) + "'");
        return false;
    }
    // THE ROUNDING BOUNDARY, which the sweep below found: "%.1f" on 999.96 is
    // "1000.0", six characters, so the switch point is 999.95 and not 1000.0.
    if (!StrongRowView.gridKjStr(999.96).equals("1000")) {
        logger.error("999.96 must switch format rather than round up into a " +
                     "sixth character; got '" +
                     StrongRowView.gridKjStr(999.96) + "'");
        return false;
    }
    // 60 minutes at 278 W, the case the claimed bound could not survive.
    if (!StrongRowView.gridKjStr(1000.8).equals("1001")) {
        logger.error("at and above 1000 kJ the tenth is dropped, so a " +
                     "60-minute interval at 278 W renders '1001'; got '" +
                     StrongRowView.gridKjStr(1000.8) + "'");
        return false;
    }
    if (!StrongRowView.gridKjStr(1.0e9).equals("9999")) {
        logger.error("an absurd total must clamp to " + $.GRID_KJ_MAX +
                     "; got '" + StrongRowView.gridKjStr(1.0e9) + "'");
        return false;
    }
    if (!StrongRowView.gridKjStr(null).equals("--")) {
        logger.error("absence is a dash, never a number");
        return false;
    }
    // The bound itself, swept rather than argued. Five characters is exactly
    // the width of the "18000" this cell replaces.
    var probe = [ 0.0, 0.05, 9.99, 99.99, 999.94, 999.96, 1000.0, 9998.6,
                  1.0e9 ];
    for (var i = 0; i < probe.size(); i++) {
        var s = StrongRowView.gridKjStr(probe[i]);
        if (s.length() > 5) {
            logger.error("gridKjStr(" + probe[i] + ") is '" + s + "', " +
                         s.length() + " characters -- the cell it replaces is " +
                         "five");
            return false;
        }
    }
    // And the per-stroke cell shares the pace row's clamp, so it is four.
    if (!StrongRowView.ergNum(1.0e9, $.GRID_J_MAX).equals("9999")) {
        logger.error("the per-stroke cell must clamp at " + $.GRID_J_MAX);
        return false;
    }
    return true;
}

// THE FOOTER'S DISTANCE TOKEN. A zero here is a fabricated measurement with a
// unit label on a glance surface, which is the #86/#107 class -- and on an erg
// elapsedDistance may have no source at all.
//
// GATED ON ERG MODE, NOT ON THE UNITS TOGGLE, and that is asserted in both
// directions: kilometres are kilometres whichever units the arc shows, so what
// decides this is whether a distance SOURCE plausibly exists.
(:test) function test_erg_c1_theFooterDistanceDashesWhenTheSourceMayBeAbsent(logger) {
    if (!StrongRowView.footDistStr(0.0, true).equals("--")) {
        logger.error("on an erg a zero distance must be a dash, not " +
                     "'0.00km' -- there may be no distance source at all");
        return false;
    }
    if (!StrongRowView.footDistStr(null, false).equals("--")) {
        logger.error("a null distance is a dash in every mode");
        return false;
    }
    // OFF the erg the shipping behaviour is untouched, including the zero.
    if (!StrongRowView.footDistStr(0.0, false).equals("0.00km")) {
        logger.error("off the erg the footer is unchanged; got '" +
                     StrongRowView.footDistStr(0.0, false) + "'");
        return false;
    }
    // SELF-HEALING: a machine that DOES broadcast distance gets its km back.
    if (!StrongRowView.footDistStr(1234.0, true).equals("1.23km")
            || !StrongRowView.footDistStr(1234.0, false).equals("1.23km")) {
        logger.error("a real distance renders identically in both modes");
        return false;
    }
    // A corrupted setting must not throw here any more than at useWorkUnits:
    // the gate goes through ergFlag, so a non-Boolean is the default (false).
    if (!StrongRowView.footDistStr(0.0, 0).equals("0.00km")) {
        logger.error("a corrupted ergMode must fall back to the off default, " +
                     "not throw");
        return false;
    }
    return true;
}

// THE CADENCE ENCODING. 0 spm is what a stationary handle broadcasts, so the
// no-reading sentinel cannot be zero -- ERG_POWER_NONE's argument, one field
// over.
(:test) function test_erg_c1_theCadenceEncodingIsOutOfBandNotZero(logger) {
    if (StrongRowView.ergCadOf(null) != $.ERG_CAD_NONE) {
        logger.error("no cadence reading must encode as ERG_CAD_NONE");
        return false;
    }
    if (StrongRowView.ergCadOf(0) != 0.0) {
        logger.error("0 spm is a READING -- a stationary handle -- and must " +
                     "encode as 0.0, not as the sentinel");
        return false;
    }
    if ($.ERG_CAD_NONE >= 0.0) {
        logger.error("the sentinel must be out of band for a real cadence, " +
                     "or the case above cannot hold");
        return false;
    }
    if (StrongRowView.ergCadOf(22) != 22.0) {
        logger.error("a real cadence passes through; got " +
                     StrongRowView.ergCadOf(22));
        return false;
    }
    return true;
}

// ===========================================================================
// c2 -- THE DIFFERENTIALS. Every case below FAILS at this commit.
//
// c1 built the decisions; nothing reads them. These cases drive the SHIPPING
// call sites -- onUpdate through a recording Dc, onTick directly, stopAndSave
// on a stand-in session -- and assert what those call sites must do once the
// wiring lands in c3. Each one is the evidence that the c3 line it names was
// not already there.
//
// The red evidence is the CI run on this commit, linked from the pull request.
// ===========================================================================

// THE ARC'S NUMERATOR AND ITS DENOMINATOR BOTH SWITCH.
//
// 120 W at 18.0 spm is 400 J/stroke, which is exactly the shipped default
// benchmark, so the arc must read 100% -- the one transition it exists to show.
//
// AND IT MUST IGNORE THE SPEED ENTIRELY. The second half is what makes this a
// unit switch rather than a second reading of the same input: the same probe is
// re-rendered at three speeds, including a speed that on the distance path
// would put the arc deep in the RED zone, and the answer must not move.
//
// The geometry is deliberately not re-asserted here. dpsPct normalises to a
// percentage of whatever benchmark it is handed, so every angle, sweep, zone
// boundary and colour downstream is the shipped one -- which is the whole
// reason this feature switches the two ends of a ratio instead of re-deriving
// an arc (#123's comment block).
(:test) function test_erg_c2_theArcReadsJoulesAgainstTheJouleBenchmark(logger) {
    var p = EgCase.onErg();
    p.setPower(120.0);
    var speeds = [ 0.0, 1.0, 6.0 ];
    for (var i = 0; i < speeds.size(); i++) {
        var pct = p.arcPctFor(p.kindWork(), speeds[i]);
        if (pct == null || (pct - 100.0).abs() > 0.01) {
            logger.error("120 W at 18 spm is 400 J/stroke, which IS the " +
                         "benchmark, so the arc must read 100%; at speed " +
                         speeds[i] + " it read " + pct);
            return false;
        }
        if (StrongRowView.dpsZone(pct) != $.DPSZ_AT) {
            logger.error("100% of benchmark must be DPSZ_AT");
            return false;
        }
    }
    // Halving the benchmark must double the percentage: the arc is read
    // against jouleBenchmark and not against anything else.
    p.setJouleBench(200.0);
    var half = p.arcPctFor(p.kindWork(), 0.0);
    if (half == null || (half - 200.0).abs() > 0.01) {
        logger.error("400 J/stroke against a 200 J benchmark is 200%; got " +
                     half);
        return false;
    }
    return true;
}

// THE DEFECT THIS WHOLE FEATURE IS MOST LIKELY TO SHIP.
//
// In erg mode with NO power source the arc must have nothing to say. What it
// must never do is keep reading the GPS-derived distance figure, because on an
// erg that number has no source -- and at the speed used here the distance path
// puts the arc at 55% of benchmark, which is DPSZ_FAR and renders RED: "far
// below benchmark", i.e. row harder, in response to a measurement that does not
// exist.
//
// The assertion is on the COLOUR as well as on the null, because the null on
// its own is not the harm.
(:test) function test_erg_c2_anAbsentPowerSourceNeverReachesTheArcAsAWarning(logger) {
    var p = EgCase.onErg();
    p.setPower(null);
    // 1.0 m/s at 18 spm is 3.33 m/stroke, 55% of the 6.0 m benchmark -- FAR.
    var pct = p.arcPctFor(p.kindWork(), 1.0);
    if (pct != null) {
        logger.error("with no power source the arc must have nothing to say; " +
                     "it read " + pct + "% -- which is the GPS distance " +
                     "figure, and on an erg that number has no source");
        return false;
    }
    var col = StrongRowView.dpsZoneColour(StrongRowView.dpsZone(pct));
    if (col == Gfx.COLOR_RED || col == Gfx.COLOR_ORANGE) {
        logger.error("with no power source the arc rendered a WARNING colour. " +
                     "An athlete whose watch reports no power at all would be " +
                     "told to row harder in response to nothing");
        return false;
    }
    return true;
}

// A REST arc reads the interval just completed, in the selected units -- the
// same two-source rule dpsForArc states for distance (live during WORK, the
// latched interval average during REST).
//
// THE INTERVAL IS INTERNALLY CONSISTENT, which is not decoration: 40 ticks of
// 250 ms is 10 seconds, and 10 seconds at the probe's 18.0 spm is 3 strokes. So
// 120 W over that interval is 1200 J and 400 J/stroke -- which is the shipped
// default benchmark, so the REST arc must read 100%.
//
// An earlier version of this case used a 20 J benchmark and 60 strokes, and it
// red at 40% for its own reason: setJouleBench clamps to JOULE_BENCH_MIN
// (50.0), so the case was asserting against a benchmark the clamp refuses.
// Recorded rather than quietly corrected -- the clamp did its job and the case
// was wrong. (Precisely: at the time, the refusal came from a copy of the clamp
// inside the probe, not from loadSettings -- see
// theJouleBenchmarkIsClampedInCode. Both now route through jouleClampBench, so
// the sentence is true of the shipping clamp as well.)
(:test) function test_erg_c2_theRestArcReadsTheIntervalThatJustEnded(logger) {
    var p = EgCase.onErg();
    var r = EgCase.ergInterval(p, 120.0, 40, 10.0, 30.0, 3);
    if (!r[0]) {
        logger.error("the latch did not take; the assertions below would be " +
                     "vacuous");
        return false;
    }
    var pct = p.arcPctFor(p.kindRest(), 4.0);
    if (pct == null || (pct - 100.0).abs() > 0.01) {
        logger.error("1200 J over 3 strokes is 400 J/stroke, which IS the " +
                     "shipped benchmark, so the REST arc must read 100%; it " +
                     "read " + pct);
        return false;
    }
    return true;
}

// THE GRID'S LABELS FOLLOW ITS UNITS, and only when BOTH toggles are on.
//
// A number whose label still says metres is worse than no number, so the labels
// are asserted in both directions: the work labels must appear and the metre
// labels must be gone, and the two off-states must leave the shipping screen
// exactly as it is.
(:test) function test_erg_c2_theGridSpeaksInWorkUnitsOnlyWhenBothTogglesAreOn(logger) {
    var p = EgCase.onErg();
    var r = EgCase.ergInterval(p, 120.0, 40, 240.0, 900.0, 60);
    if (!r[0]) { logger.error("the latch did not take"); return false; }
    var geo = r[1];
    if (!EgCase.drew(geo, "avg J/str")) {
        logger.error("in work units the per-stroke cell must be labelled " +
                     "'avg J/str'");
        return false;
    }
    if (!EgCase.drew(geo, "work kJ")) {
        logger.error("in work units the accumulated cell must be labelled " +
                     "'work kJ'");
        return false;
    }
    if (EgCase.drew(geo, "m/str") || EgCase.drew(geo, "interval m")) {
        logger.error("in work units NO metre label may survive: a number " +
                     "under a stale unit is worse than no number");
        return false;
    }

    // The toggle is ON by default, so it MUST mean nothing outside erg mode --
    // otherwise every water row ships in joules the first time this lands.
    p.setErgMode(false);
    p.setErgUnits(true);
    var ds = System.getDeviceSettings();
    var g2 = new HrGeoDc(ds.screenWidth, ds.screenHeight);
    p.runUpdate(g2);
    if (!EgCase.drew(g2, "avg m/str") || !EgCase.drew(g2, "interval m")) {
        logger.error("with erg mode OFF the grid must be the shipping metre " +
                     "grid, whatever the units toggle says");
        return false;
    }

    // And erg mode with the units toggle off is still the distance screen.
    p.setErgMode(true);
    p.setErgUnits(false);
    var g3 = new HrGeoDc(ds.screenWidth, ds.screenHeight);
    p.runUpdate(g3);
    if (!EgCase.drew(g3, "avg m/str") || !EgCase.drew(g3, "interval m")) {
        logger.error("erg mode with the units toggle OFF must stay in " +
                     "distance units");
        return false;
    }

    // AND SO MUST THE OTHER TWO CALL SITES. useWorkUnits' own justification is
    // that it is a named function "rather than an `&&` repeated at the arc, the
    // pace row and the grid, because three copies of a rule are three things
    // that can disagree after one edit" -- and until this block, only the GRID
    // copy was pinned. MEASURED: substituting `ergFlag(mErgMode, false)` for
    // useWorkUnits at arcPct and at drawPace left all 308 cases green, because
    // every other erg case is built from EgCase.onErg(), where the toggle is
    // ON and the two predicates are behaviour-identical. The state that
    // separates them is the one an athlete reaches by turning the maintainer's
    // "option (default on)" off, which is the requested feature rather than an
    // edge case.
    //
    // The two figures are far apart on purpose. 120 W at 18.0 spm is 400
    // J/stroke, exactly JOULE_BENCH_DEF, so the WORK path would read 100%;
    // 1.0 m/s at 18.0 spm is 3.33 m/stroke against the 6.0 m dpsBenchmark, so
    // the DISTANCE path reads 55.6%.
    var pct = p.arcPctFor(p.kindWork(), 1.0);
    if (pct == null || (pct - 55.56).abs() > 0.1) {
        logger.error("with the units toggle OFF the arc must read the " +
                     "DISTANCE figure against dpsBenchmark (55.6%); it read " +
                     pct);
        return false;
    }
    // freeRowScreen and not the workout screen, because #108 stood the pace
    // row down during WORK.
    p.setSpeed(4.0);
    var g4 = EgCase.freeRowScreen(p);
    if (!EgCase.drew(g4, "/500m") || !EgCase.drew(g4, "m/str")) {
        logger.error("with the units toggle OFF the pace row must stay the " +
                     "shipping distance row");
        return false;
    }
    if (EgCase.drew(g4, "J/str") || EgCase.drew(g4, "W  ")) {
        logger.error("with the units toggle OFF the pace row rendered work " +
                     "units anyway -- a mixed-unit screen");
        return false;
    }
    return true;
}

// THE GRID'S VALUES, against hand-computed numbers, through the shipping tick.
//
// The same internally consistent interval the REST-arc case uses: 40 ticks of
// 250 ms is 10 s, which at 18.0 spm is 3 strokes, and 120 W over it is 1200 J
// = 1.2 kJ and 400 J/stroke. Asserted as EXACT rendered strings, because a
// "contains" check would match a substring of a neighbouring cell.
(:test) function test_erg_c2_theGridValuesAreTheIntervalsOwnWork(logger) {
    var p = EgCase.onErg();
    var r = EgCase.ergInterval(p, 120.0, 40, 10.0, 30.0, 3);
    if (!r[0]) { logger.error("the latch did not take"); return false; }
    var geo = r[1];
    if (!EgCase.drewExact(geo, "1.2")) {
        logger.error("120 W for 40 ticks of " + $.TICK_MS + " ms is 1200 J, " +
                     "so the accumulated cell must render '1.2' kJ");
        return false;
    }
    if (!EgCase.drewExact(geo, "400")) {
        logger.error("1200 J over 3 strokes is 400 J/stroke, so the " +
                     "per-stroke cell must render '400'");
        return false;
    }
    // The latched pair, read back through the shipping accumulator rather than
    // only off the screen: the number AND the flag that says it is a
    // measurement.
    if (p.lastWorkN() != 40) {
        logger.error("an interval of 40 ticks with real power samples must " +
                     "latch a sample count of 40; got " + p.lastWorkN());
        return false;
    }
    var j = p.lastWorkJ();
    if (j == null || (j - 1200.0).abs() > 0.001) {
        logger.error("the latched interval work must be 1200 J; got " + j);
        return false;
    }
    return true;
}

// A POWERLESS INTERVAL RENDERS DASHES, NEVER ZEROES. This is acceptance
// criterion 2 at the grid, and it is the case the feature exists to not get
// wrong: 0.0 kJ is a claim about the interval, and an athlete with no power
// meter did not make it.
//
// Both erg cells are asserted absent AS VALUES and present AS DASHES, and the
// zero forms they would take are asserted absent by name.
(:test) function test_erg_c2_aPowerlessIntervalRendersDashesNotZeroes(logger) {
    var p = EgCase.onErg();
    var r = EgCase.ergInterval(p, null, 40, 10.0, 30.0, 3);
    if (!r[0]) { logger.error("the latch did not take"); return false; }
    var geo = r[1];
    if (p.lastWorkN() != 0) {
        logger.error("an interval with NO power samples must not claim a " +
                     "measurement; the sample count is " + p.lastWorkN());
        return false;
    }
    if (EgCase.drewExact(geo, "0.0") || EgCase.drewExact(geo, "0")) {
        logger.error("with no power source the grid rendered a ZERO. That is " +
                     "a claim about the interval -- the #86/#107 class");
        return false;
    }
    if (EgCase.countExact(geo, "--") < 2) {
        logger.error("both erg cells must render a dash when there was no " +
                     "power source; saw " + EgCase.countExact(geo, "--") +
                     " dash cells");
        return false;
    }
    // And the labels are still the work labels: the units did not silently
    // fall back to metres just because the source was missing.
    if (!EgCase.drew(geo, "avg J/str") || !EgCase.drew(geo, "work kJ")) {
        logger.error("a missing source must not change the UNITS, only the " +
                     "values");
        return false;
    }
    return true;
}

// THE PACE ROW. Free row is the screen that still draws it (#108 stood it down
// during WORK), so it is where both forms are measured.
//
// 150 W at 18.0 spm is 500 J/stroke.
(:test) function test_erg_c2_thePaceRowSpeaksInPowerAndWorkPerStroke(logger) {
    var p = EgCase.onErg();
    p.setPower(150.0);
    p.setSpeed(4.0);
    var geo = EgCase.freeRowScreen(p);
    if (!EgCase.drew(geo, "150W")) {
        logger.error("the erg pace row must carry the power; 150 W was not " +
                     "drawn");
        return false;
    }
    if (!EgCase.drew(geo, "500J/str")) {
        logger.error("150 W at 18 spm is 500 J/stroke; that term was not drawn");
        return false;
    }
    if (EgCase.drew(geo, "/500m") || EgCase.drew(geo, "m/str")) {
        logger.error("in work units the pace row must not also carry the " +
                     "distance form -- a number under a stale unit is worse " +
                     "than no number");
        return false;
    }

    // No power source: dashes, never zeroes, and the speed must not creep back
    // in as a substitute.
    var q = EgCase.onErg();
    q.setPower(null);
    q.setSpeed(4.0);
    var g2 = EgCase.freeRowScreen(q);
    if (!EgCase.drew(g2, "--W") || !EgCase.drew(g2, "--J/str")) {
        logger.error("with no power source the erg pace row must read " +
                     "'--W  --J/str'");
        return false;
    }
    if (EgCase.drew(g2, "0W") || EgCase.drew(g2, "0J/str")) {
        logger.error("absence rendered as a zero on the pace row");
        return false;
    }
    return true;
}

// A REAL ZERO IS A READING. Acceptance criterion 3, at the pace row, which is
// the one element that renders the instantaneous figure as a NUMBER.
(:test) function test_erg_c2_aRealZeroWattReadingRendersAsZero(logger) {
    var p = EgCase.onErg();
    p.setPower(0.0);
    p.setSpeed(4.0);
    var geo = EgCase.freeRowScreen(p);
    if (!EgCase.drew(geo, "0W")) {
        logger.error("0 W is a MEASUREMENT -- an athlete sitting at the catch " +
                     "-- and must render as the value 0, not as a dash");
        return false;
    }
    if (EgCase.drew(geo, "--W")) {
        logger.error("a real zero-watt reading must not render as absence");
        return false;
    }
    return true;
}

// THE INTERVAL WORK IS INTEGRATED FROM THE TICKS, AND ONLY FROM THE TICKS OF
// THE INTERVAL IT DESCRIBES.
//
// TWO intervals, because ONE cannot tell the difference. An earlier shape of
// this case drove pre-interval ticks, paused ticks and live ticks into a single
// interval and asserted the total -- and MUTATION TESTING SHOWED IT PINNED
// NOTHING ABOUT THE RESET: deleting both reset lines from beginWorkAccum left
// all 308 cases green, because the pre-interval ticks were already stopped by
// the `mSetNum > 0` gate, so there was never anything for the reset to clear.
// The two guards masked each other and the case was credited with coverage it
// did not have. That is the exact failure `test_dps_brokenTrackSegmentsAreDrawable`
// records one file over, reached from a new direction.
//
// A SECOND INTERVAL IS WHAT SEPARATES THEM, and it is powerless on purpose so
// that BOTH halves of the reset are differentiated: without the joules reset it
// latches the first interval's 1000 J, and without the flag reset it latches
// the first interval's claim that a measurement was taken -- which would render
// 1.0 kJ for an interval rowed with no power meter at all.
//
// WHAT IS STILL NOT DIFFERENTIATED, stated rather than implied: the
// `mSetNum > 0` gate itself. Given that beginWorkAccum resets, no reachable
// state distinguishes gating from not gating -- anything a rest tick adds is
// cleared before the next interval reads it. The gate is redundant defence that
// mirrors mSetHrSum's, it is documented as such at the call site, and no case
// here claims to pin it.
(:test) function test_erg_c2_onlyWorkTicksReachTheIntervalAccumulator(logger) {
    var p = EgCase.onErg();
    p.enterStepLive(p.kindWork(), false);
    p.setPower(1000.0);
    for (var i = 0; i < 20; i++) { p.runTick(); }      // no interval open

    p.beginWork(1);                                     // the real entry
    p.enterStepLive(p.kindWork(), true);                // PAUSED ticks
    for (var i = 0; i < 20; i++) { p.runTick(); }

    p.enterStepLive(p.kindWork(), false);               // live ticks
    p.setPower(100.0);
    for (var i = 0; i < 40; i++) { p.runTick(); }

    if (!p.latchSet(1, 10.0, 30.0, 3, 1230, 10)) {
        logger.error("the first latch did not take");
        return false;
    }
    var j = p.lastWorkJ();
    // 40 ticks of 250 ms is 10 s; 100 W for 10 s is 1000 J.
    if (j == null || (j - 1000.0).abs() > 0.001) {
        logger.error("only the 40 live work ticks at 100 W may reach the " +
                     "interval accumulator, i.e. 1000 J. Got " + j +
                     " -- 6000 J would mean the paused ticks were counted");
        return false;
    }

    // THE SECOND INTERVAL, and it measured nothing.
    p.beginWork(2);
    p.enterStepLive(p.kindWork(), false);
    p.setPower(null);
    for (var i = 0; i < 40; i++) { p.runTick(); }
    if (!p.latchSet(2, 10.0, 30.0, 3, 1230, 10)) {
        logger.error("the second latch did not take");
        return false;
    }
    if (p.lastWorkN() != 0) {
        logger.error("the second interval measured NO power, so its sample " +
                     "count must be zero. It is " + p.lastWorkN() +
                     " -- the first interval's claim survived the interval " +
                     "boundary, and the grid would render 1.0 kJ for an " +
                     "interval rowed with no power meter");
        return false;
    }
    var j2 = p.lastWorkJ();
    if (j2 == null || j2 != 0.0) {
        logger.error("the second interval's work must start from zero; it " +
                     "latched " + j2 + " -- 1000.0 would mean the first " +
                     "interval's joules survived the boundary");
        return false;
    }
    return true;
}

// THE FIT WRITES: A VALUE EVERY TICK, NEVER A SILENCE.
//
// Record-scope fields LATCH -- a skipped setData re-emits the previous value
// (#36 byte level, reconfirmed by #48's probe_skip) -- so withholding a write
// on a tick with no power source would fabricate a power reading that was not
// taken. That makes the WRITE COUNT part of the assertion and not a detail:
// three ticks must produce three writes on each record-scope field.
//
// SCOPE, stated because it is exactly the claim this repository keeps
// overreaching on: this observes the ARGUMENT of an in-app setData call. It
// says nothing about what lands in the file's bytes and nothing about what a
// decoder renders. Those need a simulator session and a decode.
(:test) function test_erg_c2_theTickRecordsThePowerStateAsAValue(logger) {
    var p = EgCase.onErg();
    var pw = new ErgField();
    var jp = new ErgField();
    var dg = new ErgField();
    var wk = new ErgField();
    p.installErgFields(pw, jp, dg, wk, new ErgField());
    p.enterStepLive(p.kindWork(), false);

    p.setPower(null);
    p.runTick();
    if (pw.last() != $.ERG_POWER_NONE) {
        logger.error("a tick with no power source must WRITE the sentinel " +
                     $.ERG_POWER_NONE + ", not stay silent -- a record-scope " +
                     "field that is not written re-emits the last value. Got " +
                     pw.last());
        return false;
    }
    if (jp.last() != $.ERG_JPS_NONE) {
        logger.error("the joules-per-stroke field must carry its sentinel too; " +
                     "got " + jp.last());
        return false;
    }
    var d0 = dg.last();
    if (d0 == null || (d0 & $.ERGD_ALIVE) == 0 || (d0 & $.ERGD_PWR_OK) != 0) {
        logger.error("the diagnostic must record ALIVE with the power bit " +
                     "CLEAR when there was no reading; got " + d0);
        return false;
    }

    p.setPower(0.0);
    p.runTick();
    if (pw.last() != 0.0) {
        logger.error("0 W is a reading and must be recorded verbatim; got " +
                     pw.last());
        return false;
    }
    var d1 = dg.last();
    if (d1 == null || (d1 & $.ERGD_PWR_OK) == 0 || (d1 & $.ERGD_PWR_POS) != 0) {
        logger.error("a broadcast ZERO must set the populated bit and clear " +
                     "the positive bit -- that pair is the whole point of the " +
                     "instrumentation. Got " + d1);
        return false;
    }

    p.setPower(120.0);
    p.runTick();
    if (pw.last() != 120.0) {
        logger.error("a real reading must be recorded verbatim; got " + pw.last());
        return false;
    }
    // 120 W at 18 spm is 400 J/stroke.
    var j = jp.last();
    if (j == null || (j - 400.0).abs() > 0.01) {
        logger.error("120 W at 18 spm must record 400 J/stroke; got " + j);
        return false;
    }

    if (pw.count() != 3 || jp.count() != 3 || dg.count() != 3) {
        logger.error("every record-scope erg field must be written on EVERY " +
                     "tick, because a skipped write re-emits the previous " +
                     "value. Three ticks produced " + pw.count() + " / " +
                     jp.count() + " / " + dg.count() + " writes");
        return false;
    }
    // The session field is a SAVE-time write and must not be touched per tick.
    if (wk.count() != 0) {
        logger.error("the session-scope work field must not be written per " +
                     "tick; it was written " + wk.count() + " times");
        return false;
    }
    return true;
}

// THE SESSION TOTAL, written once at save -- and withheld when nothing was ever
// measured.
//
// GUARDED BY THE EVER FLAG, never by `> 0.0`. A `> 0.0` guard would suppress
// the field for a row whose true total work was zero and leave a reader unable
// to tell suppression from absence, which is the reasoning #80 records for
// declining a session-scope heat-strain companion.
(:test) function test_erg_c2_theSessionTotalIsWrittenOnlyWhenMeasured(logger) {
    var p = EgCase.onErg();
    var wk = new ErgField();
    p.installErgFields(new ErgField(), new ErgField(), new ErgField(), wk,
                       new ErgField());
    p.installSession(new ErgSession());
    p.enterStepLive(p.kindWork(), false);
    p.setPower(200.0);
    for (var i = 0; i < 40; i++) { p.runTick(); }
    p.runStopAndSave();
    // 200 W for 40 ticks of 250 ms is 2000 J = 2.0 kJ. NOT gated on an
    // interval: the session total accumulates across rests too, which is the
    // difference between it and the grid cell.
    var v = wk.last();
    if (v == null || (v - 2.0).abs() > 0.001) {
        logger.error("200 W over 40 ticks is 2000 J, so the session field " +
                     "must carry 2.0 kJ; got " + v);
        return false;
    }

    var q = EgCase.onErg();
    var wk2 = new ErgField();
    q.installErgFields(new ErgField(), new ErgField(), new ErgField(), wk2,
                       new ErgField());
    q.installSession(new ErgSession());
    q.enterStepLive(q.kindWork(), false);
    q.setPower(null);
    for (var i = 0; i < 40; i++) { q.runTick(); }
    q.runStopAndSave();
    if (wk2.count() != 0) {
        logger.error("a row that never measured any power must leave the " +
                     "session work field UNWRITTEN; it was written " +
                     wk2.count() + " time(s) with " + wk2.last());
        return false;
    }
    return true;
}

// THE INSTRUMENTATION RECORDS WHAT THE MACHINE POPULATED, through the shipping
// tick.
//
// This is the case that decides whether ONE erg session settles the assumption.
// A machine that broadcasts as fitness equipment would populate speed, distance
// and cadence as well as power, and if it does then the distance-based figures
// still work on an erg -- which changes the design. All four sources are driven
// independently and read back out of the one recorded word.
//
// WHAT THIS CASE DOES NOT ESTABLISH, corrected here because an earlier header
// claimed the bits "answer their own question" and the cadence pair does not.
// These assertions pin the ENCODING -- "the bit is set when the source is
// non-null" -- and they pass identically for a wrist-sourced cadence, because
// the wrist populates ai.currentCadence with no machine present (measured on
// the water; see the ERGD_CAD_OK note in source/StrongRowView.mc). The bits
// therefore say whether cadence populated AT ALL, not where it came from; the
// erg_cadence VALUE is what carries the source question off the file.
(:test) function test_erg_c2_theDiagnosticRecordsWhatTheMachinePopulated(logger) {
    var p = EgCase.onErg();
    var dg = new ErgField();
    p.installErgFields(new ErgField(), new ErgField(), dg, new ErgField(),
                       new ErgField());
    p.enterStepLive(p.kindWork(), false);

    // Nothing populated: the answer the assumption fails with.
    p.setPower(null);
    p.setSpeed(null);
    p.setDist(null);
    p.setCadence(null);
    p.runTick();
    var none = dg.last();
    if (none != ($.ERGD_ALIVE | $.ERGD_ERGMODE | $.ERGD_WORKUNI)) {
        logger.error("with nothing populated the word must be ALIVE plus the " +
                     "two setting bits; got " + none);
        return false;
    }

    // The machine broadcasts as fitness equipment: all four populated.
    p.setPower(150.0);
    p.setSpeed(4.2);
    p.setDist(900.0);
    p.setCadence(22);
    p.runTick();
    var all = dg.last();
    var wantOn = [ $.ERGD_PWR_OK, $.ERGD_PWR_POS, $.ERGD_SPD_OK, $.ERGD_SPD_POS,
                   $.ERGD_DST_OK, $.ERGD_DST_POS, $.ERGD_CAD_OK, $.ERGD_CAD_POS ];
    for (var i = 0; i < wantOn.size(); i++) {
        if ((all & wantOn[i]) == 0) {
            logger.error("bit " + wantOn[i] + " must be set when its source is " +
                         "populated and positive; the word was " + all);
            return false;
        }
    }
    if (all > $.ERGD_MAX) {
        logger.error("the recorded word " + all + " escaped the reserved band");
        return false;
    }
    return true;
}

// ===========================================================================
// r5 c2 -- THE REVISION'S DIFFERENTIALS. Every case below FAILS at this commit.
//
// r5 c1 added the decisions these need; nothing reads them. Each case drives a
// SHIPPING call site and asserts what it must do once r5 c3 wires the decision
// in. The red evidence is the CI run on this commit, linked from the pull
// request.
// ===========================================================================

// THE REC FOOTER'S KILOMETRES ARE THE ONE DISTANCE FIGURE THE UNIT SWITCH DID
// NOT REACH.
//
// Every other distance string on screen became conditional when erg mode
// landed. drawFoot's was not, and its input -- elapsedDist() -- collapses an
// absent reading to 0.0, so in the mode this feature ships the footer rendered
// a fabricated "0.00km", with a unit label, on the glance surface, directly
// under a grid whose own cells were dashing for exactly the same missing
// source. That is the #86/#107 class.
//
// A REST render, because that is the screen the maintainer sees the grid and
// the footer on together, and the footer draws on every non-WORK step.
(:test) function test_erg_c2_theRecFooterNeverFabricatesADistanceOnAnErg(logger) {
    var p = EgCase.onErg();
    // Without this the footer is NO ACCEL and the case would hold vacuously.
    p.setSensorOk(true);
    var r = EgCase.ergInterval(p, 120.0, 40, 10.0, 0.0, 3);
    if (!r[0]) {
        logger.error("the latch did not take; the assertions below would be " +
                     "vacuous");
        return false;
    }
    var foot = EgCase.recFoot(r[1]);
    if (foot == null) {
        logger.error("the REC footer must be on screen for this case to say " +
                     "anything; it was not drawn");
        return false;
    }
    if (foot.find("0.00km") != null) {
        logger.error("on an erg with no distance source the footer rendered " +
                     "'" + foot + "' -- a fabricated measurement with a unit " +
                     "label, which is what every other cell on this screen " +
                     "refuses to do");
        return false;
    }
    if (foot.find("--") == null) {
        logger.error("the footer's distance token must be a dash when there " +
                     "may be no source; the footer read '" + foot + "'");
        return false;
    }

    // NOT A UNITS QUESTION. Kilometres are kilometres whichever figures the arc
    // shows, so turning the work-units toggle off must NOT restore the
    // fabricated zero.
    p.setErgUnits(false);
    var f2 = EgCase.recFoot(EgCase.reRender(p));
    if (f2 == null || f2.find("0.00km") != null) {
        logger.error("with the units toggle off but still on the erg, the " +
                     "footer must still refuse to invent a distance; it read " +
                     "'" + f2 + "'");
        return false;
    }

    // OFF THE ERG NOTHING CHANGES, which is what keeps this a scoped fix and
    // stops the case holding for the wrong reason.
    p.setErgMode(false);
    var f3 = EgCase.recFoot(EgCase.reRender(p));
    if (f3 == null || f3.find("0.00km") == null) {
        logger.error("off the erg the shipping footer is unchanged and must " +
                     "still read '0.00km'; it read '" + f3 + "'");
        return false;
    }
    return true;
}

// A PARTIALLY COVERED INTERVAL UNDER-REPORTS ITS WORK BY EXACTLY THE FRACTION
// THE SOURCE WAS DOWN, AND NOTHING ABOUT THE NUMBER SAYS SO.
//
// The interval accumulator is an INTEGRAL of instantaneous samples. mSetHrN
// makes the heart-rate mean immune to a dropout and an odometer delta makes the
// distance immune by construction; an integral has neither defence. 30 of 40
// ticks carrying a sample is 75% coverage, so an athlete rowing exactly at the
// 400 J/stroke benchmark latches 300 J/stroke -- which the shipping dpsZone
// calls FAR, i.e. "far below benchmark, row harder", handed to someone who is
// on benchmark.
//
// The answer is a DASH, not a scaled-up estimate: extrapolating the measured
// mean across the unmeasured time would invent work the app never saw.
(:test) function test_erg_c2_aPartlyCoveredIntervalDashesRatherThanUnderReporting(logger) {
    // THE STAKES, through the shipping zone decision rather than restated: 75%
    // of benchmark is the warning zone this gate exists to keep an on-benchmark
    // athlete out of.
    if (StrongRowView.dpsZone(75.0) != $.DPSZ_FAR) {
        logger.error("75% of benchmark must be the FAR zone, or this case " +
                     "has no stakes");
        return false;
    }

    var p = EgCase.onErg();
    // 30 live ticks and 10 dead ones over a 10.0 s interval: 7.5 s of samples
    // against 10 s of rowing.
    var r = EgCase.ergIntervalPartial(p, 120.0, 30, 10, 10.0, 30.0, 3);
    if (!r[0]) { logger.error("the latch did not take"); return false; }
    if (p.lastWorkN() != 30) {
        logger.error("the latch must carry the SAMPLE COUNT, which is the " +
                     "whole input to the coverage decision; it carried " +
                     p.lastWorkN());
        return false;
    }
    var pct = p.arcPctFor(p.kindRest(), 4.0);
    if (pct != null) {
        logger.error("a quarter of the interval had no power sample, so the " +
                     "arc must have NO reading rather than an under-reported " +
                     "one; it read " + pct + "% -- an athlete on benchmark " +
                     "shown 'far below benchmark'");
        return false;
    }
    var geo = r[1];
    if (EgCase.countExact(geo, "--") < 2) {
        logger.error("both erg cells must dash when the interval is too " +
                     "sparsely sampled to report; saw " +
                     EgCase.countExact(geo, "--") + " dash cells");
        return false;
    }
    if (EgCase.drewExact(geo, "0.9") || EgCase.drewExact(geo, "300")) {
        logger.error("the grid rendered the under-reported figures (0.9 kJ / " +
                     "300 J/stroke) as though they were the interval's work");
        return false;
    }

    // THE CONTROL, so the gate cannot pass by refusing everything: the same
    // interval fully covered reads 100% and carries both numbers.
    var q = EgCase.onErg();
    var r2 = EgCase.ergIntervalPartial(q, 120.0, 40, 0, 10.0, 30.0, 3);
    if (!r2[0]) { logger.error("the control latch did not take"); return false; }
    var pct2 = q.arcPctFor(q.kindRest(), 4.0);
    if (pct2 == null || (pct2 - 100.0).abs() > 0.01) {
        logger.error("a fully covered interval at the benchmark must read " +
                     "100%; it read " + pct2);
        return false;
    }
    if (!EgCase.drewExact(r2[1], "1.2") || !EgCase.drewExact(r2[1], "400")) {
        logger.error("a fully covered interval must still carry both figures");
        return false;
    }
    return true;
}

// THE TWO ERG CELLS CANNOT OVERRUN THEIR STATED WIDTH.
//
// The grid's format table asserted maxima ("9999" J/stroke, "999.9" kJ) that
// nothing clamped and no case pinned -- an assumption about athlete power
// printed in the same table as the format strings. The pace row's analogous
// bound is enforced by ergNum against PACE_W_MAX and pinned in characters; the
// grid had neither.
//
// CHARACTERS, NOT PIXELS (#121). Five characters is the width of the "18000"
// the accumulated cell replaces; nothing here claims a pixel clearance.
(:test) function test_erg_c2_theGridCellsCannotOverrunTheirWidth(logger) {
    var p = EgCase.onErg();
    // 1e8 W for 40 ticks of 250 ms is 1e9 J: 1 000 000 kJ over 3 strokes, i.e.
    // 3.3e8 J/stroke. Absurd by construction -- the point is that an absurd
    // input must not become an absurd STRING.
    var r = EgCase.ergInterval(p, 1.0e8, 40, 10.0, 30.0, 3);
    if (!r[0]) { logger.error("the latch did not take"); return false; }
    var geo = r[1];
    if (EgCase.countExact(geo, "9999") != 2) {
        logger.error("both erg cells must clamp to '9999'; the screen carried " +
                     EgCase.countExact(geo, "9999") + " of them");
        return false;
    }
    // Every cell value on this screen, bounded. Five characters or fewer.
    for (var i = 0; i < geo.texts.size(); i++) {
        var s = geo.texts[i][3];
        if (s.find("kJ") != null || s.find("J/str") != null) { continue; }
        if (s.length() > 6 && s.find(" ") == null) {
            logger.error("an unbounded numeric cell reached the screen: '" +
                         s + "', " + s.length() + " characters");
            return false;
        }
    }
    return true;
}

// THE NATIVE CADENCE IS RECORDED AS A VALUE.
//
// The erg_diag cadence BITS cannot say where cadence came from -- the wrist
// populates ai.currentCadence with no machine present, measured on the water in
// the README's Potomac row -- so a set bit is the expected reading either way.
// Only the VALUE can be differenced against row_stroke_rate, and
// corrective_rate cannot serve because it clamps that difference at zero and so
// destroys the one sign that would be evidence.
//
// SCOPE: this observes the ARGUMENT of an in-app setData. It says nothing about
// what lands in the file's bytes or what a decoder renders (#154, #168).
(:test) function test_erg_c2_theTickRecordsTheNativeCadenceAsAValue(logger) {
    var p = EgCase.onErg();
    var cd = new ErgField();
    p.installErgFields(new ErgField(), new ErgField(), new ErgField(),
                       new ErgField(), cd);
    p.enterStepLive(p.kindWork(), false);

    p.setCadence(22);
    p.runTick();
    if (cd.count() != 1 || cd.last() != 22.0) {
        logger.error("the tick must record the native cadence; the field was " +
                     "written " + cd.count() + " time(s) with " + cd.last());
        return false;
    }

    // ABSENCE IS A VALUE, NEVER A SILENCE. Record-scope fields LATCH, so
    // skipping the write would re-emit 22 spm on a record where the source
    // reported nothing.
    p.setCadence(null);
    p.runTick();
    if (cd.count() != 2) {
        logger.error("the field must be written on EVERY tick -- a skipped " +
                     "write re-emits the last value. It was written " +
                     cd.count() + " time(s)");
        return false;
    }
    if (cd.last() != $.ERG_CAD_NONE) {
        logger.error("no cadence reading must record as ERG_CAD_NONE; it " +
                     "recorded " + cd.last());
        return false;
    }

    // A REAL ZERO IS A READING -- a stationary handle -- and is exactly the
    // state that would tell a machine source from a wrist one.
    p.setCadence(0);
    p.runTick();
    if (cd.count() != 3 || cd.last() != 0.0) {
        logger.error("0 spm is a measurement and must record as 0.0; it " +
                     "recorded " + cd.last());
        return false;
    }
    return true;
}

} // module Erg
