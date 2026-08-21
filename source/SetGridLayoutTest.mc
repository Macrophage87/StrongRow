using Toybox.Test;
using Toybox.System;
using Toybox.Lang;

// Rendering suite for #131: the set-summary grid, driven through the shipping
// onUpdate.
//
// THE GATE MOVED UNDER THIS FILE. #130 added STEP_DONE to it, so the call site
// is now `(type == STEP_REST || type == STEP_GATE || type == STEP_DONE) &&
// mLastSetValid` while the SUB-ROW suppression stays on REST and GATE alone.
// The DONE half of that gate, and the geometry that makes it fit beside "BACK
// to save", live in source/GridGateTest.mc together with the two pins #142
// found missing here; this file keeps the REST / GATE / COOL cases and the
// negative sweep. Line numbers in the paragraphs below are pre-#130 and are
// left as written rather than silently re-pointed -- re-derive them from the
// current file rather than trusting them.
//
// WHY THIS FILE EXISTS. The grid's call site --
// `if ((type == STEP_REST || type == STEP_GATE) && mLastSetValid)`
// (StrongRowView.mc:3677) and its mirror on the sub row (:3748) -- was
// UNREACHED by every (:test) in the repository, because HrProbe had no way to
// set mLastSetValid. An earlier note in SetSummaryTest.mc called it "not
// reachable from a (:test)". That was the wrong word and it is retracted here
// as well as there: HrProbe.runUpdate drives the shipping onUpdate against
// HrGeoDc, a hand-written recording Dc, and HrLayoutTest.mc already renders
// GATE, WARM, COOL and DONE in CI today. #121's segfault is about obtaining a
// REAL graphics Dc and does not apply to a mock.
//
// The cost of the gap was measured, not hypothesised: the gate went through two
// display regressions during #109's review, both caught by a human reading a
// diff and neither by a test.
//
//   * the grid drawn on every non-WORK step, which took the live rate, pace and
//     m/stroke off COOL DOWN -- an ACTIVE ROWING step, on by default;
//   * the sub row suppressed on every non-WORK step, which deleted
//     "BACK to save" from DONE, the only text on the app that tells the athlete
//     how to write the FIT.
//
// Each of the cases below was mutation-tested by re-introducing exactly those
// two edits; the numbers are in the pull request.
//
// WHAT THESE CASES CAN AND CANNOT SEE, stated before anything below relies on
// it. HrGeoDc records x, y, font, string and justification for every drawText.
// So a case here can say WHICH elements a screen draws, in what order, and at
// what ANCHOR coordinates. It cannot see a glyph, a text box, an ink extent or
// an overlap: no font metric is available to a (:test) that runs in CI (#121).
// Nothing here claims the grid is legible, that its rows clear one another, or
// that it clears the countdown above it. Those are the local, per-device font
// measurements recorded on #109's pull request, and they are not re-run here.
//
// EVERY HELPER IS A STATIC ON ONE CLASS, and that is a hard constraint rather
// than a style preference. The four fenix6-family devices cap module `globals`
// at 253 members.
//
// MEASURED, by adding dummy free functions to a tree until monkeyc refuses and
// reading the number it reports -- the count is not printed on a successful
// build, so it has to be bracketed:
//
//   origin/main, --unit-test, fenix6        246   (7 free)
//   this file's first shape, +12            258   REJECTED on fenix6,
//                                                 fenix6pro, fenix6spro and
//                                                 fenix6xpro; clean on the
//                                                 other eight devices
//   this file as it stands, +5              251   (2 free)
//
// A class costs ONE global however many statics it holds, and a module-scope
// `const` costs none -- which is why the rejected shape's eight free helpers
// plus four (:test)s came to +12 rather than the +14 its fourteen declarations
// suggest. The four (:test) functions have to stay free functions, so this file
// spends 5 of the 7. The next suite added here has 2 to work with.
//
// Execution note: the run-tests CI job runs these headlessly in the simulator
// on fr965. Test names are pinned in scripts/expected_tests.txt -- update that
// file in the same commit as any (:test) change. See docs/CI.md.

class SgCase {

