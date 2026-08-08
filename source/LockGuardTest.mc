using Toybox.Test;
using Toybox.Lang;

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
//
// Execution note: the run-tests CI job runs these headlessly in the simulator on
// fr965. Test names are pinned in scripts/expected_tests.txt -- update that file
// in the SAME commit as any (:test) change here. See docs/CI.md.

// -- Fixture ------------------------------------------------------------------
// One module, one member of `globals`. See the ceiling note above.
module Lock {

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

        // The shipping decision, called -- not transcribed.
        function out() { return outputRate(); }

        // Real strokes at a chosen cadence, through the SHIPPING
        // registerStroke() / recomputeRate() path, so whatever the detector
        // establishes from a steady row is established by the shipping code
        // and not assigned here.
        //
        // `spm` must lie inside registerStroke's accepted period band
        // [60/MAX_RATE, 60/MIN_RATE] = [1.5 s, 10 s], i.e. 6..40 spm, or the
        // periods are rejected and nothing is established at all.
        function rowAt(spm, strokes) {
            var per = 60.0 / spm;
            var t = 0.0;
            for (var i = 0; i < strokes; i++) {
                registerStroke(t);
                t += per;
            }
        }
    }

    // A probe with the detector at (spm, lock period) and nothing else
    // established -- a fresh view, so no rate history exists.
    function at(spm, acPeriod) {
        var p = new Probe();
        p.setDetector(spm, acPeriod);
        return p;
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

// ---- end of `module Lock` -------------------------------------------------
}
