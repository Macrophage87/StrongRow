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
// WHAT THIS FILE OBSERVES OF THAT CONSTRAINT, stated because the sentence above
// names THREE writes and the pins reach ONE.
// test_cue_c0_theMeasurementSurvivesTheCue installs a recording Field on
// mFitRate ALONE (CueFix.Probe exposes only installFitRate), so row_stroke_rate
// is pinned and dist_per_stroke and corrective_rate are NOT. Their safety here
// is STRUCTURAL and reviewable rather than pinned: mCueZone / mCueCand /
// mCueSince are written only from onUpdate, and the onTick path that issues all
// three writes never reads them (see the display-cue state block in
// StrongRowView.mc), and the whole StrongRowView diff for this change removes
// one line and touches none of outputRate / recomputeRate / registerStroke /
// distPerStroke / correctiveRate.
//
// MEASURED, so that this is a statement rather than a hedge: halving
// distPerStroke's return leaves all 236 cases green. A dist_per_stroke pin IS
// available in process (speed 3.0 m/s at 25.0 spm writes 7.2) and is worth its
// own RED step rather than being smuggled in green here -- filed, not done.
// corrective_rate is NOT pinnable in process at all: Activity.getActivityInfo()
// carries no currentCadence under (:test), so nativeCadence() is 0.0 and
// correctiveRate() clamps to 0.0 whatever outputRate() returns. An assertion on
// it would be green for the wrong reason, which is the fourth trap in this
// file's own list.
//
// The displayed NUMBER stays raw too -- only the colour is filtered. That is a
// measured result and not a preference; the negative result that rules out
// filtering the number is recorded at the CUE_* constants in StrongRowView.mc.
//
// -- WHY EVERYTHING LIVES IN ONE MODULE, AND WHY THE CASES ARE SO SECTIONED ---
// MEASURED, and it is a hard ceiling rather than a style choice. The fenix6
// family caps a module at 253 members, and the --unit-test build of main at
// 920d4e1 already sat at 246 members of `globals`:
//
//     monkeyc -d fenix6 --unit-test, main + 14 (:test) functions
//       -> ERROR: fenix6: Found 260 members in module 'globals',
//          exceeding the limit of 253.
//
// So 246, and SEVEN free. What counts is a module-scope FUNCTION or CLASS, one
// member each. A module-scope `const` is inlined and costs nothing (measured:
// 14 unreferenced consts compiled clean, 14 (:test) functions did not). A
// `module` block costs ONE member and takes everything inside it out of
// `globals` (measured: 14 tests + 2 classes + 2 functions inside one module
// compiled clean).
//
// The first CI run of this branch is the evidence: it red compile-unit-test on
// fenix6/6pro/6spro/6xpro at 270 members while fr965 compiled clean locally --
// exactly the class of defect a local run cannot see.
//
// So EVERYTHING in this file, fixtures and (:test) functions alike, is inside
// `module CueFix`: one member for the lot. The simulator prints a module-scoped
// test as `CueFix.test_...` and scripts/list_tests.py extracts that qualified
// name (3460b27, which landed on main independently while this branch was in
// flight and measured the same 246/253 ceiling), so the pin carries the
// qualified names.
//
// RETRACTION, kept rather than edited away because the claim was load-bearing
// for a whole commit: an earlier revision of this header said pinning
// module-scoped tests "would deadlock check_expected_tests.sh against
// check_ciq_tests.py" and that making the extractor module-aware was filed
// rather than done. That was TRUE against 920d4e1 and is FALSE against the
// merged main. The commit that consolidated fifteen (:test) functions into six
// (c1b) was forced by the ceiling as it stood when it was written.
//
// The six are KEPT rather than split back apart, and the reason is evidence, not
// inertia: each was shown RED at c2 before the fix landed (CI run 31255063213).
// Splitting one into three would create three names that were never shown
// failing. That split is worth doing and needs its own red step, so it is filed
// rather than done here. Each case therefore carries several sections, each with
// its own error message, so a failure still names what broke.
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
//   c1b  the consolidation, to fit the ceiling measured above
//   c2   the differentials -- RED against c1b, by design
//   c3   the fix; touches no test file, no pin, no scripts/, no .github/
//   c4   merge main, and move the (:test) functions inside the module
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
        // #80's heat-strain mark, added when main's status row grew it. Not
        // recorded -- no case here asserts about it -- but a duck-typed Dc that
        // is MISSING a method the shipping path calls fails as a runtime ERROR
        // rather than a readable assertion, and the two REST/free-row cases
        // below did exactly that when main merged in. Present so this fixture
        // keeps failing on its assertions.
        function drawCircle(x, y, r) { }
        function fillCircle(x, y, r) { }

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

