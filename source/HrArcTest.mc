using Toybox.Test;
using Toybox.Graphics as Gfx;
using Toybox.Lang;
using Toybox.System;

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
// measures. The one call site that DOES pass a Dc is HrProbe.runUpdate below,
// and it carries the cast unconditionally -- #117's mitigation applied without
// guessing which sites would be rejected.
//
// -- Recording Dc --------------------------------------------------------------
// A duck-typed stand-in that logs every primitive the shipping draw path issues.
// mTimer and mCoreSensor are untyped fields and onUpdate's dc is used only
// through method calls, so at runtime only duck typing applies and this needs
// just the members onUpdate and its helpers actually call.
//
// Two things it records, for two different jobs:
//   arcs / lines  the arc widget's own geometry, which is all this class can
//                 see of it -- a count and an order, never an appearance.
//   texts         every drawText, fully argument-qualified. The arc draws NO
//                 text at all, so the text log is exactly the screen OUTSIDE
//                 the arc, which is what makes "a missing heart rate must not
//                 degrade priorities 1 and 2" checkable by comparison rather
//                 than by assertion.
//
// It records what the code CALLS. It says nothing about what a panel shows.
class HrDc {
    var w; var h;
    var arcs;        // drawArc call count
    var arcLo;       // every drawArc's degStart, in call order
    var arcHi;       // every drawArc's degEnd, in call order
    var lines;       // drawLine call count
    var texts;       // every drawText, as "x|y|font|string|justify"
    var throwAtArc;  // 1-based index of the drawArc that should throw; 0 = none

    function initialize(width, height) {
        w = width; h = height;
        arcs = 0; arcLo = []; arcHi = []; lines = 0; texts = []; throwAtArc = 0;
    }

    function getWidth()  { return w; }
    function getHeight() { return h; }
    function setColor(fg, bg) { }
    function setPenWidth(p)   { }
    function clear()          { }

    // Counts FIRST, then fails -- the same rule LifeTimer.start states
    // (ViewLifecycleTest.mc:50-55): "never called" and "called and threw" must
    // stay distinguishable.
    //
    // Records the ANGLES too. The count alone left the drawn segment LAYOUT
    // unpinned, and the gaps ARE the no-data channel: changing the loop stride
    // from `i * 2.0 * seg` to `i * seg` abuts the three segments into a solid
    // track with no gaps, and every count-based case stays green.
    function drawArc(x, y, r, attr, degStart, degEnd) {
        arcs++;
        arcLo.add(degStart);
        arcHi.add(degEnd);
        if (throwAtArc > 0 && arcs >= throwAtArc) { throw new Lang.Exception(); }
    }

    function drawLine(x1, y1, x2, y2) { lines++; }

    function drawText(x, y, font, s, just) {
        texts.add(x.toString() + "|" + y.toString() + "|" + font.toString() +
                  "|" + s + "|" + just.toString());
    }

    // The whole text log as one comparable string.
    function textLog() {
        var out = "";
        for (var i = 0; i < texts.size(); i++) { out += texts[i] + "\n"; }
        return out;
    }
}

class HrProbe extends StrongRowView {
    function initialize() { StrongRowView.initialize(); }

    hidden function startSensor() { }
    hidden function startGps()    { }

    // Neutralised for determinism, and ONLY these two beyond the sensor pair
    // above: both read Activity.getActivityInfo(), whose value is not under
    // test here and is not under this test's control. Everything else in
    // onUpdate is the shipping code, so the draw cases below drive the ACTUAL
    // call site rather than a transcription of it -- the rule
    // DspTimeBaseTest.mc:19-21 states for onSensorData. Both overrides live
    // further down, beside the settable fields that back them.

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

    // Put the view into a live, TIME-STABLE work step.
    //
    // Time stability is the whole difficulty and it is deliberate, not
    // incidental. onUpdate renders two clocks -- the countdown from
    // stepRemaining() and the footer from totalElapsed() -- and a case that
    // compares two renders a few milliseconds apart would flake the moment one
    // of them ticked. So:
    //   * mStepStartMs is pushed far enough into the past that stepRemaining()
    //     is clamped at 0.0, giving a constant "0:00";
    //   * mPaused selects drawFoot's PAUSED branch, which carries a stroke
    //     count and no elapsed time.
    // Both are real states of the shipping code, not test-only shims -- and
    // PAUSED is a state #110 has to answer for anyway, since the arc is drawn
    // during it.
    function enterWorkStep(paused) {
        mStarted = true;
        mPaused  = paused;
        mStartMs = System.getTimer();
        mStepStartMs = System.getTimer() - 3600000;
        for (var i = 0; i < mSteps.size(); i++) {
            if (mSteps[i][:type] == STEP_WORK) { mStepIdx = i; return; }
        }
    }

