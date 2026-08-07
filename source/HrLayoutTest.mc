using Toybox.Test;
using Toybox.Graphics as Gfx;
using Toybox.System;
using Toybox.Math;
using Toybox.Lang;

// Layout suite for #110's left-edge heart-rate arc.
//
// WHAT HAPPENED, because the shape of this file is a consequence of it.
//
// #22's systemic finding is that every string width in this application is
// ASSUMED -- getTextWidthInPixels, getFontHeight and getTextDimensions were
// called NOWHERE in the repository. The arc's first clearance argument was
// derived arithmetic of exactly that kind and it was wrong twice over: it
// tracked each primitive's CENTRELINE rather than its outermost pixel, and it
// assumed text extents. Measured against real font metrics, the arc overlapped
// rendered text on 11 of the 12 manifest devices -- worst -23.3 px on
// fenix843mm and -21.4 px on fr965, at STEP_GATE.
//
// That measurement was done with a real Dc, obtained inside a (:test) through
// a buffered bitmap, and it drove the geometry fix. It CANNOT RUN IN CI: the
// container's simulator segfaults the moment a test obtains a graphics Dc --
// `Segmentation fault (core dumped)`, no summary line, harness failure rather
// than a verdict. Isolated to a single case that did nothing else, reproduced
// four times, and filed as #121. It is an environment limitation, not an API
// or SDK one: the identical .prg measures correctly on a desktop simulator, on
// all twelve devices.
//
// SO THE WORK IS SPLIT, and the split is stated rather than hidden:
//
//   * the text measurement is LOCAL. Its per-device results are recorded in
//     PR #119 and re-run by hand, not on every push. #121 owns closing that.
//   * what runs HERE is font-free and needs no Dc: the arc's own geometry,
//     captured from the shipping draw path through a recording Dc. These cases
//     cannot see a text box. What they CAN see is every way the arc could
//     drift back toward the text it was moved away from -- which is the
//     regression the local measurement cannot catch between runs.
//
// Neither half is described as the other. Nothing here claims a collision has
// been proven absent in CI, and nothing here claims anything about legibility
// or about how any of this looks on a wrist.
//
// Execution note: the run-tests CI job runs these headlessly in the simulator
// on fr965. Test names are pinned in scripts/expected_tests.txt -- update that
// file in the same commit as any (:test) change. See docs/CI.md.

// The arc's outward bound, as a fraction of display width: no pixel it draws
// may sit at or right of this. MEASURED, on all twelve manifest devices, from
// the same recording used for the collision figures.
//
// RAISED FROM 0.16 BY #108, and the reason is geometric rather than a
// relaxation of standards. The outermost drawn pixel is the band tick at a
// sweep END, at the arc's INNER radius -- x = cx - rTkIn*cos(S) + ptk/2 -- so
// widening the sweep moves it right even though nothing about the radii
// changes. At the shipping +/-22 it landed between 0.1377w and 0.1526w
// (fenix6spro, 240 px, where the integer truncation of every derived dimension
// bites hardest); at #108's +/-28 it lands between 0.1552w (the four 454 px
// devices) and 0.1694w (fenix6spro). The pin is 0.18w: above every measured
// value with room for rounding, and still below the nearest text a WORK or
// REST screen draws.
//
// The pin was WIDENED, so between the commit that widened it and the commit
// that widened the sweep the lane guard is looser than the geometry needs.
// That is unavoidable when a lane grows and is stated rather than hidden.
//
// This is the invariant that keeps the geometry fix from silently unwinding. A
// smaller radius, a longer tick or a fatter pen all push the outermost pixel
// right, toward the centred numerals -- and all of them red here before they
// can reach the text.
const HL_X_MAX_FRAC = 0.18;

