using Toybox.Test;
using Toybox.Graphics as Gfx;
using Toybox.System;
using Toybox.Math;
using Toybox.Lang;

// Layout collision suite for #110's left-edge heart-rate arc.
//
// WHY THIS FILE EXISTS. #22's systemic finding is that every string width in
// this application is ASSUMED: `getTextWidthInPixels`, `getFontHeight` and
// `getTextDimensions` were called NOWHERE in the repository. The arc's own
// clearance argument was derived arithmetic of exactly that kind, and a review
// found it wrong -- the arc collides with rendered text in states the
// derivation never considered. Derivation is what failed; measurement is the
// fix. This file contains the repository's first getTextWidthInPixels call.
//
// WHAT IT MEASURES, and the two places it is deliberately conservative:
//
//   * text occupies a BOX, obtained from the real font metrics of a real Dc --
//     width from getTextWidthInPixels, height from getFontHeight -- placed
//     according to the justification flags the shipping call actually passed;
//   * arc and line primitives occupy PIXELS, not paths. Every primitive is
//     sampled along its path and each sample contributes a square patch of the
//     side of the pen width in force when it was issued. "Outermost drawn
//     pixel" therefore means the pixel, which is the reading that matters and
//     the one an earlier centreline-only derivation got wrong.
//
// The sampling step is chosen so consecutive patches OVERLAP (arc step
// r*1deg <= pen width for every radius and pen this app uses), so the model
// covers the swept region rather than dotting it.
//
// WHAT IT DOES NOT MEASURE, stated so nothing here is read as more than it is:
// glyph boxes are not glyphs. A box is the advance width and the font height,
// so a string clears by a margin at least as large as this reports -- the model
// is conservative in the safe direction. And none of it says anything about
// legibility, or about how any of this looks on a wrist. No job in this
// repository renders a screen.
//
// Execution note: the run-tests CI job runs these headlessly in the simulator
// on ONE device (fr965). The per-device table in the PR body comes from running
// the same suite locally against all twelve manifest devices; the suite adapts
// itself through System.getDeviceSettings, so it is the same code either way.
// Test names are pinned in scripts/expected_tests.txt -- update that file in
// the same commit as any (:test) change. See docs/CI.md.

// Sampling resolution, in degrees, along an arc path. At the largest radius
// this app draws (0.42*454 = 190) one degree is 3.3 px, and the smallest pen
// width in force on any arc is 4, so consecutive patches always overlap.
const HL_ARC_STEP_DEG = 1.0;

// -- A Dc that records full geometry -------------------------------------------
// HrDc (HrArcTest.mc) counts primitives; this one keeps their coordinates,
// which is what a collision check needs. Kept separate rather than widening
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
    // pixels is the same either way, and a collision check only cares about the
    // set.
    function drawArc(x, y, r, attr, degStart, degEnd) {
        var lo = degStart;
        var hi = degEnd;
        if (lo > hi) { var t = lo; lo = hi; hi = t; }
        arcs.add([x, y, r, pen, lo, hi]);
    }

    function drawLine(x0, y0, x1, y1) { lines.add([x0, y0, x1, y1, pen]); }

    function drawText(x, y, font, s, just) { texts.add([x, y, font, s, just]); }
}

// -- Metrics ------------------------------------------------------------------

// A real Dc, purely for font metrics. Two acquisition paths because the twelve
// manifest devices straddle the API level that replaced the constructor:
// createBufferedBitmap is API 4.0.0 and the four fenix6 variants are API 3.4,
// where the deprecated constructor is the only one available. Both are guarded
// by `has` so the file compiles for every device, and both were confirmed to
// return working metrics -- fr965 through the first path, fenix6spro through
// the second.
//
// 8x8 because only the FONT metrics are wanted; they are a property of the
// device, not of the surface, and a screen-sized buffer would be a large
// allocation for nothing.
function hlMetricDc() {
    if (Gfx has :createBufferedBitmap) {
        return Gfx.createBufferedBitmap({ :width => 8, :height => 8 }).get().getDc();
    }
    return new Gfx.BufferedBitmap({ :width => 8, :height => 8 }).getDc();
}

