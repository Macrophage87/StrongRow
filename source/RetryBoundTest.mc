using Toybox.Test;
using Toybox.Lang;

// The CORE channel's RETRY PATH, and the one property it has to have: no
// sequence of failures, of any length, in any interleaving, may produce
// unbounded recursion.
//
// openChannel()'s catch calls scheduleReopen(), and scheduleReopen() calls
// openChannel() back. That is TWO cycles in one pair of functions, and they are
// not equally safe:
//
//   * the ZERO-DELAY cycle (the burst) terminates, but only arithmetically --
//     mFails rises on every pass and ctBackoffMs stops returning 0 once the
//     burst is spent. Nothing structural stops it. That is what the c0 pin
//     below stands in front of.
//   * the TIMER-CATCH cycle does not terminate at all on the tree this file
//     was added to. Its differentials are in the c2 section.
//
// ---- THE GLOBALS CEILING ---------------------------------------------------
//
// EVERY declaration in this file sits inside `module RetryBound`. A file-scope
// (:test), helper function or class costs one member of module 'globals', which
// the fenix6 family caps at 253; a `module { }` block costs ONE member for
// everything inside it. See the measured ceiling note at the top of
// scripts/list_tests.py -- it is that note, not this comment, that
// scripts/check_ceiling_notes.py checks.
//
// So: declare nothing outside the module block. The simulator prints these as
// `RetryBound.test_rb_...`, and scripts/expected_tests.txt carries that
// qualified name because the pin has to match what the RUNNER prints.
//
// ---- Execution -------------------------------------------------------------
//
// These are (:test) functions: included in the --unit-test build, stripped from
// the shipping build, and EXECUTED on every PR (the run-tests CI job runs them
// headlessly in the simulator, judged by a fail-closed parser). Adding, removing
// or renaming one means editing scripts/expected_tests.txt in the SAME commit.
// See docs/CI.md.
module RetryBound {

// ---- doubles ----------------------------------------------------------------
//
// CoreProbe (CoreTempSensorTest.mc) OVERRIDES scheduleReopen entirely, with a
// stand-in that reopens synchronously behind a depth guard -- and its own
// comment says why: "a real Timer breaks that cycle by deferring." That is true
// whenever the Timer works, and it is exactly why CoreProbe cannot see what
// happens when it does not. The probes below run the REAL scheduleReopen and
// the REAL openChannel against a timer factory they control, which is the only
// way the catch under test is reachable at all.

// A one-shot Timer stand-in that arms normally.
class LiveTimer {
    var starts;
    var stops;
    var lastMs;
    var lastRepeat;
    function initialize() { starts = 0; stops = 0; lastMs = -1; lastRepeat = true; }
    function start(cb, ms, repeat) {
        starts++; lastMs = ms; lastRepeat = repeat;
        return true;
    }
    function stop() { stops++; return true; }
}

// A Timer that cannot be armed. Records the call FIRST and then fails, so
// "never called" and "called and threw" stay distinguishable.
//
// Connect IQ caps concurrent Timers, so a start() that fails is a documented
// resource exhaustion rather than an invented case -- and the exhaustion that
// makes it fail is correlated with the one that makes the ANT open throw.
// Whether it EVER fails on this path is NOT measured and is not claimed here:
// no environment in this repository has an ANT radio, and the one real-row
// ct_diag readout available (#122) reached the timer branch with 22 of 22 opens
// succeeding. The path is reachable by construction; its outcome is what these
// cases measure.
class DeadTimer {
    var starts;
    var stops;
    function initialize() { starts = 0; stops = 0; }
    function start(cb, ms, repeat) {
        starts++;
        throw new Lang.Exception();
    }
    function stop() { stops++; return true; }
}

// Base probe over the SHIPPING retry path.
//
// MEASURED HAZARD, the one CoreProbe documents: CoreTempSensor.initialize()
// calls openChannel(), which DISPATCHES TO THIS SUBCLASS while the subclass's
// own fields are still null, because Monkey C requires Base.initialize() to
// complete before a subclass assigns anything. So every override lazy-
// initialises on entry, and the channel double is returned from the
// constructor's own attempt onward -- the real allocation throws under the
// headless simulator and would drive the ladder before a test could configure
// anything.
//
// $.FakeChannel(true) is CoreTempSensorTest.mc's existing double, whose open()
// throws; reused rather than re-declared, because a second copy of it would
// cost another globals member and could drift from the original.
//
// The channel always throws, so the whole ladder runs from construction:
// CT_BURST_TRIES attempts at zero delay, then the first delayed retry, which is
// where the timer factory below is reached.
class LadderProbe extends CoreTempSensor {
    var opens;      // openChannel() entries, counted before delegating
    var runaway;    // the re-entry cap was hit -- see openChannel below
    var timers;     // every timer handed to the shipping code, in order

