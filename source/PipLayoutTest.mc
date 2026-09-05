using Toybox.Test;
using Toybox.Graphics as Gfx;
using Toybox.System;
using Toybox.Math;
using Toybox.Lang;


// ---------------------------------------------------------------------------
// EVERYTHING #80 ADDS TO THIS FILE LIVES IN `module Hsi`, and that is a
// hard constraint rather than a taste. MEASURED, SDK 9.2.0: a --unit-test
// build for the fenix6 family fails at 254 members of module 'globals', and
// this repository was already at 246 before #80. A file-scope (:test) costs
// one of the seven that were left; the whole of #80's suite inside a module
// costs one between them. The simulator names these cases `Hsi.test_...`, and
// scripts/list_tests.py emits that qualified name so the pin matches what the
// runner prints. See the note in scripts/list_tests.py.
// ---------------------------------------------------------------------------
module Hsi {
// Layout suite for #80's status-row heat-strain indicator.
//
// WHAT THIS FILE CAN AND CANNOT SEE, first, because every case below is shaped
// by it. No (:test) in this repository may obtain a real graphics Dc (#121:
// the CI container segfaults the moment one does), so nothing here can measure
// a glyph. What it CAN do is evaluate the shipping geometry functions against
// the device sizes and the font metrics MEASURED SEPARATELY, and hold them to
// the clearances that measurement established.
//
// THE MEASUREMENT. dc.getTextDimensions and dc.getFontHeight, called from a
// throwaway app under SDK 9.2.0, once per device, on all NINETEEN devices in
// manifest.xml. Every device reports SCREEN_SHAPE_ROUND with w == h. The method
// reproduces a figure already recorded in StrongRowView.mc from earlier work
// ("-:--/500m  12.5m/str" at 277 px on the 454 px devices) to the pixel, which
// is the cross-check that it measures the same thing that work did. The results
// are the table below and are restated in the pull request.
//
// THE SEVEN fenix 9 ROWS WERE RE-MEASURED THE SAME WAY, and the same run
// re-measured the twelve that were already here: all twelve reproduced their
// committed values exactly, which is what makes the seven new rows comparable
// to them rather than to a differently-instrumented probe.
//
// AND THE PARAGRAPH BELOW ABOUT SIZE-MATES IS NO LONGER HYPOTHETICAL. The two
// fenix 9 Pro Solar devices share their WIDTH with devices already in this
// table and DO NOT share their font metrics: fenix9prosolar47mm is 260 px like
// fenix7/fenix6 but measures 21/31/20/20 where those measure 19/27/18/18, and
// fenix9prosolar51mm is 280 px like fenix6xpro and measures 22/32/22/21 where
// fenix6xpro measures 19/27/18/18. A row keyed on screen size alone would have
// carried the wrong numbers for both.
//
// WHAT NONE OF IT CLAIMS. These are TEXT-BOX extents, not ink extents: nothing
// in this repository can measure where a glyph's ink starts inside its box, so
// a box corner sitting on the display edge does not mean a pixel was lost. That
// cuts both ways and is why the shipped row is treated as being AT its limit
// rather than comfortably inside it. And nothing here says anything about
// legibility, or about how any of this looks on a wrist.

// -- The measured table -------------------------------------------------------
// [ name, w, h, FONT_XTINY height, width("GPS"), width("RR"), width("CT") ]
// All values in pixels, SDK 9.2.0. Duplicated rows are kept rather than
// collapsed by screen size: the device list is the contract, and a future
// device whose metrics differ from its size-mates must appear as its own row.
function pipDevices() {
    return [
        [ "fr970",         454, 454, 37, 59, 38, 39 ],
        [ "fr965",         454, 454, 37, 59, 38, 39 ],
        [ "fenix847mm",    454, 454, 37, 59, 38, 39 ],
        [ "fenix843mm",    416, 416, 34, 55, 36, 36 ],
        [ "fenix8pro47mm", 454, 454, 37, 59, 38, 39 ],
        [ "fenix7",        260, 260, 19, 27, 18, 18 ],
        [ "fenix7pro",     260, 260, 19, 27, 18, 18 ],
        [ "epix2pro47mm",  416, 416, 31, 43, 28, 28 ],
        [ "fenix6",        260, 260, 19, 27, 18, 18 ],
        [ "fenix6pro",     260, 260, 19, 27, 18, 18 ],
        [ "fenix6spro",    240, 240, 19, 27, 18, 18 ],
        [ "fenix6xpro",    280, 280, 19, 27, 18, 18 ],
        // fenix 9 family. Same probe, same SDK, same run as the re-measurement
        // of the twelve above.
        [ "fenix943mm",         416, 416, 34, 55, 36, 36 ],
        [ "fenix947mm",         454, 454, 37, 59, 38, 39 ],
        [ "fenix9pro43mm",      416, 416, 34, 55, 36, 36 ],
        [ "fenix9pro47mm",      454, 454, 37, 59, 38, 39 ],
        [ "fenix9pro51mm",      466, 466, 37, 59, 38, 39 ],
        [ "fenix9prosolar47mm", 260, 260, 21, 31, 20, 20 ],
        [ "fenix9prosolar51mm", 280, 280, 22, 32, 22, 21 ]
    ];
}

// Clearance floors. Both are BELOW every measured value with room to spare, so
// they are regression guards rather than restatements of the measurement: a
// change that made the mark fatter, the gap constant smaller or the row's y
// higher walks the margin down toward them.
const PIP_MIN_BEZEL_PX = 2.0;   // worst measured: mark 6.32, label 4.06
const PIP_MIN_GAP_PX   = 5.0;   // worst measured RR-to-CT gap: 7.15

// Distance from the display centre to the furthest corner of an axis-aligned
// box. The display is the circle inscribed in w x h, so a box is fully visible
// exactly when this is at most the radius.
function pipWorstCorner(w, h, x0, x1, y0, y1) {
    var cx = w / 2.0;
    var cy = h / 2.0;
    var worst = 0.0;
    for (var i = 0; i < 2; i++) {
        var x = (i == 0) ? x0 : x1;
        for (var j = 0; j < 2; j++) {
            var y = (j == 0) ? y0 : y1;
            var d = Math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
            if (d > worst) { worst = d; }
        }
    }
    return worst;
}

function pipRadius(w, h) { return ((w < h) ? w : h) / 2.0; }

// -- c1: the geometry --------------------------------------------------------

// The mark must be inside the display on every device.
//
// Asserted on its BOUNDING BOX rather than on its centre, and at the mark's own
// y rather than at the row's top: the centre being inside says nothing about a
// mark of any radius, and the row's top is where the chord is narrowest.
(:test) function test_pip_markStaysInsideTheDisplay(logger) {
    var devs = pipDevices();
    var ok = true;
    for (var i = 0; i < devs.size(); i++) {
        var name = devs[i][0];
        var w = devs[i][1];
        var h = devs[i][2];
        var fh = devs[i][3];
        var r  = StrongRowView.pipDotR(w);
        var cx = StrongRowView.pipDotCx(w, h);
        var cy = StrongRowView.pipDotCy(h, fh);
        var m  = pipRadius(w, h) - pipWorstCorner(w, h, cx - r, cx + r, cy - r, cy + r);
        if (m < PIP_MIN_BEZEL_PX) {
            logger.error(name + ": the heat-strain mark clears the display edge " +
                         "by only " + m + " px (floor " + PIP_MIN_BEZEL_PX +
                         "). The status row sits at its chord limit already, so " +
                         "anything that fattens the mark or raises the row has " +
                         "to be re-measured, not tuned.");
            ok = false;
        }
    }
    return ok;
}

// The CT label must still be inside the display once the mark has taken the
// row's right end. Uses the MEASURED label width, not the bound the code lays
// out against, so this case sees the real box.
(:test) function test_pip_labelStaysInsideTheDisplay(logger) {
    var devs = pipDevices();
    var ok = true;
    for (var i = 0; i < devs.size(); i++) {
        var name = devs[i][0];
        var w = devs[i][1];
        var h = devs[i][2];
        var fh  = devs[i][3];
        var wct = devs[i][6];
        var cx  = StrongRowView.pipCtCx(w, h);
        var y0  = $.PIP_ROW_Y_FRAC * h;
        var m   = pipRadius(w, h) -
                  pipWorstCorner(w, h, cx - wct / 2.0, cx + wct / 2.0, y0, y0 + fh);
        if (m < PIP_MIN_BEZEL_PX) {
            logger.error(name + ": the CT label clears the display edge by only " +
                         m + " px (floor " + PIP_MIN_BEZEL_PX + ")");
            ok = false;
        }
    }
    return ok;
}

// The label must not collide with the RR pip it was moved toward.
//
// This is the cost the #80 layout pays and the one a later edit is most likely
// to spend without noticing: every pixel the mark takes at the right end comes
// out of this gap. Measured worst case is 7.15 px on fenix6spro, against 15.6
// px before the change.
(:test) function test_pip_labelClearsTheRrPip(logger) {
    var devs = pipDevices();
    var ok = true;
    for (var i = 0; i < devs.size(); i++) {
        var name = devs[i][0];
        var w = devs[i][1];
        var h = devs[i][2];
        var wrr = devs[i][5];
        var wct = devs[i][6];
        // RR is unchanged by #80 and still centred at 0.52w.
        var rrRight = 0.52 * w + wrr / 2.0;
        var ctLeft  = StrongRowView.pipCtCx(w, h) - wct / 2.0;
        var gap = ctLeft - rrRight;
        if (gap < PIP_MIN_GAP_PX) {
            logger.error(name + ": only " + gap + " px between the RR pip and " +
                         "the CT label (floor " + PIP_MIN_GAP_PX + "). The " +
                         "status row is full; a wider mark cannot be paid for " +
                         "out of this gap.");
            ok = false;
        }
    }
    return ok;
}

// PIP_CT_W_FRAC is used as an upper BOUND on the label's width. If it ever
// under-states a real device the layout stops being conservative and the label
// creeps right, toward the mark -- silently, because nothing else would move.
(:test) function test_pip_widthBoundCoversEveryMeasuredLabel(logger) {
    var devs = pipDevices();
    var ok = true;
    for (var i = 0; i < devs.size(); i++) {
        var name = devs[i][0];
        var w = devs[i][1];
        var wct = devs[i][6];
        var bound = w * $.PIP_CT_W_FRAC;
        if (bound < wct) {
            logger.error(name + ": PIP_CT_W_FRAC gives " + bound +
                         " px but the measured 'CT' label is " + wct + " px");
            ok = false;
        }
    }
    return ok;
}

// pipDotCx's bound is taken at the row's TOP, where the chord is narrowest, and
// is only conservative for the mark because the mark sits lower. That holds
// exactly while the mark's radius is under half the font height -- pinned here
// rather than left as a sentence in a comment.
(:test) function test_pip_markIsShorterThanTheRow(logger) {
    var devs = pipDevices();
    var ok = true;
    for (var i = 0; i < devs.size(); i++) {
        var name = devs[i][0];
        var w = devs[i][1];
        var fh = devs[i][3];
        if (StrongRowView.pipDotR(w) >= fh / 2.0) {
            logger.error(name + ": mark radius " + StrongRowView.pipDotR(w) +
                         " is not under half the " + fh + " px row height, so " +
                         "the chord bound taken at the row top is no longer " +
                         "conservative for it");
            ok = false;
        }
    }
    return ok;
}

// The chord function itself, against the circle it claims to describe.
// Independent of any device row: at the vertical centre it must give the full
// half-width, and at every sampled height the returned point must lie ON the
// circle to within rounding.
(:test) function test_pip_chordFollowsTheCircle(logger) {
    var w = 454;
    var h = 454;
    var ok = true;
    var mid = StrongRowView.pipChordXMax(w, h, h / 2.0);
    if (mid < w - 0.001 || mid > w + 0.001) {
        logger.error("at the centreline the chord must reach the full width, got " + mid);
        ok = false;
    }
    var ys = [ 0.045 * h, 0.13 * h, 0.30 * h, 0.70 * h, 0.87 * h ];
    for (var i = 0; i < ys.size(); i++) {
        var x = StrongRowView.pipChordXMax(w, h, ys[i]);
        var dx = x - w / 2.0;
        var dy = ys[i] - h / 2.0;
        var d = Math.sqrt(dx * dx + dy * dy);
        if (d < w / 2.0 - 0.01 || d > w / 2.0 + 0.01) {
            logger.error("chord at y = " + ys[i] + " lands " + d +
                         " from the centre, expected the radius " + (w / 2.0));
            ok = false;
        }
    }
    // Above the display entirely: degenerate rather than a square root of a
    // negative number.
    if (StrongRowView.pipChordXMax(w, h, -100) != w / 2.0) {
        logger.error("a y outside the circle must degenerate to the centreline, got " +
                     StrongRowView.pipChordXMax(w, h, -100));
        ok = false;
    }
    return ok;
}

// -- c1: the FIT write predicate ---------------------------------------------

// The guard that must never become `v > 0.0`.
//
// 0.0 a.u. is "no thermal strain", an ordinary reading. Suppressing it would
// delete every genuine low-strain sample and leave the recorded series covering
// only the hard parts of the row, with nothing in the file to say so -- the
// same defect class as a zero that reads as data, arrived at from the other
// side.
(:test) function test_pip_zeroStrainIsWritable(logger) {
    var ok = true;
    if (StrongRowView.hsiWritable(0.0) != true) {
        logger.error("0.0 is a legal Heat Strain Index and must be written");
        ok = false;
    }
    if (StrongRowView.hsiWritable(3.9) != true) {
        logger.error("an ordinary reading must be written");
        ok = false;
    }
    if (StrongRowView.hsiWritable(null) != false) {
        logger.error("absence must not be written -- there is no in-band value " +
                     "on this scale that could stand for it");
        ok = false;
    }
    return ok;
}

}