// [left, top, right, bottom] for one recorded drawText, from real metrics.
//
// TEXT_JUSTIFY_RIGHT is 0, CENTER 1, LEFT 2 and VCENTER 4, so the horizontal
// term is the low two bits and VCENTER is a flag above them. Without VCENTER
// the y passed to drawText is the TOP of the box, which is what the shipping
// code relies on for every row placed by a height fraction.
function hlTextBox(mdc, t) {
    var x = t[0]; var y = t[1]; var font = t[2]; var s = t[3]; var just = t[4];
    var tw = mdc.getTextWidthInPixels(s, font);
    var th = mdc.getFontHeight(font);
    var hj = just & 3;
    var left;
    if (hj == Gfx.TEXT_JUSTIFY_CENTER)    { left = x - tw / 2.0; }
    else if (hj == Gfx.TEXT_JUSTIFY_LEFT) { left = x; }
    else                                  { left = x - tw; }
    var top = y;
    if ((just & Gfx.TEXT_JUSTIFY_VCENTER) != 0) { top = y - th / 2.0; }
    return [left, top, left + tw, top + th];
}

// Separation between a pen-wide square patch centred at (px, py) and a text
// box. Positive is clearance in pixels; negative or zero is an overlap.
function hlGap(px, py, halfPen, box) {
    var dx1 = box[0] - (px + halfPen);   // patch is left of the box
    var dx2 = (px - halfPen) - box[2];   // patch is right of the box
    var dy1 = box[1] - (py + halfPen);   // patch is above the box
    var dy2 = (py - halfPen) - box[3];   // patch is below the box
    var best = dx1;
    if (dx2 > best) { best = dx2; }
    if (dy1 > best) { best = dy1; }
    if (dy2 > best) { best = dy2; }
    return best;
}

// The worst (smallest) separation between anything the arc drew and anything
// the view wrote, over one rendered state. Returns a Float; <= 0 is a
// collision.
function hlWorstGap(geo, mdc) {
    if (geo.texts.size() == 0) { return 9999.0; }

    var boxes = new [geo.texts.size()];
    for (var i = 0; i < geo.texts.size(); i++) {
        boxes[i] = hlTextBox(mdc, geo.texts[i]);
    }

    var worst = 9999.0;

    // arcs, sampled along the path
    for (var a = 0; a < geo.arcs.size(); a++) {
        var arc = geo.arcs[a];
        var cx = arc[0]; var cy = arc[1]; var r = arc[2];
        var hp = arc[3] / 2.0;
        var deg = arc[4];
        var end = arc[5];
        while (true) {
            var rad = deg * Math.PI / 180.0;
            var px = cx + r * Math.cos(rad);
            var py = cy - r * Math.sin(rad);
            for (var b = 0; b < boxes.size(); b++) {
                var g = hlGap(px, py, hp, boxes[b]);
                if (g < worst) { worst = g; }
            }
            if (deg >= end) { break; }
            deg += $.HL_ARC_STEP_DEG;
            if (deg > end) { deg = end; }
        }
    }

    // lines, sampled at one pixel along their length
    for (var l = 0; l < geo.lines.size(); l++) {
        var ln = geo.lines[l];
        var x0 = ln[0]; var y0 = ln[1]; var x1 = ln[2]; var y1 = ln[3];
        var hp2 = ln[4] / 2.0;
        var dx = x1 - x0;
        var dy = y1 - y0;
        var len = Math.sqrt(dx * dx + dy * dy);
        var steps = len.toNumber() + 1;
        for (var s = 0; s <= steps; s++) {
            var f = (steps == 0) ? 0.0 : (s * 1.0) / steps;
            var px2 = x0 + dx * f;
            var py2 = y0 + dy * f;
            for (var b2 = 0; b2 < boxes.size(); b2++) {
                var g2 = hlGap(px2, py2, hp2, boxes[b2]);
                if (g2 < worst) { worst = g2; }
            }
        }
    }

    return worst;
}

// Render one configuration and return its worst gap.
//
// `kind` is a step-type constant read off the probe, or -1 for the pre-START
// screen, or -2 for free-row mode.
//
// `wide` drives every data-dependent string to its practical maximum: the
// largest workout settings.xml declares, a long session with a large distance
// and stroke count, a GPS speed spike (which shortens the pace term but adds
// the metres-per-stroke one), and a live step clock so the countdown shows its
// full duration. Measuring only the narrow instance of each string would
// measure the narrowest screen this app can draw rather than the widest, which
// is the mistake this whole suite exists to stop making.
function hlRender(kind, paused, bandLo, bandHi, hrBpm, hrLive, sensorOk, wide, mdc) {
    var ds = System.getDeviceSettings();
    var p = new HrProbe();
    p.driveStrokes();
    if (wide) { p.setWorkoutShape(30, 3600); }
    p.setBand(bandLo, bandHi);
    p.setSensorOk(sensorOk);
    if (hrLive) { p.setHrState(hrBpm, System.getTimer(), true); }
    else        { p.setHrState(hrBpm, 0, false); }

    if (kind == -2)      { p.setFreeRow(); }
    else if (kind == -1) { p.enterPreStart(); }
    else if (wide)       { p.enterStepLive(kind, paused); }
    else                 { p.enterStep(kind, paused); }

    if (wide) {
        p.setWideSession();
        p.setSpeed(6.0);
    } else {
        p.setSpeed(0.0);
    }

    var geo = new HrGeoDc(ds.screenWidth, ds.screenHeight);
    p.runUpdate(geo);
    return hlWorstGap(geo, mdc);
}

