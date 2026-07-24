using Toybox.Test;

// Regression tests for issue #8: the DSP time base must be a function of the
// configured sample RATE (REQ_RATE), never of an accelerometer batch's SIZE.
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
// Execution note: the runner-free CI compiles these across all 12 devices but
// does NOT run them (no headless-sim job -- see docs/CI.md). Run locally with
// `monkeydo <prg> <device> -t`.

// -- Stubs -------------------------------------------------------------------
// Duck-typed stand-ins for Sensor.SensorData / AccelerometerData. onSensorData
// is declared `(sensorData as Sensor.SensorData)`, but Monkey C only enforces
// that under a typecheck level, and this codebase compiles untyped (no -l), so
// a structurally compatible object is accepted.

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

    shortBatch.onSensorData(new FakeSensorData(3));
    fullBatch.onSensorData(new FakeSensorData(25));

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
    p.onSensorData(new FakeSensorData(3));

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
