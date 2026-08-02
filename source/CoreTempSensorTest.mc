using Toybox.Test;
using Toybox.System;
using Toybox.Lang;

// Unit tests for source/CoreTempSensor.mc -- the CORE (greenTEG) ANT pod
// decoder and its channel lifecycle. Covers issues #86 (skin decoded from the
// wrong bytes), #19 (freshness window mismatch), #17 (skin/everSeen gated on
// core validity), #18 (channel leaked on throw) and #26 (unbounded re-search).
//
// These are (:test) functions: included in the --unit-test build and stripped
// from the shipping build. They EXECUTE on every PR (the run-tests CI job runs
// them headlessly in the simulator, judged by a fail-closed parser), and their
// names are pinned in scripts/expected_tests.txt -- adding or removing a test
// here means editing that file in the SAME commit. See docs/CI.md.
//
// c0: characterization pins only. Every assertion below is true BOTH before and
// after the five fixes land -- they exist to prove the c1 refactor is
// behaviour-preserving, not to describe the defects. The differentials that
// must go red before the fix are added later, in c2.

// -- Probe -------------------------------------------------------------------
// `hidden` in Monkey C is protected, so a subclass can reach the sensor's state
// without adding any accessor to the shipping class -- the same pattern as
// DspProbe in DspTimeBaseTest.mc. Referenced only from (:test) functions, so it
// drops out of the release build.
//
// MEASURED HAZARD -- do not remove the null guards. A base initialize() that
// calls an unqualified `hidden` method DISPATCHES TO THE SUBCLASS OVERRIDE, and
// it does so while the subclass's own fields are still null, because Monkey C
// requires Base.initialize() to complete before the subclass assigns anything.
// A null-symbol invocation raised inside a `catch` block is additionally NOT
// caught by any enclosing `try` -- it surfaces as a test ERROR, not a FAIL. So
// every override here lazy-initialises its own recorder on entry rather than
// trusting initialize() to have run.
class CoreProbe extends CoreTempSensor {

    var mOpens;
    var mDelays;
    var mCancels;
    var mFake;          // when set, makeChannel() returns this instead of ANT
    var mDepth;         // re-entrancy guard, see scheduleReopen

    function initialize() {
        CoreTempSensor.initialize();   // may re-enter the overrides below
        if (mOpens   == null) { mOpens   = 0; }
        if (mDelays  == null) { mDelays  = []; }
        if (mCancels == null) { mCancels = 0; }
    }

    // Counts the call, THEN runs the real body -- tests that assert on what
    // openChannel() does to the channel need the shipping code to execute.
    hidden function openChannel() {
        if (mOpens == null) { mOpens = 0; }
        mOpens++;
        CoreTempSensor.openChannel();
    }

    hidden function makeChannel() {
        if (mFake != null) { return mFake; }
        return CoreTempSensor.makeChannel();
    }

    // Records the requested delay and then reopens SYNCHRONOUSLY, standing in
    // for the one-shot Timer. Recording alone would be wrong: once the retry
    // path is the only route back into openChannel(), a record-only override
    // would make every open-count assertion trivially zero.
    hidden function scheduleReopen(delayMs) {
        if (mDelays == null) { mDelays = []; }
        mDelays.add(delayMs);
        // Stand in for the one-shot Timer. The reopen must be SYNCHRONOUS --
        // once the retry path is the only route back into openChannel(), a
        // record-only override makes every open-count assertion trivially 0 --
        // but it must NOT re-enter: the failure path schedules a retry from
        // inside openChannel()'s own catch, and a real Timer breaks that cycle
        // by deferring. This depth guard is what the Timer would have done.
        if (mDepth == null) { mDepth = 0; }
        if (mDepth > 0) { return; }
        mDepth++;
        // UNQUALIFIED on purpose: a qualified CoreTempSensor.openChannel() call
        // bypasses this class's own counting override, so every open-count
        // assertion would read 0 and stay red no matter what the fix does.
        openChannel();
        mDepth--;
    }

    hidden function cancelReopen() {
        if (mCancels == null) { mCancels = 0; }
        mCancels++;
    }

    function opens() {
        if (mOpens == null) { mOpens = 0; }
        return mOpens;
    }

    function delays() {
        if (mDelays == null) { mDelays = []; }
        return mDelays;
    }

    function cancels() {
        if (mCancels == null) { mCancels = 0; }
        return mCancels;
    }

    function useFakeChannel(f) { mFake = f; mChannel = null; }

    // Baseline clear: initialize() runs openChannel() before any test body
    // starts, so counters are reset rather than compared against an assumed 0.
    function resetRecorders() {
        mOpens   = 0;
        mDelays  = [];
        mCancels = 0;
        mFails   = 0;
        mDepth   = 0;
    }