// -- The acceptance case -------------------------------------------------------
// Every step type the view can render, at the extremes of the band range
// settings.xml declares, with the heart rate absent, live, and clamped at both
// ends, and with the pace row driven to its widest.
//
// One case rather than a dozen, deliberately: the interesting output is the
// WORST margin over the whole space and which configuration produced it, and a
// dozen cases would report a dozen minima and hide the shape of the space.
(:test) function test_hr_arcNeverOverlapsAnyText(logger) {
    var mdc = hlMetricDc();
    var ds = System.getDeviceSettings();
    var k = new HrProbe();

    // step kinds, plus the two screens that are not steps
    var kinds = [ k.kindWork(), k.kindRest(), k.kindGate(),
                  k.kindWarm(), k.kindCool(), k.kindDone(), -1, -2 ];
    var kindNames = [ "WORK", "REST", "GATE", "WARM", "COOL", "DONE",
                      "pre-START", "free-row" ];

    // Band extremes of the settable range, plus the shipped default.
    var bands = [ [116, 130], [$.HR_DISP_LO, $.HR_DISP_LO],
                  [$.HR_DISP_HI, $.HR_DISP_HI], [$.HR_DISP_LO, $.HR_DISP_HI] ];

    // Heart-rate states: absent, in band, clamped low, clamped high.
    var hrs = [ [0, false], [123, true], [$.HR_DISP_LO - 20, true],
                [$.HR_DISP_HI + 20, true] ];

    var worst = 9999.0;
    var worstWhere = "none";

    // Main pass: every screen, every band extreme, every heart-rate state, in
    // both the narrowest and the widest string shape.
    for (var ki = 0; ki < kinds.size(); ki++) {
        for (var bi = 0; bi < bands.size(); bi++) {
            for (var hi = 0; hi < hrs.size(); hi++) {
                for (var wi = 0; wi < 2; wi++) {
                    var g = hlRender(kinds[ki], false,
                                     bands[bi][0], bands[bi][1],
                                     hrs[hi][0], hrs[hi][1],
                                     true, wi == 1, mdc);
                    if (g < worst) {
                        worst = g;
                        worstWhere = kindNames[ki] +
                            " band " + bands[bi][0] + "-" + bands[bi][1] +
                            " hr " + hrs[hi][0] +
                            (hrs[hi][1] ? "" : "(absent)") +
                            (wi == 1 ? " wide-strings" : " narrow-strings");
                    }
                }
            }
        }
    }

    // Second pass, over the two step types that actually draw the arc: PAUSED
    // and NO ACCEL. Both replace the footer with a SHORTER string, so neither
    // can be the widest screen -- but "narrower is safe" is an assumption, and
    // this suite exists because an assumption about string width was wrong.
    var arcKinds = [ k.kindWork(), k.kindRest() ];
    var arcNames = [ "WORK", "REST" ];
    for (var ai = 0; ai < arcKinds.size(); ai++) {
        for (var bi2 = 0; bi2 < bands.size(); bi2++) {
            for (var vi = 0; vi < 4; vi++) {
                var paused  = (vi & 1) != 0;
                var accelOk = (vi & 2) == 0;
                var g2 = hlRender(arcKinds[ai], paused,
                                  bands[bi2][0], bands[bi2][1],
                                  123, true, accelOk, true, mdc);
                if (g2 < worst) {
                    worst = g2;
                    worstWhere = arcNames[ai] +
                        (paused ? "/PAUSED" : "") +
                        (accelOk ? "" : "/NO-ACCEL") +
                        " band " + bands[bi2][0] + "-" + bands[bi2][1] +
                        " wide-strings";
                }
            }
        }
    }

    logger.debug("HL " + ds.screenWidth + "x" + ds.screenHeight +
                 " worst gap " + worst.format("%.2f") + " px at " + worstWhere);

    if (worst <= 0.0) {
        logger.error("#110: the heart-rate arc OVERLAPS rendered text. Worst " +
                     "separation " + worst.format("%.2f") + " px (<= 0 is an " +
                     "overlap) on a " + ds.screenWidth + "x" + ds.screenHeight +
                     " display, at: " + worstWhere +
                     ". Measured from real font metrics, with every primitive " +
                     "sampled at its PEN WIDTH -- the outermost drawn pixel, " +
                     "not the centreline.");
        return false;
    }
    return true;
}
