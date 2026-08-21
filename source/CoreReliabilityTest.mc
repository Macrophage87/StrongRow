using Toybox.Test;
using Toybox.Lang;

// The CORE channel's RELIABILITY CLUSTER: three open issues that are one
// coherent failure, measured on two real rows recorded on v0.7.1.
//
//   #122  the post-loss listen duty settles at 30 s in every 330 s -- 9.1 % --
//         so a pod that wakes again is likely to be missed;
//   #151  Ant.GenericChannel.open() returning FALSE (rather than throwing) was
//         counted and then ignored, so the retry ladder never engaged and CORE
//         stayed dead for the rest of the app run;
//   #165  page 0x00 is discarded, and it carries the pod's own data-quality
//         rating and its heart-rate-support state.
//
// ---- THE GLOBALS CEILING ---------------------------------------------------
//
// EVERY declaration in this file sits inside `module CoreRel`. A file-scope
// (:test), helper function or test class costs one member of module 'globals',
// which the fenix6 family caps at 253; a `module { }` block costs ONE member for
// everything inside it. See the measured ceiling note at the top of
// scripts/list_tests.py -- it is that note, not this comment, that
// scripts/check_ceiling_notes.py checks.
//
// So: declare nothing outside the module block. The simulator prints these as
// `CoreRel.test_cr_...`, and scripts/expected_tests.txt carries that qualified
// name because the pin has to match what the RUNNER prints.
//
// ---- Execution -------------------------------------------------------------
//
// These are (:test) functions: included in the --unit-test build, stripped from
// the shipping build, and EXECUTED on every PR (the run-tests CI job runs them
// headlessly in the simulator, judged by a fail-closed parser). Adding, removing
// or renaming one means editing scripts/expected_tests.txt in the SAME commit.
// See docs/CI.md.
//
// ---- What no test in this file can be evidence of --------------------------
//
// NOTHING HERE TOUCHES AN ANT RADIO OR A CORE POD. Every payload below is bytes
// this file chose, fed to a decoder this branch wrote; every channel is a
// double. So these cases are a regression guard on INTENT -- what the code
// reads and decides -- and never evidence about what a pod transmits or what a
// decoder sees. The same statement CoreTempSensorTest.mc makes about its own
// synthetic frames applies with full force to page 0x00, whose layout comes
// from a vendor example read for facts (#165) and has never been measured on
// air.
module CoreRel {

// ---- doubles ----------------------------------------------------------------
//
// CoreProbe (CoreTempSensorTest.mc) OVERRIDES scheduleReopen wholesale with a
// stand-in that reopens synchronously behind a depth guard. That is the right
// double for counting re-opens, and it is the wrong one here: the whole subject
// of #122 is WHAT DELAY THE LADDER ASKS FOR, and a depth guard changes which
// delays are ever requested. The probes below run the REAL scheduleReopen
// against a timer factory they control, and record the delay on the way past.

// A one-shot Timer stand-in that arms normally and never fires. Never firing is
// deliberate: a callback landing mid-case would re-enter openChannel() from
// outside the case's own control flow, and every open-count assertion would
// depend on wall-clock timing.
class RelTimer {
    var starts;
    var lastMs;
    var lastRepeat;
    function initialize() { starts = 0; lastMs = -1; lastRepeat = true; }
    function start(cb, ms, repeat) { starts++; lastMs = ms; lastRepeat = repeat; return true; }
    function stop() { return true; }
}

// A Timer that cannot be armed, so scheduleReopen's catch is reachable. Used
// only to re-prove #161's bound on the failure path #151 adds: a resource state
// that makes the ANT open fail is exactly the one that makes a Timer allocation
// fail, so the two must be tested TOGETHER or the interleaving is unpinned.
class RelDeadTimer {
    var starts;
    function initialize() { starts = 0; }
    function start(cb, ms, repeat) { starts++; throw new Lang.Exception(); }
    function stop() { return true; }
}

// Base probe over the SHIPPING retry path.
//
// MEASURED HAZARD, the one CoreProbe and LadderProbe both document:
// CoreTempSensor.initialize() calls openChannel(), which DISPATCHES TO THIS
// SUBCLASS while the subclass's own fields are still null, because Monkey C
// requires Base.initialize() to complete before a subclass assigns anything. So
// every override lazy-initialises on entry, and the channel double is returned
// from the constructor's own attempt onward -- the real allocation throws under
// the headless simulator and would drive the ladder before a case could
// configure anything.
class RelProbe extends CoreTempSensor {
    var opens;      // openChannel() entries, counted before delegating
    var runaway;    // the re-entry cap was hit -- see openChannel below
    var asked;      // every delay handed to the REAL scheduleReopen, in order

    function initialize() {
        CoreTempSensor.initialize();   // re-enters the overrides below
        if (opens   == null) { opens   = 0; }
        if (runaway == null) { runaway = false; }
        if (asked   == null) { asked   = []; }
    }