    // Deterministic clock forms -- see the *At(nowMs) note in CoreTempSensor.
    function coreTempAtT(nowMs) { return coreTempAt(nowMs); }
    function skinTempAtT(nowMs) { return skinTempAt(nowMs); }
    function isFreshAtT(nowMs)  { return isFreshAt(nowMs); }
    function coreFreshAtT(nowMs){ return coreFreshAt(nowMs); }
    function skinFreshAtT(nowMs){ return skinFreshAt(nowMs); }

    function feed(p)     { onBroadcast(p); }
    function closeEvent(){ onChannelClosed(); }

    // Stamp the freshness clock `ageMs` in the past and seed the readings.
    //
    // Clock-robust by construction: System.getTimer() is device uptime, which is
    // ~9.4e6 ms on this workstation's simulator but may be only a few thousand
    // in a fresh CI container. When `ageMs` exceeds the uptime the stamp goes
    // <= 0, which the getters treat as never-seen -- the SAME verdict a genuinely
    // stale stamp gets. Both c0 staleness pins therefore hold under either clock.
    function stamp(ageMs, core, skin) {
        mCore   = core;
        mSkin   = skin;
        mLastMs = System.getTimer() - ageMs;
        mCoreMs = mLastMs;
        mSkinMs = mLastMs;
    }

    // Absolute stamp for deterministic tests: pair with the *AtT(nowMs) forms
    // so no assertion depends on device uptime.
    function stampAt(coreMs, skinMs, core, skin) {
        mCore   = core;
        mSkin   = skin;
        mCoreMs = coreMs;
        mSkinMs = skinMs;
        mLastMs = (coreMs > skinMs) ? coreMs : skinMs;
    }
}

// A stand-in for Ant.GenericChannel. `open()` optionally throws, so the failure
// path in openChannel() becomes reachable; `release()` is recorded so a test
// can prove the channel was handed back rather than orphaned.
class FakeChannel {
    var released;
    var opened;
    var throwOnOpen;

    function initialize(doThrow) {
        released    = false;
        opened      = false;
        throwOnOpen = doThrow;
    }

    function setDeviceConfig(cfg) { }

    function open() {
        opened = true;
        if (throwOnOpen) { throw new Lang.Exception(); }
        return true;
    }

    function release() { released = true; return true; }
}

// -- c0 characterization pins ------------------------------------------------

// A freshly constructed sensor reports nothing. Also proves the constructor is
// safe to run in the headless simulator: openChannel() throws
// "Unable to acquire ANT Channel" there, which its own catch swallows, so no
// channel is acquired and none leaks.
(:test) function test_ct_initialStateIsCold(logger) {
    var s = new CoreTempSensor();
    var ok = true;
    if (s.everSeen() != false) { logger.error("everSeen should be false on a fresh sensor"); ok = false; }
    if (s.isFresh()  != false) { logger.error("isFresh should be false on a fresh sensor");  ok = false; }
    if (s.coreTemp() != 0.0)   { logger.error("coreTemp should be 0.0, got " + s.coreTemp()); ok = false; }
    if (s.skinTemp() != 0.0)   { logger.error("skinTemp should be 0.0, got " + s.skinTemp()); ok = false; }
    return ok;
}

// Just-stamped readings are returned and reported fresh. True under both the
// 15 s and the 30 s window, so it survives #19 either way.
(:test) function test_ct_freshReturnsValue(logger) {
    var p = new CoreProbe();
    p.stamp(0, 37.42, 33.00);
    var ok = true;
    if (p.coreTemp() != 37.42) { logger.error("coreTemp " + p.coreTemp() + " != 37.42"); ok = false; }
    if (p.skinTemp() != 33.00) { logger.error("skinTemp " + p.skinTemp() + " != 33.00"); ok = false; }
    if (p.isFresh()  != true)  { logger.error("isFresh should be true immediately after a stamp"); ok = false; }
    return ok;
}

// 60 s is past BOTH the 15 s isFresh() bound and the 30 s getter bound, which is
// exactly what makes this pin epoch-invariant: a 20 s age would NOT be, and that
// divergence is #19's differential (added in c2), not a characterization pin.
(:test) function test_ct_staleReturnsZero(logger) {
    var p = new CoreProbe();
    p.stamp(60000, 37.42, 33.00);
    var ok = true;
    if (p.coreTemp() != 0.0)  { logger.error("stale coreTemp should be 0.0, got " + p.coreTemp()); ok = false; }
    if (p.skinTemp() != 0.0)  { logger.error("stale skinTemp should be 0.0, got " + p.skinTemp()); ok = false; }
    if (p.isFresh()  != false){ logger.error("stale isFresh should be false"); ok = false; }
    return ok;
}