    function initialize() {
        CoreTempSensor.initialize();   // re-enters the overrides below
        if (opens   == null) { opens   = 0; }
        if (runaway == null) { runaway = false; }
        if (timers  == null) { timers  = []; }
    }

    hidden function makeChannel() { return new $.FakeChannel(true); }

    // Overridden by the two concrete probes below; never used from here.
    hidden function makeRetryTimer() { return null; }

    // Counts, THEN runs the real body -- and refuses to re-enter past a cap.
    // The cap is what turns an unbounded openChannel <-> scheduleReopen
    // recursion into a FAILED ASSERTION rather than a hung test process. It is
    // 12 against a legitimate ladder depth of CT_BURST_TRIES = 4: high enough
    // that no correct behaviour reaches it, low enough that the simulator's own
    // stack limit is not the thing that stops the run.
    hidden function openChannel() {
        if (opens == null) { opens = 0; }
        opens++;
        if (opens > 12) {
            runaway = true;
            return;
        }
        CoreTempSensor.openChannel();
    }

    function openCount()  { if (opens  == null) { opens  = 0; }  return opens; }
    function ranAway()    { return runaway == true; }
    function timerCount() { if (timers == null) { timers = []; } return timers.size(); }
    function timerAt(i)   { return timers[i]; }

    // A search timeout / dropout, delivered at the same seam CoreProbe uses.
    function closeEvent() { onChannelClosed(); }

