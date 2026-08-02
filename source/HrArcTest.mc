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
