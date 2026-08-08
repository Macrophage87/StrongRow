using Toybox.Test;
using Toybox.Graphics as Gfx;
using Toybox.System;
using Toybox.Lang;

// Suite for the DISPLAY CUE: the stroke-rate colour treated as an instruction
// ("row harder" / "hold" / "ease off") rather than as a rendering of the
// measurement.
//
// THE SPLIT THIS FILE EXISTS TO GUARD, in the maintainer's words:
//
//   "The in row measurement is designed to just tell me whether I should
//    increase or decrease my rate. Have it keep the actual measurement in the
//    file though."
//
// So one number does two jobs and they get different treatment:
//
//   ON THE WATER   the COLOUR is a controller cue. Lag and hysteresis are free
//                  here, because a late instruction is cheaper than a wrong one.
//   IN THE FIT     row_stroke_rate, dist_per_stroke and corrective_rate stay the
//                  UNMODIFIED estimator output. If a recorded value moves, the
//                  change is wrong.
//
// The displayed NUMBER stays raw too -- only the colour is filtered. That is a
// measured result and not a preference; the negative result that rules out
// filtering the number is recorded at the CUE_* constants in StrongRowView.mc.
//
// -- WHY THE CASES BELOW ARE SO FEW, AND SO SECTIONED ------------------------
// MEASURED, and it is a hard ceiling rather than a style choice. The fenix6
// family caps a module at 253 members, and the --unit-test build of main at
// 920d4e1 already sits at 246 members of `globals`:
//
//     monkeyc -d fenix6 --unit-test, main + 14 (:test) functions
//       -> ERROR: fenix6: Found 260 members in module 'globals',
//          exceeding the limit of 253.
//
// So 246, and SEVEN free for this whole change. What counts is a module-scope
// FUNCTION or CLASS, one member each. A module-scope `const` is inlined and
// costs nothing (measured: 14 unreferenced consts compiled clean, 14 (:test)
// functions did not). A `module` block costs ONE member and takes everything
// inside it out of `globals` (measured: 14 tests + 2 classes + 2 functions
// inside one module compiled clean).
//
// Hence the shape of this file: every helper, fixture and probe lives inside
// the single `CueFix` module -- one member -- and there are SIX (:test)
// functions, each carrying several sections with its own error message per
// section. The first CI run of this branch is the evidence for all of the
// above; it red compile-unit-test on fenix6/6pro/6spro/6xpro at 270 members
// while fr965 compiled clean locally, which is exactly the class of defect a
// local run cannot see.
//
// A (:test) function inside a `module` is RUN, but the simulator reports it as
// `Module.name` while scripts/list_tests.py extracts the bare name -- so
// pinning module-scoped tests would deadlock check_expected_tests.sh against
// check_ciq_tests.py. Making the extractor module-aware would lift the ceiling
// for the whole repository; it is a tooling change with its own differentials to
// prove, so it is FILED rather than folded in here.
//
// -- WHAT THIS FILE CAN SEE --------------------------------------------------
// CueFix.Dc records every drawText the shipping draw path issues together with
// the FOREGROUND COLOUR IN EFFECT AT THAT CALL. So a case here can say which
// string was drawn in which colour. It cannot say anything about how that looks
// on a wrist, and no case here claims to: #121 measured the CI container
// segfaulting the moment a test obtains a real graphics Dc, so no font metric
// and no rendered pixel is available to any (:test) in this repository.
//
// It records what the code CALLS. It says nothing about what a panel shows.
//
// -- COMMIT PARTITION --------------------------------------------------------
//   c0   characterization pins on existing symbols only, no source change
//   c1   the cue seam, wired behaviour-preservingly
//   c1b  this consolidation, to fit the ceiling measured above
//   c2   the differentials -- RED against c1b, by design
//   c3   the fix; touches no test file, no pin, no scripts/, no .github/
//
// Execution note: the run-tests CI job runs these headlessly in the simulator on
// fr965. Test names are pinned in scripts/expected_tests.txt -- update that file
// in the SAME commit as any (:test) change here. See docs/CI.md.

