using Toybox.Test;
using Toybox.Graphics as Gfx;

// Unit tests for issue #123: the right-edge distance-per-stroke arc.
//
// The arc answers one question — am I clearing my benchmark? — as a colour
// category readable in the fraction of a second between strokes, with position
// carried geometrically so colour is reinforcement rather than the sole channel.
//
// SCOPE, stated rather than implied: these pin the PREDICATES. That drawDpsArc
// calls them, that dpsForArc picks the latched interval average during REST,
// and that the arc is drawn on the right two step types are covered by review
// and by the envelope guards in HrLayoutTest.mc. Same caveat RateColourTest.mc,
// FootStateTest.mc and SetSummaryTest.mc each state about their own call sites.

// -- The blue collision, first, because it is the constraint that shaped the
// -- whole palette -------------------------------------------------------------

// COLOR_BLUE means "below target" on the heart-rate arc and on the stroke-rate
// numeral, both shipped. The spectral ramp originally proposed for this arc
// reached blue at about 120% of benchmark — i.e. GOOD — and at a glance the eye
// reads the colour before it locates which edge the arc is on, so position
// cannot disambiguate. No state here may return blue.
(:test) function test_dps_noStateIsEverBlue(logger) {
    var zones = [ $.DPSZ_NONE, $.DPSZ_FAR, $.DPSZ_UNDER, $.DPSZ_AT, $.DPSZ_OVER ];
    for (var i = 0; i < zones.size(); i++) {
        var c = StrongRowView.dpsZoneColour(zones[i]);
        if (c == Gfx.COLOR_BLUE || c == Gfx.COLOR_DK_BLUE) {
            logger.error("zone " + zones[i] + " returned a BLUE. Blue means " +
                         "'below target' on two shipped elements; on this arc " +
                         "the cool end would mean GOOD, and the two are on " +
                         "screen together");
            return false;
        }
    }
    return true;
}

// The four live states must be four distinct colours, and none may collide with
// the no-data colour. A duplicate would make two states render identically
// while every boundary case below still passed.
(:test) function test_dps_theFourStatesAreDistinct(logger) {
    var z = [ $.DPSZ_FAR, $.DPSZ_UNDER, $.DPSZ_AT, $.DPSZ_OVER, $.DPSZ_NONE ];
    for (var i = 0; i < z.size(); i++) {
        for (var j = i + 1; j < z.size(); j++) {
            if (StrongRowView.dpsZoneColour(z[i]) == StrongRowView.dpsZoneColour(z[j])) {
                logger.error("zones " + z[i] + " and " + z[j] +
                             " share a colour");
                return false;
            }
        }
    }
    return true;
}

// -- Null, never zero ---------------------------------------------------------

// THE TRAP THIS EXISTS FOR. distPerStroke() answers 0.0 for its no-data case —
// harmless where drawPace gates on `> 0.0`, and NOT harmless here: 0.0 maps to
// the bottom of the range and renders RED, "far below benchmark". Absence
// rendered as a value is the #86/#107 class.
(:test) function test_dps_zeroMetresIsNullNotFarBelow(logger) {
    var pct = StrongRowView.dpsPct(0.0, 6.0);
    if (pct != null) {
        logger.error("0.0 m/stroke must be null, not " + pct +
                     " -- distPerStroke's no-data return would otherwise " +
                     "render RED as though the athlete were far below benchmark");
        return false;
    }
    if (StrongRowView.dpsZone(null) != $.DPSZ_NONE) {
        logger.error("a null percentage must be DPSZ_NONE");
        return false;
    }
    return true;
}

(:test) function test_dps_nullAndBadBenchmarkAreNull(logger) {
    if (StrongRowView.dpsPct(null, 6.0)  != null) { logger.error("null m"); return false; }
    if (StrongRowView.dpsPct(6.0, null)  != null) { logger.error("null bench"); return false; }
    if (StrongRowView.dpsPct(6.0, 0.0)   != null) { logger.error("zero bench"); return false; }
    if (StrongRowView.dpsPct(-1.0, 6.0)  != null) { logger.error("negative m"); return false; }
    return true;
}

// -- The boundaries -----------------------------------------------------------

