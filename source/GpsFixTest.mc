using Toybox.Test;
using Toybox.Graphics as Gfx;
using Toybox.Position;
using Toybox.System;
using Toybox.Lang;

// ---------------------------------------------------------------------------
// GPS: the enable form, an honest pip, and the gps_diag receive-path counters.
//
// WHY THIS FILE EXISTS. Activity i185890690 (v0.9.2, fenix 9 Pro 51 mm,
// garmin_product 4954, firmware 6.38, 2,625 records over 43.8 min) carried
// position_lat / position_long / enhanced_speed on records 0-16 ONLY --
// 11:50:41 to 11:50:57 -- and on none of the remaining 2,608. The watch's own
// native gps_metadata messages agree: 17 of them, in the same window. Session
// total_distance is 26.02 m. The rower's report was "GPS is no longer working
// on this app, despite the GPS circle being green".
//
// TWO SEPARATE THINGS ARE IN THAT SENTENCE and only one of them is settled.
//
//   * WHY the watch's GNSS stream stopped after 17 s is NOT ESTABLISHED and
//     nothing in this file or in the source it guards claims a cause.
//     Candidates, none proven: the legacy enableLocationEvents form on a
//     configuration-driven chipset; early firmware; a system power policy; an
//     interaction with this app's other radios. The lap boundary is NOT among
//     them -- lap 1 began at 11:50:46 and the stream stopped at 11:50:57,
//     eleven seconds INTO the lap, not at its edge -- and the accelerometer
//     path was live throughout (native total_cycles on lap 1 is 70, ~23 spm).
//   * THAT THE PIP WENT ON SAYING "GREEN" is settled, and it is an app defect
//     whatever stopped the stream. On v0.9.2 onPosition assigns mGpsQual and
//     records NOTHING else -- no stamp, no counter -- and drawGps colours from
//     mGpsQual alone. So when the callbacks stop, the last colour FREEZES.
//     test_gps_c0_theQualityLatchesWhenCallbacksStop pins that freeze on the
//     shipped code, and it stays green afterwards: the latch is still there,
//     it is the COLOUR that stops trusting it.
//
// EVERYTHING IN THIS FILE LIVES IN `module GpsFix`, and that is a hard
// constraint rather than a taste, for the reason source/RrHrvTest.mc:7-13
// states: the fenix6 family caps module `globals` at 253 members, a file-scope
// (:test), helper function or test class costs one member each, and a
// `module { }` block costs ONE between all of them. The simulator prints these
// cases as `GpsFix.test_gps_...`, which is the name scripts/list_tests.py
// emits and the name scripts/expected_tests.txt must therefore carry.
//
// Measured by bisection on this branch, with monkeyc --unit-test for fenix6, by
// adding N throwaway file-scope (:test) stubs to a scratch file until the build
// reds. Measured at the c1 commit, with `module GpsDiag` and `module GpsFix`
// both present -- so this line is the branch's figure at every commit from c1
// onward, not a per-commit one:
//
//     CEILING gps-fenix9 fenix6: 251 used of 253, 2 free -- the 3rd file-scope (:test) added reds
//
// N=2 BUILD SUCCESSFUL; N=3 "ERROR: fenix6: Found 254 members in module
// 'globals', exceeding the limit of 253"; N=4 "Found 255".
//
// THIS CHANGE COSTS EXACTLY TWO MEMBERS against the previous anchor
// (`hrv-correctness`, 249 used / 4 free, source/RrHrvTest.mc), and the two are
// the two module blocks: `module GpsDiag` and `module GpsFix`. Every constant
// this change adds -- both freshness windows, the eleven slot indices, the four
// FORM_* values, the three flag bits -- is inside GpsDiag and costs nothing,
// which is why GPS_FRESH_MS is $.GpsDiag.GPS_FRESH_MS rather than a file-scope
// sibling of $.HR_FRESH_MS. Every (:test), fixture class and helper here is
// inside GpsFix for the same reason.
//
// scripts/check_ceiling_notes.py enumerates every anchor in the tree and
// CANNOT tell you which is the newest one. Re-bisect when the tree changes; do
// not read either note as current without doing so.
//
// THE COMMIT PARTITION, which is how the red evidence exists at all
// (docs/agents/rituals/FIX_ROUND.md section 3):
//   c0  characterization pins on shipped symbols -- green in EVERY epoch.
//   c1  the behaviour-preserving refactor, the new symbols, and green pins on
//       them in isolation.
//   c2  RED differentials only. Every case in the c2 section was shown
//       failing, by name, in a CI run on this branch before the fix landed.
//       Each one drives an entry point that already exists at c1 -- onPosition,
//       onTick, startGps, gpsPipColour -- and fails because the WIRING is
//       absent, not because a symbol is.
//   c3  the fix. No test file, no pin, no script.
//
// THE CLOCK IS INJECTED, ALWAYS, for the reason source/RrHrvTest.mc:75-80
// gives: System.getTimer() counts from DEVICE start, so a case that synthesises
// a stamp from it passes on a desktop simulator open for hours and REDS on
// CI's, which is seconds old. Every case here sets the probe's nowMs() to a
// literal.
//
// WHAT NO CASE IN THIS FILE CAN SHOW, stated so nobody reads more into a green
// run. Nothing here touches a FIT file, a GNSS chipset or a real position fix.
// No (:test) can obtain a Session (docs/agents/FACTS.md section 3.2), so
// createField is unreachable and nothing below proves gps_diag is accepted,
// saved or decodable. Nothing below calls Position.enableLocationEvents either
// -- the enable ladder is driven through an overridable seam, so what these
// cases pin is WHICH FORM the code chooses and in what order it falls back,
// never that any form acquires a fix on any device. The [Local] issue filed
// with this change owns both.
// ---------------------------------------------------------------------------
module GpsFix {

// A stand-in Position.Info. Only `accuracy` is read by onPosition, so only
// `accuracy` is here -- a fuller fake would invite a case to assert about a
// member the shipping code never looks at.
//
// ACCURACY MAY BE NULL, and that is the point of the member rather than an
// omission: onPosition's null guard is one of the things c0 pins, and a
// stand-in that could not express null could not drive it.
class GpsInfo {
    var accuracy;
    function initialize(acc) { accuracy = acc; }
}

// A recording Dc that keeps the COLOUR each string was drawn in.
//
// HrDc (source/HrArcTest.mc) already records every drawText, but its setColor
// is an empty method, so the colour -- which is the whole of what the GPS pip
// says -- is not in its log. This subclass adds exactly that and changes
// nothing else, so every other case in the repository that uses HrDc is
// untouched.
class GpsDc extends HrDc {
    var fg;        // the most recent setColor foreground
    var painted;   // [colour, string] for every drawText, in call order

