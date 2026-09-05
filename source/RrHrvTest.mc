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
// The 247 figure is one member tighter than the `v08-display-fixes` anchor,
// which was taken at 211f106: that note is STALE rather than wrong, and the
// tree has gained a member since. Round-2 review found that docs/agents/FACTS.md
// 5.1 still presented it as "the newest anchor in the tree" while this file
// carried a newer one, so that section now quotes the note above instead. Two
// committed statements about the same tree disagreed; the one that was wrong
// was the pointer, and it is corrected where it lives rather than only here.
// scripts/check_ceiling_notes.py enumerates every anchor and cannot tell you
// which is newest, so re-bisect rather than reading either.
//
// RE-BISECTED at the round-2 head, with the two cases this round adds: still
// N=4 BUILD SUCCESSFUL, N=5 "Found 254 members in module 'globals'". Both new
// cases live inside the existing `module RrHrv` block, so they cost nothing --
// which is the whole reason the block is a hard constraint.
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

// ---------------------------------------------------------------------------
// #70, the NEGATIVE-CLOCK half. c0 pins: green before the fix and after it.
// ---------------------------------------------------------------------------
// System.getTimer() is a SIGNED 32-bit millisecond count from device start, so
// between 24.855 and 49.71 days of uptime every stamp this app takes is
// NEGATIVE. Activity i183553852 (recorded on v0.9) was rowed inside that band.
//
// The fix makes "has this ever been stamped?" sign-agnostic -- `!= 0` instead
// of `> 0`. The two cases below pin the two premises that fix rests on, and
// both must hold in EVERY epoch of the change:
//
//   * 0 must keep meaning never-seen, INCLUDING on a negative clock, where the
//     age term alone would say "fresh" (this case);
//   * the age term `now - stamp` must be exact for two stamps in the same half
//     of the signed cycle (the case after it).
//
// A ZERO STAMP IS STILL ABSENT, and on a negative clock the presence guard is
// the ONLY thing that can produce that answer. With now = -2,000,000,000 the
// age of a never-seen stamp is `now - 0` = -2,000,000,000, which is less than
// any threshold, so deleting the guard makes an unstamped field read FRESH
// forever. That is the failure this fix must not introduce while removing the
// sign test -- #54 recorded the positive-clock version of the same trap one
// file over (source/RrRecordTest.mc, test_rr_isFresh_states).
//
// Calls the SHIPPING helpers, all four of them, so it cannot pass against a
// private copy of the comparison.
(:test) function test_rr_c0_neverSeenIsStillNeverSeenOnANegativeClock(logger) {
    var ok = true;
    var neg = -2000000000;
    if (StrongRowView.rrIsFresh(neg, 0, 5000) != false) {
        logger.error("rrIsFresh: a never-seen stamp read FRESH on a negative " +
                     "clock -- now - 0 is hugely negative and passes < thresh");
        ok = false;
    }
    if (StrongRowView.hrHave(true, 0, neg, 5000) != false) {
        logger.error("hrHave: a never-seen stamp read PRESENT on a negative clock");
        ok = false;
    }
    if (CoreTempSensor.ctIsFresh(neg, 0, 5000) != false) {
        logger.error("ctIsFresh: a never-seen stamp read FRESH on a negative clock");
        ok = false;
    }
    // rrGapExceeded's comparison is `>`, so a zero stamp pushes the result the
    // same way the guard does and the guard is NOT load-bearing here. Asserted
    // anyway, and the asymmetry is named rather than left to be rediscovered --
    // it is the exact shape #54 found in test_rr_isFresh_states.
    if (StrongRowView.rrGapExceeded(neg, 0, 2500) != false) {
        logger.error("rrGapExceeded: a never-seen stamp read as a GAP");
        ok = false;
    }
    return ok;
}