// -- Fixture ------------------------------------------------------------------
// One module, one member of `globals`. See the ceiling note above.
module CueFix {

    // The shipped default band (resources/settings/properties.xml: targetLo 16 /
    // targetHi 18), named so no case can disagree with its own band by typo.
    // Same convention as RateColourTest.mc's RC_LO / RC_HI.
    const LO = 16;
    const HI = 18;

    // A COLOUR-RECORDING Dc.
    //
    // Duck-typed: onUpdate's `dc` is used only through method calls and the
    // members it reaches are untyped, so at runtime only duck typing applies and
    // this needs exactly the surface the shipping draw path uses -- measured
    // with a grep for `dc.`, not guessed: clear, setColor, setPenWidth,
    // getWidth, getHeight, getFontHeight, drawText, drawArc, drawLine.
    //
    // The one thing it adds over HrDc (HrArcTest.mc) is the COLOUR. HrDc's
    // setColor is a no-op, which is right for a suite about geometry and wrong
    // for a suite about a cue, since the cue's entire output IS the colour.
    class Dc {
        var w; var h;
        var fg;         // the foreground colour the last setColor established
        var strings;    // every drawText string, in call order
        var colours;    // the fg in effect at each of those calls
        var fonts;      // the font each was drawn in

        function initialize(width, height) {
            w = width; h = height;
            fg = null;
            strings = []; colours = []; fonts = [];
        }

        function getWidth()  { return w; }
        function getHeight() { return h; }
        // Never consulted by any assertion here: only drawSetGrid calls it, and
        // no case in this file renders the #109 grid. Present so a future case
        // that does reach it fails on its assertion rather than on a missing
        // method.
        function getFontHeight(f) { return h / 10; }

        function setColor(f, b) { fg = f; }
        function setPenWidth(p) { }
        function clear()        { }
        function drawArc(x, y, r, attr, degStart, degEnd) { }
        function drawLine(x1, y1, x2, y2) { }

        function drawText(x, y, font, s, just) {
            strings.add(s);
            colours.add(fg);
            fonts.add(font);
        }
    }

    // A FitContributor field stand-in. Records every value written, in order, so
    // a case can assert on WHAT WAS HANDED TO setData.
    //
    // SCOPE, stated because this is precisely the claim this repository keeps
    // overreaching on: this observes the ARGUMENT of an in-app call. It says
    // nothing about what lands in the file's bytes and nothing about what a
    // decoder renders. Those need a simulator session and a decode.
    class Field {
        var vals;
        function initialize() { vals = []; }
        function setData(v) { vals.add(v); }
        function last() { return (vals.size() == 0) ? null : vals[vals.size() - 1]; }
    }

    // Extends HrProbe (HrArcTest.mc) rather than re-deriving from
    // StrongRowView: the seams this suite needs -- the injected nowMs() clock,
    // enterStepLive, runUpdate's Dc cast, the neutralised sensor and GPS starts,
    // the deterministic currentSpeed/elapsedDist, the step-kind accessors --
    // already exist there and are already exercised by two suites. Duplicating
    // them would be a second copy free to drift.
    class Probe extends HrProbe {
        function initialize() { HrProbe.initialize(); }

        // Put the ESTIMATOR at a chosen rate.
        //
        // Writes the detector's median (mRate) and clears the autocorrelation
        // lock, which is the state registerStroke/recomputeRate leave behind for
        // a steady cadence below FAST_NEEDS_LOCK. It does NOT bypass
        // outputRate(): every assertion reads the value through the shipping
        // outputRate(), which for mAcPeriod == 0.0 and 0 < mRate <= 30 returns
        // mRate unchanged. Rates used here are 14.0-25.0, well inside that.
        //
        // Direct rather than driveStrokes() because these cases need the rate to
        // CHANGE at a chosen instant -- a spike, a dip, a return -- and a median
        // of the last five stroke periods cannot be steered to an exact value on
        // a chosen frame.
        function setRate(spm) {
            mRate = spm;
            mAcPeriod = 0.0;
        }

