using Toybox.Test;
using Toybox.Graphics as Gfx;
using Toybox.Lang;

// Unit tests for issue #110: the left-edge heart-rate arc -- glance priority 3,
// "is my heart rate in target?", answered in peripheral vision while the eye is
// on the stroke rate.
//
// This file opens with CHARACTERIZATION PINS ONLY (commit c0). Every case here
// is green on main at e8676ae, before a single line of #110's source lands, and
// stays green after it. They exist so that the two things #110 must NOT disturb
// are guarded by a test rather than by a promise:
//
//   priority 1 -- the stroke rate      (outputRate, StrongRowView.mc:1109-1123)
//   priority 2 -- the interval countdown (mmss,      StrongRowView.mc:1632-1637)
//
// The acceptance criterion those pins implement is stated on #110 and is
// deliberately phrased as an invariant rather than as a rendering claim: a
// missing heart rate must leave the stroke rate and the countdown IDENTICAL.
// Nothing in this repository can render a screen, so what is testable is that
// the VALUES feeding those two elements do not acquire a dependency on HR
// state. A future edit that coupled them moves a case here.
//
// SCOPE, stated rather than implied: these pin the value paths, not the draw
// calls. drawRate (:1684-1691) and the countdown branch in onUpdate
// (:1758-1774) need a Dc and a fully-built view, so they are covered by review
// only -- the same caveat rateColour states at StrongRowView.mc:911-914.
//
// Execution note: the run-tests CI job runs these headlessly in the simulator
// on every PR (`monkeydo <prg> fr965 -t`, judged by a fail-closed parser), with
// the test names pinned in scripts/expected_tests.txt -- update that file in
// the same commit as any (:test) change here. See docs/CI.md.

// -- Probe ---------------------------------------------------------------------
// `hidden` in Monkey C is protected, so a subclass reaches the shipping class's
// internals without adding anything to it -- the same seam LifeProbe
// (ViewLifecycleTest.mc:148), DspProbe (DspTimeBaseTest.mc) and CoreProbe
// (CoreTempSensorTest.mc) use. Referenced only from (:test) functions, so it
// drops out of the shipping build.
//
// startSensor()/startGps() are neutralised for the same reason LifeProbe
// neutralises them (ViewLifecycleTest.mc:105-110): nothing here calls onLayout,
// but a probe that COULD register a real 25 Hz listener if a later test reached
// that path is a trap left lying around. Neither participates in #110.
//
// No Dc is passed anywhere in this file, by construction: every decision #110
// adds is a class-scope static taking plain numbers and booleans, and the probe
// methods below take no arguments. That keeps this file clear of the call-site
// type-enforcement problem #117 describes and ViewLifecycleTest.mc:115-146
// measures -- there is no `as Gfx.Dc` cast here because there is nothing to
// cast.
class HrProbe extends StrongRowView {
    function initialize() { StrongRowView.initialize(); }

    hidden function startSensor() { }
    hidden function startGps()    { }

    // Priority 1's value path, read straight from the shipping method.
    function rateValue() { return outputRate(); }

    // Priority 2's formatter, read straight from the shipping method. Taking
    // the argument rather than calling stepRemaining() keeps the case
    // deterministic: stepRemaining reads System.getTimer() (:1364).
    function fmtCountdown(secs) { return mmss(secs); }

    // The SPM target band. Named for the unit on purpose -- #110 adds a bpm
    // band alongside it, and the whole point of these two accessors is that the
    // two bands stay distinct.
    function spmTargetLo() { return mTgtLo; }
    function spmTargetHi() { return mTgtHi; }

    // The BPM band, as loadSettings left it (clamped and swapped).
    function bpmBandLo() { return mHrLo; }
    function bpmBandHi() { return mHrHi; }

    // Drive the three heart-rate fields directly, so a case can put the view in
    // "HR present" and "HR absent" without a sensor. Written, never read back
    // through a second path -- the point is what the REST of the view does with
    // them.
    function setHrState(bpm, lastMs, ever) {
        mHrBpm    = bpm;
        mLastHrMs = lastMs;
        mHrEver   = ever;
    }
}

// -- c0: characterization pins -------------------------------------------------
// Green in every epoch of this change.

// Priority 1, the no-data end of it. A freshly constructed view has measured
// nothing, and outputRate() must say so with 0.0 -- which is the premise the
// `rate > 0.0` guard in rateColour (:948) rests on, and which drawRate turns
// into "--.-" (:1687). #110 must not touch this, and #110 must not COPY it
// either: the same guard applied to a heart rate is unsound, because the last
// bpm stays in the field after the source drops. That distinction is the
// subject of the differentials later in this file.
(:test) function test_hr_c0_freshViewRateIsZero(logger) {
    var p = new HrProbe();
    var r = p.rateValue();
    if (r != 0.0) {
        logger.error("a freshly constructed view has measured no strokes, so " +
                     "outputRate() must be 0.0 (the '--.-' state); got " + r);
        return false;
    }
    return true;
}