    // The step "kinds" that are not step-type constants, using the same
    // convention hlRender (HrLayoutTest.mc:336) established. Functions rather
    // than consts: a class-scope `const` is an instance member in Monkey C, so
    // a free function could not name it (HrProbe.kindWork documents the same
    // trap), and a module-scope const would cost a global this file cannot
    // afford.
    static function preStart() { return -1; }
    static function freeRow()  { return -2; }

    // The grid's four labels, IN DRAW ORDER (drawSetGrid, StrongRowView.mc:3054).
    // Order matters to the geometry case below, which reads the row anchors out
    // of the recorded block positionally.
    static function labels() {
        return [ "avg spm", "avg m/str", "interval m", "avg bpm" ];
    }

    // Did any string this render drew CONTAIN `needle`? Matches the string
    // field only -- x, y and font are asserted explicitly where they are the
    // subject, never smuggled into a presence check.
    static function drew(geo, needle) {
        for (var i = 0; i < geo.texts.size(); i++) {
            if (geo.texts[i][3].find(needle) != null) { return true; }
        }
        return false;
    }

    // The index of the first text EQUAL to `s`, or -1. Equality, not
    // containment: "avg spm" has to be the grid's own label and not a substring
    // of some other row that happens to grow one.
    static function indexOf(geo, s) {
        for (var i = 0; i < geo.texts.size(); i++) {
            if (geo.texts[i][3].equals(s)) { return i; }
        }
        return -1;
    }

    // The whole text log, for failure messages. Carries the coordinates,
    // because the failures this file is built to catch are positional.
    static function log(geo) {
        var out = "";
        for (var i = 0; i < geo.texts.size(); i++) {
            var t = geo.texts[i];
            out += i.toString() + ": (" + t[0].toString() + ", " +
                   t[1].toString() + ") '" + t[3] + "'\n";
        }
        return out;
    }

    static function render(p) {
        var ds = System.getDeviceSettings();
        var geo = new HrGeoDc(ds.screenWidth, ds.screenHeight);
        p.runUpdate(geo);
        return geo;
    }

    // Put a probe on `kind`, mid-session: recording, unpaused, healthy
    // accelerometer, a live heart rate, a real stroke rate from the shipping
    // detector (18.0 spm) and a speed that makes drawPace render both a pace
    // and an m/stroke term.
    static function enter(p, kind) {
        if (kind == preStart()) {
            p.enterPreStart();
        } else if (kind == freeRow()) {
            // mStarted has to be raised before the mode is switched: free row
            // reaches the footer through onUpdate's early return, not through
            // the workout branch. Same ordering as WorkLayoutTest.mc:96-99.
            p.enterStep(p.kindWork(), false);
            p.setFreeRow();
        } else {
            p.enterStep(kind, false);
        }
        p.setNarrowSession();
        p.setSpeed(4.0);
    }

    static function probeAt(kind) {
        var p = new HrProbe();
        p.driveStrokes();
        p.setSensorOk(true);
        p.setHrState(128, System.getTimer(), true);
        enter(p, kind);
        return p;
    }

    // The same probe with one completed interval latched through the shipping
    // latchWorkAccum. Returns NULL if the latch refused, so a caller reds
    // instead of asserting against an un-latched screen and being right for the
    // wrong reason.
    //
    // The totals are a 4-minute interval covering 400 m in 63 strokes at a mean
    // 150 bpm, so all four cells derive to a value and none renders the "--"
    // no-data dash: 15.75 spm, 6.35 m/str, 400 m, 150 bpm. 63 rather than 64 is
    // the count registerStroke really produces across a rest gap
    // (StrongRowView.mc:2564-2572).
    //
    // The SECONDS total is the one figure this file does not pin exactly.
    // latchSet works by moving mStepStartMs and letting the shipping
    // latchWorkAccum read stepElapsed(), so mLastSetSec is 240 s plus however
    // long the render takes -- the honest consequence of driving the real latch
    // instead of assigning the field. The cases below assert the spm cell is
    // not the dash, never that it reads 15.8.
    static function latchedProbeAt(kind) {
        var p = new HrProbe();
        p.driveStrokes();
        p.setSensorOk(true);
        p.setHrState(128, System.getTimer(), true);
        if (!p.latchSet(3, 240.0, 400.0, 63, 9450, 63)) { return null; }
        enter(p, kind);
        return p;
    }
}

