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

// -- Probe --------------------------------------------------------------------
// `hidden` in Monkey C is protected, so a subclass reads the lifecycle handles
// without adding any accessor to the shipping class -- the same seam DspProbe
// (DspTimeBaseTest.mc) and CoreProbe (CoreTempSensorTest.mc) use. Referenced
// only from (:test) functions, so it drops out of the shipping build.

class LifeProbe extends StrongRowView {
    function initialize() { StrongRowView.initialize(); }

    // The two handles #11 is about. Read, never written, from the tests.
    function timerHandle()  { return mTimer; }
    function sensorHandle() { return mCoreSensor; }
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