// Priority 2. The countdown's format is pinned at three points -- a whole
// minute, a sub-minute value needing the %02d pad, and zero -- so an edit that
// changed the shape while #110 was adding an arc would move this case rather
// than reaching a wrist unnoticed. mmss ceils (:1633), so 239.1 is 4:00.
(:test) function test_hr_c0_countdownFormatUnchanged(logger) {
    var p = new HrProbe();
    var a = p.fmtCountdown(240.0);
    var b = p.fmtCountdown(65.0);
    var c = p.fmtCountdown(0.0);
    if (!a.equals("4:00") || !b.equals("1:05") || !c.equals("0:00")) {
        logger.error("the interval countdown format must not move: 240.0 -> " +
                     a + " (want 4:00), 65.0 -> " + b + " (want 1:05), 0.0 -> " +
                     c + " (want 0:00)");
        return false;
    }
    return true;
}

// The SPM band is loaded from targetLo/targetHi (properties.xml:6-7, labelled
// "spm" in strings.xml:7-8) and consumed as a stroke rate at :1777 and :1783.
// #110 adds a SECOND band, in bpm. This pins that adding it leaves the first
// one alone -- the failure #110 warns about is a reader, or a future edit,
// confusing targetLo (spm) with hrLo (bpm), and the two must not become
// entangled in loadSettings.
(:test) function test_hr_c0_spmBandDefaultsUnchanged(logger) {
    var p = new HrProbe();
    if (p.spmTargetLo() != 16 || p.spmTargetHi() != 18) {
        logger.error("the SPM target band must stay 16-18 spm: got " +
                     p.spmTargetLo() + "-" + p.spmTargetHi() +
                     " -- a bpm band must never be loaded into mTgtLo/mTgtHi");
        return false;
    }
    return true;
}

// -- c1: green pins on the new seam --------------------------------------------
// Green from the commit that introduces the statics onward. They are the anchor
// for the red differentials that follow: without them a "fix" that made hrZone
// return HRZ_NONE unconditionally, or that collapsed the angle map, would
// satisfy every red case while being strictly worse than the defect.

// The map's two endpoints. The bottom of the display range sits at the bottom
// of the sweep and the top at the top -- low bpm low on the screen, which is
// the direction the fill grows in.
(:test) function test_hr_angleSpansTheSweep(logger) {
    var lo = StrongRowView.hrAngle($.HR_DISP_LO);
    var hi = StrongRowView.hrAngle($.HR_DISP_HI);
    if (lo != $.HR_ARC_BOT || hi != $.HR_ARC_TOP) {
        logger.error("the display range must map onto the whole sweep: " +
                     $.HR_DISP_LO + " bpm -> " + lo + " deg (want " +
                     $.HR_ARC_BOT + "), " + $.HR_DISP_HI + " bpm -> " + hi +
                     " deg (want " + $.HR_ARC_TOP + ")");
        return false;
    }
    return true;
}

// Nothing, in range or out of it, can put a mark outside the sweep. This case
// is what keeps the sweep bound from being only a comment: the bound is worth
// something only if the angle function cannot exceed it.
(:test) function test_hr_angleStaysInsideTheSweep(logger) {
    var probes = [0, 1, 40, 59, 60, 61, 97, 123, 147, 199, 200, 201, 250, 400];
    for (var i = 0; i < probes.size(); i++) {
        var a = StrongRowView.hrAngle(probes[i]);
        if (a < $.HR_ARC_TOP || a > $.HR_ARC_BOT) {
            logger.error("hrAngle(" + probes[i] + ") = " + a +
                         " is outside the sweep [" + $.HR_ARC_TOP + ", " +
                         $.HR_ARC_BOT + "] -- the sweep bound is what keeps " +
                         "this off the caption row");
            return false;
        }
    }
    return true;
}

// A higher heart rate never sits lower on the arc. Degrees DECREASE as bpm
// rises (0 is 3 o'clock and the sweep runs up the left edge), so the assertion
// is non-increasing, not non-decreasing -- and getting that backwards is
// exactly the class of inversion the #107 colour work already had to correct.
(:test) function test_hr_angleIsMonotonic(logger) {
    var prev = StrongRowView.hrAngle(0);
    for (var bpm = 1; bpm <= 260; bpm += 1) {
        var a = StrongRowView.hrAngle(bpm);
        if (a > prev) {
            logger.error("hrAngle is not monotonic: " + (bpm - 1) + " bpm -> " +
                         prev + " deg but " + bpm + " bpm -> " + a +
                         " deg; degrees must decrease as bpm rises");
            return false;
        }
        prev = a;
    }
    return true;
}