// -- c0: characterization pins ------------------------------------------------
// Green before the cue layer exists and green after it.
//
// THE (:test) FUNCTIONS FROM HERE TO THE END OF THE FILE ARE INSIDE `module
// CueFix` TOO, and the helpers above are still referenced through the module
// name so that a case reads the same whether or not it is ever moved back out.
// The module is what makes the suite affordable at all: see the ceiling note at
// the top of this file. Every name below is therefore pinned as
// `CueFix.test_...`, which is what the simulator prints.

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

    // (b) a SUSTAINED overshoot still says so, FROM A CLEAN START.
    //
    // CORRECTION, kept rather than edited away because this section was
    // credited with coverage it has never had. An earlier revision said "what
    // matters is the frame that starts a pending change and one far past any
    // window it could be waiting on". NO FRAME HERE STARTS A PENDING CHANGE:
    // workProbe leaves mCueZone at CUEZ_NONE, so the very first renderAt is
    // taken by cueStep's no-data fast path and adopts CUEZ_ABOVE at t = 0, and
    // the 20000 ms frame merely re-asserts a zone adopted twenty seconds
    // earlier. Deleting the fast path reds this case; deleting the call site's
    // `mCueCand = cue[1];` did NOT, which is how the overclaim was found.
    //
    // What it pins is real and worth keeping: a rate over the band from the
    // first frame of a work step must read red and stay red. ADOPTION UNDER
    // PERSISTENCE -- an IN display that has to become ABOVE -- is a different
    // path and is pinned by section (c) of
    // test_cue_theScreenLagsTheColourNotTheNumber.
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

// -- c2: the differentials ----------------------------------------------------
//
// ALL THREE CASES BELOW ARE RED AGAINST c1b AND GREEN ONLY AT c3. That is the
// whole job of this commit: the hysteresis is not implemented yet, so each fails
// first and is then made to pass by a commit that touches no test file.
//
// THE RULE THEY PIN, stated once:
//
//   * while the cue zone is IN, LEAVING it requires rate > hi + DEADBAND or
//     rate < lo - DEADBAND;
//   * from any other zone the plain band comparison applies -- returning to
//     "you're fine" is cheap;
//   * a change to an OUT-OF-BAND instruction must persist PERSIST_OUT; a change
//     back INTO the band needs only PERSIST_IN;
//   * DEADBAND = 1.0 spm, PERSIST_OUT = 4 s, PERSIST_IN = 1 s.
//
// WHY THE DIRECTIONS ARE NOT SYMMETRIC. The damaging error is FALSE-HIGH:
// telling the athlete to ease off while they are actually in the band. In the
// choppy recording five of the eight work-lap medians (16.5, 15.0, 14.2, 15.2,
// 13.2, 14.3, 16.1, 16.0) sit below a 16-18 target. So asserting an out-of-band
// correction is the expensive claim and pays the long window; withdrawing one is
// cheap.
//
// RETRACTION: an earlier revision of this paragraph quoted "16.5 -> 15.0 ->
// 14.2 -> 13.2" as a progressive drift. That is four of the eight laps with the
// middle and the tail dropped; the real series is not monotone and recovers into
// band over the last two intervals. Corrected at its source in the CUE_* block
// of StrongRowView.mc, which also records what replaying the SHIPPED rule does
// and does not deliver.
//
// AND WHY THE NUMBER IS NOT FILTERED, which is the trap a later "improvement"
// would walk into: pre-smoothing the displayed rate and taking the zone from the
// smoothed value makes the choppy row WORSE, re-measured on the shipped rule
// with causal filters -- 6.9% false-high unfiltered against 9.7% (median-5) and
// 13.2% (median-9), with Hampel unable to move it at all. Filter the zone, not
// the number. Regenerate with `python3 scripts/cue_replay.py`.
//
// TIME IS INJECTED, NEVER SYNTHESISED. Every stamp below is an absolute number
// the case chose. A stamp derived from System.getTimer() would depend on device
// uptime, and CI's simulator is seconds old while a desktop one is hours old.

