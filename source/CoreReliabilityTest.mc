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

// ---- #122 c1: the new ladder shape, as pure arithmetic ----------------------
// Green from the commit that adds ctSearchDelayMs/ctDutyPerMille onward, and
// green after the fix wires mPodEverNear in. They assert what must NOT move.

// #161'S BOUND, RE-PROVED ON THE NEW FUNCTION, and it is the case in this file
// that matters most.
//
// scheduleReopen(0) calls openChannel() straight back from inside openChannel's
// own failure handler. That chain unwinds only because mFails rises on every
// pass and the ladder stops returning 0 once the burst is spent -- an ARITHMETIC
// bound, capped at CT_BURST_TRIES frames, not a structural one. #161 is the
// stack overflow that happened when a path could ask for an immediate reopen
// forever: MEASURED on fr965 / SDK 9.2.0 as "Error: Stack Overflow Error" on a
// stack alternating scheduleReopen and openChannel down to initialize(), i.e.
// the app dying during onLayout and taking the recording with it.
//
// #122 puts a new function in front of that decision, so the bound has to be
// re-proved THROUGH it -- for both values of podNear, and far past the cap. A
// single 0 anywhere in the right-hand loop is an unbounded recursion.
(:test) function test_cr_c1_theNearLadderNeverAsksForZeroPastTheBurst(logger) {
    var ok = true;
    var flags = [false, true];
    for (var k = 0; k < flags.size(); k++) {
        var near = flags[k];
        for (var f = 0; f < $.CT_BURST_TRIES; f++) {
            if (CoreTempSensor.ctSearchDelayMs(f, near) != 0) {
                logger.error("ctSearchDelayMs(" + f + ", " + near + ") = " +
                             CoreTempSensor.ctSearchDelayMs(f, near) +
                             "; inside the burst the ladder must still reopen immediately, or " +
                             "#26's pod donned after rigging is lost again");
                ok = false;
            }
        }
        for (var f = $.CT_BURST_TRIES; f <= $.CT_BURST_TRIES + 64; f++) {
            if (CoreTempSensor.ctSearchDelayMs(f, near) <= 0) {
                logger.error("ctSearchDelayMs(" + f + ", " + near + ") = " +
                             CoreTempSensor.ctSearchDelayMs(f, near) +
                             "; a zero here makes openChannel <-> scheduleReopen recurse without " +
                             "bound -- that is #161, which crashed the app during onLayout");
                ok = false;
            }
        }
        if (CoreTempSensor.ctSearchDelayMs(100000, near) <= 0) {
            logger.error("ctSearchDelayMs(100000, " + near + ") = " +
                         CoreTempSensor.ctSearchDelayMs(100000, near) +
                         "; the cap must be a ceiling, not a wrap");
            ok = false;
        }
    }
    return ok;
}

// THE TWO LADDERS, side by side, called rather than restated.
//
// The left column is #26's ladder, which this branch does not move; the right
// is the same ladder capped once a broadcast has been tracked. The cap sits
// ABOVE CT_BACKOFF_BASE_MS on purpose: a cap at or below the base would flatten
// the ladder into a fixed interval and delete the doubling #26 exists for.
(:test) function test_cr_c1_theTwoLaddersDifferOnlyInTheirCap(logger) {
    var cold = [0, 0, 0, 0, 30000, 60000, 120000, 240000, 300000, 300000];
    var near = [0, 0, 0, 0, 30000, 60000,  60000,  60000,  60000,  60000];
    var ok = true;
    if ($.CT_BACKOFF_NEAR_MAX_MS >= $.CT_BACKOFF_MAX_MS) {
        logger.error("CT_BACKOFF_NEAR_MAX_MS = " + $.CT_BACKOFF_NEAR_MAX_MS + " is not below " +
                     "CT_BACKOFF_MAX_MS = " + $.CT_BACKOFF_MAX_MS + "; then #122 changes nothing");
        ok = false;
    }
    if ($.CT_BACKOFF_NEAR_MAX_MS <= $.CT_BACKOFF_BASE_MS) {
        logger.error("CT_BACKOFF_NEAR_MAX_MS = " + $.CT_BACKOFF_NEAR_MAX_MS + " is at or below the " +
                     "base " + $.CT_BACKOFF_BASE_MS + "; that flattens the ladder into a fixed " +
                     "interval and deletes the doubling #26 exists for");
        ok = false;
    }
    for (var f = 0; f < cold.size(); f++) {
        var gc = CoreTempSensor.ctSearchDelayMs(f, false);
        var gn = CoreTempSensor.ctSearchDelayMs(f, true);
        if (gc != cold[f]) {
            logger.error("ctSearchDelayMs(" + f + ", false) = " + gc + ", expected " + cold[f]);
            ok = false;
        }
        if (gn != near[f]) {
            logger.error("ctSearchDelayMs(" + f + ", true) = " + gn + ", expected " + near[f]);
            ok = false;
        }
    }
    return ok;
}

