using Toybox.Test;

// Lifecycle tests for issue #11: onLayout allocates the 250 ms tick Timer and
// the CoreTempSensor (which owns an ANT channel) with no idempotency guard, so
// a second invocation orphans the first of each. shutdown() releases only the
// handle it can still see, so an orphaned timer keeps calling onTick for the
// rest of the app run -- which double-counts mCorrAccum and writes
// total_corrective_strokes at ~2x.
//
// SCOPE / REACHABILITY, stated rather than implied. Whether Connect IQ can
// re-invoke View.onLayout on a live view is NOT established here, in either
// direction: no simulator scenario in this repository has produced a second
// onLayout, and none has shown that it cannot happen. These tests pin the
// idempotency PROPERTY of the callback -- "calling it twice must allocate
// once" -- which is the correct contract under either answer, and which the
// tests themselves can drive by calling it twice directly.
//
// Execution note: the run-tests CI job runs these headlessly in the simulator
// on every PR (`monkeydo <prg> fr965 -t`, judged by a fail-closed parser),
// with the test names pinned in scripts/expected_tests.txt -- update that
// file in the same commit as any (:test) change here. See docs/CI.md.

// -- Stubs --------------------------------------------------------------------
// Duck-typed stand-ins for the two resources onLayout allocates. mTimer and
// mCoreSensor are untyped fields, so at runtime only duck typing applies and
// each stub needs just the members the shipping code calls on it.
//
// Substituting them is not a convenience. A real Timer.Timer started here would
// keep firing onTick inside the test process for the remainder of the run, and
// a real CoreTempSensor's ANT allocation always throws under the headless
// simulator (CoreTempSensor.mc:168-170) and drives the retry ladder -- so the
// stubs are what make onLayout reachable at all.
//
// Referenced only from (:test) functions, so both drop out of the shipping
// build -- same argument as DspProbe and FakeCoreSensor.

class LifeTimer {
    var starts;      // start() call count
    var stops;       // stop() call count
    var lastMs;      // interval of the most recent start()
    var lastRepeat;  // repeat flag of the most recent start()
    function initialize() {
        starts = 0; stops = 0; lastMs = 0; lastRepeat = false;
    }
    function start(cb, ms, repeat) {
        starts++; lastMs = ms; lastRepeat = repeat;
    }
    function stop() { stops++; }
}

class LifeCoreSensor {
    var closes;      // close() call count
    function initialize() { closes = 0; }
    function close() { closes++; }
    // Not called on any path these tests drive, but present so a future test
    // that reaches drawGps or onTick does not measure a missing-member throw
    // and call it a lifecycle defect.
    function isFresh()  { return false; }
    function everSeen() { return false; }
    function coreTemp() { return 0.0; }
    function skinTemp() { return 0.0; }
}

// -- Probe --------------------------------------------------------------------
// `hidden` in Monkey C is protected, so a subclass reads the lifecycle handles
// and overrides the allocation seams without adding anything to the shipping
// class -- the same seam DspProbe (DspTimeBaseTest.mc) and CoreProbe
// (CoreTempSensorTest.mc) use. Referenced only from (:test) functions, so it
// drops out of the shipping build.
//
// startSensor()/startGps() are neutralised, and ONLY those two: everything else
// in onLayout is the shipping code, so these tests drive the ACTUAL CALL SITE
// rather than a transcription of it -- the rule DspTimeBaseTest.mc:19-21
// states for onSensorData. Neutralising them keeps the test from registering a
// real 25 Hz sensor listener and enabling real GPS for the rest of the run;
// neither participates in #11.
//
// Every allocation is RECORDED, not just counted, because the defect is about
// WHICH instance survives, not only how many were made.

class LifeProbe extends StrongRowView {
    var madeTimers;    // every LifeTimer handed to the shipping code, in order
    var madeSensors;   // every LifeCoreSensor handed to the shipping code

    function initialize() { StrongRowView.initialize(); }

    hidden function startSensor() { }
    hidden function startGps()    { }

    hidden function makeTimer() {
        if (madeTimers == null) { madeTimers = []; }
        var t = new LifeTimer();
        madeTimers.add(t);
        return t;
    }

    hidden function makeCoreSensor() {
        if (madeSensors == null) { madeSensors = []; }
        var s = new LifeCoreSensor();
        madeSensors.add(s);
        return s;
    }

    // The two handles #11 is about. Read, never written, from the tests.
    function timerHandle()  { return mTimer; }
    function sensorHandle() { return mCoreSensor; }