// -- 1. The geometry, which is the half nothing in CI could see ----------------

// THE FOUR ROWS ARE DISTINCT AND RUN DOWN THE SCREEN.
//
// #131 asks for this one first, and the reason is that drawSetGrid's row
// positions (0.44h / 0.533h / 0.655h / 0.749h) were chosen from getFontHeight
// readings taken on a LOCAL simulator across all twelve devices. CI cannot
// obtain a font metric (#121), so nothing in this repository could see a row
// edit at all -- the pitch could collapse to a single y and every existing case
// would stay green.
//
// WHAT IS ASSERTED, precisely:
//   * the grid draws exactly eight texts, contiguously, in the documented
//     order: four labels then four values, left column then right;
//   * the two cells of a row share a y, and the two columns are at distinct x,
//     with every value in its own label's column;
//   * the four row anchors strictly increase down the screen;
//   * the whole block sits below every text drawn before it and above every
//     text drawn after it.
//
// WHAT IS NOT ASSERTED. These are ANCHOR coordinates. Whether the rows' INK
// clears is a font measurement, and the countdown's anchor is a CENTRE
// (TEXT_JUSTIFY_VCENTER) while every other row's is the top of its box, so the
// last bullet orders anchors and not boxes -- it catches a gross row move, not
// a clearance loss. The 2.46 px worst-case vertical clearance quoted at
// drawSetGrid was measured locally and is not re-measured here or anywhere in
// CI.
(:test) function test_grid_rowsAreDistinctAndOrderedDownTheScreen(logger) {
    var k = new HrProbe();
    var p = SgCase.latchedProbeAt(k.kindRest());
    if (p == null) {
        logger.error("#131: the shipping latchWorkAccum refused the seeded " +
                     "interval, so this case would assert nothing");
        return false;
    }
    var geo = SgCase.render(p);
    var lab = SgCase.labels();
    var i = SgCase.indexOf(geo, lab[0]);
    if (i < 0 || i + 7 >= geo.texts.size()) {
        logger.error("#131/#109: a latched REST screen must draw the eight-cell " +
                     "grid; '" + lab[0] + "' is at index " + i + " of " +
                     geo.texts.size() + " texts. Drew:\n" + SgCase.log(geo));
        return false;
    }
    for (var j = 0; j < 4; j++) {
        if (!geo.texts[i + j][3].equals(lab[j])) {
            logger.error("#131: the grid's labels must be drawn in the order " +
                         "drawSetGrid documents; slot " + j + " is '" +
                         geo.texts[i + j][3] + "', want '" + lab[j] +
                         "'. Drew:\n" + SgCase.log(geo));
            return false;
        }
    }

    // Row anchors, in top-to-bottom draw order: labels 1, values 1, labels 2,
    // values 2. The block is [labels x4][values x4], so each value row is four
    // slots on from its labels.
    var rowY   = [ geo.texts[i][1], geo.texts[i + 4][1],
                   geo.texts[i + 2][1], geo.texts[i + 6][1] ];
    var rowNm  = [ "label row 1", "value row 1", "label row 2", "value row 2" ];
    // The right-hand cell of each row, which must share its row's y.
    var mateOf = [ i + 1, i + 5, i + 3, i + 7 ];
    var homeOf = [ i, i + 4, i + 2, i + 6 ];

    for (var r = 0; r < 4; r++) {
        if (geo.texts[mateOf[r]][1] != rowY[r]) {
            logger.error("#109: the two cells of " + rowNm[r] + " must sit on " +
                         "one row; got y " + geo.texts[homeOf[r]][1] + " and " +
                         geo.texts[mateOf[r]][1] + ". Drew:\n" + SgCase.log(geo));
            return false;
        }
    }

    var xL = geo.texts[i][0];
    var xR = geo.texts[i + 1][0];
    if (!(xL < xR)) {
        logger.error("#109: the grid is two COLUMNS -- the left column must be " +
                     "left of the right one; got x " + xL + " and " + xR +
                     ". Drew:\n" + SgCase.log(geo));
        return false;
    }
    for (var c = 0; c < 4; c++) {
        var wantX = ((c % 2) == 0) ? xL : xR;
        if (geo.texts[i + c][0] != wantX || geo.texts[i + 4 + c][0] != wantX) {
            logger.error("#109: cell " + c + " and its label must share a " +
                         "column; label x " + geo.texts[i + c][0] + ", value x " +
                         geo.texts[i + 4 + c][0] + ", want " + wantX +
                         ". Drew:\n" + SgCase.log(geo));
            return false;
        }
    }

    for (var s = 1; s < 4; s++) {
        if (!(rowY[s] > rowY[s - 1])) {
            logger.error("#131/#109: the grid's four rows must be at DISTINCT, " +
                         "INCREASING y -- " + rowNm[s] + " is at " + rowY[s] +
                         " and " + rowNm[s - 1] + " at " + rowY[s - 1] +
                         ". The row pitch was measured against getFontHeight on " +
                         "a local simulator across all twelve devices and CI " +
                         "cannot re-measure it (#121), so this ordering is the " +
                         "only part of that geometry a test can hold. Drew:\n" +
                         SgCase.log(geo));
            return false;
        }
    }

    // The block occupies its own vertical band: below the title and countdown
    // above it, above the footer below it.
    for (var b = 0; b < i; b++) {
        if (geo.texts[b][1] >= rowY[0]) {
            logger.error("#109: '" + geo.texts[b][3] + "' is drawn before the " +
                         "grid but anchored at y " + geo.texts[b][1] +
                         ", at or below the grid's first row (" + rowY[0] +
                         "). Drew:\n" + SgCase.log(geo));
            return false;
        }
    }
    for (var a = i + 8; a < geo.texts.size(); a++) {
        if (geo.texts[a][1] <= rowY[3]) {
            logger.error("#109: '" + geo.texts[a][3] + "' is drawn after the " +
                         "grid but anchored at y " + geo.texts[a][1] +
                         ", at or above the grid's last row (" + rowY[3] +
                         "). Drew:\n" + SgCase.log(geo));
            return false;
        }
    }

    var ds = System.getDeviceSettings();
    logger.debug("SG rows " + ds.screenWidth + "x" + ds.screenHeight + ": " +
                 (rowY[0] / ds.screenHeight).format("%.4f") + "h / " +
                 (rowY[1] / ds.screenHeight).format("%.4f") + "h / " +
                 (rowY[2] / ds.screenHeight).format("%.4f") + "h / " +
                 (rowY[3] / ds.screenHeight).format("%.4f") + "h; columns " +
                 (xL / ds.screenWidth).format("%.4f") + "w / " +
                 (xR / ds.screenWidth).format("%.4f") + "w");
    return true;
}