// The arc's vertical half-extent, as a fraction of display height: no pixel it
// draws may sit further than this above or below the centreline.
//
// WHY THIS EXISTS. The x envelope above bounds the arc's LANE, and it gets
// GREENER as the sweep widens in one important sense and worse in another: a
// wider sweep pushes the outermost pixel right AND pushes the arc's ends down
// and up, toward the rows the arc was moved away from. Nothing in this
// repository could see the second motion. This is the companion that can.
//
// WHAT IT DOES NOT CLAIM. It is a SWEEP guard, not a collision proof. The
// nearest text below the arc on a work screen sits at |dy| = 0.20h, INSIDE
// this bound, and does not collide because it is horizontally separated --
// which no font-free case can see. What this pins is that the sweep stays at
// the width that was MEASURED clear against real font metrics on all twelve
// devices (recorded in the pull request, per #121 not re-runnable in CI).
// Anything that widens it reds here and has to be re-measured rather than
// assumed.
//
// MEASURED at #108's +/-28 over all twelve manifest devices: the worst
// half-extent is 0.2351h (the four 454 px devices) and the smallest 0.2332h
// (fenix6spro). The pin is 0.245h -- above every measured value with room for
// rounding, and below the 0.2500h that +/-30 would produce, so the next whole
// degree of widening past what was measured reds.
const HL_Y_MAX_FRAC = 0.245;

// Sampling resolution, in degrees, along an arc path. At the largest radius
// this app draws one degree is about 3.4 px and the smallest pen width in
// force on any arc is 4, so consecutive samples overlap and the model covers
// the swept region rather than dotting it.
const HL_ARC_STEP_DEG = 1.0;

// -- A Dc that records full geometry -------------------------------------------
// HrDc (HrArcTest.mc) counts primitives; this one keeps their coordinates,
// which is what a geometric bound needs. Kept separate rather than widening
// HrDc: the counting cases assert on shape and would be noisier for carrying
// geometry they never read.
class HrGeoDc {
    var w; var h;
    var pen;      // pen width currently in force
    var arcs;     // [cx, cy, r, penAtIssue, degLo, degHi]
    var lines;    // [x0, y0, x1, y1, penAtIssue]
    var texts;    // [x, y, font, string, justify]

    function initialize(width, height) {
        w = width; h = height; pen = 1;
        arcs = []; lines = []; texts = [];
    }

    function getWidth()  { return w; }
    function getHeight() { return h; }
    function setColor(fg, bg) { }
    function clear() { }
    function setPenWidth(p) { pen = p; }

    // Normalised to [lo, hi] regardless of the direction flag: the swept set of
    // pixels is the same either way, and a bound only cares about the set.
    function drawArc(x, y, r, attr, degStart, degEnd) {
        var lo = degStart;
        var hi = degEnd;
        if (lo > hi) { var t = lo; lo = hi; hi = t; }
        arcs.add([x, y, r, pen, lo, hi]);
    }

    function drawLine(x0, y0, x1, y1) { lines.add([x0, y0, x1, y1, pen]); }

    function drawText(x, y, font, s, just) { texts.add([x, y, font, s, just]); }
}

// The rightmost pixel any primitive in this render occupies. Arcs are sampled
// along their path and lines at their endpoints, and every sample is widened by
// half its pen: the OUTERMOST PIXEL, not the centreline, which is the reading
// the original derivation got wrong.
function hlMaxDrawnX(geo) {
    var maxX = -9999.0;

    for (var a = 0; a < geo.arcs.size(); a++) {
        var arc = geo.arcs[a];
        var cx = arc[0]; var r = arc[2];
        var half = arc[3] / 2.0;
        var deg = arc[4];
        var end = arc[5];
        while (true) {
            var x = cx + r * Math.cos(deg * Math.PI / 180.0) + half;
            if (x > maxX) { maxX = x; }
            if (deg >= end) { break; }
            deg += $.HL_ARC_STEP_DEG;
            if (deg > end) { deg = end; }
        }
    }

    for (var l = 0; l < geo.lines.size(); l++) {
        var ln = geo.lines[l];
        var half2 = ln[4] / 2.0;
        var xa = ln[0] + half2;
        var xb = ln[2] + half2;
        if (xa > maxX) { maxX = xa; }
        if (xb > maxX) { maxX = xb; }
    }

    return maxX;
}