    // Overridden by the concrete probes below; never used from here.
    hidden function makeChannel()    { return null; }
    hidden function makeRetryTimer() { return null; }

    // Counts, THEN runs the real body -- and refuses to re-enter past a cap of
    // 12, against a legitimate ladder depth of CT_BURST_TRIES = 4.
    //
    // WHAT THE CAP ACTUALLY BOUNDS, stated as measured rather than as intended.
    // RetryBoundTest.mc records the measurement: on fr965 / SDK 9.2.0 an
    // unbounded openChannel <-> scheduleReopen cycle aborts the case at the
    // ELEVENTH nested frame with "Error: Stack Overflow Error", so a restored
    // recursion surfaces as a test ERROR before this cap is reached. The cap
    // still earns its place -- it bounds the re-open COUNT, which a runaway that
    // did not grow the stack would blow past while the interpreter never
    // complained -- and neither bound lets CI hang.
    hidden function openChannel() {
        if (opens == null) { opens = 0; }
        opens++;
        if (opens > 12) {
            runaway = true;
            return;
        }
        CoreTempSensor.openChannel();
    }

    // Records the requested delay and then runs the REAL body. Recording alone
    // would be wrong twice over: the burst's zero-delay reopen is a genuine
    // re-entry into openChannel() and is the thing #161's bound is about, and
    // the timer branch is where the delay actually reaches a Timer.
    hidden function scheduleReopen(delayMs) {
        if (asked == null) { asked = []; }
        asked.add(delayMs);
        CoreTempSensor.scheduleReopen(delayMs);
    }

    // Baseline clear: initialize() has already run openChannel() before any case
    // body starts, so recorders are reset rather than compared against an
    // assumed 0. mFails goes with them -- a probe whose constructor drove the
    // ladder would otherwise start every case part-way up it.
    function reset() {
        opens   = 0;
        runaway = false;
        asked   = [];
        mFails  = 0;
        resetDiag();
    }

    function openCount()  { if (opens == null) { opens = 0; }  return opens; }
    function ranAway()    { return runaway == true; }
    function asks()       { if (asked == null) { asked = []; } return asked; }
    function lastAsk()    {
        if (asked == null || asked.size() == 0) { return -1; }
        return asked[asked.size() - 1];
    }
    function worstAsk()   {
        if (asked == null) { return -1; }
        var w = -1;
        for (var i = 0; i < asked.size(); i++) {
            if (asked[i] > w) { w = asked[i]; }
        }
        return w;
    }

    // Seams onto the shipping paths, named for what they deliver rather than
    // for the method they reach.
    function closeEvent() { onChannelClosed(); }
    function feed(p)      { onBroadcast(p); }
    function channelHeld(){ return mChannel != null; }