// -- 2. The two screens the grid owns ------------------------------------------

// REST AND GATE, WITH A LATCHED SET: the grid is up and the sub row stands down.
//
// Both step types, because #109's acceptance list asks for both and an earlier
// revision narrowed it to REST alone -- `restMinutes = 0` is legal, and a
// rest-free workout is WORK/GATE/WORK, so a REST-only gate would never have
// rendered the grid at all.
//
// The title is asserted as a WITNESS that the latch actually took: "REST - SET
// n" and "READY - Wn" are the mLastSetValid arms of onUpdate's title chain
// (:3587, :3609), so a screen showing the bare "REST" / "READY" would mean the
// grid assertions below were being made against an un-latched view.
(:test) function test_grid_restAndGateShowTheGridAndDropTheSubRow(logger) {
    var k     = new HrProbe();
    var kinds = [ k.kindRest(), k.kindGate() ];
    var names = [ "REST", "GATE" ];
    // The mLastSetValid arm of the title, and the sub row that must stand down.
    var title = [ "REST - SET ", "READY - W" ];
    var sub   = [ "next: WORK ", "to start WORK " ];
    var lab   = SgCase.labels();

    for (var i = 0; i < kinds.size(); i++) {
        var p = SgCase.latchedProbeAt(kinds[i]);
        if (p == null) {
            logger.error("#131: the shipping latchWorkAccum refused the seeded " +
                         "interval on " + names[i]);
            return false;
        }
        var geo = SgCase.render(p);

        if (!SgCase.drew(geo, title[i])) {
            logger.error("#109: " + names[i] + " must show the latched set in " +
                         "its title ('" + title[i] + "') -- without it the " +
                         "assertions below would be measuring an UN-LATCHED " +
                         "screen. Drew:\n" + SgCase.log(geo));
            return false;
        }
        for (var j = 0; j < lab.size(); j++) {
            if (SgCase.indexOf(geo, lab[j]) < 0) {
                logger.error("#109: " + names[i] + " must draw the completed " +
                             "interval as a four-cell grid; '" + lab[j] +
                             "' is missing. The rest interval is when the " +
                             "athlete reads the interval just finished, and " +
                             "there is no stroke to correct. Drew:\n" +
                             SgCase.log(geo));
                return false;
            }
        }
        if (SgCase.drew(geo, sub[i])) {
            logger.error("#109: " + names[i] + " must NOT draw its sub row " +
                         "while the grid is up -- the grid needs the whole band " +
                         "between the countdown and the footer, and '" + sub[i] +
                         "' would land inside it. The number that row carried " +
                         "rides in the title instead. Drew:\n" + SgCase.log(geo));
            return false;
        }

        // The four cells carry VALUES, not the no-data dash. Absent data
        // renders as a distinct state in this app, so a grid of four dashes is
        // a legitimate screen -- and it would satisfy every presence check
        // above while proving nothing about the latch reaching the cells.
        var g = SgCase.indexOf(geo, lab[0]);
        for (var c = 0; c < 4; c++) {
            if (geo.texts[g + 4 + c][3].equals("--")) {
                logger.error("#109: cell " + c + " on " + names[i] + " rendered " +
                             "the no-data dash from a latch that carried 63 " +
                             "strokes, 400 m and 63 heart-rate samples. Drew:\n" +
                             SgCase.log(geo));
                return false;
            }
        }
    }
    return true;
}

