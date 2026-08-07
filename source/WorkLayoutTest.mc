using Toybox.Test;
using Toybox.Graphics as Gfx;
using Toybox.System;
using Toybox.Lang;

// Layout suite for issue #108: the per-step-type split of onUpdate, and the
// work-remaining figure that lands underneath the countdown.
//
// WHAT THIS FILE CAN AND CANNOT SEE, stated first because everything below
// depends on it. HrDc (HrArcTest.mc) records every drawText the shipping draw
// path issues, with its coordinates, font, string and justification. So a case
// here can say WHICH ELEMENTS a screen draws, exactly, in order. It cannot say
// anything about how they look, whether they overlap, or whether they are
// legible: no font metric is available to a (:test) that runs in CI (#121 --
// the container segfaults the moment a test obtains a graphics Dc), and no CI
// job renders a screen.
//
// The clearance measurements that decide the geometry are therefore LOCAL and
// are recorded in the pull request, not re-run here. What runs here is the
// element set, which is the half a local measurement cannot guard between runs.
//
// This file opens with CHARACTERIZATION PINS (commit c0). Every case in that
// section is green on main BEFORE any of #108 lands and green after it, and
// they exist so that the screens #108 must NOT touch are guarded by a test
// rather than by a promise:
//
//   free row   (mWorkoutEnabled == false; onUpdate returns before the workout
//               branch, so none of #108's split applies to it)
//   WARM / COOL / DONE / pre-START      already rest-shaped, unchanged
//   REST / GATE                         keep everything WORK drops
//
// Execution note: the run-tests CI job runs these headlessly in the simulator
// on fr965. Test names are pinned in scripts/expected_tests.txt -- update that
// file in the same commit as any (:test) change. See docs/CI.md.

// Does any string this render drew contain `needle`?
//
// Matches on the STRING field only, deliberately. HrDc's log line also carries
// x, y, font and justify, and matching those would pin coordinates that this
// file has no way to justify -- the y fractions are a layout decision measured
// elsewhere, not a contract these cases own.
function wlDrew(d, needle) {
    for (var i = 0; i < d.texts.size(); i++) {
        var s = d.texts[i];
        if (s.find(needle) != null) { return true; }
    }
    return false;
}

// A probe in a live, recording, unpaused step of `kind`, with a heart rate, a
// stroke rate and a healthy accelerometer -- i.e. the ordinary mid-session
// state, which is the one whose footer reads "REC ...".
function wlProbeAt(kind) {
    var p = new HrProbe();
    p.driveStrokes();
    p.setSensorOk(true);
    p.setHrState(128, System.getTimer(), true);
    p.enterStep(kind, false);
    p.setNarrowSession();
    p.setSpeed(4.0);
    return p;
}

// How many of them do. Needed where presence cannot separate two elements that
// legitimately share a word -- the title and the footer both say PAUSED.
function wlCount(d, needle) {
    var n = 0;
    for (var i = 0; i < d.texts.size(); i++) {
        var s = d.texts[i];
        if (s.find(needle) != null) { n += 1; }
    }
    return n;
}

function wlRender(p) {
    var ds = System.getDeviceSettings();
    var d = new HrDc(ds.screenWidth, ds.screenHeight);
    p.runUpdate(d);
    return d;
}

// -- c0: characterization pins -------------------------------------------------
// Green in every epoch of this change.

// Free-row mode is #108's hardest negative requirement: it has no step types at
// all, so onUpdate returns before the workout branch and none of the split may
// reach it. Pinned as the full element set rather than as "the early return
// exists", so a refactor that moved the pips or the footer above that return
// would red here.
(:test) function test_lay_c0_freeRowDrawsTheFullScreen(logger) {
    var p = new HrProbe();
    p.driveStrokes();
    p.setSensorOk(true);
    // Recording, THEN switched to free row: mStarted has to be true for the
    // footer to read "REC ...", and free row reaches the footer through the
    // early return rather than through the workout branch. Ordered this way
    // because enterStep is the only seam that raises mStarted.
    p.enterStep(p.kindWork(), false);
    p.setFreeRow();
    p.setNarrowSession();
    p.setSpeed(4.0);
    var d = wlRender(p);
    var want = [ "GPS", "RR", "CT", "ROW SPM", "/500m", "free row", "REC " ];
    for (var i = 0; i < want.size(); i++) {
        if (!wlDrew(d, want[i])) {
            logger.error("#108: free-row mode must be unchanged, and it is " +
                         "missing '" + want[i] + "'. It has no step types, so " +
                         "the per-step-type split must not reach it. Drew:\n" +
                         d.textLog());
            return false;
        }
    }
    return true;
}