// The fill can never be negative and can never exceed the sweep. Both ends
// matter: a negative sweep would draw the arc the wrong way round the dial, and
// an over-long one would run past the sweep bound.
(:test) function test_hr_fillSweepIsBounded(logger) {
    var span = $.HR_ARC_BOT - $.HR_ARC_TOP;
    var probes = [0, 30, 60, 100, 130, 180, 200, 240];
    for (var i = 0; i < probes.size(); i++) {
        var s = StrongRowView.hrFillSweep(probes[i]);
        if (s < 0 || s > span) {
            logger.error("hrFillSweep(" + probes[i] + ") = " + s +
                         " is outside [0, " + span + "]");
            return false;
        }
    }
    return true;
}

// The band pair is ordered low-degree first (drawArc counter-clockwise wants
// the smaller degree as degreeStart) and lands inside the sweep, so the marker
// is always ON the track. That last property is why loadSettings clamps the
// band to the DISPLAY RANGE rather than to some independent pair of bounds.
(:test) function test_hr_bandArcOrderedAndInsideSweep(logger) {
    var ba = StrongRowView.hrBandArc(116, 130);
    if (ba[0] > ba[1]) {
        logger.error("hrBandArc must return [smaller, larger] degrees for a " +
                     "counter-clockwise draw; got [" + ba[0] + ", " + ba[1] + "]");
        return false;
    }
    if (ba[0] < $.HR_ARC_TOP || ba[1] > $.HR_ARC_BOT) {
        logger.error("the band marker must land on the track: [" + ba[0] + ", " +
                     ba[1] + "] escapes the sweep [" + $.HR_ARC_TOP + ", " +
                     $.HR_ARC_BOT + "]");
        return false;
    }
    return true;
}

// An inverted band produces the same marker as the right-way-round one. That
// post-condition belongs to the static, not to loadSettings' swap -- a public
// static should not depend on a caller elsewhere in the file having tidied up
// first.
(:test) function test_hr_bandArcHandlesInvertedInput(logger) {
    var a = StrongRowView.hrBandArc(116, 130);
    var b = StrongRowView.hrBandArc(130, 116);
    if (a[0] != b[0] || a[1] != b[1]) {
        logger.error("an inverted band must draw the same marker: [" + a[0] +
                     ", " + a[1] + "] vs [" + b[0] + ", " + b[1] + "]");
        return false;
    }
    return true;
}

// #21 is that settings.xml's declared bounds are not applied in code. The three
// cases below are this feature's promise that it does not add to that backlog.
// Connect IQ Properties survive an app update and a sideloaded .set file is not
// re-clamped on load, so the declaration alone is not a bound.
(:test) function test_hr_clampBandSwapsInverted(logger) {
    var b = StrongRowView.hrClampBand(140, 110);
    if (b[0] != 110 || b[1] != 140) {
        logger.error("an inverted band must be swapped, not accepted: got [" +
                     b[0] + ", " + b[1] + "], want [110, 140]");
        return false;
    }
    return true;
}

(:test) function test_hr_clampBandBoundsBothEnds(logger) {
    var lowSide  = StrongRowView.hrClampBand(10, 20);
    var highSide = StrongRowView.hrClampBand(400, 500);
    var both     = StrongRowView.hrClampBand(10, 500);
    if (lowSide[0] != $.HR_DISP_LO || lowSide[1] != $.HR_DISP_LO ||
        highSide[0] != $.HR_DISP_HI || highSide[1] != $.HR_DISP_HI ||
        both[0] != $.HR_DISP_LO || both[1] != $.HR_DISP_HI) {
        logger.error("both ends must be clamped to [" + $.HR_DISP_LO + ", " +
                     $.HR_DISP_HI + "]: 10-20 -> [" + lowSide[0] + ", " +
                     lowSide[1] + "], 400-500 -> [" + highSide[0] + ", " +
                     highSide[1] + "], 10-500 -> [" + both[0] + ", " +
                     both[1] + "]");
        return false;
    }
    return true;
}

(:test) function test_hr_clampBandLeavesValidBandAlone(logger) {
    var b = StrongRowView.hrClampBand(116, 130);
    if (b[0] != 116 || b[1] != 130) {
        logger.error("a band already inside the display range must pass " +
                     "through untouched; got [" + b[0] + ", " + b[1] + "]");
        return false;
    }
    return true;
}

// The shipped defaults, reached through loadSettings rather than asserted
// against the literals in properties.xml, so the two cannot drift apart.
//
// 116-130 is DERIVED, not invented: a 68-minute durability row rowed with a
// stated intent of ~123 bpm, +/-7. It is configuration, not doctrine, and is
// expected to be set per athlete. The band is also drawn ON THE TRACK, so a
// band that does not match the athlete shows up as a marker in the wrong place
// rather than as a silently wrong colour.
(:test) function test_hr_bandDefaultsAreTheMeasuredTarget(logger) {
    var p = new HrProbe();
    if (p.bpmBandLo() != 116 || p.bpmBandHi() != 130) {
        logger.error("the shipped HR band must load as 116-130 bpm; got " +
                     p.bpmBandLo() + "-" + p.bpmBandHi());
        return false;
    }
    return true;
}

