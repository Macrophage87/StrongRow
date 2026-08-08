using Toybox.Test;
using Toybox.System;
using Toybox.Lang;

// The CORE P1 bundle: #13 (temperature record fields log 0.0 during a pod
// dropout), plus the residue of #18 (a resource allocated, thrown past and
// dropped without release) and #26 (a retry path with no bound) that the
// merged fixes for those two left behind in the RETRY TIMER.
//
// WHAT #18, #26 AND #17 ALREADY DO ON MAIN, because it decides what this file
// is for. All three were fixed by the CoreTempSensor PR (commits c5af074 #18,
// 872a1d9 #26, 31a807a #17) and their issues were simply never closed. Their
// pins live in CoreTempSensorTest.mc and each was watched failing against a
// deliberate mutation before this file was written -- see the PR body's
// mutation table. Nothing here re-pins them.
//
// ---- THE GLOBALS CEILING ---------------------------------------------------
//
// EVERY declaration in this file sits inside `module CoreP1`. A file-scope
// (:test), helper function or class costs one member of module 'globals', which
// the fenix6 family caps at 253; a `module { }` block costs ONE member for
// everything inside it. Measured by bisection on SDK 9.2.0 against this branch,
// the same way scripts/list_tests.py records it:
//
//     CEILING core-p1 fenix6-family: 240 used of 253, 13 free -- the 14th file-scope (:test) added reds
//
// (240 = main's 239 after #139's `module CueFix`, plus this file's one module.
// The `post-move` note in scripts/list_tests.py and source/FootStateTest.mc
// records 238/15 free against an older tree and is not restated here; a note
// carries its own anchor precisely so two measurements of different trees are
// not mistaken for a disagreement.)
//
// So: declare nothing in this file outside the module block. The names the
// simulator prints -- and therefore the names scripts/expected_tests.txt must
// carry -- are `CoreP1.test_...`.
//
// ---- Execution -------------------------------------------------------------
//
// These run headlessly in the simulator on every PR (`monkeydo <prg> fr965 -t`,
// judged by a fail-closed parser), with names pinned in
// scripts/expected_tests.txt -- edit that file in the SAME commit as any
// (:test) change here. See docs/CI.md.
//
// c0: characterization pins ONLY. Every assertion below is true both before and
// after the fixes in this branch. They exist so the differentials that follow
// cannot be satisfied by a change that is merely different, and -- for
// test_c0_dropoutAfterAReadingWritesZeroNotTheLastValue especially -- so that
// the ONE thing #13 must not do has a test standing in front of it.
module CoreP1 {

    // ---- doubles -----------------------------------------------------------

    // A FitContributor field stand-in that records the VALUES written, not just
    // a count. #13 is a question about what lands in the file, so a counter
    // alone could not tell a fix from a regression: "wrote something" and
    // "wrote 0.0" are the two answers that have to stay apart.
    class RecField {
        var values;
        function initialize() { values = []; }
        function setData(v) {
            if (values == null) { values = []; }
            values.add(v);
        }
        function count() {
            if (values == null) { values = []; }
            return values.size();
        }
        function last() {
            if (values == null || values.size() == 0) { return null; }
            return values[values.size() - 1];
        }
    }

    // A CORE pod stand-in. A dropout is expressed the way the SHIPPING sensor
    // expresses one -- coreTemp() / skinTemp() returning 0.0 -- rather than by
    // a flag of this double's own invention, so the probe below feeds onTick
    // exactly the values CoreTempSensor.coreTempAt / skinTempAt produce (they
    // return `fresh ? reading : 0.0`).
    //
    // Duck-typed: mCoreSensor is an untyped field and this codebase compiles
    // untyped, so only the members onTick actually calls need to exist.
    class StubCore {
        var core;
        var skin;
        function initialize() { core = 0.0; skin = 0.0; }
        function coreTemp() { return core; }
        function skinTemp() { return skin; }
        // Pod-level freshness, matching CoreTempSensor.isFreshAt: either field.
        function isFresh()  { return core > 0.0 || skin > 0.0; }
        function everSeen() { return core > 0.0 || skin > 0.0; }
        // #80's field is left absent throughout: heat strain is a separate
        // quantity on a separate stamp, and letting it move would put a second
        // variable in every #13 case.
        function hsiFresh()  { return false; }
        function heatIndex() { return null; }
        function close() { }
    }

