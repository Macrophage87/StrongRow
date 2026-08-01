using Toybox.Test;
using Toybox.System;

// Unit tests for source/CoreTempSensor.mc -- the CORE (greenTEG) ANT pod
// decoder and its channel lifecycle. Covers issues #86 (skin decoded from the
// wrong bytes), #19 (freshness window mismatch), #17 (skin/everSeen gated on
// core validity), #18 (channel leaked on throw) and #26 (unbounded re-search).
//
// These are (:test) functions: included in the --unit-test build and stripped
// from the shipping build. They EXECUTE on every PR (the run-tests CI job runs
// them headlessly in the simulator, judged by a fail-closed parser), and their
// names are pinned in scripts/expected_tests.txt -- adding or removing a test
// here means editing that file in the SAME commit. See docs/CI.md.
//
// c0: characterization pins only. Every assertion below is true BOTH before and
// after the five fixes land -- they exist to prove the c1 refactor is
// behaviour-preserving, not to describe the defects. The differentials that
// must go red before the fix are added later, in c2.

// -- Probe -------------------------------------------------------------------
// `hidden` in Monkey C is protected, so a subclass can reach the sensor's state
// without adding any accessor to the shipping class -- the same pattern as
// DspProbe in DspTimeBaseTest.mc. Referenced only from (:test) functions, so it
// drops out of the release build.
//
// MEASURED HAZARD -- do not remove the null guards. A base initialize() that
// calls an unqualified `hidden` method DISPATCHES TO THE SUBCLASS OVERRIDE, and
// it does so while the subclass's own fields are still null, because Monkey C
// requires Base.initialize() to complete before the subclass assigns anything.
// A null-symbol invocation raised inside a `catch` block is additionally NOT
// caught by any enclosing `try` -- it surfaces as a test ERROR, not a FAIL. So
// every override here lazy-initialises its own recorder on entry rather than
// trusting initialize() to have run.
class CoreProbe extends CoreTempSensor {

    var mOpens;

    function initialize() {
        CoreTempSensor.initialize();   // may re-enter openChannel() below
        if (mOpens == null) { mOpens = 0; }
    }

    // Counts the call, THEN runs the real body -- tests that assert on what
    // openChannel() does to the channel need the shipping code to execute.
    hidden function openChannel() {
        if (mOpens == null) { mOpens = 0; }
        mOpens++;
        CoreTempSensor.openChannel();
    }

    function opens() {
        if (mOpens == null) { mOpens = 0; }
        return mOpens;
    }

    // Baseline clear: initialize() runs openChannel() before any test body
    // starts, so counters are reset rather than compared against an assumed 0.
    function resetRecorders() {
        mOpens = 0;
    }

    // Stamp the freshness clock `ageMs` in the past and seed the readings.
    //
    // Clock-robust by construction: System.getTimer() is device uptime, which is
    // ~9.4e6 ms on this workstation's simulator but may be only a few thousand
    // in a fresh CI container. When `ageMs` exceeds the uptime the stamp goes
    // <= 0, which the getters treat as never-seen -- the SAME verdict a genuinely
    // stale stamp gets. Both c0 staleness pins therefore hold under either clock.
    function stamp(ageMs, core, skin) {
        mCore   = core;
        mSkin   = skin;
        mLastMs = System.getTimer() - ageMs;
    }
}

// -- c0 characterization pins ------------------------------------------------

// A freshly constructed sensor reports nothing. Also proves the constructor is
// safe to run in the headless simulator: openChannel() throws
// "Unable to acquire ANT Channel" there, which its own catch swallows, so no
// channel is acquired and none leaks.
(:test) function test_ct_initialStateIsCold(logger) {
    var s = new CoreTempSensor();
    var ok = true;
    if (s.everSeen() != false) { logger.error("everSeen should be false on a fresh sensor"); ok = false; }
    if (s.isFresh()  != false) { logger.error("isFresh should be false on a fresh sensor");  ok = false; }
    if (s.coreTemp() != 0.0)   { logger.error("coreTemp should be 0.0, got " + s.coreTemp()); ok = false; }
    if (s.skinTemp() != 0.0)   { logger.error("skinTemp should be 0.0, got " + s.skinTemp()); ok = false; }
    return ok;
}

// Just-stamped readings are returned and reported fresh. True under both the
// 15 s and the 30 s window, so it survives #19 either way.
(:test) function test_ct_freshReturnsValue(logger) {
    var p = new CoreProbe();
    p.stamp(0, 37.42, 33.00);
    var ok = true;
    if (p.coreTemp() != 37.42) { logger.error("coreTemp " + p.coreTemp() + " != 37.42"); ok = false; }
    if (p.skinTemp() != 33.00) { logger.error("skinTemp " + p.skinTemp() + " != 33.00"); ok = false; }
    if (p.isFresh()  != true)  { logger.error("isFresh should be true immediately after a stamp"); ok = false; }
    return ok;
}

// 60 s is past BOTH the 15 s isFresh() bound and the 30 s getter bound, which is
// exactly what makes this pin epoch-invariant: a 20 s age would NOT be, and that
// divergence is #19's differential (added in c2), not a characterization pin.
(:test) function test_ct_staleReturnsZero(logger) {
    var p = new CoreProbe();
    p.stamp(60000, 37.42, 33.00);
    var ok = true;
    if (p.coreTemp() != 0.0)  { logger.error("stale coreTemp should be 0.0, got " + p.coreTemp()); ok = false; }
    if (p.skinTemp() != 0.0)  { logger.error("stale skinTemp should be 0.0, got " + p.skinTemp()); ok = false; }
    if (p.isFresh()  != false){ logger.error("stale isFresh should be false"); ok = false; }
    return ok;
}