// -- c1 green pins on the new symbols ----------------------------------------
// These assert semantics that do NOT change when the fixes land, so they stay
// green from here to the final commit.

// Mirrors test_rr_freshConstUnchanged: pin the constant so a retune of the
// recorded-freshness window is visible rather than silently self-consistent.
(:test) function test_ct_freshConstUnchanged(logger) {
    if ($.CT_FRESH_MS != 30000) {
        logger.error("CT_FRESH_MS changed to " + $.CT_FRESH_MS);
        return false;
    }
    return true;
}

// Boundary semantics of the one freshness predicate: strict `<`, and a
// never-seen stamp is not fresh. Same contract as StrongRowView.rrIsFresh.
(:test) function test_ct_isFreshPredicate(logger) {
    var ok = true;
    if (CoreTempSensor.ctIsFresh(10000, 9000, 5000) != true)  { logger.error("fresh 1s should be true"); ok = false; }
    if (CoreTempSensor.ctIsFresh(10000, 4000, 5000) != false) { logger.error("stale 6s should be false"); ok = false; }
    if (CoreTempSensor.ctIsFresh(10000, 5000, 5000) != false) { logger.error("boundary == thresh must be false (strict <)"); ok = false; }
    if (CoreTempSensor.ctIsFresh(10000, 5001, 5000) != true)  { logger.error("just inside thresh should be true"); ok = false; }
    if (CoreTempSensor.ctIsFresh(10000, 0,    5000) != false) { logger.error("never-seen (ts=0) must be false"); ok = false; }
    if (CoreTempSensor.ctIsFresh(10000, -500, 5000) != false) { logger.error("negative stamp must be false"); ok = false; }
    return ok;
}

// 12-bit assembly: byte 3 supplies bits 0:7, byte 4 bits 4:7 supply bits 8:11,
// and byte 4's low nibble (Reserved) must not leak in.
(:test) function test_ct_skinRaw12Assembly(logger) {
    var ok = true;
    if (CoreTempSensor.skinRaw12(0x94, 0x28) != 0x294) { logger.error("skinRaw12(0x94,0x28) = " + CoreTempSensor.skinRaw12(0x94, 0x28)); ok = false; }
    if (CoreTempSensor.skinRaw12(0xFF, 0xFF) != 0xFFF) { logger.error("skinRaw12(0xFF,0xFF) = " + CoreTempSensor.skinRaw12(0xFF, 0xFF)); ok = false; }
    if (CoreTempSensor.skinRaw12(0x00, 0x0F) != 0x000) { logger.error("byte 4 low nibble leaked: " + CoreTempSensor.skinRaw12(0x00, 0x0F)); ok = false; }
    if (CoreTempSensor.skinRaw12(0x00, 0x80) != 0x800) { logger.error("skinRaw12(0x00,0x80) = " + CoreTempSensor.skinRaw12(0x00, 0x80)); ok = false; }
    return ok;
}

// Sign extension from bit 11. 0x800 is the most-negative code point, which is
// exactly why the vendor range is +/-102.35 (2047/20) and not +/-102.40.
(:test) function test_ct_sext12(logger) {
    var ok = true;
    if (CoreTempSensor.sext12(0x000) !=     0) { logger.error("sext12(0x000) = " + CoreTempSensor.sext12(0x000)); ok = false; }
    if (CoreTempSensor.sext12(0x7FF) !=  2047) { logger.error("sext12(0x7FF) = " + CoreTempSensor.sext12(0x7FF)); ok = false; }
    if (CoreTempSensor.sext12(0x800) != -2048) { logger.error("sext12(0x800) = " + CoreTempSensor.sext12(0x800)); ok = false; }
    if (CoreTempSensor.sext12(0xFFF) !=    -1) { logger.error("sext12(0xFFF) = " + CoreTempSensor.sext12(0xFFF)); ok = false; }
    return ok;
}

// The retry ladder: CT_BURST_TRIES back-to-back searches, then doubling to a
// cap. The burst prefix is what keeps discovery byte-identical to today.
(:test) function test_ct_backoffLadder(logger) {
    var exp = [[1, 0], [2, 0], [3, 0], [4, 30000], [5, 60000],
               [6, 120000], [7, 240000], [8, 300000], [12, 300000]];
    var ok = true;
    for (var i = 0; i < exp.size(); i++) {
        var got = CoreTempSensor.ctBackoffMs(exp[i][0]);
        if (got != exp[i][1]) {
            logger.error("ctBackoffMs(" + exp[i][0] + ") = " + got + " exp " + exp[i][1]);
            ok = false;
        }
    }
    return ok;
}

// -- c2 red differentials ----------------------------------------------------
// Every test below FAILS on the code as it stands and passes once the fixes
// land. Assertions are written null-safely so a wrong result reports as FAIL,
// not ERROR -- an ERROR carries no information about which behaviour is wrong.

