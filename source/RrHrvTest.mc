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