// The greatest distance above OR below the centreline that any primitive in
// this render occupies. Same expansion rule as hlMaxDrawnX: arcs are sampled
// along their path, lines at their endpoints, and every sample is widened by
// half its pen -- the OUTERMOST PIXEL, not the centreline.
function hlMaxDrawnDy(geo) {
    var cy = geo.h / 2.0;
    var maxDy = -9999.0;

    for (var a = 0; a < geo.arcs.size(); a++) {
        var arc = geo.arcs[a];
        var cyA = arc[1]; var r = arc[2];
        var half = arc[3] / 2.0;
        var deg = arc[4];
        var end = arc[5];
        while (true) {
            var y = cyA - r * Math.sin(deg * Math.PI / 180.0);
            var dy = y - cy;
            if (dy < 0.0) { dy = -dy; }
            dy += half;
            if (dy > maxDy) { maxDy = dy; }
            if (deg >= end) { break; }
            deg += $.HL_ARC_STEP_DEG;
            if (deg > end) { deg = end; }
        }
    }

    for (var l = 0; l < geo.lines.size(); l++) {
        var ln = geo.lines[l];
        var half2 = ln[4] / 2.0;
        var da = ln[1] - cy; if (da < 0.0) { da = -da; }
        var db = ln[3] - cy; if (db < 0.0) { db = -db; }
        da += half2; db += half2;
        if (da > maxDy) { maxDy = da; }
        if (db > maxDy) { maxDy = db; }
    }

    return maxDy;
}

// -- Configuration space -------------------------------------------------------

// The band extremes of the range settings.xml declares, plus the shipped
// default. The extremes are the interesting ones: they put the band marker at
// the very top and the very bottom of the sweep, which is where it reaches
// furthest toward the rows above and below.
function hlBands() {
    return [ [116, 130], [$.HR_DISP_LO, $.HR_DISP_LO],
             [$.HR_DISP_HI, $.HR_DISP_HI], [$.HR_DISP_LO, $.HR_DISP_HI] ];
}

// Absent, in band, clamped low, clamped high.
function hlHrStates() {
    return [ [0, false], [123, true], [$.HR_DISP_LO - 20, true],
             [$.HR_DISP_HI + 20, true] ];
}

// ONE PROBE PER SWEEP, not one per render. Constructing an HrProbe runs the
// full StrongRowView initialize -- a 128-slot autocorrelation buffer, a 90-slot
// R-R difference buffer, and one dictionary per workout step. One per render
// put thousands of live objects through a watch-sized heap inside a single
// (:test) and was a plausible enough cause of the CI crash to be worth fixing
// on its own, even though the crash turned out to be #121.
function hlProbeFor(wide) {
    var p = new HrProbe();
    p.driveStrokes();
    if (wide) { p.setWorkoutShape(30, 3600); }
    return p;
}

// The configuration arrives as ONE ARRAY rather than as separate parameters,
// and that is forced rather than stylistic: at ten parameters monkeyc rejects
// the declaration with "Too many arguments passed to method" -- but only in the
// SHIPPING build, so the --unit-test compile passes on all twelve devices and
// release-build is the job that fails. Layout of cfg:
//   [0] kind        step-type constant, or -1 pre-START, or -2 free row
//   [1] paused
//   [2] bandLo      [3] bandHi
//   [4] hrBpm       [5] hrLive
//   [6] sensorOk
//   [7] wide        drive every data-dependent string to its maximum
function hlRender(p, cfg) {
    var kind = cfg[0];
    var wide = cfg[7];
    var ds = System.getDeviceSettings();
    // Restored on every render, not only when entering free row: a reused probe
    // would otherwise render every kind after free-row AS free-row, which draws
    // no arc and would pass every later case for the wrong reason.
    p.setWorkoutEnabled(kind != -2);
    p.setBand(cfg[2], cfg[3]);
    p.setSensorOk(cfg[6]);
    if (cfg[5]) { p.setHrState(cfg[4], System.getTimer(), true); }
    else        { p.setHrState(cfg[4], 0, false); }

    if (kind == -2)      { p.setFreeRow(); }
    else if (kind == -1) { p.enterPreStart(); }
    else if (wide)       { p.enterStepLive(kind, cfg[1]); }
    else                 { p.enterStep(kind, cfg[1]); }

    if (wide) {
        p.setWideSession();
        p.setSpeed(6.0);
    } else {
        p.setNarrowSession();
        p.setSpeed(0.0);
    }

    var geo = new HrGeoDc(ds.screenWidth, ds.screenHeight);
    p.runUpdate(geo);
    return geo;
}

// -- The cases -----------------------------------------------------------------

