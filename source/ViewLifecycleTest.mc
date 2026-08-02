using Toybox.Test;
using Toybox.Graphics as Gfx;

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
    var log;         // shared ordered event log owned by the probe, or null
    function initialize(sharedLog) { closes = 0; log = sharedLog; }
    function close() {
        closes++;
        // Ordered, not just counted: #103 latches its ANT diagnostics at
        // close() precisely because shutdown() calls close() BEFORE
        // stopAndSave(), so the relative order is a contract another PR
        // depends on and not an implementation detail.
        if (log != null) { log.add("close"); }
    }
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
//
// CALL-SITE CAST, and why every one of them carries it. onLayout inherits
// `(dc as Graphics.Dc)` from Ui.View, and monkeyc enforces that parameter type
// with no -l typecheck level -- the same trap DspTimeBaseTest.mc:31-37
// documents for onSensorData, so `p.onLayout(null)` is rejected with
// "Invalid 'Null' passed as parameter 1 of type '$.Toybox.Graphics.Dc'".
// The cast is erased at runtime; only duck typing applies there, and onLayout
// never touches dc.
//
// The enforcement is NOT uniform across call sites, which is why the rule here
// is "cast every one" rather than "cast the ones that complain". Measured on
// SDK 9.2.0 / fr965: an earlier revision of this file with three uncast call
// sites compiled clean (and passed CI on all 12 devices); adding four more
// tests made the compiler reject seven of the ten -- including two that had
// just compiled unchanged. The selection rule is unknown and is not guessed at
// here. Casting unconditionally makes the file independent of it.

class LifeProbe extends StrongRowView {
    var madeTimers;    // every LifeTimer handed to the shipping code, in order
    var madeSensors;   // every LifeCoreSensor handed to the shipping code
    var events;        // ordered "close" / "save" log across the teardown path
    var saves;         // stopAndSave() call count
    var sensorAtSave;  // was mCoreSensor still readable when stopAndSave ran?
    var timerAtSave;   // ditto for mTimer

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
        if (events == null) { events = []; }
        var s = new LifeCoreSensor(events);
        madeSensors.add(s);
        return s;
    }

    // Records the teardown ORDER and the state visible AT readout time, then
    // runs the real body. stopAndSave() is where every session-scope field is
    // written, and what those writes can still reach is decided by what
    // shutdown() has already cleared -- which is the whole of the #103
    // interaction this probe exists to pin.
    function stopAndSave() {
        if (events == null) { events = []; }
        events.add("save");
        saves = (saves == null) ? 1 : saves + 1;
        sensorAtSave = (mCoreSensor != null);
        timerAtSave  = (mTimer != null);
        StrongRowView.stopAndSave();
    }

    // The two handles #11 is about. Read, never written, from the tests.
    function timerHandle()  { return mTimer; }
    function sensorHandle() { return mCoreSensor; }

    function timerCount()  { if (madeTimers  == null) { madeTimers  = []; } return madeTimers.size(); }
    function sensorCount() { if (madeSensors == null) { madeSensors = []; } return madeSensors.size(); }
    function timerAt(i)    { return madeTimers[i]; }
    function sensorAt(i)   { return madeSensors[i]; }

    function saveCount()          { return (saves == null) ? 0 : saves; }
    function sensorLiveAtSave()   { return sensorAtSave == true; }

    // Index of the first occurrence of `what` in the teardown log, or -1.
    function eventIndex(what) {
        if (events == null) { return -1; }
        for (var i = 0; i < events.size(); i++) {
            if (events[i].equals(what)) { return i; }
        }
        return -1;
    }
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
    p.onLayout(null as Gfx.Dc);

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
    p.onLayout(null as Gfx.Dc);

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
    p.onLayout(null as Gfx.Dc);
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

// -- #11 red differentials ----------------------------------------------------
// The four below are the whole point. All fail against onLayout/shutdown as
// they stand and pass once the guards land. Nothing else in the suite moves
// between those two epochs.
//
// Each drives onLayout TWICE. That is a direct exercise of the callback's
// idempotency contract and does not depend on whether Connect IQ can actually
// re-invoke it -- a question this repository has NOT settled in either
// direction (see the header, and the [Local] issue linked from #11). The
// contract is correct under either answer.