// EXACTLY 100% IS "AT", NOT "UNDER". The benchmark is a floor being cleared,
// not a line being crossed, so meeting it is success. This is the boundary the
// whole arc exists to show and the one the palette's luminance separation was
// tuned for.
(:test) function test_dps_exactlyAtBenchmarkIsAt(logger) {
    if (StrongRowView.dpsZone(100.0) != $.DPSZ_AT) {
        logger.error("100% of benchmark must be DPSZ_AT, not " +
                     StrongRowView.dpsZone(100.0));
        return false;
    }
    if (StrongRowView.dpsZone(99.9) != $.DPSZ_UNDER) {
        logger.error("99.9% must still be UNDER");
        return false;
    }
    return true;
}

// Above the benchmark must never render as a warning. Green spans everything
// from 100 to 125 so the arc STOPS CHANGING once cleared, and purple above that
// is a reward tier — neither is red or amber.
(:test) function test_dps_aboveBenchmarkIsNeverAWarning(logger) {
    var pcts = [100.0, 110.0, 125.0, 130.0, 200.0, 1000.0];
    for (var i = 0; i < pcts.size(); i++) {
        var c = StrongRowView.dpsZoneColour(StrongRowView.dpsZone(pcts[i]));
        if (c == Gfx.COLOR_RED || c == Gfx.COLOR_ORANGE) {
            logger.error(pcts[i] + "% of benchmark rendered as a warning " +
                         "colour. Exceeding the benchmark is not a fault");
            return false;
        }
    }
    return true;
}

(:test) function test_dps_theOtherTwoBoundaries(logger) {
    if (StrongRowView.dpsZone(84.9) != $.DPSZ_FAR)   { logger.error("84.9 far");   return false; }
    if (StrongRowView.dpsZone(85.0) != $.DPSZ_UNDER) { logger.error("85.0 under"); return false; }
    if (StrongRowView.dpsZone(125.0) != $.DPSZ_AT)   { logger.error("125 at");     return false; }
    if (StrongRowView.dpsZone(125.1) != $.DPSZ_OVER) { logger.error("125.1 over"); return false; }
    return true;
}

// -- Geometry -----------------------------------------------------------------

// The angle must stay inside the sweep for ANY input, including inputs no
// benchmark can produce. drawArc renders a COMPLETE CIRCLE when its two angles
// are equal, so an out-of-range angle is not a mark in the wrong place — it is
// a ring across the whole display.
(:test) function test_dps_angleStaysInsideTheSweep(logger) {
    var probes = [0.0, 1.0, 59.0, 60.0, 61.0, 100.0, 139.0, 140.0, 141.0,
                  500.0, 10000.0];
    var lo = $.DPS_ARC_BOT - 360;
    for (var i = 0; i < probes.size(); i++) {
        var a = StrongRowView.dpsAngle(probes[i]);
        if (a < lo || a > $.DPS_ARC_TOP) {
            logger.error(probes[i] + "% mapped to " + a +
                         ", outside [" + lo + "," + $.DPS_ARC_TOP + "]");
            return false;
        }
    }
    return true;
}

// More metres per stroke must never move the mark DOWN the arc.
(:test) function test_dps_angleIsMonotonic(logger) {
    var prev = -9999;
    for (var pct = 50; pct <= 150; pct += 5) {
        var a = StrongRowView.dpsAngle(pct);
        if (a < prev) {
            logger.error("angle went backwards at " + pct + "%: " + a +
                         " after " + prev);
            return false;
        }
        prev = a;
    }
    return true;
}

// The sweep must mirror the heart-rate arc's exactly. Two arcs of visibly
// different size on the two edges would read as a defect, and this is what
// stops one being widened without the other.
(:test) function test_dps_sweepMirrorsTheHeartRateArc(logger) {
    var hrSpan  = $.HR_ARC_BOT - $.HR_ARC_TOP;
    var dpsSpan = $.DPS_ARC_TOP - ($.DPS_ARC_BOT - 360);
    if (hrSpan != dpsSpan) {
        logger.error("the two arcs must span the same angle: heart rate " +
                     hrSpan + ", distance per stroke " + dpsSpan);
        return false;
    }
    // And be mirror images about the vertical axis: a -> 180 - a.
    if ($.DPS_ARC_TOP != 180 - $.HR_ARC_TOP) {
        logger.error("DPS_ARC_TOP must be 180 - HR_ARC_TOP");
        return false;
    }
    if ($.DPS_ARC_BOT - 360 != 180 - $.HR_ARC_BOT) {
        logger.error("DPS_ARC_BOT must mirror HR_ARC_BOT");
        return false;
    }
    return true;
}