function ctAlmostEq(a, b) {
    if (a == null) { return false; }
    var d = a - b;
    if (d < 0) { d = -d; }
    return d < 0.001;
}

// Build a page-0x01 payload from field values, per the layout in #86: byte 3 +
// byte 4 bits 4:7 = skin (12-bit signed), byte 4 bits 0:3 + byte 5 = reserved,
// bytes 6-7 = core little endian.
function ctPayload(skinRaw12, reserved12, coreRaw) {
    return [0x01,
            0x1E,
            0x64,
            skinRaw12 & 0xFF,
            ((skinRaw12 >> 4) & 0xF0) | (reserved12 & 0x0F),
            (reserved12 >> 4) & 0xFF,
            coreRaw & 0xFF,
            (coreRaw >> 8) & 0xFF];
}

// #86: skin's low 8 bits live in byte 3, which the shipped decode never reads.
(:test) function test_ct_skinDecodedFromByte3(logger) {
    var got = CoreTempSensor.decodeSkinC(ctPayload(0x294, 0x0C8, 3742));
    if (!ctAlmostEq(got, 33.00)) {
        logger.error("decodeSkinC = " + got + ", expected 33.00 (raw12 0x294 / 20)");
        return false;
    }
    return true;
}

// #86, the load-bearing property: the recorded value must MOVE with the real
// signal. The shipped decode returns the same number for 25.60, 33.00 and
// 38.30 because only skin's top nibble reaches it.
(:test) function test_ct_skinTracksTrueSignal(logger) {
    var raws = [512, 660, 766];             // 25.60, 33.00, 38.30 C
    var exps = [25.60, 33.00, 38.30];
    var ok = true;
    for (var i = 0; i < raws.size(); i++) {
        var got = CoreTempSensor.decodeSkinC(ctPayload(raws[i], 0x0C8, 3742));
        if (!ctAlmostEq(got, exps[i])) {
            logger.error("true skin " + exps[i] + " decoded as " + got);
            ok = false;
        }
    }
    return ok;
}

// #86, the converse: the Reserved field must not reach the result at all.
(:test) function test_ct_skinIgnoresReserved(logger) {
    var res = [0x000, 0x0C8, 0xFFF];
    var ok = true;
    for (var i = 0; i < res.size(); i++) {
        var got = CoreTempSensor.decodeSkinC(ctPayload(0x294, res[i], 3742));
        if (!ctAlmostEq(got, 33.00)) {
            logger.error("reserved " + res[i] + " changed skin to " + got);
            ok = false;
        }
    }
    return ok;
}

// #86: the documented invalid marker is 0x800 on the 12-bit field, not 0xFFFF
// on a 16-bit one.
(:test) function test_ct_skinInvalidSentinel(logger) {
    var got = CoreTempSensor.decodeSkinC(ctPayload(0x800, 0x0C8, 3742));
    if (got != null) {
        logger.error("skin raw 0x800 must decode as invalid, got " + got);
        return false;
    }
    return true;
}

// #86: the field is signed. 0xFFF is -1 -> -0.05 C, which the plausibility
// clamp then rejects -- it must not surface as a large positive temperature.
(:test) function test_ct_skinNegativeRejected(logger) {
    var got = CoreTempSensor.decodeSkinC(ctPayload(0xFFF, 0x0C8, 3742));
    if (got != null) {
        logger.error("skin raw 0xFFF (-0.05 C) must be rejected, got " + got);
        return false;
    }
    return true;
}

// #19: one freshness definition. At 20 s stale the getters still report the
// reading as current, so the CT pip must agree rather than greying out.
(:test) function test_ct_freshnessUnified(logger) {
    var p = new CoreProbe();
    p.stampAt(100000, 100000, 37.42, 33.00);
    var ok = true;
    if (p.isFreshAtT(120000) != true) {
        logger.error("isFresh at 20 s stale should agree with the getters (true)");
        ok = false;
    }
    if (p.coreTempAtT(120000) != 37.42) {
        logger.error("coreTemp at 20 s stale = " + p.coreTempAtT(120000));
        ok = false;
    }
    return ok;
}

// #17: a frame with valid skin but invalid core must still stamp freshness and
// latch everSeen. Core 0x8000 is 327.68 C, which the clamp rejects.
(:test) function test_ct_skinIndependentOfCore(logger) {
    var p = new CoreProbe();
    p.feed(ctPayload(660, 0x0C8, 0x8000));
    var ok = true;
    if (p.everSeen() != true)  { logger.error("everSeen must latch on a valid skin reading"); ok = false; }
    if (p.skinFresh() != true) { logger.error("skinFresh must be true after a valid skin frame"); ok = false; }
    if (!ctAlmostEq(p.skinTemp(), 33.00)) { logger.error("skinTemp = " + p.skinTemp() + ", expected 33.00"); ok = false; }
    return ok;
}