// PLATFORM CHARACTERIZATION, not a logic pin, and it is labelled as one because
// this repository's dominant defect is a claim stronger than its evidence.
//
// The fix's correctness argument is "within either half of the signed cycle,
// `now - stamp` is exact, so only the presence term was wrong". Nothing in this
// repository had ever measured Monkey C's Number arithmetic near the 32-bit
// bounds, so that sentence rested on the language reference alone. The first
// block measures it.
//
// The overflow question is DELIBERATELY LOGGED AND NOT ASSERTED. Whether
// 2147483647 + 1 wraps to -2147483648, promotes to a Long, or throws decides
// what happens at the ONE-MINUTE-IN-49.7-DAYS crossing, which is #70's other
// direction and is NOT fixed by this change. Asserting a value here would pin a
// guess; logging it puts the measurement in the run log where the next reader
// can take it. The operands come out of an array
// so the compiler is not handed a literal to fold. Measured on fr965: it folds
// an `if` whose condition is a compile-time constant and says so ("Statement is
// not reachable"), and it emits no such diagnostic for the plain-literal
// comparison at the top of this function -- so it leaves literal integer
// arithmetic to the runtime here either way.
(:test) function test_rr_c0_stampArithmeticOnANegativeClock(logger) {
    var ok = true;
    // 100 ms apart, both deep in the negative half.
    if ((-1999999900) - (-2000000000) != 100) {
        logger.error("subtracting two negative stamps 100 ms apart did not give " +
                     "100 -- the whole 'only the presence term was wrong' " +
                     "argument depends on this being exact");
        ok = false;
    }
    // The same subtraction with the operands behind an array read.
    var st = [-2000000000, -1999999900];
    if (st[1] - st[0] != 100) {
        logger.error("the same subtraction through variables gave " + (st[1] - st[0]));
        ok = false;
    }
    // And the premise that makes `!= 0` a different test from `> 0`.
    if (st[0] == 0 || st[0] > 0) {
        logger.error("a large negative literal did not compare as negative");
        ok = false;
    }
    // MEASURED, NOT ASSERTED -- see the note above. In a try/catch because
    // "it throws" is one of the three candidate answers, and a case that ERRORS
    // while measuring an open question would be indistinguishable from a real
    // regression in the run this file's red evidence comes from.
    var ov = [2147483647, 1];
    try {
        logger.debug("MEASURE #70-wrap: 2147483647 + 1 evaluates to " + (ov[0] + ov[1]));
    } catch (e) {
        logger.debug("MEASURE #70-wrap: 2147483647 + 1 THREW");
    }
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
    // The SESSION-START half of the receive-path diagnostic, driven directly
    // because no (:test) can obtain a Session and so startSession's body is
    // unreachable from here (FACTS.md 3.2). This calls the SHIPPING
    // rrDiagSessionReset -- the same function startSession calls, with no
    // logic of its own -- so a case built on it pins the production reset and
    // not a copy of it. What it CANNOT pin is that startSession still calls
    // it; that link is a one-line static fact, and nothing in the suite can
    // reach it.
    function beginRowAt(t) { rrDiagSessionReset(t); }
    function gapBaseMs()   { return mRrGapBaseMs; }
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

// The snapshot's clamp is USED, not merely present -- and the case above
// cannot show that. test_rr_c1_diagCountersSaturate calls $.RrDiag.clamp with
// literals, so it stays green if rrDiagSnapshot stops calling it. MEASURED on
// this branch at c96ea5a: replacing the snapshot's `a[i] = $.RrDiag.clamp(
// mRrDiag[i]);` with `a[i] = mRrDiag[i];` left the WHOLE suite green at
// PASSED (passed=383, failed=0, errors=0) -- a surviving mutant, and the shape
// source/RrDiag.mc's header warns about one sensor over (ct_diag pinned a
// prefix; a tail permutation would have gone unnoticed).
//
// The gap slots are the cheap way in: handleRrAt writes them as raw whole
// seconds, unclamped, so a 70,000 s silence puts a value past MAXV in front of
// a UINT16 setData and ONLY the readout clamp brings it back. Both slots are
// driven by one batch because both are written from it -- the "a beat has ever
// been range-accepted" guard and `mLastBeatMs == now` both hold on the second
// feed. (That guard was spelled `prevBeatMs > 0` when this paragraph was
// written; #70 respells it `!= 0` because on a negative System.getTimer() the
// sign test rejects every live stamp. Named by role here rather than by
// spelling, so the paragraph cannot go stale a second time.)
(:test) function test_rr_c1_snapshotClampsAGapPastMaxv(logger) {
    var ok = true;
    var p = new RrProbe();
    p.feed(1000, [800]);
    p.feed(70001000, [800]);   // 70,000 s of silence -- past MAXV in both slots
    if (p.diagAt($.RrDiag.I_MAXGAP_BATCH) != $.RrDiag.MAXV) {
        logger.error("batch-gap slot read " + p.diagAt($.RrDiag.I_MAXGAP_BATCH) +
                     ", not MAXV -- an unclamped value reaches the UINT16 field");
        ok = false;
    }
    if (p.diagAt($.RrDiag.I_MAXGAP_BEAT) != $.RrDiag.MAXV) {
        logger.error("beat-gap slot read " + p.diagAt($.RrDiag.I_MAXGAP_BEAT) +
                     ", not MAXV");
        ok = false;
    }
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

// #70's new symbol. laterStamp(a, b) is "the later of two stamps on one clock,
// where 0 means never-seen", and it exists because the two rr_diag gap-baseline
// sites each wrote that as a bare `>` -- correct only while the clock is
// positive, where the 0 sentinel loses every comparison by luck.
//
// Green from the commit that introduces it. Wiring the call sites is the fix;
// test_rr_c2_theGapSlotsPopulateOnANegativeClock is the differential that
// proves the wiring, and its SECOND half -- an unset baseline against a real
// negative stamp -- is the half a fixed outer guard alone does not close.
//
// The THIRD row of each half is the one that matters and is why this symbol
// exists at all: with a negative stamp and an unset (0) baseline, `>` picks 0.
(:test) function test_rr_c1_laterStampTreatsZeroAsNeverSeen(logger) {
    var ok = true;
    // Positive clock: ordinary max, and the sentinel loses either way round.
    if (StrongRowView.laterStamp(1000, 2000) != 2000) { logger.error("later(1000,2000)"); ok = false; }
    if (StrongRowView.laterStamp(2000, 1000) != 2000) { logger.error("later(2000,1000)"); ok = false; }
    if (StrongRowView.laterStamp(1000, 0)    != 1000) { logger.error("later(1000,0) must ignore the sentinel"); ok = false; }
    if (StrongRowView.laterStamp(0, 1000)    != 1000) { logger.error("later(0,1000) must ignore the sentinel"); ok = false; }
    // Negative clock: ordering still holds, and -1 is LATER than -2000000000.
    if (StrongRowView.laterStamp(-2000000000, -1999000000) != -1999000000) { logger.error("later(-2e9,-1.999e9)"); ok = false; }
    if (StrongRowView.laterStamp(-1999000000, -2000000000) != -1999000000) { logger.error("later(-1.999e9,-2e9)"); ok = false; }
    // THE CASE `>` GETS WRONG: an unset baseline must not displace a real stamp.
    if (StrongRowView.laterStamp(-2000000000, 0) != -2000000000) {
        logger.error("later(-2e9, 0) returned " + StrongRowView.laterStamp(-2000000000, 0) +
                     " -- an UNSET baseline displaced a real negative stamp, which " +
                     "is exactly what the bare `>` did");
        ok = false;
    }
    if (StrongRowView.laterStamp(0, -2000000000) != -2000000000) { logger.error("later(0,-2e9)"); ok = false; }
    // Both never-seen stays never-seen, so the caller's own `!= 0` gate still
    // sees a sentinel rather than a time.
    if (StrongRowView.laterStamp(0, 0) != 0) { logger.error("later(0,0) must stay 0"); ok = false; }
    return ok;
}

// #70's new flag bit. F_CLOCK_NEG must be a distinct power of two, or ORing the
// three bits into slot 20 is lossy and every recorded file's flags byte is
// re-keyed. Setting the bit is the fix;
// test_rr_c2_theClockSignReachesTheDiagFlags is the differential for it, and
// it also carries the ABSOLUTE version pin that nothing here had before.
(:test) function test_rr_c1_theClockSignFlagBitIsDistinct(logger) {
    var ok = true;
    if ($.RrDiag.F_CLOCK_NEG != 4) {
        logger.error("F_CLOCK_NEG is " + $.RrDiag.F_CLOCK_NEG + ", not 4 -- moving " +
                     "a flag bit re-keys the flags slot of every recorded file");
        ok = false;
    }
    if (($.RrDiag.F_CLOCK_NEG & $.RrDiag.F_RR_REGISTERED) != 0
            || ($.RrDiag.F_CLOCK_NEG & $.RrDiag.F_SENSOR_OK) != 0) {
        logger.error("the rr_diag flag bits overlap, so the OR into slot 20 is lossy");
        ok = false;
    }
    // It fits the UINT16 slot with the other two set, which is the only size
    // question a flags slot has.
    var all = $.RrDiag.F_RR_REGISTERED | $.RrDiag.F_SENSOR_OK | $.RrDiag.F_CLOCK_NEG;
    if (all != 7 || $.RrDiag.clamp(all) != all) {
        logger.error("all three flags together read " + all + " and clamp to " +
                     $.RrDiag.clamp(all));
        ok = false;
    }
    return ok;
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

// THE TWO GAP SLOTS MEASURE SILENCE INSIDE THE ROW, not silence that straddled
// START. Round-2 review finding 2: zeroing mRrDiag at startSession is not the
// whole reset, because slots 18 and 19 are computed from mLastRrMs and
// mLastBeatMs, and those two stamps deliberately SURVIVE a session boundary
// (stopAndSave says so in as many words -- the display pip and the #16 gap
// check need them). So the first post-START batch after a silence that
// straddled START loaded the WHOLE straddling duration into the two slots, and
// the slots take a running max, so it was sticky for the row.
//
// That inverts the discrimination the pair exists to make: source/RrDiag.mc
// tells a reader "both large means delivery stopped", and the row below had a
// 30 s in-row gap, not a 390 s delivery failure.
//
// Driven through the SHIPPING rrDiagSessionReset (via RrProbe.beginRowAt),
// which is the function startSession calls; no (:test) can reach startSession
// itself, so what this case CANNOT show is that startSession still calls it.
//
// The second half is the near neighbour, and it is here because the same
// mechanism recurs at EVERY session boundary in one app run, not just the
// first: stopAndSave does not reset the stamps either, so a second row started
// after a gap since the first row's last beat would load that inter-row
// silence into its own slots.
(:test) function test_rr_c2_theGapSlotsAreMeasuredFromSessionStart(logger) {
    var ok = true;
    var p = new RrProbe();
    // On the dock: the strap streams, so both stamps are set. Then it comes
    // loose and delivers nothing for six minutes.
    p.feed(1000, [850]);
    // START pressed mid-silence, at t+360 s.
    p.beginRowAt(361000);
    if (p.gapBaseMs() != 361000) {
        logger.error("the session reset must stamp the gap baseline, got " + p.gapBaseMs());
        return false;
    }
    if (p.diagAt($.RrDiag.I_BATCH_OK) != 0) {
        logger.error("setup failed: the session reset must zero the counters, BATCH_OK=" +
                     p.diagAt($.RrDiag.I_BATCH_OK));
        return false;
    }
    // The strap reconnects 30 s into the row.
    p.feed(391000, [850]);
    if (p.diagAt($.RrDiag.I_MAXGAP_BATCH) != 30) {
        logger.error("the batch-gap slot must measure 30 s from session start, got " +
                     p.diagAt($.RrDiag.I_MAXGAP_BATCH) +
                     " -- silence that straddled START is being reported as part of the row");
        ok = false;
    }
    if (p.diagAt($.RrDiag.I_MAXGAP_BEAT) != 30) {
        logger.error("the beat-gap slot must measure 30 s from session start, got " +
                     p.diagAt($.RrDiag.I_MAXGAP_BEAT));
        ok = false;
    }
    // Second row of the same app run, started 1000 s after the first row's
    // last beat, with the first batch 10 s in.
    p.endSession();
    p.beginRowAt(1391000);
    p.feed(1401000, [850]);
    if (p.diagAt($.RrDiag.I_MAXGAP_BATCH) != 10) {
        logger.error("the batch-gap slot must restart at the SECOND row too, got " +
                     p.diagAt($.RrDiag.I_MAXGAP_BATCH));
        ok = false;
    }
    if (p.diagAt($.RrDiag.I_MAXGAP_BEAT) != 10) {
        logger.error("the beat-gap slot must restart at the SECOND row too, got " +
                     p.diagAt($.RrDiag.I_MAXGAP_BEAT));
        ok = false;
    }
    return ok;
}

// ===========================================================================
// #70 -- the NEGATIVE-CLOCK differentials. All RED before c3.
// ===========================================================================
// System.getTimer() is a SIGNED 32-bit millisecond count from device start, so
// from 24.855 days of uptime to 49.71 days every stamp is negative. Every
// presence guard in the app asked "has this ever been stamped?" by testing the
// SIGN of such a value, so on a device inside that band a live signal read as
// never-seen and stayed that way for the whole row.
//
// NOT A THOUGHT EXPERIMENT. Activity i183553852, 56 minutes, recorded on v0.9
// with the device's uptime inside the band: rr_diag REC_STAGED = 0 and
// REC_INVALID = 13335 while BEAT_ACCEPT = 1597, avg_rmssd absent from the
// session despite DIFF_ACCEPT = 1596, core_temperature / skin / HSI /
// max_core never written while ct_diag CORE_OK = 33, and the HR arc on its
// no-data track for the whole row while Garmin logged 118.6 bpm average.
//
// THE CONSTANTS. -2,000,000,000 ms is about 23.1 days before the signed
// counter's wrap, i.e. an ordinary reading inside the negative half; the
// second stamp is 100 ms later, which is one R-R batch period at the
// :period => 1 registration. Nothing here crosses the wrap -- that is #70's
// OTHER direction and is explicitly not fixed by this change.
//
// EVERY CASE CALLS THE SHIPPING CODE. The four pure ones call the shipping
// statics directly; the three end-to-end ones drive handleRrAt / onTick /
// rrDiagSessionReset through RrProbe, which overrides nowMs() and adds no
// logic of its own.

// rrIsFresh: a stamp 100 ms old on a negative clock is FRESH.
//
// RED before the fix: `tsMs > 0` is false for every stamp in the negative half,
// so the helper answered "never seen" for a reading taken 100 ms ago. This is
// the gate on rr_interval (RR_REC_FRESH_MS), on rmssd/avg_rmssd
// (RR_LOG_FRESH_MS) and on the display pip (RR_DISPLAY_FRESH_MS).
(:test) function test_rr_c2_rrIsFreshOnANegativeClock(logger) {
    var ok = true;
    if (StrongRowView.rrIsFresh(-1999999900, -2000000000, 5000) != true) {
        logger.error("a 100 ms old stamp on a negative clock read STALE -- " +
                     "the presence guard is testing the sign, not the presence");
        ok = false;
    }
    // The age term still decides, so a genuinely stale negative stamp stays
    // stale. Without this the fix could be "return true whenever ts != 0".
    if (StrongRowView.rrIsFresh(-1999990000, -2000000000, 5000) != false) {
        logger.error("a 10 s old stamp on a negative clock read FRESH");
        ok = false;
    }
    // and the boundary keeps its strict `<` on this side of zero too
    if (StrongRowView.rrIsFresh(-1999995000, -2000000000, 5000) != false) {
        logger.error("age == thresh must be stale (strict <) on a negative clock");
        ok = false;
    }
    return ok;
}

// rrGapExceeded: a 3 s silence on a negative clock IS a gap.
//
// RED before the fix, and it fails the OTHER way from rrIsFresh -- the guard is
// `>` here, so a suppressed presence term makes a real gap invisible. The
// consequence is #16's adjacency reset never firing, so the first beat after a
// dropout is diffed against a pre-dropout beat and that difference is fed to
// rMSSD as though the two were consecutive.
(:test) function test_rr_c2_rrGapExceededOnANegativeClock(logger) {
    var ok = true;
    if (StrongRowView.rrGapExceeded(-1999997000, -2000000000, 2500) != true) {
        logger.error("a 3 s silence on a negative clock was not seen as a gap -- " +
                     "the adjacency reset never fires and rMSSD diffs across the dropout");
        ok = false;
    }
    if (StrongRowView.rrGapExceeded(-1999999000, -2000000000, 2500) != false) {
        logger.error("a 1 s silence on a negative clock was reported as a gap");
        ok = false;
    }
    if (StrongRowView.rrGapExceeded(-1999997500, -2000000000, 2500) != false) {
        logger.error("gap == thresh must not be a gap (strict >) on a negative clock");
        ok = false;
    }
    return ok;
}

// hrHave: a heart rate read 100 ms ago on a negative clock is PRESENT.
//
// RED before the fix. This is the HR arc's whole presence decision, and it is
// what put the arc on its no-data track for all 56 minutes of i183553852 while
// Garmin's own heart_rate field averaged 118.6 bpm over the same row.
(:test) function test_rr_c2_hrHaveOnANegativeClock(logger) {
    var ok = true;
    if (StrongRowView.hrHave(true, -2000000000, -1999999900, 5000) != true) {
        logger.error("a 100 ms old HR reading on a negative clock read ABSENT -- " +
                     "the arc renders its no-data track for the whole row");
        ok = false;
    }
    // The EVER flag is still independent and still dominant: #110's two
    // conditions stay two conditions.
    if (StrongRowView.hrHave(false, -2000000000, -1999999900, 5000) != false) {
        logger.error("hrHave ignored the ever-seen flag on a negative clock");
        ok = false;
    }
    if (StrongRowView.hrHave(true, -2000000000, -1999990000, 5000) != false) {
        logger.error("a 10 s old HR reading on a negative clock read PRESENT");
        ok = false;
    }
    return ok;
}

// ctIsFresh: the same defect in CoreTempSensor, and the same fix.
//
// RED before the fix. coreFreshAt / skinFreshAt / hsiFreshAt all route through
// this one predicate, and coreTempAt / skinTempAt return 0.0 when it says
// stale -- which is why i183553852 has ct_diag CORE_OK = 33 (33 valid core
// frames decoded) and no core_temperature, skin_temperature, heat_strain_index
// or max_core_temperature anywhere in the file.
//
// Lives in this file rather than beside its siblings in CoreTempSensorTest.mc
// for one reason: `module RrHrv` costs no fenix6 `globals` member, and a new
// file-scope (:test) in CoreTempSensorTest.mc costs one out of the four free
// (FACTS.md 5.1). CoreTempSensor.ctIsFresh is a public static, so the case
// calls exactly the shipping predicate the CORE getters call.
(:test) function test_rr_c2_ctIsFreshOnANegativeClock(logger) {
    var ok = true;
    if (CoreTempSensor.ctIsFresh(-1999999900, -2000000000, 5000) != true) {
        logger.error("a 100 ms old CORE stamp on a negative clock read STALE -- " +
                     "coreTemp()/skinTemp() then return 0.0 and the fields are never written");
        ok = false;
    }
    if (CoreTempSensor.ctIsFresh(-1999990000, -2000000000, 5000) != false) {
        logger.error("a 10 s old CORE stamp on a negative clock read FRESH");
        ok = false;
    }
    // At the SHIPPING window rather than a synthetic one, so the case also
    // says the real 30 s gate behaves on this side of zero.
    if (CoreTempSensor.ctIsFresh(-1999980000, -2000000000, $.CT_FRESH_MS) != true) {
        logger.error("a 20 s old CORE stamp is inside CT_FRESH_MS and read STALE");
        ok = false;
    }
    return ok;
}

// END TO END, through the shipping receive path and the shipping onTick: a
// clean batch on a negative clock is STAGED, not sentinelled.
//
// RED before the fix. This is the exact shape of i183553852's rr_diag:
// REC_STAGED = 0 with REC_INVALID = 13335 while BEAT_ACCEPT = 1597 -- beats
// were accepted and staged on every tick and the record wrote the 0xFFFF
// sentinel anyway, because the staleness gate could not see the stamp
// handleRrAt had just written.
(:test) function test_rr_c2_theRecordStagesOnANegativeClock(logger) {
    var ok = true;
    var p = new RrProbe();
    p.armRr();
    p.feed(-2000000000, [850, 860]);
    if (p.lastBeatMs() != -2000000000) {
        logger.error("setup failed: the beat stamp should be the injected clock, got " +
                     p.lastBeatMs());
        return false;
    }
    p.tickAt(-1999999900);
    if (p.diagAt($.RrDiag.I_REC_STAGED) != 1) {
        logger.error("REC_STAGED = " + p.diagAt($.RrDiag.I_REC_STAGED) +
                     ", expected 1 -- a batch accepted 100 ms ago was recorded as absent");
        ok = false;
    }
    if (p.diagAt($.RrDiag.I_REC_INVALID) != 0) {
        logger.error("REC_INVALID = " + p.diagAt($.RrDiag.I_REC_INVALID) +
                     ", expected 0 -- the sentinel was written over live beats");
        ok = false;
    }
    if (!arrEq(p.rrField().last(), [850, 860, $.RR_INVALID, $.RR_INVALID], logger,
               "the record written 100 ms after a clean batch, on a negative clock")) {
        ok = false;
    }
    return ok;
}

// The same seam one gate over: the rMSSD / avg_rmssd log gate.
//
// RED before the fix. i183553852 has DIFF_ACCEPT = 1596 -- 1,596 artifact-
// accepted successive differences -- and no avg_rmssd in the session at all,
// because the gate at onTick keys on mLastDiffMs through the same helper.
(:test) function test_rr_c2_theRmssdGateOpensOnANegativeClock(logger) {
    var ok = true;
    var p = new RrProbe();
    p.armRmssd();
    p.feed(-2000000000, [800, 810, 800, 810, 800, 810, 800]);
    if (p.diffCount() < 5 || !(p.rmssd() > 0.0)) {
        logger.error("setup failed: ring=" + p.diffCount() + " rmssd=" + p.rmssd());
        return false;
    }
    p.tickAt(-1999999900);
    if (p.rmssdField().count() != 1) {
        logger.error("the rmssd trace was written " + p.rmssdField().count() +
                     " times, expected 1 -- the log gate read a 100 ms old " +
                     "difference as stale");
        ok = false;
    }
    if (p.rmssdN() != 1) {
        logger.error("the avg_rmssd accumulator did not advance (n=" + p.rmssdN() +
                     ") -- this is the session field going missing entirely");
        ok = false;
    }
    return ok;
}

// The two rr_diag gap slots populate on a negative clock. THE laterStamp
// DIFFERENTIAL: `!= 0` on the outer guard alone is not enough here.
//
// RED before the fix, in BOTH halves and for two different reasons:
//
//   * first half -- a row with a baseline. `bBase = mLastRrMs` then
//     `if (mRrGapBaseMs > bBase)`: both stamps are negative and the max is
//     right, but the outer `bBase > 0` is false, so neither slot is written.
//   * second half -- a probe that never started a session, so mRrGapBaseMs is
//     still 0. Now `0 > -2000360000` is TRUE, the unset sentinel displaces a
//     real stamp, and even a fixed outer guard measures from nothing. That is
//     the half `!= 0` alone does not fix and StrongRowView.laterStamp does.
//
// Mirrors test_rr_c2_theGapSlotsAreMeasuredFromSessionStart above, on the
// negative side of zero, and is driven through the SHIPPING
// rrDiagSessionReset (via RrProbe.beginRowAt) for the same reason that case
// gives: no (:test) can reach startSession itself.
(:test) function test_rr_c2_theGapSlotsPopulateOnANegativeClock(logger) {
    var ok = true;
    var p = new RrProbe();
    // On the dock, 360 s before START: the strap streams, then goes quiet.
    p.feed(-2000360000, [850]);
    p.beginRowAt(-2000000000);
    if (p.gapBaseMs() != -2000000000) {
        logger.error("setup failed: the gap baseline is " + p.gapBaseMs());
        return false;
    }
    // The strap reconnects 30 s into the row.
    p.feed(-1999970000, [850]);
    if (p.diagAt($.RrDiag.I_MAXGAP_BATCH) != 30) {
        logger.error("MAXGAP_BATCH = " + p.diagAt($.RrDiag.I_MAXGAP_BATCH) +
                     ", expected 30 -- the batch-gap slot is blind on a negative clock");
        ok = false;
    }
    if (p.diagAt($.RrDiag.I_MAXGAP_BEAT) != 30) {
        logger.error("MAXGAP_BEAT = " + p.diagAt($.RrDiag.I_MAXGAP_BEAT) +
                     ", expected 30 -- the beat-gap slot is blind on a negative clock");
        ok = false;
    }
    // NO SESSION EVER STARTED, so the baseline is the 0 sentinel and the whole
    // 390 s silence is the measurement. This is the half that needs laterStamp:
    // with a bare `>` the sentinel wins and the slot reads 0.
    var q = new RrProbe();
    q.feed(-2000360000, [850]);
    q.feed(-1999970000, [850]);
    if (q.gapBaseMs() != 0) {
        logger.error("setup failed: this probe must never have started a row, base=" +
                     q.gapBaseMs());
        return false;
    }
    if (q.diagAt($.RrDiag.I_MAXGAP_BATCH) != 390) {
        logger.error("MAXGAP_BATCH = " + q.diagAt($.RrDiag.I_MAXGAP_BATCH) +
                     ", expected 390 -- an UNSET baseline displaced a real negative " +
                     "stamp, so the slot measured from the sentinel instead");
        ok = false;
    }
    if (q.diagAt($.RrDiag.I_MAXGAP_BEAT) != 390) {
        logger.error("MAXGAP_BEAT = " + q.diagAt($.RrDiag.I_MAXGAP_BEAT) + ", expected 390");
        ok = false;
    }
    return ok;
}

// The clock's sign reaches the file, and the layout version says the file
// changed shape.
//
// RED before the fix on three counts: VERSION is still 1, the bit is never
// set, and slot 0 therefore still carries 1.
//
// WHY THE VERSION BUMP IS PINNED ABSOLUTELY HERE. test_rr_c1_diagSnapshotShape
// compares slot 0 against $.RrDiag.VERSION, which is a RELATIVE check: it
// tracks any bump silently and cannot notice one that was forgotten. Nothing
// in this repository pinned the rr_diag version to a literal before this case,
// so adding a flag bit without bumping -- which silently re-keys the flags slot
// of every file already recorded -- would have passed the whole suite.
(:test) function test_rr_c2_theClockSignReachesTheDiagFlags(logger) {
    var ok = true;
    if ($.RrDiag.VERSION != 2) {
        logger.error("RrDiag.VERSION is " + $.RrDiag.VERSION + ", expected 2 -- " +
                     "the flags slot gained a bit and every recorded file's key moved");
        ok = false;
    }
    var p = new RrProbe();
    p.beginRowAt(-2000000000);
    if ((p.diagAt($.RrDiag.I_FLAGS) & $.RrDiag.F_CLOCK_NEG) == 0) {
        logger.error("F_CLOCK_NEG is clear after a session start on a negative " +
                     "clock; flags = " + p.diagAt($.RrDiag.I_FLAGS));
        ok = false;
    }
    if (p.diagAt($.RrDiag.I_VERSION) != 2) {
        logger.error("slot 0 carries " + p.diagAt($.RrDiag.I_VERSION) + ", not 2");
        ok = false;
    }
    // A positive clock leaves it clear, so the bit is a MEASUREMENT and not a
    // constant. Without this half the fix could be "always set the bit".
    var q = new RrProbe();
    q.beginRowAt(1000);
    if ((q.diagAt($.RrDiag.I_FLAGS) & $.RrDiag.F_CLOCK_NEG) != 0) {
        logger.error("F_CLOCK_NEG is set after a session start on a POSITIVE clock");
        ok = false;
    }
    // A probe that never started a row has never measured the clock, so the
    // bit must be clear rather than null-derived garbage.
    var r = new RrProbe();
    if ((r.diagAt($.RrDiag.I_FLAGS) & $.RrDiag.F_CLOCK_NEG) != 0) {
        logger.error("F_CLOCK_NEG is set on a probe that never started a row");
        ok = false;
    }
    return ok;
}

}
