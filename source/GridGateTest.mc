using Toybox.Test;
using Toybox.System;
using Toybox.Lang;

// ---------------------------------------------------------------------------
// #142 / #130 -- the set-summary grid's GATE, and its no-data arm.
//
// EVERYTHING IN THIS FILE LIVES IN `module GridGate`, and that is a hard
// constraint rather than a taste. The four fenix6-family devices cap module
// `globals` at 253 members; a file-scope (:test) costs one member each, a
// module block costs ONE between all of them. The simulator prints these cases
// as `GridGate.test_gg_...`, which is the name scripts/list_tests.py emits and
// the name scripts/expected_tests.txt must therefore carry.
//
// RE-BISECTED for this branch on fenix6 with SDK 9.2.0. N throwaway file-scope
// (:test) functions were added to the tree until monkeyc refused, and the
// number it reports was read off the FAILURE -- the count is not printed on a
// successful build, so it can only be bracketed.
//
// Against origin/main at 9617605, WITHOUT this file (N=10 builds, N=11 reports
// "Found 254 members in module 'globals', exceeding the limit of 253"):
//
//     CEILING 9617605 fenix6: 243 used of 253, 10 free -- the 11th file-scope (:test) added reds
//
// And WITH this file in the tree (N=9 builds, N=10 reports 254):
//
//     CEILING v08-display-fixes fenix6: 244 used of 253, 9 free -- the 10th file-scope (:test) added reds
//
// The limit is INCLUSIVE, which is what makes 9 free and the 10th the one that
// reds. The first figure is unchanged from the erg-r5 note in
// source/ErgUnitsTest.mc, and that it did not move is itself the measurement:
// nothing was removed at file scope between them. The second says what this
// whole file costs -- ONE member for every case and helper it holds, which is
// the module block's entire justification stated as arithmetic.
//
// WHY THIS FILE EXISTS -- two gaps in source/SetGridLayoutTest.mc, both of
// which were confirmed by MUTATION rather than by reading:
//
//   (a) THE WORK EXCLUSION WAS PINNED BY NOTHING. That file renders WORK only
//       with NO set latched (test_grid_noLatchedSetMeansNoGridOnAnyScreen), and
//       a screen with no latch draws no grid whatever the step type -- so
//       widening the gate to `type != STEP_WORK || latched` left the whole
//       suite green. The exclusion that keeps a frozen summary off the LIVE
//       work screen is exactly the boundary both of #109's review regressions
//       crossed.
//
//   (b) NO CASE EVER RENDERED A NULL CELL. Every existing grid case latches
//       63 strokes, 400 m and 63 heart-rate samples, so all four cells derive
//       to a value and the arm that turns a missing value into a dash never
//       executed. setAvgSpm / setAvgDps / setAvgBpm / setDistM were built to
//       return null rather than 0.0 precisely so the renderer could show a
//       dash -- and nothing checked that it does. That leaves the #86 / #107
//       absence-rendered-as-a-value class unguarded ON THE RENDER PATH, which
//       is where the athlete meets it.
//
// WHAT THESE CASES CAN AND CANNOT SEE, stated before anything below leans on
// it. HrGeoDc records x, y, font, string and justification for every drawText,
// so a case here can say WHICH elements a screen draws, in what order, and at
// what ANCHOR coordinates. It cannot see a glyph, a text box, an ink extent or
// an overlap: no font metric is available to a (:test) that runs in CI (#121).
// Nothing here claims the grid is legible or that its rows clear one another.
// Where a font height is needed it is taken from the MEASURED per-device table
// recorded at drawSetGrid and in #130's body -- a figure measured once on a
// local simulator across all twelve devices, never re-measured here, and never
// a chosen fraction (that guess is what produced two prior layout regressions).
//
// The shared plumbing -- HrProbe, HrGeoDc and SgCase's render / drew / indexOf
// / labels / enter helpers -- is REUSED from source/HrArcTest.mc and
// source/SetGridLayoutTest.mc rather than copied. A private copy would cost a
// second globals member and could drift from the layout the other suite pins.
//
// Execution note: the run-tests CI job runs these headlessly in the simulator
// on fr965. Test names are pinned in scripts/expected_tests.txt -- update that
// file in the same commit as any (:test) change. See docs/CI.md.

module GridGate {

class GgCase {

    // The four VALUE cells of the rendered grid, in draw order, or null if the
    // grid is not on screen. The block is [4 labels][4 values]; indexing off
    // the first LABEL is how SgCase's geometry case reads the same block.
    static function values(geo) {
        var lab = SgCase.labels();
        var i = SgCase.indexOf(geo, lab[0]);
        if (i < 0 || i + 7 >= geo.texts.size()) { return null; }
        return [ geo.texts[i + 4][3], geo.texts[i + 5][3],
                 geo.texts[i + 6][3], geo.texts[i + 7][3] ];
    }