// #17 + #86: the converse. A frame with valid core but an INVALID skin field
// must not publish a skin number -- today the Reserved bytes supply one.
(:test) function test_ct_coreIndependentOfSkin(logger) {
    var p = new CoreProbe();
    p.feed(ctPayload(0x800, 0x0C8, 3742));
    var ok = true;
    if (!ctAlmostEq(p.coreTemp(), 37.42)) { logger.error("coreTemp = " + p.coreTemp() + ", expected 37.42"); ok = false; }
    if (p.skinTemp() != 0.0) { logger.error("skinTemp must stay 0.0 when the skin field is invalid, got " + p.skinTemp()); ok = false; }
    if (p.coreFresh() != true) { logger.error("coreFresh must be true after a valid core frame"); ok = false; }
    return ok;
}

// #26, pre-acquisition branch: `mTries < 3` gives 4 searches then permanent
// silence, so a pod donned after rigging is never found.
(:test) function test_ct_retryContinuesPastPreAcquisitionBound(logger) {
    var p = new CoreProbe();
    // A channel whose open() SUCCEEDS, so the retry ladder is measured on its
    // own. The real allocation always throws under the headless simulator,
    // which would drive the failure path and mix its retries into the count.
    p.useFakeChannel(new FakeChannel(false));
    p.resetRecorders();
    for (var i = 0; i < 6; i++) { p.closeEvent(); }
    if (p.opens() != 6) {
        logger.error("6 channel closes produced " + p.opens() + " re-opens; searching must not stop");
        return false;
    }
    return true;
}

// #26, post-acquisition branch: unbounded re-search with no backoff. The ladder
// must pace it, and any tracked frame must reset the pacing.
(:test) function test_ct_backoffLadderAndReset(logger) {
    var p = new CoreProbe();
    p.useFakeChannel(new FakeChannel(false));   // see the note in the test above
    p.resetRecorders();
    for (var i = 0; i < 6; i++) { p.closeEvent(); }
    var exp = [0, 0, 0, 30000, 60000, 120000];
    var got = p.delays();
    var ok = true;
    if (got.size() != exp.size()) {
        logger.error("delay count " + got.size() + " != " + exp.size());
        ok = false;
    } else {
        for (var i = 0; i < exp.size(); i++) {
            if (got[i] != exp[i]) { logger.error("delay[" + i + "] = " + got[i] + " exp " + exp[i]); ok = false; }
        }
    }
    p.feed(ctPayload(660, 0x0C8, 3742));   // a tracked frame resets the pacing
    p.closeEvent();
    var after = p.delays();
    if (after[after.size() - 1] != 0) {
        logger.error("a tracked frame must reset the backoff, next delay = " + after[after.size() - 1]);
        ok = false;
    }
    return ok;
}

// #18: a throw after allocation must hand the channel back. ANT channels are a
// scarce hardware resource, and because the reference is discarded close() can
// no longer release it.
(:test) function test_ct_openThrowReleasesChannel(logger) {
    var p = new CoreProbe();
    var f = new FakeChannel(true);
    p.resetRecorders();
    p.useFakeChannel(f);
    p.closeEvent();
    var ok = true;
    if (f.opened != true)   { logger.error("the fake channel's open() was never reached"); ok = false; }
    if (f.released != true) { logger.error("open() threw and the channel was never released"); ok = false; }
    return ok;
}

// #18 x #26: after the catch fires, mChannel is null and no further
// CHANNEL_CLOSED can arrive, so without a scheduled retry CORE is dead for the
// rest of the app run.
(:test) function test_ct_openThrowSchedulesRetry(logger) {
    var p = new CoreProbe();
    p.resetRecorders();
    p.useFakeChannel(new FakeChannel(true));
    p.closeEvent();
    if (p.delays().size() < 2) {
        logger.error("a failed open must schedule a retry; delays recorded = " + p.delays().size());
        return false;
    }
    return true;
}

// #26 lifecycle: a pending reopen must be cancelled on close, or a retry can
// re-open an ANT channel after shutdown.
(:test) function test_ct_closeCancelsPendingRetry(logger) {
    var p = new CoreProbe();
    p.resetRecorders();
    p.closeEvent();
    p.close();
    if (p.cancels() < 1) {
        logger.error("close() must cancel a pending reopen; cancelReopen calls = " + p.cancels());
        return false;
    }
    return true;
}

