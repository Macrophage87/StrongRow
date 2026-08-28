using Toybox.Test;

// ---------------------------------------------------------------------------
// Epic #59 -- R-R / HRV correctness. Sub-issues #37, #38, #39, #40, #46, #68,
// plus the receive-path diagnostic rr_diag.
//
// EVERYTHING IN THIS FILE LIVES IN `module RrHrv`, and that is a hard
// constraint rather than a taste. The fenix6 family caps module `globals` at
// 253 members; a file-scope (:test), helper function or test class costs one
// member each, a `module { }` block costs ONE between all of them. The
// simulator prints these cases as `RrHrv.test_rr_...`, which is the name
// scripts/list_tests.py emits and the name scripts/expected_tests.txt must
// therefore carry. See the ceiling note at the top of scripts/list_tests.py.
//
// Measured by bisection on this branch, with monkeyc --unit-test for fenix6,
// by adding N file-scope (:test) stubs to a throwaway file until the build
// reds. Measured at the TIP OF THIS BRANCH, with the whole of epic #59
// applied -- so this line is the branch's figure at every commit of it,
// not a per-commit one:
//
//     CEILING hrv-correctness fenix6: 249 used of 253, 4 free -- the 5th file-scope (:test) added reds
//
// BEFORE this change, on the same tree, the bisection read 247 used / 6 free
// (N=6 BUILD SUCCESSFUL, N=7 "Found 254 members in module 'globals'"). So the
// whole of epic #59 costs TWO members: the RR_FRESH_MS split is +3 constants
// and -1, and `module RrDiag` and `module RrHrv` are one each -- three module
// blocks of the same name still cost one between them, which is why this file
// re-opens `module RrHrv` rather than nesting everything in one brace.
//
// The 247 figure is also one member tighter than the `v08-display-fixes`
// anchor recorded in docs/agents/FACTS.md, which was taken at 211f106: that
// note is STALE rather than wrong, and the tree has gained a member since.
// scripts/check_ceiling_notes.py enumerates every anchor and cannot tell you
// which is newest, so re-bisect rather than reading either.
//
// WHY THESE SEVEN LANDED TOGETHER. They modify the same ~40 lines -- handleRr's
// diff-accumulation loop, the onTick freshness gate, and the constants they
// share -- and they share a root cause: handleRr conflated "did a batch
// arrive?", "was a beat accepted?" and "is this beat adjacent to the last
// one?" across overlapping state with one five-second constant serving a UI
// indicator, an rMSSD accumulator and a FIT record field. Landed separately
// they would have meant six rebases through one function.
//
// THE COMMIT PARTITION, which is how the red evidence exists at all:
//   c0  characterization pins on shipped symbols -- green in EVERY epoch of
//       this change. They pin the premises the design rests on, so a later
//       edit that made a premise false reds here rather than passing silently.
//   c1  the behaviour-preserving refactor, the new symbols, and green pins on
//       them.
//   c2  RED differentials only. Every case in the c2 section below was shown
//       failing, by name, in a CI run on this branch before the fix landed.
//   c3  the fix. No test file, no pin, no script.
//
// WHAT NO CASE IN THIS FILE CAN SHOW, stated so nobody reads more into a green
// run. Nothing here touches a FIT file. These cases pin what the code CALLS --
// which arrays reach setData and which do not -- and say NOTHING about what a
// decoder or Garmin Connect SEES for any of them. In particular: that an
// explicit per-record setData([0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF]) on a UINT16
// :count => 4 field lands as those bytes, and that a decoder reads them as
// absent, is UNMEASURED -- #48 proved the FLOAT scalar case at record scope,
// not the UINT16 array case. The [Local] issue filed with this change owns it.
// No (:test) can obtain a Session either, so createField is unreachable from
// here and nothing below proves rr_diag is accepted, saved or decodable.
//
// THE CLOCK IS INJECTED, ALWAYS. System.getTimer() counts from device start, so
// a case synthesising a timestamp from it passes on a desktop simulator that
// has been open for hours and REDS on CI's, which is seconds old -- reliably,
// not flakily. Every case drives handleRrAt(nowMs, ivals) with literal
// milliseconds and overrides nowMs() in the probe. That seam exists for this
// reason and for no other.
// ---------------------------------------------------------------------------
module RrHrv {

// Element-wise array compare. Not (:test)-annotated, and inside the module, so
// it costs no globals member and drops out of the shipping build.
function arrEq(got, exp, logger, what) {
    if (got == null) { logger.error(what + ": got null"); return false; }
    if (got.size() != exp.size()) {
        logger.error(what + ": size " + got.size() + " != " + exp.size());
        return false;
    }
    for (var i = 0; i < exp.size(); i++) {
        if (got[i] != exp[i]) {
            logger.error(what + ": idx " + i + " got " + got[i] + " exp " + exp[i]);
            return false;
        }
    }
    return true;
}

// ===========================================================================
// c0 -- characterization pins on the SHIPPED helpers.
// ===========================================================================
// Green before this change and green after it. They exist because the whole
// #46 design rests on one premise -- RR_INVALID is out of band for a real
// reading -- and #158 established that such a premise must be pinned THROUGH
// THE REAL FILTER rather than by restating the constant that expresses it. A
// test that re-read RR_MIN_MS/RR_MAX_MS would agree with any future edit that
// widened them and silently turned the sentinel into data.

// No value filterRr ACCEPTS can be packed into a data slot equal to RR_INVALID.
//
// Swept one code point at a time over raw 0..3000 -- the accepted 250..2500
// band with ~250 ms of margin either side -- plus the sentinel itself, its
// neighbour, and the other candidate sentinel. Values far above 3000 are all
// far above the range bound and cannot be the ones that reach 0xFFFF; the
// sweep is bounded where the question is, and 65535 is tested explicitly.
//
// This is the OUT-OF-BAND CLAIM ITSELF. Raising RR_MAX_MS to 0xFFFF reds it.
(:test) function test_rr_c0_noFilterSurvivorIsTheSentinel(logger) {
    var ok = true;
    var accepted = 0;
    for (var raw = 0; raw <= 3000; raw++) {
        var f = StrongRowView.filterRr([raw]);
        if (f.size() == 0) { continue; }
        accepted++;
        var rec = StrongRowView.packRr(f);
        if (rec[0] == $.RR_INVALID) {
            logger.error("filterRr accepted raw " + raw + " and packRr put " +
                         "RR_INVALID in a DATA slot -- the sentinel can no " +
                         "longer be told from a reading");
            ok = false;
        }
    }
    // The sentinel's own neighbourhood, ABOVE the swept band, checked through
    // the same two functions. Without these three the sweep could not see the
    // one edit that matters most here -- widening RR_MAX_MS to the sentinel --
    // because the widened band would still contain no value equal to 0xFFFF
    // below 3000. Measured: raising RR_MAX_MS to 65535 reds this case.
    var high = [65534, $.RR_INVALID, 70000];
    for (var k = 0; k < high.size(); k++) {
        var fh = StrongRowView.filterRr([high[k]]);
        if (fh.size() == 0) { continue; }
        accepted++;
        var rh = StrongRowView.packRr(fh);
        if (rh[0] == $.RR_INVALID) {
            logger.error("filterRr accepted " + high[k] + " and packRr put " +
                         "RR_INVALID in a DATA slot -- the sentinel is in band");
            ok = false;
        }
    }
    // Fail closed: a filter that rejected everything would satisfy the loops
    // vacuously, and the sweep's whole job is to say what the accepted set is.
    if (accepted == 0) {
        logger.error("filterRr accepted no code point in 0..3000 -- the sweep " +
                     "proved nothing about the accepted set");
        ok = false;
    }
    return ok;
}

// The two sentinel candidates are BOTH rejected by the shipping filter, so
// neither can arrive as data. 0xFFFF is the one #46 writes; 0 is the
// alternative, and this case is what makes "0 would also have been out of
// band" a measurement rather than an assertion in the argument beside the
// write site.
(:test) function test_rr_c0_theSentinelIsRejectedByTheFilter(logger) {
    var ok = true;
    if (StrongRowView.filterRr([$.RR_INVALID]).size() != 0) {
        logger.error("filterRr ACCEPTED 0xFFFF; the rr_interval sentinel is " +
                     "in band and #46's whole encoding collapses");
        ok = false;
    }
    if (StrongRowView.filterRr([65534]).size() != 0) {
        logger.error("filterRr accepted 65534 -- the region around the " +
                     "sentinel is not out of band");
        ok = false;
    }
    if (StrongRowView.filterRr([0]).size() != 0) {
        logger.error("filterRr ACCEPTED 0; the rejected alternative sentinel " +
                     "would have been in band too");
        ok = false;
    }
    // and the band itself still admits an ordinary beat, so the three above
    // are not passing because everything is rejected.
    if (StrongRowView.filterRr([850]).size() != 1) {
        logger.error("filterRr rejected an ordinary 850 ms interval");
        ok = false;
    }
    return ok;
}

// filterRr converts with toNumber() BEFORE the range comparison, not after.
//
// All eleven pre-existing filterRr pins use integer literals only, so this
// ordering was invisible to the entire suite: moving the range check before the
// conversion would have left every one of them green. It matters because
// rrAccept now carries the same order for the adjacency path, and because
// heartBeatIntervals is not documented to deliver Numbers.
(:test) function test_rr_c0_filterConvertsBeforeRangeChecking(logger) {
    var ok = true;
    // 2500.7 is ABOVE RR_MAX_MS as a float and 2500 -- accepted -- after
    // truncation. Comparing first would reject it.
    if (!arrEq(StrongRowView.filterRr([2500.7]), [2500], logger, "2500.7")) { ok = false; }
    // 249.9 is BELOW RR_MIN_MS after truncation to 249, so it is rejected --
    // the mirror case, which fails if toNumber were dropped altogether.
    if (StrongRowView.filterRr([249.9]).size() != 0) {
        logger.error("filterRr accepted 249.9; it truncates to 249, below RR_MIN_MS");
        ok = false;
    }
    if (!arrEq(StrongRowView.filterRr([250.4]), [250], logger, "250.4")) { ok = false; }
    return ok;
}

}