    function initialize(width, height) {
        HrDc.initialize(width, height);
        fg = null;
        painted = [];
    }

    function setColor(f, b) { fg = f; }

    function drawText(x, y, font, s, just) {
        painted.add([fg, s]);
        HrDc.drawText(x, y, font, s, just);
    }

    // The colour `s` was LAST drawn in, or null if it was never drawn.
    function colourOf(s) {
        var c = null;
        for (var i = 0; i < painted.size(); i++) {
            if (painted[i][1].equals(s)) { c = painted[i][0]; }
        }
        return c;
    }

    // How many times `s` was drawn. Paired with colourOf on purpose: a case
    // that asserted only a colour would pass against a screen that drew the
    // label twice in two different colours.
    function countOf(s) {
        var n = 0;
        for (var i = 0; i < painted.size(); i++) {
            if (painted[i][1].equals(s)) { n += 1; }
        }
        return n;
    }
}

// The probe.
//
// EXTENDS HrProbe rather than StrongRowView, so the render cases reuse the
// already-reviewed setup seams (enterStep, setNarrowSession, driveStrokes,
// runUpdate, setNowMs) instead of a second copy of them. HrProbe neutralises
// startSensor() and startGps() and nothing else, so every draw case below
// drives the ACTUAL call site.
class GpsProbe extends HrProbe {
    // The enable ladder's three inputs and its transcript. Set by a case before
    // it calls realStartGps(); read afterwards.
    var capCfgApi;    // what gpsCapConfigApi() should report (c3 onward)
    var capSatIq;     // what gpsCapSatIq() should report
    var capConst;     // what gpsCapConstellations() should report
    var failForms;    // the FORM_* values gpsEnable() should report as throwing
    var attempted;    // every form gpsEnable() was asked for, in call order
    var starts;       // startGps() calls, counted whether or not the body runs
    var runRealStart; // when true, startGps() runs the SHIPPING ladder

    function initialize() {
        HrProbe.initialize();
        capCfgApi = false;
        capSatIq = false;
        capConst = false;
        failForms = [];
        attempted = [];
        starts = 0;
        runRealStart = false;
    }

    // `hidden` is protected in Monkey C, so this reads the shipping field
    // rather than a copy of it.
    function gpsQual() { return mGpsQual; }

    // COUNTS FIRST, THEN RUNS, the rule LifeTimer.start states
    // (ViewLifecycleTest.mc:125-127): "never called" and "called and did
    // something" must stay distinguishable.
    //
    // The body is off by default, so a case about the WATCHDOG never reaches
    // the enable ladder and a case about the LADDER has to ask for it. That is
    // also what keeps a probe from ever arming real positioning: with
    // runRealStart set, gpsEnable below is overridden too, so no case in this
    // file can reach Position.enableLocationEvents.
    hidden function startGps() {
        starts += 1;
        if (runRealStart) { StrongRowView.startGps(); }
    }

    // OVERRIDES AN ABSENT METHOD AT c1 AND c2, deliberately: gpsCapConfigApi is
    // added by c3, so until then this is an unused probe method and after it
    // the override takes effect. It exists so that ALL THREE flag bits are
    // driven by the case rather than by whichever device the suite happens to
    // run on -- `Position has :hasConfigurationSupport` is true on fr965, so a
    // case that read it directly would pin the runner, not the code.
    hidden function gpsCapConfigApi()      { return capCfgApi; }
    hidden function gpsCapSatIq()          { return capSatIq; }
    hidden function gpsCapConstellations() { return capConst; }

    hidden function gpsEnable(form) {
        attempted.add(form);
        return failForms.indexOf(form) < 0;
    }

    // -- seams on the new shipping methods -------------------------------------
    // Every one of these CALLS the shipping code. None re-implements it: a test
    // that re-implements logic instead of calling it pins nothing
    // (docs/agents/FACTS.md section 6, which has the receipt twice).
    function note(acc, t)     { gpsNote(acc, t); }
    function watchdog()       { gpsWatchdog(); }
    function sessionReset(t)  { gpsDiagSessionReset(t); }
    function snapshot()       { return gpsDiagSnapshot(); }
    function pipColour()      { return gpsPipColour(); }
    function slot(i)          { return mGpsDiag[i]; }
    function setSlot(i, v)    { mGpsDiag[i] = v; }
    function lastGpsMs()      { return mLastGpsMs; }
    function everSeen()       { return mGpsEver; }
    function realStartGps()   { runRealStart = true; startGps(); }