// ============================================================================
// #102 -- ANT diagnostic counters. A separate commit partition from everything
// above, with its own c0/c1/c2 sections below.
//
// The change is DIAGNOSTIC ONLY: it must not move a decoded value, a clamp, a
// freshness window or the retry ladder by one bit. The c0 pins immediately
// below are the mechanical half of that promise -- they fix the exact
// boundaries the new counters classify by, so a fix commit that shifted one of
// them could not stay green.
// ============================================================================

// -- #102 c0: characterization pins on existing symbols -----------------------
// Every assertion in this section is true on the code as it stands AND after
// the diagnostic counters land. They exist to prove the change is
// behaviour-preserving, not to describe a defect.

// decodeCoreC's documented invalid marker. Pinned as OBSERVABLE behaviour only:
// 0xFFFF is also outside the CT_CORE_MIN_C..MAX_C clamp (655.35 C), so this
// assertion cannot tell which of the two gates rejected it -- and that
// indistinguishability from outside is exactly why #102's counters have to
// re-test the sentinel themselves rather than read it off the return value.
// See the divergence note at CoreTempSensor.mc decodeCoreC (#87).
(:test) function test_ct_coreSentinelRejected(logger) {
    var got = CoreTempSensor.decodeCoreC(ctPayload(660, 0x0C8, 0xFFFF));
    if (got != null) {
        logger.error("core raw 0xFFFF must decode as invalid, got " + got);
        return false;
    }
    return true;
}

// The core plausibility clamp, at its bounds. raw * 0.01 against
// CT_CORE_MIN_C = 25.0 and CT_CORE_MAX_C = 45.0, both INCLUSIVE (the guard is
// `t < MIN || t > MAX`). These four values are the boundary the coreClamp
// counter keys off, so pinning them keeps the counter's meaning stable.
(:test) function test_ct_coreClampBounds(logger) {
    var ok = true;
    if (CoreTempSensor.decodeCoreC(ctPayload(660, 0x0C8, 2499)) != null) {
        logger.error("core 24.99 C is below the clamp and must be rejected");
        ok = false;
    }
    if (!ctAlmostEq(CoreTempSensor.decodeCoreC(ctPayload(660, 0x0C8, 2500)), 25.00)) {
        logger.error("core 25.00 C is the inclusive lower bound and must be accepted, got " +
                     CoreTempSensor.decodeCoreC(ctPayload(660, 0x0C8, 2500)));
        ok = false;
    }
    if (!ctAlmostEq(CoreTempSensor.decodeCoreC(ctPayload(660, 0x0C8, 4500)), 45.00)) {
        logger.error("core 45.00 C is the inclusive upper bound and must be accepted, got " +
                     CoreTempSensor.decodeCoreC(ctPayload(660, 0x0C8, 4500)));
        ok = false;
    }
    if (CoreTempSensor.decodeCoreC(ctPayload(660, 0x0C8, 4501)) != null) {
        logger.error("core 45.01 C is above the clamp and must be rejected");
        ok = false;
    }
    return ok;
}

// The skin plausibility clamp, at its bounds. sext12(raw) / 20.0 against
// CT_SKIN_MIN_C = 15.0 and CT_SKIN_MAX_C = 45.0, both inclusive -- so raw 300
// and raw 900 are the edge code points. Same role as the core pin above: the
// skinClamp counter's meaning is only stable while these hold.
(:test) function test_ct_skinClampBounds(logger) {
    var ok = true;
    if (CoreTempSensor.decodeSkinC(ctPayload(299, 0x0C8, 3742)) != null) {
        logger.error("skin 14.95 C is below the clamp and must be rejected");
        ok = false;
    }
    if (!ctAlmostEq(CoreTempSensor.decodeSkinC(ctPayload(300, 0x0C8, 3742)), 15.00)) {
        logger.error("skin 15.00 C is the inclusive lower bound and must be accepted, got " +
                     CoreTempSensor.decodeSkinC(ctPayload(300, 0x0C8, 3742)));
        ok = false;
    }
    if (!ctAlmostEq(CoreTempSensor.decodeSkinC(ctPayload(900, 0x0C8, 3742)), 45.00)) {
        logger.error("skin 45.00 C is the inclusive upper bound and must be accepted, got " +
                     CoreTempSensor.decodeSkinC(ctPayload(900, 0x0C8, 3742)));
        ok = false;
    }
    if (CoreTempSensor.decodeSkinC(ctPayload(901, 0x0C8, 3742)) != null) {
        logger.error("skin 45.05 C is above the clamp and must be rejected");
        ok = false;
    }
    return ok;
}

// -- #102 c1: green pins on the new symbols -----------------------------------
// These assert semantics that hold from the moment the symbols exist and do NOT
// move when the counters are wired up in the fix commit. Nothing here asserts
// that a counter is zero: a freshly constructed sensor runs openChannel() from
// its own initialize(), so "all counters zero" is true before the wiring and
// false after -- that is a c2 differential, not a c1 pin.