// THE DEADBAND. Two sections for what it suppresses and one for where it must
// NOT apply.
(:test) function test_cue_theDeadbandIsPaidOnExitOnly(logger) {
    // (a) and (b): a rate that leaves the band by less than 1.0 spm does not
    // change the instruction AT ALL -- not after four seconds, not after ten.
    // Driven as a real frame sequence at the 250 ms tick, feeding each step's
    // output back in, so an implementation that merely delayed the change would
    // still red here.
    //
    // WHAT THESE TWO CANNOT SEE, stated so the next reader does not credit them
    // with it: while the rate sits inside the deadband cueStep returns
    // [cur, cur, now], so the fed-back candidate is pinned EQUAL to the
    // displayed zone and `cur != cand` never arises in this loop. They pin that
    // a deadband exists and that it is not merely a delay; they cannot tell
    // cueTarget(rate, lo, hi, cur) from cueTarget(rate, lo, hi, cand). Section
    // (c) below is what does that.
    var probes = [[18.5, "(a) above"], [15.5, "(b) below"]];
    for (var i = 0; i < probes.size(); i++) {
        var rate = probes[i][0];
        var zone = $.CUEZ_IN;
        var cand = $.CUEZ_IN;
        var since = 0;
        for (var t = 0; t <= 10000; t += 250) {
            var out = StrongRowView.cueStep(rate, CueFix.LO, CueFix.HI,
                                            zone, cand, since, t);
            zone = out[0]; cand = out[1]; since = out[2];
        }
        if (zone != $.CUEZ_IN) {
            logger.error(probes[i][1] + ": a rate of " + rate + " leaves the " +
                         "16-18 band by less than the 1.0 spm deadband, so the " +
                         "cue must not change -- held for 10 s and the zone " +
                         "became " + zone);
            return false;
        }
    }

    // (c) THE DEADBAND KEYS ON THE DISPLAYED ZONE, NOT ON THE PENDING ONE.
    //
    // This is the load-bearing sentence of the whole design -- "while the cue
    // zone is IN, leaving it requires rate > hi + DEADBAND" is about the zone ON
    // SCREEN -- and until this section existed nothing pinned it: changing
    // cueStep's first line to cueTarget(rate, lo, hi, cand) left all 236 cases
    // green (measured, not argued).
    //
    // Reached by spiking ONCE past hi + DEADBAND, which forms a pending ABOVE
    // while IN is still displayed, then settling 0.5 spm over the band -- the
    // recorded choppy-water pattern, and an ordinary frame sequence at the call
    // site, which feeds mCueZone/mCueCand/mCueSince straight back in every
    // frame. Under the mutant the widened band would belong to the pending
    // ABOVE, 18.5 would be plainly over 18, and the cue would turn red after
    // four seconds: a FALSE-HIGH, the exact error direction this feature was
    // measured and chosen to remove.
    var spike = StrongRowView.cueStep(20.0, CueFix.LO, CueFix.HI,
                                      $.CUEZ_IN, $.CUEZ_IN, 0, 0);
    if (spike[0] != $.CUEZ_IN || spike[1] != $.CUEZ_ABOVE) {
        logger.error("(c) setup: one frame at 20.0 must leave IN displayed " +
                     "with ABOVE pending; got zone " + spike[0] +
                     ", candidate " + spike[1]);
        return false;
    }
    var hz = spike[0]; var hc = spike[1]; var hs = spike[2];
    for (var t = 250; t <= 10000; t += 250) {
        var ho = StrongRowView.cueStep(18.5, CueFix.LO, CueFix.HI,
                                       hz, hc, hs, t);
        hz = ho[0]; hc = ho[1]; hs = ho[2];
    }
    if (hz != $.CUEZ_IN) {
        logger.error("(c) the widened band belongs to the zone ON SCREEN, not " +
                     "to the candidate asking to replace it: 18.5 is inside " +
                     "the 1.0 spm deadband around a displayed IN, so a single " +
                     "20.0 frame must not license it. Zone became " + hz +
                     " -- this is the false-high the feature exists to remove");
        return false;
    }
    // The mirror, so the below-band side is stated rather than inferred.
    var dip = StrongRowView.cueStep(14.0, CueFix.LO, CueFix.HI,
                                    $.CUEZ_IN, $.CUEZ_IN, 0, 0);
    if (dip[0] != $.CUEZ_IN || dip[1] != $.CUEZ_BELOW) {
        logger.error("(c) setup: one frame at 14.0 must leave IN displayed " +
                     "with BELOW pending; got zone " + dip[0] +
                     ", candidate " + dip[1]);
        return false;
    }
    var dz = dip[0]; var dc = dip[1]; var ds = dip[2];
    for (var u = 250; u <= 10000; u += 250) {
        var dout = StrongRowView.cueStep(15.5, CueFix.LO, CueFix.HI,
                                         dz, dc, ds, u);
        dz = dout[0]; dc = dout[1]; ds = dout[2];
    }
    if (dz != $.CUEZ_IN) {
        logger.error("(c) below-band mirror: 15.5 is inside the deadband " +
                     "around a displayed IN, so a single 14.0 frame must not " +
                     "license 'row harder'; zone became " + dz);
        return false;
    }

    // (d) THE DEADBAND IS ASYMMETRIC BETWEEN EXIT AND ENTRY. Re-entry pays NO
    // deadband: the rate has only to reach the band edge, not to clear it by
    // 1.0 spm. A deadband applied here would make the band effectively 17-17 to
    // get back into, and an athlete who corrected exactly onto the edge would be
    // told to keep correcting.
    var early = StrongRowView.cueStep(16.0, CueFix.LO, CueFix.HI,
                                      $.CUEZ_BELOW, $.CUEZ_IN, 0, 999);
    if (early[0] != $.CUEZ_BELOW) {
        logger.error("(d) re-entry still owes its 1 s at 999 ms; zone is " +
                     early[0] + ", expected " + $.CUEZ_BELOW);
        return false;
    }
    var late = StrongRowView.cueStep(16.0, CueFix.LO, CueFix.HI,
                                     $.CUEZ_BELOW, $.CUEZ_IN, 0, 1000);
    if (late[0] != $.CUEZ_IN) {
        logger.error("(d) 16.0 IS the band's lower edge, and coming back from " +
                     "below costs no deadband -- reaching the edge is enough. " +
                     "Zone is " + late[0] + ", expected " + $.CUEZ_IN);
        return false;
    }
    return true;
}