        // The estimator's output, read through the shipping method.
        function rawRate() { return outputRate(); }

        // Hand the view a recording stand-in for the row_stroke_rate field.
        function installFitRate(f) { mFitRate = f; }

        // The real 250 ms tick, called directly.
        function runTick() { onTick(); }
    }

    // The big stroke-rate numeral, located BY ITS FONT rather than by its
    // position or its content.
    //
    // By font because that is the only identifier stable across everything these
    // cases vary. The string changes with the rate (and is "--.-" in the no-data
    // state, which is one of the states under test), and the y fraction is a
    // layout decision this file does not own. drawRate is the ONLY call site
    // using FONT_NUMBER_THAI_HOT / FONT_NUMBER_HOT -- the countdown beside it
    // uses FONT_NUMBER_MILD, a different constant -- so the font selects it
    // exactly.
    function numeralIdx(d) {
        for (var i = 0; i < d.fonts.size(); i++) {
            var f = d.fonts[i];
            if (f == Gfx.FONT_NUMBER_THAI_HOT || f == Gfx.FONT_NUMBER_HOT) {
                return i;
            }
        }
        return -1;
    }

    function numeralColour(d) {
        var i = numeralIdx(d);
        return (i < 0) ? null : d.colours[i];
    }

    function numeralText(d) {
        var i = numeralIdx(d);
        return (i < 0) ? null : d.strings[i];
    }

    // Render at a stated instant on the probe's injected clock.
    //
    // NEVER System.getTimer(). That counts from DEVICE start, so a case that
    // synthesised its stamps from it would depend on how long the simulator had
    // been up -- and CI's simulator is seconds old while a desktop one is hours
    // old. This repository has already been bitten by that asymmetry (the note
    // at StrongRowView.nowMs); every stamp in this file is an absolute number
    // chosen by the case.
    //
    // Device dimensions come from the simulator the suite is actually running
    // on, exactly as WorkLayoutTest.wlRender does, so drawRate's `w >= 300` font
    // choice is the real one for that device rather than a number picked here.
    function renderAt(p, tMs) {
        p.setNowMs(tMs);
        var ds = System.getDeviceSettings();
        var d = new Dc(ds.screenWidth, ds.screenHeight);
        p.runUpdate(d);
        return d;
    }

    // A probe already in a live, unpaused WORK step with the default band.
    // enterStepLive (not enterStep) leaves the step clock running, so
    // stepRemaining() is the full interval and onTick's advanceStep() is not
    // triggered -- these cases must not advance the workout underneath
    // themselves.
    function workProbe() {
        var p = new Probe();
        p.enterStepLive(p.kindWork(), false);
        p.setSpeed(0.0);
        p.setDist(0.0);
        return p;
    }
}

// -- c0: characterization pins ------------------------------------------------
// Green before the cue layer exists and green after it.