// The layout constants ARE the wire format of the ct_diag field. Pinned so that
// changing one without bumping CT_DIAG_VERSION cannot pass silently: every
// value already recorded in a FIT file is interpreted through this key.
(:test) function test_ct_diagLayoutConstants(logger) {
    var ok = true;
    if ($.CT_DIAG_SLOTS != 21)      { logger.error("CT_DIAG_SLOTS changed to " + $.CT_DIAG_SLOTS + " -- bump CT_DIAG_VERSION and the field's :count together"); ok = false; }
    if ($.CT_DIAG_VERSION != 1)     { logger.error("CT_DIAG_VERSION changed to " + $.CT_DIAG_VERSION); ok = false; }
    if ($.CT_DIAG_MAX != 65535)     { logger.error("CT_DIAG_MAX must be the UINT16 ceiling, got " + $.CT_DIAG_MAX); ok = false; }
    if ($.CT_DIAG_NONE != 0xFFFF)   { logger.error("CT_DIAG_NONE changed to " + $.CT_DIAG_NONE); ok = false; }
    return ok;
}

// Every slot index must be distinct and inside the array. A duplicated index is
// the failure this guards: two counters would write the same slot, one would be
// invisible and the other wrong, and every other test here would still pass
// because each one reads the slot it just wrote.
(:test) function test_ct_diagSlotIndicesDistinct(logger) {
    var idx = [$.CT_DIAG_I_VERSION, $.CT_DIAG_I_OPEN_ATTEMPTS, $.CT_DIAG_I_OPEN_OK,
               $.CT_DIAG_I_OPEN_THROW, $.CT_DIAG_I_MSG_TOTAL, $.CT_DIAG_I_BCAST,
               $.CT_DIAG_I_SHORT_PAY, $.CT_DIAG_I_PAGE1, $.CT_DIAG_I_PAGE_OTHER,
               $.CT_DIAG_I_CORE_OK, $.CT_DIAG_I_CORE_SENTINEL, $.CT_DIAG_I_CORE_CLAMP,
               $.CT_DIAG_I_SKIN_OK, $.CT_DIAG_I_SKIN_SENTINEL, $.CT_DIAG_I_SKIN_CLAMP,
               $.CT_DIAG_I_CHAN_CLOSED, $.CT_DIAG_I_MAX_FAILS, $.CT_DIAG_I_FLAGS,
               $.CT_DIAG_I_PAGE_FIRST, $.CT_DIAG_I_PAGE_OTHER_LAST,
               $.CT_DIAG_I_ACQ_PERIOD];
    var ok = true;
    if (idx.size() != $.CT_DIAG_SLOTS) {
        logger.error("this test lists " + idx.size() + " indices but CT_DIAG_SLOTS is " +
                     $.CT_DIAG_SLOTS + " -- a slot was added without a pin");
        ok = false;
    }
    for (var i = 0; i < idx.size(); i++) {
        if (idx[i] < 0 || idx[i] >= $.CT_DIAG_SLOTS) {
            logger.error("index " + i + " = " + idx[i] + " is outside 0.." + ($.CT_DIAG_SLOTS - 1));
            ok = false;
        }
        for (var j = i + 1; j < idx.size(); j++) {
            if (idx[i] == idx[j]) {
                logger.error("slot index collision: entries " + i + " and " + j + " both = " + idx[i]);
                ok = false;
            }
        }
    }
    return ok;
}

// Shape of the readout, independent of what the counters happen to hold: the
// array is exactly CT_DIAG_SLOTS long, slot 0 carries the version, and no slot
// can leave the UINT16 range the field's base type admits.
(:test) function test_ct_diagSnapshotShape(logger) {
    var s = new CoreTempSensor();
    var a = s.diagSnapshot();
    var ok = true;
    if (a == null) {
        logger.error("diagSnapshot returned null");
        return false;
    }
    if (a.size() != $.CT_DIAG_SLOTS) {
        logger.error("diagSnapshot size " + a.size() + " != CT_DIAG_SLOTS " + $.CT_DIAG_SLOTS);
        ok = false;
    }
    if (a[$.CT_DIAG_I_VERSION] != $.CT_DIAG_VERSION) {
        logger.error("version slot = " + a[$.CT_DIAG_I_VERSION] + ", expected " + $.CT_DIAG_VERSION);
        ok = false;
    }
    for (var i = 0; i < a.size(); i++) {
        if (a[i] == null || a[i] < 0 || a[i] > $.CT_DIAG_MAX) {
            logger.error("slot " + i + " = " + a[i] + " is not a UINT16");
            ok = false;
        }
    }
    return ok;
}

