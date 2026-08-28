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

    // Counts, THEN runs the real body -- and refuses to re-enter past a cap of
    // 12, against a legitimate ladder depth of CT_BURST_TRIES = 4.
    //
    // WHAT THE CAP ACTUALLY BOUNDS, stated as MEASURED rather than as intended.
    // It is not what stops the pre-fix run: on fr965 / SDK 9.2.0 the simulator
    // aborts the case first, at the ELEVENTH nested openChannel frame, with
    //
    //     Error: Stack Overflow Error
    //     Details: Failed invoking <symbol>
    //
    // on a stack alternating makeRetryTimer / scheduleReopen / openChannel down
    // to initialize(). So the red is an ERROR, not a FAIL, and the observation
    // is the crash itself -- which is the defect: on a device where the ANT open
    // throws and no Timer can be armed, the app dies during onLayout rather than
    // merely wasting radio. An earlier version of this comment claimed the cap
    // was chosen low enough that the stack limit would not fire first; that was
    // written before it was run and is RETRACTED here rather than deleted.
    //
    // The cap still earns its place: it bounds the re-open COUNT, which a
    // runaway that does NOT grow the stack (a future edit that looped instead of
    // recursing) would blow past while the interpreter never complained. Both
    // bounds are needed; neither lets CI hang.
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
    // #165 grew the array by one slot and bumped the version to 4 in the same
    // commit as this line. The assertion's SUBJECT is unchanged and is what
    // matters here: CT_DIAG_F_RETRY_LOST is a BIT in an existing slot and did
    // not, by itself, cost any array growth. The number is a pin on the
    // wire format's current length, which the createField :count must equal --
    // a longer setData array is an uncatchable System Error at save.
    if ($.CT_DIAG_SLOTS != 25) {
        logger.error("CT_DIAG_SLOTS = " + $.CT_DIAG_SLOTS + "; the array length and the " +
                     "createField :count must move together, and only with a CT_DIAG_VERSION bump");
        ok = false;
    }
    if ($.CT_DIAG_VERSION != 4) {
        logger.error("CT_DIAG_VERSION = " + $.CT_DIAG_VERSION + "; extending the flags key " +
                     "without bumping the version leaves a reader unable to tell a bit from residue");
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

// ---- c2: red differentials --------------------------------------------------
// Every case below FAILS on the code as of the previous commit and passes after
// the fix. Nothing else is in the commit that adds them.

// THE INVARIANT: no sequence of failures, of any length, in any interleaving of
// openChannel() throwing and the retry timer failing to arm, may produce
// unbounded recursion.
//
// The cycle, and why nothing in the ladder stops it. openChannel()'s catch calls
// scheduleReopen(), and scheduleReopen()'s catch called openChannel() straight
// back. Once mFails >= CT_BURST_TRIES the delay is 30 s or more and NEVER
// returns to 0 again (test_rb_c0_onlyTheBurstEverAsksForZeroDelay), so every
// pass takes the timer branch -- and if the Timer cannot be allocated, which is
// precisely the resource state that also makes the ANT open throw, the pair
// alternates without bound. The ladder growing cannot help: the delay it grows
// is the delay being discarded.
//
// The probe's cap turns that into a failed assertion rather than a hung test.
// The re-open count is asserted too, not just the cap: after the fix the ladder
// must stop at exactly CT_BURST_TRIES, not merely somewhere below 12.
//
// The second half is the INTERLEAVING the invariant claims: six more channel
// closes, each landing on the timer branch (mFails is already past the burst)
// and each failing to arm, must add no re-opens at all -- while still ATTEMPTING
// to arm every time, so a later retry is not permanently foresworn.
(:test) function test_rb_c2_anUnarmableTimerCannotRecurseWithoutBound(logger) {
    var p = new DeadTimerProbe();
    var ok = true;
    if (p.ranAway()) {
        logger.error("openChannel <-> scheduleReopen recursed past the probe's cap: a retry " +
                     "timer that cannot be armed must not be answered with an immediate " +
                     "reopen -- that is unbounded recursion, and it is #26's unpaced " +
                     "re-search besides");
        ok = false;
    }
    if (p.openCount() != $.CT_BURST_TRIES) {
        logger.error("open attempts = " + p.openCount() + ", expected exactly " +
                     $.CT_BURST_TRIES + " -- the burst, and then nothing further");
        ok = false;
    }
    if (p.timerCount() != 1) {
        logger.error("arm attempts = " + p.timerCount() + ", expected 1 for the first " +
                     "delayed retry");
        ok = false;
    }
    for (var i = 0; i < 6; i++) { p.closeEvent(); }
    if (p.ranAway()) {
        logger.error("a run of channel closes with an unarmable timer recursed past the cap");
        ok = false;
    }
    if (p.openCount() != $.CT_BURST_TRIES) {
        logger.error("open attempts after 6 further closes = " + p.openCount() + ", expected " +
                     $.CT_BURST_TRIES + ": every one of those closes asks for 60 s or more, " +
                     "and a dropped retry must not become an immediate one");
        ok = false;
    }
    if (p.timerCount() != 7) {
        logger.error("arm attempts = " + p.timerCount() + ", expected 7 (one per scheduled " +
                     "retry): dropping THIS retry must not stop the ladder trying to arm the next");
        ok = false;
    }
    return ok;
}

// #18's own defect class, in the code #18 added: a resource is allocated,
// something throws past it, and the reference is dropped without handing the
// resource back. Connect IQ caps concurrent Timers exactly as the radio caps
// channels.
//
// Before the fix the catch did `mRetryTimer = null` and nothing else, so a Timer
// whose start() threw is orphaned -- and if it armed before throwing,
// cancelReopen() can no longer stop it, which is a callback firing into
// openChannel() after close(). cancelReopen() is where the release rule for
// timers already lives, so the fix reuses it rather than restating it; this case
// is what distinguishes the two.
(:test) function test_rb_c2_anUnarmableTimerIsHandedBack(logger) {
    var p = new DeadTimerProbe();
    if (p.timerCount() < 1) {
        logger.error("the ladder never reached the timer branch; nothing to assert on");
        return false;
    }
    var t = p.timerAt(0);
    if (t.starts != 1) {
        logger.error("the timer's start() must have been attempted, starts = " + t.starts);
        return false;
    }
    if (t.stops < 1) {
        logger.error("start() threw and the timer was never stopped -- it is orphaned, and " +
                     "cancelReopen() cannot reach it once the reference is dropped. That is " +
                     "#18's defect, in the code #18 added.");
        return false;
    }
    return true;
}

// A crash-avoidance fix that hides the condition trades one invisible failure
// for another, so the dropped retry has to be READABLE IN THE FILE.
//
// What is lost when the timer cannot be armed is the retry itself: nothing else
// re-enters openChannel() (after the catch mChannel is null, so no further
// CHANNEL_CLOSED can arrive), so CORE is dead for the rest of the app run. In
// ct_diag that state and "a 30 s retry is still pending" differ only by an
// openAttempt that has not happened YET -- an absence. CT_DIAG_F_RETRY_LOST is
// what makes it positive evidence instead.
//
// Asserted BOTH ways on purpose. The bit being set is satisfiable by a mistake
// that sets it always; the armed probe leaving it clear is the property that
// makes the two rows different, and the whole-slot comparison is what a reader
// of the file actually does.
(:test) function test_rb_c2_aLostRetryIsVisibleInCtDiag(logger) {
    var dead  = new DeadTimerProbe();
    var armed = new ArmedProbe();
    var ok = true;
    var df = dead.flagsSlot();
    var af = armed.flagsSlot();
    if (df < 0 || af < 0) {
        logger.error("the flags slot is unreadable: dead = " + df + ", armed = " + af);
        return false;
    }
    if ((df & $.CT_DIAG_F_RETRY_LOST) == 0) {
        logger.error("flags = " + df + " after a retry was dropped for want of a timer; " +
                     "CT_DIAG_F_RETRY_LOST (" + $.CT_DIAG_F_RETRY_LOST + ") must be set, or " +
                     "the file cannot tell a stalled ladder from one still waiting");
        ok = false;
    }
    if ((af & $.CT_DIAG_F_RETRY_LOST) != 0) {
        logger.error("flags = " + af + " on a probe whose timer ARMED; the bit must mean what " +
                     "it says");
        ok = false;
    }
    if (df == af) {
        logger.error("both probes read flags = " + df + "; a dropped retry and an armed one " +
                     "are the same row in the file");
        ok = false;
    }
    return ok;
}

}