    // Drives the REAL onTick. `hidden` is protected in Monkey C, so a subclass
    // reaches the field handles and the recording flags without adding anything
    // to the shipping class -- the same seam LifeProbe (ViewLifecycleTest.mc)
    // and CoreProbe (CoreTempSensorTest.mc) use.
    //
    // Driving onTick() rather than a transcription of its core/skin block is
    // the point: a test that re-implements the write decision pins nothing, and
    // this repository has shipped that twice. The gate onTick applies BEFORE
    // any field write (`mStarted && !mPaused`) is therefore part of what is
    // under test, not something the probe reaches around.
    class TickProbe extends StrongRowView {
        var core;   // the RecField behind mFitCore
        var skin;   // the RecField behind mFitSkin
        var pod;    // the StubCore behind mCoreSensor

        function initialize() {
            StrongRowView.initialize();
            core = new RecField();
            skin = new RecField();
            pod  = new StubCore();
            mFitCore    = core;
            mFitSkin    = skin;
            mCoreSensor = pod;
            mStarted    = true;
            mPaused     = false;
            // onTick's tail held inert, and only its tail. The step machine
            // and the per-interval heart-rate accumulator take no part in #13,
            // and driving the step machine from a test would reach alert() --
            // which vibrates and plays a tone.
            mWorkoutEnabled = false;
            mSetNum         = 0;
        }

        // One tick with the pod reporting `c` and `s`. 0.0 is not a magic
        // number here: it is what the shipping getters return when nothing is
        // current, so `tick(0.0, 0.0)` IS a dropout as onTick sees one.
        function tick(c, s) {
            pod.core = c;
            pod.skin = s;
            onTick();
        }

        // Session-scope max, to show the #13 gate does not disturb it.
        function maxCore() { return mMaxCore; }
    }

    // ---- helpers -----------------------------------------------------------

    function almost(a, b) {
        if (a == null) { return false; }
        var d = a - b;
        if (d < 0) { d = -d; }
        return d < 0.001;
    }

    // ---- c0 pins -----------------------------------------------------------

    // The ordinary case, pinned first so no later differential can be satisfied
    // by a gate that simply stops writing. A tick with a current reading writes
    // that reading, to both fields, exactly once.
    (:test) function test_c0_freshTickWritesTheReading(logger) {
        var p = new TickProbe();
        p.tick(37.42, 33.00);
        var ok = true;
        if (p.core.count() != 1) {
            logger.error("a tick with a current core reading must write it once, writes = " + p.core.count());
            ok = false;
        } else if (!almost(p.core.last(), 37.42)) {
            logger.error("core_temperature = " + p.core.last() + ", expected 37.42");
            ok = false;
        }
        if (p.skin.count() != 1) {
            logger.error("a tick with a current skin reading must write it once, writes = " + p.skin.count());
            ok = false;
        } else if (!almost(p.skin.last(), 33.00)) {
            logger.error("skin_temperature = " + p.skin.last() + ", expected 33.00");
            ok = false;
        }
        return ok;
    }

    // THE PIN THAT STANDS IN FRONT OF #13's OWN SUGGESTED FIX.
    //
    // The issue proposes skipping setData during a dropout, "leaving the record
    // field absent for stale ticks". Record-scope FitContributor fields LATCH:
    // #36 measured, byte level on fr965 / SDK 9.2.0, that a skipped write
    // RE-EMITS THE PREVIOUS VALUE on the next record. So skipping after a real
    // reading does not produce a gap -- it republishes 37.42 for the rest of
    // the row, which is indistinguishable from a pod that stayed on and read
    // steady. That is strictly worse than the 0.0 this issue was filed about,
    // because 0.0 is outside the accepted band by construction
    // (test_c0_zeroIsNeverAnAcceptedReading below) and a latched 37.42 is not.
    //
    // Green before and after this branch, deliberately: the fix must NOT change
    // this case. If a later edit turns the dropout write into a skip, this test
    // is what reds.
    (:test) function test_c0_dropoutAfterAReadingWritesZeroNotTheLastValue(logger) {
        var p = new TickProbe();
        p.tick(37.42, 33.00);
        p.tick(0.0, 0.0);              // the pod dropped out
        var ok = true;
        if (p.core.count() != 2) {
            logger.error("a dropout after a reading must still write -- record fields " +
                         "latch, so skipping re-emits 37.42 rather than gapping. writes = " +
                         p.core.count());
            ok = false;
        } else if (p.core.last() != 0.0) {
            logger.error("dropout core_temperature = " + p.core.last() + ", expected 0.0");
            ok = false;
        }
        if (p.skin.count() != 2) {
            logger.error("a dropout after a reading must still write skin_temperature, writes = " +
                         p.skin.count());
            ok = false;
        } else if (p.skin.last() != 0.0) {
            logger.error("dropout skin_temperature = " + p.skin.last() + ", expected 0.0");
            ok = false;
        }
        return ok;
    }

