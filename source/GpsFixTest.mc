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
    function initialize() { HrProbe.initialize(); }

    // `hidden` is protected in Monkey C, so this reads the shipping field
    // rather than a copy of it.
    function gpsQual() { return mGpsQual; }

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

}
