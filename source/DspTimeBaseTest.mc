using Toybox.Test;
using Toybox.Sensor;

// Regression tests for two defects on the onSensorData path.
//
// #8: the DSP time base must be a function of the configured sample RATE
// (REQ_RATE), never of an accelerometer batch's SIZE.
//
// #20: onSensorData null-checked only accel.x while dereferencing accel.y/.z and
// sizing the loop from xs.size(). See the "#20" section at the bottom of this
// file; it reuses the stubs and the probe declared here.
//
// The original defect was `computeCoeffs(n)` in onSensorData, where n = the first
// batch's sample count. A short first batch (CIQ does not guarantee the first
// callback is full) permanently rescaled the synthetic clock `mSampleIdx * mDt`,
// so every stroke period, the QUIET_S boot gate, the refractory window and the
// autocorrelation ran on a wrong time base for the whole session.
//
// These tests drive the ACTUAL CALL SITE (onSensorData) rather than the timing
// arithmetic, because the bug was a wrong-argument bug: a test of the arithmetic
// alone passes just as happily with computeCoeffs(n) still in place.
//
// Execution note: the run-tests CI job runs these headlessly in the simulator
// on every PR (`monkeydo <prg> fr965 -t`, judged by a fail-closed parser),
// with the test names pinned in scripts/expected_tests.txt -- update that
// file in the same commit as any (:test) change here. See docs/CI.md.

// -- Stubs -------------------------------------------------------------------
// Duck-typed stand-ins for Sensor.SensorData / AccelerometerData.
//
// onSensorData is declared `(sensorData as Sensor.SensorData)`, and monkeyc
// enforces that parameter type EVEN WITH NO -l typecheck level -- passing a
// structurally compatible object is rejected with
// "Invalid '$.FakeSensorData' passed as parameter 1". So each call site casts
// the stub with `as Sensor.SensorData`. The cast is erased at runtime, where
// only duck typing applies, so the stub just needs the members onSensorData
// actually reads: accelerometerData.x/.y/.z (and heartRateData, below).

class FakeAccel {
    var x; var y; var z;
    function initialize(n) {
        x = new [n]; y = new [n]; z = new [n];
        for (var i = 0; i < n; i++) { x[i] = 0; y[i] = 0; z[i] = 0; }
    }
}

class FakeSensorData {
    var accelerometerData;
    // Explicitly present and null. onSensorData's HR branch short-circuits on
    // mRrOk (false until startSensor runs), so this is not strictly required
    // today -- but relying on that ordering is a trap if the condition is ever
    // reordered, so the stub carries the member.
    var heartRateData;
    function initialize(n) {
        accelerometerData = new FakeAccel(n);
        heartRateData = null;
    }
}

// -- Probe -------------------------------------------------------------------
// `hidden` in Monkey C is protected, so a subclass can read the DSP state
// without adding any accessor to the shipping class. This probe is referenced
// only from (:test) functions, so it drops out of the release build.

class DspProbe extends StrongRowView {
    function initialize() { StrongRowView.initialize(); }
    function dt()    { return mDt; }
    function decim() { return mDecim; }
    // #20: the synthetic clock's sample counter. resetDetector() zeroes it, so a
    // fresh probe reads 0 and every processed sample adds exactly one.
    function sampleIdx() { return mSampleIdx; }
}

function dspAlmostEq(a, b) {
    var d = a - b;
    if (d < 0) { d = -d; }
    return d < 0.000001;
}

// -- Tests -------------------------------------------------------------------

// THE load-bearing regression test: the time base must be INVARIANT to batch
// size. Feeding a stubby 3-sample first batch and a full 25-sample first batch
// must produce an identical time base.
//
// RED on the old code: the 3-sample probe latched mDt = 1/3 (~0.333) and
// mDecim = 1, while the 25-sample probe latched 0.04 / 5 -- so they differed.
// GREEN now: both are fixed at init from REQ_RATE and never touched again.
//
// Phrased as an invariance check (rather than pinning numbers) so it keeps
// guarding this bug even if REQ_RATE is legitimately retuned some day.
(:test) function test_dsp_timeBaseInvariantToBatchSize(logger) {
    var shortBatch = new DspProbe();
    var fullBatch  = new DspProbe();

    shortBatch.onSensorData(new FakeSensorData(3) as Sensor.SensorData);
    fullBatch.onSensorData(new FakeSensorData(25) as Sensor.SensorData);

    var ok = true;
    if (!dspAlmostEq(shortBatch.dt(), fullBatch.dt())) {
        logger.error("mDt depends on batch size: n=3 -> " + shortBatch.dt() +
                     " vs n=25 -> " + fullBatch.dt());
        ok = false;
    }
    if (shortBatch.decim() != fullBatch.decim()) {
        logger.error("mDecim depends on batch size: n=3 -> " + shortBatch.decim() +
                     " vs n=25 -> " + fullBatch.decim());
        ok = false;
    }
    return ok;
}