module Hsi {

// -- c2 red differentials -----------------------------------------------------
// Both cases below FAIL on the commit that precedes them -- the geometry exists
// but drawGps draws no mark -- and pass once the indicator lands.

// A stand-in CORE sensor, so a render case can put the view in "heat index
// present" and "heat index absent" with no ANT channel.
//
// heatIndex() returns NULL for absent, matching the shipping sensor. A
// stand-in returning 0.0 would let these cases pass against a view that
// rendered absence as a reading, which is the one thing the indicator exists to
// avoid.
class PipCore {
    var hsiOn; var hsiVal; var tempOn;
    function initialize(on, v, t) { hsiOn = on; hsiVal = v; tempOn = t; }
    function isFresh()   { return tempOn; }
    function everSeen()  { return true; }
    function coreTemp()  { return 0.0; }
    function skinTemp()  { return 0.0; }
    function hsiFresh()  { return hsiOn; }
    function heatIndex() { return hsiVal; }
}

function pipRender(kind, core) {
    var p = new HrProbe();
    p.driveStrokes();
    p.setSensorOk(true);
    p.setHrState(128, System.getTimer(), true);
    p.enterStep(kind, false);
    p.setNarrowSession();
    p.setSpeed(4.0);
    p.setCoreSensor(core);
    var ds = System.getDeviceSettings();
    var d = new HrDc(ds.screenWidth, ds.screenHeight);
    p.runUpdate(d);
    return d;
}

// The indicator is drawn on the status row, once, at the geometry the pure
// functions computed -- and NOT on the work screen, which #108 stripped to
// three text elements and two arcs.
//
// Both halves are one case on purpose. Separated, the negative half is green in
// every epoch and would pass while the indicator did not exist at all; joined,
// it is what stops the mark being added somewhere outside drawGps, where the
// status row's own suppression could not reach it.
(:test) function test_pip_markRidesTheStatusRowOnly(logger) {
    var k = new HrProbe();
    var rest = pipRender(k.kindWarm(), new PipCore(true, 3.9, true));
    var work = pipRender(k.kindWork(), new PipCore(true, 3.9, true));
    var ok = true;
    if (rest.circleCount() != 1) {
        logger.error("the status row must draw exactly one heat-strain mark, " +
                     "counted " + rest.circleCount());
        return false;
    }
    if (work.circleCount() != 0) {
        logger.error("the work screen drops the status row, so it must draw no " +
                     "heat-strain mark; counted " + work.circleCount() +
                     ". A mark added outside drawGps would appear here.");
        ok = false;
    }
    var w = rest.getWidth();
    var h = rest.getHeight();
    var c = rest.circleAt(0);
    var wantX = StrongRowView.pipDotCx(w, h);
    var wantR = StrongRowView.pipDotR(w);
    if (c[0] < wantX - 0.01 || c[0] > wantX + 0.01) {
        logger.error("mark drawn at x = " + c[0] + ", expected " + wantX +
                     " -- the draw call must use the pinned geometry, not a " +
                     "second copy of it");
        ok = false;
    }
    if (c[2] != wantR) {
        logger.error("mark radius " + c[2] + ", expected " + wantR);
        ok = false;
    }
    return ok;
}

// Present and absent must differ in SHAPE as well as colour.
//
// The mark is small -- 3 px radius on the two smallest displays -- so the
// filled/outline distinction there is a handful of pixels and colour carries
// most of the load. That is stated rather than dressed up. The outline is drawn
// in BOTH states deliberately: a marker that vanishes with its data cannot be
// read against, which is the same rule the distance-per-stroke arc's benchmark
// tick states.
(:test) function test_pip_absentStrainIsHollowAndPresentIsFilled(logger) {
    var k = new HrProbe();
    var on  = pipRender(k.kindWarm(), new PipCore(true, 3.9, true));
    var off = pipRender(k.kindWarm(), new PipCore(false, null, true));
    var ok = true;
    if (off.circleCount() != 1) {
        logger.error("the mark must be drawn even with no reading; counted " +
                     off.circleCount());
        return false;
    }
    if (off.filledCircleCount() != 0) {
        logger.error("no reading must render as an OUTLINE, but " +
                     off.filledCircleCount() + " of " + off.circleCount() +
                     " circles were filled");
        ok = false;
    }
    if (on.filledCircleCount() < 1) {
        logger.error("a current reading must render as a FILLED mark; none of " +
                     on.circleCount() + " circles was filled");
        ok = false;
    }
    // A zero reading is a reading. This is the same trap as the FIT write, and
    // it reaches the screen by a different path, so it is pinned on both.
    var zero = pipRender(k.kindWarm(), new PipCore(true, 0.0, true));
    if (zero.filledCircleCount() < 1) {
        logger.error("a heat index of 0.0 is a current reading and must render " +
                     "as present, not as no-data");
        ok = false;
    }
    return ok;
}

}
