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
// RE-MEASURED FOR THIS BRANCH, not extrapolated from the previous note. The
// count is only printed once the build is ALREADY over, so it has to be probed:
// N throwaway file-scope (:test) functions dropped into source/, compiled
// --unit-test for fenix6, and N subtracted from the reported total. SDK 9.2.0,
// this tree, with all TWENTY-SIX CoreRel cases present (5 c0 + 9 c1 + 12 c2 --
// an earlier version of this line said twenty-three, which was a miscount of
// this file and is corrected rather than quietly dropped; the MEASUREMENT below
// was taken on the real tree and is unaffected by it):
//
//     N=30  fenix6   Found 274 members in module 'globals', exceeding 253
//     N=9   fenix6 / fenix6pro / fenix6spro / fenix6xpro   BUILD SUCCESSFUL
//     N=10  all four   Found 254 members in module 'globals', exceeding 253
//
// so 274 - 30 = 244 used, and the LIMIT IS INCLUSIVE -- at 244 the ninth added
// test lands on 253 and BUILDS, and it is the tenth that reds. The machine-
// readable line scripts/check_ceiling_notes.py checks:
//
//     CEILING core-reliability fenix6-family: 244 used of 253, 9 free -- the 10th file-scope (:test) added reds
//
// One member more than main's 243 (ErgUnitsTest.mc's `erg-r5` note, re-measured
// here and confirmed unchanged), and that one member is this file's `module`
// block. Twenty-six file-scope cases would have cost twenty-six -- seventeen
// more than the nine free, so this file at file scope would red the required
// compile-unit-test check on four devices with an error naming neither the test
// nor the file.
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
    // makeChannel() entries. Counted because #151 turns on whether a channel
    // that failed to open is RELEASED: the `mChannel == null` guard in
    // openChannel means a retained one is reused, and "was a fresh channel
    // allocated for the next attempt" is the observable form of that question
    // that a double can answer. $.QuietFailChannel carries no release recorder.
    var makes;

    function initialize() {
        CoreTempSensor.initialize();   // re-enters the overrides below
        if (opens   == null) { opens   = 0; }
        if (runaway == null) { runaway = false; }
        if (asked   == null) { asked   = []; }
        if (makes   == null) { makes   = 0; }
    }

    // Counted by the concrete probes' makeChannel overrides, which run before
    // this class's own fields exist -- hence the lazy guard, for the reason the
    // class comment states.
    function noteMake() {
        if (makes == null) { makes = 0; }
        makes++;
    }
    function makeCount() { if (makes == null) { makes = 0; } return makes; }

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
        makes   = 0;
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
        noteMake();
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
        noteMake();
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
        noteMake();
        chan = new $.QuietFailChannel();
        return chan;
    }
    hidden function makeRetryTimer() { return new RelTimer(); }
}