// The three step types #108 leaves alone. Each keeps the status pips, the pace
// row and the recording footer.
(:test) function test_lay_c0_warmCoolDoneKeepTheFullScreen(logger) {
    var k = new HrProbe();
    var kinds = [ k.kindWarm(), k.kindCool(), k.kindDone() ];
    var names = [ "WARM", "COOL", "DONE" ];
    var want  = [ "GPS", "RR", "CT", "/500m", "REC " ];
    for (var i = 0; i < kinds.size(); i++) {
        var d = wlRender(wlProbeAt(kinds[i]));
        for (var j = 0; j < want.size(); j++) {
            if (!wlDrew(d, want[j])) {
                logger.error("#108: " + names[i] + " is already rest-shaped and " +
                             "must keep today's full layout; '" + want[j] +
                             "' is missing. Drew:\n" + d.textLog());
                return false;
            }
        }
    }
    return true;
}

// The pre-START screen, which #108 also leaves alone.
(:test) function test_lay_c0_preStartKeepsTheFullScreen(logger) {
    var p = new HrProbe();
    p.driveStrokes();
    p.setSensorOk(true);
    p.enterPreStart();
    p.setSpeed(4.0);
    var d = wlRender(p);
    var want = [ "GPS", "RR", "CT", "/500m", "START to record", "START to begin" ];
    for (var i = 0; i < want.size(); i++) {
        if (!wlDrew(d, want[i])) {
            logger.error("#108: the pre-START screen must be unchanged; '" +
                         want[i] + "' is missing. Drew:\n" + d.textLog());
            return false;
        }
    }
    return true;
}

// REST and GATE are where everything the work view drops comes back, and where
// #109's grid lives. Pinned on the pips and the footer, which are the two
// groups #108 removes from work -- the pace row is NOT pinned here because
// #109 already replaces it with the grid on exactly these two screens whenever
// a completed interval has been latched.
(:test) function test_lay_c0_restAndGateKeepPipsAndFooter(logger) {
    var k = new HrProbe();
    var kinds = [ k.kindRest(), k.kindGate() ];
    var names = [ "REST", "GATE" ];
    var want  = [ "GPS", "RR", "CT", "REC " ];
    for (var i = 0; i < kinds.size(); i++) {
        var d = wlRender(wlProbeAt(kinds[i]));
        for (var j = 0; j < want.size(); j++) {
            if (!wlDrew(d, want[j])) {
                logger.error("#108: " + names[i] + " must keep everything the " +
                             "work view drops; '" + want[j] + "' is missing. " +
                             "Drew:\n" + d.textLog());
                return false;
            }
        }
    }
    return true;
}

// The target band stays on the work view. #107 depends on it: it is what keeps
// colour from being the sole channel for the in-band / out-of-band judgement,
// so removing it would silently break that issue's accessibility argument.
// Green before and after the strip -- the strip must not take this with it.
(:test) function test_lay_c0_workKeepsTheTargetCaption(logger) {
    var d = wlRender(wlProbeAt(new HrProbe().kindWork()));
    if (!wlDrew(d, "target ")) {
        logger.error("#108/#107: the work view must keep the target-band " +
                     "caption -- it is the non-colour channel for the " +
                     "in-band judgement. Drew:\n" + d.textLog());
        return false;
    }
    return true;
}

// Glance priorities 1 and 2 survive the strip: the interval label and the big
// stroke-rate numeral are what the work view exists to show.
(:test) function test_lay_c0_workKeepsLabelAndRate(logger) {
    var d = wlRender(wlProbeAt(new HrProbe().kindWork()));
    if (!wlDrew(d, "WORK ")) {
        logger.error("#108: the work view must keep its interval label. Drew:\n" +
                     d.textLog());
        return false;
    }
    if (!wlDrew(d, "18.0")) {
        logger.error("#108: the work view must keep the stroke-rate numeral -- " +
                     "it is glance priority 1 and the whole point of the " +
                     "screen. Drew:\n" + d.textLog());
        return false;
    }
    return true;
}

// -- c1: green pins on the new seam --------------------------------------------
// Green from the commit that introduces the statics onward. They are the anchor
// for the red differentials that follow: without them a "fix" that made
// workLeftSec return zero, or that dropped the caption entirely, would satisfy
// every red case while being strictly worse than the defect.

