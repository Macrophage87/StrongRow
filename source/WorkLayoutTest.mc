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