// -- 3. The two screens the grid must stay off --------------------------------

// COOL DOWN KEEPS ITS LIVE ROWS AND ITS SUB ROW, with a set latched.
//
// This is the case that would have caught BOTH of #109's review regressions,
// and the state it renders is a real one: advanceStep latches at every WORK
// exit, so mLastSetValid is true for the whole of COOL.
//
// COOL DOWN is ACTIVE ROWING. It gets its own lap and step clock, its
// instruction is "START when docked", and warmupCooldown defaults to true.
// Replacing its live rate and pace with a frozen summary of an interval that
// already ended is a downgrade on the DEFAULT path.
//
// DONE WAS SWEPT HERE TOO AND NO LONGER IS, and that is a RETRACTION rather
// than a quiet edit. This case used to require DONE to keep its live rows and
// draw no grid; #130 establishes that requirement was wrong in half. The last
// work interval is followed by COOL or DONE and never by a REST, so DONE was
// the one screen the final interval's summary could appear on and it never
// did. What was RIGHT about the old case -- that "BACK to save" survives,
// because it is the only text in the app telling the athlete how to write the
// FIT -- is kept, and is now asserted WITH the grid up by
// GridGate.test_gg_c2_doneShowsTheFinalIntervalAndKeepsBackToSave. DONE's grid
// geometry is pinned by GridGate.test_gg_c2_theDoneGridClearsTheTitleAndTheSubRow.
//
// WARM is deliberately not swept here: it precedes every latch, so a latched
// WARM is not a state the app can reach, and asserting about one would be
// pinning fiction. It is covered un-latched by the case below.
(:test) function test_grid_coolKeepsTheLiveRowsAndTheSubRow(logger) {
    var k     = new HrProbe();
    var kinds = [ k.kindCool() ];
    var names = [ "COOL" ];
    var sub   = [ "START when docked" ];
    var lab   = SgCase.labels();

    for (var i = 0; i < kinds.size(); i++) {
        var p = SgCase.latchedProbeAt(kinds[i]);
        if (p == null) {
            logger.error("#131: the shipping latchWorkAccum refused the seeded " +
                         "interval on " + names[i]);
            return false;
        }
        var geo = SgCase.render(p);

        for (var j = 0; j < lab.size(); j++) {
            if (SgCase.indexOf(geo, lab[j]) >= 0) {
                logger.error("#109: " + names[i] + " must NOT draw the set " +
                             "grid, and it drew '" + lab[j] + "'. Widening the " +
                             "gate to every non-WORK step takes the LIVE rate, " +
                             "pace and m/stroke off COOL DOWN -- an active " +
                             "rowing step that is on by default -- and replaces " +
                             "them with a frozen summary of an interval that " +
                             "already ended. Drew:\n" + SgCase.log(geo));
                return false;
            }
        }
        if (!SgCase.drew(geo, sub[i])) {
            logger.error("#109: " + names[i] + " must draw '" + sub[i] + "'. " +
                         "The sub row stands down on exactly the two screens " +
                         "the grid occupies and NOWHERE else: suppressing it on " +
                         "every non-WORK step deletes the only text telling the " +
                         "athlete how to write the FIT. Drew:\n" + SgCase.log(geo));
            return false;
        }
        // The live rows the grid would have displaced. 18.0 spm is what
        // driveStrokes produces through the shipping detector, and "/500m" is
        // drawPace's pace term.
        if (!SgCase.drew(geo, "18.0")) {
            logger.error("#109: " + names[i] + " must keep the LIVE stroke-rate " +
                         "numeral; a latched set must not freeze it. Drew:\n" +
                         SgCase.log(geo));
            return false;
        }
        if (!SgCase.drew(geo, "/500m")) {
            logger.error("#109: " + names[i] + " must keep the live pace and " +
                         "metres-per-stroke row. Drew:\n" + SgCase.log(geo));
            return false;
        }
    }
    return true;
}