// THE TWO WINDOWS, and what they are measured against.
(:test) function test_cue_theWindowsAreFourSecondsAndOneOnAClock(logger) {
    // (a) LEAVING the band takes PERSIST_OUT = 4 s. Both edges, so the window is
    // pinned at its boundary rather than "somewhere before ten seconds". 19.5
    // clears hi + DEADBAND = 19.0, so only the time is under test here.
    var oe = StrongRowView.cueStep(19.5, CueFix.LO, CueFix.HI,
                                   $.CUEZ_IN, $.CUEZ_ABOVE, 0, 3999);
    var ol = StrongRowView.cueStep(19.5, CueFix.LO, CueFix.HI,
                                   $.CUEZ_IN, $.CUEZ_ABOVE, 0, 4000);
    if (oe[0] != $.CUEZ_IN) {
        logger.error("(a) a candidate that has been asking for 3999 ms has not " +
                     "yet earned the 4 s out-of-band window; zone is " + oe[0] +
                     ", expected " + $.CUEZ_IN);
        return false;
    }
    if (ol[0] != $.CUEZ_ABOVE) {
        logger.error("(a) at 4000 ms the out-of-band change is due and must be " +
                     "taken -- a genuine overshoot has to arrive; zone is " +
                     ol[0] + ", expected " + $.CUEZ_ABOVE);
        return false;
    }

    // (b) RETURNING to the band takes PERSIST_IN = 1 s, not four. "You're fine"
    // is the cheap claim and must come back quickly, or the cue keeps shouting at
    // an athlete who has already corrected.
    var ie = StrongRowView.cueStep(17.0, CueFix.LO, CueFix.HI,
                                   $.CUEZ_ABOVE, $.CUEZ_IN, 0, 999);
    var il = StrongRowView.cueStep(17.0, CueFix.LO, CueFix.HI,
                                   $.CUEZ_ABOVE, $.CUEZ_IN, 0, 1000);
    if (ie[0] != $.CUEZ_ABOVE) {
        logger.error("(b) 999 ms is not yet the 1 s re-entry window; zone is " +
                     ie[0] + ", expected " + $.CUEZ_ABOVE);
        return false;
    }
    if (il[0] != $.CUEZ_IN) {
        logger.error("(b) at 1000 ms the return to the band is due; zone is " +
                     il[0] + ", expected " + $.CUEZ_IN);
        return false;
    }

    // (c) CROSSING THE BAND, below to above, with no settled frame in between.
    // Covered by neither "leaving IN" nor "entering IN", so it is stated rather
    // than left to be inferred: any out-of-band instruction is the expensive
    // claim and pays the long window.
    var xe = StrongRowView.cueStep(25.0, CueFix.LO, CueFix.HI,
                                   $.CUEZ_BELOW, $.CUEZ_ABOVE, 0, 3999);
    var xl = StrongRowView.cueStep(25.0, CueFix.LO, CueFix.HI,
                                   $.CUEZ_BELOW, $.CUEZ_ABOVE, 0, 4000);
    if (xe[0] != $.CUEZ_BELOW || xl[0] != $.CUEZ_ABOVE) {
        logger.error("(c) an out-of-band instruction is the expensive claim " +
                     "whichever zone it replaces: at 3999 ms the zone is " +
                     xe[0] + " (expected " + $.CUEZ_BELOW + ") and at 4000 ms " +
                     xl[0] + " (expected " + $.CUEZ_ABOVE + ")");
        return false;
    }

    // (d) PERSISTENCE MEANS CONTINUOUS. One frame back at the displayed zone
    // discards the pending change and the next candidate starts a fresh clock --
    // otherwise an intermittent spike accumulates credit across the gaps between
    // its appearances, which is a total, not a persistence test.
    var brk = StrongRowView.cueStep(17.0, CueFix.LO, CueFix.HI,
                                    $.CUEZ_IN, $.CUEZ_ABOVE, 0, 3000);
    var again = StrongRowView.cueStep(19.5, CueFix.LO, CueFix.HI,
                                      brk[0], brk[1], brk[2], 3250);
    var stillIn = StrongRowView.cueStep(19.5, CueFix.LO, CueFix.HI,
                                        again[0], again[1], again[2], 6000);
    if (stillIn[0] != $.CUEZ_IN) {
        logger.error("(d) the second spike had been asking for 2750 ms, not " +
                     "6000 -- the interrupted first spike must not have banked " +
                     "credit for it. Zone is " + stillIn[0] + ", expected " +
                     $.CUEZ_IN);
        return false;
    }

    // (e) PERSISTENCE IS MEASURED IN TIME, NOT IN CALLS. Forty calls at one
    // instant: any implementation that counts invocations reaches its threshold
    // here, one that reads the clock cannot. At the 250 ms tick a window counted
    // in callbacks would make PERSIST_OUT = 4 mean one second rather than four,
    // and would silently retune itself if the tick period ever changed.
    var z = $.CUEZ_IN;
    var cd = $.CUEZ_IN;
    var sc = 5000;
    for (var i = 0; i < 40; i++) {
        var out = StrongRowView.cueStep(19.5, CueFix.LO, CueFix.HI,
                                        z, cd, sc, 5000);
        z = out[0]; cd = out[1]; sc = out[2];
    }
    if (z != $.CUEZ_IN) {
        logger.error("(e) forty calls at a single instant advanced the cue to " +
                     z + " -- the window is being counted in callbacks, not " +
                     "measured on a clock");
        return false;
    }

    // (f) A CLOCK THAT GOES BACKWARDS restarts the timer rather than adopting or
    // stalling forever.
    //
    // SCOPE, stated precisely because the neighbouring hazard is already an open
    // question here: this pins the guard's contract on a backwards step, using
    // small unambiguous stamps. It does NOT claim to reproduce
    // System.getTimer()'s 32-bit wrap -- whether that presents as a backwards
    // step or as correct two's-complement arithmetic depends on Monkey C's
    // overflow semantics, which nothing in this repository measures and which
    // #70 owns for the pre-existing rrIsFresh / hrHave pair. The guard is
    // written so either answer is safe: the worst case is one window's delay,
    // once.
    var back = StrongRowView.cueStep(19.5, CueFix.LO, CueFix.HI,
                                     $.CUEZ_IN, $.CUEZ_ABOVE, 5000, 1000);
    if (back[0] != $.CUEZ_IN) {
        logger.error("(f) a backwards clock must not be read as 'the candidate " +
                     "has waited long enough'; zone became " + back[0]);
        return false;
    }
    if (back[2] != 1000) {
        logger.error("(f) the timer must restart from the new clock reading, " +
                     "or the change stalls until the clock catches up; since " +
                     "is " + back[2] + ", expected 1000");
        return false;
    }
    return true;
}

