using Toybox.Test;
using Toybox.Sensor;
using Toybox.Lang;
using Toybox.Math;

// Suite for the STROKE-RATE LOCK GUARD -- the last decision the detector makes
// before a rate reaches the screen, the FIT file and everything derived from
// either.
//
// WHAT THE GUARD IS. outputRate() takes the detector's median rate and:
//   * if the autocorrelation lock is UP, snaps a reading that disagrees with
//     the lock by more than LOCK_SNAP_K to the lock;
//   * if the lock is DOWN, ZEROES a reading above a threshold, on the argument
//     that a fast reading nothing independent corroborates is a phantom burst
//     from non-rowing hand motion;
//   * clamps whatever survives to MAX_RATE.
//
// WHAT #149 FOUND WRONG WITH IT, and it is only the middle clause: that
// threshold was the ABSOLUTE constant FAST_NEEDS_LOCK = 30.0 spm, while the
// error it defends against -- a doubled stroke period -- is RELATIVE to the
// athlete. Measured on the two recorded rows (#149, second maintainer comment):
//
//     row            baseline    30.0 in units of this rower's own rate
//     calm 4x15'     20.3 spm    1.48x
//     choppy 8x3'    15.2 spm    1.98x
//
// So a 20 spm rower was guarded at 1.5x and a 15 spm rower only past a full
// doubling -- the weakest protection went to the low-rate work this app exists
// for. That is the defect this suite pins, and the cases below state the bar in
// exactly the three parts #149 asks for: never looser than 30.0 at any rate;
// the same MULTIPLE for a 15 spm rower that a 20 spm rower already had; and a
// guard that still exists before any rate is established.
//
// THIS SUITE CANNOT SEE THE WATER. Every number above came from decoded
// recordings, not from anything in this process. What these cases observe is
// the DECISION -- which rate the shipping code returns for a stated detector
// state. Whether that decision improves a real row is a question for a recorded
// session, and no case here claims it.
//
// -- WHY EVERYTHING LIVES IN ONE MODULE ---------------------------------------
// The fenix6 family caps module `globals` at 253 members and monkeyc prints the
// count only once the build is already over. A file-scope (:test), helper
// function or class costs one member each; a `module { }` block costs ONE for
// everything inside it, and a module-scope `const` costs none (it is inlined).
// The measurement and its consequence are recorded at the top of
// scripts/list_tests.py and source/FootStateTest.mc.
//
// So EVERYTHING here -- fixtures and (:test) functions alike -- is inside
// `module Lock`. The simulator prints such a test as `Lock.test_...` and
// scripts/list_tests.py extracts that qualified name, so scripts/expected_tests.txt
// pins the qualified form.
//
// -- COMMIT PARTITION ---------------------------------------------------------
//   c0   characterization pins on existing symbols only; no source change
//   c1   the pure seam + the baseline plumbing, wired behaviour-preservingly
//   c2   the differentials -- RED against c1, by design
//   c3   the fix; touches no test file, no pin, no scripts/, no .github/
//   c4   the lock-state diagnostic symbols, wired behaviour-preservingly
//   c5   the diagnostic differentials -- RED against c4, by design
//   c6   the diagnostic fields and their writes
//   c9   the GATE-INPUT encodings + plumbing, wired behaviour-preservingly
//   c10  the gate-input differentials -- RED against c9, by design
//   c11  the gate-input fields (ids 23-24) and their writes
//
// Execution note: the run-tests CI job runs these headlessly in the simulator on
// fr965. Test names are pinned in scripts/expected_tests.txt -- update that file
// in the SAME commit as any (:test) change here. See docs/CI.md.

// -- Fixture ------------------------------------------------------------------
// One module, one member of `globals`. See the ceiling note above.
module Lock {

    // A WRITEABLE stand-in for Sensor.AccelerometerData / SensorData.
    //
    // DspTimeBaseTest's FakeAccel is reused everywhere a batch of ZEROES is
    // wanted (Probe.feedQuiet), and is not widened here: its whole contract is
    // "n samples of zero", three suites rely on that, and a constructor that
    // sometimes carries a waveform is a stub that can drift into two things.
    // These two are the same shape with mutable arrays, and they live inside
    // `module Lock` so they cost no `globals` member.
    class WaveAccel {
        var x; var y; var z;
        function initialize(n) {
            x = new [n]; y = new [n]; z = new [n];
            for (var i = 0; i < n; i++) { x[i] = 0; y[i] = 0; z[i] = 0; }
        }
    }

    class WaveData {
        var accelerometerData;
        var heartRateData;
        function initialize(n) {
            accelerometerData = new WaveAccel(n);
            heartRateData = null;
        }
    }

    // Drives the detector's two output-stage inputs directly.
    //
    // Extends HrProbe (HrArcTest.mc) rather than re-deriving from
    // StrongRowView: the neutralised sensor and GPS starts, the injected clock
    // and the deterministic speed/distance already exist there and are already
    // exercised by three suites. A second copy would be free to drift.
    //
    // DIRECT rather than through driveStrokes(): outputRate()'s decision is a
    // function of (median rate, lock period) and these cases need to visit
    // pairs the stroke ring cannot be steered to -- a 25 spm median against no
    // lock is precisely the state under test and cannot be produced by feeding
    // a steady cadence in.
    //
    // Every assertion still reads the answer back through the SHIPPING
    // outputRate(). Nothing here re-implements the decision.
    class Probe extends HrProbe {
        function initialize() { HrProbe.initialize(); }

        function setDetector(spm, acPeriod) {
            mRate     = spm;
            mAcPeriod = acPeriod;
        }

        // The established-rate baseline. Written for the sweep that proves the
        // static and the method agree; READ everywhere else, because the point
        // of rowAt() below is that the shipping code establishes it.
        function setRateBase(b) { mRateBase = b; }
        function rateBase()     { return mRateBase; }

        // The shipping decision, called -- not transcribed.
        function out() { return outputRate(); }

        // Quiet accelerometer batches through the SHIPPING onSensorData, which
        // is the only place the stroke-ring timeout lives. Each batch is
        // `n` samples of zero, so no stroke is detected and the synthetic clock
        // `mSampleIdx * mDt` simply advances.
        //
        // FakeSensorData is DspTimeBaseTest.mc's stub, reused rather than
        // copied: a second stand-in for the same platform type is a second
        // thing that can drift from it. The cast is required -- monkeyc
        // enforces onSensorData's declared parameter type with no -l level --
        // and is erased at runtime, where only duck typing applies.
        function feedQuiet(batches, n) {
            for (var i = 0; i < batches; i++) {
                onSensorData(new FakeSensorData(n) as Sensor.SensorData);
            }
        }

        // -- #149's lock-state diagnostics --------------------------------
        // The three estimator fields the diagnostic write reports, driven
        // directly so a case can visit lock states the estimator cannot be
        // steered to on demand -- "locked at exactly 20.0 spm with a
        // confidence of 0.42" is not a state a synthetic signal produces.
        function setLockState(acPeriod, conf, lowConf) {
            mAcPeriod  = acPeriod;
            mAcConf    = conf;
            mAcLowConf = lowConf;
        }

        function lockConfState()   { return mAcConf; }
        function lockPeriodState() { return mAcPeriod; }
        function lockLowState()    { return mAcLowConf; }
        function dtState()         { return mDt; }

        // #149 part 2: the PRE-GATE median, read straight off the detector.
        // rateBase() above is its companion. Both are READ-ONLY views for the
        // cases that establish state through the shipping registerStroke, which
        // is the whole point of driving a rate rather than assigning one.
        function rawRate() { return mRate; }

        // The estimator's own unlock threshold. A class `hidden const` is an
        // INSTANCE member, so a (:test) free function cannot name it; exposing
        // it here rather than transcribing 0.35 into an assertion keeps the pin
        // keyed to the constant the shipping gate actually reads.
        function acMinConf() { return AC_MIN_CONF; }

        // NON-ZERO accelerometer batches through the SHIPPING onSensorData.
        //
        // feedQuiet above can only ever reach updateAutocorr's zero-energy
        // early return, so nothing in this file used to reach the estimator's
        // MAIN path at all -- which is how a fabricated mAcConf survived the
        // whole suite. `samples` is a flat array of x-axis values, cut into
        // batches of `chunk`; y and z stay at zero so the dominant-axis chooser
        // cannot move off x mid-run.
        function feedWave(samples, chunk) {
            var i = 0;
            while (i < samples.size()) {
                var n = chunk;
                if (i + n > samples.size()) { n = samples.size() - i; }
                var d = new WaveData(n);
                for (var k = 0; k < n; k++) { d.accelerometerData.x[k] = samples[i + k]; }
                onSensorData(d as Sensor.SensorData);
                i += n;
            }
        }

        // Recording stand-ins for the three record-scope handles.
        function installLockFields(rateF, confF, lowF) {
            mFitLockRate = rateF;
            mFitLockConf = confF;
            mFitLockLow  = lowF;
        }

        // #149 part 2: the two gate-input handles.
        function installRateFields(rawF, baseF) {
            mFitRateRaw  = rawF;
            mFitRateBase = baseF;
        }

        // row_stroke_rate itself -- the field these two exist to be read
        // ALONGSIDE. Installed so a case can compare the gate's recorded INPUT
        // against the gate's recorded OUTPUT as two arguments of two shipping
        // setData calls in the same tick, rather than against outputRate()
        // called a second time from the case.
        function installOutField(rateF) { mFitRate = rateF; }

        // The real 250 ms tick, called directly.
        function runTick() { onTick(); }

        // Real strokes at a chosen cadence, through the SHIPPING
        // registerStroke() / recomputeRate() path, so whatever the detector
        // establishes from a steady row is established by the shipping code
        // and not assigned here.
        //
        // `spm` must lie inside registerStroke's accepted period band
        // [60/MAX_RATE, 60/MIN_RATE] = [1.5 s, 10 s], i.e. 6..40 spm, or the
        // periods are rejected and nothing is established at all.
        function rowAt(spm, strokes) { rowFrom(spm, strokes, 0.0); }

        // The same, on a CONTINUING clock, returning the time one period past
        // the last stroke so the next leg can start there.
        //
        // rowAt() restarts at t = 0.0, and a second rowAt() on the same probe
        // therefore hands registerStroke a NEGATIVE period, which it drops --
        // so a case that drives a row, a pause and a resume as three rowAt()
        // calls silently loses the first stroke of each later leg. Every case
        // with more than one leg uses this instead.
        // -- D3: the pre-START carry-over ---------------------------------
        // READ-ONLY views of the stroke-period ring, so a case can assert that
        // a recording start left NOTHING behind rather than inferring it from
        // the rate alone. mRate can be 0.0 with a full ring (every period
        // rejected) and non-zero with one entry, so the two are separate
        // questions and get separate accessors.
        function ringCount()   { return mPCount; }
        function ringIdx()     { return mPIdx; }
        function lastStrokeT() { return mLastStrokeT; }
        function lastPeriod()  { return mLastPeriod; }
        function baseHold()    { return mBaseHold; }

        // The reset seam, called -- not transcribed.
        function resetBaseline() { resetStrokeBaseline(); }

        // The function every recording-start path calls, called directly. This
        // is the reachable half of the START boundary: startSession() itself
        // cannot run in process (it calls Rec.createSession), which is why
        // source/CoreFieldGateTest.mc:10 says so and why check_step_fields.py
        // is a static check.
        function beginAccum() { beginSessionAccum(); }

        // startSession() NEUTRALISED, exactly as HrProbe neutralises
        // startSensor() and startGps(), so the REAL startWorkout() can be
        // driven end to end. Returns true because both callers read the return
        // as "a session exists and start() did not throw" and then proceed;
        // returning false would make startWorkout() bail before it reached
        // anything worth asserting on.
        //
        // THIS IS WHY THE RESET IS NOT INSIDE startSession(): a probe that
        // stubs startSession stubs the reset with it, and the wiring would be
        // pinned by nothing.
        hidden function startSession() { return true; }

        // The REAL workout start, through the shipping startWorkout().
        function startWorkoutLive() { startWorkout(); }

        // Did it actually start? Read so a case can tell "the estimator is
        // empty because the reset ran" from "the estimator is empty because
        // startWorkout bailed before doing anything".
        function isStarted() { return mStarted; }

        function rowFrom(spm, strokes, t0) {
            var per = 60.0 / spm;
            var t = t0;
            for (var i = 0; i < strokes; i++) {
                registerStroke(t);
                t += per;
            }
            return t;
        }
    }

    // A probe in a live, unpaused WORK step with the three diagnostic fields
    // installed, which is the state onTick's FIT writes are gated on
    // (mStarted && !mPaused).
    //
    // enterStepLive (not enterStep) leaves the step clock running, so
    // stepRemaining() is the full interval and onTick's advanceStep() is not
    // triggered -- these cases must not advance the workout underneath
    // themselves.
    function tickProbe(fields) {
        var p = new Probe();
        p.enterStepLive(p.kindWork(), false);
        p.setSpeed(0.0);
        p.setDist(0.0);
        p.installLockFields(fields[0], fields[1], fields[2]);
        // #149 part 2. Installed for EVERY tickProbe, not only for the cases
        // that read them: a probe whose field set depends on which case built
        // it is two probes, and the cases that ignore slots 3-5 are unaffected
        // by a write they never look at.
        p.installRateFields(fields[3], fields[4]);
        p.installOutField(fields[5]);
        return p;
    }