    // One ct_diag slot, read through diagSnapshot() rather than off a field, so
    // a readout that dropped the value on the way out is still caught.
    function slot(i) {
        var a = diagSnapshot();
        if (a == null || i < 0 || i >= a.size()) { return -1; }
        return a[i];
    }
}

// A channel whose open() RETURNS TRUE. The control for everything below.
class RelOkProbe extends RelProbe {
    var chan;
    function initialize() { RelProbe.initialize(); }
    hidden function makeChannel() {
        // $.FakeChannel is CoreTempSensorTest.mc's existing double, reused
        // rather than re-declared: a second copy could drift from the original,
        // and inside a module it would still be a second class to maintain.
        chan = new $.FakeChannel(false);
        return chan;
    }
    hidden function makeRetryTimer() { return new RelTimer(); }
}

// A channel whose open() THROWS -- the failure mode #18 and #26 were filed on.
class RelThrowProbe extends RelProbe {
    var chan;
    function initialize() { RelProbe.initialize(); }
    hidden function makeChannel() {
        chan = new $.FakeChannel(true);
        return chan;
    }
    hidden function makeRetryTimer() { return new RelTimer(); }
}

// A channel whose open() FAILS QUIETLY: returns false, throws nothing. #151's
// subject. $.QuietFailChannel is CoreTempSensorTest.mc's existing double.
class RelQuietProbe extends RelProbe {
    var chan;
    function initialize() { RelProbe.initialize(); }
    hidden function makeChannel() {
        chan = new $.QuietFailChannel();
        return chan;
    }
    hidden function makeRetryTimer() { return new RelTimer(); }
}

// A quietly-failing channel AND a Timer that cannot be armed -- the correlated
// resource exhaustion, which is the interleaving #161's bound has to survive.
class RelQuietDeadProbe extends RelProbe {
    function initialize() { RelProbe.initialize(); }
    hidden function makeChannel()    { return new $.QuietFailChannel(); }
    hidden function makeRetryTimer() { return new RelDeadTimer(); }
}

// Build a page-0x00 payload from the two bytes #165 says carry meaning.
//
// Byte 2 is the data-quality byte and byte 3 packs the heart-rate-support and
// UTC-request fields. Every other byte is left at zero: this file must not
// imply it knows what they hold.
function relPage0(b2, b3) {
    return [0x00, 0x00, b2 & 0xFF, b3 & 0xFF, 0x00, 0x00, 0x00, 0x00];
}

// Byte 3 with a heart-rate-support code in bits 6:7, per #165.
function relHrByte(code) {
    return (code & 0x03) << 6;
}

// ---- c0: characterization pins on existing symbols --------------------------
// Every assertion below is true BOTH before and after the three fixes on this
// branch. They exist to prove that what the fixes claim not to touch is in fact
// untouched; the differentials that must go red first are in the c2 sections.

// THE COLD LADDER, unchanged. #122 shortens the post-loss wait for a pod that
// has actually been heard from -- it does NOT re-shape the ladder a pod that
// was never there gets, because that ladder is #26's battery bound and this
// branch has no measurement that would justify moving it.
//
// Asserted by CALLING ctBackoffMs rather than by restating its constants, and
// swept past the cap: a table that re-implemented the doubling would pin
// nothing.
(:test) function test_cr_c0_theColdLadderIsUnchanged(logger) {
    var exp = [0, 0, 0, 0, 30000, 60000, 120000, 240000, 300000, 300000];
    var ok = true;
    for (var f = 0; f < exp.size(); f++) {
        var got = CoreTempSensor.ctBackoffMs(f);
        if (got != exp[f]) {
            logger.error("ctBackoffMs(" + f + ") = " + got + ", expected " + exp[f] +
                         " -- the cold ladder is #26's battery bound and this branch does not move it");
            ok = false;
        }
    }
    if (CoreTempSensor.ctBackoffMs(1000) != $.CT_BACKOFF_MAX_MS) {
        logger.error("ctBackoffMs(1000) = " + CoreTempSensor.ctBackoffMs(1000) +
                     ", expected the cap " + $.CT_BACKOFF_MAX_MS + "; the cap must be a ceiling, not a wrap");
        ok = false;
    }
    return ok;
}

// A channel that OPENS must engage nothing. This is the pin standing in front
// of #151's fix: teaching openChannel to answer a false return with a release
// and a retry must not make a SUCCESSFUL open do either of those things.
//
// One delay is expected, not zero: the close event that drove the re-open asked
// for it. What must not appear is a SECOND ask from inside openChannel itself.
(:test) function test_cr_c0_aSuccessfulOpenNeitherFailsNorRetries(logger) {
    var p = new RelOkProbe();
    p.reset();
    p.closeEvent();
    var ok = true;
    if (p.openCount() != 1) {
        logger.error("one close event produced " + p.openCount() + " re-opens, expected 1");
        ok = false;
    }
    if (p.asks().size() != 1) {
        logger.error("delays requested = " + p.asks().size() + ", expected exactly 1 (the close " +
                     "event's own); a successful open must not schedule a retry of its own");
        ok = false;
    }
    if (p.slot($.CT_DIAG_I_OPEN_OK) != 1) {
        logger.error("openOk = " + p.slot($.CT_DIAG_I_OPEN_OK) + ", expected 1");
        ok = false;
    }
    if (p.slot($.CT_DIAG_I_OPEN_THROW) != 0) {
        logger.error("openThrow = " + p.slot($.CT_DIAG_I_OPEN_THROW) + ", expected 0");
        ok = false;
    }
    if (!p.channelHeld()) {
        logger.error("a channel that opened was released; only a FAILED open hands the channel back");
        ok = false;
    }
    return ok;
}

// The throw path, which #151's fix refactors into a shared handler and must
// leave behaving exactly as it did: the channel is handed back (#18), the throw
// is counted (#102), the high-water mark rises, and a retry is scheduled (#26).
(:test) function test_cr_c0_aThrowingOpenStillReleasesAndRelands(logger) {
    var p = new RelThrowProbe();
    var ok = true;
    if (p.chan == null) {
        logger.error("the probe never reached makeChannel(); nothing to assert on");
        return false;
    }
    if (p.chan.opened != true) {
        logger.error("the double's open() was never reached");
        ok = false;
    }
    if (p.chan.released != true) {
        logger.error("open() threw and the channel was never released -- that is #18");
        ok = false;
    }
    if (p.channelHeld()) {
        logger.error("mChannel is still set after a throwing open; the next openChannel would reuse it");
        ok = false;
    }
    if (p.slot($.CT_DIAG_I_OPEN_THROW) < 1) {
        logger.error("openThrow = " + p.slot($.CT_DIAG_I_OPEN_THROW) + "; a throwing open must be recorded");
        ok = false;
    }
    if (p.slot($.CT_DIAG_I_OPEN_OK) != 0) {
        logger.error("openOk = " + p.slot($.CT_DIAG_I_OPEN_OK) + "; a throwing open is not a success");
        ok = false;
    }
    if (p.slot($.CT_DIAG_I_MAX_FAILS) < 1) {
        logger.error("maxFails = " + p.slot($.CT_DIAG_I_MAX_FAILS) + "; a failed open must raise the high-water mark");
        ok = false;
    }
    if (p.asks().size() < 1) {
        logger.error("a failed open must schedule a retry; delays requested = " + p.asks().size());
        ok = false;
    }
    return ok;
}

// PAGE 0x00 REMAINS AN UNDECODED PAGE. #165 teaches this class to READ page
// 0x00 for the pod's own quality rating and heart-rate state; it does not
// promote page 0x00 into a temperature source, and it does not remove page 0x00
// from the pageOther tally.
//
// Slot 8's key is "page byte != 0x01", and page 0x00 satisfies it before and
// after. Keeping the slot's meaning fixed is what lets a v1 key still read a v4
// file -- which is the property the README claims and this case is the pin for.
(:test) function test_cr_c0_pageZeroIsCountedAsAnUndecodedPage(logger) {
    var p = new RelOkProbe();
    p.reset();
    p.feed(relPage0(0x01, relHrByte(1)));
    var ok = true;
    if (p.slot($.CT_DIAG_I_BCAST) != 1) {
        logger.error("bcast = " + p.slot($.CT_DIAG_I_BCAST) + ", expected 1");
        ok = false;
    }
    if (p.slot($.CT_DIAG_I_PAGE1) != 0) {
        logger.error("page1 = " + p.slot($.CT_DIAG_I_PAGE1) + "; page 0x00 is not page 0x01");
        ok = false;
    }
    if (p.slot($.CT_DIAG_I_PAGE_OTHER) != 1) {
        logger.error("pageOther = " + p.slot($.CT_DIAG_I_PAGE_OTHER) + ", expected 1: slot 8's key is " +
                     "\"page byte != 0x01\" and page 0x00 must keep satisfying it, or every key ever " +
                     "written against an older file changes meaning");
        ok = false;
    }
    if (p.slot($.CT_DIAG_I_PAGE_OTHER_LAST) != 0x00) {
        logger.error("pageOtherLast = " + p.slot($.CT_DIAG_I_PAGE_OTHER_LAST) + ", expected 0x00");
        ok = false;
    }
    if (p.slot($.CT_DIAG_I_CORE_OK) != 0 || p.slot($.CT_DIAG_I_SKIN_OK) != 0 ||
        p.slot($.CT_DIAG_I_HSI_OK) != 0) {
        logger.error("a page-0x00 frame produced a decoded value: coreOk = " + p.slot($.CT_DIAG_I_CORE_OK) +
                     ", skinOk = " + p.slot($.CT_DIAG_I_SKIN_OK) + ", hsiOk = " + p.slot($.CT_DIAG_I_HSI_OK) +
                     " -- page 0x00 carries no temperature and must never be read as one");
        ok = false;
    }
    if (p.everSeen()) {
        logger.error("a page-0x00 frame latched everSeen; that flag gates the ANT search period's " +
                     "alternation and must move only on an accepted temperature");
        ok = false;
    }
    return ok;
}

// THE FOUR EXISTING FLAG BITS, nailed to their literal values.
//
// #165 spends previously-unused bits of the same slot, and the failure that
// makes worth pinning is renumbering rather than collision:
// RetryBound.test_rb_c1_theRetryLostBitIsDistinctAndTheArrayDidNotGrow proves
// the newest bit does not OVERLAP its neighbours, but it is invariant under a
// wholesale re-assignment that shifts all four. Every ct_diag file already
// recorded carries slot 17 under this key.
(:test) function test_cr_c0_theFourFlagBitsKeepTheirValues(logger) {
    var ok = true;
    if ($.CT_DIAG_F_CHANNEL_HELD != 1) { logger.error("CT_DIAG_F_CHANNEL_HELD moved to " + $.CT_DIAG_F_CHANNEL_HELD); ok = false; }
    if ($.CT_DIAG_F_CLOSED       != 2) { logger.error("CT_DIAG_F_CLOSED moved to " + $.CT_DIAG_F_CLOSED); ok = false; }
    if ($.CT_DIAG_F_EVER_SEEN    != 4) { logger.error("CT_DIAG_F_EVER_SEEN moved to " + $.CT_DIAG_F_EVER_SEEN); ok = false; }
    if ($.CT_DIAG_F_RETRY_LOST   != 8) { logger.error("CT_DIAG_F_RETRY_LOST moved to " + $.CT_DIAG_F_RETRY_LOST); ok = false; }
    return ok;
}

}