// THE SPIKE CASE, END TO END ON THE DRAW PATH -- what the maintainer would
// actually notice, and the case that separates "four seconds" from "four
// frames" at the real call site.
//
// FIVE consecutive frames of a 25.0 spm reading, spanning 1000 ms of injected
// clock at the 250 ms tick. Both halves matter and together they are the whole
// design in one case: the NUMBER is the measurement and updates immediately; the
// COLOUR is the instruction and does not, because a one-second excursion is not
// something to correct against.
//
// Five rather than two, deliberately: an implementation that counted callbacks
// with PERSIST_OUT = 4 would flip on the fifth frame while barely a second of
// clock had passed.
(:test) function test_cue_theScreenLagsTheColourNotTheNumber(logger) {
    var p = CueFix.workProbe();
    p.setRate(17.0);
    CueFix.renderAt(p, 0);
    CueFix.renderAt(p, 250);

    p.setRate(25.0);
    CueFix.renderAt(p, 500);
    CueFix.renderAt(p, 750);
    CueFix.renderAt(p, 1000);
    CueFix.renderAt(p, 1250);
    var d = CueFix.renderAt(p, 1500);

    var s = CueFix.numeralText(d);
    if (s == null || !s.equals("25.0")) {
        logger.error("the NUMBER is the measurement and must update at once; " +
                     "got '" + s + "', expected '25.0'");
        return false;
    }
    var c = CueFix.numeralColour(d);
    if (c != Gfx.COLOR_GREEN) {
        logger.error("a 1.0 s excursion is not an instruction to ease off: " +
                     "five frames spanning 1000 ms after the spike, the cue " +
                     "must still read green (COLOR_GREEN = " + Gfx.COLOR_GREEN +
                     "); got " + c + ". Either the window is being counted in " +
                     "frames rather than measured in seconds, or there is no " +
                     "window at all");
        return false;
    }

    // The other direction, one frame: a single dip below the band does not turn
    // the numeral blue, so the athlete is not told to row harder on the strength
    // of one reading.
    var q = CueFix.workProbe();
    q.setRate(17.0);
    CueFix.renderAt(q, 0);
    CueFix.renderAt(q, 250);
    q.setRate(14.0);
    var cd = CueFix.numeralColour(CueFix.renderAt(q, 500));
    if (cd != Gfx.COLOR_GREEN) {
        logger.error("one frame below the band is not an instruction; the cue " +
                     "must still read green (COLOR_GREEN = " + Gfx.COLOR_GREEN +
                     "); got " + cd);
        return false;
    }

    // (c) THE ADOPTION HALF. Everything above is suppression: it asserts GREEN,
    // and a call site that had stopped advancing the cue at all would satisfy
    // every line of it. A spike that does NOT stop must still become "ease off",
    // and until this section existed nothing in the suite drove an IN -> ABOVE
    // adoption through the shipping draw path. Measured, not argued: deleting
    // `mCueCand = cue[1];` at the call site left all 236 cases green.
    //
    // Driven from an IN DISPLAY on purpose -- not from CUEZ_NONE, which cueStep
    // adopts without delay and which is what section (b) of
    // test_cue_c0_theSteadyAndTheWhiteStatesAreUnchanged actually exercises.
    //
    // THE STAMPS START LATE ON PURPOSE. With every stamp under 4000 ms a call
    // site that never wrote mCueSince back would be indistinguishable from one
    // that did, because `now - 0` is already past the window. Starting at 60 s
    // makes the window relative to the candidate rather than to zero, so this
    // one section kills both write-backs.
    var r = CueFix.workProbe();
    r.setRate(17.0);
    CueFix.renderAt(r, 60000);
    CueFix.renderAt(r, 60250);
    r.setRate(25.0);
    CueFix.renderAt(r, 60500);
    CueFix.renderAt(r, 60750);
    CueFix.renderAt(r, 61000);
    CueFix.renderAt(r, 61250);
    var cs = CueFix.numeralColour(CueFix.renderAt(r, 61500));
    if (cs != Gfx.COLOR_GREEN) {
        logger.error("(c) one second into the spike is still not an " +
                     "instruction; expected green (COLOR_GREEN = " +
                     Gfx.COLOR_GREEN + "), got " + cs);
        return false;
    }
    for (var t = 61750; t < 64500; t += 250) {
        CueFix.renderAt(r, t);
    }
    var cr = CueFix.numeralColour(CueFix.renderAt(r, 64500));
    if (cr != Gfx.COLOR_RED) {
        logger.error("(c) a 25.0 spm overshoot held past PERSIST_OUT must " +
                     "reach red (COLOR_RED = " + Gfx.COLOR_RED + "); got " +
                     cr + ". The warning half of the cue has been deleted: " +
                     "either the candidate or its timestamp is not surviving " +
                     "the frame at the call site, so the zone freezes at " +
                     "whatever it first showed");
        return false;
    }
    return true;
}

// ---- end of `module CueFix` ----------------------------------------------
}