    // The other direction: whatever the gate does with a silent start, the
    // first real reading has to reach the field. Without this a fix that simply
    // never wrote would satisfy every differential in c2.
    (:test) function test_c0_theFirstReadingIsAlwaysWritten(logger) {
        var p = new TickProbe();
        p.tick(0.0, 0.0);
        p.tick(0.0, 0.0);
        p.tick(37.42, 33.00);
        var ok = true;
        if (!almost(p.core.last(), 37.42)) {
            logger.error("the first current core reading must be written, last = " + p.core.last());
            ok = false;
        }
        if (!almost(p.skin.last(), 33.00)) {
            logger.error("the first current skin reading must be written, last = " + p.skin.last());
            ok = false;
        }
        return ok;
    }

    // max_core_temperature is accumulated at the same call site and must not
    // move when the gate does. A dropout tick contributes nothing to it either
    // way, which is why the `mMaxCore > 0.0` guard in stopAndSave is still the
    // sole defence against a bogus 0 C on a podless row.
    (:test) function test_c0_dropoutsDoNotDisturbTheSessionMax(logger) {
        var p = new TickProbe();
        p.tick(37.42, 33.00);
        p.tick(0.0, 0.0);
        p.tick(36.10, 32.00);
        if (!almost(p.maxCore(), 37.42)) {
            logger.error("max core = " + p.maxCore() + ", expected the 37.42 peak");
            return false;
        }
        return true;
    }

    // THE PREMISE THE #13 GATE RESTS ON, asserted through the DECODER rather
    // than by restating the constants. 0.0 C can only serve as the dropout
    // marker if no accepted frame can ever produce it -- so a frame carrying a
    // genuine 0.00 C in either field must be REJECTED by the plausibility
    // clamps. If a future clamp change ever admitted 0.0, the marker would
    // start colliding with real data and this reds.
    (:test) function test_c0_zeroIsNeverAnAcceptedReading(logger) {
        var ok = true;
        // core raw 0 -> 0.00 C, skin raw 0 -> 0.00 C.
        if (CoreTempSensor.decodeCoreC($.ctPayload(660, 0x0C8, 0)) != null) {
            logger.error("core 0.00 C must be rejected by the clamp -- 0.0 is the dropout marker");
            ok = false;
        }
        if (CoreTempSensor.decodeSkinC($.ctPayload(0, 0x0C8, 3742)) != null) {
            logger.error("skin 0.00 C must be rejected by the clamp -- 0.0 is the dropout marker");
            ok = false;
        }
        if ($.CT_CORE_MIN_C <= 0.0 || $.CT_SKIN_MIN_C <= 0.0) {
            logger.error("both accepted bands must start above 0.0 C");
            ok = false;
        }
        return ok;
    }

    // THE INVARIANT THE RETRY PATH'S RECURSION BOUND RESTS ON.
    //
    // openChannel()'s catch calls scheduleReopen(), and scheduleReopen() calls
    // openChannel() straight back when the ladder asks for no delay. That cycle
    // terminates ONLY because mFails rises on every pass and ctBackoffMs stops
    // returning 0 once the burst is spent -- an arithmetic bound, not a
    // structural one. Pinned here so an edit that let the backoff return 0
    // again (a "always retry immediately" tidy-up, or a burst count raised
    // without thought) reds a test that names the consequence, instead of
    // producing an unbounded recursion nothing measures.
    (:test) function test_c0_backoffIsPositiveOncePastTheBurst(logger) {
        var ok = true;
        if (CoreTempSensor.ctBackoffMs($.CT_BURST_TRIES - 1) != 0) {
            logger.error("inside the burst the ladder must still reopen immediately");
            ok = false;
        }
        for (var f = $.CT_BURST_TRIES; f <= $.CT_BURST_TRIES + 8; f++) {
            if (CoreTempSensor.ctBackoffMs(f) <= 0) {
                logger.error("ctBackoffMs(" + f + ") = " + CoreTempSensor.ctBackoffMs(f) +
                             "; a zero here makes openChannel <-> scheduleReopen recurse without bound");
                ok = false;
            }
        }
        return ok;
    }
}