// The arithmetic, on a shape that has all four ingredients: a current step with
// time on it, future steps that carry :dur, and future steps that do not.
(:test) function test_lay_workLeftAddsFutureDurations(logger) {
    var steps = [ { :dur => 240 }, { :dur => 120 }, { :dur => 240 }, {} ];
    var got = StrongRowView.workLeftSec(steps, 0, 100.0);
    if (got != 460.0) {
        logger.error("#108: work-left must be the current step's remainder " +
                     "plus every future :dur -- 100 + 120 + 240 = 460; got " + got);
        return false;
    }
    return true;
}

// buildWorkout attaches :dur to STEP_WORK and STEP_REST only; warm-up, gates,
// cool-down and done carry none. A step without the key contributes ZERO, which
// is the whole reason this figure is a lower bound rather than a session total.
(:test) function test_lay_workLeftSkipsStepsWithNoDuration(logger) {
    var steps = [ { :dur => 240 }, {}, { :dur => 120 }, {}, {} ];
    var got = StrongRowView.workLeftSec(steps, 0, 0.0);
    if (got != 120.0) {
        logger.error("#108: steps with no :dur key contribute zero -- gates, " +
                     "warm-up and cool-down end on a user press, so they are " +
                     "not clocks. Expected 120; got " + got);
        return false;
    }
    return true;
}

// #108's acceptance list asks for this reading to be VERIFIED as intended
// rather than discovered as a bug: standing on a gate, the current-step term is
// zero (stepRemaining() returns 0.0 for a step with no :dur), so the figure is
// exactly the future sum. Those steps have no clock to count down, so there is
// nothing of them to include.
(:test) function test_lay_workLeftOnAGateIsTheFutureSumOnly(logger) {
    var steps = [ { :dur => 240 }, {}, { :dur => 180 }, { :dur => 60 } ];
    var got = StrongRowView.workLeftSec(steps, 1, 0.0);
    if (got != 240.0) {
        logger.error("#108: on a step with no :dur the current-step term is " +
                     "zero and the figure is the future sum, 180 + 60 = 240; " +
                     "got " + got);
        return false;
    }
    return true;
}

// The last step has nothing after it, so the sum is the current remainder
// alone. Guards the loop bound: `i = idx` instead of `i = idx + 1` would
// double-count the current step, and every other case here would stay green.
(:test) function test_lay_workLeftNeverDoubleCountsTheCurrentStep(logger) {
    var steps = [ { :dur => 240 }, { :dur => 120 } ];
    var last = StrongRowView.workLeftSec(steps, 1, 55.0);
    if (last != 55.0) {
        logger.error("#108: on the final step the figure is the current " +
                     "remainder alone; got " + last + " (want 55.0)");
        return false;
    }
    var first = StrongRowView.workLeftSec(steps, 0, 240.0);
    if (first != 360.0) {
        logger.error("#108: the current step's own :dur must not be added on " +
                     "top of its remainder -- 240 + 120 = 360, not 600; got " +
                     first);
        return false;
    }
    return true;
}

// #108's honesty criterion, as a test rather than a promise. Gates carry no
// :dur, so the figure is a lower bound; "session", "total" and "remaining"
// would each make it read as a true session total, which is the one thing it
// provably is not.
(:test) function test_lay_workLeftCaptionIsAnHonestLowerBound(logger) {
    var s = StrongRowView.workLeftCaption("18:20");
    if (s.find("work left") == null) {
        logger.error("#108: the caption must contain 'work left' -- it is the " +
                     "honesty qualifier, and a bare figure fails the " +
                     "criterion. Got '" + s + "'");
        return false;
    }
    if (s.find("18:20") == null) {
        logger.error("#108: the caption must carry the figure it captions; " +
                     "got '" + s + "'");
        return false;
    }
    var banned = [ "session", "total", "remaining" ];
    for (var i = 0; i < banned.size(); i++) {
        if (s.find(banned[i]) != null) {
            logger.error("#108: the caption must not contain '" + banned[i] +
                         "' -- gates carry no :dur, so this figure is a LOWER " +
                         "BOUND and that word would present it as a session " +
                         "total. Got '" + s + "'");
            return false;
        }
    }
    return true;
}