// A quietly-failing channel AND a Timer that cannot be armed -- the correlated
// resource exhaustion, which is the interleaving #161's bound has to survive.
class RelQuietDeadProbe extends RelProbe {
    function initialize() { RelProbe.initialize(); }
    hidden function makeChannel()    { noteMake(); return new $.QuietFailChannel(); }
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

// ---- #165 c1: the page-0x00 extractors and the grown wire format ------------
// Green from the commit that adds ctPage0Quality/ctPage0HrSupport and slot 24
// onward, and green after the fix wires them into onBroadcast.
//
// WHAT THESE ARE NOT. They feed bytes this file chose to a decoder this branch
// wrote, and both encode the same layout, read from ONE unmeasured source. They
// restate that assumption; they do not verify it, and no case here is evidence
// about what a CORE pod transmits. What they do verify is that the extraction is
// the function it is documented to be rather than the vendor's buggy one, and
// that absence is not rendered as a value.

// THE MASK AND THE OFFSET, swept over the whole domain byte 2 can carry.
//
// A RETRACTION LIVES HERE, and it is why this case is named what it is. An
// earlier version was called ...AvoidsTheVendorPrecedenceBug and claimed to
// separate `(payload[2] & 0x03) + 1` from the vendor example's unparenthesised
// `payload[2] & 0x03 + 1`, which #165 calls a precedence defect binding as
// `payload[2] & 4`. THAT IS WRONG FOR MONKEY C, and the vendor's file is Monkey
// C. Reverting the source to the unparenthesised spelling was run as a mutant
// and the whole suite stayed GREEN -- 342 passed -- which is what prompted the
// direct measurement: on fr965 / SDK 9.2.0, `raw & 0x03 + 1` with raw = 2
// evaluates to 3, i.e. `&` binds TIGHTER than `+`, not looser. So no test can
// distinguish the two spellings, and a case named for that distinction was
// claiming an assurance it did not provide.
//
// WHAT THE SWEEP DOES GUARD, which is a live risk rather than a phantom one: a
// mask widened to three bits (`& 0x07` agrees with `& 0x03` on half the domain
// and is caught here), a missing or doubled +1, and a read of the wrong byte.
(:test) function test_cr_c1_theQualityCodeIsTheLowTwoBitsPlusOne(logger) {
    var ok = true;
    for (var b = 0x00; b <= 0xFE; b++) {
        var got = CoreTempSensor.ctPage0Quality(relPage0(b, 0));
        var want = (b & 0x03) + 1;
        if (got != want) {
            logger.error("ctPage0Quality(byte2 = " + b + ") = " + got + ", expected " + want);
            return false;
        }
    }
    // The endpoints of the documented 1..4 range, named so a failure message
    // says which end moved.
    if (CoreTempSensor.ctPage0Quality(relPage0(0x00, 0)) != 1) {
        logger.error("ctPage0Quality(byte2 = 0x00) = " +
                     CoreTempSensor.ctPage0Quality(relPage0(0x00, 0)) +
                     ", expected 1; the code is 1-based, not 0-based");
        ok = false;
    }
    if (CoreTempSensor.ctPage0Quality(relPage0(0x03, 0)) != 4) {
        logger.error("ctPage0Quality(byte2 = 0x03) = " +
                     CoreTempSensor.ctPage0Quality(relPage0(0x03, 0)) + ", expected 4");
        ok = false;
    }
    // ...and the high bits of byte 2 must not leak into the answer.
    if (CoreTempSensor.ctPage0Quality(relPage0(0xFC, 0)) != 1) {
        logger.error("ctPage0Quality(byte2 = 0xFC) = " +
                     CoreTempSensor.ctPage0Quality(relPage0(0xFC, 0)) +
                     ", expected 1; only the low two bits carry the code");
        ok = false;
    }
    return ok;
}

// THE DISREGARD MARKER IS ABSENCE, NOT A CODE.
//
// byte 2 == 0xFF is the pod saying "disregard this broadcast". Every value the
// arithmetic can produce is a legal 1..4 rating, so there is no in-band code
// point that could carry "no rating" -- exactly the situation decodeHsi is in,
// and exactly the trap #86/#107 cost this repository twice by returning a
// number for absence.
//
// Note that 0xFF would otherwise arithmetic to 4, which is a perfectly
// plausible-looking rating. That is the whole reason the marker is tested
// BEFORE the arithmetic rather than after.
(:test) function test_cr_c1_theDisregardMarkerIsNullNotAFourthCode(logger) {
    var ok = true;
    if (CoreTempSensor.ctPage0Quality(relPage0($.CT_PAGE0_Q_INVALID, 0)) != null) {
        logger.error("ctPage0Quality(byte2 = 0xFF) = " +
                     CoreTempSensor.ctPage0Quality(relPage0($.CT_PAGE0_Q_INVALID, 0)) +
                     "; the marker must be NULL. It arithmetics to 4, an entirely " +
                     "plausible-looking rating, which is why it is tested first");
        ok = false;
    }
    // ...and the marker must not become a flag bit either.
    if (CoreTempSensor.ctQualityBit(CoreTempSensor.ctPage0Quality(relPage0($.CT_PAGE0_Q_INVALID, 0))) != 0) {
        logger.error("the disregard marker produced a quality bit; absence is not a code");
        ok = false;
    }
    if (CoreTempSensor.ctQualityBit(null) != 0 || CoreTempSensor.ctQualityBit(0) != 0 ||
        CoreTempSensor.ctQualityBit(5) != 0) {
        logger.error("ctQualityBit must answer 0 outside 1..4, got " +
                     CoreTempSensor.ctQualityBit(null) + ", " + CoreTempSensor.ctQualityBit(0) +
                     ", " + CoreTempSensor.ctQualityBit(5));
        ok = false;
    }
    return ok;
}

// THE HEART-RATE-SUPPORT FIELD, swept over all 256 values of byte 3.
//
// Per #165 the code is bits 6:7. The live confusion risk is not precedence --
// see the retraction on the quality case above, and the measurement it records
// -- it is READING THE WRONG FIELD: bits 2:3 of the same byte carry the UTC
// request, and `(p[3] & 0x0C) >> 2` returns equally plausible small integers.
// The sweep is what separates the two, and the last assertion names it.
(:test) function test_cr_c1_theHeartRateSupportFieldIsTheTopTwoBits(logger) {
    var ok = true;
    for (var b = 0x00; b <= 0xFF; b++) {
        var got  = CoreTempSensor.ctPage0HrSupport(relPage0(0, b));
        var want = (b & 0xC0) >> 6;
        if (got != want) {
            logger.error("ctPage0HrSupport(byte3 = " + b + ") = " + got + ", expected " + want);
            return false;
        }
    }
    // The two values #165 gives a meaning to, named so a failure says which.
    if (CoreTempSensor.ctPage0HrSupport(relPage0(0, relHrByte(1))) != 1) {
        logger.error("the pod's REQUESTING-heart-rate code did not read back as 1");
        ok = false;
    }
    if (CoreTempSensor.ctPage0HrSupport(relPage0(0, relHrByte(2))) != 2) {
        logger.error("the pod's HAS-heart-rate code did not read back as 2");
        ok = false;
    }
    // The low bits of byte 3 carry the UTC-request field, which this branch
    // deliberately does not act on. They must not leak into this answer.
    if (CoreTempSensor.ctPage0HrSupport(relPage0(0, relHrByte(0) | 0x3F)) != 0) {
        logger.error("the low six bits of byte 3 leaked into the heart-rate-support code; " +
                     "an extractor reading bits 2:3 answers the UTC request instead, in the " +
                     "same plausible 0..3 range");
        ok = false;
    }
    return ok;
}

// THE NEW FLAG BITS, and the wire format they live in.
//
// Three separate properties, all of which a mistake could satisfy one of:
//
//   * the nine new bits are distinct from each other AND from the four that
//     already exist. A collision would silently make two observations one;
//   * Q1..Q4 and HR0..HR3 are CONTIGUOUS runs, because ctQualityBit and
//     ctHrSupportBit shift rather than branch. Renumber one and the shift maps
//     the wrong code to the wrong bit while every distinctness check stays
//     green;
//   * the whole slot still fits the UINT16 the ct_diag field is typed as. The
//     readout clamps at CT_DIAG_MAX, so a bit above the ceiling would be
//     silently truncated at save rather than reported.
(:test) function test_cr_c1_theNewFlagBitsAreContiguousAndDistinct(logger) {
    var bits = [$.CT_DIAG_F_CHANNEL_HELD, $.CT_DIAG_F_CLOSED, $.CT_DIAG_F_EVER_SEEN,
                $.CT_DIAG_F_RETRY_LOST,
                $.CT_DIAG_F_Q1, $.CT_DIAG_F_Q2, $.CT_DIAG_F_Q3, $.CT_DIAG_F_Q4,
                $.CT_DIAG_F_Q_NONE,
                $.CT_DIAG_F_HR0, $.CT_DIAG_F_HR1, $.CT_DIAG_F_HR2, $.CT_DIAG_F_HR3];
    var ok = true;
    var all = 0;
    for (var i = 0; i < bits.size(); i++) {
        if (bits[i] <= 0) {
            logger.error("flag bit " + i + " = " + bits[i] + "; a zero bit can never be read back");
            ok = false;
        }
        if ((all & bits[i]) != 0) {
            logger.error("flag bit " + bits[i] + " collides with an earlier one; two observations " +
                         "would silently become one");
            ok = false;
        }
        all |= bits[i];
    }
    if (all > $.CT_DIAG_MAX) {
        logger.error("the flags slot can reach " + all + ", above the UINT16 ceiling " +
                     $.CT_DIAG_MAX + "; the readout clamp would silently truncate it at save");
        ok = false;
    }
    // Contiguity, asserted THROUGH the shifting helpers rather than on the
    // constants: that is what actually breaks if a bit is renumbered.
    var q = [$.CT_DIAG_F_Q1, $.CT_DIAG_F_Q2, $.CT_DIAG_F_Q3, $.CT_DIAG_F_Q4];
    for (var i = 0; i < 4; i++) {
        if (CoreTempSensor.ctQualityBit(i + 1) != q[i]) {
            logger.error("ctQualityBit(" + (i + 1) + ") = " + CoreTempSensor.ctQualityBit(i + 1) +
                         ", expected " + q[i] + "; the helper shifts, so Q1..Q4 must be contiguous");
            ok = false;
        }
    }
    var h = [$.CT_DIAG_F_HR0, $.CT_DIAG_F_HR1, $.CT_DIAG_F_HR2, $.CT_DIAG_F_HR3];
    for (var i = 0; i < 4; i++) {
        if (CoreTempSensor.ctHrSupportBit(i) != h[i]) {
            logger.error("ctHrSupportBit(" + i + ") = " + CoreTempSensor.ctHrSupportBit(i) +
                         ", expected " + h[i] + "; the helper shifts, so HR0..HR3 must be contiguous");
            ok = false;
        }
    }
    if (CoreTempSensor.ctHrSupportBit(null) != 0 || CoreTempSensor.ctHrSupportBit(-1) != 0 ||
        CoreTempSensor.ctHrSupportBit(4) != 0) {
        logger.error("ctHrSupportBit must answer 0 outside 0..3");
        ok = false;
    }
    // The array grew, and the version moved with it. These two must never be
    // edited apart: the createField :count reads CT_DIAG_SLOTS, and a setData
    // array longer than :count is an uncatchable System Error that kills the
    // app at save time and takes the whole activity with it.
    if ($.CT_DIAG_SLOTS != 25) {
        logger.error("CT_DIAG_SLOTS = " + $.CT_DIAG_SLOTS + ", expected 25");
        ok = false;
    }
    if ($.CT_DIAG_VERSION != 4) {
        logger.error("CT_DIAG_VERSION = " + $.CT_DIAG_VERSION + ", expected 4");
        ok = false;
    }
    if ($.CT_DIAG_I_PAGE0 != 24) {
        logger.error("CT_DIAG_I_PAGE0 = " + $.CT_DIAG_I_PAGE0 + ", expected 24 -- the new slot goes " +
                     "on the END, or every index after it is silently re-labelled in files already written");
        ok = false;
    }
    // ...and the readout must already carry the new slot, at zero, before
    // anything populates it. A snapshot short of CT_DIAG_SLOTS would be
    // accepted by setData without complaint and leave the slot absent.
    var p = new RelOkProbe();
    p.reset();
    if (p.slot($.CT_DIAG_I_PAGE0) != 0) {
        logger.error("slot 24 reads " + p.slot($.CT_DIAG_I_PAGE0) + " on a sensor that has seen " +
                     "no frame at all; it must be present and zero");
        ok = false;
    }
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

// ---- #151 c2: red differentials ---------------------------------------------
// Every case below FAILS on the code as of the previous commit and passes after
// the fix. Nothing else is in the commit that adds them.
//
// All five start from a probe whose channel's open() returns FALSE and throws
// nothing. Before the fix that channel is opened ONCE, from the constructor, and
// then nothing at all happens: no release, no mFails, no retry -- the whole
// point of #151.

// THE OUTAGE. A channel that failed to open must engage the retry ladder,
// because nothing else can: no MSG_CODE_EVENT_CHANNEL_CLOSED can arrive on a
// channel that never opened, and onChannelClosed is the only other thing that
// re-enters openChannel(). Before the fix CORE is dead for the rest of the app
// run with nothing on the screen to say so.
(:test) function test_cr_c2_aQuietlyFailedOpenEngagesTheLadder(logger) {
    var p = new RelQuietProbe();
    var ok = true;
    if (p.slot($.CT_DIAG_I_OPEN_ATTEMPTS) < 1) {
        logger.error("the probe never reached openChannel; nothing to assert on");
        return false;
    }
    if (p.slot($.CT_DIAG_I_MAX_FAILS) < 1) {
        logger.error("maxFails = " + p.slot($.CT_DIAG_I_MAX_FAILS) + " after an open that returned " +
                     "FALSE; a failure that does not raise the ladder is a failure the ladder " +
                     "cannot pace");
        ok = false;
    }
    if (p.asks().size() < 1) {
        logger.error("delays requested = " + p.asks().size() + " after an open that returned FALSE; " +
                     "nothing else re-enters openChannel(), so CORE is dead for the rest of the run");
        ok = false;
    }
    return ok;
}

// THE REUSE. openChannel's `if (mChannel == null)` guard means a retained
// channel is REUSED by the next attempt, so a channel that failed to open would
// be handed straight back to the open that is meant to recover from it.
// Releasing it matters as much as scheduling the retry.
//
// Asserted as "a fresh channel was allocated for the next attempt", which is the
// observable form a double can answer: makeChannel() must have run once per
// attempt, and no channel may be held at the end.
(:test) function test_cr_c2_aQuietlyFailedOpenHandsTheChannelBack(logger) {
    var p = new RelQuietProbe();
    var ok = true;
    if (p.channelHeld()) {
        logger.error("mChannel is still set after an open that returned FALSE; the `mChannel == " +
                     "null` guard would hand that same channel to the next attempt");
        ok = false;
    }
    if (p.makeCount() != p.openCount()) {
        logger.error("makeChannel() ran " + p.makeCount() + " times against " + p.openCount() +
                     " open attempts; a failed open must be followed by a FRESH allocation, not a reuse");
        ok = false;
    }
    if (p.openCount() < 2) {
        logger.error("only " + p.openCount() + " open attempt(s) happened, so 'one allocation per " +
                     "attempt' is vacuously true; the ladder must have retried");
        ok = false;
    }
    return ok;
}

// #161'S BOUND ON THE NEW PATH. The fix adds a second caller of the handler
// whose zero-delay branch re-enters openChannel() from inside openChannel(). It
// therefore inherits the arithmetic bound, and the bound has to be pinned on it:
// exactly CT_BURST_TRIES attempts, the burst's delays all zero, then one
// CT_BACKOFF_BASE_MS ask, and no further re-entry.
//
// The probe's cap turns a restored recursion into a failed assertion rather than
// a hung test -- although on fr965 / SDK 9.2.0 the simulator's own stack limit
// fires first, at the eleventh nested frame, so the observation is an ERROR.
(:test) function test_cr_c2_aQuietlyFailedOpenIsBoundedByTheBurst(logger) {
    var p = new RelQuietProbe();
    var ok = true;
    if (p.ranAway()) {
        logger.error("openChannel <-> scheduleReopen recursed past the probe's cap on the " +
                     "quiet-failure path; that is #161 reintroduced through a new caller");
        return false;
    }
    if (p.openCount() != $.CT_BURST_TRIES) {
        logger.error("open attempts = " + p.openCount() + ", expected exactly " + $.CT_BURST_TRIES +
                     ": the burst, and then a deferred retry");
        ok = false;
    }
    var a = p.asks();
    if (a.size() != $.CT_BURST_TRIES) {
        logger.error("delays requested = " + a.size() + ", expected " + $.CT_BURST_TRIES);
        return false;
    }
    for (var i = 0; i < a.size() - 1; i++) {
        if (a[i] != 0) {
            logger.error("delay[" + i + "] = " + a[i] + ", expected 0 inside the burst");
            ok = false;
        }
    }
    if (a[a.size() - 1] != $.CT_BACKOFF_BASE_MS) {
        logger.error("the first deferred retry asked for " + a[a.size() - 1] + ", expected " +
                     $.CT_BACKOFF_BASE_MS + "; a quiet failure must be paced exactly as a throw is");
        ok = false;
    }
    return ok;
}

// THE DIAGNOSTIC KEY, restated against the new behaviour.
//
// openAttempts - openOk - openThrow is the quiet-failure residual, and it stays
// EXACTLY that: every retry a quiet failure now causes is another attempt with
// no openOk and no openThrow, so the residual counts all of them rather than the
// single one that used to end the run. What must not happen is a quiet failure
// leaking into openOk (it is not a success) or into openThrow (it did not throw).
(:test) function test_cr_c2_theQuietFailureResidualStillCountsQuietFailures(logger) {
    var p = new RelQuietProbe();
    var attempts = p.slot($.CT_DIAG_I_OPEN_ATTEMPTS);
    var okCount  = p.slot($.CT_DIAG_I_OPEN_OK);
    var thrown   = p.slot($.CT_DIAG_I_OPEN_THROW);
    var ok = true;
    if (okCount != 0) {
        logger.error("openOk = " + okCount + "; open() returned false every time, so nothing opened");
        ok = false;
    }
    if (thrown != 0) {
        logger.error("openThrow = " + thrown + "; a quiet false is not a throw, and slot 3's key is " +
                     "\"the catch was entered\"");
        ok = false;
    }
    if (attempts - okCount - thrown != $.CT_BURST_TRIES) {
        logger.error("attempts - openOk - openThrow = " + (attempts - okCount - thrown) +
                     ", expected " + $.CT_BURST_TRIES + ": the residual is the quiet-failure count, " +
                     "and every retry a quiet failure causes is another quiet failure");
        ok = false;
    }
    return ok;
}

// THE CORRELATED EXHAUSTION. The resource state that makes an ANT open fail is
// the one that makes a Timer allocation fail, so the two have to be pinned
// TOGETHER or the interleaving is unpinned. With both failing, the ladder must
// still stop at the burst -- and the dropped retry must be READABLE in the file,
// or a fix that avoids a crash has only traded one invisible failure for another.
(:test) function test_cr_c2_aQuietOpenAndAnUnarmableTimerStillTerminate(logger) {
    var p = new RelQuietDeadProbe();
    var ok = true;
    if (p.ranAway()) {
        logger.error("the quiet-failure path recursed past the probe's cap with an unarmable timer");
        return false;
    }
    if (p.openCount() != $.CT_BURST_TRIES) {
        logger.error("open attempts = " + p.openCount() + ", expected exactly " + $.CT_BURST_TRIES);
        ok = false;
    }
    var f = p.slot($.CT_DIAG_I_FLAGS);
    if (f < 0) {
        logger.error("the flags slot is unreadable");
        return false;
    }
    if ((f & $.CT_DIAG_F_RETRY_LOST) == 0) {
        logger.error("flags = " + f + " after a retry was dropped for want of a timer on the " +
                     "quiet-failure path; CT_DIAG_F_RETRY_LOST must be set, or the file cannot tell " +
                     "a stalled ladder from one still waiting");
        ok = false;
    }
    // ...and the armed control must leave it clear, or the bit diagnoses nothing.
    var armed = new RelQuietProbe();
    if ((armed.slot($.CT_DIAG_I_FLAGS) & $.CT_DIAG_F_RETRY_LOST) != 0) {
        logger.error("flags = " + armed.slot($.CT_DIAG_I_FLAGS) + " on a probe whose retry timer " +
                     "ARMED; a bit that is always set is not a diagnostic");
        ok = false;
    }
    return ok;
}

// ---- #122 c2: red differentials ---------------------------------------------

// THE FIX ITSELF. A pod that has been heard from this session must never be
// asked to wait longer than CT_BACKOFF_NEAR_MAX_MS, and the cap must actually be
// REACHED in the run -- an assertion that only the ceiling holds is satisfiable
// by a ladder that never climbs.
//
// Before the fix the ninth ask is CT_BACKOFF_MAX_MS: five minutes of silence
// after a pod that was broadcasting a moment ago.
(:test) function test_cr_c2_aPodThatWasNearGetsTheShorterCap(logger) {
    var p = new RelOkProbe();
    p.reset();
    p.feed($.ctPayload(660, 0x0C8, 3742));   // a tracked page-1 frame: the pod is near
    for (var i = 0; i < 10; i++) { p.closeEvent(); }
    var a = p.asks();
    var ok = true;
    if (a.size() != 10) {
        logger.error("delays requested = " + a.size() + ", expected 10");
        return false;
    }
    for (var i = 0; i < a.size(); i++) {
        if (a[i] > $.CT_BACKOFF_NEAR_MAX_MS) {
            logger.error("delay[" + i + "] = " + a[i] + " exceeds CT_BACKOFF_NEAR_MAX_MS " +
                         $.CT_BACKOFF_NEAR_MAX_MS + "; a pod that was broadcasting a moment ago " +
                         "must not be left unheard that long");
            ok = false;
        }
    }
    if (p.worstAsk() != $.CT_BACKOFF_NEAR_MAX_MS) {
        logger.error("the longest delay asked for was " + p.worstAsk() + ", expected the cap " +
                     $.CT_BACKOFF_NEAR_MAX_MS + "; a ladder that never reaches its cap makes the " +
                     "ceiling assertion above vacuous");
        ok = false;
    }
    return ok;
}

// THE SAME THING IN THE UNITS #122 IS ABOUT. The worst wait a near pod is
// actually subjected to, run through the same duty function the source comment
// quotes -- so this case fails with the number the issue was filed on (91)
// rather than with a raw millisecond count.
(:test) function test_cr_c2_aNearPodsWorstCaseListenDutyIsTheShortenedOne(logger) {
    var p = new RelOkProbe();
    p.reset();
    p.feed($.ctPayload(660, 0x0C8, 3742));
    for (var i = 0; i < 10; i++) { p.closeEvent(); }
    var worst = p.worstAsk();
    if (worst < 0) {
        logger.error("no delay was ever requested; nothing to measure");
        return false;
    }
    var duty = CoreTempSensor.ctDutyPerMille($.CT_SEARCH_WINDOW_MS, worst);
    if (duty != 333) {
        logger.error("steady-state listen duty for a pod that WAS near = " + duty + " per mille " +
                     "(worst wait " + worst + " ms); expected 333. 91 is the 9.1 % #122 was filed on.");
        return false;
    }
    return true;
}

// THE PACING RESET IS ABOUT THE SEARCH, NOT ABOUT THE PAGE.
//
// mFails counts consecutive FAILED SEARCHES. A payload arriving at all means the
// search found the pod, whatever page the frame was on -- so the reset belongs
// above the page filter, not below it. Before the fix a pod broadcasting only
// the general-information page left the ladder climbing to five minutes while
// its frames were arriving.
//
// The assertion is that the next ask is ZERO, which isolates the reset: with the
// shorter cap alone the ask would be 60000, not 0.
(:test) function test_cr_c2_aTrackedFrameOfAnyPageResetsThePacing(logger) {
    var p = new RelOkProbe();
    p.reset();
    for (var i = 0; i < 6; i++) { p.closeEvent(); }
    if (p.lastAsk() <= 0) {
        logger.error("the ladder had not climbed before the frame (last ask = " + p.lastAsk() +
                     "); the case would be vacuous");
        return false;
    }
    p.feed(relPage0(0x01, relHrByte(1)));   // page 0x00: tracked, not decodable
    p.closeEvent();
    var ok = true;
    if (p.lastAsk() != 0) {
        logger.error("after a tracked page-0x00 frame the next delay was " + p.lastAsk() +
                     ", expected 0: mFails paces the SEARCH, and a frame arriving at all means " +
                     "the search found the pod");
        ok = false;
    }
    // ...and the reset must be a RESET, not a one-off suppression: the ladder
    // climbs again from the bottom of the burst rather than resuming where it
    // left off.
    //
    // THREE more closes, not four, and the arithmetic is worth spelling out
    // because an earlier version of this case got it wrong and asserted 30000
    // one close too early. The burst is CT_BURST_TRIES = 4 long and mFails
    // equals the number of closes SINCE the reset, so closes 1, 2 and 3 ask for
    // 0 and the FOURTH -- the one already spent above -- is the first deferred
    // one. The count here is therefore CT_BURST_TRIES - 1.
    for (var i = 0; i < $.CT_BURST_TRIES - 1; i++) { p.closeEvent(); }
    if (p.lastAsk() != $.CT_BACKOFF_BASE_MS) {
        logger.error("close " + $.CT_BURST_TRIES + " after the reset asked for " + p.lastAsk() +
                     ", expected " + $.CT_BACKOFF_BASE_MS + ": the ladder must restart at the " +
                     "bottom of the burst, not resume where it left off");
        ok = false;
    }
    return ok;
}

// ---- #165 c2: red differentials ---------------------------------------------

// THE COUNT. Page 0x00 gets its own tally, and slot 8 keeps its old meaning --
// so pageOther - page0 is the count of pages that are still genuinely unknown.
(:test) function test_cr_c2_aPageZeroFrameIsCountedInItsOwnSlot(logger) {
    var p = new RelOkProbe();
    p.reset();
    p.feed(relPage0(0x00, 0));
    p.feed(relPage0(0x00, 0));
    var other = $.ctPayload(660, 0x0C8, 3742);
    other[0] = 0x50;                       // an ANT+ common page: still unknown
    p.feed(other);
    p.feed($.ctPayload(660, 0x0C8, 3742)); // page 1
    var ok = true;
    if (p.slot($.CT_DIAG_I_PAGE0) != 2) {
        logger.error("page0 = " + p.slot($.CT_DIAG_I_PAGE0) + ", expected 2");
        ok = false;
    }
    if (p.slot($.CT_DIAG_I_PAGE_OTHER) != 3) {
        logger.error("pageOther = " + p.slot($.CT_DIAG_I_PAGE_OTHER) + ", expected 3; slot 8's key " +
                     "is \"page byte != 0x01\" and page 0x00 must keep satisfying it");
        ok = false;
    }
    if (p.slot($.CT_DIAG_I_PAGE_OTHER) - p.slot($.CT_DIAG_I_PAGE0) != 1) {
        logger.error("pageOther - page0 = " +
                     (p.slot($.CT_DIAG_I_PAGE_OTHER) - p.slot($.CT_DIAG_I_PAGE0)) +
                     ", expected 1: the count of pages that are still genuinely unknown");
        ok = false;
    }
    if (p.slot($.CT_DIAG_I_PAGE1) != 1) {
        logger.error("page1 = " + p.slot($.CT_DIAG_I_PAGE1) + ", expected 1; page 0x00 must not " +
                     "be counted as a temperature frame");
        ok = false;
    }
    return ok;
}

// THE QUALITY CODES, as a mask of what was ever seen.
//
// Two frames carrying different codes must set two different bits, and no bit
// belonging to a code that never arrived. A latest-wins encoding would pass the
// first half and fail the second, which is exactly the encoding this branch
// argued against.
(:test) function test_cr_c2_theQualityCodesSeenReachTheFlags(logger) {
    var p = new RelOkProbe();
    p.reset();
    p.feed(relPage0(0x00, 0));   // (0 & 3) + 1 = 1
    p.feed(relPage0(0x02, 0));   // (2 & 3) + 1 = 3
    var f = p.slot($.CT_DIAG_I_FLAGS);
    var ok = true;
    if (f < 0) {
        logger.error("the flags slot is unreadable");
        return false;
    }
    if ((f & $.CT_DIAG_F_Q1) == 0) {
        logger.error("flags = " + f + "; quality code 1 arrived and its bit is clear");
        ok = false;
    }
    if ((f & $.CT_DIAG_F_Q3) == 0) {
        logger.error("flags = " + f + "; quality code 3 arrived and its bit is clear -- a mask " +
                     "records every code seen, not the last one");
        ok = false;
    }
    if ((f & $.CT_DIAG_F_Q2) != 0 || (f & $.CT_DIAG_F_Q4) != 0) {
        logger.error("flags = " + f + "; a bit is set for a quality code that never arrived");
        ok = false;
    }
    if ((f & $.CT_DIAG_F_Q_NONE) != 0) {
        logger.error("flags = " + f + "; the disregard marker never arrived and its bit is set");
        ok = false;
    }
    return ok;
}

// THE ASK NOBODY ANSWERS. heartRateSupport == 1 means the pod is requesting a
// heart rate and is running its core-temperature estimate without one. #165's
// central claim is that this happens on every row and is invisible in the file.
// The bit is what makes it visible; replying is a transmit path and is
// deliberately out of scope on this branch.
(:test) function test_cr_c2_theHeartRateRequestReachesTheFlags(logger) {
    var p = new RelOkProbe();
    p.reset();
    p.feed(relPage0(0x00, relHrByte(1)));   // asking for a heart rate
    p.feed(relPage0(0x00, relHrByte(2)));   // ...and later, has one
    var f = p.slot($.CT_DIAG_I_FLAGS);
    var ok = true;
    if (f < 0) {
        logger.error("the flags slot is unreadable");
        return false;
    }
    if ((f & $.CT_DIAG_F_HR1) == 0) {
        logger.error("flags = " + f + "; the pod ASKED for a heart rate and the bit that records it " +
                     "is clear -- that ask is the whole evidence for the transmit-path follow-up");
        ok = false;
    }
    if ((f & $.CT_DIAG_F_HR2) == 0) {
        logger.error("flags = " + f + "; the pod later reported HAVING a heart rate and its bit is clear");
        ok = false;
    }
    if ((f & $.CT_DIAG_F_HR0) != 0 || (f & $.CT_DIAG_F_HR3) != 0) {
        logger.error("flags = " + f + "; a bit is set for a heart-rate-support code that never arrived");
        ok = false;
    }
    return ok;
}

// ABSENCE IS NOT A CODE, at the wire this time rather than at the extractor.
//
// byte 2 == 0xFF arithmetics to 4, so the failure mode this guards is a pod
// saying "disregard this" and the file recording "quality 4" -- a perfectly
// plausible-looking rating, indistinguishable afterwards from a real one. The
// marker gets its own bit and NO quality bit.
(:test) function test_cr_c2_theDisregardMarkerIsRecordedWithoutAQualityCode(logger) {
    var p = new RelOkProbe();
    p.reset();
    p.feed(relPage0($.CT_PAGE0_Q_INVALID, 0));
    var f = p.slot($.CT_DIAG_I_FLAGS);
    var ok = true;
    if (f < 0) {
        logger.error("the flags slot is unreadable");
        return false;
    }
    if ((f & $.CT_DIAG_F_Q_NONE) == 0) {
        logger.error("flags = " + f + "; the pod's own disregard marker arrived and left no trace");
        ok = false;
    }
    var anyQ = $.CT_DIAG_F_Q1 | $.CT_DIAG_F_Q2 | $.CT_DIAG_F_Q3 | $.CT_DIAG_F_Q4;
    if ((f & anyQ) != 0) {
        logger.error("flags = " + f + "; the disregard marker was recorded as a quality CODE. It " +
                     "arithmetics to 4, an entirely plausible rating, and a reader could never tell " +
                     "it apart from a real one afterwards");
        ok = false;
    }
    // ...and the frame is still counted as a page-0 frame: the marker is about
    // the pod's opinion of its data, not about whether the frame arrived.
    if (p.slot($.CT_DIAG_I_PAGE0) != 1) {
        logger.error("page0 = " + p.slot($.CT_DIAG_I_PAGE0) + ", expected 1");
        ok = false;
    }
    return ok;
}

}