// Separately pin the PHYSICAL time base, so an accidental REQ_RATE change is
// visible rather than silently self-consistent (same split as
// test_rr_freshConstUnchanged). mDt is the load-bearing value here: it scales
// every stroke period. Tolerance rather than == because these are floats.
(:test) function test_dsp_timeBaseIs25Hz(logger) {
    var p = new DspProbe();
    p.onSensorData(new FakeSensorData(3) as Sensor.SensorData);

    var ok = true;
    if (!dspAlmostEq(p.dt(), 0.04)) {
        logger.error("mDt " + p.dt() + " != 0.04 (25 Hz)");
        ok = false;
    }
    if (p.decim() != 5) {
        logger.error("mDecim " + p.decim() + " != 5 (25 Hz / AC_HZ 5)");
        ok = false;
    }
    return ok;
}

// The time base must be established by initialize(), before any sensor data
// arrives -- it is no longer computed lazily on the first batch.
(:test) function test_dsp_timeBaseSetAtInit(logger) {
    var p = new DspProbe();   // no onSensorData call at all
    if (!dspAlmostEq(p.dt(), 0.04)) {
        logger.error("mDt not established at init: " + p.dt());
        return false;
    }
    return true;
}

// == #20: accelerometer batch guards =========================================
//
// onSensorData binds all three axis arrays but guards only `xs`, and bounds the
// loop with `xs.size()`, so a null or SHORT `y`/`z` is dereferenced unguarded.
// The accepted fix DROPS the batch (requires all three non-null, and `ys`/`zs`
// at least as long as `xs`) rather than clamping to the common prefix, so every
// malformed input below must leave mSampleIdx at 0 -- the same accounting the
// three guards already ahead of the loop use.
//
// Two test-shape rules these depend on:
//
//  * ACCUMULATE, don't early-return. Each test records BOTH whether the call
//    threw AND what the clock reads, because the two are independent reasons to
//    be red and a `catch { return false; }` would never reach the second. On
//    unmodified main a throwing input stops the loop where it throws; if it
//    turned out NOT to throw, the loop would run to completion and leave 25 --
//    so the value assertion reds the same tests by a different route.
//  * ZERO-FILL every array. `new [n]` is NULL-filled in Monkey C (which is why
//    FakeAccel loops to zero-fill after allocating), and a null element throws
//    in `xs[i].toFloat()` BEFORE any guard under test is reached -- measuring
//    the wrong defect.
//
// Which reds carry which evidence is recorded per test below: two are carried
// by both the throw and the value, three by the throw alone.

// Zero-filled array of length n. See the ZERO-FILL rule above.
function dspZeros(n) {
    var a = new [n];
    for (var i = 0; i < n; i++) { a[i] = 0; }
    return a;
}

// Well-formed batch: the fix must not touch the path that already works. This is
// the anchor for every "== 0" below -- without it, a fix that dropped EVERY
// batch would satisfy all five red tests.
(:test) function test_dsp_accelEqualSizeAdvancesClock(logger) {
    var p = new DspProbe();
    var ok = true;
    try {
        p.onSensorData(new FakeSensorData(25) as Sensor.SensorData);
    } catch (e) {
        logger.error("threw on a well-formed 25-sample batch");
        ok = false;
    }
    if (p.sampleIdx() != 25) {
        logger.error("well-formed batch must advance the clock by 25, got " + p.sampleIdx());
        ok = false;
    }
    return ok;
}

// y/z LONGER than x is not ragged in the dangerous direction: every index the
// loop reads exists. Today's behaviour is to ignore the surplus tail, and the
// fix keeps it -- this is what distinguishes the accepted `<` guard from an
// `!=` guard, which would drop this batch and read 0.
(:test) function test_dsp_accelLongerYZIgnoresExtra(logger) {
    var p = new DspProbe();
    var sd = new FakeSensorData(25);
    sd.accelerometerData.y = dspZeros(40);
    sd.accelerometerData.z = dspZeros(40);
    var ok = true;
    try {
        p.onSensorData(sd as Sensor.SensorData);
    } catch (e) {
        logger.error("threw on x=25 with longer y/z");
        ok = false;
    }
    if (p.sampleIdx() != 25) {
        logger.error("longer y/z must still process 25 and ignore the tail, got " + p.sampleIdx());
        ok = false;
    }
    return ok;
}

// GREEN on main: `if (xs == null) { return; }` already covers this. It is pinned
// because the fix REWRITES that line, and without this case the mutant
// `if (ys == null || zs == null)` -- dropping the xs half -- passes every other
// test here and then throws on `xs.size()`, which is the same crash class #20 is
// about.
(:test) function test_dsp_accelNullXDropsBatch(logger) {
    var p = new DspProbe();
    var sd = new FakeSensorData(25);
    sd.accelerometerData.x = null;
    var ok = true;
    try {
        p.onSensorData(sd as Sensor.SensorData);
    } catch (e) {
        logger.error("threw on a null x axis");
        ok = false;
    }
    if (p.sampleIdx() != 0) {
        logger.error("null x must consume no samples, got " + p.sampleIdx());
        ok = false;
    }
    return ok;
}