// One vocabulary, not two that happen to agree today. Asserted against
// rateColour itself rather than against the Gfx constants, so a future retune
// of the stroke-rate palette drags the arc along with it or reds here.
(:test) function test_hr_zoneColoursMatchTheStrokeRateVocabulary(logger) {
    var below = StrongRowView.hrZoneColour($.HRZ_BELOW);
    var inB   = StrongRowView.hrZoneColour($.HRZ_IN);
    var above = StrongRowView.hrZoneColour($.HRZ_ABOVE);
    if (below != StrongRowView.rateColour(true, 14.0, 16, 18) ||
        inB   != StrongRowView.rateColour(true, 17.0, 16, 18) ||
        above != StrongRowView.rateColour(true, 22.0, 16, 18)) {
        logger.error("the arc and the stroke-rate numeral must share one " +
                     "colour vocabulary: below -> " + below + ", in -> " + inB +
                     ", above -> " + above);
        return false;
    }
    return true;
}

// Phrased as a separation check rather than pinning four constants, the same
// style as test_rate_belowDiffersFromAbove: whatever the palette becomes, the
// four zone answers must not collide -- and in particular "no data" must not
// look like any reading.
(:test) function test_hr_zoneColoursAreDistinct(logger) {
    var z = [$.HRZ_NONE, $.HRZ_BELOW, $.HRZ_IN, $.HRZ_ABOVE];
    for (var i = 0; i < z.size(); i++) {
        for (var j = i + 1; j < z.size(); j++) {
            var a = StrongRowView.hrZoneColour(z[i]);
            var b = StrongRowView.hrZoneColour(z[j]);
            if (a == b) {
                logger.error("zone " + z[i] + " and zone " + z[j] +
                             " render the same colour (" + a + ")");
                return false;
            }
        }
    }
    return true;
}

// Presence needs BOTH the explicit flag and freshness -- #110's acceptance
// criterion, stated as a truth table. The stale row is the one that matters: a
// view that has genuinely had a reading, whose reading has since gone stale,
// does NOT have a heart rate.
(:test) function test_hr_haveNeedsBothFlagAndFreshness(logger) {
    var neverFlag  = StrongRowView.hrHave(false, 1000, 1100, 5000);
    var neverStamp = StrongRowView.hrHave(true, 0, 1100, 5000);
    var stale      = StrongRowView.hrHave(true, 1000, 9000, 5000);
    var live       = StrongRowView.hrHave(true, 1000, 1100, 5000);
    if (neverFlag || neverStamp || stale || !live) {
        logger.error("hrHave truth table wrong: no-flag -> " + neverFlag +
                     " (want false), no-stamp -> " + neverStamp +
                     " (want false), stale -> " + stale +
                     " (want false), live -> " + live + " (want true)");
        return false;
    }
    return true;
}

// With a heart rate, the track is ONE continuous arc. Green in both epochs, and
// it is the anchor the broken-track differential is measured against: without
// it, a "fix" that broke the track in every state would satisfy that
// differential while being worse than the defect.
(:test) function test_hr_trackIsOneArcWhenHrIsPresent(logger) {
    var n = StrongRowView.hrTrackParts(true);
    if (n != 1) {
        logger.error("with a heart rate present the track must be one " +
                     "continuous arc; got " + n + " segments");
        return false;
    }
    return true;
}

// #110's negative acceptance criterion as a test rather than a promise: the
// stroke rate and the interval countdown must be IDENTICAL with and without a
// heart rate. Driven by putting one view into both states and reading the two
// value paths back.
//
// Green from the commit that introduces the HR fields onward. The point is not
// that it can fail today; it is that a later edit routing either priority
// through HR state would move it.
(:test) function test_hr_rateAndCountdownIgnoreHrState(logger) {
    var p = new HrProbe();
    p.setHrState(0, 0, false);
    var rateAbsent = p.rateValue();
    var cdAbsent = p.fmtCountdown(240.0);
    p.setHrState(128, 1000, true);
    var ratePresent = p.rateValue();
    var cdPresent = p.fmtCountdown(240.0);
    if (rateAbsent != ratePresent || !cdAbsent.equals(cdPresent)) {
        logger.error("a heart rate must not change glance priorities 1 or 2: " +
                     "rate " + rateAbsent + " -> " + ratePresent +
                     ", countdown " + cdAbsent + " -> " + cdPresent);
        return false;
    }
    return true;
}