    function timerCount()  { if (madeTimers  == null) { madeTimers  = []; } return madeTimers.size(); }
    function sensorCount() { if (madeSensors == null) { madeSensors = []; } return madeSensors.size(); }
    function timerAt(i)    { return madeTimers[i]; }
    function sensorAt(i)   { return madeSensors[i]; }
}

// -- Characterization pins ----------------------------------------------------
// Both are green in every epoch of this change. They pin the PRECONDITION the
// #11 guard rests on: a freshly constructed view holds neither handle, so
// `if (mTimer == null)` in onLayout is guaranteed to fire on the first call.
// Without these, a future change that allocated either resource in
// initialize() would leave the guard permanently false and silently restore
// #11's "the first onLayout does nothing" mirror image -- with no test moving.

// mTimer's null at construction is the load-bearing one, because unlike
// mCoreSensor it is NOT assigned in initialize() on today's main: it relies on
// Monkey C defaulting an unassigned member to null. shutdown() already depends
// on that (`if (mTimer != null)`), so this pins a dependency that already
// exists rather than inventing one.
(:test) function test_life_freshViewHoldsNoTimer(logger) {
    var p = new LifeProbe();
    if (p.timerHandle() != null) {
        logger.error("a freshly constructed view must hold no Timer: the #11 " +
                     "guard `if (mTimer == null)` can only fire if this holds");
        return false;
    }
    return true;
}

(:test) function test_life_freshViewHoldsNoCoreSensor(logger) {
    var p = new LifeProbe();
    if (p.sensorHandle() != null) {
        logger.error("a freshly constructed view must hold no CoreTempSensor: " +
                     "the #11 guard `if (mCoreSensor == null)` depends on it");
        return false;
    }
    return true;
}

// -- Green pins on the seam ---------------------------------------------------
// The three below are green in every epoch of this change: one onLayout has
// always made one of each, and shutdown() has always released what it holds.
// They are the anchor for the red differentials that follow -- without them, a
// "fix" that allocated NOTHING, or that nulled the handles without stopping the
// timer or closing the ANT channel, would satisfy every red case while being
// strictly worse than the defect.

// The interval and the repeat flag are pinned, not just the count. The 2x
// inflation of total_corrective_strokes is a function of tick RATE
// (mCorrAccum += cr / 240.0 assumes 250 ms), so a change to either number is
// the same class of defect as a duplicate timer and should be visible.
(:test) function test_life_onLayoutStartsTheTickTimer(logger) {
    var p = new LifeProbe();
    p.onLayout(null);

    var ok = true;
    if (p.timerCount() != 1) {
        logger.error("one onLayout must make exactly one Timer, made " + p.timerCount());
        return false;   // the reads below would be meaningless
    }
    var t = p.timerAt(0);
    if (t.starts != 1) {
        logger.error("the tick timer must be started exactly once, starts = " + t.starts);
        ok = false;
    }
    if (t.lastMs != 250) {
        logger.error("tick interval " + t.lastMs + " != 250 ms (mCorrAccum's " +
                     "cr / 240.0 assumes 250 ms ticks)");
        ok = false;
    }
    if (t.lastRepeat != true) {
        logger.error("the tick timer must repeat");
        ok = false;
    }
    if (p.timerHandle() != t) {
        logger.error("the view must hold the timer it just made");
        ok = false;
    }
    return ok;
}

(:test) function test_life_onLayoutCreatesTheCoreSensor(logger) {
    var p = new LifeProbe();
    p.onLayout(null);

    var ok = true;
    if (p.sensorCount() != 1) {
        logger.error("one onLayout must make exactly one CoreTempSensor, made " +
                     p.sensorCount());
        return false;
    }
    if (p.sensorHandle() != p.sensorAt(0)) {
        logger.error("the view must hold the sensor it just made");
        ok = false;
    }
    return ok;
}

// RELEASE, as distinct from clearing the handle. This asserts on the recorded
// stubs rather than on mTimer/mCoreSensor precisely so it stays green when the
// fix starts nulling those fields -- and so it reds if a future change nulls
// them WITHOUT stopping the timer and closing the ANT channel, which would
// orphan both permanently instead of only on a repeat onLayout.
(:test) function test_life_shutdownReleasesTheLiveResources(logger) {
    var p = new LifeProbe();
    p.onLayout(null);
    var t = p.timerAt(0);
    var s = p.sensorAt(0);
    p.shutdown();

    var ok = true;
    if (t.stops < 1) {
        logger.error("shutdown must stop the tick timer, stops = " + t.stops);
        ok = false;
    }
    if (s.closes < 1) {
        logger.error("shutdown must close the CORE sensor (it owns an ANT " +
                     "channel), closes = " + s.closes);
        ok = false;
    }
    return ok;
}
