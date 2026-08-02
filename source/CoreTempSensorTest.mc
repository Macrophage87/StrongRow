using Toybox.Test;
using Toybox.System;
using Toybox.Lang;
using Toybox.Ant;

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

    // #102 seams. deliver() enters at onMessage rather than onBroadcast, which
    // is the only way to reach the msgTotal counter and the channel-response
    // branch; feed() above still enters one level down, so a test that uses it
    // exercises bcast but not msgTotal. diagReset() re-baselines the counters
    // without reconstructing the sensor -- initialize() opens a channel, so a
    // fresh probe never starts from zero.
    function deliver(m)  { onMessage(m); }
    function diagReset() { resetDiag(); }

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

// A channel whose open() FAILS QUIETLY: it returns false, as
// Ant.GenericChannel.open() is documented to do ("Returns Boolean true on
// success, otherwise false" -- SDK 9.2.0 api.debug.xml), and throws nothing.
//
// FakeChannel above cannot express this: its open() either returns true or
// throws, so the whole "did not throw but did not open" region was unreachable
// from any test. That is exactly the region where openChannel's diagnostics
// were wrong.
//
// NOT MEASURED, and not claimable: whether open() ever actually returns false
// on this code path. There is no ANT radio here and none of this repository's
// simulator runs can produce one. What is measurable, and is what the test
// below asserts, is that the counters must not mislabel the case if it occurs.
class QuietFailChannel {
    var opened;
    function initialize() { opened = false; }
    function setDeviceConfig(cfg) { }
    function open() { opened = true; return false; }
    function release() { return true; }
}

// A probe wired to a quietly-failing channel, counters re-baselined -- the
// ctFreshProbe analogue for the false-return case.
function ctQuietFailProbe() {
    var p = new CoreProbe();
    p.useFakeChannel(new QuietFailChannel());
    p.resetRecorders();
    p.diagReset();
    return p;
}

// A duck-typed stand-in for Ant.Message (#102). onMessage is annotated
// `msg as Ant.Message`, but this codebase is compiled untyped (CI passes no
// -l typecheck level -- see docs/CI.md), so runtime duck typing applies and an
// object exposing just messageId and getPayload() is accepted. MEASURED in the
// simulator on fr965 / SDK 9.2.0 before this was relied on; without it the
// msgTotal counter and the channel-response branch would be review-only.
//
// Ant.Message itself cannot be constructed here: it carries native state and
// arrives from the radio, which is the whole reason a stand-in is needed.
class FakeAntMsg {
    var messageId;
    hidden var mPayload;
    function initialize(id, payload) {
        messageId = id;
        mPayload  = payload;
    }
    function getPayload() { return mPayload; }
}

// The two message shapes the sensor reacts to, as helpers so each test says
// what it is delivering rather than assembling constants inline.
function ctBroadcastMsg(payload) {
    return new FakeAntMsg(Ant.MSG_ID_BROADCAST_DATA, payload);
}

// A search timeout / dropout, which is what a row with no pod in range
// actually produces: the radio reports the channel closed, onChannelClosed
// re-arms the search, and no broadcast is ever delivered.
function ctChannelClosedMsg() {
    return new FakeAntMsg(Ant.MSG_ID_CHANNEL_RESPONSE_EVENT,
                          [Ant.MSG_ID_RF_EVENT, Ant.MSG_CODE_EVENT_CHANNEL_CLOSED]);
}