// THE MEASUREMENT SURVIVES THE CUE. Three sections, all about the two things the
// maintainer's instruction protects: the file and the number.
//
// Constructed so that it is a real differential once the cue exists: the screen
// is first put in band at 17.0, then the rate jumps to 25.0 and ONE frame is
// drawn 250 ms later. After the change that frame is still showing the in-band
// colour (the jump has not persisted long enough to be believed), so cue and
// measurement genuinely disagree at the moment onTick runs -- and both the field
// and the numeral must still carry 25.0.
//
// Before the change the two agree trivially and this is a plain characterization
// pin. That is the point of writing it at c0: it is green in both epochs and its
// meaning strengthens rather than changes.
(:test) function test_cue_c0_theMeasurementSurvivesTheCue(logger) {
    var p = CueFix.workProbe();
    var f = new CueFix.Field();
    p.installFitRate(f);

    p.setRate(17.0);
    CueFix.renderAt(p, 0);
    p.setRate(25.0);
    var d = CueFix.renderAt(p, 250);

    // (a) the FIT write is the raw estimator, never the cue.
    p.runTick();
    var got = f.last();
    var want = p.rawRate();
    if (got == null) {
        logger.error("(a) onTick wrote nothing to row_stroke_rate at all");
        return false;
    }
    if (got != want || got != 25.0) {
        logger.error("(a) row_stroke_rate must carry the UNMODIFIED estimator: " +
                     "outputRate() is " + want + ", the estimator was put at " +
                     "25.0, and setData got " + got);
        return false;
    }

    // (b) the displayed NUMBER is the measurement too. Only the colour is a cue.
    var s = CueFix.numeralText(d);
    if (s == null || !s.equals("25.0")) {
        logger.error("(b) the numeral must show the raw estimator ('25.0'); " +
                     "got '" + s + "' -- the displayed NUMBER has been " +
                     "filtered, which is the one thing the measured result " +
                     "rules out");
        return false;
    }

    // (c) the no-data state survives. outputRate() returns 0.0 when nothing has
    // been measured, drawRate renders that as "--.-", and a dash must never be
    // given an instruction colour -- the #86 / #107 defect class (a sentinel
    // rendered as a reading), which a cue layer holding a previous zone is a
    // fresh way to reintroduce.
    p.setRate(0.0);
    var d2 = CueFix.renderAt(p, 500);
    var s2 = CueFix.numeralText(d2);
    var c2 = CueFix.numeralColour(d2);
    if (s2 == null || !s2.equals("--.-")) {
        logger.error("(c) a zero estimator is the no-data state and must " +
                     "render '--.-'; got '" + s2 + "'");
        return false;
    }
    if (c2 != Gfx.COLOR_WHITE) {
        logger.error("(c) '--.-' must be white (COLOR_WHITE = " +
                     Gfx.COLOR_WHITE + "), never carrying a colour from the " +
                     "last real reading; got " + c2);
        return false;
    }
    return true;
}

// THE STATES THAT MUST NOT MOVE. Lag is free; suppression and invention are not.
(:test) function test_cue_c0_theSteadyAndTheWhiteStatesAreUnchanged(logger) {
    // (a) steady in band -- what the athlete looks at for most of an interval.
    var pin = CueFix.workProbe();
    pin.setRate(17.0);
    CueFix.renderAt(pin, 0);
    CueFix.renderAt(pin, 250);
    var cin = CueFix.numeralColour(CueFix.renderAt(pin, 20000));
    if (cin != Gfx.COLOR_GREEN) {
        logger.error("(a) 17.0 spm held inside a 16-18 band must read green " +
                     "(COLOR_GREEN = " + Gfx.COLOR_GREEN + "); got " + cin);
        return false;
    }

    // (b) a SUSTAINED overshoot still says so. Three frames, not an 80-frame
    // sweep: what matters is the frame that starts a pending change and one far
    // past any window it could be waiting on.
    var pov = CueFix.workProbe();
    pov.setRate(25.0);
    CueFix.renderAt(pov, 0);
    CueFix.renderAt(pov, 250);
    var cov = CueFix.numeralColour(CueFix.renderAt(pov, 20000));
    if (cov != Gfx.COLOR_RED) {
        logger.error("(b) 25.0 spm held for 20 s against a 16-18 band must " +
                     "read red (COLOR_RED = " + Gfx.COLOR_RED + "); got " + cov);
        return false;
    }

    // (c) a REST step has no target, so it has no instruction.
    var pr = new CueFix.Probe();
    pr.enterStepLive(pr.kindRest(), false);
    pr.setSpeed(0.0); pr.setDist(0.0);
    pr.setRate(25.0);
    var crest = CueFix.numeralColour(CueFix.renderAt(pr, 0));
    if (crest != Gfx.COLOR_WHITE) {
        logger.error("(c) a REST step draws the numeral white whatever the " +
                     "rate (COLOR_WHITE = " + Gfx.COLOR_WHITE + "); got " +
                     crest);
        return false;
    }

    // (d) free row has no band at all.
    var pf = new CueFix.Probe();
    pf.setFreeRow();
    pf.setSpeed(0.0); pf.setDist(0.0);
    pf.setRate(25.0);
    var cfree = CueFix.numeralColour(CueFix.renderAt(pf, 0));
    if (cfree != Gfx.COLOR_WHITE) {
        logger.error("(d) free row draws the numeral white (COLOR_WHITE = " +
                     Gfx.COLOR_WHITE + "); got " + cfree);
        return false;
    }

    // (e) rateColour STAYS MEMORYLESS. The cue is a NEW layer in front of it,
    // never an edit to it -- and this is what stops the next reader from
    // "simplifying" the two back together. A module-scope var would let a static
    // carry state between calls, so this is a reachable regression rather than a
    // theoretical one, and it would break every RateColourTest case's premise at
    // once.
    var a = StrongRowView.rateColour(true, 25.0, CueFix.LO, CueFix.HI);
    for (var i = 0; i < 10; i++) {
        StrongRowView.rateColour(true, 17.0, CueFix.LO, CueFix.HI);
    }
    var b = StrongRowView.rateColour(true, 25.0, CueFix.LO, CueFix.HI);
    if (a != b) {
        logger.error("(e) rateColour answered " + a + " then " + b + " for the " +
                     "same input -- it has acquired state, and every case in " +
                     "RateColourTest.mc silently depends on it not having any");
        return false;
    }
    return true;
}