    // Six recording fields, in the order tickProbe installs them:
    //
    //   0  lock_rate         1  lock_confidence    2  lock_lowconf_run
    //   3  rate_raw          4  rate_base          5  row_stroke_rate
    //
    // Slots 0-2 are #149's lock state; 3-4 are part 2's gate inputs; 5 is the
    // shipping output field the pair exists to be read alongside.
    //
    // CueFix.Field (CueZoneTest.mc) is REUSED rather than copied: a second
    // stand-in for the same platform type is a second thing that can drift from
    // it, which is the same argument Lock.Probe makes for extending HrProbe and
    // feedQuiet makes for reusing FakeSensorData.
    //
    // SCOPE, stated because it is precisely the claim this repository keeps
    // overreaching on: a Field observes the ARGUMENT of an in-app call. It says
    // nothing about what lands in the file's bytes and nothing about what a
    // decoder renders. Those need a simulator session and a decode.
    function fields() {
        return [new CueFix.Field(), new CueFix.Field(), new CueFix.Field(),
                new CueFix.Field(), new CueFix.Field(), new CueFix.Field()];
    }

    // A probe with the detector at (spm, lock period) and nothing else
    // established -- a fresh view, so no rate history exists.
    function at(spm, acPeriod) {
        var p = new Probe();
        p.setDetector(spm, acPeriod);
        return p;
    }

    // -- waveforms for the estimator's MAIN path --------------------------
    // Both are functions of the SAMPLE INDEX and a fixed seed. Never
    // System.getTimer(): a case that synthesises a signal from it passes on an
    // hours-old desktop simulator and reds on CI's seconds-old one, which this
    // repository has shipped once.

    // A clean stroke cycle at `spm`, sampled at the accelerometer step the app
    // configured. Amplitude is well over MIN_THR so the peak detector arms.
    function sineWave(spm, n, dt, amp) {
        var out = new [n];
        var w = 2.0 * Math.PI / (60.0 / spm);
        for (var i = 0; i < n; i++) {
            out[i] = (amp * Math.sin(w * i * dt)).toNumber();
        }
        return out;
    }

    // The same energy with no period the estimator can find. Lehmer generator,
    // multiplier 75 and modulus 65537, chosen so every intermediate stays under
    // 5e6 and cannot overflow a 32-bit Number -- the arithmetic is the point,
    // not the statistics.
    function noiseWave(n, amp, seed) {
        var out = new [n];
        var s = seed;
        for (var i = 0; i < n; i++) {
            s = (s * 75 + 74) % 65537;
            out[i] = (s % (2 * amp + 1)) - amp;
        }
        return out;
    }