module RrHrv {

// -- Stubs -------------------------------------------------------------------

// Stand-in for a FitContributor field handle. Records EVERY write in order,
// because the defects here are about which value a record ends up carrying and
// that is decided by the LAST write before the record commits -- a call count
// alone cannot see a good array being overwritten by a sentinel.
class RrField {
    var writes;     // every value handed to setData, in order
    function initialize() { writes = []; }
    function setData(v) { writes.add(v); }
    function count()   { return writes.size(); }
    function last()    { return (writes.size() == 0) ? null : writes[writes.size() - 1]; }
}

// -- Probe -------------------------------------------------------------------
// `hidden` in Monkey C is protected, so a subclass reads the R-R state and
// drives the shipping handleRrAt / onTick without adding an accessor to the
// shipping class -- the same seam DspProbe and LifeProbe use. Referenced only
// from (:test) functions, so it drops out of the release build.
//
// startSensor()/startGps() are neutralised, and ONLY those two: everything the
// cases drive below is the shipping code. A real sensor registration would
// install a 25 Hz listener for the rest of the run.
//
// nowMs() is overridable so onTick's three freshness gates are deterministic.
// mFitCore / mFitSkin / mFitHsi are left null on purpose: onTick dereferences
// mCoreSensor with NO null check inside those three branches, and mCoreSensor
// is null in a fresh probe.
class RrProbe extends StrongRowView {
    var clock;      // what nowMs() returns