// THE defect, in its strongest form: a second onLayout must not construct a
// second Timer AT ALL.
//
// The count is pinned at 1 rather than merely requiring that no orphan survives,
// because that also fixes WHICH resolution is correct. #11 offers two -- guard,
// or tear down and reallocate -- and this file chooses guard. Rebuilding
// mid-row is the wrong one for the sensor (it would release a tracking ANT
// channel and reset the CoreTempSensor.mc:341-348 retry ladder, trading a leak
// for a data dropout), and the timer is guarded the same way for the same
// reason: preserving the live instance is what "idempotent" has to mean for a
// callback that may re-fire during a recording. A future change to
// tear-down-and-rebuild is a design reversal, and it should have to red a test
// and argue for itself rather than pass quietly.
(:test) function test_life_repeatOnLayoutMakesOneTimer(logger) {
    var p = new LifeProbe();
    p.onLayout(null as Gfx.Dc);
    p.onLayout(null as Gfx.Dc);

    if (p.timerCount() != 1) {
        logger.error("#11: a repeat onLayout constructed " + p.timerCount() +
                     " timers; the first is orphaned (shutdown stops only the " +
                     "newest), so onTick runs at 2x and mCorrAccum -- and with " +
                     "it total_corrective_strokes -- doubles");
        return false;
    }
    if (p.timerHandle() != p.timerAt(0)) {
        logger.error("#11: the view must still hold the timer it made first");
        return false;
    }
    return true;
}

// The sensor half. Each CoreTempSensor owns an ANT channel
// (CoreTempSensor.mc:71 -> openChannel), and an orphaned one keeps searching
// and receiving with its onMessage callback live, because close() is only ever
// called on whatever mCoreSensor points at when shutdown() runs.
(:test) function test_life_repeatOnLayoutMakesOneCoreSensor(logger) {
    var p = new LifeProbe();
    p.onLayout(null as Gfx.Dc);
    p.onLayout(null as Gfx.Dc);

    if (p.sensorCount() != 1) {
        logger.error("#11: a repeat onLayout constructed " + p.sensorCount() +
                     " CoreTempSensors; each holds an ANT channel and only the " +
                     "newest is ever close()d, so the rest leak for the app run");
        return false;
    }
    if (p.sensorHandle() != p.sensorAt(0)) {
        logger.error("#11: the view must still hold the sensor it made first");
        return false;
    }
    return true;
}

// The same defect stated as a PROPERTY rather than a count, deliberately
// duplicating coverage. If someone later argues for tear-down-and-rebuild, the
// count test above reds and this one stays green -- which tells a reader that a
// design choice was reversed, not that #11 regressed. Phrased the way
// test_dsp_timeBaseInvariantToBatchSize is, for the same reason.
(:test) function test_life_repeatOnLayoutLeavesNoOrphanTimer(logger) {
    var p = new LifeProbe();
    p.onLayout(null as Gfx.Dc);
    p.onLayout(null as Gfx.Dc);

    var live = 0;
    var heldIsLive = false;
    for (var i = 0; i < p.timerCount(); i++) {
        var t = p.timerAt(i);
        if (t.starts > 0 && t.stops == 0) {
            live++;
            if (p.timerHandle() == t) { heldIsLive = true; }
        }
    }

    var ok = true;
    if (live != 1) {
        logger.error("#11: " + live + " started-and-never-stopped timers after " +
                     "two onLayout calls; every one past the first drives onTick " +
                     "forever and no reference survives to stop it");
        ok = false;
    }
    if (!heldIsLive) {
        logger.error("#11: the timer the view holds is not the live one, so " +
                     "shutdown cannot stop what is actually running");
        ok = false;
    }
    return ok;
}

