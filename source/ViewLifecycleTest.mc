using Toybox.Test;
using Toybox.Graphics as Gfx;
using Toybox.Lang;

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
    var throwOnStop; // make stop() fail, to measure the unwind path
    function initialize() {
        starts = 0; stops = 0; lastMs = 0; lastRepeat = false;
        throwOnStop = false;
    }
    function start(cb, ms, repeat) {
        starts++; lastMs = ms; lastRepeat = repeat;
    }
    // Records FIRST, then fails: the call did happen, and a test asserting on
    // stops must not be unable to tell "never called" from "called and threw".
    function stop() {
        stops++;
        if (throwOnStop) { throw new Lang.Exception(); }
    }
}

// Stand-in for a FitContributor field handle. Only identity and non-nullness
// matter to the invariant tests; setData is present so nothing faults if a
// future test reaches a write.
class LifeField {
    var writes;
    function initialize() { writes = 0; }
    function setData(v) { writes++; }
}

class LifeCoreSensor {
    var closes;       // close() call count
    var log;          // shared ordered event log owned by the probe, or null
    var throwOnClose; // make close() fail, to measure the unwind path
    function initialize(sharedLog) {
        closes = 0; log = sharedLog; throwOnClose = false;
    }
    function close() {
        closes++;
        // Ordered, not just counted: #103 latches its ANT diagnostics at
        // close() precisely because shutdown() calls close() BEFORE
        // stopAndSave(), so the relative order is a contract another PR
        // depends on and not an implementation detail.
        if (log != null) { log.add("close"); }
        if (throwOnClose) { throw new Lang.Exception(); }
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
// NONE OF THE CASTS IS REDUNDANT, and that is measured rather than assumed.
// The root cause is that StrongRowView.onLayout(dc) is an UNANNOTATED override
// of Ui.View.onLayout(dc as Graphics.Dc). Measured on SDK 9.2.0 / fr965, with
// every call site in this file uncast:
//
//   * onLayout ANNOTATED `dc as Gfx.Dc`  -> all 11 call sites rejected,
//     uniformly. So every cast here is load-bearing; removing any one of them
//     would break the build the moment that annotation is added.
//   * onLayout UNANNOTATED (as it is today) -> 7 of the 11 rejected, and WHICH
//     seven is stable across rebuilds but not predictable from the call site:
//     the four accepted sites are byte-identical to rejected ones.
//
// The selection is keyed on the ENCLOSING FUNCTION'S NAME, which is a
// measurement and not a mechanism: renaming one test whose call site was
// accepted -- body and call site byte-identical, nothing else touched -- flips
// that site to rejected, reproducibly. That is why the rule here is "cast every
// one" rather than "cast the ones that complain": a later rename of an
// unrelated test would otherwise break the build for no visible reason.
//
// Annotating onLayout (and onUpdate, also unannotated) is the real fix and is
// deliberately NOT done in this PR -- it is a separate change with its own
// blast radius, tracked in #117. Widening the parameter instead is illegal:
// Monkey C rejects `Cannot override parameter 1 ... with type 'PolyType<Null
// or $.Toybox.Graphics.Dc>'`.

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

    // Stand up the two record-scope CORE field handles without a Session, so
    // the invariant that couples them to mCoreSensor is drivable. mSession is
    // deliberately left null: stopAndSave's body is then skipped entirely, so
    // nothing but the finally can clear these.
    function armCoreField() {
        mFitCore = new LifeField();
        mFitSkin = new LifeField();
    }
    function coreFieldHandle() { return mFitCore; }
    function skinFieldHandle() { return mFitSkin; }

    function saveCount()          { return (saves == null) ? 0 : saves; }
    function sensorLiveAtSave()   { return sensorAtSave == true; }
    function timerLiveAtSave()    { return timerAtSave == true; }

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
    // The mTimer half of the same contract, and it is the OPPOSITE of the
    // sensor's. Nothing in stopAndSave() reads mTimer, and the timer must be
    // stopped before any of the teardown runs, so it is cleared FIRST -- the
    // asymmetry is deliberate and is what the two constraints demand. Asserted
    // rather than merely recorded: without this, the symmetric form of the
    // #103 defect (something in stopAndSave growing a dependency on mTimer)
    // would red nothing here.
    if (p.timerLiveAtSave()) {
        logger.error("mTimer must already be cleared when stopAndSave() runs: " +
                     "it is stopped first so no onTick is scheduled during " +
                     "teardown, and nothing in stopAndSave reads it");
        ok = false;
    }
    return ok;
}

// Probes for the three points in shutdown() where a release call can fail.
// Each subclasses LifeProbe so every seam, stub and recorder is shared and only
// the failing call differs.
//
// SHUTDOWN HAS THREE UNWIND POINTS, not one, and each is its own defect if the
// teardown does not survive it:
//   mTimer.stop()      -- upstream of everything; a throw here skips the sensor
//                         close, the save, AND both clears
//   mCoreSensor.close() -- a throw here skips the save and the sensor clear
//   stopAndSave()      -- a throw here skips the sensor clear
// The tests below cover all three. Round 2 fixed only the third, which is how
// the first two survived into round 3.

class LifeThrowingSaveProbe extends LifeProbe {
    function initialize() { LifeProbe.initialize(); }
    function stopAndSave() {
        LifeProbe.stopAndSave();     // record the call, run the real body
        throw new Lang.Exception();  // then fail, as a throwing save would
    }
}

class LifeThrowingStopProbe extends LifeProbe {
    function initialize() { LifeProbe.initialize(); }
    hidden function makeTimer() {
        var t = LifeProbe.makeTimer();
        t.throwOnStop = true;
        return t;
    }
}

class LifeThrowingCloseProbe extends LifeProbe {
    function initialize() { LifeProbe.initialize(); }
    hidden function makeCoreSensor() {
        var s = LifeProbe.makeCoreSensor();
        s.throwOnClose = true;
        return s;
    }
}

// mTimer.stop() throwing. THE round-3 finding, and the third instance of one
// pattern in this function.
//
// Before the fix, `mTimer = null` sat inside the same block as `mTimer.stop()`,
// so the clear was conditional on stop() returning normally. A throw then:
//   * skipped the clear, so the guard this PR added to onLayout reads a stopped
//     Timer as live and NEVER re-arms -- zero live timers, permanently;
//   * propagated out of shutdown() from a point UPSTREAM of the round-2
//     try/finally, so the sensor close and stopAndSave() never ran at all --
//     the sensor is left non-null-but-live and THE ROW IS NEVER SAVED.
//
// On base main this was harmless: onLayout allocated unconditionally, so a
// throwing stop() left an orphan but recovery still worked. This PR is what
// converts "orphaned timer, recovery works" into "no timer ever again", so the
// unwind protection is this PR's to add -- the same argument, symmetric, that
// justified the sensor's finally in round 2.
//
// Asserts the OUTCOME (a later onLayout really does re-allocate), not just the
// proxy (handle is null). The proxy is what the guard reads, but re-arming is
// what the user gets.
(:test) function test_life_shutdownClearsTimerEvenIfStopThrows(logger) {
    var p = new LifeThrowingStopProbe();
    p.onLayout(null as Gfx.Dc);

    try {
        p.shutdown();
    } catch (e) {
        logger.error("a throwing stop() must not propagate out of shutdown: it " +
                     "is upstream of the save, so the row is lost as well");
        return false;
    }

    var ok = true;
    if (p.timerAt(0).stops != 1) {
        logger.error("stop() must still have been attempted once, got " +
                     p.timerAt(0).stops);
        ok = false;
    }
    if (p.timerHandle() != null) {
        logger.error("a throw in stop() skipped the clear: shutdown left a " +
                     "STOPPED Timer in mTimer, so onLayout's guard reads it as " +
                     "live and never re-arms -- ZERO live timers, permanently");
        ok = false;
    }
    if (p.saveCount() != 1) {
        logger.error("a throw in stop() skipped stopAndSave entirely -- the row " +
                     "is never saved. saveCount=" + p.saveCount());
        ok = false;
    }
    if (p.sensorHandle() != null) {
        logger.error("the sensor handle must be cleared too; a throw upstream " +
                     "of the try/finally skips that clear as well");
        ok = false;
    }
    // The outcome, not the proxy: recovery must actually work.
    p.onLayout(null as Gfx.Dc);
    if (p.timerCount() != 2) {
        logger.error("onLayout must re-arm after shutdown, timers made = " +
                     p.timerCount() + " (expected a second one)");
        ok = false;
    }
    return ok;
}

// The INVARIANT `mFitCore != null => mCoreSensor != null` on the throw path.
//
// coreFieldsWanted's null term exists to keep that invariant local to one line,
// and onTick dereferences mCoreSensor guarded ONLY by mFitCore. Round 2's
// try/finally made the invariant violable: a throw partway through
// stopAndSave(), before it reaches `mFitCore = null`, still runs the finally
// and clears mCoreSensor -- leaving mFitCore set and mCoreSensor null. A
// subsequent onTick is then a HARD FAULT, not a catchable exception, which is
// strictly worse than the exception that caused it.
//
// The fix clears the dependent field handles together with the sensor in the
// same finally, so they cannot be observed disagreeing. This test drives it
// with mSession null, so stopAndSave's body is skipped entirely and mFitCore
// is untouched by it -- isolating the finally as the only thing that can
// restore the invariant.
//
// This is a LISTED scope decision, not a smuggled one: review raised the stale
// comment as non-blocking and asked for the comment to be corrected. Fixing the
// hazard instead is a behaviour change beyond that, taken because the fix is
// two assignments in a finally this PR already added, and because the failure
// mode is an uncatchable fault. Flagged for review rather than assumed agreed.
(:test) function test_life_shutdownKeepsCoreFieldInvariantOnThrow(logger) {
    var p = new LifeThrowingSaveProbe();
    p.onLayout(null as Gfx.Dc);
    p.armCoreField();     // mFitCore/mFitSkin set, mSession left null

    try {
        p.shutdown();
    } catch (e) {
        // expected: this probe's stopAndSave throws
    }

    var ok = true;
    if (p.sensorHandle() != null) {
        logger.error("the sensor handle should have been cleared by the finally");
        ok = false;
    }
    if (p.coreFieldHandle() != null) {
        logger.error("mFitCore outlived mCoreSensor: the invariant " +
                     "`mFitCore != null => mCoreSensor != null` is violated, and " +
                     "onTick dereferences mCoreSensor guarded only by mFitCore -- " +
                     "a subsequent tick is a HARD FAULT, not a catchable throw. " +
                     "Clear the dependent field handles in the same finally");
        ok = false;
    }
    if (p.skinFieldHandle() != null) {
        logger.error("mFitSkin outlived mCoreSensor; same invariant, same line " +
                     "in onTick");
        ok = false;
    }
    return ok;
}

// mCoreSensor.close() throwing -- the near neighbour of the finding above, one
// line further down and structurally identical. A throw here is downstream of
// the timer but still UPSTREAM of the try/finally, so it skips both the save
// and the sensor clear. Not reported in review; found by looking one line out
// from the reported defect, which is this repository's documented habit.
(:test) function test_life_shutdownSavesEvenIfSensorCloseThrows(logger) {
    var p = new LifeThrowingCloseProbe();
    p.onLayout(null as Gfx.Dc);

    try {
        p.shutdown();
    } catch (e) {
        logger.error("a throwing close() must not propagate out of shutdown: " +
                     "the save is downstream of it and the row would be lost");
        return false;
    }

    var ok = true;
    if (p.sensorAt(0).closes != 1) {
        logger.error("close() must still have been attempted once, got " +
                     p.sensorAt(0).closes);
        ok = false;
    }
    if (p.saveCount() != 1) {
        logger.error("a throw in close() skipped stopAndSave -- the row is " +
                     "never saved. saveCount=" + p.saveCount());
        ok = false;
    }
    if (p.sensorHandle() != null) {
        logger.error("a throw in close() skipped the sensor clear, leaving a " +
                     "dead handle onLayout's guard reads as live");
        ok = false;
    }
    if (p.timerHandle() != null) {
        logger.error("mTimer must be null: it is cleared before this point");
        ok = false;
    }
    return ok;
}

// The regression the round-2 delta created, and the mirror image of the defect
// this whole PR exists to fix.
//
// Moving `mCoreSensor = null` after stopAndSave() (constraint 2 above) made it
// the LAST statement of shutdown() -- which makes it the one statement a throw
// can skip. If stopAndSave() throws, shutdown() unwinds holding a CLOSED
// CoreTempSensor, and onLayout's guard then reads that dead handle as live and
// declines to allocate: ZERO live sensors, exactly the state the comment on
// shutdown() exists to prevent. Neither main nor this PR's own c3 could reach
// it -- both left onLayout free to re-allocate -- so this is the delta's own
// defect, not an inherited one.
//
// `try { stopAndSave(); } finally { mCoreSensor = null; }` is the fix: the
// clear survives the unwind while the throw still propagates, which is what
// keeps this from silently swallowing a failed save.
//
// UNVERIFIED IN BOTH DIRECTIONS, and stated rather than assumed: the throw here
// is INJECTED, and nothing in this repository has observed stopAndSave()
// throwing on a device. But mSession.save() and the setData calls it performs
// are unguarded and shutdown() has no catch, so the path is not obviously
// unreachable either. The guard is correct under either answer and costs a
// finally block -- the same trade, and the same argument, as #11's own guard.
(:test) function test_life_shutdownClearsSensorEvenIfSaveThrows(logger) {
    var p = new LifeThrowingSaveProbe();
    p.onLayout(null as Gfx.Dc);

    var threw = false;
    try {
        p.shutdown();
    } catch (e) {
        threw = true;
    }

    if (!threw) {
        logger.error("the probe's stopAndSave must throw, or this test is " +
                     "measuring the ordinary path and proves nothing");
        return false;
    }

    var ok = true;
    if (p.saveCount() != 1) {
        logger.error("stopAndSave must still have been reached once, got " +
                     p.saveCount());
        ok = false;
    }
    if (p.sensorAt(0).closes != 1) {
        logger.error("the sensor must still have been closed before the throw");
        ok = false;
    }
    if (p.sensorHandle() != null) {
        logger.error("a throw in stopAndSave skipped the clear: shutdown left " +
                     "a CLOSED CoreTempSensor in mCoreSensor, so onLayout's " +
                     "guard reads it as live and never re-opens the ANT " +
                     "channel -- ZERO live sensors, the mirror image of #11. " +
                     "Clear it in a finally");
        ok = false;
    }
    if (p.timerHandle() != null) {
        logger.error("mTimer must be null too. It is cleared earlier in " +
                     "shutdown than this throw point -- but 'earlier' is not " +
                     "the same as 'unconditionally', which is what " +
                     "test_life_shutdownClearsTimerEvenIfStopThrows covers");
        ok = false;
    }
    // The outcome, not just the proxy: after a failed save the app must still
    // be able to re-arm. Cheap to assert here and it is what the user gets.
    p.onLayout(null as Gfx.Dc);
    if (p.sensorCount() != 2) {
        logger.error("onLayout must re-open a sensor after shutdown, sensors " +
                     "made = " + p.sensorCount() + " (expected a second one)");
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