// The readout clamp. Saturation is what keeps a long row honest: a counter past
// the UINT16 ceiling must read "at least CT_DIAG_MAX", never a wrapped number.
(:test) function test_ct_diagClampSaturates(logger) {
    var ok = true;
    if (CoreTempSensor.ctDiagClamp(0)      != 0)            { logger.error("clamp(0) = " + CoreTempSensor.ctDiagClamp(0)); ok = false; }
    if (CoreTempSensor.ctDiagClamp(123)    != 123)          { logger.error("clamp(123) = " + CoreTempSensor.ctDiagClamp(123)); ok = false; }
    if (CoreTempSensor.ctDiagClamp(65535)  != 65535)        { logger.error("clamp(65535) must pass through, got " + CoreTempSensor.ctDiagClamp(65535)); ok = false; }
    if (CoreTempSensor.ctDiagClamp(65536)  != $.CT_DIAG_MAX){ logger.error("clamp(65536) must saturate, got " + CoreTempSensor.ctDiagClamp(65536)); ok = false; }
    if (CoreTempSensor.ctDiagClamp(999999) != $.CT_DIAG_MAX){ logger.error("clamp(999999) must saturate, got " + CoreTempSensor.ctDiagClamp(999999)); ok = false; }
    if (CoreTempSensor.ctDiagClamp(-1)     != 0)            { logger.error("clamp(-1) must floor at 0, got " + CoreTempSensor.ctDiagClamp(-1)); ok = false; }
    if (CoreTempSensor.ctDiagClamp(null)   != 0)            { logger.error("clamp(null) must be 0, got " + CoreTempSensor.ctDiagClamp(null)); ok = false; }
    return ok;
}

// The extraction that keeps the diagnostic sentinel test and decodeCoreC
// reading the same bytes: bytes 6-7, little endian, byte 7 the high half.
(:test) function test_ct_coreRaw16Assembly(logger) {
    var ok = true;
    if (CoreTempSensor.coreRaw16(ctPayload(660, 0x0C8, 3742)) != 3742) {
        logger.error("coreRaw16 = " + CoreTempSensor.coreRaw16(ctPayload(660, 0x0C8, 3742)) + ", expected 3742");
        ok = false;
    }
    if (CoreTempSensor.coreRaw16(ctPayload(660, 0x0C8, 0xFFFF)) != 0xFFFF) {
        logger.error("coreRaw16 of the marker = " + CoreTempSensor.coreRaw16(ctPayload(660, 0x0C8, 0xFFFF)));
        ok = false;
    }
    if (CoreTempSensor.coreRaw16(ctPayload(660, 0x0C8, 0x0100)) != 256) {
        logger.error("byte 7 must be the HIGH half: got " + CoreTempSensor.coreRaw16(ctPayload(660, 0x0C8, 0x0100)));
        ok = false;
    }
    if (CoreTempSensor.coreRaw16(ctPayload(660, 0x0C8, 0)) != 0) {
        logger.error("coreRaw16 of 0 = " + CoreTempSensor.coreRaw16(ctPayload(660, 0x0C8, 0)));
        ok = false;
    }
    return ok;
}

// The two sentinel classifiers. They answer a question decodeCoreC/decodeSkinC
// structurally cannot -- both gates return null -- so they must agree with the
// decoders about WHICH pattern is the marker, and must not fire on a value the
// clamp rejected instead.
(:test) function test_ct_diagSentinelClassifiers(logger) {
    var ok = true;
    if (CoreTempSensor.ctCoreSentinel(ctPayload(660, 0x0C8, 0xFFFF)) != true) {
        logger.error("ctCoreSentinel must fire on raw 0xFFFF");
        ok = false;
    }
    // 100 -> 1.00 C: rejected by the clamp, NOT by the marker.
    if (CoreTempSensor.ctCoreSentinel(ctPayload(660, 0x0C8, 100)) != false) {
        logger.error("ctCoreSentinel must not fire on a clamp rejection (raw 100)");
        ok = false;
    }
    if (CoreTempSensor.ctSkinSentinel(ctPayload(0x800, 0x0C8, 3742)) != true) {
        logger.error("ctSkinSentinel must fire on raw12 0x800");
        ok = false;
    }
    // 0xFFF -> -1 -> -0.05 C: rejected by the clamp, NOT by the marker. This is
    // the case the pre-sign-extension test exists for.
    if (CoreTempSensor.ctSkinSentinel(ctPayload(0xFFF, 0x0C8, 3742)) != false) {
        logger.error("ctSkinSentinel must not fire on a clamp rejection (raw12 0xFFF)");
        ok = false;
    }
    if (CoreTempSensor.ctSkinSentinel(ctPayload(660, 0x0C8, 3742)) != false) {
        logger.error("ctSkinSentinel must not fire on a valid reading");
        ok = false;
    }
    return ok;
}