    // Drive the SHIPPING callback. Never a transcription of it: onPosition is
    // what the platform calls, and it is what these cases must exercise.
    //
    // THE CAST IS LOAD-BEARING. onPosition is annotated
    // `(info as Position.Info)` and monkeyc enforces that at the call site with
    // no -l level, the same trap ViewLifecycleTest.mc:120-124 measures for
    // onLayout's Dc. Erased at runtime; only duck typing applies there.
    function feed(acc) {
        onPosition(new GpsInfo(acc) as Position.Info);
    }
}

// Render the status row through the REAL onUpdate and return the log.
//
// STEP_WARM, not STEP_WORK: onUpdate draws the status row only when the step
// is not WORK (the `if (!isWork)` gate), which is the shipped behaviour this
// change deliberately leaves alone. The work screen is rendered by the case
// that asserts the row is absent there.
function gpsRender(p, kind, nowMs) {
    p.driveStrokes();
    p.setSensorOk(true);
    p.enterStep(kind, false);
    p.setNarrowSession();
    p.setSpeed(4.0);
    p.setNowMs(nowMs);
    var ds = System.getDeviceSettings();
    var d = new GpsDc(ds.screenWidth, ds.screenHeight);
    p.runUpdate(d);
    return d;
}

// ===========================================================================
// c0 -- CHARACTERIZATION. Green on origin/main at 9ece925, before a line of
// this change lands, and green after it.
// ===========================================================================

// onPosition's whole shipped body, read back through the shipping field.
(:test) function test_gps_c0_onPositionRecordsTheAccuracy(logger) {
    var p = new GpsProbe();
    p.feed(4);
    if (p.gpsQual() != 4) {
        logger.error("onPosition must record info.accuracy; got " + p.gpsQual());
        return false;
    }
    p.feed(2);
    if (p.gpsQual() != 2) {
        logger.error("a later callback must replace it; got " + p.gpsQual());
        return false;
    }
    return true;
}

// The null guard, both halves of it. A null accuracy must leave the previous
// reading alone rather than clearing it -- which is what makes the FREEZE the
// case below pins a property of the design and not of one callback.
(:test) function test_gps_c0_onPositionIgnoresANullAccuracy(logger) {
    var p = new GpsProbe();
    p.feed(4);
    p.feed(null);
    if (p.gpsQual() != 4) {
        logger.error("a null accuracy must not overwrite the last reading; got " +
                     p.gpsQual());
        return false;
    }
    return true;
}

// THE FIELD DEFECT, characterized on the shipped code.
//
// One usable fix, then silence -- i185890690's shape. mGpsQual still reads 4 an
// hour later, because nothing in the shipped view records WHEN the callback
// happened. This case is green in every epoch on purpose: the latch survives
// the fix. What the fix changes is that the COLOUR stops trusting it, which is
// the c2 differential one section down.
(:test) function test_gps_c0_theQualityLatchesWhenCallbacksStop(logger) {
    var p = new GpsProbe();
    p.setNowMs(100000);
    p.feed(4);
    p.setNowMs(100000 + 3600000);          // one hour of silence
    if (p.gpsQual() != 4) {
        logger.error("the shipped view latches the last accuracy; got " +
                     p.gpsQual());
        return false;
    }
    return true;
}

// Today's pip colouring, driven through the REAL drawGps.
//
// Three bands, because drawGps has three: >= 3 green, == 2 yellow, everything
// else red. Each render stamps the callback and reads the pip AT THE SAME
// INSTANT, so this stays green once the colour gains a freshness term -- a
// fresh usable fix is green before and after.
(:test) function test_gps_c0_theFreshPipColoursByAccuracy(logger) {
    var bands = [[4, Gfx.COLOR_GREEN], [3, Gfx.COLOR_GREEN],
                 [2, Gfx.COLOR_YELLOW], [1, Gfx.COLOR_RED],
                 [0, Gfx.COLOR_RED]];
    var ok = true;
    for (var i = 0; i < bands.size(); i++) {
        var p = new GpsProbe();
        p.setNowMs(500000);
        p.feed(bands[i][0]);
        var d = gpsRender(p, p.kindWarm(), 500000);
        var got = d.colourOf("GPS");
        if (got != bands[i][1]) {
            logger.error("accuracy " + bands[i][0] + " must draw GPS in " +
                         bands[i][1] + "; got " + got);
            ok = false;
        }
    }
    return ok;
}

// The pip rides the status row, once, and the work screen does not carry it.
//
// BOTH HALVES ARE ONE CASE, for the reason PipLayoutTest.mc:346-350 gives for
// the heat-strain mark: separated, the negative half is green in every epoch
// and would pass against a view that drew no pip at all. Joined, it is what
// pins the decision this change records -- the work screen is left untouched,
// so a GPS mark added there would red here rather than landing unnoticed.
(:test) function test_gps_c0_theRowCarriesTheGpsPipAndWorkDoesNot(logger) {
    var p = new GpsProbe();
    p.setNowMs(500000);
    p.feed(4);
    var warm = gpsRender(p, p.kindWarm(), 500000);
    var ok = true;
    if (warm.countOf("GPS") != 1) {
        logger.error("the status row must draw exactly one GPS pip; counted " +
                     warm.countOf("GPS"));
        return false;
    }
    var q = new GpsProbe();
    q.setNowMs(500000);
    q.feed(4);
    var work = gpsRender(q, q.kindWork(), 500000);
    if (work.countOf("GPS") != 0) {
        logger.error("the work screen drops the status row, so it must draw no " +
                     "GPS pip; counted " + work.countOf("GPS") +
                     ". A mark added outside drawGps would appear here.");
        ok = false;
    }
    return ok;
}

// Element-wise array compare. Not (:test)-annotated, and inside the module, so
// it costs no globals member and drops out of the shipping build.
function arrEq(got, exp, logger, what) {
    if (got == null) { logger.error(what + ": got null"); return false; }
    if (got.size() != exp.size()) {
        logger.error(what + ": size " + got.size() + " != " + exp.size());
        return false;
    }
    for (var i = 0; i < exp.size(); i++) {
        if (got[i] != exp[i]) {
            logger.error(what + ": idx " + i + " got " + got[i] + " exp " + exp[i]);
            return false;
        }
    }
    return true;
}

// ===========================================================================
// c1 -- THE NEW SYMBOLS, pinned in ISOLATION. Green from the commit that adds
// them. None of these proves the shipping call sites USE them; that is exactly
// what the c2 differentials one section down are for.
// ===========================================================================

// gpsHave's whole truth table, including the case a `> 0` test gets wrong.
//
// THE NEGATIVE-CLOCK ROW IS THE REASON THIS FUNCTION EXISTS IN THIS SHAPE.
// System.getTimer() is negative for 25 of every 50 days of device uptime
// (#70), so `lastMs > 0` reads a live signal as absent for half the calendar.
// Both stamps below are negative and one millisecond apart: the sentinel test
// must be `!= 0`, and the age term subtracts exactly inside one half of the
// signed cycle.
(:test) function test_gps_c1_freshnessUsesTheNeverSeenSentinel(logger) {
    var ok = true;
    // [lastMs, now, thresh, expected]
    var rows = [[0,       100000,  5000, false],   // never seen
                [0,       0,       5000, false],   // never seen, clock at 0
                [100000,  100000,  5000, true],    // same instant
                [100000,  104999,  5000, true],    // one ms inside
                [100000,  105000,  5000, false],   // EXACTLY the threshold is stale
                [100000,  105001,  5000, false],
                [-900000, -899000, 5000, true],    // negative clock, 1 s old
                [-900000, -894000, 5000, false]];  // negative clock, 6 s old
    for (var i = 0; i < rows.size(); i++) {
        var got = StrongRowView.gpsHave(rows[i][0], rows[i][1], rows[i][2]);
        if (got != rows[i][3]) {
            logger.error("gpsHave(" + rows[i][0] + ", " + rows[i][1] + ", " +
                         rows[i][2] + ") = " + got + ", expected " + rows[i][3]);
            ok = false;
        }
    }
    return ok;
}

// gpsColour: absence is a DIFFERENT KIND of answer from a poor fix.
//
// The three graded bands are today's, unchanged. The fourth row is the change:
// with no recent callback the pip carries the no-data colour whatever the last
// accuracy was -- which is the whole of i185890690's display defect.
(:test) function test_gps_c1_theColourSeparatesAbsenceFromQuality(logger) {
    var ok = true;
    // [have, qual, expected]
    var rows = [[true,  4, Gfx.COLOR_GREEN],
                [true,  3, Gfx.COLOR_GREEN],
                [true,  2, Gfx.COLOR_YELLOW],
                [true,  1, Gfx.COLOR_RED],
                [true,  0, Gfx.COLOR_RED],
                [false, 4, Gfx.COLOR_DK_GRAY],
                [false, 2, Gfx.COLOR_DK_GRAY],
                [false, 0, Gfx.COLOR_DK_GRAY]];
    for (var i = 0; i < rows.size(); i++) {
        var got = StrongRowView.gpsColour(rows[i][0], rows[i][1]);
        if (got != rows[i][2]) {
            logger.error("gpsColour(" + rows[i][0] + ", " + rows[i][1] + ") = " +
                         got + ", expected " + rows[i][2]);
            ok = false;
        }
    }
    return ok;
}

// The enable ladder's two pure decisions: which rung to start on, and which
// rung follows a throw.
//
// BOTH IN ONE CASE, because the pair IS the ladder: a chooser that preferred
// the configuration form while nextFormFrom dropped straight to legacy would
// be green on either half alone and wrong together.
(:test) function test_gps_c1_theFormChooserPrefersConfigurationThenConstellations(logger) {
    var ok = true;
    // [satIqOk, constOk, expected first rung]
    var first = [[true,  true,  $.GpsDiag.FORM_CONFIG],
                 [true,  false, $.GpsDiag.FORM_CONFIG],
                 [false, true,  $.GpsDiag.FORM_CONST],
                 [false, false, $.GpsDiag.FORM_LEGACY]];
    for (var i = 0; i < first.size(); i++) {
        var got = $.GpsDiag.chooseForm(first[i][0], first[i][1]);
        if (got != first[i][2]) {
            logger.error("chooseForm(" + first[i][0] + ", " + first[i][1] +
                         ") = " + got + ", expected " + first[i][2]);
            ok = false;
        }
    }
    // [form, constOk, expected next rung]
    var next = [[$.GpsDiag.FORM_CONFIG, true,  $.GpsDiag.FORM_CONST],
                [$.GpsDiag.FORM_CONFIG, false, $.GpsDiag.FORM_LEGACY],
                [$.GpsDiag.FORM_CONST,  true,  $.GpsDiag.FORM_LEGACY],
                [$.GpsDiag.FORM_CONST,  false, $.GpsDiag.FORM_LEGACY],
                [$.GpsDiag.FORM_LEGACY, true,  $.GpsDiag.FORM_NONE],
                [$.GpsDiag.FORM_LEGACY, false, $.GpsDiag.FORM_NONE],
                [$.GpsDiag.FORM_NONE,   true,  $.GpsDiag.FORM_NONE]];
    for (var j = 0; j < next.size(); j++) {
        var g = $.GpsDiag.nextFormFrom(next[j][0], next[j][1]);
        if (g != next[j][2]) {
            logger.error("nextFormFrom(" + next[j][0] + ", " + next[j][1] +
                         ") = " + g + ", expected " + next[j][2]);
            ok = false;
        }
    }
    return ok;
}

// gpsRearmDue's four refusals, one row each.
(:test) function test_gps_c1_theRearmDecisionIsBoundedAndNeedsAFixEverSeen(logger) {
    var ok = true;
    var R = $.GpsDiag.GPS_REARM_MS;
    // [ever, lastMs, lastRearmMs, now, expected]
    var rows = [
        [false, 100000, 0, 100000 + R,     false],  // never had a usable fix
        [true,  0,      0, 100000 + R,     false],  // never-seen stamp
        [true,  100000, 0, 100000 + R - 1, false],  // one ms short of the window
        [true,  100000, 0, 100000 + R,     true],   // EXACTLY the window is due
        [true,  100000, 0, 100000 + R + 1, true],
        // already re-armed inside this window: refused until the next one
        [true,  100000, 100000 + R, 100000 + R + 1,     false],
        [true,  100000, 100000 + R, 100000 + 2 * R - 1, false],
        [true,  100000, 100000 + R, 100000 + 2 * R,     true],
        // a negative clock, where a `> 0` sentinel would refuse forever
        [true,  -900000, 0, -900000 + R, true]];
    for (var i = 0; i < rows.size(); i++) {
        var got = StrongRowView.gpsRearmDue(rows[i][0], rows[i][1], rows[i][2],
                                            rows[i][3], R);
        if (got != rows[i][4]) {
            logger.error("gpsRearmDue(" + rows[i][0] + ", " + rows[i][1] + ", " +
                         rows[i][2] + ", " + rows[i][3] + ", " + R + ") = " +
                         got + ", expected " + rows[i][4]);
            ok = false;
        }
    }
    return ok;
}

// THE SLOT INDICES ARE THE WIRE FORMAT. Every one nailed to its literal number,
// for the reason RrDiag.mc's header gives: a permutation confined to an
// unpinned tail would re-key every file already recorded with the whole suite
// green. The FORM_* values are pinned for the same reason -- they are the
// contents of slot 7, not an internal enum.
(:test) function test_gps_c1_theSlotKeyIsZeroToTen(logger) {
    var ok = true;
    var names = ["I_VERSION", "I_CB_TOTAL", "I_CB_USABLE", "I_CB_GOOD",
                 "I_LAST_CB_S", "I_MAXGAP_S", "I_REARMS", "I_FORM",
                 "I_ENABLE_THROW", "I_LAST_ACC", "I_FLAGS"];
    var idx = [$.GpsDiag.I_VERSION, $.GpsDiag.I_CB_TOTAL, $.GpsDiag.I_CB_USABLE,
               $.GpsDiag.I_CB_GOOD, $.GpsDiag.I_LAST_CB_S, $.GpsDiag.I_MAXGAP_S,
               $.GpsDiag.I_REARMS, $.GpsDiag.I_FORM, $.GpsDiag.I_ENABLE_THROW,
               $.GpsDiag.I_LAST_ACC, $.GpsDiag.I_FLAGS];
    for (var i = 0; i < idx.size(); i++) {
        if (idx[i] != i) {
            logger.error($.GpsDiag.VERSION + ": " + names[i] + " must be " + i +
                         ", is " + idx[i] + " -- slot indices are the wire " +
                         "format; renumbering one re-keys every recorded file");
            ok = false;
        }
    }
    if ($.GpsDiag.SLOTS != 11) {
        logger.error("SLOTS must be 11, is " + $.GpsDiag.SLOTS);
        ok = false;
    }
    if ($.GpsDiag.MAXV != 65534) {
        logger.error("MAXV must be 65534 -- one below the UINT16 invalid " +
                     "value, so a saturated slot cannot be read as absent; is " +
                     $.GpsDiag.MAXV);
        ok = false;
    }
    var forms = [$.GpsDiag.FORM_NONE, $.GpsDiag.FORM_LEGACY,
                 $.GpsDiag.FORM_CONST, $.GpsDiag.FORM_CONFIG];
    for (var j = 0; j < forms.size(); j++) {
        if (forms[j] != j) {
            logger.error("FORM_* value " + j + " must be " + j + ", is " + forms[j]);
            ok = false;
        }
    }
    var flags = [$.GpsDiag.F_CFG_API, $.GpsDiag.F_SATIQ_OK, $.GpsDiag.F_CONST_API];
    var want  = [1, 2, 4];
    for (var k = 0; k < flags.size(); k++) {
        if (flags[k] != want[k]) {
            logger.error("flag bit " + k + " must be " + want[k] + ", is " + flags[k]);
            ok = false;
        }
    }
    return ok;
}

// newCounters and clamp: a clean array carries the version and nothing else,
// and no slot can leave the range the field can hold.
(:test) function test_gps_c1_theCountersStartCleanAndClampAtTheSlotCeiling(logger) {
    var a = $.GpsDiag.newCounters();
    var exp = [$.GpsDiag.VERSION, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    if (!arrEq(a, exp, logger, "newCounters")) { return false; }
    var ok = true;
    // [input, expected]
    var rows = [[null, 0], [-1, 0], [-99999, 0], [0, 0], [1, 1],
                [65533, 65533], [65534, 65534], [65535, 65534], [999999, 65534]];
    for (var i = 0; i < rows.size(); i++) {
        var got = $.GpsDiag.clamp(rows[i][0]);
        if (got != rows[i][1]) {
            logger.error("clamp(" + rows[i][0] + ") = " + got + ", expected " +
                         rows[i][1]);
            ok = false;
        }
    }
    return ok;
}

// The session reset zeroes the receive path and KEEPS the enable answer.
//
// Both halves in one case, because the split is the decision: a reset that
// cleared I_FORM would delete the answer for exactly the row -- one with no
// callbacks at all -- that this field was built to explain.
(:test) function test_gps_c1_theSessionResetKeepsTheEnableAnswer(logger) {
    var a = $.GpsDiag.newCounters();
    for (var i = 0; i < $.GpsDiag.SLOTS; i++) { a[i] = 7; }
    a[$.GpsDiag.I_VERSION]      = $.GpsDiag.VERSION;
    a[$.GpsDiag.I_FORM]         = $.GpsDiag.FORM_CONFIG;
    a[$.GpsDiag.I_ENABLE_THROW] = 2;
    a[$.GpsDiag.I_FLAGS]        = 3;
    $.GpsDiag.resetSession(a);
    var exp = [$.GpsDiag.VERSION,      // 0 version, untouched
               0, 0, 0,                // 1-3 callback counters, zeroed
               7,                      // 4 derived at readout, not reset here
               0, 0,                   // 5-6 gap and re-arms, zeroed
               $.GpsDiag.FORM_CONFIG,  // 7 the enable answer, KEPT
               2,                      // 8 throws, KEPT
               0,                      // 9 last accuracy, zeroed
               3];                     // 10 flags, KEPT
    return arrEq(a, exp, logger, "resetSession");
}

// secsBetween: truncation, the never-seen sentinel, and the refusal to report a
// negative span as a duration.
(:test) function test_gps_c1_secondsBetweenTruncatesAndRefusesNegatives(logger) {
    var ok = true;
    // [from, to, expected]
    var rows = [[0,     500000, 0],        // never-seen baseline
                [0,     0,      0],
                [1000,  1000,   0],
                [1000,  1999,   0],        // truncates, never rounds up
                [1000,  2000,   1],
                [1000,  3999,   2],
                [5000,  1000,   0],        // out of order: 0, not a wrap
                [1000,  1000 + 65534000, 65534],
                [1000,  1000 + 99999000, 65534]];   // clamped, "at least"
    for (var i = 0; i < rows.size(); i++) {
        var got = $.GpsDiag.secsBetween(rows[i][0], rows[i][1]);
        if (got != rows[i][2]) {
            logger.error("secsBetween(" + rows[i][0] + ", " + rows[i][1] + ") = " +
                         got + ", expected " + rows[i][2]);
            ok = false;
        }
    }
    return ok;
}

// gpsNote, called directly: the stamp, the three counters, the ever-latch and
// the gap slot.
//
// IN ISOLATION ONLY. Nothing here says onPosition calls it -- that is
// test_gps_c2_onPositionStampsAndCountsTheCallback, and this case would stay
// green if the call site were deleted.
(:test) function test_gps_c1_theCallbackNoteCountsAndStamps(logger) {
    var p = new GpsProbe();
    p.sessionReset(100000);
    p.note(4, 101000);
    p.note(3, 102000);
    p.note(2, 103000);
    p.note(null, 110000);       // counted, but grades nothing
    var ok = true;
    if (p.slot($.GpsDiag.I_CB_TOTAL) != 4) {
        logger.error("every callback counts, including a null accuracy; got " +
                     p.slot($.GpsDiag.I_CB_TOTAL));
        ok = false;
    }
    if (p.slot($.GpsDiag.I_CB_USABLE) != 2) {
        logger.error("accuracy >= 3 is usable: expected 2, got " +
                     p.slot($.GpsDiag.I_CB_USABLE));
        ok = false;
    }
    if (p.slot($.GpsDiag.I_CB_GOOD) != 1) {
        logger.error("accuracy == 4 is good: expected 1, got " +
                     p.slot($.GpsDiag.I_CB_GOOD));
        ok = false;
    }
    if (p.slot($.GpsDiag.I_LAST_ACC) != 2) {
        logger.error("a null accuracy must not overwrite the last graded one; got " +
                     p.slot($.GpsDiag.I_LAST_ACC));
        ok = false;
    }
    if (p.slot($.GpsDiag.I_MAXGAP_S) != 7) {
        logger.error("the longest gap is the 7 s between 103000 and 110000; got " +
                     p.slot($.GpsDiag.I_MAXGAP_S));
        ok = false;
    }
    if (p.lastGpsMs() != 110000) {
        logger.error("the arrival stamp must be the last callback; got " +
                     p.lastGpsMs());
        ok = false;
    }
    if (!p.everSeen()) {
        logger.error("a usable fix was seen, so the ever-latch must be set");
        ok = false;
    }
    return ok;
}

// The gap slot's BASELINE, which is the half a bare `previous arrival` would
// get wrong: a silence that straddles START belongs to the row before it.
(:test) function test_gps_c1_theGapSlotBaselinesAtTheStartOfTheRow(logger) {
    var p = new GpsProbe();
    p.note(4, 10000);            // long before START -- no session yet
    p.sessionReset(600000);      // START, ten minutes later
    p.note(4, 602000);           // two seconds into the row
    var ok = true;
    if (p.slot($.GpsDiag.I_MAXGAP_S) != 2) {
        logger.error("the 590 s straddling START belongs to no row: the gap " +
                     "must be 2 s, got " + p.slot($.GpsDiag.I_MAXGAP_S));
        ok = false;
    }
    return ok;
}

// The watchdog seam, called directly: one re-arm per window and no more.
//
// IN ISOLATION ONLY. Nothing here says onTick calls it -- that is
// test_gps_c2_theTickRearmsAStaleStream, and this case would stay green if the
// call site were deleted.
(:test) function test_gps_c1_theWatchdogSeamRearmsAtMostOncePerWindow(logger) {
    var R = $.GpsDiag.GPS_REARM_MS;
    var p = new GpsProbe();
    p.sessionReset(100000);
    p.note(4, 100000);                 // a usable fix, so the latch is set
    var ok = true;
    p.setNowMs(100000 + R - 1);
    p.watchdog();
    if (p.starts != 0) {
        logger.error("one ms short of the window must not re-arm; starts=" + p.starts);
        ok = false;
    }
    p.setNowMs(100000 + R);
    p.watchdog();
    if (p.starts != 1) {
        logger.error("at the window the watchdog re-arms once; starts=" + p.starts);
        ok = false;
    }
    p.setNowMs(100000 + 2 * R - 1);
    p.watchdog();
    p.watchdog();
    if (p.starts != 1) {
        logger.error("inside the same window no further re-arm; starts=" + p.starts);
        ok = false;
    }
    p.setNowMs(100000 + 2 * R);
    p.watchdog();
    if (p.starts != 2) {
        logger.error("the next window re-arms again; starts=" + p.starts);
        ok = false;
    }
    if (p.slot($.GpsDiag.I_REARMS) != 2) {
        logger.error("every re-arm is counted; slot says " +
                     p.slot($.GpsDiag.I_REARMS));
        ok = false;
    }
    return ok;
}

// The watchdog will not re-arm a receiver that has never produced a usable fix:
// that device is acquiring, not stalled, and a re-enable may reset it.
(:test) function test_gps_c1_theWatchdogWaitsForTheFirstUsableFix(logger) {
    var R = $.GpsDiag.GPS_REARM_MS;
    var p = new GpsProbe();
    p.sessionReset(100000);
    p.note(2, 100000);                 // POOR: a callback, but not a usable fix
    p.setNowMs(100000 + 10 * R);
    p.watchdog();
    if (p.starts != 0) {
        logger.error("no usable fix has ever been seen, so no re-arm; starts=" +
                     p.starts);
        return false;
    }
    return true;
}

// The snapshot: SLOTS long, version in slot 0, every counter clamped, and
// I_LAST_CB_S derived from the two stamps rather than accumulated.
(:test) function test_gps_c1_theSnapshotIsSlotsLongAndDerivesTheLastCallback(logger) {
    var p = new GpsProbe();
    p.sessionReset(100000);
    p.note(4, 112500);                        // 12.5 s into the row
    p.setSlot($.GpsDiag.I_CB_TOTAL, 99999);   // past the ceiling
    p.setSlot($.GpsDiag.I_FORM, $.GpsDiag.FORM_CONFIG);
    var a = p.snapshot();
    var ok = true;
    if (a.size() != $.GpsDiag.SLOTS) {
        logger.error("the snapshot must be SLOTS long -- a setData array longer " +
                     "than :count is an uncatchable System Error at save time; " +
                     "got " + a.size());
        return false;
    }
    if (a[$.GpsDiag.I_VERSION] != $.GpsDiag.VERSION) {
        logger.error("slot 0 must carry the layout version; got " +
                     a[$.GpsDiag.I_VERSION]);
        ok = false;
    }
    if (a[$.GpsDiag.I_CB_TOTAL] != $.GpsDiag.MAXV) {
        logger.error("counters clamp at readout; got " + a[$.GpsDiag.I_CB_TOTAL]);
        ok = false;
    }
    if (a[$.GpsDiag.I_LAST_CB_S] != 12) {
        logger.error("the last callback is 12.5 s into the row and truncates to " +
                     "12; got " + a[$.GpsDiag.I_LAST_CB_S]);
        ok = false;
    }
    if (a[$.GpsDiag.I_FORM] != $.GpsDiag.FORM_CONFIG) {
        logger.error("the enable answer reaches the snapshot; got " +
                     a[$.GpsDiag.I_FORM]);
        ok = false;
    }
    return ok;
}

// ===========================================================================
// c2 -- RED DIFFERENTIALS ONLY. Every case below FAILS on the commit that
// precedes it and passes once the fix lands. Each one drives a SHIPPING ENTRY
// POINT that already exists at c1 -- onPosition, onTick, startGps,
// gpsPipColour -- so what it measures is that the WIRING is absent, not that a
// symbol is missing.
// ===========================================================================

// THE DEFECT THE ROWER SAW. A usable fix, then silence, then a pip that still
// says green.
//
// Three renders, because two of them are the boundary and the third is the
// field's own shape. The first stays green in every epoch (it is the c0
// colouring, one millisecond inside the window); the second and third are the
// change.
(:test) function test_gps_c2_thePipGoesStaleAfterTheFreshnessWindow(logger) {
    var F = $.GpsDiag.GPS_FRESH_MS;
    var ok = true;
    var p = new GpsProbe();
    p.setNowMs(500000);
    p.feed(4);
    var fresh = gpsRender(p, p.kindWarm(), 500000 + F - 1);
    if (fresh.colourOf("GPS") != Gfx.COLOR_GREEN) {
        logger.error("one ms inside the window the pip is still green; got " +
                     fresh.colourOf("GPS"));
        ok = false;
    }
    var q = new GpsProbe();
    q.setNowMs(500000);
    q.feed(4);
    var edge = gpsRender(q, q.kindWarm(), 500000 + F);
    if (edge.colourOf("GPS") != Gfx.COLOR_DK_GRAY) {
        logger.error("at exactly GPS_FRESH_MS the pip must carry the no-data " +
                     "colour, not the last accuracy; got " + edge.colourOf("GPS"));
        ok = false;
    }
    // i185890690's shape: one good fix and then 43 minutes of nothing.
    var r = new GpsProbe();
    r.setNowMs(500000);
    r.feed(4);
    var dead = gpsRender(r, r.kindWarm(), 500000 + 2628000);
    if (dead.colourOf("GPS") != Gfx.COLOR_DK_GRAY) {
        logger.error("after 43.8 min of silence the pip must not still report " +
                     "the last fix; got " + dead.colourOf("GPS"));
        ok = false;
    }
    return ok;
}

// onPosition must do the bookkeeping, not just latch the accuracy.
//
// DRIVEN THROUGH onPosition, the platform's own entry point, so this cannot
// pass against a gpsNote that nothing calls -- which is exactly the state at
// c1, where test_gps_c1_theCallbackNoteCountsAndStamps is green and this is
// red.
(:test) function test_gps_c2_onPositionStampsAndCountsTheCallback(logger) {
    var p = new GpsProbe();
    p.sessionReset(100000);
    p.setNowMs(101000); p.feed(4);
    p.setNowMs(104000); p.feed(3);
    p.setNowMs(124000); p.feed(null);
    var ok = true;
    if (p.lastGpsMs() != 124000) {
        logger.error("onPosition must stamp the arrival; mLastGpsMs=" +
                     p.lastGpsMs());
        ok = false;
    }
    if (!p.everSeen()) {
        logger.error("a usable fix reached onPosition, so the ever-latch must be set");
        ok = false;
    }
    var want = [[$.GpsDiag.I_CB_TOTAL,  3, "every callback counts"],
                [$.GpsDiag.I_CB_USABLE, 2, "accuracy >= 3"],
                [$.GpsDiag.I_CB_GOOD,   1, "accuracy == 4"],
                [$.GpsDiag.I_LAST_ACC,  3, "the last GRADED accuracy"],
                [$.GpsDiag.I_MAXGAP_S, 20, "the 20 s between 104000 and 124000"]];
    for (var i = 0; i < want.size(); i++) {
        if (p.slot(want[i][0]) != want[i][1]) {
            logger.error("slot " + want[i][0] + " (" + want[i][2] + ") = " +
                         p.slot(want[i][0]) + ", expected " + want[i][1]);
            ok = false;
        }
    }
    var a = p.snapshot();
    if (a[$.GpsDiag.I_LAST_CB_S] != 24) {
        logger.error("the last callback is 24 s after START; snapshot says " +
                     a[$.GpsDiag.I_LAST_CB_S]);
        ok = false;
    }
    return ok;
}

// The watchdog has to be WIRED to the tick, not merely to exist.
//
// At c1 test_gps_c1_theWatchdogSeamRearmsAtMostOncePerWindow is green while
// this is red, and the pair is the whole point: one pins the decision, the
// other pins that anything ever asks it.
(:test) function test_gps_c2_theTickRearmsAStaleStream(logger) {
    var R = $.GpsDiag.GPS_REARM_MS;
    var p = new GpsProbe();
    p.sessionReset(100000);
    p.setNowMs(100000);
    p.feed(4);
    var ok = true;
    p.setNowMs(100000 + R - 1);
    p.onTick();
    if (p.starts != 0) {
        logger.error("one ms short of the window the tick must not re-arm; starts=" +
                     p.starts);
        ok = false;
    }
    p.setNowMs(100000 + R);
    p.onTick();
    p.onTick();
    p.onTick();
    if (p.starts != 1) {
        logger.error("three ticks inside one window re-arm ONCE; starts=" + p.starts);
        ok = false;
    }
    if (p.slot($.GpsDiag.I_REARMS) != 1) {
        logger.error("the re-arm must be counted; slot says " +
                     p.slot($.GpsDiag.I_REARMS));
        ok = false;
    }
    p.setNowMs(100000 + 2 * R);
    p.onTick();
    if (p.starts != 2) {
        logger.error("the next window re-arms again; starts=" + p.starts);
        ok = false;
    }
    return ok;
}

// startGps must CHOOSE a form and RECORD which one it got.
//
// The three flag bits are driven by the probe rather than read off the runner,
// so this pins the code and not fr965 -- see the note on gpsCapConfigApi above.
(:test) function test_gps_c2_startGpsChoosesTheConfigurationForm(logger) {
    var p = new GpsProbe();
    p.capCfgApi = true;
    p.capSatIq  = true;
    p.capConst  = true;
    p.realStartGps();
    var ok = true;
    if (!arrEq(p.attempted, [$.GpsDiag.FORM_CONFIG], logger,
               "the ladder must ask for the configuration form FIRST and stop " +
               "there when it succeeds")) {
        ok = false;
    }
    if (p.slot($.GpsDiag.I_FORM) != $.GpsDiag.FORM_CONFIG) {
        logger.error("the form that succeeded must reach slot I_FORM; got " +
                     p.slot($.GpsDiag.I_FORM));
        ok = false;
    }
    if (p.slot($.GpsDiag.I_ENABLE_THROW) != 0) {
        logger.error("nothing threw; I_ENABLE_THROW=" +
                     p.slot($.GpsDiag.I_ENABLE_THROW));
        ok = false;
    }
    var want = $.GpsDiag.F_CFG_API | $.GpsDiag.F_SATIQ_OK | $.GpsDiag.F_CONST_API;
    if (p.slot($.GpsDiag.I_FLAGS) != want) {
        logger.error("all three capability bits must be recorded; I_FLAGS=" +
                     p.slot($.GpsDiag.I_FLAGS) + ", expected " + want);
        ok = false;
    }
    // The device that has none of it falls to the legacy call, and its flags
    // say so -- which is what tells a reader of a mute row which half failed.
    var q = new GpsProbe();
    q.realStartGps();
    if (!arrEq(q.attempted, [$.GpsDiag.FORM_LEGACY], logger,
               "no capability at all means the legacy call and nothing else")) {
        ok = false;
    }
    if (q.slot($.GpsDiag.I_FORM) != $.GpsDiag.FORM_LEGACY) {
        logger.error("the legacy form must be recorded too; got " +
                     q.slot($.GpsDiag.I_FORM));
        ok = false;
    }
    if (q.slot($.GpsDiag.I_FLAGS) != 0) {
        logger.error("no capability bits should be set; I_FLAGS=" +
                     q.slot($.GpsDiag.I_FLAGS));
        ok = false;
    }
    return ok;
}

// A throw on one rung must leave the next one reachable, and the fall-through
// must SKIP a rung the device cannot support rather than charging it to the
// throw counter.
(:test) function test_gps_c2_theEnableLadderFallsThroughAThrow(logger) {
    var ok = true;
    var p = new GpsProbe();
    p.capCfgApi = true;
    p.capSatIq  = true;
    p.capConst  = true;
    p.failForms = [$.GpsDiag.FORM_CONFIG, $.GpsDiag.FORM_CONST];
    p.realStartGps();
    if (!arrEq(p.attempted,
               [$.GpsDiag.FORM_CONFIG, $.GpsDiag.FORM_CONST, $.GpsDiag.FORM_LEGACY],
               logger, "two throws must walk the ladder to the legacy call")) {
        ok = false;
    }
    if (p.slot($.GpsDiag.I_FORM) != $.GpsDiag.FORM_LEGACY) {
        logger.error("the rung that SUCCEEDED is the one recorded; got " +
                     p.slot($.GpsDiag.I_FORM));
        ok = false;
    }
    if (p.slot($.GpsDiag.I_ENABLE_THROW) != 2) {
        logger.error("two rungs threw; I_ENABLE_THROW=" +
                     p.slot($.GpsDiag.I_ENABLE_THROW));
        ok = false;
    }
    // No constellation symbols: that rung is SKIPPED, not attempted and failed.
    var q = new GpsProbe();
    q.capCfgApi = true;
    q.capSatIq  = true;
    q.capConst  = false;
    q.failForms = [$.GpsDiag.FORM_CONFIG];
    q.realStartGps();
    if (!arrEq(q.attempted, [$.GpsDiag.FORM_CONFIG, $.GpsDiag.FORM_LEGACY], logger,
               "a device with no CONSTELLATION_* symbols must skip that rung")) {
        ok = false;
    }
    if (q.slot($.GpsDiag.I_ENABLE_THROW) != 1) {
        logger.error("only one rung threw -- a skipped rung is not a throw; " +
                     "I_ENABLE_THROW=" + q.slot($.GpsDiag.I_ENABLE_THROW));
        ok = false;
    }
    // Every rung throws: no form succeeded, and the slot says so rather than
    // naming a form that did not work.
    var r = new GpsProbe();
    r.capCfgApi = true;
    r.capSatIq  = true;
    r.capConst  = true;
    r.failForms = [$.GpsDiag.FORM_CONFIG, $.GpsDiag.FORM_CONST, $.GpsDiag.FORM_LEGACY];
    r.realStartGps();
    if (r.slot($.GpsDiag.I_FORM) != $.GpsDiag.FORM_NONE) {
        logger.error("no rung succeeded, so I_FORM must be FORM_NONE; got " +
                     r.slot($.GpsDiag.I_FORM));
        ok = false;
    }
    if (r.slot($.GpsDiag.I_ENABLE_THROW) != 3) {
        logger.error("three rungs threw; I_ENABLE_THROW=" +
                     r.slot($.GpsDiag.I_ENABLE_THROW));
        ok = false;
    }
    return ok;
}

// ===========================================================================
// c2' -- FIX-ROUND 1's RED DIFFERENTIAL. Fails on the commit that precedes it
// and passes once the guard lands.
// ===========================================================================

// THE MUTE ROW, on the negative half of the clock. Round 1's behaviour lens,
// P1-1.
//
// secsBetween tested the never-seen sentinel on `fromMs` ONLY, and its one call
// site -- gpsDiagSnapshot's
// `secsBetween(mGpsBaseMs, mLastGpsMs)` -- carries the sentinel in `toMs`:
// mLastGpsMs is 0 for a row that received no callback at all. mGpsBaseMs is
// raw System.getTimer() at START, which is NEGATIVE for 25 of every 50 days of
// device uptime (#70), so `0 - fromMs` is POSITIVE, the `d < 0` guard does not
// fire, and slot 4 reported |fromMs| / 1000 clamped at MAXV.
//
// That lands on the mute row specifically -- the one row gps_diag exists to
// explain (source/StrongRowView.mc says so at the createField site) -- and it
// makes #214's decode rule `total_elapsed_time - I_LAST_CB_S` produce nonsense
// exactly where a reader needs it.
//
// A c2' CASE RATHER THAN A ROW IN the c1 secondsBetween case, which is what
// the verdict suggested. The two are not equivalent: a row added
// to a case that is green at the head cannot produce red-before-green evidence
// for this round, and this is a behaviour change. The c1 case is left alone and
// stays green throughout.
//
// CALLS THE SHIPPING FUNCTION, not a transliteration of it. The lens verified
// P1-1 by re-implementing secsBetween in Python and said so; this case is what
// makes the same statement in Monkey C, on the arithmetic the device runs.
(:test) function test_gps_c2p_theMuteRowReportsNoDurationOnANegativeClock(logger) {
    var ok = true;
    // [from, to, expected] -- the sentinel in EITHER argument means 0.
    var rows = [[-100000,     0, 0],    // mute row, 100 s of negative uptime
                [-1500000,    0, 0],    // mute row, 25 min in
                [-2147000000, 0, 0],    // mute row, near the far end of the half
                [100000,      0, 0],    // mute row, positive clock: already 0
                [0,      500000, 0],    // the symmetric case, already guarded
                [0,     -500000, 0],
                [0,           0, 0]];
    for (var i = 0; i < rows.size(); i++) {
        var got = $.GpsDiag.secsBetween(rows[i][0], rows[i][1]);
        if (got != rows[i][2]) {
            logger.error("secsBetween(" + rows[i][0] + ", " + rows[i][1] + ") = " +
                         got + ", expected " + rows[i][2] +
                         " -- a never-seen stamp in EITHER argument is 0 seconds, " +
                         "never a duration since device boot");
            ok = false;
        }
    }
    // And the same fact through the shipping snapshot, so this cannot pass
    // against a guarded secsBetween that gpsDiagSnapshot stops calling.
    var p = new GpsProbe();
    p.sessionReset(-1500000);          // START on the negative half of the clock
    var a = p.snapshot();              // no callback has ever arrived
    if (a[$.GpsDiag.I_LAST_CB_S] != 0) {
        logger.error("a row with no callback at all must report 0 in slot 4; got " +
                     a[$.GpsDiag.I_LAST_CB_S] + " -- #214 computes the end-of-row " +
                     "gap as total_elapsed_time minus this slot");
        ok = false;
    }
    if (a[$.GpsDiag.I_CB_TOTAL] != 0) {
        logger.error("premise of this case: no callback was fed; I_CB_TOTAL=" +
                     a[$.GpsDiag.I_CB_TOTAL]);
        ok = false;
    }
    return ok;
}

}