// A probe with a channel whose open() succeeds, counters re-baselined. Every
// #102 differential starts here: a bare `new CoreProbe()` has already run
// initialize() -> openChannel(), which throws under the headless simulator, so
// nothing starts from zero and the real allocation's retries would otherwise
// be mixed into every count.
function ctFreshProbe(openThrows) {
    var p = new CoreProbe();
    p.useFakeChannel(new FakeChannel(openThrows));
    p.resetRecorders();
    p.diagReset();
    return p;
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

// -- #102 c2 red differentials ------------------------------------------------
// Every test below FAILS on the code as of the previous commit -- the counters
// exist but nothing increments them, so each reads 0 -- and passes once the
// instrumentation is wired up. Assertions are written null-safely so a wrong
// result reports as FAIL rather than ERROR.

// Slot reader, so a failure message names the slot rather than an index.
function ctSlot(p, i) {
    var a = p.diagSnapshot();
    if (a == null || i < 0 || i >= a.size()) { return -1; }
    return a[i];
}

// A successful open must be counted, and counted as a SUCCESS. Three channel
// closes drive three re-opens through the retry ladder; none of them throws,
// so the throw counter must stay at zero -- that separation is the whole basis
// of the "channel never opened" verdict.
(:test) function test_ct_diagCountsOpenAttempts(logger) {
    var p = ctFreshProbe(false);
    for (var i = 0; i < 3; i++) { p.closeEvent(); }
    var ok = true;
    if (ctSlot(p, $.CT_DIAG_I_OPEN_ATTEMPTS) != 3) { logger.error("openAttempts = " + ctSlot(p, $.CT_DIAG_I_OPEN_ATTEMPTS) + ", expected 3"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_OPEN_OK)       != 3) { logger.error("openOk = " + ctSlot(p, $.CT_DIAG_I_OPEN_OK) + ", expected 3"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_OPEN_THROW)    != 0) { logger.error("openThrow = " + ctSlot(p, $.CT_DIAG_I_OPEN_THROW) + ", expected 0"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_CHAN_CLOSED)   != 3) { logger.error("chanClosed = " + ctSlot(p, $.CT_DIAG_I_CHAN_CLOSED) + ", expected 3"); ok = false; }
    return ok;
}

// The converse, and the reason #102 was filed against openChannel's catch at
// all: a channel that cannot be acquired must leave a record. openOk must stay
// zero, or "the channel never opened" is indistinguishable from "it opened and
// heard nothing".
(:test) function test_ct_diagCountsOpenThrows(logger) {
    var p = ctFreshProbe(true);
    p.closeEvent();
    var ok = true;
    if (ctSlot(p, $.CT_DIAG_I_OPEN_THROW) < 1) { logger.error("openThrow = " + ctSlot(p, $.CT_DIAG_I_OPEN_THROW) + ", a failed open must be recorded"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_OPEN_OK)   != 0) { logger.error("openOk = " + ctSlot(p, $.CT_DIAG_I_OPEN_OK) + ", a throwing open must not count as a success"); ok = false; }
    return ok;
}

// Messages, broadcasts and page numbers. The page byte is what settles "frames
// arrived but were discarded": today source/CoreTempSensor.mc drops a non-0x01
// page with a bare return and the byte is never examined, so a pod broadcasting
// only the ANT+ common pages looks exactly like no pod at all.
(:test) function test_ct_diagCountsBroadcastAndPages(logger) {
    var p = ctFreshProbe(false);
    p.deliver(ctBroadcastMsg(ctPayload(660, 0x0C8, 3742)));   // page 0x01
    var other = ctPayload(660, 0x0C8, 3742);
    other[0] = 0x50;                                          // an ANT+ common page
    p.deliver(ctBroadcastMsg(other));
    p.deliver(ctBroadcastMsg([0x01, 0x02, 0x03, 0x04]));      // too short to decode
    var ok = true;
    if (ctSlot(p, $.CT_DIAG_I_MSG_TOTAL)  != 3)    { logger.error("msgTotal = " + ctSlot(p, $.CT_DIAG_I_MSG_TOTAL) + ", expected 3"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_BCAST)      != 3)    { logger.error("bcast = " + ctSlot(p, $.CT_DIAG_I_BCAST) + ", expected 3"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_PAGE1)      != 1)    { logger.error("page1 = " + ctSlot(p, $.CT_DIAG_I_PAGE1) + ", expected 1"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_PAGE_OTHER) != 1)    { logger.error("pageOther = " + ctSlot(p, $.CT_DIAG_I_PAGE_OTHER) + ", expected 1"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_SHORT_PAY)  != 1)    { logger.error("shortPay = " + ctSlot(p, $.CT_DIAG_I_SHORT_PAY) + ", expected 1"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_PAGE_FIRST) != 0x01) { logger.error("pageFirst = " + ctSlot(p, $.CT_DIAG_I_PAGE_FIRST) + ", expected 0x01"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_PAGE_OTHER_LAST) != 0x50) { logger.error("pageOtherLast = " + ctSlot(p, $.CT_DIAG_I_PAGE_OTHER_LAST) + ", expected 0x50"); ok = false; }
    return ok;
}

// A short payload must be counted as short and NOT as a page rejection: they
// point at different defects (a truncated frame versus a wrong page
// assumption), and source/CoreTempSensor.mc's two guards are adjacent bare
// returns today.
(:test) function test_ct_diagShortPayloadNotAPageReject(logger) {
    var p = ctFreshProbe(false);
    p.deliver(ctBroadcastMsg([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]));  // 7 bytes
    p.deliver(ctBroadcastMsg(null));
    var ok = true;
    if (ctSlot(p, $.CT_DIAG_I_SHORT_PAY)  != 2) { logger.error("shortPay = " + ctSlot(p, $.CT_DIAG_I_SHORT_PAY) + ", expected 2"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_PAGE1)      != 0) { logger.error("a short payload must not count as page 1"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_PAGE_OTHER) != 0) { logger.error("a short payload must not count as a page rejection"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_PAGE_FIRST) != $.CT_DIAG_NONE) { logger.error("pageFirst = " + ctSlot(p, $.CT_DIAG_I_PAGE_FIRST) + "; an unreadable frame has no page byte"); ok = false; }
    return ok;
}

// Core rejections, split by cause. decodeCoreC returns null for both, so
// without this split "the pod sent an invalid marker" and "the decode produced
// an implausible temperature" -- a documented-behaviour case and a possible
// layout defect -- are the same observation.
(:test) function test_ct_diagClassifiesCoreRejection(logger) {
    var p = ctFreshProbe(false);
    p.feed(ctPayload(660, 0x0C8, 0xFFFF));   // the invalid marker
    p.feed(ctPayload(660, 0x0C8, 100));      // 1.00 C -- below the clamp
    p.feed(ctPayload(660, 0x0C8, 3742));     // 37.42 C -- accepted
    var ok = true;
    if (ctSlot(p, $.CT_DIAG_I_CORE_SENTINEL) != 1) { logger.error("coreSentinel = " + ctSlot(p, $.CT_DIAG_I_CORE_SENTINEL) + ", expected 1"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_CORE_CLAMP)    != 1) { logger.error("coreClamp = " + ctSlot(p, $.CT_DIAG_I_CORE_CLAMP) + ", expected 1"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_CORE_OK)       != 1) { logger.error("coreOk = " + ctSlot(p, $.CT_DIAG_I_CORE_OK) + ", expected 1"); ok = false; }
    return ok;
}

// The skin analogue. 0xFFF is -0.05 C: a CLAMP rejection, not the marker --
// the case that exists because the marker is tested before sign extension.
(:test) function test_ct_diagClassifiesSkinRejection(logger) {
    var p = ctFreshProbe(false);
    p.feed(ctPayload(0x800, 0x0C8, 3742));   // the invalid marker
    p.feed(ctPayload(0xFFF, 0x0C8, 3742));   // -0.05 C -- below the clamp
    p.feed(ctPayload(660,   0x0C8, 3742));   // 33.00 C -- accepted
    var ok = true;
    if (ctSlot(p, $.CT_DIAG_I_SKIN_SENTINEL) != 1) { logger.error("skinSentinel = " + ctSlot(p, $.CT_DIAG_I_SKIN_SENTINEL) + ", expected 1"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_SKIN_CLAMP)    != 1) { logger.error("skinClamp = " + ctSlot(p, $.CT_DIAG_I_SKIN_CLAMP) + ", expected 1"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_SKIN_OK)       != 1) { logger.error("skinOk = " + ctSlot(p, $.CT_DIAG_I_SKIN_OK) + ", expected 1"); ok = false; }
    return ok;
}

// maxFails must survive the reset mFails does not. Any tracked page-1 frame
// zeroes mFails (that is deliberate -- the counter means what its name says),
// so at save time mFails carries the CURRENT ladder depth and says nothing
// about the depth reached. This is the one counter that is not a tally.
(:test) function test_ct_diagRecordsMaxFails(logger) {
    var p = ctFreshProbe(false);
    for (var i = 0; i < 5; i++) { p.closeEvent(); }
    var ok = true;
    if (ctSlot(p, $.CT_DIAG_I_MAX_FAILS) != 5) {
        logger.error("maxFails = " + ctSlot(p, $.CT_DIAG_I_MAX_FAILS) + " after 5 closes, expected 5");
        ok = false;
    }
    p.feed(ctPayload(660, 0x0C8, 3742));   // a tracked frame resets mFails to 0
    if (ctSlot(p, $.CT_DIAG_I_MAX_FAILS) != 5) {
        logger.error("maxFails fell to " + ctSlot(p, $.CT_DIAG_I_MAX_FAILS) + " when mFails reset; it must record the HIGH-WATER mark");
        ok = false;
    }
    return ok;
}

// The terminal channel state must be the state the SESSION ended in, not the
// state after teardown. StrongRowView.shutdown calls mCoreSensor.close()
// BEFORE stopAndSave, so reading the live channel at readout would report
// "released, closed" on every row ever recorded and carry no information.
(:test) function test_ct_diagFlagsLatchedAtClose(logger) {
    var p = ctFreshProbe(false);
    p.closeEvent();                          // re-opens, so a channel is held
    p.feed(ctPayload(660, 0x0C8, 3742));     // everSeen latches
    p.close();
    var f = ctSlot(p, $.CT_DIAG_I_FLAGS);
    var ok = true;
    if (f < 0) { logger.error("flags slot unreadable"); return false; }
    if ((f & $.CT_DIAG_F_CHANNEL_HELD) == 0) {
        logger.error("flags = " + f + "; a channel WAS held when close() ran, so the latch must record it -- reading live state after teardown always says otherwise");
        ok = false;
    }
    if ((f & $.CT_DIAG_F_CLOSED) == 0)    { logger.error("flags = " + f + "; the closed bit must be set after close()"); ok = false; }
    if ((f & $.CT_DIAG_F_EVER_SEEN) == 0) { logger.error("flags = " + f + "; the everSeen bit must be set after an accepted reading"); ok = false; }
    return ok;
}

// #84: does the 4 Hz PERIOD_B fallback ever acquire? Answerable only if the
// period is recorded at the FIRST broadcast -- mPeriod keeps alternating while
// nothing has been seen, so its value at save time is the last one TRIED, not
// the one that worked.
(:test) function test_ct_diagAcqPeriodIsTheFirstOne(logger) {
    var p = ctFreshProbe(false);
    var other = ctPayload(660, 0x0C8, 3742);
    other[0] = 0x50;                     // tracked but not accepted: mEverSeen stays false
    p.deliver(ctBroadcastMsg(other));
    var first = ctSlot(p, $.CT_DIAG_I_ACQ_PERIOD);
    var ok = true;
    if (first != 16384) {
        logger.error("acqPeriod = " + first + " at the first broadcast, expected PERIOD_A 16384");
        ok = false;
    }
    p.closeEvent();                      // mEverSeen false, so the period alternates
    p.deliver(ctBroadcastMsg(other));
    if (ctSlot(p, $.CT_DIAG_I_ACQ_PERIOD) != first) {
        logger.error("acqPeriod moved to " + ctSlot(p, $.CT_DIAG_I_ACQ_PERIOD) + "; it must record the FIRST period a frame arrived on, not the last tried");
        ok = false;
    }
    return ok;
}

// The labelled negative control. A row with a pod that never broadcasts -- the
// 2026-08-02 row, root-caused as a pod that was never woken -- delivers channel
// closes and nothing else. Its signature must be positively identifiable, not
// merely "everything is zero": the channel DID open and ANT WAS live.
(:test) function test_ct_diagNoPodRowProfile(logger) {
    var p = ctFreshProbe(false);
    for (var i = 0; i < 4; i++) { p.deliver(ctChannelClosedMsg()); }
    var ok = true;
    if (ctSlot(p, $.CT_DIAG_I_OPEN_OK)     < 1) { logger.error("openOk = " + ctSlot(p, $.CT_DIAG_I_OPEN_OK) + "; a podless row still opens the channel"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_OPEN_THROW) != 0) { logger.error("openThrow = " + ctSlot(p, $.CT_DIAG_I_OPEN_THROW) + ", expected 0"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_MSG_TOTAL)  != 4) { logger.error("msgTotal = " + ctSlot(p, $.CT_DIAG_I_MSG_TOTAL) + "; ANT was live, so this must be non-zero and is what separates a podless row from a dead channel"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_CHAN_CLOSED)!= 4) { logger.error("chanClosed = " + ctSlot(p, $.CT_DIAG_I_CHAN_CLOSED) + ", expected 4"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_BCAST)      != 0) { logger.error("bcast = " + ctSlot(p, $.CT_DIAG_I_BCAST) + "; nothing broadcast"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_PAGE1)      != 0) { logger.error("page1 = " + ctSlot(p, $.CT_DIAG_I_PAGE1) + ", expected 0"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_CORE_OK)    != 0) { logger.error("coreOk = " + ctSlot(p, $.CT_DIAG_I_CORE_OK) + ", expected 0"); ok = false; }
    if (ctSlot(p, $.CT_DIAG_I_PAGE_FIRST) != $.CT_DIAG_NONE) { logger.error("pageFirst = " + ctSlot(p, $.CT_DIAG_I_PAGE_FIRST) + "; no page byte was ever observed"); ok = false; }
    return ok;
}

// openOk must mean "the channel opened", not "openChannel() did not throw".
//
// Ant.GenericChannel.open() reports failure by RETURN VALUE as well as by
// throwing, and openChannel discarded the return. A channel that failed
// quietly therefore counted as a success, and -- measured on the pre-fix code
// -- produced a snapshot identical in ALL 21 SLOTS to the no-pod profile. A
// reader applying the slot key would have diagnosed "no pod" and gone to
// re-shake a working sensor: the exact failure #102 exists to eliminate,
// occurring inside the discriminator meant to eliminate it.
//
// Asserted two ways, because either alone is too weak. The counter identity
// (openOk == 0) can be satisfied by a mistake that breaks the other profiles
// too; the non-collision against a live H1 profile is the property that
// actually matters and cannot be satisfied by accident.
//
// This does NOT bear on ANT channel exhaustion, #102's named suspect: that
// raises Ant.UnableToAcquireChannelException from the GenericChannel
// constructor, which sits inside openChannel's try and is already counted as
// openThrow. The quiet-false path is a different, and unmeasured, mode.
(:test) function test_ct_diagOpenOkRequiresOpenToReturnTrue(logger) {
    var f = ctQuietFailProbe();
    for (var i = 0; i < 4; i++) { f.deliver(ctChannelClosedMsg()); }

    // The same stimulus against a channel that really opens: the no-pod row.
    var h1 = ctFreshProbe(false);
    for (var i = 0; i < 4; i++) { h1.deliver(ctChannelClosedMsg()); }

    var ok = true;

    if (ctSlot(f, $.CT_DIAG_I_OPEN_ATTEMPTS) != 4) {
        logger.error("openAttempts = " + ctSlot(f, $.CT_DIAG_I_OPEN_ATTEMPTS) + ", expected 4; the attempts happened either way");
        ok = false;
    }
    if (ctSlot(f, $.CT_DIAG_I_OPEN_OK) != 0) {
        logger.error("openOk = " + ctSlot(f, $.CT_DIAG_I_OPEN_OK) +
                     "; open() returned false every time, so nothing opened -- openOk must count successes, not non-throws");
        ok = false;
    }
    if (ctSlot(f, $.CT_DIAG_I_OPEN_THROW) != 0) {
        logger.error("openThrow = " + ctSlot(f, $.CT_DIAG_I_OPEN_THROW) + "; a quiet false is not a throw");
        ok = false;
    }
    // The residual is the false-return count, which is the arithmetic
    // openChannel's own comment reasons about and which was always 0 before.
    var residual = ctSlot(f, $.CT_DIAG_I_OPEN_ATTEMPTS) - ctSlot(f, $.CT_DIAG_I_OPEN_OK) -
                   ctSlot(f, $.CT_DIAG_I_OPEN_THROW);
    if (residual != 4) {
        logger.error("attempts - openOk - openThrow = " + residual + ", expected 4 quiet failures");
        ok = false;
    }

    // The property that actually matters: this must not read as a no-pod row.
    if (ctSlot(h1, $.CT_DIAG_I_OPEN_OK) <= 0) {
        logger.error("the control profile did not open a channel; the comparison below would be vacuous");
        return false;
    }
    var a = f.diagSnapshot();
    var b = h1.diagSnapshot();
    var same = (a.size() == b.size());
    if (same) {
        for (var i = 0; i < a.size(); i++) {
            if (a[i] != b[i]) { same = false; }
        }
    }
    if (same) {
        logger.error("a channel that failed to open is byte-identical to the no-pod profile in all " +
                     a.size() + " slots; the key would name the wrong hypothesis");
        ok = false;
    }
    return ok;
}

// THE acceptance test for #102: the three hypotheses must be separable from ONE
// row's counters. The discriminating triple is (openOk, msgTotal, bcast):
//
//   opened, radio live, nothing broadcast   -> (>0, >0,  0)
//   nothing opened, nothing arrived         -> ( 0,  0,  0)
//   opened and frames arrived               -> (>0, >0, >0)
//
// The left column deliberately describes what the COUNTERS observed, not what
// was wrong with the equipment. "(>0, >0, 0)" means the channel opened and the
// radio was live and nothing broadcast on it; "no pod in range" is the
// inference a reader draws from that, and it is only as good as the
// alternatives having been excluded. The labels used to state the inference,
// which is how a false-returning open() came to be filed under "no pod".
//
// openOk is the load-bearing leg. It alone separates the first two rows, so
// the separation does NOT depend on the unmeasured premise that a real podless
// row generates channel-response events -- if it generates none, the first row
// reads (>0, 0, 0) and is still distinct from (0, 0, 0). msgTotal corroborates.
//
// Asserted as pairwise distinctness AND against the documented signature, so
// neither a collapsed encoding nor a re-labelled one can pass.
(:test) function test_ct_diagThreeHypothesesDistinct(logger) {
    // H1 -- no pod in range.
    var h1 = ctFreshProbe(false);
    for (var i = 0; i < 4; i++) { h1.deliver(ctChannelClosedMsg()); }

    // H2 -- the channel never opened.
    var h2 = ctFreshProbe(true);
    for (var i = 0; i < 4; i++) { h2.closeEvent(); }

    // H3 -- frames arrived and were discarded by the page filter.
    //
    // The closeEvent() is load-bearing, not incidental: ctFreshProbe zeroes the
    // counters AFTER the constructor's own open, so without an open inside the
    // counted window this profile would read openOk == 0 -- which is H2's
    // signature, not H3's. It also models the real sequence, where the first
    // search times out and the second finds the pod before any frame arrives.
    // Frames cannot reach a channel that was never opened, so a profile that
    // claimed otherwise would be asserting something unreachable.
    var h3 = ctFreshProbe(false);
    h3.closeEvent();
    var other = ctPayload(660, 0x0C8, 3742);
    other[0] = 0x50;
    for (var i = 0; i < 4; i++) { h3.deliver(ctBroadcastMsg(other)); }

    var ok = true;

    if (!(ctSlot(h1, $.CT_DIAG_I_OPEN_OK) > 0 && ctSlot(h1, $.CT_DIAG_I_MSG_TOTAL) > 0 && ctSlot(h1, $.CT_DIAG_I_BCAST) == 0)) {
        logger.error("no-pod triple (openOk, msgTotal, bcast) = (" + ctSlot(h1, $.CT_DIAG_I_OPEN_OK) + ", " +
                     ctSlot(h1, $.CT_DIAG_I_MSG_TOTAL) + ", " + ctSlot(h1, $.CT_DIAG_I_BCAST) + "), expected (>0, >0, 0)");
        ok = false;
    }
    if (!(ctSlot(h2, $.CT_DIAG_I_OPEN_OK) == 0 && ctSlot(h2, $.CT_DIAG_I_MSG_TOTAL) == 0 && ctSlot(h2, $.CT_DIAG_I_BCAST) == 0)) {
        logger.error("dead-channel triple = (" + ctSlot(h2, $.CT_DIAG_I_OPEN_OK) + ", " +
                     ctSlot(h2, $.CT_DIAG_I_MSG_TOTAL) + ", " + ctSlot(h2, $.CT_DIAG_I_BCAST) + "), expected (0, 0, 0)");
        ok = false;
    }
    if (!(ctSlot(h3, $.CT_DIAG_I_OPEN_OK) > 0 && ctSlot(h3, $.CT_DIAG_I_MSG_TOTAL) > 0 &&
          ctSlot(h3, $.CT_DIAG_I_BCAST) > 0)) {
        logger.error("frames-discarded triple = (" + ctSlot(h3, $.CT_DIAG_I_OPEN_OK) + ", " +
                     ctSlot(h3, $.CT_DIAG_I_MSG_TOTAL) + ", " + ctSlot(h3, $.CT_DIAG_I_BCAST) + "), expected (>0, >0, >0)");
        ok = false;
    }
    // ...and H2 must be distinguishable by its OWN positive evidence, not only
    // by absence: every attempt threw.
    if (ctSlot(h2, $.CT_DIAG_I_OPEN_THROW) < 1) {
        logger.error("a dead channel must record openThrow > 0, got " + ctSlot(h2, $.CT_DIAG_I_OPEN_THROW));
        ok = false;
    }
    // ...and H3 must name WHICH gate discarded the frames.
    if (ctSlot(h3, $.CT_DIAG_I_PAGE_OTHER) != 4 || ctSlot(h3, $.CT_DIAG_I_PAGE1) != 0 ||
        ctSlot(h3, $.CT_DIAG_I_PAGE_OTHER_LAST) != 0x50) {
        logger.error("frames-discarded must name the page filter: pageOther = " + ctSlot(h3, $.CT_DIAG_I_PAGE_OTHER) +
                     ", page1 = " + ctSlot(h3, $.CT_DIAG_I_PAGE1) +
                     ", pageOtherLast = " + ctSlot(h3, $.CT_DIAG_I_PAGE_OTHER_LAST));
        ok = false;
    }
    return ok;
}