// THE DUTY ARITHMETIC IN THE SOURCE, EXECUTED.
//
// The CT_BACKOFF_NEAR_MAX_MS block states 9.1 % and 33.3 %. Those are not hand
// figures in a comment -- they are ctDutyPerMille applied to constants in the
// same file, and this case is what makes a later edit to any of those constants
// red instead of silently falsifying the prose. That discipline is the point:
// this repository has withdrawn several claims that were arithmetic nobody
// re-ran.
//
// It is a DUTY CYCLE and nothing else. No milliamp-hour figure appears here or
// in the source, because none has been measured on any watch.
(:test) function test_cr_c1_theDutyArithmeticIsTheOneStatedHere(logger) {
    var ok = true;
    // The window the arithmetic uses and the number the radio is actually told
    // must agree, or every figure below is about a search that never happens.
    if ($.CT_SEARCH_WINDOW_MS != $.CT_SEARCH_TIMEOUT_LP * 2500) {
        logger.error("CT_SEARCH_WINDOW_MS = " + $.CT_SEARCH_WINDOW_MS + " but the DeviceConfig is " +
                     "told searchTimeoutLowPriority = " + $.CT_SEARCH_TIMEOUT_LP + ", i.e. " +
                     ($.CT_SEARCH_TIMEOUT_LP * 2500) + " ms");
        ok = false;
    }
    var coldDuty = CoreTempSensor.ctDutyPerMille($.CT_SEARCH_WINDOW_MS, $.CT_BACKOFF_MAX_MS);
    var nearDuty = CoreTempSensor.ctDutyPerMille($.CT_SEARCH_WINDOW_MS, $.CT_BACKOFF_NEAR_MAX_MS);
    if (coldDuty != 91) {
        logger.error("steady-state cold duty = " + coldDuty + " per mille, expected 91 (9.1 %) -- " +
                     "the figure #122 was filed on");
        ok = false;
    }
    if (nearDuty != 333) {
        logger.error("steady-state near-pod duty = " + nearDuty + " per mille, expected 333 (33.3 %)");
        ok = false;
    }
    if (nearDuty <= coldDuty) {
        logger.error("the near-pod ladder listens no more than the cold one (" + nearDuty + " vs " +
                     coldDuty + " per mille); then #122 is not fixed");
        ok = false;
    }
    // ...and it must not be a return to the pre-#26 behaviour, which is the
    // other half of the tension #122 describes.
    if (nearDuty >= 1000) {
        logger.error("near-pod duty = " + nearDuty + " per mille: that is a continuous search, " +
                     "which is exactly what #26 was filed to stop");
        ok = false;
    }
    // Endpoints, so the helper itself is pinned rather than trusted.
    if (CoreTempSensor.ctDutyPerMille(30000, 0) != 1000) {
        logger.error("ctDutyPerMille(30000, 0) = " + CoreTempSensor.ctDutyPerMille(30000, 0) +
                     ", expected 1000: no idle time is a 100 % duty");
        ok = false;
    }
    if (CoreTempSensor.ctDutyPerMille(0, 30000) != 0) {
        logger.error("ctDutyPerMille(0, 30000) = " + CoreTempSensor.ctDutyPerMille(0, 30000) +
                     ", expected 0");
        ok = false;
    }
    if (CoreTempSensor.ctDutyPerMille(0, 0) != 0) {
        logger.error("ctDutyPerMille(0, 0) = " + CoreTempSensor.ctDutyPerMille(0, 0) +
                     ", expected 0 rather than a division by zero");
        ok = false;
    }
    return ok;
}