    // Free-row mode: onUpdate returns before the workout branch, so the arc is
    // never reached. Driven through the real flag rather than by asserting the
    // early return exists.
    function setFreeRow() { mWorkoutEnabled = false; }

    // The restoring half of setFreeRow. A sweep that reuses one probe across
    // kinds would otherwise render every kind after free-row AS free-row --
    // silently, and in the safe direction, so every later case would pass for
    // the wrong reason.
    function setWorkoutEnabled(v) { mWorkoutEnabled = v; }

    // -- seams the layout suite (HrLayoutTest.mc) drives -----------------------

    // Any step type, by its class constant, without going through onPrimary.
    function enterStep(kind, paused) {
        mStarted = true;
        mPaused  = paused;
        mStartMs = System.getTimer();
        mStepStartMs = System.getTimer() - 3600000;
        for (var i = 0; i < mSteps.size(); i++) {
            if (mSteps[i][:type] == kind) { mStepIdx = i; return true; }
        }
        return false;
    }

    // The pre-START screen: built, never started.
    function enterPreStart() { mStarted = false; mPaused = false; }

    // The step-type constants are class `hidden const`s, i.e. instance members,
    // so a (:test) free function cannot name them. Exposed here rather than
    // transcribed into the layout suite, where a copy could drift.
    function kindWork() { return STEP_WORK; }
    function kindRest() { return STEP_REST; }
    function kindGate() { return STEP_GATE; }
    function kindWarm() { return STEP_WARM; }
    function kindCool() { return STEP_COOL; }
    function kindDone() { return STEP_DONE; }

    // The bpm band, bypassing loadSettings so a case can sweep the whole
    // settable range. Pushed through hrClampBand so a case can never assert
    // against a band the shipping clamp would have refused.
    function setBand(lo, hi) {
        var b = StrongRowView.hrClampBand(lo, hi);
        mHrLo = b[0];
        mHrHi = b[1];
    }

    // drawFoot's hard-failure branch: NO ACCEL is the longest footer string and
    // must stay visible during work (#108), so it is a layout case.
    function setSensorOk(ok) { mSensorOk = ok; }

    // A settable speed and distance, so the layout suite can drive the WIDEST
    // strings drawPace and drawFoot can produce. A GPS speed spike shortens the
    // pace term but ADDS the metres-per-stroke term, so the widest pace string
    // is not the idle one.
    hidden var mFakeSpeed;
    hidden var mFakeDist;
    function setSpeed(v) { mFakeSpeed = v; }
    function setDist(v)  { mFakeDist = v; }
    hidden function currentSpeed() {
        return (mFakeSpeed == null) ? 0.0 : mFakeSpeed;
    }
    hidden function elapsedDist() {
        return (mFakeDist == null) ? 0.0 : mFakeDist;
    }

    // Every string this view can draw is DATA-DEPENDENT, and a layout case that
    // renders only one instance of each measures the narrowest screen the app
    // can produce rather than the widest. These push each one to its practical
    // maximum:
    //   * 30 x 60' is the largest workout settings.xml declares, so the title
    //     is "30x60'", the interval label "WORK 30/30", and the rest and gate
    //     sub-rows "next: WORK 30" / "to start WORK 30";
    //   * a long session with a large distance and stroke count gives
    //     drawFoot's widest form, "REC 199:59 12.35km 9999str".
    function setWorkoutShape(n, workSec) {
        mNumWork = n;
        mWorkSec = workSec;
        buildWorkout();
    }

    function setWideSession() {
        mStrokeCount = 9999;
        mStartMs = System.getTimer() - 11999000;   // ~199:59 elapsed
        setDist(12345.6);
    }

    // The other end of the same dial, so a reused probe can be put back into
    // the narrow shape instead of needing a fresh one.
    function setNarrowSession() {
        mStrokeCount = 6;
        mStartMs = System.getTimer();
        setDist(0.0);
    }