// The near neighbour, and the reason the guard alone is not the whole fix.
// shutdown() releases both resources but leaves the dead handles in the fields.
// Once onLayout is guarded on those fields, "non-null" has to mean "live" or
// the guard reads a stopped timer as a running one and declines to allocate --
// leaving ZERO live timers where the unfixed code left two. That is #11's
// mirror image, reachable under exactly the same unverified condition, so both
// halves ship together.
//
// This asserts only that the handles are CLEARED.
// test_life_shutdownReleasesTheLiveResources above asserts that the resources
// were RELEASED first, and it reads the recorded stubs rather than these
// fields precisely so the two cannot be satisfied by nulling without releasing.
// The CROSS-PR interaction, and the one nothing else in either suite can see.
//
// shutdown() clears mCoreSensor, and stopAndSave() is where every session-scope
// field is written. If the clear happens BEFORE stopAndSave(), then any
// session-scope write that needs the sensor is silently skipped -- the field
// handle is non-null, the session saves, and the value is simply never written.
//
// That is not hypothetical. #103 adds
//     if (mFitCtDiag != null && mCoreSensor != null) {
//         mFitCtDiag.setData(mCoreSensor.diagSnapshot());
//     }
// to stopAndSave(), and latches its flags at close() *because* shutdown()
// calls close() before stopAndSave() (CoreTempSensor.mc, "Flags latched at
// close(), because shutdown() calls close() BEFORE stopAndSave()"). Clearing
// the handle first defeats that accommodation exactly on the app-stop exit --
// the one that does NOT go through BACK, and therefore the entire reason
// shutdown() calls stopAndSave() at all. Measured on the merged tree: the BACK
// path wrote ct_diag, the onStop path wrote nothing, and both trees compiled
// clean and passed their full suites.
//
// So the ordering contract is three-part, and all three are pinned here:
//   1. close() still precedes stopAndSave()      -- #103's latch depends on it
//   2. the handle is still READABLE during stopAndSave() -- the readout needs it
//   3. the handle is null once shutdown() RETURNS -- #11's "non-null means live"
// Only (2) moves between epochs. (1) and (3) are pinned alongside it because a
// "fix" that satisfied (2) by moving close() after the save, or by not clearing
// at all, would break the other two.
//
// Neither PR's suite can catch this alone: this file has no ct_diag and #103's
// has no lifecycle probe. It is pinned on THIS side because the ordering
// constraint is shutdown()'s to keep.
(:test) function test_life_shutdownKeepsSensorReadableUntilSaved(logger) {
    var p = new LifeProbe();
    p.onLayout(null as Gfx.Dc);
    p.shutdown();

    if (p.saveCount() != 1) {
        logger.error("shutdown must reach stopAndSave exactly once, got " +
                     p.saveCount() + " -- the assertions below read its state");
        return false;
    }

    var ok = true;
    var iClose = p.eventIndex("close");
    var iSave  = p.eventIndex("save");
    if (iClose < 0 || iSave < 0 || iClose > iSave) {
        logger.error("close() must still precede stopAndSave(): #103 latches " +
                     "its ANT diagnostics at close() for exactly that reason " +
                     "(close idx " + iClose + ", save idx " + iSave + ")");
        ok = false;
    }
    if (!p.sensorLiveAtSave()) {
        logger.error("mCoreSensor was already null when stopAndSave() ran, so " +
                     "any session-scope field read from the sensor there is " +
                     "silently skipped -- #103's ct_diag is lost on the " +
                     "app-stop exit, the one that does not go through BACK. " +
                     "Clear the handle AFTER stopAndSave(), not before");
        ok = false;
    }
    if (p.sensorHandle() != null) {
        logger.error("the handle must still be null once shutdown() returns, " +
                     "or onLayout's guard reads a closed sensor as live");
        ok = false;
    }
    return ok;
}

(:test) function test_life_shutdownClearsTheHandles(logger) {
    var p = new LifeProbe();
    p.onLayout(null as Gfx.Dc);
    p.shutdown();

    var ok = true;
    if (p.timerHandle() != null) {
        logger.error("#11: shutdown left a stopped Timer in mTimer; the " +
                     "onLayout guard would read it as live and never re-arm");
        ok = false;
    }
    if (p.sensorHandle() != null) {
        logger.error("#11: shutdown left a closed CoreTempSensor in " +
                     "mCoreSensor; the onLayout guard would read it as live " +
                     "and never re-open the ANT channel");
        ok = false;
    }
    return ok;
}