// -- 4. Before any latch -------------------------------------------------------

// NO LATCHED SET MEANS NO GRID, ON EVERY SCREEN THE APP CAN DRAW.
//
// The negative half of the gate, swept over every step type plus the pre-START
// screen and free-row mode. A fresh session has completed no interval, so there
// is nothing to summarise and the four cells would all be dashes -- an empty
// table where the live numerals belong.
//
// Each render is checked NON-VACUOUS first: a screen that drew nothing at all
// would satisfy "no grid" and satisfy it for the wrong reason. That failure
// mode is not hypothetical -- it is the one HrLayoutTest.mc:453-460 records
// having shipped.
//
// REST and GATE additionally keep their sub row here, which pins the
// suppression's gate on the LATCH rather than on the step type. Without it, a
// change that suppressed the row on REST and GATE unconditionally would leave
// those two screens with neither a grid nor a "next: WORK n" -- and every other
// case in this file would stay green.
(:test) function test_grid_noLatchedSetMeansNoGridOnAnyScreen(logger) {
    var k     = new HrProbe();
    var kinds = [ k.kindWork(), k.kindRest(), k.kindGate(), k.kindWarm(),
                  k.kindCool(), k.kindDone(),
                  SgCase.preStart(), SgCase.freeRow() ];
    var names = [ "WORK", "REST", "GATE", "WARM", "COOL", "DONE",
                  "pre-START", "free-row" ];
    // The sub row REST and GATE must still carry with no set latched; null
    // where the screen has no such requirement.
    var sub   = [ null, "next: WORK ", "to start WORK ", null,
                  null, null, null, null ];
    var lab   = SgCase.labels();

    for (var i = 0; i < kinds.size(); i++) {
        var geo = SgCase.render(SgCase.probeAt(kinds[i]));
        if (geo.texts.size() < 3) {
            logger.error(names[i] + " drew only " + geo.texts.size() +
                         " text elements, so the check below proves nothing " +
                         "about it");
            return false;
        }
        for (var j = 0; j < lab.size(); j++) {
            if (SgCase.indexOf(geo, lab[j]) >= 0) {
                logger.error("#109: " + names[i] + " has no completed interval " +
                             "to summarise, so it must draw no grid -- and it " +
                             "drew '" + lab[j] + "'. Every cell would be the " +
                             "no-data dash, which is an empty table standing " +
                             "where the live numerals belong. Drew:\n" +
                             SgCase.log(geo));
                return false;
            }
        }
        if (sub[i] != null && !SgCase.drew(geo, sub[i])) {
            logger.error("#109: with NO set latched, " + names[i] + " must " +
                         "still draw '" + sub[i] + "' -- the sub row stands " +
                         "down for the GRID, not for the step type, and this " +
                         "screen has no grid. Drew:\n" + SgCase.log(geo));
            return false;
        }
    }
    return true;
}