    function initialize() {
        StrongRowView.initialize();
        clock = 0;
    }

    hidden function startSensor() { }
    hidden function startGps()    { }
    hidden function nowMs()       { return clock; }

    // Drive the SHIPPING receive path with an injected clock.
    function feed(t, ivals) { handleRrAt(t, ivals); }
    // Drive the shipping callback-facing wrapper, to pin that it delegates.
    function feedNow(ivals) { handleRr(ivals); }

    // Drive the SHIPPING onTick at time t. Ui.requestUpdate() is its last
    // statement, so every observable precedes it; the try/catch contains the
    // catchable failure modes of a headless update request.
    function tickAt(t) {
        clock = t;
        try { onTick(); } catch (e) { }
    }

    // Stand the FIT handles up without a Session. mSession stays null, so
    // stopAndSave's body is skipped entirely and nothing but its tail runs.
    function armRr()    { mFitRr = new RrField();    mStarted = true; mPaused = false; }
    function armRmssd() { mFitRmssd = new RrField(); mStarted = true; mPaused = false; }
    function setStopped() { mStarted = false; }
    function rrField()    { return mFitRr; }
    function rmssdField() { return mFitRmssd; }

    // Reads on the state model. Never written from a case except through the
    // shipping code above.
    function diffCount()  { return mDiffCount; }
    function diffIdx()    { return mDiffIdx; }
    function rrLast()     { return mRrLast; }
    function rmssd()      { return mRmssd; }
    function lastRrMs()   { return mLastRrMs; }
    function lastBeatMs() { return mLastBeatMs; }
    function lastDiffMs() { return mLastDiffMs; }
    function rmssdN()     { return mRmssdN; }
    function rmssdSum()   { return mRmssdSum; }
    function pendingRr()  { return mPendingRr; }
    function diag()       { return rrDiagSnapshot(); }
    function diagAt(i)    { return rrDiagSnapshot()[i]; }
    function endSession() { stopAndSave(); }
}


// ===========================================================================
// c1 -- green pins on the NEW symbols.
// ===========================================================================
// Green from the commit that introduces each symbol onward. They are the anchor
// for the c2 differentials: without them a "fix" that stopped writing anything
// at all, or that never advanced a counter, would satisfy every red case below
// while being strictly worse than the defect.

// handleRr delegates to handleRrAt and adds nothing. If it did anything of its
// own, every case in this file would be testing a different function from the
// one onSensorData calls.
(:test) function test_rr_c1_handleRrDelegatesToHandleRrAt(logger) {
    var ok = true;
    var a = new RrProbe();
    var b = new RrProbe();
    a.feed(1000, [800, 810, 800]);
    b.feedNow([800, 810, 800]);
    // The clock differs (b read the real timer), so compare everything the
    // clock does not decide.
    if (a.diffCount() != b.diffCount()) {
        logger.error("handleRr and handleRrAt disagree on the ring: " +
                     a.diffCount() + " vs " + b.diffCount());
        ok = false;
    }
    if (a.rrLast() != b.rrLast()) {
        logger.error("handleRr and handleRrAt disagree on mRrLast");
        ok = false;
    }
    if (a.diagAt($.RrDiag.I_BEAT_ACCEPT) != b.diagAt($.RrDiag.I_BEAT_ACCEPT)) {
        logger.error("handleRr and handleRrAt disagree on the accepted-beat count");
        ok = false;
    }
    // And handleRrAt really did use the injected clock rather than the timer.
    if (a.lastRrMs() != 1000) {
        logger.error("handleRrAt(1000, ...) stamped mLastRrMs " + a.lastRrMs() +
                     " -- the clock seam is not being used");
        ok = false;
    }
    return ok;
}

// rrAccept classifies the four cases, and the three reject classes are
// DISTINCT -- collapsing them would still break adjacency correctly but would
// make the rr_diag reject counters unable to say which failure mode a row had.
(:test) function test_rr_c1_rrAcceptClassifiesTheFourCases(logger) {
    var ok = true;
    if (StrongRowView.rrAccept(null) != $.RrDiag.A_NULL) { logger.error("null must be A_NULL"); ok = false; }
    if (StrongRowView.rrAccept(249)  != $.RrDiag.A_LOW)  { logger.error("249 must be A_LOW");  ok = false; }
    if (StrongRowView.rrAccept(250)  != $.RrDiag.A_OK)   { logger.error("250 must be A_OK (inclusive)"); ok = false; }
    if (StrongRowView.rrAccept(2500) != $.RrDiag.A_OK)   { logger.error("2500 must be A_OK (inclusive)"); ok = false; }
    if (StrongRowView.rrAccept(2501) != $.RrDiag.A_HIGH) { logger.error("2501 must be A_HIGH"); ok = false; }
    // Conversion before comparison, the same order filterRr pins in c0.
    if (StrongRowView.rrAccept(2500.7) != $.RrDiag.A_OK)  { logger.error("2500.7 truncates to 2500 and must be A_OK"); ok = false; }
    if (StrongRowView.rrAccept(249.9)  != $.RrDiag.A_LOW) { logger.error("249.9 truncates to 249 and must be A_LOW"); ok = false; }
    if ($.RrDiag.A_NULL == $.RrDiag.A_LOW || $.RrDiag.A_LOW == $.RrDiag.A_HIGH
            || $.RrDiag.A_NULL == $.RrDiag.A_HIGH || $.RrDiag.A_OK == $.RrDiag.A_LOW) {
        logger.error("the rrAccept codes are not distinct");
        ok = false;
    }
    return ok;
}

// ONE range gate. filterRr's survivor set and rrAccept's verdict agree on every
// code point in the swept band -- which is what stops the record path and the
// adjacency path from drifting the way they did before #37.
(:test) function test_rr_c1_filterRrAgreesWithRrAccept(logger) {
    var ok = true;
    for (var raw = 0; raw <= 3000; raw += 1) {
        var kept  = (StrongRowView.filterRr([raw]).size() == 1);
        var wants = (StrongRowView.rrAccept(raw) == $.RrDiag.A_OK);
        if (kept != wants) {
            logger.error("filterRr and rrAccept disagree at raw " + raw +
                         ": kept=" + kept + " rrAccept-ok=" + wants);
            ok = false;
            return ok;   // one report is enough; 3001 would flood the log
        }
    }
    if (StrongRowView.filterRr([null]).size() != 0
            || StrongRowView.rrAccept(null) == $.RrDiag.A_OK) {
        logger.error("filterRr and rrAccept disagree on null");
        ok = false;
    }
    return ok;
}

// The rr_diag snapshot has exactly SLOTS entries and carries the layout version
// in slot 0. THE LENGTH IS SAFETY-CRITICAL: the createField `:count` reads the
// same constant, and a setData array longer than :count is an uncatchable
// System Error at save time that takes the whole activity with it.
(:test) function test_rr_c1_diagSnapshotShape(logger) {
    var ok = true;
    var p = new RrProbe();
    var a = p.diag();
    if (a.size() != $.RrDiag.SLOTS) {
        logger.error("rrDiagSnapshot returned " + a.size() + " slots, not " +
                     $.RrDiag.SLOTS + " -- this is the array-too-long System Error");
        return false;
    }
    if (a[$.RrDiag.I_VERSION] != $.RrDiag.VERSION) {
        logger.error("slot 0 carries " + a[$.RrDiag.I_VERSION] + ", not the layout version");
        ok = false;
    }
    // A fresh view has seen nothing. Everything but the version is zero, which
    // is what makes "all zero" a readable answer on a real row.
    for (var i = 1; i < $.RrDiag.SLOTS; i++) {
        if (a[i] != 0) {
            logger.error("fresh view: slot " + i + " is " + a[i] + ", not 0");
            ok = false;
        }
    }
    return ok;
}

// EVERY slot index nailed to its literal number, 0 to 20 inclusive.
//
// This case is written the way it is because of what happened one file over:
// ct_diag's index pin asserted a PREFIX of its slots, so a permutation confined
// to the unpinned tail would have re-keyed three slots of every file already
// recorded with the whole suite green. Slot indices ARE the wire format. A
// distinctness check is not enough -- it is invariant under a wholesale
// renumbering, which is exactly the change that breaks a reader's key.
(:test) function test_rr_c1_diagSlotKeyIsZeroToTwenty(logger) {
    var ok = true;
    var exp = [
        $.RrDiag.I_VERSION,      $.RrDiag.I_SENSOR_CB,    $.RrDiag.I_HR_ABSENT,
        $.RrDiag.I_BATCH_NULL,   $.RrDiag.I_BATCH_EMPTY,  $.RrDiag.I_BATCH_OK,
        $.RrDiag.I_BEATS,        $.RrDiag.I_BEAT_ACCEPT,  $.RrDiag.I_REJ_NULL,
        $.RrDiag.I_REJ_LOW,      $.RrDiag.I_REJ_HIGH,     $.RrDiag.I_DIFF_ACCEPT,
        $.RrDiag.I_DIFF_REJ_ART, $.RrDiag.I_ADJ_GAP,      $.RrDiag.I_ADJ_INTRA,
        $.RrDiag.I_RING_CLEAR,   $.RrDiag.I_REC_STAGED,   $.RrDiag.I_REC_INVALID,
        $.RrDiag.I_MAXGAP_BATCH, $.RrDiag.I_MAXGAP_BEAT,  $.RrDiag.I_FLAGS
    ];
    if (exp.size() != $.RrDiag.SLOTS) {
        logger.error("this pin lists " + exp.size() + " indices but SLOTS is " +
                     $.RrDiag.SLOTS + " -- a slot was added without pinning it");
        return false;
    }
    for (var i = 0; i < exp.size(); i++) {
        if (exp[i] != i) {
            logger.error("slot key: position " + i + " holds index " + exp[i] +
                         " -- renumbering re-keys every file already recorded");
            ok = false;
        }
    }
    // The flag bits are powers of two and distinct, so ORing them is lossless.
    if ($.RrDiag.F_RR_REGISTERED != 1 || $.RrDiag.F_SENSOR_OK != 2) {
        logger.error("the rr_diag flag bits moved; every recorded file's flags slot is re-keyed");
        ok = false;
    }
    return ok;
}

// Counters SATURATE at readout rather than wrapping. A slot reading MAXV means
// "at least MAXV", never a small number that used to be large.
(:test) function test_rr_c1_diagCountersSaturate(logger) {
    var ok = true;
    if ($.RrDiag.clamp(70000) != $.RrDiag.MAXV) { logger.error("70000 must clamp to MAXV"); ok = false; }
    if ($.RrDiag.clamp($.RrDiag.MAXV) != $.RrDiag.MAXV) { logger.error("MAXV must survive"); ok = false; }
    if ($.RrDiag.clamp($.RrDiag.MAXV - 1) != $.RrDiag.MAXV - 1) { logger.error("MAXV-1 must survive"); ok = false; }
    if ($.RrDiag.clamp(0) != 0)     { logger.error("0 must survive"); ok = false; }
    if ($.RrDiag.clamp(-1) != 0)    { logger.error("a negative must floor at 0, never reach the field"); ok = false; }
    if ($.RrDiag.clamp(null) != 0)  { logger.error("null must floor at 0, never reach setData"); ok = false; }
    return ok;
}

// The receive path counts what it saw. Drives the SHIPPING handleRrAt and reads
// the SHIPPING snapshot -- no counter is computed in the test.
//
// One batch of six elements: two in range, one null, one below RR_MIN_MS, one
// above RR_MAX_MS, one in range. So BEATS = 6 and the four class counters
// partition it exactly, which is the consistency a reader can check on a file.
(:test) function test_rr_c1_theReceivePathCountsWhatItSaw(logger) {
    var ok = true;
    var p = new RrProbe();
    p.feed(1000, [850, null, 100, 9000, 860, 870]);
    if (p.diagAt($.RrDiag.I_BATCH_OK) != 1)    { logger.error("one non-empty batch"); ok = false; }
    if (p.diagAt($.RrDiag.I_BEATS) != 6)       { logger.error("six elements examined, got " + p.diagAt($.RrDiag.I_BEATS)); ok = false; }
    if (p.diagAt($.RrDiag.I_BEAT_ACCEPT) != 3) { logger.error("three accepted, got " + p.diagAt($.RrDiag.I_BEAT_ACCEPT)); ok = false; }
    if (p.diagAt($.RrDiag.I_REJ_NULL) != 1)    { logger.error("one null reject, got " + p.diagAt($.RrDiag.I_REJ_NULL)); ok = false; }
    if (p.diagAt($.RrDiag.I_REJ_LOW) != 1)     { logger.error("one low reject, got " + p.diagAt($.RrDiag.I_REJ_LOW)); ok = false; }
    if (p.diagAt($.RrDiag.I_REJ_HIGH) != 1)    { logger.error("one high reject, got " + p.diagAt($.RrDiag.I_REJ_HIGH)); ok = false; }
    var part = p.diagAt($.RrDiag.I_BEAT_ACCEPT) + p.diagAt($.RrDiag.I_REJ_NULL)
             + p.diagAt($.RrDiag.I_REJ_LOW) + p.diagAt($.RrDiag.I_REJ_HIGH);
    if (part != p.diagAt($.RrDiag.I_BEATS)) {
        logger.error("the four class counters do not partition BEATS: " + part +
                     " vs " + p.diagAt($.RrDiag.I_BEATS));
        ok = false;
    }
    // The two early returns are counted separately, because a null member and
    // a present-but-empty array are different platform behaviours.
    p.feed(2000, null);
    p.feed(3000, []);
    if (p.diagAt($.RrDiag.I_BATCH_NULL) != 1)  { logger.error("one null batch"); ok = false; }
    if (p.diagAt($.RrDiag.I_BATCH_EMPTY) != 1) { logger.error("one empty batch"); ok = false; }
    if (p.diagAt($.RrDiag.I_BATCH_OK) != 1)    { logger.error("a null/empty batch must not count as OK"); ok = false; }
    return ok;
}

// The two longest-gap slots are recorded in WHOLE SECONDS and are DIFFERENT
// measurements. Batches arriving that carry nothing usable is the profile the
// activity behind rr_diag showed, and it is the case where the two diverge.
(:test) function test_rr_c1_theTwoGapSlotsMeasureDifferentThings(logger) {
    var ok = true;
    var p = new RrProbe();
    // Batches every second; the first two carry beats, the middle four carry
    // only out-of-range values, then beats resume. Batch gaps are all 1 s;
    // the beat gap spans the whole unusable stretch.
    p.feed(1000, [850]);
    p.feed(2000, [850]);
    p.feed(3000, [9000]);
    p.feed(4000, [9000]);
    p.feed(5000, [9000]);
    p.feed(6000, [9000]);
    p.feed(7000, [850]);
    if (p.diagAt($.RrDiag.I_MAXGAP_BATCH) != 1) {
        logger.error("longest batch gap should be 1 s, got " + p.diagAt($.RrDiag.I_MAXGAP_BATCH));
        ok = false;
    }
    if (p.diagAt($.RrDiag.I_MAXGAP_BEAT) != 5) {
        logger.error("longest accepted-beat gap should be 5 s (2000 -> 7000), got " +
                     p.diagAt($.RrDiag.I_MAXGAP_BEAT));
        ok = false;
    }
    return ok;
}

// A good batch followed by an ALL-REJECTED one, inside the staleness window,
// still records the good batch. This is the trap the standalone "drop the
// record on an invalid batch" guard falls into: it would record absence for
// beats that were genuinely received.
//
// Green in every epoch -- before the change the all-rejected batch simply
// skipped its write and the field latched the good array; after it, onTick
// re-writes the still-fresh stage. The ASSERTION is the same either way, which
// is what makes it an anchor rather than a differential.
(:test) function test_rr_c1_anAllRejectedBatchDoesNotOverwriteAGoodOne(logger) {
    var p = new RrProbe();
    p.armRr();
    p.feed(1000, [850, 860]);
    p.feed(1500, [50, 50, 9000]);
    p.tickAt(1600);
    var f = p.rrField();
    if (f.count() < 1) {
        logger.error("nothing was ever written to rr_interval");
        return false;
    }
    return arrEq(f.last(), [850, 860, $.RR_INVALID, $.RR_INVALID], logger,
                 "the last rr_interval write after an all-rejected batch");
}

}