    // The y anchors of the grid's four ROWS, top to bottom: labels 1, values 1,
    // labels 2, values 2. Null if the grid is not on screen.
    static function rowY(geo) {
        var lab = SgCase.labels();
        var i = SgCase.indexOf(geo, lab[0]);
        if (i < 0 || i + 7 >= geo.texts.size()) { return null; }
        return [ geo.texts[i][1], geo.texts[i + 4][1],
                 geo.texts[i + 2][1], geo.texts[i + 6][1] ];
    }

    // Is the grid on screen at all? Asks for EVERY label, so a partial block
    // is a failure rather than a half-answer.
    static function gridUp(geo) {
        var lab = SgCase.labels();
        for (var j = 0; j < lab.size(); j++) {
            if (SgCase.indexOf(geo, lab[j]) < 0) { return false; }
        }
        return true;
    }

    // The same probe SgCase.latchedProbeAt builds, but with an interval whose
    // every cell derives to NULL: no strokes, no distance, no heart-rate
    // samples. 240 s of step clock, so the interval is real and only its
    // CONTENTS are absent.
    //
    // A REACHABLE STATE, not a contrived one. mLastSetDist comes from
    // Activity.Info.elapsedDistance, which is 0.0 on an indoor row with no GPS
    // fix; mLastSetHrN is 0 whenever no strap is paired or the reading is
    // stale for the whole interval (the hrHave gate in onTick); and
    // mLastSetStrokes is 0 for an interval in which the detector accepted no
    // period. Each cell's null comes from its OWN static -- setAvgSpm,
    // setAvgDps, setDistM and setAvgBpm are independent and each is pinned in
    // source/SetSummaryTest.mc -- so this drives all four arms at once without
    // claiming they share one.
    //
    // Returns NULL if the shipping latch refused, so a caller reds rather than
    // asserting against an un-latched screen and being right for the wrong
    // reason.
    static function nullLatchedProbeAt(kind) {
        var p = new HrProbe();
        p.driveStrokes();
        p.setSensorOk(true);
        p.setHrState(128, System.getTimer(), true);
        // A SUBTRACTION from the device clock happens inside latchSet; nothing
        // here synthesises an absolute stamp from System.getTimer(), which is
        // the local-green / CI-red trap this repository has recorded.
        if (!p.latchSet(3, 240.0, 0.0, 0, 0, 0)) { return null; }
        SgCase.enter(p, kind);
        return p;
    }
}

// -- c1: the two pins #142 asks for. Green before the #130 fix and after it ---

// A LATCHED SET DOES NOT PUT THE GRID ON THE LIVE WORK SCREEN.
//
// #142(a). This is the case whose absence let the gate be widened to include
// WORK with the whole suite staying green, and it is the boundary both of
// #109's review regressions crossed. During WORK there IS a stroke to correct:
// the screen's whole job is the live numeral, and a frozen summary of an
// interval that already ended standing in its place is the downgrade.
//
// NON-VACUITY IS SCOPED TO THE ELEMENT UNDER TEST, not to the screen. "The
// screen drew something" stops proving anything the moment a second element
// exists, so what is asserted is that the LIVE STROKE RATE -- the element the
// grid would displace -- is on screen in this very render. 18.0 spm is what
// HrProbe.driveStrokes produces through the shipping detector.
(:test) function test_gg_c1_workWithALatchedSetDrawsNoGrid(logger) {
    var k = new HrProbe();
    var p = SgCase.latchedProbeAt(k.kindWork());
    if (p == null) {
        logger.error("#142: the shipping latchWorkAccum refused the seeded " +
                     "interval, so this case would assert nothing");
        return false;
    }
    var geo = SgCase.render(p);
    // THE SUBJECT FIRST and the non-vacuity check after it, so the widened-gate
    // mutant reports the grid it drew rather than the live rate it displaced.
    var lab = SgCase.labels();
    for (var j = 0; j < lab.size(); j++) {
        if (SgCase.indexOf(geo, lab[j]) >= 0) {
            logger.error("#142/#109: WORK must NOT draw the set grid, and it " +
                         "drew '" + lab[j] + "'. A latched set is the ORDINARY " +
                         "state of every work interval after the first, so " +
                         "this is not an edge case: widening the gate to " +
                         "include WORK replaces the live stroke rate with a " +
                         "frozen summary for the whole of the piece. Drew:\n" +
                         SgCase.log(geo));
            return false;
        }
    }
    if (!SgCase.drew(geo, "18.0")) {
        logger.error("#142: the WORK screen must carry the LIVE stroke rate " +
                     "(18.0 spm from the shipping detector) -- without it the " +
                     "check above would be asserting 'no grid' against a " +
                     "screen that drew nothing useful, and would hold for the " +
                     "wrong reason. Drew:\n" + SgCase.log(geo));
        return false;
    }
    return true;
}

// A MISSING VALUE RENDERS AS A DASH, IN EVERY CELL, AND NEVER AS A ZERO.
//
// #142(b), and the #86 / #107 defect class on the render path. Every other grid
// case latches 63 strokes, 400 m and 63 heart-rate samples, so this arm has
// never executed in CI: the four statics were deliberately built to return null
// rather than 0.0, and nothing checked that the renderer honours it.
//
// "0.0 m/str" is not a smaller version of the truth -- it is a claim the
// interval never made, and 0.0 is a LEGAL value for three of these four cells,
// which is what makes the confusion unrecoverable downstream.
//
// The assertion is SCOPED TO THE FOUR VALUE SLOTS, positionally. A screen-wide
// search for "0.0" would be answered by the live pace row and would fail for a
// reason that has nothing to do with the grid.
(:test) function test_gg_c1_aNullCellRendersADashNeverAZero(logger) {
    var k = new HrProbe();
    var p = GgCase.nullLatchedProbeAt(k.kindRest());
    if (p == null) {
        logger.error("#142: the shipping latchWorkAccum refused the empty " +
                     "interval, so this case would assert nothing");
        return false;
    }
    var geo = SgCase.render(p);
    // The title is the WITNESS that the latch took: "REST - SET n" is the
    // mLastSetValid arm of onUpdate's title chain, so a bare "REST" would mean
    // everything below was being asserted against an un-latched screen.
    if (!SgCase.drew(geo, "REST - SET ")) {
        logger.error("#142: REST must show the latched set in its title -- " +
                     "without it the cells below are an UN-LATCHED screen. " +
                     "Drew:\n" + SgCase.log(geo));
        return false;
    }
    var v = GgCase.values(geo);
    if (v == null) {
        logger.error("#142: an interval with no strokes, no distance and no " +
                     "heart-rate samples still HAPPENED -- the grid must be " +
                     "drawn and must say so with dashes, not omitted. Drew:\n" +
                     SgCase.log(geo));
        return false;
    }
    for (var c = 0; c < 4; c++) {
        if (!v[c].equals("--")) {
            logger.error("#142/#86/#107: cell " + c + " rendered '" + v[c] +
                         "' for a value that is ABSENT. Every cell must render " +
                         "the dash: 0.0 is a legal reading for three of these " +
                         "four quantities, so a zero standing in for 'no data' " +
                         "cannot be told from a measurement by anything " +
                         "downstream. Drew:\n" + SgCase.log(geo));
            return false;
        }
    }
    return true;
}

// -- c2: the differentials for #130. RED until the DONE arm lands -------------

// MEASURED FONT HEIGHTS, as fractions of display height, worst case over all
// TWELVE manifest devices. NOT re-measured here and NOT a chosen fraction: they
// come from the getFontHeight sweep recorded at drawSetGrid and in #130's body,
// taken once on a local simulator, because no (:test) that runs in CI can
// obtain a font metric (#121). Two prior layout regressions came from guessed
// fractions, which is why these carry their provenance in the name of the
// constant's comment rather than in a commit message.
//
//   FONT_TINY   29/260 on the fenix6 / 6pro / 7 / 7pro family
//   FONT_SMALL  the fenix6xpro reading from #130's table
const GG_TINY_H_FRAC  = 0.1115;
const GG_SMALL_H_FRAC = 0.1214;

// THE GRID IS UP ON EVERY RECOVERY SCREEN AND ON NO ACTIVE ONE.
//
// The whole gate in one table, with a set latched -- which is the ORDINARY
// state of everything after the first work interval, since advanceStep latches
// at every WORK exit and mLastSetValid never clears within a row.
//
//   WORK  no   there is a stroke to correct; the live numeral is the screen
//   REST  yes  the recovery screen the grid was built for (#109)
//   GATE  yes  likewise -- restMinutes = 0 is legal, so a rest-free workout is
//              WORK/GATE/WORK and a REST-only gate would never draw the grid
//   COOL  no   ACTIVE ROWING: its own lap and step clock, "START when docked",
//              and warmupCooldown defaults to true. Freezing its live rate and
//              pace is a downgrade on the DEFAULT path
//   DONE  yes  #130. The last work interval is followed by COOL or DONE and
//              never by a REST, so the summary of the final interval -- the one
//              the athlete most wants -- was the only one never displayed
//
// WARM IS DELIBERATELY NOT SWEPT. It precedes every latch, so a latched WARM is
// not a state the app can reach and asserting about one would be pinning
// fiction. It is covered un-latched by
// test_grid_noLatchedSetMeansNoGridOnAnyScreen.
//
// Every no-grid screen is additionally checked for the LIVE stroke rate, so
// "no grid" can never hold because the render drew nothing.
(:test) function test_gg_c2_theGridIsUpOnEveryRecoveryStepAndNowhereElse(logger) {
    var k     = new HrProbe();
    var kinds = [ k.kindWork(), k.kindRest(), k.kindGate(),
                  k.kindCool(), k.kindDone() ];
    var names = [ "WORK", "REST", "GATE", "COOL", "DONE" ];
    var want  = [ false, true, true, false, true ];

    for (var i = 0; i < kinds.size(); i++) {
        var p = SgCase.latchedProbeAt(kinds[i]);
        if (p == null) {
            logger.error("#130: the shipping latchWorkAccum refused the seeded " +
                         "interval on " + names[i]);
            return false;
        }
        var geo = SgCase.render(p);
        var up  = GgCase.gridUp(geo);
        if (up != want[i]) {
            logger.error("#130/#109: with a set latched, " + names[i] +
                         " must " + (want[i] ? "DRAW" : "NOT draw") +
                         " the set grid; it " + (up ? "did" : "did not") +
                         ". The gate is REST, GATE and DONE -- the three " +
                         "screens where no stroke is being taken -- and it is " +
                         "NOT every non-WORK step, which would freeze COOL " +
                         "DOWN's live rate on the default path. Drew:\n" +
                         SgCase.log(geo));
            return false;
        }
        if (!up && !SgCase.drew(geo, "18.0")) {
            logger.error("#130: " + names[i] + " draws no grid, so it must be " +
                         "showing the LIVE stroke rate instead -- otherwise " +
                         "'no grid' holds for the wrong reason. Drew:\n" +
                         SgCase.log(geo));
            return false;
        }
    }
    return true;
}

// DONE SHOWS THE FINAL INTERVAL **AND** KEEPS "BACK to save".
//
// Both halves, in one case, because they are the two things #130 has to hold at
// once and #109's second review regression is precisely what happens when the
// sub row is suppressed wherever the grid appears: "BACK to save" is the only
// text in the app that tells the athlete how to write the FIT, and losing it
// loses the row.
//
// The live rows go, and that is the trade being pinned rather than an
// oversight. On DONE the piece is over: there is no stroke to correct, so the
// live numeral and the pace row are reporting an activity that has stopped,
// while the interval just finished is the thing worth reading.
(:test) function test_gg_c2_doneShowsTheFinalIntervalAndKeepsBackToSave(logger) {
    var k = new HrProbe();
    var p = SgCase.latchedProbeAt(k.kindDone());
    if (p == null) {
        logger.error("#130: the shipping latchWorkAccum refused the seeded " +
                     "interval on DONE");
        return false;
    }
    var geo = SgCase.render(p);
    var lab = SgCase.labels();
    for (var j = 0; j < lab.size(); j++) {
        if (SgCase.indexOf(geo, lab[j]) < 0) {
            logger.error("#130: DONE must draw the completed interval as a " +
                         "four-cell grid; '" + lab[j] + "' is missing. The " +
                         "last work interval is followed by COOL or DONE and " +
                         "never by a REST, so this is the ONLY screen its " +
                         "summary can appear on. Drew:\n" + SgCase.log(geo));
            return false;
        }
    }
    if (!SgCase.drew(geo, "BACK to save")) {
        logger.error("#130/#109: DONE must keep 'BACK to save' WITH the grid " +
                     "up. It is the only text in the app telling the athlete " +
                     "how to write the FIT, and suppressing the sub row " +
                     "wherever the grid appears is exactly the regression " +
                     "#109's review shipped once already. Drew:\n" +
                     SgCase.log(geo));
        return false;
    }
    // The four cells carry VALUES, not the no-data dash: a grid of four dashes
    // would satisfy every presence check above and prove nothing about the
    // latch reaching the cells.
    var v = GgCase.values(geo);
    for (var c = 0; c < 4; c++) {
        if (v[c].equals("--")) {
            logger.error("#130: cell " + c + " on DONE rendered the no-data " +
                         "dash from a latch that carried 63 strokes, 400 m " +
                         "and 63 heart-rate samples. Drew:\n" + SgCase.log(geo));
            return false;
        }
    }
    if (SgCase.drew(geo, "18.0") || SgCase.drew(geo, "/500m")) {
        logger.error("#130: DONE must not draw the live stroke rate or the " +
                     "live pace row while the grid is up -- the two would " +
                     "occupy the same band, and the piece is over. Drew:\n" +
                     SgCase.log(geo));
        return false;
    }
    return true;
}

// THE DONE GRID SITS IN ITS OWN BAND: BELOW THE TITLE, ABOVE THE SUB ROW.
//
// #130's whole difficulty is geometric. DONE's band is already spoken for by
// "BACK to save" at h*0.78, and the grid's shipping rows put the bottom value
// row at 0.749h -- so drawn at the REST positions the grid would land ON the
// one row that must survive. What buys the space is that DONE draws NO
// countdown: the band starts at the title rather than under a FONT_NUMBER_MILD
// numeral.
//
// WHAT IS ASSERTED, and it is a real clearance rather than an ordering:
//   * the title's ink, taken at the MEASURED worst-case FONT_SMALL height,
//     ends at or above the grid's first row anchor;
//   * the bottom value row's ink, at the MEASURED worst-case FONT_TINY height,
//     ends at or above the sub row's anchor.
// Both reference points are READ OUT OF THE RENDER -- the title and the sub row
// are found by their strings, never transcribed as fractions -- so a change to
// either row's y moves this case with it.
//
// WHAT IS NOT ASSERTED. These are ANCHOR coordinates plus a worst-case font
// height from a table measured on a local simulator; they are not ink extents,
// and no (:test) in CI can measure one (#121). This says the boxes do not
// overlap on the twelve devices the table covers. It says nothing about
// legibility, and nothing about the columns.
//
// It is also what stops the DONE grid being drawn at the REST row positions:
// 0.749h + 0.1115h = 0.8605h is below the 0.78h sub row, so that arrangement
// reds here.
(:test) function test_gg_c2_theDoneGridClearsTheTitleAndTheSubRow(logger) {
    var k = new HrProbe();
    var p = SgCase.latchedProbeAt(k.kindDone());
    if (p == null) {
        logger.error("#130: the shipping latchWorkAccum refused the seeded " +
                     "interval on DONE");
        return false;
    }
    var geo = SgCase.render(p);
    var row = GgCase.rowY(geo);
    if (row == null) {
        logger.error("#130: DONE must draw the grid for this case to have a " +
                     "subject. Drew:\n" + SgCase.log(geo));
        return false;
    }
    var ti = SgCase.indexOf(geo, "DONE");
    var si = SgCase.indexOf(geo, "BACK to save");
    if (ti < 0 || si < 0) {
        logger.error("#130: DONE must draw both its title and 'BACK to save' " +
                     "-- they are the two reference rows this case measures " +
                     "against. title index " + ti + ", sub index " + si +
                     ". Drew:\n" + SgCase.log(geo));
        return false;
    }
    var h       = geo.getHeight();
    var titleY  = geo.texts[ti][1];
    var subY    = geo.texts[si][1];
    var titleEnd = titleY + GG_SMALL_H_FRAC * h;
    var gridEnd  = row[3] + GG_TINY_H_FRAC * h;
    if (!(titleEnd <= row[0])) {
        logger.error("#130: the title's box ends at " + titleEnd +
                     " and the grid's first row is anchored at " + row[0] +
                     " -- the grid must start BELOW the title. Drew:\n" +
                     SgCase.log(geo));
        return false;
    }
    if (!(gridEnd <= subY)) {
        logger.error("#130: the grid's bottom value row ends at " + gridEnd +
                     " and 'BACK to save' is anchored at " + subY +
                     " -- the grid must finish ABOVE the sub row. Drawing it " +
                     "at the REST row positions (bottom value row 0.749h, box " +
                     "to 0.8605h) lands it ON that row, which is why DONE " +
                     "needs a raised base rather than the same fractions. " +
                     "Drew:\n" + SgCase.log(geo));
        return false;
    }
    logger.debug("DONE grid band: title box ends " + (titleEnd / h).format("%.4f") +
                 "h, rows " + (row[0] / h).format("%.4f") + "h .. " +
                 (row[3] / h).format("%.4f") + "h, grid box ends " +
                 (gridEnd / h).format("%.4f") + "h, sub row " +
                 (subY / h).format("%.4f") + "h");
    return true;
}

}
