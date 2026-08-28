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