// The strip removes the REC footer from the work view and that cost is
// accepted. A HARD FAILURE is not part of the bargain.
//
// NO_ACCEL is #108's own acceptance criterion. NO_REC is a listed departure
// from its element table, argued at the static: it is reachable during work
// through an unconfirmed resume, and it is exactly #74 -- a row that looks like
// it is recording and produces no FIT file.
(:test) function test_lay_workFooterSurvivesForHardFailuresOnly(logger) {
    var keep = [ $.FOOT_NO_ACCEL, $.FOOT_NO_REC ];
    for (var i = 0; i < keep.size(); i++) {
        if (!StrongRowView.workFootVisible(true, keep[i])) {
            logger.error("#108: footer state " + keep[i] + " is a HARD FAILURE " +
                         "and must stay visible during work -- with no " +
                         "accelerometer the stroke rate is meaningless, and a " +
                         "failed recording is #74");
            return false;
        }
    }
    var drop = [ $.FOOT_PAUSED, $.FOOT_REC, $.FOOT_IDLE ];
    for (var j = 0; j < drop.size(); j++) {
        if (StrongRowView.workFootVisible(true, drop[j])) {
            logger.error("#108: footer state " + drop[j] + " must NOT be drawn " +
                         "during work -- REC is the element the strip removes, " +
                         "PAUSED is already the title, and IDLE cannot occur " +
                         "inside a step");
            return false;
        }
    }
    return true;
}

// Off the work view nothing changes: every state still draws.
(:test) function test_lay_footerIsUntouchedOffTheWorkView(logger) {
    var all = [ $.FOOT_NO_ACCEL, $.FOOT_NO_REC, $.FOOT_PAUSED, $.FOOT_REC,
                $.FOOT_IDLE ];
    for (var i = 0; i < all.size(); i++) {
        if (!StrongRowView.workFootVisible(false, all[i])) {
            logger.error("#108: REST, GATE, WARM, COOL, DONE, the pre-START " +
                         "screen and free row keep the footer in every state; " +
                         "state " + all[i] + " was suppressed");
            return false;
        }
    }
    return true;
}

// -- c2: the differentials, and two guards that ride with them -----------------
// Seven cases. FIVE are RED against the commit that adds them and green against
// the one that splits the layout; the section is labelled honestly rather than
// generously, because the other TWO are green in BOTH epochs:
//
//   test_lay_workViewStillShowsNoAccel
//   test_lay_workViewStillShowsAFailedRecording
//
// Those two are not differentials. Today the footer is drawn unconditionally,
// so they pass before the change; they exist to red if the strip goes TOO FAR
// and takes the hard failures with it, which is the failure the differentials
// above them make possible. They sit here rather than in the c1 section because
// they are only meaningful next to the case that removes the footer, and
// nothing is gained by scattering the pair.
//
// Together they are the whole of #108's acceptance list that a font-free case
// can see: WHICH elements the work view draws. What they cannot see -- whether
// the result is more legible at a glance, and whether anything overlaps -- is a
// wrist judgement and a font measurement respectively, and neither is claimed
// anywhere in this file.

// The maintainer's constraint, in their words: "the work interval #, speed and
// distance are nice, but I have a fraction of a second to glance between
// strokes and want the cleanest info. The other ones are useful at rest breaks."
//
// Three groups come off the work view and each gets its own case, so a partial
// strip names which half it did.
(:test) function test_lay_workViewDropsTheStatusPips(logger) {
    var d = wlRender(wlProbeAt(new HrProbe().kindWork()));
    var pips = [ "GPS", "RR", "CT" ];
    for (var i = 0; i < pips.size(); i++) {
        if (wlDrew(d, pips[i])) {
            logger.error("#108: the work view must not draw the " + pips[i] +
                         " status pip. It competes with the two elements the " +
                         "rower is actually reading, and #98 is open on the CT " +
                         "pip reporting pod freshness rather than whether CORE " +
                         "data is reaching the file. Drew:\n" + d.textLog());
            return false;
        }
    }
    return true;
}

(:test) function test_lay_workViewDropsThePaceRow(logger) {
    var d = wlRender(wlProbeAt(new HrProbe().kindWork()));
    if (wlDrew(d, "/500m")) {
        logger.error("#108: the work view must not draw the pace and " +
                     "metres-per-stroke row -- those are rest-break numbers. " +
                     "Removing it is also what buys the room the widened arc " +
                     "sweep needs. Drew:\n" + d.textLog());
        return false;
    }
    return true;
}