    // The CT_DIAG_I_FLAGS slot as the FIT field would carry it -- read through
    // diagSnapshot() rather than off a field, so a readout that dropped the bit
    // on the way out would still be caught.
    function flagsSlot() {
        var a = diagSnapshot();
        if (a == null || $.CT_DIAG_I_FLAGS >= a.size()) { return -1; }
        return a[$.CT_DIAG_I_FLAGS];
    }
}

class ArmedProbe extends LadderProbe {
    function initialize() { LadderProbe.initialize(); }
    hidden function makeRetryTimer() {
        if (timers == null) { timers = []; }
        var t = new LiveTimer();
        timers.add(t);
        return t;
    }
}

class DeadTimerProbe extends LadderProbe {
    function initialize() { LadderProbe.initialize(); }
    hidden function makeRetryTimer() {
        if (timers == null) { timers = []; }
        var t = new DeadTimer();
        timers.add(t);
        return t;
    }
}

// ---- c0: characterization pins on existing symbols --------------------------
// True BOTH before and after the fix in this branch. They exist to prove the
// change is behaviour-preserving where it claims to be, not to describe the
// defect; the differentials are in c2.

// THE ARITHMETIC THE BURST'S RECURSION BOUND RESTS ON, asserted by calling the
// ladder rather than by restating its constants.
//
// Two separate consequences hang on this one function, which is why it is
// pinned here and not left to test_ct_backoffLadder's table:
//
//   * scheduleReopen(0) calls openChannel() directly, from inside
//     openChannel()'s own catch. The chain unwinds ONLY because mFails rises on
//     every pass and this function stops returning 0 -- so the depth is capped
//     at CT_BURST_TRIES frames. An edit that let 0 come back (a "just retry
//     immediately" tidy-up, or a burst count raised without thought) would
//     reintroduce an unbounded recursion, and it would red HERE, in a case that
//     names the consequence.
//   * once the burst is spent the delay NEVER returns to 0 -- it only doubles
//     to a cap. So from that point on scheduleReopen always takes the timer
//     branch, and a timer branch that answered failure with an immediate reopen
//     could never be rescued by the ladder growing. That is the whole reason
//     the c2 cycle below has no bound.
(:test) function test_rb_c0_onlyTheBurstEverAsksForZeroDelay(logger) {
    var ok = true;
    for (var f = 0; f < $.CT_BURST_TRIES; f++) {
        if (CoreTempSensor.ctBackoffMs(f) != 0) {
            logger.error("ctBackoffMs(" + f + ") = " + CoreTempSensor.ctBackoffMs(f) +
                         "; inside the burst the ladder must still reopen immediately");
            ok = false;
        }
    }
    // Past the burst, and far past it: a single 0 anywhere here makes
    // openChannel <-> scheduleReopen recurse for as long as both keep failing.
    for (var f = $.CT_BURST_TRIES; f <= $.CT_BURST_TRIES + 16; f++) {
        if (CoreTempSensor.ctBackoffMs(f) <= 0) {
            logger.error("ctBackoffMs(" + f + ") = " + CoreTempSensor.ctBackoffMs(f) +
                         "; a zero here makes openChannel <-> scheduleReopen recurse without bound");
            ok = false;
        }
    }
    // The cap is a ceiling, not a wrap back to zero.
    if (CoreTempSensor.ctBackoffMs(1000) != $.CT_BACKOFF_MAX_MS) {
        logger.error("ctBackoffMs(1000) = " + CoreTempSensor.ctBackoffMs(1000) +
                     ", expected the cap " + $.CT_BACKOFF_MAX_MS);
        ok = false;
    }
    return ok;
}

// ---- c1: green pins on the new seam and the new flag bit --------------------
// Green from the commit that adds makeRetryTimer() and CT_DIAG_F_RETRY_LOST
// onward, and green after the fix. They assert what must NOT move.

// THE NON-VACUITY GUARD FOR EVERYTHING BELOW, and the pin that stands in front
// of the laziest possible "fix".
//
// The retry path could be made non-recursive by deleting it: never arm a timer,
// never reopen. Every c2 case about recursion would then pass, and #26 -- a pod
// donned after rigging is never found -- would be reopened by the change meant
// to harden it. This case is what reds if that happens: with a timer that arms
// normally the ladder must still arm EXACTLY ONE one-shot at the ladder's own
// delay, and must not reopen the channel synchronously.
(:test) function test_rb_c1_aWorkingTimerIsArmedOnceAndNothingReopens(logger) {
    var p = new ArmedProbe();
    var ok = true;
    if (p.ranAway()) {
        logger.error("the ladder re-entered openChannel past the probe's cap with a " +
                     "WORKING timer; the burst must stop at CT_BURST_TRIES");
        return false;
    }
    if (p.openCount() != $.CT_BURST_TRIES) {
        logger.error("burst attempts = " + p.openCount() + ", expected " + $.CT_BURST_TRIES +
                     " before the first deferred retry");
        ok = false;
    }
    if (p.timerCount() != 1) {
        logger.error("the first delayed retry must arm exactly one timer, armed = " +
                     p.timerCount());
        return false;
    }
    var t = p.timerAt(0);
    if (t.starts != 1) {
        logger.error("the retry timer must be started once, starts = " + t.starts);
        ok = false;
    }
    if (t.lastMs != $.CT_BACKOFF_BASE_MS) {
        logger.error("retry delay " + t.lastMs + " != " + $.CT_BACKOFF_BASE_MS);
        ok = false;
    }
    if (t.lastRepeat != false) {
        logger.error("the retry timer must be ONE-SHOT; a repeating timer would " +
                     "re-search every 30 s forever, which is #26 restored");
        ok = false;
    }
    return ok;
}

// The new diagnostic bit, from the side the FIT file sees it.
//
// Two things at once, and both are load-bearing:
//
//   * the bit is DISTINCT from the three that already exist, so setting it
//     cannot be mistaken for -- or silently clear -- "a channel was held",
//     "close() had run" or "a reading was accepted";
//   * the array did NOT grow. CT_DIAG_SLOTS is what the createField `:count` in
//     StrongRowView reads, and a setData array longer than :count is an
//     uncatchable System Error that takes the whole activity at save time. A
//     new BIT in an existing slot costs none of that risk, which is why the
//     signal is a bit and not a counter. The version bump is what tells a
//     reader the key grew.
//
// The last assertion is the one that keeps the bit meaningful rather than
// decorative: on a probe whose timer arms normally it must be CLEAR. A flag
// that is always set is not a diagnostic.
(:test) function test_rb_c1_theRetryLostBitIsDistinctAndTheArrayDidNotGrow(logger) {
    var ok = true;
    var others = [$.CT_DIAG_F_CHANNEL_HELD, $.CT_DIAG_F_CLOSED, $.CT_DIAG_F_EVER_SEEN];
    for (var i = 0; i < others.size(); i++) {
        if (($.CT_DIAG_F_RETRY_LOST & others[i]) != 0) {
            logger.error("CT_DIAG_F_RETRY_LOST (" + $.CT_DIAG_F_RETRY_LOST +
                         ") overlaps an existing flag bit (" + others[i] + ")");
            ok = false;
        }
    }
    if ($.CT_DIAG_F_RETRY_LOST <= 0) {
        logger.error("CT_DIAG_F_RETRY_LOST = " + $.CT_DIAG_F_RETRY_LOST + "; a zero bit can never be read back");
        ok = false;
    }
    if ($.CT_DIAG_SLOTS != 24) {
        logger.error("CT_DIAG_SLOTS = " + $.CT_DIAG_SLOTS + "; the flag bit must not grow the " +
                     "array -- the createField :count reads this constant and a longer setData " +
                     "array is an uncatchable System Error at save");
        ok = false;
    }
    if ($.CT_DIAG_VERSION != 3) {
        logger.error("CT_DIAG_VERSION = " + $.CT_DIAG_VERSION + "; extending the flags key " +
                     "without bumping the version leaves a reader unable to tell the bit from residue");
        ok = false;
    }
    var armed = new ArmedProbe();
    if ((armed.flagsSlot() & $.CT_DIAG_F_RETRY_LOST) != 0) {
        logger.error("flags = " + armed.flagsSlot() + " on a probe whose retry timer ARMED; " +
                     "a bit that is always set diagnoses nothing");
        ok = false;
    }
    return ok;
}

}