module RrHrv {

// ===========================================================================
// c2 -- the RED differentials. Each was shown failing by name before the fix.
// ===========================================================================

// #37. An intra-batch RANGE rejection breaks adjacency.
//
// [800, 200, 700] is a double detection -- the most common wrist-optical
// failure mode under rowing. filterRr drops the 200, and the survivors 800 and
// 700 are NOT successive intervals. RED before the fix: the loop diffed them,
// d = 100, and 100 <= 0.30 * 800 so the artifact gate PASSED it and a
// non-consecutive pair entered the ring, deflating rMSSD. The gate cannot catch
// this class -- it is precisely the plausible-looking pair that slips through.
(:test) function test_rr_c2_anIntraBatchRejectBreaksAdjacency(logger) {
    var ok = true;
    var p = new RrProbe();
    p.feed(1000, [800, 200, 700]);
    if (p.diffCount() != 0) {
        logger.error("a beat either side of an intra-batch reject was diffed as " +
                     "consecutive: ring holds " + p.diffCount() + " entries, expected 0");
        ok = false;
    }
    if (p.rrLast() != 700) {
        logger.error("the surviving beat after the reject must still SEED the " +
                     "reference, mRrLast=" + p.rrLast());
        ok = false;
    }
    if (p.diagAt($.RrDiag.I_ADJ_INTRA) != 1) {
        logger.error("the intra-batch break must be counted once, got " +
                     p.diagAt($.RrDiag.I_ADJ_INTRA));
        ok = false;
    }
    // and a clean batch still diffs, so the fix has not simply disabled the ring
    var q = new RrProbe();
    q.feed(1000, [800, 810, 800]);
    if (q.diffCount() != 2) {
        logger.error("a clean batch must still produce diffs, got " + q.diffCount());
        ok = false;
    }
    return ok;
}

// #39. An inter-batch gap CLEARS the ring.
//
// RED before the fix: the ring kept up to RR_NDIFF-1 pre-dropout differences,
// so the first post-resume record logged an rMSSD composed entirely of
// pre-dropout beats and accumulated it into avg_rmssd as though it were clean.
(:test) function test_rr_c2_aGapClearsTheRing(logger) {
    var ok = true;
    var p = new RrProbe();
    p.feed(1000, [800, 810, 800, 810, 800, 810, 800]);
    if (p.diffCount() != 6) {
        logger.error("setup failed: expected 6 diffs, got " + p.diffCount());
        return false;
    }
    // A batch more than RR_MAX_MS later: the gap reset fires.
    p.feed(9000, [800]);
    if (p.diffCount() != 0) {
        logger.error("the ring still holds " + p.diffCount() + " pre-dropout " +
                     "differences after a gap; the first post-resume record " +
                     "would log an rMSSD made entirely of pre-gap beats");
        ok = false;
    }
    if (p.diffIdx() != 0) {
        logger.error("mDiffIdx must be cleared with the count -- the code depends " +
                     "on idx == count while filling; idx=" + p.diffIdx());
        ok = false;
    }
    if (p.diagAt($.RrDiag.I_RING_CLEAR) != 1) {
        logger.error("the ring clear must be counted once, got " + p.diagAt($.RrDiag.I_RING_CLEAR));
        ok = false;
    }
    // A gap with an EMPTY ring is not a clear -- the counter measures discarded
    // data, not events, so a strapless row does not report phantom clears.
    var q = new RrProbe();
    q.feed(1000, [800]);
    q.feed(9000, [800]);
    if (q.diagAt($.RrDiag.I_RING_CLEAR) != 0) {
        logger.error("a gap over an empty ring must not count as a clear");
        ok = false;
    }
    if (q.diagAt($.RrDiag.I_ADJ_GAP) != 1) {
        logger.error("the gap EVENT must still be counted, got " + q.diagAt($.RrDiag.I_ADJ_GAP));
        ok = false;
    }
    return ok;
}

// #38. Sustained artifact rejection closes the rMSSD logging gate.
//
// Six clean beats fill the ring, then in-range beats whose every successive
// difference is rejected by RR_ART_K keep arriving for eight seconds. RED
// before the fix: mLastBeatMs kept advancing, the gate stayed open, and a
// FROZEN mRmssd was written to the trace on every record and accumulated into
// avg_rmssd -- the same staleness #15 set out to remove.
//
// Drives the SHIPPING onTick, so it pins which stamp the gate reads rather
// than restating the predicate.
(:test) function test_rr_c2_sustainedArtifactRejectionClosesTheLogGate(logger) {
    var ok = true;
    var p = new RrProbe();
    p.armRmssd();
    p.feed(1000, [800, 810, 800, 810, 800, 810, 800]);
    if (!(p.rmssd() > 0.0) || p.diffCount() != 6) {
        logger.error("setup failed: rmssd=" + p.rmssd() + " count=" + p.diffCount());
        return false;
    }
    // 500/900 alternating: both well in range, and EVERY successive difference
    // is rejected -- 400 > 0.30 * 900 and 400 > 0.30 * 500 within the pattern,
    // and the first of them is 300 > 0.30 * 800 against the last clean beat.
    // (600/900 does NOT work here and the arithmetic is why: the first
    // difference against an 800 ms reference is 200, and 200 <= 0.30 * 800, so
    // one difference would land and the case would test nothing.)
    // One second apart, so no gap reset fires and the ring is not cleared.
    for (var t = 2000; t <= 9000; t += 1000) {
        p.feed(t, [500, 900]);
    }
    if (p.lastBeatMs() != 9000) {
        logger.error("setup failed: beats should still be arriving, mLastBeatMs=" + p.lastBeatMs());
        return false;
    }
    if (p.lastDiffMs() != 1000) {
        logger.error("no difference should have been accepted since 1000, mLastDiffMs=" + p.lastDiffMs());
        ok = false;
    }
    if (p.diagAt($.RrDiag.I_DIFF_REJ_ART) < 8) {
        logger.error("the artifact rejections must be counted, got " + p.diagAt($.RrDiag.I_DIFF_REJ_ART));
        ok = false;
    }
    var before = p.rmssdField().count();
    p.tickAt(9100);
    if (p.rmssdField().count() != before) {
        logger.error("a frozen rMSSD was written to the trace 8.1 s after the " +
                     "last accepted difference, while beats were still arriving");
        ok = false;
    }
    if (p.rmssdN() != 0) {
        logger.error("a frozen rMSSD was accumulated into avg_rmssd, n=" + p.rmssdN());
        ok = false;
    }
    // The gate is not simply stuck shut: a fresh difference re-opens it.
    p.feed(9500, [900, 890]);
    p.tickAt(9600);
    if (p.rmssdField().count() <= before) {
        logger.error("the gate never re-opened after a fresh accepted difference");
        ok = false;
    }
    return ok;
}

// #68. The rmssd trace is never written as 0.0.
//
// Two clean beats give one difference: the ring is fresh (mLastDiffMs is
// stamped, so the gate is OPEN) and mDiffCount < 5, so recomputeRmssd sets
// mRmssd = 0.0 -- "perfect regularity", an in-band lie the onTick comment block
// itself forbids. RED before the fix: the trace write had no value guard while
// the accumulator beside it did, and that asymmetry is the evidence it was an
// oversight rather than a decision.
(:test) function test_rr_c2_theRmssdTraceIsNeverWrittenAsZero(logger) {
    var ok = true;
    var p = new RrProbe();
    p.armRmssd();
    p.feed(1000, [800, 810, 800]);
    if (p.rmssd() != 0.0) {
        logger.error("setup failed: mRmssd should be the 0.0 insufficient-data " +
                     "sentinel, got " + p.rmssd());
        return false;
    }
    if (p.lastDiffMs() != 1000) {
        logger.error("setup failed: the log gate must be OPEN for this case to " +
                     "test the value guard, mLastDiffMs=" + p.lastDiffMs());
        return false;
    }
    p.tickAt(1100);
    if (p.rmssdField().count() != 0) {
        logger.error("0.0 was written to the rmssd trace -- 'perfect regularity' " +
                     "for a ring holding one difference. Wrote: " + p.rmssdField().last());
        ok = false;
    }
    // and a REAL value is still written, so the guard has not silenced the field
    p.feed(2000, [800, 810, 800, 810, 800]);
    if (!(p.rmssd() > 0.0)) {
        logger.error("setup failed: expected a real rMSSD, got " + p.rmssd());
        return false;
    }
    p.tickAt(2100);
    if (p.rmssdField().count() != 1) {
        logger.error("a real rMSSD was not written; the guard is too wide");
        ok = false;
    }
    return ok;
}

// #68 window 5, the profile #46's review called the dominant real-world dropout
// mode: clean in-range beats arriving MORE than RR_MAX_MS apart. The gap reset
// zeroes the adjacency reference on every batch, so no difference ever lands,
// mDiffCount never leaves 0, and recomputeRmssd returns the 0.0 sentinel -- for
// the whole session, unbounded. Nothing here is artifact-related, and the code
// path is the gap reset rather than the artifact gate.
//
// After the fix mLastDiffMs is never stamped, so the gate is CLOSED as well as
// the value being guarded. Both must hold: either alone would leave a row of
// 0.0 records if the other were removed.
(:test) function test_rr_c2_sparseCleanBeatsLogNoRmssdAtAll(logger) {
    var ok = true;
    var p = new RrProbe();
    p.armRmssd();
    for (var t = 1000; t <= 21000; t += 4000) {
        p.feed(t, [850]);
    }
    if (p.diffCount() != 0) {
        logger.error("setup failed: sparse beats must produce no difference, count=" + p.diffCount());
        return false;
    }
    if (p.lastBeatMs() != 21000) {
        logger.error("setup failed: the beats themselves were accepted, mLastBeatMs=" + p.lastBeatMs());
        return false;
    }
    p.tickAt(21100);
    if (p.rmssdField().count() != 0) {
        logger.error("a 0.0 rMSSD was logged for a session that never produced a " +
                     "single beat pair; wrote " + p.rmssdField().last());
        ok = false;
    }
    if (p.rmssdN() != 0) {
        logger.error("avg_rmssd accumulated from a session with no beat pairs");
        ok = false;
    }
    return ok;
}

// #46, THE CORE CASE. A dropout records the RR_INVALID array, not the last
// batch's beats.
//
// RED before the fix: handleRr wrote the field itself and skipped when there
// was nothing to write, so the record-scope field LATCHED and every subsequent
// record re-emitted the previous batch's intervals. On the activity that
// motivated this, 1,730 of 2,476 records repeated the previous array and the
// longest unbroken run was 185 records.
(:test) function test_rr_c2_aDropoutRecordsTheInvalidArray(logger) {
    var ok = true;
    var p = new RrProbe();
    p.armRr();
    p.feed(1000, [850, 860]);
    p.tickAt(1100);
    if (!arrEq(p.rrField().last(), [850, 860, $.RR_INVALID, $.RR_INVALID], logger,
               "the record written while the batch is fresh")) {
        ok = false;
    }
    // Nothing arrives for six seconds. RR_REC_FRESH_MS is 5000.
    p.tickAt(7100);
    if (!arrEq(p.rrField().last(),
               [$.RR_INVALID, $.RR_INVALID, $.RR_INVALID, $.RR_INVALID], logger,
               "the record written 6.1 s into a dropout")) {
        logger.error("the field re-emitted real beats during a dropout -- " +
                     "duplicate beats in the logged series, which look like data");
        ok = false;
    }
    if (p.diagAt($.RrDiag.I_REC_INVALID) < 1) {
        logger.error("the sentinel write must be counted, got " + p.diagAt($.RrDiag.I_REC_INVALID));
        ok = false;
    }
    // and a fresh batch brings it straight back, so the sentinel is not sticky
    p.feed(8000, [900]);
    p.tickAt(8100);
    if (!arrEq(p.rrField().last(),
               [900, $.RR_INVALID, $.RR_INVALID, $.RR_INVALID], logger,
               "the record after R-R resumes")) {
        ok = false;
    }
    return ok;
}

// #46, THE CASE THAT SEPARATES THE TWO CANDIDATE KEYS, and the reason the
// staleness gate reads mLastBeatMs rather than mLastRrMs.
//
// Batches keep arriving every second for eight seconds, all carrying only
// out-of-range values -- the profile of a strap that is still talking while its
// R-R stream is unusable, which is what "HRM seemed to cut in and out" looks
// like from inside the app. Batch arrival stays fresh throughout; the last
// ACCEPTED BEAT does not. Keying on batch arrival would re-emit the stale array
// for the entire dropout, which is the defect wearing a new hat.
(:test) function test_rr_c2_theRecordGoesInvalidWhenOnlyRejectedBatchesArrive(logger) {
    var ok = true;
    var p = new RrProbe();
    p.armRr();
    p.feed(1000, [850, 860]);
    p.tickAt(1100);
    for (var t = 2000; t <= 9000; t += 1000) {
        p.feed(t, [9000, 9000]);
    }
    if (p.lastRrMs() != 9000) {
        logger.error("setup failed: batches must still be arriving, mLastRrMs=" + p.lastRrMs());
        return false;
    }
    if (p.lastBeatMs() != 1000) {
        logger.error("setup failed: no beat should have been accepted since 1000, " +
                     "mLastBeatMs=" + p.lastBeatMs());
        return false;
    }
    p.tickAt(9100);
    if (!arrEq(p.rrField().last(),
               [$.RR_INVALID, $.RR_INVALID, $.RR_INVALID, $.RR_INVALID], logger,
               "the record 8.1 s after the last ACCEPTED beat, with batches still arriving")) {
        logger.error("the staleness gate is keyed on BATCH ARRIVAL, so a strap " +
                     "delivering unusable R-R holds a stale array fresh forever");
        ok = false;
    }
    return ok;
}

// #46's counterpart to the case above: the field is written on EVERY tick while
// recording, so the record that commits always carries a decision. Before the
// fix it was written only when a batch happened to arrive, which is what let
// the latch reach the file at all -- the naive "stop writing during a dropout"
// remedy IS the defect.
(:test) function test_rr_c2_theRecordFieldIsWrittenOnEveryTick(logger) {
    var ok = true;
    var p = new RrProbe();
    p.armRr();
    p.feed(1000, [850]);
    var n0 = p.rrField().count();
    p.tickAt(1100);
    p.tickAt(1350);
    p.tickAt(1600);
    if (p.rrField().count() != n0 + 3) {
        logger.error("three ticks produced " + (p.rrField().count() - n0) +
                     " writes, not 3 -- a record committing between writes " +
                     "would carry whatever the last write left behind");
        ok = false;
    }
    if (p.diagAt($.RrDiag.I_REC_STAGED) != 3) {
        logger.error("the staged writes must be counted, got " + p.diagAt($.RrDiag.I_REC_STAGED));
        ok = false;
    }
    // and nothing is written while stopped: the write sites are inside the
    // mStarted && !mPaused gate, exactly as every other record field is.
    var q = new RrProbe();
    q.armRr();
    q.setStopped();
    q.feed(1000, [850]);
    q.tickAt(1100);
    if (q.rrField().count() != 0) {
        logger.error("rr_interval was written while not recording");
        ok = false;
    }
    return ok;
}

// A session boundary clears the R-R accumulators, so a second row in the same
// app run does not inherit the first row's rMSSD ring or adjacency reference.
// stopAndSave had never done this. mSession is null in the probe, so only the
// tail of stopAndSave runs -- which is where these resets live, deliberately.
(:test) function test_rr_c2_aSessionBoundaryClearsTheRrAccumulators(logger) {
    var ok = true;
    var p = new RrProbe();
    p.feed(1000, [800, 810, 800, 810, 800, 810, 800]);
    if (p.diffCount() < 5) {
        logger.error("setup failed: the ring should have filled, count=" + p.diffCount());
        return false;
    }
    if (!(p.rmssd() > 0.0)) {
        logger.error("setup failed: mRmssd should be positive, got " + p.rmssd());
        return false;
    }
    p.endSession();
    if (p.diffCount() != 0) { logger.error("the ring must be cleared at a session boundary, count=" + p.diffCount()); ok = false; }
    if (p.diffIdx()   != 0) { logger.error("the ring index must be cleared, idx=" + p.diffIdx()); ok = false; }
    if (p.rrLast()    != 0) { logger.error("the adjacency reference must be cleared, mRrLast=" + p.rrLast()); ok = false; }
    if (p.rmssd()     != 0.0) { logger.error("the cached rMSSD must be cleared, got " + p.rmssd()); ok = false; }
    if (p.lastDiffMs() != 0) { logger.error("mLastDiffMs must be cleared, got " + p.lastDiffMs()); ok = false; }
    if (p.pendingRr() != null) { logger.error("the staged rr_interval array must be dropped"); ok = false; }
    return ok;
}

}