// THE SCREENS THAT MUST DRAW NO ARC AT ALL.
//
// STEP_GATE is the one that matters and the one this round is about. Its
// headline is "PRESS START" in FONT_MEDIUM, centred and vertically centred at
// h*0.30, and it is enormous relative to the display -- on fenix843mm it spans
// 74% of the width. Measured, the arc overlapped it by 21-23 px on the five
// largest devices at DEFAULT settings, from the track alone.
//
// #110's acceptance list asks for the arc during GATE, so excluding it is a
// listed departure, argued at the call site in StrongRowView.onUpdate: keeping
// it would have forced the sweep to about +/-16 degrees on every device to
// satisfy one screen, coarsening the band marker everywhere to serve the screen
// where nobody is rowing.
//
// This case is what stops that decision from quietly unwinding, and it needs no
// font metrics to do it.
(:test) function test_hr_arclessScreensDrawNoArcGeometry(logger) {
    var k = new HrProbe();
    var kinds = [ k.kindGate(), k.kindWarm(), k.kindCool(), k.kindDone(), -1, -2 ];
    var names = [ "GATE", "WARM", "COOL", "DONE", "pre-START", "free-row" ];
    var bands = hlBands();
    var hrs = hlHrStates();
    var p = hlProbeFor(true);

    for (var ki = 0; ki < kinds.size(); ki++) {
        for (var bi = 0; bi < bands.size(); bi++) {
            for (var hi = 0; hi < hrs.size(); hi++) {
                var geo = hlRender(p, [kinds[ki], false, bands[bi][0], bands[bi][1],
                                       hrs[hi][0], hrs[hi][1], true, true]);
                if (geo.arcs.size() != 0 || geo.lines.size() != 0) {
                    logger.error("#110: " + names[ki] + " must draw NO arc " +
                                 "geometry -- it has no room for it. Got " +
                                 geo.arcs.size() + " arcs and " + geo.lines.size() +
                                 " lines, at band " + bands[bi][0] + "-" +
                                 bands[bi][1] + ", hr " + hrs[hi][0] +
                                 (hrs[hi][1] ? "" : "(absent)"));
                    return false;
                }
                if (geo.texts.size() < 3) {
                    logger.error(names[ki] + " drew only " + geo.texts.size() +
                                 " text elements, so the check above proves " +
                                 "nothing about it");
                    return false;
                }
            }
        }
    }
    return true;
}

// THE OUTWARD BOUND, on the two screens that do draw the arc.
//
// This is the font-free half of the collision fix. It cannot see a text box, so
// it does not claim the arc clears one -- that was measured locally, on all
// twelve devices, and is recorded in PR #119 with #121 explaining why it cannot
// be re-measured here. What it does claim is the property that measurement
// depended on: the arc stays in its left-edge lane.
//
// Every knob that could undo the fix moves the outermost pixel RIGHT -- a
// smaller radius, a wider sweep, a longer head tick, a fatter pen, a band
// marker allowed past the sweep ends -- so all of them red here first.
(:test) function test_hr_arcStaysWithinItsXEnvelope(logger) {
    var k = new HrProbe();
    var kinds = [ k.kindWork(), k.kindRest() ];
    var names = [ "WORK", "REST" ];
    var bands = hlBands();
    var hrs = hlHrStates();
    var ds = System.getDeviceSettings();
    var limit = ds.screenWidth * $.HL_X_MAX_FRAC;
    var worst = -9999.0;
    var where = "none";

    for (var wi = 0; wi < 2; wi++) {
        var p = hlProbeFor(wi == 1);
        for (var ki = 0; ki < kinds.size(); ki++) {
            for (var bi = 0; bi < bands.size(); bi++) {
                for (var hi = 0; hi < hrs.size(); hi++) {
                    for (var vi = 0; vi < 4; vi++) {
                        var paused  = (vi & 1) != 0;
                        var accelOk = (vi & 2) == 0;
                        var geo = hlRender(p, [kinds[ki], paused,
                                               bands[bi][0], bands[bi][1],
                                               hrs[hi][0], hrs[hi][1],
                                               accelOk, wi == 1]);
                        if (geo.arcs.size() == 0 && geo.lines.size() == 0) {
                            logger.error(names[ki] + " drew no arc geometry at " +
                                         "all; the bound below would be vacuous");
                            return false;
                        }
                        var mx = hlMaxDrawnX(geo);
                        if (mx > worst) {
                            worst = mx;
                            where = names[ki] + (paused ? "/PAUSED" : "") +
                                    (accelOk ? "" : "/NO-ACCEL") +
                                    " band " + bands[bi][0] + "-" + bands[bi][1] +
                                    " hr " + hrs[hi][0] +
                                    (hrs[hi][1] ? "" : "(absent)") +
                                    (wi == 1 ? " wide" : " narrow");
                        }
                    }
                }
            }
        }
    }

    logger.debug("HL envelope " + ds.screenWidth + "x" + ds.screenHeight +
                 ": outermost drawn x " + worst.format("%.1f") + " (" +
                 (worst / ds.screenWidth).format("%.4f") + "w), limit " +
                 limit.format("%.1f") + " @ " + where);

    if (worst >= limit) {
        logger.error("#110/#108: the heart-rate arc has drifted out of its lane. " +
                     "Outermost drawn pixel x=" + worst.format("%.1f") +
                     " on a " + ds.screenWidth + "-wide display, limit " +
                     limit.format("%.1f") + " (" + $.HL_X_MAX_FRAC +
                     "w), at " + where + ". Measured at the PEN WIDTH, not " +
                     "the centreline. Every pixel right of that lane is a " +
                     "pixel closer to the centred numerals the arc was moved " +
                     "away from -- see PR #119 for the measured clearances.");
        return false;
    }
    return true;
}