// The wrap helper must produce angles drawArc accepts, for every angle the
// sweep can yield.
(:test) function test_dps_wrapProducesDrawableAngles(logger) {
    for (var pct = 0; pct <= 200; pct += 5) {
        var wdeg = StrongRowView.dpsWrap(StrongRowView.dpsAngle(pct));
        if (wdeg < 0 || wdeg >= 360) {
            logger.error(pct + "% wrapped to " + wdeg + ", outside [0,360)");
            return false;
        }
    }
    return true;
}

// The fill is suppressed below a drawable length — same full-circle hazard —
// and the suppressed band must be at the BOTTOM of the range, where the head
// tick still marks the position.
(:test) function test_dps_subDegreeFillIsSuppressedAtTheBottomOnly(logger) {
    if (StrongRowView.dpsFillVisible(60.0)) {
        logger.error("a fill of zero length must be suppressed: drawArc " +
                     "renders a COMPLETE CIRCLE when its two angles are equal");
        return false;
    }
    if (!StrongRowView.dpsFillVisible(100.0)) {
        logger.error("the benchmark itself must have a visible fill");
        return false;
    }
    if (!StrongRowView.dpsFillVisible(140.0)) {
        logger.error("the top of the range must have a visible fill");
        return false;
    }
    return true;
}

// -- The broken track spans its own sweep -------------------------------------
// The mirror of test_hr_brokenTrackSpansTheWholeSweep, and it exists because
// the mirrored draw path originally got none of the mirrored harness. Two
// defects lived in that gap: the third segment passed a NEGATIVE degreeStart to
// drawArc (bypassing dpsWrap, the one helper written to prevent it), and the
// last segment fell a degree short of the sweep's end to Float truncation.
(:test) function test_dps_brokenTrackSegmentsAreDrawable(logger) {
    var parts = StrongRowView.hrTrackParts(false);
    var lo    = ($.DPS_ARC_BOT - 360) * 1.0;
    var span  = ($.DPS_ARC_TOP - lo) * 1.0;
    var seg   = span / (2 * parts - 1);
    var lastEnd = -9999;
    for (var i = 0; i < parts; i++) {
        var b0 = lo + i * 2.0 * seg;
        if (b0 >= $.DPS_ARC_TOP) { break; }
        var b1 = b0 + seg;
        if (b1 > $.DPS_ARC_TOP - 0.001) { b1 = $.DPS_ARC_TOP * 1.0; }
        var s0 = StrongRowView.dpsWrap(b0.toNumber());
        var s1 = StrongRowView.dpsWrap(b1.toNumber());
        // EVERY angle handed to drawArc must be in [0,360). A negative
        // degreeStart is not a mark in the wrong place -- it is outside the
        // documented contract, and what the real Dc does with it is unmeasured.
        if (s0 < 0 || s0 >= 360 || s1 < 0 || s1 >= 360) {
            logger.error("segment " + i + " would call drawArc with an angle " +
                         "outside [0,360): start " + s1 + ", end " + s0);
            return false;
        }
        if (s0 == s1) {
            logger.error("segment " + i + " has equal angles -- drawArc renders " +
                         "a COMPLETE CIRCLE, not a short arc");
            return false;
        }
        lastEnd = b1;
    }
    // The last segment must reach the top of the sweep, the way the heart-rate
    // mirror reaches HR_ARC_BOT.
    if (lastEnd < $.DPS_ARC_TOP - 0.01) {
        logger.error("the broken track stops at " + lastEnd + ", short of " +
                     "DPS_ARC_TOP (" + $.DPS_ARC_TOP + ")");
        return false;
    }
    return true;
}