// THE NON-VACUITY GUARD for every #122 differential below.
//
// The shortened cap could be "delivered" by applying it unconditionally, which
// would hand a podless row a 33.3 % search duty for the whole session and
// reopen #26 with the change meant to fix #122. This case is what reds if that
// happens: a sensor that has never had a broadcast frame must still walk the
// COLD ladder all the way to CT_BACKOFF_MAX_MS, measured through the SHIPPING
// path rather than through the pure function.
(:test) function test_cr_c1_aPodNeverNearStillWalksTheColdLadder(logger) {
    var p = new RelOkProbe();
    p.reset();
    for (var i = 0; i < 9; i++) { p.closeEvent(); }
    var exp = [0, 0, 0, 30000, 60000, 120000, 240000, 300000, 300000];
    var got = p.asks();
    var ok = true;
    if (got.size() != exp.size()) {
        logger.error("delays requested = " + got.size() + ", expected " + exp.size());
        return false;
    }
    for (var i = 0; i < exp.size(); i++) {
        if (got[i] != exp[i]) {
            logger.error("delay[" + i + "] = " + got[i] + ", expected " + exp[i] +
                         " -- a pod that was never heard from gets #26's ladder unchanged");
            ok = false;
        }
    }
    if (p.slot($.CT_DIAG_I_BCAST) != 0) {
        logger.error("bcast = " + p.slot($.CT_DIAG_I_BCAST) + "; this probe must never have tracked " +
                     "a frame, or the case is not about a never-near pod");
        ok = false;
    }
    return ok;
}

// ---- #151 c1: the shared failure handler ------------------------------------
// Green from the commit that extracts noteOpenFailure() onward, and green after
// the fix. It asserts what must NOT move while a second caller is added.

// The throw path, driven through the ladder rather than once, and asserted on
// the ORDER the handler imposes: the channel is released BEFORE the retry is
// scheduled, because the retry re-enters openChannel() and the `mChannel ==
// null` guard there would otherwise reuse the channel that just failed.
//
// Ordering is what makes this different from the c0 pin above, which asserts
// the same four effects happened. Here the effects are separated: after the
// burst has run to its first deferred retry, exactly CT_BURST_TRIES opens have
// happened, every one of them released its channel, and no channel is held.
// A handler that scheduled first and released afterwards would leave a channel
// held at the end of the burst and red here while the c0 pin stayed green.
(:test) function test_cr_c1_theThrowPathReleasesBeforeItRelands(logger) {
    var p = new RelThrowProbe();
    var ok = true;
    if (p.ranAway()) {
        logger.error("the ladder re-entered openChannel past the probe's cap; the burst must " +
                     "stop at CT_BURST_TRIES -- that is #161's bound");
        return false;
    }
    if (p.openCount() != $.CT_BURST_TRIES) {
        logger.error("burst attempts = " + p.openCount() + ", expected " + $.CT_BURST_TRIES +
                     " before the first deferred retry");
        ok = false;
    }
    if (p.channelHeld()) {
        logger.error("a channel is still held after the burst; the retry re-enters openChannel(), " +
                     "whose `mChannel == null` guard would then REUSE the channel that just failed");
        ok = false;
    }
    if (p.slot($.CT_DIAG_I_OPEN_THROW) != $.CT_BURST_TRIES) {
        logger.error("openThrow = " + p.slot($.CT_DIAG_I_OPEN_THROW) + ", expected " + $.CT_BURST_TRIES +
                     "; the throw counter stays in the catch, not in the shared handler");
        ok = false;
    }
    if (p.slot($.CT_DIAG_I_MAX_FAILS) != $.CT_BURST_TRIES) {
        logger.error("maxFails = " + p.slot($.CT_DIAG_I_MAX_FAILS) + ", expected " + $.CT_BURST_TRIES);
        ok = false;
    }
    // The burst's zero-delay asks, then the first real one. Asserted as a
    // sequence because it is the sequence that bounds the recursion.
    var a = p.asks();
    if (a.size() != $.CT_BURST_TRIES) {
        logger.error("delays requested = " + a.size() + ", expected " + $.CT_BURST_TRIES);
        return ok && false;
    }
    for (var i = 0; i < a.size() - 1; i++) {
        if (a[i] != 0) {
            logger.error("delay[" + i + "] = " + a[i] + "; inside the burst the ladder must still " +
                         "reopen immediately, or #26's donned-after-rigging pod is lost again");
            ok = false;
        }
    }
    if (a[a.size() - 1] != $.CT_BACKOFF_BASE_MS) {
        logger.error("the first deferred retry asked for " + a[a.size() - 1] + ", expected " +
                     $.CT_BACKOFF_BASE_MS);
        ok = false;
    }
    return ok;
}

}