// THE VERTICAL BOUND, on the two screens that draw the arc.
//
// The companion the x envelope needed and did not have. #108 widens the sweep
// from +/-22 to +/-28, and the x envelope alone cannot police that: widening
// pushes the outermost pixel right by a little and the arc's two ends down and
// up by a lot, and only the first of those was ever measured by a case.
//
// Read the bound as "the sweep is still the width that was measured clear",
// not as "nothing collides". Text at these heights is cleared HORIZONTALLY,
// which needs font metrics this suite cannot obtain (#121); those clearances
// are in the pull request, per device.
//
// The configuration is narrower than the x case's on purpose and the reason is
// that the two are not measuring the same thing. The vertical extreme is
// reached by the head tick at a sweep END, which happens exactly when the
// reading is clamped off either end of the display range -- so the band and
// heart-rate sweeps are what matter, and pause / accelerometer state cannot
// move it (neither is read by drawHrArc).
(:test) function test_hr_arcStaysWithinItsYEnvelope(logger) {
    var k = new HrProbe();
    var kinds = [ k.kindWork(), k.kindRest() ];
    var names = [ "WORK", "REST" ];
    var bands = hlBands();
    var hrs = hlHrStates();
    var ds = System.getDeviceSettings();
    var limit = ds.screenHeight * $.HL_Y_MAX_FRAC;
    var worst = -9999.0;
    var where = "none";
    var p = hlProbeFor(true);

    for (var ki = 0; ki < kinds.size(); ki++) {
        for (var bi = 0; bi < bands.size(); bi++) {
            for (var hi = 0; hi < hrs.size(); hi++) {
                var geo = hlRender(p, [kinds[ki], false,
                                       bands[bi][0], bands[bi][1],
                                       hrs[hi][0], hrs[hi][1], true, true]);
                if (geo.arcs.size() == 0 && geo.lines.size() == 0) {
                    logger.error(names[ki] + " drew no arc geometry at all; " +
                                 "the bound below would be vacuous");
                    return false;
                }
                var dy = hlMaxDrawnDy(geo);
                if (dy > worst) {
                    worst = dy;
                    where = names[ki] + " band " + bands[bi][0] + "-" +
                            bands[bi][1] + " hr " + hrs[hi][0] +
                            (hrs[hi][1] ? "" : "(absent)");
                }
            }
        }
    }

    logger.debug("HL y-envelope " + ds.screenWidth + "x" + ds.screenHeight +
                 ": max |dy| " + worst.format("%.1f") + " (" +
                 (worst / ds.screenHeight).format("%.4f") + "h), limit " +
                 limit.format("%.1f") + " @ " + where);

    if (worst >= limit) {
        logger.error("#108: the heart-rate arc's sweep has grown past the " +
                     "width that was measured clear. Furthest drawn pixel is " +
                     worst.format("%.1f") + " px from the centreline on a " +
                     ds.screenHeight + "-tall display, limit " +
                     limit.format("%.1f") + " (" + $.HL_Y_MAX_FRAC +
                     "h), at " + where + ". Measured at the PEN WIDTH, not " +
                     "the centreline. A wider sweep moves the arc's ends DOWN " +
                     "and UP toward the rows it was moved away from, and the " +
                     "x envelope cannot see that motion -- re-measure the " +
                     "clearances on all twelve devices before raising this.");
        return false;
    }
    return true;
}