    // Float comparison with a tolerance well under a tenth of a spm, which is
    // the finest distinction the display draws. An exact == would make these
    // cases hostage to the last bit of a division.
    function near(a, b) {
        if (a == null || b == null) { return false; }
        var d = a - b;
        if (d < 0.0) { d = -d; }
        return d < 0.0005;
    }

// -- c0: characterization pins ------------------------------------------------
// GREEN IN EVERY EPOCH of this change, and each one says why it survives the
// change that is coming.
//
// Every case here builds a FRESH probe, so no rate is established. That is what
// makes them epoch-invariant: #149's rule falls back to the absolute constant
// exactly when there is no established rate to be relative to, so a fresh view
// answers identically before and after.

// THE ABSOLUTE GATE, at its boundary. The comparison is strict (`r > gate`), so
// a reading EXACTLY at the gate passes -- pinned at both sides of it because
// "somewhere near thirty" is not a threshold.
(:test) function test_lock_c0_theAbsoluteGateIsThirtyWithNoRateEstablished(logger) {
    var cases = [[29.9, 29.9], [30.0, 30.0], [30.1, 0.0], [45.0, 0.0]];
    for (var i = 0; i < cases.size(); i++) {
        var p = Lock.at(cases[i][0], 0.0);
        var got = p.out();
        if (!Lock.near(got, cases[i][1])) {
            logger.error("with no autocorrelation lock and no established " +
                         "rate, a median of " + cases[i][0] + " spm must come " +
                         "out as " + cases[i][1] + "; got " + got);
            return false;
        }
    }
    return true;
}

// THE SNAP. Untouched by #149 -- the relative rule replaces the NO-LOCK branch
// only -- so this is a pin on the half that must not move.
(:test) function test_lock_c0_aLockedReadingSnapsOnlyWhenItDisagrees(logger) {
    // 3.0 s period is a 20.0 spm lock; LOCK_SNAP_K = 0.30 puts the snap
    // threshold at a 6.0 spm deviation, so 25.9 is inside it and 26.1 is not.
    var cases = [[20.0, 20.0], [25.9, 25.9], [26.1, 20.0], [14.1, 14.1],
                 [13.9, 20.0], [38.0, 20.0]];
    for (var i = 0; i < cases.size(); i++) {
        var p = Lock.at(cases[i][0], 3.0);
        var got = p.out();
        if (!Lock.near(got, cases[i][1])) {
            logger.error("against a 20.0 spm lock (period 3.0 s), a median of " +
                         cases[i][0] + " spm must come out as " +
                         cases[i][1] + "; got " + got);
            return false;
        }
    }

    // A zero median is the NO-DATA state and the snap must not invent a rate
    // from the lock for it. outputRate() returning a genuine 0.0 when nothing
    // has been measured is the premise rateColour's `rate > 0.0` guard rests
    // on, and drawRate renders it as "--.-".
    var pz = Lock.at(0.0, 3.0);
    if (!Lock.near(pz.out(), 0.0)) {
        logger.error("a zero median against a live lock must stay 0.0 -- the " +
                     "no-data state must never be filled in from the lock; " +
                     "got " + pz.out());
        return false;
    }
    return true;
}

// THE MAX_RATE CLAMP. Reached only through the LOCK branch: with no lock,
// anything over MAX_RATE is over the absolute gate too and is zeroed before the
// clamp can see it. Pinned because #149 requires the clamp to survive the
// change, and a case that never reaches it would not notice its removal.
(:test) function test_lock_c0_theSurvivingRateIsClampedToFortySpm(logger) {
    // A 1.5 s lock is 40.0 spm, the fastest the estimator can lock to. A 45.0
    // median deviates by 5.0, inside the 12.0 spm snap threshold, so it is NOT
    // snapped -- and must then be clamped.
    var p = Lock.at(45.0, 1.5);
    if (!Lock.near(p.out(), 40.0)) {
        logger.error("a 45.0 spm median that the lock declines to snap must " +
                     "still be clamped to MAX_RATE (40.0); got " + p.out() +
                     ". The clamp is the last line of outputRate and nothing " +
                     "else bounds what reaches row_stroke_rate");
        return false;
    }

    // The mirror, so the clamp is pinned as a CEILING and not as a constant:
    // a reading under it passes through untouched.
    var q = Lock.at(39.0, 1.5);
    if (!Lock.near(q.out(), 39.0)) {
        logger.error("39.0 spm is under MAX_RATE and must pass through " +
                     "unchanged; got " + q.out());
        return false;
    }
    return true;
}
// THE SNAP ACROSS A HARMONIC OR SUBHARMONIC LOCK, as shipped (#193).
//
// CHARACTERIZATION ONLY. Every triple below is read off recording i183553852
// (3385 records, 2026-09-05) and is replayed by scripts/lock_snap_replay.py
// from scripts/fixtures/lock_snap_records.txt, so the two sides of the
// transcription assert the same vectors -- the pairing scripts/cue_replay.py
// and source/CueZoneTest.mc already keep, for the reason stated there.
//
// This case asserts what `gatedRate` DOES today, not what it should do. The
// autocorrelation of a stroke signal peaks at integer multiples and divisors of
// the true period, so a lock can sit on a harmonic or a subharmonic; the snap
// has no plausibility bound, so it substitutes the lock anyway and CREATES the
// half/double read it exists to kill. #193's fix retires this case and replaces
// it with the two c2 differentials, which is why the substitution is pinned
// here first: without it the c2 red does not say which behaviour moved.
(:test) function test_lock_c0_theSnapSubstitutesAHarmonicLockAtRatioTwoAndThree(logger) {
    // [median spm, lock period s, what gatedRate returns TODAY, what it is]
    //
    // 9.4 s is a 6.383 spm lock against an 18.52 spm median -- a ratio of
    // 2.901, the near-3:1 SUBHARMONIC the rower saw at records 2489-2499 while
    // the median never moved. 1.8 s is a 33.333 spm lock against a 10.42 spm
    // median -- a ratio of 3.200, the near-3:1 HARMONIC at records 2503-2505.
    var cases = [[18.518518, 9.4, 60.0 / 9.4], [10.416667, 1.8, 60.0 / 1.8],
                 [39.0, 3.0, 20.0], [10.0, 3.0, 20.0]];
    for (var i = 0; i < cases.size(); i++) {
        var p = Lock.at(cases[i][0], cases[i][1]);
        if (!Lock.near(p.out(), cases[i][2])) {
            logger.error("as shipped, a median of " + cases[i][0] +
                         " spm against a " + cases[i][1] + " s lock (" +
                         (60.0 / cases[i][1]) + " spm) must come out as " +
                         cases[i][2] + "; got " + p.out());
            return false;
        }
    }
    return true;
}

// A DISAGREEMENT THAT IS NOT A HARMONIC STILL SNAPS -- green in EVERY epoch.
//
// The guard #193 adds refuses the snap only at a near-2:1 or near-3:1 ratio.
// This case is the other half of that statement and it is the one that keeps
// the fix from being "delete the snap": each pair below is a disagreement the
// snap must still resolve in the lock's favour, before and after.
//
// The 28.0-against-20.0 pair is #10's worked example (a legitimate surge the
// snap wrongly pins to the lagging lock). Its ratio is 1.40, outside both
// bands, so #193 leaves #10 exactly where it is rather than half-fixing it --
// pinned here so that claim is checked rather than asserted in prose.
(:test) function test_lock_c0_aNonHarmonicDisagreementSnapsInEveryEpoch(logger) {
    // [median spm, lock period s, expected out, ratio for the message]
    var cases = [[28.0, 3.0, 20.0], [26.1, 3.0, 20.0], [13.9, 3.0, 20.0],
                 [34.0, 3.0, 20.0], [10.416667, 9.4, 60.0 / 9.4]];
    for (var i = 0; i < cases.size(); i++) {
        var p = Lock.at(cases[i][0], cases[i][1]);
        if (!Lock.near(p.out(), cases[i][2])) {
            logger.error("a median of " + cases[i][0] + " spm against a " +
                         cases[i][1] + " s lock disagrees by more than " +
                         $.LOCK_SNAP_K + " of the lock at a ratio that is " +
                         "NOT near 2:1 or 3:1, so it must snap to " +
                         cases[i][2] + " in every epoch; got " + p.out());
            return false;
        }
    }
    return true;
}

// -- c1: the new symbols, pinned where they are epoch-invariant ---------------
//
// c1 introduces fastGate / gatedRate / nextRateBase and the mRateBase plumbing,
// and wires outputRate() to the new static. That wiring is BEHAVIOUR-PRESERVING
// by construction: fastGate still returns the absolute constant and ignores its
// argument, so nothing the c0 cases assert moves.
//
// Every case below is GREEN at c1 and STAYS GREEN once the relative rule lands
// at c3. They pin the parts that do not move: that the static IS the shipping
// decision rather than a copy of it, that the guard is never LOOSENED at any
// rate, that "no rate established" still means "guarded", and what the baseline
// does and does not fold in.

// THE SEAM IS THE SHIPPING DECISION, NOT A TRANSCRIPTION OF IT.
//
// This is the load-bearing case of the whole suite and it exists because of a
// defect class this repository has shipped twice: a test that RE-IMPLEMENTS the
// logic it is meant to guard pins nothing at all. Every other case here calls
// the pure static, which is only worth doing while the static and the method
// answer identically -- so that identity is swept rather than assumed.
(:test) function test_lock_theSeamAnswersExactlyAsTheShippingMethod(logger) {
    var raws  = [0.0, 6.0, 14.0, 17.0, 20.0, 25.0, 29.9, 30.0, 30.1, 45.0];
    var locks = [0.0, 1.5, 3.0, 4.0];
    var bases = [0.0, 8.0, 15.0, 20.0, 30.0];
    for (var i = 0; i < raws.size(); i++) {
        for (var j = 0; j < locks.size(); j++) {
            for (var k = 0; k < bases.size(); k++) {
                var p = new Lock.Probe();
                p.setDetector(raws[i], locks[j]);
                p.setRateBase(bases[k]);
                var viaMethod = p.out();
                var viaStatic = StrongRowView.gatedRate(raws[i], locks[j],
                                                        bases[k]);
                if (!Lock.near(viaMethod, viaStatic)) {
                    logger.error("the pure seam and the shipping method have " +
                                 "forked at raw " + raws[i] + ", lock period " +
                                 locks[j] + ", baseline " + bases[k] +
                                 ": outputRate() said " + viaMethod +
                                 ", gatedRate() said " + viaStatic +
                                 ". Every other case in this file reads the " +
                                 "static and is worthless once these disagree");
                    return false;
                }
            }
        }
    }
    return true;
}

// NO ESTABLISHED RATE IS NOT NO GUARD.
//
// The state exists at every session start and after every long gap, and it is
// the state in which a relative rule has nothing to be relative TO. The
// fallback is the absolute constant that shipped -- so the worst this change
// can do at that moment is exactly what the previous code did always.
(:test) function test_lock_noEstablishedRateStillGuards(logger) {
    // (a) the fallback IS the shipped constant, not merely "something large".
    var bases = [0.0, -1.0, null];
    for (var i = 0; i < bases.size(); i++) {
        var g = StrongRowView.fastGate(bases[i]);
        if (!Lock.near(g, $.FAST_NEEDS_LOCK)) {
            logger.error("(a) with baseline " + bases[i] + " there is no " +
                         "established rate, so the gate must fall back to " +
                         "FAST_NEEDS_LOCK (" + $.FAST_NEEDS_LOCK + "); got " + g);
            return false;
        }
    }

    // (b) and it still BITES there -- a fallback that returned a number nothing
    // could exceed would satisfy (a) and guard nothing.
    if (!Lock.near(StrongRowView.gatedRate(30.1, 0.0, 0.0), 0.0)) {
        logger.error("(b) 30.1 spm with no lock and no established rate must " +
                     "still be zeroed; got " +
                     StrongRowView.gatedRate(30.1, 0.0, 0.0));
        return false;
    }

    // (c) THE PROVENANCE OF THE MULTIPLE. FAST_NEEDS_LOCK is 1.5x the rate it
    // was implicitly calibrated at, and the relative rule arriving at c3 is
    // that same multiple applied to the athlete instead of to 20 spm. Pinned so
    // the pair can never be edited apart, leaving a bare 1.5 with no story.
    if (!Lock.near($.LOCK_REL_K * $.LOCK_REF_RATE, $.FAST_NEEDS_LOCK)) {
        logger.error("(c) LOCK_REL_K (" + $.LOCK_REL_K + ") x LOCK_REF_RATE (" +
                     $.LOCK_REF_RATE + ") must reproduce FAST_NEEDS_LOCK (" +
                     $.FAST_NEEDS_LOCK + ") -- the relative multiple is DERIVED " +
                     "from the absolute constant, not chosen beside it");
        return false;
    }
    return true;
}

// THE GUARD IS NEVER LOOSENED, AT ANY RATE.
//
// #149's first acceptance bar, and it is a claim about EVERY baseline rather
// than about the two that were recorded -- so it is swept, not sampled. Green
// at c1 (where the gate is the constant) and green at c3 (where it is the
// constant's minimum with something smaller).
(:test) function test_lock_theGuardIsNeverLoosenedAtAnyRate(logger) {
    // (a) the gate itself never rises above the shipped absolute.
    for (var b = 0.0; b <= 60.0; b += 0.5) {
        var g = StrongRowView.fastGate(b);
        if (g > $.FAST_NEEDS_LOCK + 0.0005) {
            logger.error("(a) at baseline " + b + " the gate is " + g +
                         ", above the shipped absolute " + $.FAST_NEEDS_LOCK +
                         " -- that reading would now pass where it used to be " +
                         "zeroed, which is the one direction this change is " +
                         "not allowed to move");
            return false;
        }
    }

    // (b) stated as the OUTCOME rather than as the threshold, because the
    // threshold is an implementation detail and the file is not: anything the
    // shipped rule zeroed must still be zeroed, at every baseline.
    var raws = [30.1, 31.0, 35.0, 45.0, 120.0];
    for (var b2 = 0.0; b2 <= 60.0; b2 += 2.5) {
        for (var i = 0; i < raws.size(); i++) {
            var got = StrongRowView.gatedRate(raws[i], 0.0, b2);
            if (!Lock.near(got, 0.0)) {
                logger.error("(b) " + raws[i] + " spm with no lock was zeroed " +
                             "by the shipped rule and must still be; at " +
                             "baseline " + b2 + " it came out as " + got);
                return false;
            }
        }
    }
    return true;
}

// WHAT THE BASELINE FOLDS IN, AND WHAT IT REFUSES TO.
//
// nextRateBase is introduced at c1 and reworked at c8; the cases below are the
// ones that hold across both, so they are invariants of the whole change rather
// than a way-station.
//
// WHAT THIS CASE DOES NOT COVER, stated here because the gap was real and shipped
// through review: every call below has `guarded == raw` or `guarded == 0.0`, so
// the third state -- guarded > 0 AND guarded != raw, which is what a lock SNAP
// produces -- is invisible to it. That state is
// test_lock_aSnappedReadingDoesNotFeedTheMedianItCorrected's, at the bottom of
// this file. Do not add a snap case here; keep the two readable apart.
(:test) function test_lock_theBaselineIsBuiltFromAcceptedReadingsOnly(logger) {
    // (a) the first ACCEPTED reading establishes it outright. An EMA eased up
    // from 0.0 would spend its first strokes claiming a rate nobody rowed.
    if (!Lock.near(StrongRowView.nextRateBase(0.0, 18.0, 18.0), 18.0)) {
        logger.error("(a) the first accepted reading must establish the " +
                     "baseline outright; got " +
                     StrongRowView.nextRateBase(0.0, 18.0, 18.0));
        return false;
    }

    // (b) a REJECTED first reading establishes NOTHING. Otherwise the first
    // phantom burst of a session sets the bar it is then measured against --
    // which would make the guard weakest exactly when it is least corroborated.
    if (!Lock.near(StrongRowView.nextRateBase(0.0, 0.0, 45.0), 0.0)) {
        logger.error("(b) a reading the guard REJECTED must not establish the " +
                     "baseline; got " +
                     StrongRowView.nextRateBase(0.0, 0.0, 45.0));
        return false;
    }

    // (c) a zero raw is the no-data state, not a rate of zero. Folding it in
    // would drag the baseline toward a cadence nobody rowed and then gate the
    // athlete against it.
    if (!Lock.near(StrongRowView.nextRateBase(16.0, 0.0, 0.0), 16.0)) {
        logger.error("(c) a zero median is 'nothing measured' and must leave " +
                     "the baseline untouched; got " +
                     StrongRowView.nextRateBase(16.0, 0.0, 0.0));
        return false;
    }

    // (d) an ACCEPTED reading moves it by LOCK_BASE_A_OK of the gap.
    var acc = StrongRowView.nextRateBase(16.0, 20.0, 20.0);
    if (!Lock.near(acc, 16.0 + $.LOCK_BASE_A_OK * 4.0)) {
        logger.error("(d) an accepted reading must move the baseline by " +
                     $.LOCK_BASE_A_OK + " of the gap: 16.0 toward 20.0 is " +
                     (16.0 + $.LOCK_BASE_A_OK * 4.0) + "; got " + acc);
        return false;
    }

    // (e) a REJECTED reading still moves it, but far less -- the escape hatch
    // that stops rejection from ever being permanent. Both halves are asserted:
    // it must MOVE (or the guard can deadlock: reject, so the baseline never
    // rises, so reject) and it must move STRICTLY LESS than an accepted one (or
    // a burst lifts its own bar as fast as real rowing does).
    var rej = StrongRowView.nextRateBase(16.0, 0.0, 20.0);
    if (!(rej > 16.0)) {
        logger.error("(e) a rejected reading must still creep the baseline " +
                     "upward, or a guard that starts rejecting can never stop " +
                     "-- the rejected reading is exactly the one that would " +
                     "have raised the bar. Got " + rej + " from 16.0");
        return false;
    }
    if (!(rej < acc)) {
        logger.error("(e) a rejected reading must move the baseline STRICTLY " +
                     "LESS than an accepted one (" + rej + " vs " + acc +
                     "), or a sustained phantom burst lifts its own gate as " +
                     "fast as real rowing does");
        return false;
    }
    return true;
}

// THE BASELINE IS ESTABLISHED BY THE SHIPPING DETECTOR, not by this file.
//
// Sections (a) and (b) drive real strokes through registerStroke() /
// recomputeRate() and read the baseline back, so the wiring -- one update per
// REGISTERED STROKE, from recomputeRate and nowhere else -- is under test and
// not merely reviewed. Section (c) drives the long-gap clear through the
// shipping onSensorData.
(:test) function test_lock_aSteadyRowEstablishesAndAGapClearsIt(logger) {
    // (a) eight strokes at a steady 15.0 spm establish a 15.0 spm baseline.
    // Steady, so the EMA has nothing to converge toward but the rate itself and
    // the assertion does not depend on LOCK_BASE_A_OK's value.
    var p = new Lock.Probe();
    p.rowAt(15.0, 8);
    if (!Lock.near(p.rateBase(), 15.0)) {
        logger.error("(a) eight strokes at a steady 15.0 spm must establish a " +
                     "15.0 spm baseline through the shipping detector; got " +
                     p.rateBase());
        return false;
    }

    // (b) a FRESH view has established nothing -- the state the fallback in
    // test_lock_noEstablishedRateStillGuards exists for, reached through the
    // real constructor rather than asserted about.
    var fresh = new Lock.Probe();
    if (!Lock.near(fresh.rateBase(), 0.0)) {
        logger.error("(b) a freshly constructed view has measured nothing and " +
                     "must hold no baseline; got " + fresh.rateBase());
        return false;
    }

    // (c) THE LONG GAP. The stroke ring times out after mLastPeriod * 2.2
    // (clamped to 4-12 s) of quiet, and the established rate must go with the
    // ring it was built from -- otherwise a warm-up cadence gates a work
    // interval, or a rest paddle gates a sprint.
    //
    // 4.0 s periods put the timeout at 8.8 s; the last stroke landed at
    // t = 28.0 s on the detector's synthetic clock (mSampleIdx * mDt, mDt =
    // 1/REQ_RATE = 0.04 s), so 1200 quiet samples take the clock to 48.0 s and
    // clear it with margin. NOT System.getTimer(): the detector's clock counts
    // samples this case feeds, so it reads the same on a seconds-old CI
    // simulator and an hours-old desktop one.
    p.feedQuiet(48, 25);
    if (!Lock.near(p.rateBase(), 0.0)) {
        logger.error("(c) 48 s of quiet must clear the established rate along " +
                     "with the stroke ring, so the next piece is guarded by " +
                     "the absolute fallback rather than by a baseline " +
                     "describing a piece that has ended; got " + p.rateBase());
        return false;
    }
    return true;
}

// -- c2: the differentials ----------------------------------------------------
//
// THE THREE CASES BELOW ARE RED AGAINST c1 AND GREEN ONLY AT c3. That is the
// whole job of this commit: fastGate() still returns the absolute constant, so
// each fails first and is then made to pass by a commit that touches no test
// file.
//
// THE RULE THEY PIN, stated once:
//
//     gate(base) = min( FAST_NEEDS_LOCK,
//                       max( LOCK_GATE_FLOOR, LOCK_REL_K * base ) )
//     gate(none) = FAST_NEEDS_LOCK
//
// which is #149's three bars in one line: never looser than the absolute
// (the outer min, pinned by theGuardIsNeverLoosenedAtAnyRate at c1), the same
// MULTIPLE for every athlete (the LOCK_REL_K term), and a fallback that still
// guards (gate(none)).
//
// WHY A FLOOR AT ALL, since #149 does not ask for one. The gate ZEROES a
// reading, and a zeroed reading does not establish the baseline, so a baseline
// that has drifted well under the rate the athlete is about to row at could
// otherwise reject the whole of the next interval. The recorded workout is
// 8 x 3' with 2' rests and the rests ARE rowed, so a rest-cadence baseline
// meeting a work interval is the ordinary case. LOCK_GATE_FLOOR is
// LOCK_REF_RATE: at or below the rate the absolute constant was calibrated at
// the gate stops tracking down and holds where a 20 spm rower's guard has
// always been. It binds only under 13.33 spm and does not touch #149's worked
// example.

// THE GATE TRACKS THE ROWER. #149's second acceptance bar, stated three ways so
// a partial implementation cannot satisfy it.
(:test) function test_lock_theGateTracksTheRowerNotAFixedThirty(logger) {
    // (a) the worked example from #149, as a number.
    var g15 = StrongRowView.fastGate(15.0);
    if (!Lock.near(g15, $.LOCK_REL_K * 15.0)) {
        logger.error("(a) a rower who has established 15.0 spm must be gated " +
                     "at " + ($.LOCK_REL_K * 15.0) + " spm; got " + g15 +
                     ". An absolute gate here is 1.98x this athlete's own " +
                     "rate -- the defect #149 measured");
        return false;
    }

    // (b) THE BAR ITSELF: the 15 spm rower gets the SAME MULTIPLE the 20 spm
    // rower already had. Stated as a ratio rather than as two numbers, so it
    // keeps holding if the constants are ever retuned together.
    var r15 = StrongRowView.fastGate(15.0) / 15.0;
    var r20 = StrongRowView.fastGate($.LOCK_REF_RATE) / $.LOCK_REF_RATE;
    if (!Lock.near(r15, r20)) {
        logger.error("(b) the guard must be the same MULTIPLE of every " +
                     "athlete's own rate: a 15.0 spm rower gets " + r15 +
                     "x and a " + $.LOCK_REF_RATE + " spm rower gets " + r20 +
                     "x. The whole finding in #149 is that these two differ");
        return false;
    }

    // (c) AND IT FIRES BELOW A FULL DOUBLING, which is the practical
    // consequence and the thing an athlete would notice. A doubled stroke
    // period is what the guard defends against; a guard that only fires PAST
    // the doubling catches it barely or not at all.
    if (!(g15 < 2.0 * 15.0)) {
        logger.error("(c) the guard on a 15.0 spm rower must fire below a full " +
                     "doubling (30.0 spm); it sits at " + g15 +
                     ", i.e. at or past the very error it exists to catch");
        return false;
    }
    return true;
}

// THE FLOOR AND THE CEILING, and the band between them where the rule is purely
// relative.
(:test) function test_lock_theGateHasAFloorAndKeepsTheAbsoluteCeiling(logger) {
    // (a) below LOCK_GATE_FLOOR / LOCK_REL_K the floor binds. 8.0 spm is a rest
    // paddle, and gating a work interval at 12.0 spm because the athlete was
    // resting is a worse failure than the one being fixed.
    var g8 = StrongRowView.fastGate(8.0);
    if (!Lock.near(g8, $.LOCK_GATE_FLOOR)) {
        logger.error("(a) an 8.0 spm baseline is under the floor, so the gate " +
                     "must hold at LOCK_GATE_FLOOR (" + $.LOCK_GATE_FLOOR +
                     "); got " + g8);
        return false;
    }

    // (b) just above the knee the rule is purely relative again, so the floor
    // is a floor and not a second regime. 14.0 x 1.5 = 21.0, over the floor.
    var g14 = StrongRowView.fastGate(14.0);
    if (!Lock.near(g14, $.LOCK_REL_K * 14.0)) {
        logger.error("(b) 14.0 spm is above the floor's knee (" +
                     ($.LOCK_GATE_FLOOR / $.LOCK_REL_K) + " spm), so the gate " +
                     "must be the relative " + ($.LOCK_REL_K * 14.0) +
                     "; got " + g14);
        return false;
    }

    // (c) the absolute ceiling survives. A fast rower's relative gate would
    // exceed the shipped constant, and #149's first bar forbids that.
    var g40 = StrongRowView.fastGate(40.0);
    if (!Lock.near(g40, $.FAST_NEEDS_LOCK)) {
        logger.error("(c) 1.5 x 40.0 is 60.0, above the shipped absolute, so " +
                     "the gate must clamp to FAST_NEEDS_LOCK (" +
                     $.FAST_NEEDS_LOCK + "); got " + g40);
        return false;
    }
    return true;
}

// END TO END ON THE SHIPPING PATH, which is what separates "the arithmetic is
// right" from "the app does this".
//
// The baseline is established by driving REAL STROKES through registerStroke()
// / recomputeRate(), never assigned; the verdict is read back through
// outputRate(). Both bands are exercised, so the case cannot be satisfied by
// something that simply zeroes more.
(:test) function test_lock_aLowRateRowerIsGuardedThroughTheShippingPath(logger) {
    // (a) THE DIFFERENTIAL. A 15.0 spm rower, then a reading at 25.0 spm with
    // no lock to corroborate it. The shipped rule passes that straight through
    // to row_stroke_rate, dist_per_stroke, corrective_rate and the numeral,
    // because 25 is under 30.
    var p = new Lock.Probe();
    p.rowAt(15.0, 8);
    p.setDetector(25.0, 0.0);
    if (!Lock.near(p.out(), 0.0)) {
        logger.error("(a) a rower established at 15.0 spm, reading 25.0 with " +
                     "NO autocorrelation lock, must be gated: 25.0 is 1.67x " +
                     "this athlete's own rate and nothing independent " +
                     "corroborates it. Got " + p.out() + " -- which is what " +
                     "reaches row_stroke_rate, dist_per_stroke and the numeral");
        return false;
    }

    // (b) AND THE GUARD IS NOT MERELY 'ZERO MORE'. Just under the gate, the
    // same rower's reading still passes untouched. Without this section an
    // implementation that zeroed everything would satisfy (a).
    var q = new Lock.Probe();
    q.rowAt(15.0, 8);
    q.setDetector(22.0, 0.0);
    if (!Lock.near(q.out(), 22.0)) {
        logger.error("(b) 22.0 spm is under the 15.0 spm rower's gate of " +
                     ($.LOCK_REL_K * 15.0) + " and must pass through " +
                     "untouched; got " + q.out());
        return false;
    }

    // (c) THE 20 SPM ROWER IS NOT PUNISHED FOR THE FIX. #149's calm row sat at
    // 20.3 spm and was already guarded at 1.48x; the change must leave that
    // athlete exactly where they were. Green in both epochs on purpose -- it is
    // the "never looser AND never gratuitously tighter" half of the bar, at the
    // one rate where the two rules coincide.
    var r = new Lock.Probe();
    r.rowAt(20.0, 8);
    r.setDetector(29.0, 0.0);
    if (!Lock.near(r.out(), 29.0)) {
        logger.error("(c) a rower established at " + $.LOCK_REF_RATE + " spm " +
                     "is gated exactly where the shipped absolute put them, " +
                     "so 29.0 must still pass; got " + r.out());
        return false;
    }
    return true;
}

// -- c4: the lock-state diagnostic symbols ------------------------------------
//
// #149's own words: "whether the lock was even up during these excursions is
// exactly what I cannot tell from the recordings". Three record-scope fields
// answer it from one more row. c4 lands the ENCODINGS and the estimator's
// confidence member; c5's differentials are RED against it because nothing
// writes the fields yet; c6 creates them and writes them.
//
// The cases below are green at c4 and stay green at c6.

// THE NO-DATA ENCODINGS CANNOT BE MISTAKEN FOR DATA.
//
// This is the #86 / #107 defect class -- absence rendered as a legal value --
// and the two fields need OPPOSITE answers, which is the whole reason they get
// separate encodings instead of a shared convention.
(:test) function test_lock_theDiagnosticEncodingsCannotBeMistakenForData(logger) {
    // (a) NO LOCK is 0.0 spm, and 0.0 is out of band BY CONSTRUCTION rather
    // than by convention: updateAutocorr searches only lags in
    // [60/MAX_RATE, 60/MIN_RATE], so a lock IS a rate in [MIN_RATE, MAX_RATE].
    // The inequality is asserted, not described, so a future MIN_RATE of zero
    // reds here instead of silently making the sentinel ambiguous.
    if (!Lock.near(StrongRowView.lockRateOf(0.0), $.LOCK_RATE_NONE)) {
        logger.error("(a) a zero period is NO LOCK and must encode as " +
                     $.LOCK_RATE_NONE + "; got " +
                     StrongRowView.lockRateOf(0.0));
        return false;
    }
    if (!($.LOCK_RATE_NONE < $.MIN_RATE)) {
        logger.error("(a) LOCK_RATE_NONE (" + $.LOCK_RATE_NONE + ") must lie " +
                     "OUTSIDE the band a lock can occupy (" + $.MIN_RATE +
                     ".." + $.MAX_RATE + " spm) or 'no lock' is " +
                     "indistinguishable from a slow one -- the #86 / #107 " +
                     "defect class");
        return false;
    }
    var absent = [null, -1.0];
    for (var i = 0; i < absent.size(); i++) {
        if (!Lock.near(StrongRowView.lockRateOf(absent[i]),
                       $.LOCK_RATE_NONE)) {
            logger.error("(a) an absent or negative period must encode as " +
                         $.LOCK_RATE_NONE + "; " + absent[i] + " gave " +
                         StrongRowView.lockRateOf(absent[i]));
            return false;
        }
    }

    // (b) and a REAL lock is the rate, at both ends of the band the estimator
    // can produce -- so the field is a rate and not a period, which is the one
    // thing a reader of the FIT cannot check for themselves.
    var pairs = [[3.0, 20.0], [1.5, $.MAX_RATE], [10.0, $.MIN_RATE],
                 [4.0, 15.0]];
    for (var j = 0; j < pairs.size(); j++) {
        var got = StrongRowView.lockRateOf(pairs[j][0]);
        if (!Lock.near(got, pairs[j][1])) {
            logger.error("(b) a lock period of " + pairs[j][0] + " s is " +
                         pairs[j][1] + " spm; got " + got);
            return false;
        }
    }

    // (c) THE CONFIDENCE IS THE OPPOSITE CASE, and this is why it gets a
    // negative sentinel instead of the same 0.0. A confidence of zero is an
    // ORDINARY READING -- an uncorrelated signal -- so 0.0 cannot also mean
    // "no estimate was computed".
    if (!Lock.near(StrongRowView.lockConf(0.5, 0.0), $.LOCK_CONF_NONE)) {
        logger.error("(c) a zero-energy window admits no confidence and must " +
                     "encode as " + $.LOCK_CONF_NONE + "; got " +
                     StrongRowView.lockConf(0.5, 0.0));
        return false;
    }
    if (!($.LOCK_CONF_NONE < 0.0)) {
        logger.error("(c) LOCK_CONF_NONE (" + $.LOCK_CONF_NONE + ") must be " +
                     "negative. A computed confidence is a correlation over " +
                     "an energy and is never negative, so that is the only " +
                     "value that cannot collide with a real one -- and 0.0 " +
                     "emphatically can");
        return false;
    }

    // (d) a computed confidence survives verbatim, including the zero that the
    // sentinel exists to be distinguishable FROM, and including the 0.35 the
    // detector's own unlock gate is keyed on.
    var cc = [[0.0, 1.0, 0.0], [0.35, 1.0, 0.35], [0.9, 2.0, 0.45],
              [2.0, 1.0, 2.0]];
    for (var k = 0; k < cc.size(); k++) {
        var gc = StrongRowView.lockConf(cc[k][0], cc[k][1]);
        if (!Lock.near(gc, cc[k][2])) {
            logger.error("(d) lockConf(" + cc[k][0] + ", " + cc[k][1] +
                         ") must be " + cc[k][2] + "; got " + gc);
            return false;
        }
    }
    if (Lock.near(StrongRowView.lockConf(0.0, 1.0), $.LOCK_CONF_NONE)) {
        logger.error("(d) a COMPUTED confidence of zero must not collapse " +
                     "onto the not-computed sentinel -- telling those two " +
                     "apart is the entire reason this field is worth logging");
        return false;
    }
    return true;
}

// THE RUN COUNTER SATURATES BELOW THE UINT16 INVALID PATTERN.
//
// mAcLowConf counts consecutive low-confidence estimates and is reset only by a
// confident one, so it grows without bound on a long unlocked row -- past what
// a UINT16 field can carry. Where it saturates is not a detail: 0xFFFF is the
// UINT16 "no data" pattern (the fact RR_INVALID records), so saturating ONTO it
// would turn the longest unlocked rows -- exactly the ones this field exists to
// show -- into an apparent absence.
(:test) function test_lock_theRunCounterSaturatesShortOfTheInvalidPattern(logger) {
    // (a) ordinary values pass through, including the 3 the unlock fires at.
    var pass = [0, 1, 3, 100, $.LOCK_LOW_MAX];
    for (var i = 0; i < pass.size(); i++) {
        if (StrongRowView.lockLowClamp(pass[i]) != pass[i]) {
            logger.error("(a) " + pass[i] + " is inside the field's range and " +
                         "must pass through; got " +
                         StrongRowView.lockLowClamp(pass[i]));
            return false;
        }
    }

    // (b) and anything beyond it saturates.
    if (StrongRowView.lockLowClamp(999999) != $.LOCK_LOW_MAX) {
        logger.error("(b) a run past the field's range must saturate at " +
                     $.LOCK_LOW_MAX + "; got " +
                     StrongRowView.lockLowClamp(999999));
        return false;
    }

    // (c) WHERE it saturates. 0xFFFF is the UINT16 no-data pattern; the
    // saturating value has to stay under it.
    if (!($.LOCK_LOW_MAX < 0xFFFF)) {
        logger.error("(c) LOCK_LOW_MAX is " + $.LOCK_LOW_MAX + ", which " +
                     "reaches the UINT16 invalid pattern 0xFFFF (" + 0xFFFF +
                     "). A row unlocked long enough would then be recorded as " +
                     "NO DATA rather than as a very long unlocked run -- the " +
                     "opposite of what this field is for");
        return false;
    }

    // (d) an impossible negative is not arithmetic. Unreachable from
    // mAcLowConf, which only ever increments from zero; here so the contract
    // belongs to the function and not to its one caller.
    if (StrongRowView.lockLowClamp(-5) != 0) {
        logger.error("(d) a negative run must clamp to 0; got " +
                     StrongRowView.lockLowClamp(-5));
        return false;
    }
    return true;
}

// THE SENTINEL IS REACHED BY THE SHIPPING ESTIMATOR, not only by the static.
//
// A pin on lockConf alone would say nothing about whether updateAutocorr ever
// puts the sentinel back once a real confidence has been recorded. Driven as a
// DIFFERENTIAL -- a confidence is planted, then quiet samples are fed through
// the shipping onSensorData -- so a wiring that simply never wrote the member
// would red here.
(:test) function test_lock_theConfidenceSentinelIsRestoredByTheEstimator(logger) {
    var p = new Lock.Probe();
    p.setLockState(3.0, 0.9, 0);
    if (!Lock.near(p.lockConfState(), 0.9)) {
        logger.error("setup: the planted confidence did not take; got " +
                     p.lockConfState());
        return false;
    }
    // 30 batches of 25 zero samples is 750 samples: past AC_MIN_N (40 decimated
    // samples = 200 raw) with margin, so updateAutocorr genuinely runs and
    // finds a window with no energy at all. The clock here is the detector's
    // own sample counter, never System.getTimer().
    p.feedQuiet(30, 25);
    if (!Lock.near(p.lockConfState(), $.LOCK_CONF_NONE)) {
        logger.error("a window with no energy admits no confidence, so the " +
                     "estimator must put the sentinel (" + $.LOCK_CONF_NONE +
                     ") back rather than leave the last real number standing " +
                     "-- a stale confidence is exactly the fabrication these " +
                     "fields exist to prevent. Got " + p.lockConfState());
        return false;
    }
    return true;
}

// THE RECORDED CONFIDENCE IS THE NUMBER THE ESTIMATOR'S OWN GATE WAS TAKEN ON.
//
// WHY THIS CASE EXISTS, and it is a coverage hole rather than a live defect.
// `mAcConf = lockConf(best, e)` is the only place the diagnostic member gets its
// MAIN-PATH value, and nothing pinned it. The two cases that mention mAcConf
// reach it another way: theConfidenceSentinelIsRestoredByTheEstimator exercises
// only updateAutocorr's zero-energy early return, and theTickRecordsTheLockState
// PLANTS a confidence through setLockState, so it pins onTick's READ of the
// member and not the estimator's WRITE to it. Every existing route into
// updateAutocorr from a (:test) went through feedQuiet, whose batches are
// literal zeros, so the estimator always returned at the zero-energy line and
// the main path was never executed at all. A mutant that computed the
// confidence into a local -- leaving the gate, and therefore every detector
// behaviour, byte-for-byte unchanged -- and assigned a constant to mAcConf
// passed the entire suite.
//
// What lands in the file is that member: onTick calls mFitLockConf.setData(
// mAcConf) with no intervening transform. So a decoupled member means
// lock_confidence carries numbers no lock decision was ever taken on, on
// precisely the rows #149 filed these fields to explain.
//
// WHAT IS ASSERTED IS A CONSISTENCY RELATION BETWEEN TWO THINGS THE SHIPPING
// ESTIMATOR DID, never a re-derivation of best/e -- a case that recomputed the
// confidence would pin its own arithmetic and nothing else. Both legs are
// required and neither suffices: any CONSTANT satisfies at most one of them.
(:test) function test_lock_theEstimatorRecordsTheConfidenceItsGateWasTakenOn(logger) {
    // (a) A CLEAN 20 spm CYCLE LOCKS. 1200 samples is 48 s at the configured
    // rate -- past AC_MIN_N with the ring full -- and the phase comes from the
    // sample index, so this reads the same on CI's simulator and a desktop one.
    var p = new Lock.Probe();
    p.feedWave(Lock.sineWave(20.0, 1200, p.dtState(), 500), 25);
    if (!(p.lockPeriodState() > 0.0) || p.lockLowState() != 0) {
        logger.error("setup (a): a clean 20 spm cycle must leave the estimator " +
                     "LOCKED with no low-confidence run, or the leg below is " +
                     "asserting about a state it never reached. period=" +
                     p.lockPeriodState() + " lowRun=" + p.lockLowState());
        return false;
    }
    // The estimator PASSED its own gate -- that is what a zero run length after
    // a locked estimate means -- so the confidence it recorded has to be one
    // that passes it.
    if (!(p.lockConfState() >= p.acMinConf())) {
        logger.error("(a) the estimator locked and reset its low-confidence " +
                     "run, which happens ONLY when the reading passed the " +
                     p.acMinConf() + " gate -- so the confidence it recorded " +
                     "must be at least that. It recorded " + p.lockConfState() +
                     ", which is the number lock_confidence would carry for a " +
                     "decision that was never taken on it");
        return false;
    }

    // (b) THE OTHER SIDE. Aperiodic input with the same energy: the estimator
    // runs its whole main path, finds no lag worth the gate, and advances the
    // low-confidence run -- which happens ONLY on the failing branch.
    var q = new Lock.Probe();
    q.feedWave(Lock.noiseWave(1200, 500, 1), 25);
    if (!(q.lockLowState() > 0)) {
        logger.error("setup (b): aperiodic input must FAIL the confidence gate " +
                     "and advance the low-confidence run, or the leg below is " +
                     "asserting about a state it never reached. lowRun=" +
                     q.lockLowState() + " period=" + q.lockPeriodState());
        return false;
    }
    if (!(q.lockConfState() < q.acMinConf())) {
        logger.error("(b) the estimator advanced its low-confidence run, which " +
                     "happens ONLY when the reading FAILED the " +
                     q.acMinConf() + " gate -- so the confidence it recorded " +
                     "must be under it. It recorded " + q.lockConfState());
        return false;
    }

    // (c) AND NEITHER LEG IS THE SENTINEL. Both windows carry real energy, so
    // both reached lockConf's computed branch; a wiring that left
    // LOCK_CONF_NONE standing on the main path would satisfy (b) by accident
    // and would report "no estimate was computed" for every unlocked row.
    var confs = [p.lockConfState(), q.lockConfState()];
    for (var i = 0; i < 2; i++) {
        if (!(confs[i] >= 0.0)) {
            logger.error("(c) leg " + i + " recorded " + confs[i] + ", which is " +
                         "not a computed confidence -- a correlation over an " +
                         "energy is never negative, so this is the sentinel " +
                         "surviving the main path. 'no estimate' and 'a bad " +
                         "estimate' are the two states these fields exist to " +
                         "tell apart");
            return false;
        }
    }
    return true;
}

// -- c5: the diagnostic differentials -----------------------------------------
//
// BOTH CASES BELOW ARE RED AGAINST c4 AND GREEN ONLY AT c6. The three handles
// exist at c4 and stay null; onTick does not know about them, so a recording
// stand-in installed on each receives nothing.
//
// WHAT THESE CASES OBSERVE, at the strength the evidence supports and no
// further: the ARGUMENT of an in-app setData call. They say nothing about what
// lands in the file's bytes and nothing about what a decoder renders. Those
// need a simulator session and a decode, and no (:test) in this repository can
// obtain either.

// THE TICK RECORDS THE LOCK STATE.
//
// One tick, one lock state, three values -- the plain case, so a failure names
// which of the three is missing rather than "the diagnostics do not work".
(:test) function test_lock_theTickRecordsTheLockState(logger) {
    var f = Lock.fields();
    var p = Lock.tickProbe(f);
    // A 3.0 s lock is 20.0 spm; 0.42 is a confidence over the 0.35 unlock gate,
    // so this is a HEALTHY LOCK -- the state the excursions would have to be
    // measured against.
    p.setLockState(3.0, 0.42, 0);
    p.runTick();

    var want = [20.0, 0.42, 0];
    var names = ["lock_rate", "lock_confidence", "lock_lowconf_run"];
    for (var i = 0; i < 3; i++) {
        var got = f[i].last();
        if (got == null) {
            logger.error(names[i] + " was never written. Record-scope fields " +
                         "LATCH, so a field this app declares and does not " +
                         "write carries the type's never-set pattern before " +
                         "the first write and then re-emits whatever it last " +
                         "held -- an unwritten diagnostic is not a quiet " +
                         "diagnostic");
            return false;
        }
        if (!Lock.near(got * 1.0, want[i] * 1.0)) {
            logger.error(names[i] + " must carry " + want[i] + " for a 3.0 s " +
                         "lock at confidence 0.42 with no low-confidence run; " +
                         "got " + got);
            return false;
        }
    }
    return true;
}

// NO LOCK IS RECORDED AS A STATE, NOT AS SILENCE.
//
// THE LOAD-BEARING CASE OF PART 2, and the trap it exists to close is specific.
// The obvious implementation writes the lock rate only when there IS a lock --
// it reads as caution. But record-scope FitContributor fields LATCH: a skipped
// setData re-emits the previous value on the next record (#36, byte level). So
// on the very rows this field exists to explain -- the ones where the lock
// DROPS mid-piece -- that implementation would keep re-emitting the last good
// lock rate and report a lock that was not there.
//
// Both halves are asserted, and the second is the one the caution-shaped
// implementation fails: the VALUE must become the no-lock encoding, and a
// SECOND WRITE must actually have happened.
(:test) function test_lock_noLockIsRecordedAsAStateNotAsSilence(logger) {
    var f = Lock.fields();
    var p = Lock.tickProbe(f);

    // A healthy lock first, so there is something to latch.
    p.setLockState(3.0, 0.55, 0);
    p.runTick();
    if (!Lock.near(f[0].last(), 20.0)) {
        logger.error("setup: the first tick must record the 20.0 spm lock; " +
                     "got " + f[0].last());
        return false;
    }

    // Then the lock drops: three low-confidence estimates in a row is exactly
    // what updateAutocorr zeroes mAcPeriod on.
    p.setLockState(0.0, 0.11, 3);
    p.runTick();

    if (!Lock.near(f[0].last(), $.LOCK_RATE_NONE)) {
        logger.error("after the lock drops, lock_rate must carry the no-lock " +
                     "encoding " + $.LOCK_RATE_NONE + "; it carries " +
                     f[0].last() + ". If that is the previous 20.0, the write " +
                     "was SKIPPED -- and a skipped write on a record-scope " +
                     "field re-emits the last value, so the file would report " +
                     "a lock that was not up. Skipping is not caution here, " +
                     "it is fabrication");
        return false;
    }
    if (f[0].vals.size() != 2) {
        logger.error("two ticks must produce two lock_rate writes; got " +
                     f[0].vals.size() + ". Withholding the write is the " +
                     "specific defect this case exists to catch: it does not " +
                     "leave a gap, it latches");
        return false;
    }

    // The other two follow the drop as well -- the confidence that FAILED the
    // gate is the interesting number, and the run counter is what says how long
    // it has been failing.
    if (!Lock.near(f[1].last(), 0.11)) {
        logger.error("lock_confidence must carry the confidence the gate was " +
                     "taken on even when it FAILED (0.11); got " + f[1].last());
        return false;
    }
    if (f[2].last() != 3) {
        logger.error("lock_lowconf_run must carry the consecutive " +
                     "low-confidence count (3, the run length updateAutocorr " +
                     "unlocks at); got " + f[2].last());
        return false;
    }
    return true;
}

// -- c7: the round-2 differentials --------------------------------------------
//
// BOTH CASES BELOW ARE RED AGAINST c6 AND GREEN ONLY AT c8. They are the two
// review findings that are behaviour defects rather than comment defects, and
// each one is a way the baseline this change introduced can be set from
// something the athlete did not row.
//
//   * PAUSE-TIME MOTION. registerStroke gates only the stroke COUNTER on
//     !mPaused (#109); recomputeRate() runs unconditionally, and c1 hung
//     updateRateBase() off recomputeRate(). So drinking, wiping down or
//     gesturing during a pause -- the exact list #109 records -- established
//     "the rate this athlete holds".
//
//   * A SNAPPED READING. gatedRate has TWO ways of not passing the median
//     through: it ZEROES a reading no lock corroborates, and it SNAPS a locked
//     reading that disagrees with the lock. nextRateBase tested only the first,
//     so a median the lock had just declared wrong was folded in as though the
//     guard had accepted it.
//
// Both defects run the SAME direction in the end: the gate reverts to the
// shipped absolute constant, or below it, for reasons that are not the
// athlete's rate. Neither can make the guard LOOSER than what shipped (the
// outer min in fastGate holds unconditionally and is pinned separately by
// theGuardIsNeverLoosenedAtAnyRate), so what they cost is this change's
// benefit, plus -- for the pause case -- a window of ZEROED row_stroke_rate
// over genuine rowing.

// THE BASELINE FREEZES WHILE THE SESSION IS PAUSED.
//
// #109's rule, applied to the one accumulator c1 added: an athlete-state
// accumulator does not advance while the athlete is not rowing. mRate and the
// DSP ring keep running, deliberately (see the note above the !mPaused counter
// gate in registerStroke) -- only the guard's REFERENCE freezes.
(:test) function test_lock_theBaselineFreezesWhileTheSessionIsPaused(logger) {
    // (a) A PAUSE ESTABLISHES NOTHING. Eight strokes of 8 spm non-rowing
    // motion during a pause must not become an established rate.
    var p = new Lock.Probe();
    p.enterStepLive(p.kindWork(), true);
    p.rowAt(8.0, 8);
    if (!Lock.near(p.rateBase(), 0.0)) {
        logger.error("(a) motion during a PAUSE must not establish the rate " +
                     "this athlete holds -- registerStroke already refuses to " +
                     "count it as a stroke (#109) and it is the same motion. " +
                     "The baseline reads " + p.rateBase());
        return false;
    }

    // (b) AND THE COST OF GETTING THIS WRONG LANDS IN THE FILE. With the
    // baseline set from the phantom cadence the gate drops to its floor, and a
    // genuine reading after the resume is ZEROED -- so row_stroke_rate and
    // dist_per_stroke carry 0.0 for real rowing, which is the #86 / #107 defect
    // class moved from the screen into the recording. main records 24.0 here.
    p.setDetector(24.0, 0.0);
    if (!Lock.near(p.out(), 24.0)) {
        logger.error("(b) a genuine 24.0 spm median after the resume must " +
                     "reach the file. The shipped absolute rule records 24.0; " +
                     "this returned " + p.out() + ", which is what " +
                     "row_stroke_rate and dist_per_stroke would carry");
        return false;
    }

    // (c) MID-SESSION, which is the case a fresh probe cannot show: the rate
    // the athlete ROWED must survive the pause and still be the reference when
    // they resume. 15.0 spm established, then a pause gestured at 8 spm.
    var q = new Lock.Probe();
    q.enterStepLive(q.kindWork(), false);
    var t = q.rowFrom(15.0, 8, 0.0);
    if (!Lock.near(q.rateBase(), 15.0)) {
        logger.error("setup: eight strokes at 15.0 spm must establish 15.0; " +
                     "got " + q.rateBase());
        return false;
    }
    q.enterStepLive(q.kindWork(), true);
    q.rowFrom(8.0, 8, t);
    if (!Lock.near(q.rateBase(), 15.0)) {
        logger.error("(c) the baseline must still be the 15.0 spm the athlete " +
                     "ROWED after a pause spent gesturing at 8 spm; it reads " +
                     q.rateBase() + ". A pause is not a piece and must not " +
                     "retune the guard for the piece that follows it");
        return false;
    }

    // (d) and the consequence, read back through the shipping decision: after
    // the resume a 22.0 spm reading is under the 15.0 spm rower's gate of 22.5
    // and must pass. Dragged down by the pause, the gate sits at its floor and
    // zeroes it.
    q.enterStepLive(q.kindWork(), false);
    q.setDetector(22.0, 0.0);
    if (!Lock.near(q.out(), 22.0)) {
        logger.error("(d) 22.0 spm is under the established 15.0 spm rower's " +
                     "gate of " + ($.LOCK_REL_K * 15.0) + " and must pass " +
                     "after the resume; got " + q.out());
        return false;
    }
    return true;
}

// AND THE RESUME IS NOT GUARDED BY THE PAUSE'S CADENCE.
//
// THE SECOND HALF OF THE SAME DEFECT, and it needs its own case because the
// pause flag alone does not close it. mPeriods survives the pause, so the first
// medians AFTER the resume are still the pause's; the baseline takes them at
// LOCK_BASE_A_OK and can only creep back at LOCK_BASE_A_REJ, because the guard
// never rejects a reading for being too SLOW. Measured through this very path
// with the pause flag and nothing else: a 20 spm rower whose pause was gestured
// at 8 spm and who resumed at 24 spm lost 15 strokes of row_stroke_rate to 0.0,
// and 24 strokes when the resume was 26 spm.
//
// WHAT THIS CASE ASSERTS IS THE OUTCOME, not the mechanism: across a whole
// row / pause / resume timeline driven through registerStroke(), no stroke of
// the resumed piece may come out of the shipping outputRate() as 0.0. An
// implementation that reaches that by any other means passes, and should.
(:test) function test_lock_theResumeIsNotGuardedByThePausesCadence(logger) {
    // Four timelines. The pause cadences are inside registerStroke's accepted
    // band (6..40 spm), which is what makes them reach the ring at all; the
    // resume rates are the band where the relative gate can bite, since the gate
    // never falls below LOCK_GATE_FLOOR.
    var cases = [[20.0, 8.0, 24.0], [20.0, 8.0, 22.0],
                 [15.0, 8.0, 22.0], [20.0, 6.0, 26.0]];
    for (var i = 0; i < cases.size(); i++) {
        var row = cases[i][0];
        var gest = cases[i][1];
        var back = cases[i][2];

        var p = new Lock.Probe();
        p.enterStepLive(p.kindWork(), false);
        var t = p.rowFrom(row, 8, 0.0);
        if (!Lock.near(p.rateBase(), row)) {
            logger.error("setup: eight strokes at " + row + " spm must " +
                         "establish " + row + "; got " + p.rateBase());
            return false;
        }

        // The pause: sustained non-rowing motion, no ring timeout (nothing
        // drives onSensorData here, and the cadences are inside the band).
        p.enterStepLive(p.kindWork(), true);
        t = p.rowFrom(gest, 10, t);

        // The resume. NO autocorrelation lock -- the state the whole relative
        // gate is about, and the one the lock_* diagnostics exist because no
        // recording can rule out.
        p.enterStepLive(p.kindWork(), false);
        for (var k = 0; k < 24; k++) {
            t = p.rowFrom(back, 1, t);
            var o = p.out();
            // The first strokes after a resume still carry the pause's median,
            // which is PRE-EXISTING and deliberate (the numeral must not blank
            // for NPER strokes) -- so a slow reading here is expected. What is
            // forbidden is a ZERO, which means the guard rejected the athlete's
            // own rate.
            if (o <= 0.0) {
                logger.error("a rower established at " + row + " spm paused, " +
                             "gestured at " + gest + " spm and resumed at " +
                             back + " spm: stroke " + k + " of the resumed " +
                             "piece came out of outputRate() as " + o +
                             ", with the baseline at " + p.rateBase() +
                             " and the gate at " +
                             StrongRowView.fastGate(p.rateBase()) +
                             ". That 0.0 is what row_stroke_rate and " +
                             "dist_per_stroke carry for real rowing, and " +
                             "drawRate renders it '--.-'");
                return false;
            }
        }

        // AND THE HOLD IS FINITE. Without this the case is satisfied by a
        // baseline that freezes FOREVER after the first paused stroke -- a
        // mutant that survived the whole suite at 255/255 when this case was
        // written. A guard whose reference stops tracking the athlete is not a
        // relative guard; after 24 strokes at a steady rate the baseline must
        // have converged on it. The tolerance is a tenth of a spm rather than
        // Lock.near's half-thousandth, because this asserts CONVERGENCE and not
        // an exact value: nineteen quarter-of-the-gap steps leave under 0.02
        // spm of the largest gap any case here starts from, so a tenth is loose
        // by a factor of five and still a hundredth of the 4.0 spm error a
        // never-expiring hold leaves standing.
        var drift = p.rateBase() - back;
        if (drift < 0.0) { drift = -drift; }
        if (!(drift < 0.1)) {
            logger.error("after 24 strokes at a steady " + back + " spm the " +
                         "baseline must have converged on it; it reads " +
                         p.rateBase() + ". A hold that never expires satisfies " +
                         "every other assertion in this case and leaves the " +
                         "guard keyed to a rate the athlete has stopped rowing");
            return false;
        }
    }
    return true;
}

// A SNAPPED READING MUST NOT FEED THE MEDIAN IT CORRECTED.
//
// gatedRate returns a NON-ZERO value in two quite different situations: the
// median was corroborated and passed through, or the lock disagreed with it and
// SNAPPED it. nextRateBase used `guarded` only as an accept/reject flag and
// always folded in `raw`, so the second situation fed the baseline the very
// number the lock had just declared wrong.
//
// Sections (a) and (b) are the arithmetic; (c) and (d) hold the two paths that
// must NOT move; (e) is the whole loop through the shipping detector, which is
// what separates "the static is right" from "the app does this".
(:test) function test_lock_aSnappedReadingDoesNotFeedTheMedianItCorrected(logger) {
    // (a) an established baseline, a 20.0 spm lock, a doubled 38.0 median. The
    // output stage publishes 20.0, so 20.0 is what the athlete is held to have
    // rowed and the baseline must not move at all.
    var snap = StrongRowView.nextRateBase(20.0, 20.0, 38.0);
    if (!Lock.near(snap, 20.0)) {
        logger.error("(a) the lock SNAPPED a 38.0 spm median to 20.0, i.e. the " +
                     "output stage declared 38.0 wrong. Folding 38.0 into the " +
                     "baseline lets the error the snap caught raise the bar " +
                     "the NO-LOCK gate is set from; got " + snap +
                     " where 20.0 was published");
        return false;
    }

    // (b) and it must not ESTABLISH from one either -- the same argument case
    // (b) of theBaselineIsBuiltFromAcceptedReadingsOnly makes for a rejected
    // reading. A first-stroke doubled median otherwise sets the bar outright:
    // fastGate(38.0) is FAST_NEEDS_LOCK, i.e. this change becomes a no-op for
    // that athlete from their first stroke.
    var est = StrongRowView.nextRateBase(0.0, 20.0, 38.0);
    if (!Lock.near(est, 20.0)) {
        logger.error("(b) with nothing established, a snapped reading must " +
                     "establish what the output stage PUBLISHED (20.0), not " +
                     "the median it discarded; got " + est);
        return false;
    }

    // (c) AN ORDINARY ACCEPTED READING IS UNTOUCHED. Without this, an
    // implementation that simply stopped folding anything in would satisfy (a)
    // and (b). guarded == raw here, so this is the no-op case.
    var acc = StrongRowView.nextRateBase(16.0, 20.0, 20.0);
    if (!Lock.near(acc, 16.0 + $.LOCK_BASE_A_OK * 4.0)) {
        logger.error("(c) an uncorrected accepted reading must still move the " +
                     "baseline by " + $.LOCK_BASE_A_OK + " of the gap: " +
                     (16.0 + $.LOCK_BASE_A_OK * 4.0) + "; got " + acc);
        return false;
    }

    // (d) AND THE REJECT PATH IS UNTOUCHED. A zeroed reading published nothing,
    // so the creep that stops rejection from being permanent must keep using
    // the raw median -- that clause is the deadlock escape hatch.
    var rej = StrongRowView.nextRateBase(16.0, 0.0, 20.0);
    if (!Lock.near(rej, 16.0 + $.LOCK_BASE_A_REJ * 4.0)) {
        logger.error("(d) a REJECTED reading must still creep the baseline by " +
                     $.LOCK_BASE_A_REJ + " of the gap toward the raw median (" +
                     (16.0 + $.LOCK_BASE_A_REJ * 4.0) + ") -- without it the " +
                     "guard deadlocks; got " + rej);
        return false;
    }

    // (e) END TO END. A 15.0 spm rower, then a burst of doubled 37.5 spm
    // medians while the lock holds the TRUE 4.0 s period. Every one of those is
    // snapped to 15.0, so the baseline must not move a step.
    var p = new Lock.Probe();
    var t = p.rowFrom(15.0, 8, 0.0);
    p.setLockState(4.0, 0.6, 0);
    p.rowFrom(37.5, 8, t);
    if (!Lock.near(p.rateBase(), 15.0)) {
        logger.error("(e) eight snapped 37.5 spm medians against a 15.0 spm " +
                     "lock must leave the 15.0 spm baseline where it is; it " +
                     "reads " + p.rateBase() + ". Every one of those readings " +
                     "came out of the output stage as 15.0");
        return false;
    }

    // (f) and the point of (e): the phantom the relative gate exists to reject
    // is still rejected afterwards. With the baseline inflated by the burst,
    // fastGate returns the shipped absolute and 28.0 spm with no lock walks
    // into row_stroke_rate.
    if (!Lock.near(StrongRowView.gatedRate(28.0, 0.0, p.rateBase()), 0.0)) {
        logger.error("(f) after the burst, 28.0 spm with NO lock must still be " +
                     "rejected by the 15.0 spm rower's gate of " +
                     ($.LOCK_REL_K * 15.0) + "; gatedRate returned " +
                     StrongRowView.gatedRate(28.0, 0.0, p.rateBase()) +
                     " against a baseline of " + p.rateBase() +
                     ". A guard disarmed by the readings the snap flagged as " +
                     "errors is this change reverting to the constant it " +
                     "replaces");
        return false;
    }
    return true;
}

// -- c9: the gate-input diagnostic symbols (#149 part 2) ----------------------
//
// WHAT PART 1 LEFT UNANSWERABLE. The lock fields say whether a lock was up.
// They do not say what the GATE was given, and the file still cannot show the
// gate firing: row_stroke_rate is gatedRate's OUTPUT, in which a zeroed reading
// and a tick with no median are the same 0.0, and a snapped reading is
// indistinguishable from one that passed through. Nor can the gate's own
// threshold be recovered -- fastGate keys on mRateBase, and nextRateBase
// consumes the PRE-GATE median, so the recursion cannot be replayed from a file
// that does not carry it.
//
// rate_raw (mRate) and rate_base (mRateBase) close both. c9 lands the encodings
// and the plumbing; c10's differentials are RED against it because nothing
// writes the fields yet; c11 creates them and writes them.
//
// The two cases below are green at c9 and stay green at c11.

// THE NO-DATA ZERO IS THE DETECTOR'S OWN VALUE, NOT A SUBSTITUTED MARKER.
//
// This is the #86 / #107 question asked for these two fields specifically, and
// the answer is NOT the one lock_confidence got. A confidence of zero is an
// ordinary reading, so 0.0 there had to mean something else and needed a
// negative sentinel. Here 0.0 is what mRate and mRateBase ACTUALLY HOLD in the
// no-data state, and no reading can collide with it -- but only because
// registerStroke DROPS an out-of-band period rather than admitting a small rate,
// which is the step this case exists to hold. Everything else in the encoding
// argument rests on it.
(:test) function test_lock_theNoDataZeroIsTheDetectorsOwnValue(logger) {
    // (a) THE INEQUALITY, asserted rather than described -- the same form
    // LOCK_RATE_NONE's takes, so a future MIN_RATE of zero reds here instead of
    // silently making both encodings ambiguous.
    if (!($.RATE_RAW_NONE < $.MIN_RATE)) {
        logger.error("(a) RATE_RAW_NONE (" + $.RATE_RAW_NONE + ") must lie " +
                     "OUTSIDE the band a median can occupy (" + $.MIN_RATE +
                     ".." + $.MAX_RATE + " spm), or 'no median' is " +
                     "indistinguishable from a slow one");
        return false;
    }
    if (!($.RATE_BASE_NONE < $.MIN_RATE)) {
        logger.error("(a) RATE_BASE_NONE (" + $.RATE_BASE_NONE + ") must lie " +
                     "OUTSIDE the band a baseline can occupy (" + $.MIN_RATE +
                     ".." + $.MAX_RATE + " spm), or 'nothing established' is " +
                     "indistinguishable from a low established rate");
        return false;
    }

    // (b) THE STEP THE INEQUALITY RESTS ON, driven through the SHIPPING
    // registerStroke rather than argued. 5.0 spm is a 12.0 s period, outside
    // the accepted band [60/MAX_RATE, 60/MIN_RATE] = [1.5, 10.0] s, so every
    // one of these strokes is DROPPED. The claim under test is that this leaves
    // the median at EXACTLY 0.0 -- if sub-band motion instead produced a small
    // rate, a recorded 0.0 would be ambiguous and the encoding above would be
    // the very defect it claims not to be.
    var slow = new Lock.Probe();
    slow.rowAt(5.0, 8);
    if (slow.rawRate() != 0.0) {
        logger.error("(b) motion at 5.0 spm is BELOW MIN_RATE and its periods " +
                     "are dropped, so the median must stay at exactly 0.0; it " +
                     "reads " + slow.rawRate() + ". A value in (0, " +
                     $.MIN_RATE + ") would collide with nothing today but " +
                     "would make rate_raw's 0.0 mean two things");
        return false;
    }
    if (slow.rateBase() != 0.0) {
        logger.error("(b) and nothing was published, so no baseline may be " +
                     "established either; it reads " + slow.rateBase());
        return false;
    }

    // (c) THE FAST EDGE runs the same way: 45.0 spm is a 1.333 s period, under
    // 60/MAX_RATE = 1.5 s, so it is dropped rather than clamped into the band.
    var fast = new Lock.Probe();
    fast.rowAt(45.0, 8);
    if (fast.rawRate() != 0.0) {
        logger.error("(c) motion at 45.0 spm is ABOVE MAX_RATE and its periods " +
                     "are dropped, so the median must stay at exactly 0.0; it " +
                     "reads " + fast.rawRate());
        return false;
    }

    // (d) AND THE SLOWEST READING THE DETECTOR CAN REPORT IS MIN_RATE ITSELF,
    // so there is no gap between the encoding and the first legal value for a
    // reading to fall into. 6.0 spm is a 10.0 s period -- the band's outer edge,
    // accepted, because the comparison is inclusive.
    var edge = new Lock.Probe();
    edge.rowAt($.MIN_RATE, 8);
    if (!Lock.near(edge.rawRate(), $.MIN_RATE)) {
        logger.error("(d) a 10.0 s period is the slowest the band admits and " +
                     "must give a median of exactly " + $.MIN_RATE + " spm; " +
                     "got " + edge.rawRate() + ". Without this leg (b) would be " +
                     "satisfied by a detector that reported nothing at all");
        return false;
    }
    if (!Lock.near(edge.rateBase(), $.MIN_RATE)) {
        logger.error("(d) that reading passes the gate (it is far under " +
                     $.FAST_NEEDS_LOCK + "), so it must ESTABLISH the baseline " +
                     "at " + $.MIN_RATE + "; got " + edge.rateBase());
        return false;
    }

    // (e) THE STATICS NORMALISE what the members cannot hold today. Reachable
    // only from a future caller, and here so the field's contract belongs to
    // these functions rather than to the invariants of their one call site --
    // the same argument lockLowClamp's negative clamp carries.
    var absent = [null, -1.0, -0.001, 0.0];
    for (var i = 0; i < absent.size(); i++) {
        if (!Lock.near(StrongRowView.rateRawOf(absent[i]), $.RATE_RAW_NONE)) {
            logger.error("(e) rateRawOf(" + absent[i] + ") must be " +
                         $.RATE_RAW_NONE + "; got " +
                         StrongRowView.rateRawOf(absent[i]));
            return false;
        }
        if (!Lock.near(StrongRowView.rateBaseOf(absent[i]), $.RATE_BASE_NONE)) {
            logger.error("(e) rateBaseOf(" + absent[i] + ") must be " +
                         $.RATE_BASE_NONE + "; got " +
                         StrongRowView.rateBaseOf(absent[i]));
            return false;
        }
    }

    // (f) AND AN IN-BAND VALUE SURVIVES VERBATIM. This is what separates
    // "the variable" from "an encoding of the variable", and without it (e)
    // would be satisfied by a function that returned the sentinel always.
    var keep = [$.MIN_RATE, 13.0, 15.2, 20.3, 29.0, $.MAX_RATE];
    for (var j = 0; j < keep.size(); j++) {
        if (!Lock.near(StrongRowView.rateRawOf(keep[j]), keep[j])) {
            logger.error("(f) rate_raw carries the median UNCHANGED; " +
                         keep[j] + " came back as " +
                         StrongRowView.rateRawOf(keep[j]));
            return false;
        }
        if (!Lock.near(StrongRowView.rateBaseOf(keep[j]), keep[j])) {
            logger.error("(f) rate_base carries the baseline UNCHANGED; " +
                         keep[j] + " came back as " +
                         StrongRowView.rateBaseOf(keep[j]));
            return false;
        }
    }
    return true;
}

// THE RECORDED INPUTS REPRODUCE THE PUBLISHED RATE.
//
// This is the property #149 actually needs, and it is the one an encoding can
// silently break: whatever transform stands between the detector's state and the
// file must not map two states the GATE reads differently onto one number. If it
// does, an analyst replaying the decision from the file gets a different answer
// from the one the athlete's watch gave, on precisely the rows these fields exist
// to explain.
//
// Asserted as an EQUALITY BETWEEN TWO CALLS OF THE SHIPPING gatedRate over a
// swept state space -- never by re-deriving the gate here, which would pin this
// case's own arithmetic and nothing else.
//
// THE SWEEP IS CHECKED FOR BEING NON-VACUOUS, and that guard is load-bearing
// rather than decorative: over a state space in which the gate never fires and
// never snaps, "the replay agrees" holds for any encoding whatsoever, including
// one that discarded the baseline entirely.
(:test) function test_lock_theRecordedInputsReproduceThePublishedRate(logger) {
    // Medians spanning the band plus the no-median 0.0; baselines spanning
    // nothing-established, under the gate floor, #149's two measured rows
    // (15.2 and 20.3 spm) and the ceiling; lock periods spanning no-lock and
    // the four corners of the estimator's own range.
    var raws  = [0.0, $.MIN_RATE, 15.0, 20.3, 22.0, 25.0, 29.0, 30.0, 38.0,
                 $.MAX_RATE];
    var bases = [0.0, $.MIN_RATE, 12.0, 13.3, 15.2, 20.0, 20.3, 25.0,
                 $.MAX_RATE];
    var acs   = [0.0, 1.5, 3.0, 4.0, 10.0];

    var fired = 0;     // the gate zeroed a reading
    var snapped = 0;   // the lock corrected a reading
    for (var i = 0; i < raws.size(); i++) {
        for (var j = 0; j < bases.size(); j++) {
            // THE THRESHOLD ITSELF, first: the value that reaches the file must
            // select the SAME gate the app used. rateBaseOf's `<= 0.0` test is
            // fastGate's own absence predicate, and this is where that identity
            // is pinned rather than left to be noticed.
            var gWas = StrongRowView.fastGate(bases[j]);
            var gRec = StrongRowView.fastGate(
                StrongRowView.rateBaseOf(bases[j]));
            if (!Lock.near(gWas, gRec)) {
                logger.error("a baseline of " + bases[j] + " gave the app a " +
                             "gate of " + gWas + ", but the value recorded for " +
                             "it (" + StrongRowView.rateBaseOf(bases[j]) +
                             ") reconstructs a gate of " + gRec + ". The " +
                             "threshold is not recoverable from the file, " +
                             "which is the whole reason rate_base is recorded " +
                             "instead of inferred");
                return false;
            }
            for (var k = 0; k < acs.size(); k++) {
                var published = StrongRowView.gatedRate(raws[i], acs[k],
                                                        bases[j]);
                var replayed  = StrongRowView.gatedRate(
                    StrongRowView.rateRawOf(raws[i]), acs[k],
                    StrongRowView.rateBaseOf(bases[j]));
                if (!Lock.near(published, replayed)) {
                    logger.error("replaying the decision from what the FILE " +
                                 "carries disagrees with what the app " +
                                 "published: raw=" + raws[i] + " acPeriod=" +
                                 acs[k] + " base=" + bases[j] +
                                 " published " + published + ", replay gave " +
                                 replayed);
                    return false;
                }
                if (raws[i] > 0.0 && published == 0.0)      { fired++; }
                if (published > 0.0 && published != raws[i]) { snapped++; }
            }
        }
    }

    // THE NON-VACUITY GUARD. Both outcomes must actually occur in the sweep, or
    // the equality above was proven over a state space in which the encodings
    // could not have mattered.
    if (fired == 0) {
        logger.error("the sweep never made the gate ZERO a reading, so the " +
                     "agreement above says nothing about the case rate_raw " +
                     "exists for -- a reading the gate rejected, invisible in " +
                     "row_stroke_rate");
        return false;
    }
    if (snapped == 0) {
        logger.error("the sweep never made the lock SNAP a reading, so the " +
                     "agreement above says nothing about the other way " +
                     "row_stroke_rate hides its input");
        return false;
    }
    return true;
}

// -- c10: the gate-input differentials ----------------------------------------
//
// BOTH CASES BELOW ARE RED AGAINST c9 AND GREEN ONLY AT c11. The two handles
// exist at c9 and stay null; onTick does not know about them, so the recording
// stand-ins tickProbe installs receive nothing and `last()` is null.
//
// WHAT THESE CASES OBSERVE, at the strength the evidence supports and no
// further -- the same scope note the c5 pair carries, because the temptation to
// overreach is the same: the ARGUMENT of an in-app setData call. They say
// nothing about what lands in the file's bytes and nothing about what a decoder
// renders. Those need a simulator session and a decode, and no (:test) in this
// repository can obtain either.

// THE TICK RECORDS THE GATE'S OWN INPUTS.
//
// The state under test is #149's, exactly: a rower established near the choppy
// row's 15.2 spm, a 25.0 spm median, and no lock to corroborate it. The gate
// zeroes it, so row_stroke_rate carries 0.0 -- and THAT NUMBER ON ITS OWN IS
// THE PROBLEM. It is the same 0.0 a tick with no median produces, so the
// recording shows the symptom and never the mechanism, which is the situation
// #149 was filed to escape.
(:test) function test_lock_theTickRecordsTheGatesOwnInputs(logger) {
    var f = Lock.fields();
    var p = Lock.tickProbe(f);
    // Established through the SHIPPING registerStroke, not assigned: what the
    // gate keys on has to be what the detector really built.
    p.rowAt(15.0, 8);
    p.setDetector(25.0, 0.0);
    p.runTick();

    // (a) SETUP, AND THE AMBIGUITY. row_stroke_rate carries 0.0 for a reading
    // the gate rejected.
    if (!Lock.near(f[5].last(), 0.0)) {
        logger.error("setup: a 25.0 spm median with no lock, against a 15.0 " +
                     "spm baseline, must be ZEROED by the gate -- otherwise " +
                     "this case is not observing the state #149 is about. " +
                     "row_stroke_rate carries " + f[5].last());
        return false;
    }

    // (b) THE PRE-GATE MEDIAN. Without it the 0.0 above is unreadable.
    if (f[3].last() == null) {
        logger.error("rate_raw was never written. Record-scope fields LATCH, " +
                     "so a field this app declares and does not write carries " +
                     "the type's never-set pattern before the first write and " +
                     "then re-emits whatever it last held -- an unwritten " +
                     "diagnostic is not a quiet diagnostic");
        return false;
    }
    if (!Lock.near(f[3].last(), 25.0)) {
        logger.error("rate_raw must carry the median the gate was GIVEN " +
                     "(25.0), which is the number row_stroke_rate discards; " +
                     "got " + f[3].last());
        return false;
    }

    // (c) AND THE THRESHOLD'S INPUT. Not reconstructible offline: nextRateBase
    // consumes the pre-gate median, so the recursion cannot be replayed from a
    // file, and the zeroed and snapped cases discard the median outright so the
    // output cannot be inverted either.
    if (f[4].last() == null) {
        logger.error("rate_base was never written, so the gate's own " +
                     "threshold at this instant is unknown and unrecoverable " +
                     "-- the same latch argument as rate_raw above applies");
        return false;
    }
    if (!Lock.near(f[4].last(), 15.0)) {
        logger.error("rate_base must carry the established baseline the gate " +
                     "keys on (15.0); got " + f[4].last());
        return false;
    }

    // (d) THE THREE READ TOGETHER ANSWER #149's QUESTION, and this leg is what
    // separates "two numbers were written" from "the mechanism is now
    // recoverable". Every step is a call into the SHIPPING statics on values
    // taken from the recording stand-ins -- nothing is re-derived here.
    if (!Lock.near(f[0].last(), $.LOCK_RATE_NONE)) {
        logger.error("(d) lock_rate must say NO LOCK for this state, or the " +
                     "replay below is reconstructing a decision that was not " +
                     "taken; got " + f[0].last());
        return false;
    }
    var gate = StrongRowView.fastGate(f[4].last());
    if (!(f[3].last() > gate)) {
        logger.error("(d) the recorded pair must SHOW the gate firing: " +
                     "rate_raw (" + f[3].last() + ") above the threshold " +
                     "rate_base reconstructs (" + gate + "). It does not, so " +
                     "a reader still cannot tell a rejected reading from a " +
                     "tick with no median");
        return false;
    }
    var replay = StrongRowView.gatedRate(f[3].last(), 0.0, f[4].last());
    if (!Lock.near(replay, f[5].last())) {
        logger.error("(d) replaying the output stage from what the FILE " +
                     "carries must give what row_stroke_rate carries; replay " +
                     "gave " + replay + " against a recorded " + f[5].last());
        return false;
    }
    return true;
}

// THE GATE INPUTS ARE RECORDED AS STATES, NOT AS SILENCE.
//
// THE LOAD-BEARING CASE, and the trap is the one part 1 already walked into
// once: the obvious implementation writes a rate only when there IS one, which
// reads as caution. Record-scope FitContributor fields LATCH -- a skipped
// setData re-emits the previous value on the next record (#36, byte level) --
// so on the rows these fields exist to explain, that implementation keeps
// re-emitting the last median and the last baseline and reports rowing that
// stopped minutes ago.
//
// The stop is driven through the SHIPPING stroke-ring timeout in onSensorData,
// which clears BOTH quantities together, rather than by assigning zeros: it is
// the state a real row ends in, and it is the one where a latched median is
// most obviously a lie.
(:test) function test_lock_theGateInputsAreRecordedAsStatesNotAsSilence(logger) {
    var f = Lock.fields();
    var p = Lock.tickProbe(f);

    // A real row first, so there is something to latch.
    p.rowAt(15.0, 8);
    p.runTick();
    if (!Lock.near(f[3].last(), 15.0) || !Lock.near(f[4].last(), 15.0)) {
        logger.error("setup: the first tick must record the 15.0 spm median " +
                     "and baseline; rate_raw=" + f[3].last() + " rate_base=" +
                     f[4].last());
        return false;
    }

    // Then the athlete stops. 4.0 s periods put the ring timeout at 8.8 s and
    // the last stroke landed at t = 28.0 s on the detector's synthetic clock
    // (mSampleIdx * mDt, mDt = 1/REQ_RATE = 0.04 s), so 1200 quiet samples take
    // that clock to 48.0 s and clear the ring with margin. NOT
    // System.getTimer(): this clock counts the samples this case feeds, so it
    // reads the same on a seconds-old CI simulator and an hours-old desktop one.
    p.feedQuiet(48, 25);
    if (p.rawRate() != 0.0 || p.rateBase() != 0.0) {
        logger.error("setup: 48 s of quiet must clear both the median and the " +
                     "baseline through the shipping timeout, or the leg below " +
                     "is asserting about a state it never reached. median=" +
                     p.rawRate() + " baseline=" + p.rateBase());
        return false;
    }
    p.runTick();

    if (!Lock.near(f[3].last(), $.RATE_RAW_NONE)) {
        logger.error("after the athlete stops, rate_raw must carry the " +
                     "no-median encoding " + $.RATE_RAW_NONE + "; it carries " +
                     f[3].last() + ". If that is the previous 15.0, the write " +
                     "was SKIPPED -- and a skipped write on a record-scope " +
                     "field re-emits the last value, so the file would report " +
                     "a median the detector no longer had");
        return false;
    }
    if (f[3].vals.size() != 2) {
        logger.error("two ticks must produce two rate_raw writes; got " +
                     f[3].vals.size() + ". Withholding the write is the " +
                     "specific defect this case exists to catch: it does not " +
                     "leave a gap, it latches");
        return false;
    }
    if (!Lock.near(f[4].last(), $.RATE_BASE_NONE)) {
        logger.error("the ring timeout takes the established rate with it, so " +
                     "rate_base must carry " + $.RATE_BASE_NONE + " -- the " +
                     "state in which the gate falls back to " +
                     $.FAST_NEEDS_LOCK + ". It carries " + f[4].last() +
                     ", which reconstructs a gate of " +
                     StrongRowView.fastGate(f[4].last()));
        return false;
    }
    if (f[4].vals.size() != 2) {
        logger.error("two ticks must produce two rate_base writes; got " +
                     f[4].vals.size());
        return false;
    }
    return true;
}

// ---- end of `module Lock` -------------------------------------------------
// -- D3, c0: the pre-START carry-over as it ships -----------------------------
//
// THE DEFECT. onLayout registers the accelerometer at APP LAUNCH, registerStroke
// has no mStarted gate, and nothing on the recording-start path touches detector
// state -- so boat handling before START fills the stroke-period ring and
// establishes mRateBase, and the first frame of the session is judged against
// it. Measured on i183553852 (2026-09-05, v0.9): the FIRST record of the
// session, with enhanced_speed 0.00 and native cadence 0 -- a stationary boat --
// carries rate_base 29.57, rate_raw 28.85 and row_stroke_rate 28.85. The app
// displayed 28.8 spm for a boat that had not moved.
//
// Both cases here are green before the fix and green after it. They pin the
// parts that do NOT move, and the second one is load-bearing for the honesty of
// the claim rather than for its correctness.

// PRE-START STROKES STILL REACH THE DETECTOR. The fix clears the carry-over at
// START; it does not gate the listener, and a gate would be the wrong change --
// the detector needs its warm-up to have a lock at all by the time the athlete
// starts rowing.
(:test) function test_lock_c0_preStartStrokesStillReachTheDetector(logger) {
    var p = new Lock.Probe();
    // No enterStep, no start of any kind: this is the app sitting on the
    // watch face with the accelerometer listener already registered.
    p.rowAt(28.0, 12);
    if (!(p.rawRate() > 0.0)) {
        logger.error("registerStroke has no mStarted gate and must not acquire " +
                     "one: twelve strokes at 28.0 spm before START must still " +
                     "produce a median. rawRate() is " + p.rawRate());
        return false;
    }
    if (!(p.rateBase() > 0.0)) {
        logger.error("the same strokes must still establish the baseline " +
                     "through the shipping nextRateBase; rateBase() is " +
                     p.rateBase());
        return false;
    }
    return true;
}

// THE GATE SATURATES AT THE ABSOLUTE FOR EVERY BASELINE FROM 20.0 SPM UP.
//
// WHAT THIS CASE ASSERTS, AND WHAT IT DOES NOT. It asserts an ARITHMETIC
// IDENTITY and nothing else: fastGate is
// min(FAST_NEEDS_LOCK, max(LOCK_GATE_FLOOR, LOCK_REL_K * base)), the shipped
// LOCK_REL_K * 20.0 is exactly FAST_NEEDS_LOCK, so for every base at or above
// 20.0 the gate IS the absolute and is identical to the gate with no baseline at
// all. 22.68 and 29.57 appear below as two of five INPUTS to that identity. This
// case says nothing whatever about what any recording did.
//
// RETRACTION, because this header said otherwise for one revision and credited
// this case with it. It read "On the recording above, rate_base never fell below
// 22.68 during the first work interval, so zeroing it would have changed no gate
// decision on that file." Measured since, from a fixture that did not exist when
// that was written (scripts/fixtures/start_carryover.txt, printed by
// scripts/start_witness.py):
//   * 22.6813 is the baseline at that interval's FIRST second. The MINIMUM over
//     the interval is 15.2863.
//   * So the identity above does NOT cover the interval: fastGate was strictly
//     below the absolute on 148 of its 181 seconds, as low as 22.9295 spm.
//   * The conclusion nevertheless holds, for a different reason: fastGate is
//     read only on gatedRate's NO-LOCK branch, all 148 of those seconds carried
//     a lock, and on zero of them did the tightened bar change a published
//     value. scripts/test_start_witness.py C3 and C4 pin both halves.
//
// So: what published the 28.8 was the stroke-period RING, which held pre-START
// periods and gave mRate a median to publish. The baseline half of the reset is
// for the case that file does NOT show -- a SLOW pre-START handling cadence
// establishing a base below 20.0 on a row whose work is not lock-corroborated,
// where fastGate does bind, is consulted, and would zero genuine rowing.
(:test) function test_lock_c0_theGateSaturatesForAnyBaselineFromTwentyUp(logger) {
    var saturating = [20.0, 22.68, 25.0, 29.57, 40.0];
    for (var i = 0; i < saturating.size(); i++) {
        var g = StrongRowView.fastGate(saturating[i]);
        if (!Lock.near(g, $.FAST_NEEDS_LOCK)) {
            logger.error("a baseline of " + saturating[i] + " spm gives gate " +
                         g + ", expected the absolute FAST_NEEDS_LOCK (" +
                         $.FAST_NEEDS_LOCK + "). LOCK_REL_K * 20.0 is exactly " +
                         "FAST_NEEDS_LOCK, so the relative term cannot exceed " +
                         "the absolute from 20.0 up");
            return false;
        }
        if (!Lock.near(g, StrongRowView.fastGate(0.0))) {
            logger.error("a baseline of " + saturating[i] + " gives " + g +
                         " and NO baseline gives " + StrongRowView.fastGate(0.0) +
                         " -- these must be equal, which is why clearing a HIGH " +
                         "inherited baseline changes no gate decision");
            return false;
        }
    }
    // And the case where it does bind: below the knee the gate is strictly
    // tighter than the absolute, which is the failure the reset is really for.
    var slow = StrongRowView.fastGate(8.0);
    if (!(slow < $.FAST_NEEDS_LOCK)) {
        logger.error("an 8.0 spm baseline -- a pre-START handling cadence -- " +
                     "must gate strictly below the absolute, or the reset has " +
                     "nothing to protect; gate is " + slow);
        return false;
    }
    return true;
}

// -- D3, c1: the reset seam, called directly ----------------------------------
//
// resetStrokeBaseline() exists at this commit and is NOT wired to anything. That
// is deliberate: the differential that matters is the WIRING -- does a recording
// start actually reach it -- and it has to be shown red before it is shown
// green. This case pins what the function does when it is called, so that when
// the wiring lands there is no doubt about which half moved.
(:test) function test_lock_c1_theResetSeamEmptiesTheEstimator(logger) {
    var p = new Lock.Probe();
    p.rowAt(28.0, 12);
    if (!(p.rawRate() > 0.0 && p.rateBase() > 0.0 && p.ringCount() > 0)) {
        logger.error("setup: twelve strokes at 28.0 spm must leave a median (" +
                     p.rawRate() + "), a baseline (" + p.rateBase() +
                     ") and a non-empty ring (" + p.ringCount() + ")");
        return false;
    }

    p.resetBaseline();

    if (p.rateBase() != 0.0) {
        logger.error("the established baseline must be gone; rateBase() is " +
                     p.rateBase());
        return false;
    }
    if (p.ringCount() != 0 || p.ringIdx() != 0) {
        logger.error("the stroke-period ring must be EMPTY, not merely " +
                     "overwritten: count is " + p.ringCount() + ", index is " +
                     p.ringIdx() + ", both expected 0");
        return false;
    }
    if (p.rawRate() != 0.0) {
        logger.error("the median goes with the ring it was built from; " +
                     "rawRate() is " + p.rawRate());
        return false;
    }
    if (p.out() != 0.0) {
        logger.error("and so the SHIPPING outputRate() publishes nothing, " +
                     "which is what drawRate renders as \"--.-\"; out() is " +
                     p.out());
        return false;
    }
    if (!(p.lastStrokeT() < -50.0)) {
        logger.error("mLastStrokeT must be back at resetDetector's " +
                     "\"no previous stroke\" sentinel, or the first stroke " +
                     "after the reset forms a period with the last one before " +
                     "it -- exactly the carry-over being removed. lastStrokeT()" +
                     " is " + p.lastStrokeT());
        return false;
    }
    if (p.lastPeriod() != 0.0 || p.baseHold() != 0) {
        logger.error("lastPeriod() is " + p.lastPeriod() + " and baseHold() is " +
                     p.baseHold() + ", both expected 0: the ring timeout must " +
                     "go back to its default window and the baseline must be " +
                     "free to build from the first post-reset stroke");
        return false;
    }

    // AND IT IS A BOUNDARY, NOT A KILL SWITCH: strokes after it rebuild
    // everything through the shipping path, and TWO are needed -- the first
    // only sets mLastStrokeT.
    p.rowFrom(24.0, 1, 100.0);
    if (p.ringCount() != 0 || p.out() != 0.0) {
        logger.error("one stroke after the reset forms no period, so the " +
                     "numeral is still \"--.-\"; ringCount() is " +
                     p.ringCount() + ", out() is " + p.out());
        return false;
    }
    p.rowFrom(24.0, 1, 100.0 + 60.0 / 24.0);
    if (p.ringCount() != 1 || !Lock.near(p.out(), 24.0)) {
        logger.error("the SECOND stroke forms the first period and the numeral " +
                     "comes back at the rate actually rowed since START; " +
                     "ringCount() is " + p.ringCount() + ", out() is " +
                     p.out() + ", expected 1 and 24.0");
        return false;
    }
    return true;
}

// -- D3, c2: the differentials for the START boundary --------------------------
//
// RED before the wiring, green after it. The wiring is ONE line -- a call to
// resetStrokeBaseline() from beginSessionAccum() -- and these three cases are
// the whole of what it changes.
//
// WHY beginSessionAccum() AND NOT startSession(). Three reasons, and the third
// is the one that decided it:
//   * it is the function this file already describes as the one "every
//     recording-start path calls" (see beginWorkAccum's caller note), and it is
//     called exactly once per recording start -- from onPrimary's free-row arm,
//     from startWorkout, and from initialize where it is a no-op because
//     resetDetector has just run;
//   * it leaves startSession() untouched, so a branch in flight that edits
//     startSession has nothing to merge here rather than one line to merge;
//   * startSession() IS NOT REACHABLE FROM A (:test) -- it calls
//     Rec.createSession -- so a probe has to stub it to drive the start path at
//     all, and a reset placed inside it would be stubbed out with it and pinned
//     by nothing. That is the trap this repository names: a test that does not
//     call the shipping code pins nothing.

// THE BASELINE DOES NOT SURVIVE A RECORDING START.
(:test) function test_lock_c2_startingASessionDropsThePreStartBaseline(logger) {
    var p = new Lock.Probe();
    // Boat handling before START: real strokes through the shipping
    // registerStroke, at the rate the recording shows the detector believing on
    // a stationary boat.
    p.rowAt(28.0, 12);
    var before = p.rateBase();
    if (!(before > 0.0)) {
        logger.error("setup: pre-START strokes must have established a " +
                     "baseline for there to be anything to drop; rateBase() " +
                     "is " + before);
        return false;
    }

    p.beginAccum();

    if (p.rateBase() != 0.0) {
        logger.error("a recording start must judge itself against nothing " +
                     "inherited: the baseline established before START was " +
                     before + " and is still " + p.rateBase() + ", expected " +
                     "0.0. On i183553852 that carried 29.57 spm out of a " +
                     "stationary boat and into the first work interval");
        return false;
    }
    return true;
}

// AND NEITHER DOES THE STROKE-PERIOD RING, which is the half that actually put
// a number on the screen.
(:test) function test_lock_c2_startingASessionEmptiesTheStrokeRing(logger) {
    var p = new Lock.Probe();
    p.rowAt(28.0, 12);
    if (!(p.ringCount() > 0 && p.out() > 0.0)) {
        logger.error("setup: twelve pre-START strokes must fill the ring (" +
                     p.ringCount() + ") and publish a rate (" + p.out() + ")");
        return false;
    }

    p.beginAccum();

    if (p.ringCount() != 0 || p.ringIdx() != 0) {
        logger.error("the ring must be empty at START, not merely overwritten " +
                     "as later strokes arrive: count " + p.ringCount() +
                     ", index " + p.ringIdx());
        return false;
    }
    if (p.out() != 0.0) {
        logger.error("and so the SHIPPING outputRate() must publish nothing " +
                     "-- drawRate renders that as \"--.-\" and the FIT " +
                     "records the app's own no-data 0.0, instead of the 28.8 " +
                     "spm a stationary boat produced. out() is " + p.out());
        return false;
    }
    if (!(p.lastStrokeT() < -50.0)) {
        logger.error("mLastStrokeT must be back at the \"no previous stroke\" " +
                     "sentinel, or the FIRST stroke after START still forms a " +
                     "period with the LAST one before it and exactly one " +
                     "pre-START period survives; lastStrokeT() is " +
                     p.lastStrokeT());
        return false;
    }
    return true;
}

// THROUGH THE REAL START PATH, which is what separates "the seam works" from
// "the app reaches it".
//
// startWorkout() is the shipping function, driven with only startSession()
// neutralised. Deleting the one wiring line leaves the two cases above green if
// they were written against resetStrokeBaseline() directly -- this is the one
// that cannot be satisfied any other way.
(:test) function test_lock_c2_theRealStartPathClearsTheCarryOver(logger) {
    var p = new Lock.Probe();
    p.rowAt(28.0, 12);
    if (!(p.rateBase() > 0.0 && p.ringCount() > 0)) {
        logger.error("setup: nothing established before START");
        return false;
    }

    p.startWorkoutLive();

    if (p.rateBase() != 0.0 || p.ringCount() != 0 || p.out() != 0.0) {
        logger.error("the SHIPPING startWorkout() must leave the estimator " +
                     "empty: rateBase() " + p.rateBase() + ", ringCount() " +
                     p.ringCount() + ", outputRate() " + p.out() +
                     ", all expected 0. The first work interval is judged " +
                     "against what the athlete rows in it, not against what " +
                     "the boat was doing on the way to the start");
        return false;
    }

    // AND THE START ITSELF STILL HAPPENED. A wiring that reset the estimator by
    // making startWorkout bail early would satisfy every line above.
    if (!p.isStarted()) {
        logger.error("startWorkout() must still have started the recording; " +
                     "mStarted is false");
        return false;
    }
    return true;
}

}