// -- c1: the new symbols, pinned where they are epoch-invariant ---------------
//
// c1 introduces cueBandZone / cueTarget / cueStep / cueColour and wires them at
// the call site in place of the direct rateColour call. That wiring is
// BEHAVIOUR-PRESERVING by construction -- cueStep adopts every zone at once and
// cueColour reproduces rateColour's mapping exactly -- so nothing on screen
// moves and the c0 cases above stay green.
//
// This case is green at c1 and stays green once the hysteresis lands at c3. It
// pins the parts that do not move: the vocabulary, the band boundaries, the
// no-data state, the transitions adopted without delay in every epoch, and the
// call site's decision to park the machine off the work step.

(:test) function test_cue_theSeamAgreesWithRateColourAndStartsClean(logger) {
    // (a) four states, four codes. Two states that cannot be told apart is one
    // state.
    var z = [$.CUEZ_NONE, $.CUEZ_BELOW, $.CUEZ_IN, $.CUEZ_ABOVE];
    for (var i = 0; i < z.size(); i++) {
        for (var j = i + 1; j < z.size(); j++) {
            if (z[i] == z[j]) {
                logger.error("(a) cue zone codes " + i + " and " + j +
                             " are both " + z[i]);
                return false;
            }
        }
    }

    // (b) THE VOCABULARY PIN. cueColour must agree with rateColour on the
    // memoryless mapping for every rate and both work states. This is what makes
    // "the cue is a layer in front of rateColour" true rather than aspirational:
    // if a future edit re-tunes one palette, this reds until the other follows.
    // It also covers "white off the work step" for every zone.
    var rates = [0.0, 10.0, 15.9, 16.0, 17.0, 18.0, 18.1, 25.0, 40.0];
    var works = [true, false];
    for (var w = 0; w < works.size(); w++) {
        for (var i = 0; i < rates.size(); i++) {
            var r = rates[i];
            var viaZone = StrongRowView.cueColour(
                works[w], StrongRowView.cueBandZone(r, CueFix.LO, CueFix.HI));
            var direct = StrongRowView.rateColour(works[w], r,
                                                  CueFix.LO, CueFix.HI);
            if (viaZone != direct) {
                logger.error("(b) the cue and the numeral have forked at rate " +
                             r + " (isWork " + works[w] + "): cueColour said " +
                             viaZone + ", rateColour said " + direct);
                return false;
            }
        }
    }

    // (c) the band edges belong to the band and the outside starts immediately
    // beyond them. Stated at the zone level because the deadband arriving at c3
    // moves the EXIT threshold and must leave this alone.
    var cases = [[16.0, $.CUEZ_IN], [18.0, $.CUEZ_IN],
                 [15.9, $.CUEZ_BELOW], [18.1, $.CUEZ_ABOVE],
                 [0.0, $.CUEZ_NONE]];
    for (var i = 0; i < cases.size(); i++) {
        var got = StrongRowView.cueBandZone(cases[i][0], CueFix.LO, CueFix.HI);
        if (got != cases[i][1]) {
            logger.error("(c) cueBandZone(" + cases[i][0] + ", 16, 18) is " +
                         got + ", expected " + cases[i][1] +
                         " -- the memoryless band comparison has moved");
            return false;
        }
    }

    // (d) a step that asks for the zone already showing changes nothing and
    // leaves no pending candidate behind. This is what makes "a candidate must
    // be CONTINUOUS" checkable: one frame back at the current zone clears
    // whatever was pending.
    var same = StrongRowView.cueStep(17.0, CueFix.LO, CueFix.HI,
                                     $.CUEZ_IN, $.CUEZ_ABOVE, 1000, 2000);
    if (same.size() != 3) {
        logger.error("(d) cueStep must return [zone, candidate, since]; got " +
                     same.size() + " element(s)");
        return false;
    }
    if (same[0] != $.CUEZ_IN || same[1] != $.CUEZ_IN) {
        logger.error("(d) an in-band rate against an in-band display must stay " +
                     "IN and discard the pending ABOVE; got zone " + same[0] +
                     ", candidate " + same[1] + ". A candidate that survives a " +
                     "frame of disagreement is not a persistence test, it is a " +
                     "total");
        return false;
    }

    // (e) NO DATA IS ADOPTED AT ONCE, both ways. Into CUEZ_NONE because the
    // numeral becomes "--.-" on the same frame and a colour outliving the number
    // it described is a claim with nothing behind it; out of CUEZ_NONE because
    // there is no displayed instruction to protect.
    var gone = StrongRowView.cueStep(0.0, CueFix.LO, CueFix.HI,
                                     $.CUEZ_IN, $.CUEZ_IN, 5000, 5000);
    if (gone[0] != $.CUEZ_NONE) {
        logger.error("(e) a zero estimator must drop the cue to CUEZ_NONE on " +
                     "the same frame the numeral becomes '--.-'; got " + gone[0]);
        return false;
    }
    var first = StrongRowView.cueStep(25.0, CueFix.LO, CueFix.HI,
                                      $.CUEZ_NONE, $.CUEZ_NONE, 5000, 5000);
    if (first[0] != $.CUEZ_ABOVE) {
        logger.error("(e) the first reading after no-data must be adopted at " +
                     "once (nothing is displayed to protect); got " + first[0]);
        return false;
    }

    // (f) THE STEP BOUNDARY, driven end to end through the shipping draw path
    // because what is being pinned is the CALL SITE's decision to park the
    // machine off the work step -- cueStep cannot see a step type. A work
    // interval starts with no cue in front of it, so its first frame shows the
    // true zone at once. Deleting that branch reds this section and no other.
    var p = new CueFix.Probe();
    p.setSpeed(0.0); p.setDist(0.0);
    p.enterStepLive(p.kindWork(), false);
    p.setRate(17.0);
    CueFix.renderAt(p, 0);
    CueFix.renderAt(p, 250);
    // A rest long enough for any persistence window to expire, rowed at the same
    // in-band cadence, so the only thing that could carry across is the zone.
    p.enterStepLive(p.kindRest(), false);
    CueFix.renderAt(p, 1000);
    CueFix.renderAt(p, 11000);
    // Back to work, already over the band.
    p.enterStepLive(p.kindWork(), false);
    p.setRate(25.0);
    var cb = CueFix.numeralColour(CueFix.renderAt(p, 11250));
    if (cb != Gfx.COLOR_RED) {
        logger.error("(f) the first work frame after a rest must show the true " +
                     "zone at once -- 25.0 against a 16-18 band is red " +
                     "(COLOR_RED = " + Gfx.COLOR_RED + "); got " + cb +
                     ". A cue carried across the step boundary is a stale " +
                     "instruction from a different activity");
        return false;
    }
    return true;
}