    // Like enterStep, but leaves the step clock LIVE so the countdown renders
    // its full duration rather than the clamped "0:00". Only the layout suite
    // uses it: it takes one measurement per render and never compares two, so a
    // ticking clock costs it nothing.
    function enterStepLive(kind, paused) {
        mStarted = true;
        mPaused  = paused;
        mStepStartMs = System.getTimer();
        for (var i = 0; i < mSteps.size(); i++) {
            if (mSteps[i][:type] == kind) { mStepIdx = i; return true; }
        }
        return false;
    }

    // Drive real strokes through the shipping detector so outputRate() is
    // NON-ZERO. Without this, "the rate is unchanged by HR state" compares 0.0
    // against 0.0 and would hold even if the rate were a constant.
    //
    // 3.3333 s between drives is 18.0 spm: inside registerStroke's accepted
    // period band, below FAST_NEEDS_LOCK, and below MAX_RATE, so outputRate()
    // passes the median straight through with no autocorrelation lock.
    function driveStrokes() {
        var t = 0.0;
        for (var i = 0; i < 7; i++) {
            registerStroke(t);
            t += 3.3333333;
        }
    }

    // The ONE Dc-passing call site in this file, and it carries the cast
    // unconditionally. onUpdate is an unannotated override of
    // Ui.View.onUpdate(dc as Graphics.Dc) and monkeyc enforces that inherited
    // type at call sites with no -l level; #117 measures the enforcement as
    // deterministic but NOT predictable from the call site, keyed on the
    // enclosing symbol's name. The rule that follows from that measurement is
    // "cast every one" rather than "cast the ones that complain", so this is
    // cast whether or not it would be rejected today. Erased at runtime; only
    // duck typing applies there.
    function runUpdate(d) { onUpdate(d as Gfx.Dc); }
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

// #110's negative acceptance criterion as a test rather than a promise: a
// missing heart rate must leave glance priorities 1 and 2 IDENTICAL.
//
// AN EARLIER VERSION OF THIS CASE WAS DEGENERATE, and it is worth recording why
// rather than quietly replacing it. It compared outputRate() before and after
// setting the HR fields on a FRESH probe -- 0.0 against 0.0 -- and mmss(240.0)
// against itself, mmss being a pure formatter. Both comparisons hold for a
// stroke rate replaced by a constant, so the case asserted almost nothing.
//
// This version fixes both halves:
//   * driveStrokes() puts a real, non-zero rate through the shipping detector,
//     so the compared quantity is live. The case asserts that explicitly before
//     comparing, so a future change that stopped the strokes registering would
//     red here rather than silently returning the case to vacuity;
//   * the comparison is the FULL TEXT LOG of a real onUpdate, not two scalars.
//     The arc draws no text at all, so the text log is exactly the screen
//     outside the arc -- every element of it, in order, with its coordinates,
//     font and justification.
//
// Green in every epoch of this change; the point is that a later edit routing
// any part of the screen through HR state would move it.
(:test) function test_hr_screenOutsideTheArcIgnoresHrState(logger) {
    var p = new HrProbe();
    p.driveStrokes();
    p.enterWorkStep(true);

    var live = p.rateValue();
    if (live <= 0.0) {
        logger.error("the comparison below is only worth making against a LIVE " +
                     "rate; driveStrokes() left outputRate() at " + live);
        return false;
    }

    p.setHrState(0, 0, false);
    var absent = new HrDc(240, 240);
    p.runUpdate(absent);

    p.setHrState(128, System.getTimer(), true);
    var present = new HrDc(240, 240);
    p.runUpdate(present);

    if (!absent.textLog().equals(present.textLog())) {
        logger.error("a heart rate changed the screen OUTSIDE the arc, which " +
                     "#110 forbids. Without HR:\n" + absent.textLog() +
                     "With HR:\n" + present.textLog());
        return false;
    }
    if (absent.texts.size() < 6) {
        logger.error("only " + absent.texts.size() + " text elements drew; the " +
                     "comparison above is vacuous if the screen is empty");
        return false;
    }
    return true;
}

// -- Draw-path pins ------------------------------------------------------------
// Green in every epoch of this change. Up to here the arc was pinned only
// through its pure statics; these drive the REAL onUpdate call site, which the
// statics explicitly do not cover (the scope caveat rateColour states for
// itself, and which these cases exist to narrow).
//
// They count primitives and nothing else. A count is not an appearance, and no
// case in this file claims one.

// With a heart rate: one continuous track arc, one fill arc, one band rail arc,
// two band edge ticks and one head tick.
(:test) function test_hr_workViewDrawsTheArcWhenHrIsPresent(logger) {
    var p = new HrProbe();
    p.enterWorkStep(false);
    p.setHrState(128, System.getTimer(), true);
    var d = new HrDc(240, 240);
    p.runUpdate(d);
    if (d.arcs != 3 || d.lines != 3) {
        logger.error("a work step with a live heart rate must draw 3 arcs " +
                     "(track, fill, band rail) and 3 lines (2 band ticks, " +
                     "1 head tick); got " + d.arcs + " arcs, " + d.lines + " lines");
        return false;
    }
    return true;
}

// Without one: the track is drawn in three segments, the fill and the head tick
// are absent, and the band rail with its two ticks stays. The end-to-end form
// of the no-data state, which until now was pinned only at hrTrackParts.
(:test) function test_hr_workViewBreaksTheTrackWhenHrIsAbsent(logger) {
    var p = new HrProbe();
    p.enterWorkStep(false);
    p.setHrState(0, 0, false);
    var d = new HrDc(240, 240);
    p.runUpdate(d);
    if (d.arcs != 4 || d.lines != 2) {
        logger.error("a work step with no heart rate must draw 4 arcs (3 " +
                     "track segments + the band rail) and 2 lines (the band " +
                     "ticks, no head tick); got " + d.arcs + " arcs, " +
                     d.lines + " lines");
        return false;
    }
    return true;
}

// PAUSED is a work step, so the arc is still drawn -- and sampleHr is called
// unconditionally in onTick, so the reading behind it keeps updating while
// paused. Recorded as a behaviour rather than left to be discovered.
(:test) function test_hr_pausedWorkStepStillDrawsTheArc(logger) {
    var p = new HrProbe();
    p.enterWorkStep(true);
    p.setHrState(128, System.getTimer(), true);
    var d = new HrDc(240, 240);
    p.runUpdate(d);
    if (d.arcs != 3 || d.lines != 3) {
        logger.error("pausing must not remove the heart-rate arc: got " +
                     d.arcs + " arcs, " + d.lines + " lines");
        return false;
    }
    return true;
}

// Free-row mode returns before the workout branch, so the arc is never reached.
// #108 requires free row to be behaviourally unchanged, and this is #110's half
// of that promise -- driven through the real mWorkoutEnabled flag rather than
// by asserting that an early return exists.
(:test) function test_hr_freeRowNeverDrawsTheArc(logger) {
    var p = new HrProbe();
    p.setFreeRow();
    p.setHrState(128, System.getTimer(), true);
    var d = new HrDc(240, 240);
    p.runUpdate(d);
    if (d.arcs != 0 || d.lines != 0) {
        logger.error("free-row mode must draw no arc geometry at all; got " +
                     d.arcs + " arcs, " + d.lines + " lines");
        return false;
    }
    if (d.texts.size() < 4) {
        logger.error("free-row mode drew only " + d.texts.size() + " text " +
                     "elements, so the check above proves nothing about it");
        return false;
    }
    return true;
}

// -- c2: the differentials -----------------------------------------------------
// Every case below is RED against the commit that introduces the seam and green
// against the one that completes it. Nothing else in this file moves between
// those two epochs.
//
// They fall into two defect families, both of which this repository has
// concrete history with.
//
// FAMILY 1 -- absence derived from a value. rateColour's `rate > 0.0` guard
// (StrongRowView.mc:948) is SOUND where it stands, because outputRate()
// genuinely returns 0.0 when nothing has been measured. Copied onto a heart
// rate it is unsound, because the last bpm survives in the field after the
// source drops: the arc would then keep painting a stale reading, and once that
// reading happened to be under the band it would paint it BELOW BAND -- telling
// the rower to work harder on the strength of a number that no longer exists.
// #86 shipped a 0.0 skin temperature this way and #107 shipped "--.-" this way.
//
// FAMILY 2 -- the full circle. SDK 9.2.0 documents drawArc as truncating its
// parameters toward zero and drawing A COMPLETE CIRCLE when degreeStart and
// degreeEnd are equal. So a degenerate band, a band narrower than one truncated
// degree, or a fill of zero length is not a small mark that nobody notices --
// it is a ring across the entire display, over every other element. The guard
// has to sit on the TRUNCATED values, because that is where the hazard is:
// 184.28 and 183.86 are different heart rates and, after truncation, one
// degree apart -- and one more bpm closes even that.

// The single most important case in this file. A heart-rate source that has
// dropped must not be rendered as "below band", whatever the last reading was.
(:test) function test_hr_absentSourceIsNeverBelowBand(logger) {
    var z = StrongRowView.hrZone(false, 105, 116, 130);
    if (z != $.HRZ_NONE) {
        logger.error("#110: with no live heart rate the zone must be " +
                     $.HRZ_NONE + " (no data); got " + z +
                     ". A stale 105 bpm rendered as BELOW BAND tells the " +
                     "rower to work harder on a number that no longer exists");
        return false;
    }
    return true;
}

// The general form: no last-reading value whatsoever turns absence into a zone.
// Includes 0, so a fix that merely special-cased zero would still red here.
(:test) function test_hr_absentSourceIsNoDataWhateverTheLastReading(logger) {
    var last = [0, 55, 105, 123, 129, 180, 240];
    for (var i = 0; i < last.size(); i++) {
        var z = StrongRowView.hrZone(false, last[i], 116, 130);
        if (z != $.HRZ_NONE) {
            logger.error("#110: hasHr=false with a last reading of " + last[i] +
                         " must be " + $.HRZ_NONE + " (no data); got " + z +
                         " -- presence is the FLAG, never the value");
            return false;
        }
    }
    return true;
}

// A band whose two ends coincide must still produce a drawable arc, because the
// alternative is not a small mark -- it is a complete circle over the whole
// screen.
(:test) function test_hr_degenerateBandNeverDrawsAFullCircle(logger) {
    var pairs = [[120, 120], [60, 60], [200, 200], [116, 116]];
    for (var i = 0; i < pairs.size(); i++) {
        var ba = StrongRowView.hrBandArc(pairs[i][0], pairs[i][1]);
        if (ba[1] - ba[0] < $.HR_ARC_MIN_D) {
            logger.error("#110: band " + pairs[i][0] + "-" + pairs[i][1] +
                         " gives degreeStart " + ba[0] + " degreeEnd " + ba[1] +
                         " (sweep " + (ba[1] - ba[0]) + "); drawArc draws a " +
                         "COMPLETE CIRCLE when its two angles are equal, so " +
                         "the sweep must be at least " + $.HR_ARC_MIN_D);
            return false;
        }
    }
    return true;
}

// The same hazard reached from UNEQUAL bpm. 120-121 is a legitimate one-bpm
// band; after truncation its two angles are one degree apart, which is below
// the minimum drawable sweep and one bpm away from being the same degree.
// Truncation is why the guard cannot live on the bpm values.
(:test) function test_hr_narrowBandSurvivesAngleTruncation(logger) {
    var ba = StrongRowView.hrBandArc(120, 121);
    if (ba[1] - ba[0] < $.HR_ARC_MIN_D) {
        logger.error("#110: the one-bpm band 120-121 truncates to degrees " +
                     ba[0] + " and " + ba[1] + " (sweep " + (ba[1] - ba[0]) +
                     "), below the minimum drawable sweep of " +
                     $.HR_ARC_MIN_D + " -- drawArc truncates toward zero, so " +
                     "the guard belongs on the DEGREES, not on the bpm");
        return false;
    }
    return true;
}

// The fill's half of the same family. A reading at or near the bottom of the
// display range asks for a zero- or one-degree arc, and a zero-degree arc is
// the complete circle again. Both the at-range and below-range cases are here,
// because a fix that only handled "outside the range" would leave 61 bpm
// drawing a full ring.
// Phrased over the WHOLE bpm domain as a property, not as a list of boundary
// values. An earlier revision of this case hardcoded the bpm either side of the
// boundary, which silently encoded the sweep width of the day: narrowing the
// sweep moved the boundary and reddened the case against code that was correct.
// The property below is invariant to the sweep, and still RED against a
// `bpm > 0` gate, which is what it is for.
(:test) function test_hr_fillIsSkippedWhenItWouldBeSubDegree(logger) {
    for (var bpm = 0; bpm <= 260; bpm++) {
        if (StrongRowView.hrFillVisible(bpm) &&
            StrongRowView.hrFillSweep(bpm) < $.HR_ARC_MIN_D) {
            logger.error("#110: " + bpm + " bpm asks for a fill of " +
                         StrongRowView.hrFillSweep(bpm) + " degree(s), below " +
                         "the minimum drawable sweep of " + $.HR_ARC_MIN_D +
                         ", yet hrFillVisible says draw it -- drawArc with two " +
                         "equal angles is a COMPLETE CIRCLE, not a short arc");
            return false;
        }
    }
    // Non-vacuity, both ways: the bottom of the range must NOT draw a fill (its
    // sweep is zero) and the top MUST, or the property above is satisfied by a
    // function that never draws anything.
    if (StrongRowView.hrFillVisible($.HR_DISP_LO)) {
        logger.error("#110: the bottom of the display range has a zero-length " +
                     "fill and must not be drawn");
        return false;
    }
    if (!StrongRowView.hrFillVisible($.HR_DISP_HI)) {
        logger.error("#110: the top of the display range must draw a fill -- " +
                     "the fill is what carries magnitude");
        return false;
    }
    return true;
}

// #110 requires the clamp to be VISIBLE at both ends: 210 bpm and 200 bpm must
// not render identically, and neither must 50 and 60. The low end is the one
// that gets forgotten.
(:test) function test_hr_clampIsDetectedAtBothEnds(logger) {
    var high = StrongRowView.hrIsClamped($.HR_DISP_HI + 10);
    var low = StrongRowView.hrIsClamped($.HR_DISP_LO - 10);
    var inRange = StrongRowView.hrIsClamped(130);
    if (!high || !low || inRange) {
        logger.error("#110: clamping must be detected at BOTH ends: " +
                     ($.HR_DISP_HI + 10) + " -> " + high + " (want true), " +
                     ($.HR_DISP_LO - 10) + " -> " + low + " (want true), " +
                     "130 -> " + inRange + " (want false)");
        return false;
    }
    return true;
}

// The no-data state's third channel. A continuous track means "there is a heart
// rate"; the absence state has to say something different in GEOMETRY, not only
// by withholding the fill -- because "no fill" and "a fill too short to see"
// are the same picture.
(:test) function test_hr_absentSourceBreaksTheTrack(logger) {
    var n = StrongRowView.hrTrackParts(false);
    if (n <= 1) {
        logger.error("#110: with no heart rate the track must be drawn " +
                     "broken, so the no-data state is readable as geometry " +
                     "and not merely as an absence; got " + n + " segment(s)");
        return false;
    }
    return true;
}

// -- Review round 1, finding 1 -------------------------------------------------
// RED against the head this case lands on, green against the fix that follows.
//
// drawHrArc is called BEFORE every text element, and it is not guarded. A throw
// out of any Dc primitive it issues therefore propagates through onUpdate and
// takes the title, the countdown, the stroke rate, the pace row, the sub row
// and the footer with it -- which is precisely the outcome the sampler's own
// comment says the design must avoid: "a heart rate is an ornament on two
// priorities that must keep working without it". The sampling is wrapped for
// exactly that reason; the drawing was not.
//
// REACHABILITY IS UNVERIFIED, IN BOTH DIRECTIONS, and this case claims neither
// answer. No input has been found that makes a Dc primitive throw, and nothing
// establishes that none can. The property pinned here -- "a throw from the arc
// must not change the rest of the screen" -- is the correct contract under
// either answer, and the case can drive it directly with a Dc that throws on
// demand. That is the same posture ViewLifecycleTest.mc:12-18 takes for a
// second onLayout.
//
// The insurance is one line, this is the FIRST drawArc in the codebase, it runs
// on twelve devices, and it has never run on hardware. That is why the fix
// lands ahead of any reachability answer rather than behind one.
//
// Phrased as an EQUALITY against a clean render rather than as a text count, so
// it keeps guarding this property if the layout is legitimately changed later:
// whatever the screen is, a throwing arc must not alter it.
(:test) function test_hr_arcThrowLeavesTheRestOfTheScreenIntact(logger) {
    var p = new HrProbe();
    p.driveStrokes();
    p.enterWorkStep(true);
    p.setHrState(128, System.getTimer(), true);

    var clean = new HrDc(240, 240);
    p.runUpdate(clean);

    var bad = new HrDc(240, 240);
    bad.throwAtArc = 1;
    var escaped = false;
    try {
        p.runUpdate(bad);
    } catch (e) {
        escaped = true;
    }

    if (!bad.textLog().equals(clean.textLog())) {
        logger.error("a throw from the heart-rate arc changed the rest of the " +
                     "screen. Escaped onUpdate: " + escaped + ". Clean render " +
                     "drew " + clean.texts.size() + " text elements, the " +
                     "throwing one drew " + bad.texts.size() +
                     " -- the arc is drawn before every text element, so an " +
                     "unguarded throw takes glance priorities 1 and 2 with it.");
        return false;
    }
    if (clean.texts.size() < 6) {
        logger.error("the clean render drew only " + clean.texts.size() +
                     " text elements, so the comparison above is vacuous");
        return false;
    }
    return true;
}

// -- The staleness gate ---------------------------------------------------------
// THE COVERAGE HOLE THIS CLOSES. Every other "HR absent" configuration in this
// file and in HrLayoutTest.mc sets bpm = 0, so all of them fail the presence
// VALUE as well as the presence FLAG. That left the freshness half of
// hrHave(mHrEver, mLastHrMs, now, HR_FRESH_MS) unpinned at the draw site:
// deleting the timestamp term entirely kept the whole suite green.
//
// The state below is the one that actually happens in the boat -- the strap was
// working, so mHrEver is true and mHrBpm holds a real number, and then the
// signal dropped. If that renders as a live reading, the athlete is pacing off
// a heart rate from minutes ago. It must render as no data, which is the
// #86/#107 failure class stated for this arc.
(:test) function test_hr_staleReadingRendersAsNoData(logger) {
    var p = new HrProbe();
    p.enterWorkStep(false);
    // Non-zero bpm, ever-seen true, timestamp far outside the freshness window.
    // Deliberately a BELOW-BAND value: if the gate ever fails open, the arc
    // renders blue, and blue means "below target" across the whole app.
    // Guarded, not assumed. System.getTimer() counts from DEVICE start, so on a
    // simulator up for less than 50 s this stamp would be NEGATIVE and hrHave
    // would reject it on its `lastMs > 0` sign term without ever reaching the
    // freshness comparison this case exists to pin.
    var stamp = System.getTimer() - (10 * $.HR_FRESH_MS);
    if (stamp <= 0) {
        logger.error("device uptime is under " + (10 * $.HR_FRESH_MS) +
                     " ms, so this case would pass on hrHave's sign term " +
                     "rather than on freshness. Re-run on a warmer device");
        return false;
    }
    p.setHrState(105, stamp, true);
    var d = new HrDc(240, 240);
    p.runUpdate(d);
    if (d.arcs != 4 || d.lines != 2) {
        logger.error("a STALE heart rate must render exactly as an absent one " +
                     "(4 arcs: 3 track segments + the band rail; 2 lines: the " +
                     "band ticks and no head tick). Got " + d.arcs + " arcs, " +
                     d.lines + " lines -- a non-zero bpm with an expired " +
                     "timestamp is being drawn as though it were live");
        return false;
    }
    return true;
}

// The companion: the SAME bpm, freshly stamped, must render as present. Without
// this the case above would pass for the wrong reason -- an arc that never drew
// a fill for 105 bpm under any circumstances would satisfy it too.
(:test) function test_hr_freshReadingOfTheSameBpmRendersAsPresent(logger) {
    var p = new HrProbe();
    p.enterWorkStep(false);
    p.setHrState(105, System.getTimer(), true);
    var d = new HrDc(240, 240);
    p.runUpdate(d);
    if (d.arcs != 3 || d.lines != 3) {
        logger.error("a FRESH 105 bpm must render as present (3 arcs: whole " +
                     "track + band rail + fill; 3 lines: 2 band ticks + the " +
                     "head tick); got " + d.arcs + " arcs, " + d.lines +
                     " lines. If this and the stale case agree, the staleness " +
                     "test above proves nothing");
        return false;
    }
    return true;
}

// -- The broken track spans its own sweep ---------------------------------------
// hrTrackSeg used integer division: (202 - 158) / (2*3 - 1) is 44/5, which
// truncates to 8 rather than 8.8. The three segments then ran [158,166]
// [174,182] [190,198] and the arc stopped FOUR DEGREES short of its own end,
// with a gap landing on the shipped default band so the band rail and both its
// ticks were drawn over empty track -- the exact outcome the three-segment
// choice exists to avoid.
//
// Pinned on the invariant rather than on 8.8, so the case still means something
// if the sweep or the part count changes: segments and gaps together are
// 2*parts - 1 equal slices, so they must span the sweep exactly.
(:test) function test_hr_brokenTrackSpansTheWholeSweep(logger) {
    var parts = StrongRowView.hrTrackParts(false);
    var seg   = StrongRowView.hrTrackSeg(parts);
    var span  = ($.HR_ARC_BOT - $.HR_ARC_TOP) * 1.0;
    var total = seg * (2 * parts - 1);
    if (total < span - 0.001 || total > span + 0.001) {
        logger.error("the " + parts + " segments and " + (parts - 1) +
                     " gaps must span the sweep exactly: " + (2 * parts - 1) +
                     " x " + seg + " = " + total + ", expected " + span);
        return false;
    }
    return true;
}

// The DRAWN layout, not the formula. The case above pins hrTrackSeg's
// arithmetic; this pins what drawHrArc actually issues, which is a different
// claim and the one that matters -- the GAPS are the no-data channel.
//
// Replaces a case that asserted
//   HR_ARC_TOP + (parts-1)*2*seg + seg == HR_ARC_BOT
// which is the case above rearranged: (2*parts-1)*seg == span, algebraically
// identical for every parts and seg, so it could never red while the other
// stayed green. It was credited with coverage it did not have.
(:test) function test_hr_brokenTrackDrawsSeparatedSegments(logger) {
    var p = new HrProbe();
    p.enterWorkStep(false);
    p.setHrState(0, 0, false);
    var d = new HrDc(240, 240);
    p.runUpdate(d);

    var parts = StrongRowView.hrTrackParts(false);
    // Track segments are the first `parts` arcs; the band rail follows them.
    if (d.arcs < parts + 1) {
        logger.error("expected at least " + (parts + 1) + " arcs (track " +
                     "segments + band rail); got " + d.arcs);
        return false;
    }
    // Every index below is a LOOP variable. The type checker rejects a literal
    // index into an array built with add(), which is why there is no
    // arcLo[0] here -- same reason textLog walks its array rather than
    // subscripting it.
    var prevHi = -1;
    for (var i = 0; i < parts; i++) {
        var lo = d.arcLo[i];
        var hi = d.arcHi[i];
        if (i == 0 && lo != $.HR_ARC_TOP) {
            logger.error("the first segment must start on HR_ARC_TOP (" +
                         $.HR_ARC_TOP + "); it starts at " + lo);
            return false;
        }
        if (i == parts - 1 && hi != $.HR_ARC_BOT) {
            logger.error("the last segment must end on HR_ARC_BOT (" +
                         $.HR_ARC_BOT + "); it ends at " + hi);
            return false;
        }
        if (hi <= lo) {
            logger.error("segment " + i + " is empty or inverted: [" + lo +
                         "," + hi + "] -- equal angles make drawArc render a " +
                         "FULL CIRCLE, the hazard HR_ARC_MIN_D exists for");
            return false;
        }
        // THE POINT OF THE CASE. Consecutive segments must be SEPARATED. A
        // stride of `i * seg` instead of `i * 2 * seg` draws three ABUTTING
        // arcs -- a solid track that merely stops short -- and the no-data
        // state stops being distinguishable from a present one.
        if (prevHi >= 0 && lo <= prevHi) {
            logger.error("segments " + (i - 1) + " and " + i + " abut or " +
                         "overlap: previous ended at " + prevHi + ", this " +
                         "starts at " + lo + ". The broken track IS the " +
                         "no-data channel; with no gaps there is no channel");
            return false;
        }
        prevHi = hi;
    }
    return true;
}

// hrTrackSeg must be TOTAL: it has to degrade sensibly at parts <= 1 rather
// than dividing by one and handing back a slice. Stated as what it pins,
// because an earlier version of this comment claimed the one-segment render
// goes through hrTrackSeg. It does not -- drawHrArc takes its `parts <= 1`
// branch and draws with HR_ARC_TOP / HR_ARC_BOT directly. This guards a future
// caller, not the shipping path.
(:test) function test_hr_wholeTrackIsTheWholeSweep(logger) {
    var seg = StrongRowView.hrTrackSeg(StrongRowView.hrTrackParts(true));
    var span = ($.HR_ARC_BOT - $.HR_ARC_TOP) * 1.0;
    if (seg < span - 0.001 || seg > span + 0.001) {
        logger.error("a 1-part track must be the whole sweep " + span +
                     "; got " + seg);
        return false;
    }
    return true;
}