// The REC footer goes, and the cost is real: mid-interval there is no recording
// assurance on the screen. Accepted as a decision on #108, not an oversight,
// and the two cases after this one are what keeps the acceptance narrow.
(:test) function test_lay_workViewDropsTheRecFooter(logger) {
    var d = wlRender(wlProbeAt(new HrProbe().kindWork()));
    if (wlDrew(d, "REC ")) {
        logger.error("#108: the work view must not draw the REC footer. Drew:\n" +
                     d.textLog());
        return false;
    }
    return true;
}

// #108 section B. The figure is the sum of remaining :dur over the current and
// all future steps, and it MUST carry its caption -- a bare number would read
// as a session total, which it provably is not.
(:test) function test_lay_workViewShowsTheLabelledWorkLeftFigure(logger) {
    var d = wlRender(wlProbeAt(new HrProbe().kindWork()));
    if (!wlDrew(d, "work left")) {
        logger.error("#108: the work view must draw the work-left figure WITH " +
                     "its caption. Warm-up, gates and cool-down carry no :dur, " +
                     "so the number is a lower bound and the words 'work left' " +
                     "are what say so. Drew:\n" + d.textLog());
        return false;
    }
    var banned = [ "session", " total", "remaining" ];
    for (var i = 0; i < banned.size(); i++) {
        if (wlDrew(d, banned[i])) {
            logger.error("#108: the work view must not present that figure as " +
                         "'" + banned[i] + "' -- total session time is not " +
                         "computable, because a gate can sit unfinished for an " +
                         "unbounded time. Drew:\n" + d.textLog());
            return false;
        }
    }
    return true;
}

// #108's explicit exception, and the reason it is explicit: with no
// accelerometer the stroke rate is meaningless, so the one numeral the stripped
// work view exists to show is a lie. A hard failure is not part of the bargain
// the REC footer's removal struck.
(:test) function test_lay_workViewStillShowsNoAccel(logger) {
    var p = wlProbeAt(new HrProbe().kindWork());
    p.setSensorOk(false);
    var d = wlRender(p);
    if (!wlDrew(d, "NO ACCEL")) {
        logger.error("#108: NO ACCEL must stay visible during work. It is a " +
                     "hard failure -- with no accelerometer the stroke rate " +
                     "this screen is built around means nothing. Drew:\n" +
                     d.textLog());
        return false;
    }
    return true;
}

// The second hard failure, and a listed departure from #108's element table
// argued at StrongRowView.workFootVisible. It is reachable during work through
// a resume that isRecording() could not confirm, and it is exactly #74: a row
// that looks like it is recording and produces no FIT file. Suppressing it on
// the screen the athlete spends most of the session on would re-create that
// issue in a new place.
(:test) function test_lay_workViewStillShowsAFailedRecording(logger) {
    var p = wlProbeAt(new HrProbe().kindWork());
    p.setRecFailed(true);
    var d = wlRender(p);
    if (!wlDrew(d, "NOT RECORDING")) {
        logger.error("#108/#74: a failed recording must stay visible during " +
                     "work. mRecFailed is raised by a resume isRecording() " +
                     "could not confirm, and a row that looks like it is " +
                     "recording and writes no FIT file is worse than a crash, " +
                     "because a crash is visible. Drew:\n" + d.textLog());
        return false;
    }
    return true;
}

// PAUSED needs no footer of its own during work: the title already carries it,
// which is why #108 lists only NO ACCEL as the state that must survive. This is
// the case that keeps the two hard-failure cases above from being satisfied by
// simply restoring the whole footer.
(:test) function test_lay_pausedWorkViewDrawsNoFooterButKeepsTheTitle(logger) {
    var p = new HrProbe();
    p.driveStrokes();
    p.setSensorOk(true);
    p.enterStep(p.kindWork(), true);
    p.setNarrowSession();
    var d = wlRender(p);
    // COUNTED, not merely detected. drawFoot's paused branch renders
    // "PAUSED  <n>str" and the title renders "PAUSED", so both contain the
    // word and a presence test cannot tell one from two. Exactly one is the
    // whole assertion: the title survives, the footer does not.
    var n = wlCount(d, "PAUSED");
    if (n != 1) {
        logger.error("#108: a paused work step must draw the word PAUSED " +
                     "exactly once -- as the TITLE. The footer's own paused " +
                     "line must not come back: PAUSED is already surfaced by " +
                     "the title, so restoring the footer for it would undo the " +
                     "strip for a state the rower is not rowing in. Counted " +
                     n + ". Drew:\n" + d.textLog());
        return false;
    }
    return true;
}
