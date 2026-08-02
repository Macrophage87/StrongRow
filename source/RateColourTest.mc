using Toybox.Test;
using Toybox.Graphics as Gfx;

// Unit tests for issue #107: the stroke-rate colour is binary, so orange says
// "outside the band" without saying WHICH WAY to correct -- rowing 14 and
// rowing 22 render identically, and correcting the wrong way costs a full
// stroke cycle to discover.
//
// The decision used to be an inline expression inside onUpdate(dc), which no
// (:test) can reach: it needs a Dc and a fully-built view. It is therefore
// extracted into the pure class-scope static StrongRowView.rateColour(), the
// same seam RrRecordTest.mc uses for filterRr/packRr/rrIsFresh/rrGapExceeded
// and CoreFieldGateTest.mc uses for coreFieldsWanted.
//
// SCOPE, stated rather than implied: these tests pin the PREDICATE, not the
// call site. The `type == STEP_WORK` comparison in onUpdate is covered by
// review only -- a regression that swapped it for STEP_REST would leave every
// test in this file green. Same caveat as CoreFieldGateTest.mc, and the reason
// the first parameter is a boolean is documented at the function itself
// (STEP_WORK is a class `hidden const`, i.e. an instance member, so a static
// cannot resolve it).
//
// Execution note: the run-tests CI job runs these headlessly in the simulator
// on every PR (`monkeydo <prg> fr965 -t`, judged by a fail-closed parser),
// with the test names pinned in scripts/expected_tests.txt -- update that
// file in the same commit as any (:test) change here. See docs/CI.md.

// -- Fixture ------------------------------------------------------------------
// One band, used by every case, matching the shipped defaults in
// resources/settings/properties.xml (targetLo 16 / targetHi 18). Written as
// module-scope consts rather than repeated literals so a case can never
// disagree with its own band by typo.
const RC_LO = 16;
const RC_HI = 18;

// -- Epoch-invariant pins ------------------------------------------------------
// Every case below is GREEN both before and after the #107 fix. They exist to
// prove the three-way change does not disturb anything it was not meant to:
// the white states, the in-band state, and the boundary inclusivity.

// Outside STEP_WORK the numeral is white, whatever the rate. This is the
// behaviour of every non-work step (REST, WARM, GATE, COOL, DONE) and of the
// whole free-row path, and #107 explicitly does not change it.
(:test) function test_rate_whiteOutsideWork(logger) {
    var c = StrongRowView.rateColour(false, 17.0, $.RC_LO, $.RC_HI);
    if (c != Gfx.COLOR_WHITE) {
        logger.error("a rate outside STEP_WORK must stay white; got " + c +
                     " (COLOR_WHITE is " + Gfx.COLOR_WHITE + ")");
        return false;
    }
    return true;
}

// THE no-data guard. drawRate renders "--.-" for rate <= 0.0, so 0.0 means
// "nothing measured yet", NOT "rowing very slowly". Colouring it as below-band
// would be the same defect class as the 0.0 skin temperature in #86 -- a
// sentinel rendered as a reading. Pinned from the refactor commit onward so
// the three-way change cannot introduce it.
(:test) function test_rate_whiteWhenNoData(logger) {
    var c = StrongRowView.rateColour(true, 0.0, $.RC_LO, $.RC_HI);
    if (c != Gfx.COLOR_WHITE) {
        logger.error("a rate of 0.0 is the no-data state ('--.-') and must " +
                     "stay white, never 'below band'; got " + c);
        return false;
    }
    return true;
}

// The state the whole feature is aimed at: in band, hold. Green in both epochs.
(:test) function test_rate_greenInsideBand(logger) {
    var c = StrongRowView.rateColour(true, 17.0, $.RC_LO, $.RC_HI);
    if (c != Gfx.COLOR_GREEN) {
        logger.error("17.0 is inside 16-18 and must be green; got " + c);
        return false;
    }
    return true;
}

// Boundary inclusivity, both ends, in one case. The pre-#107 predicate is
// `rate >= lo && rate <= hi`; the post-#107 one is "neither < lo nor > hi".
// Those agree only if both edges stay IN band, so this is the case that pins
// the fix did not quietly shift a boundary by one.
(:test) function test_rate_greenAtBothEdges(logger) {
    var lo = StrongRowView.rateColour(true, 16.0, $.RC_LO, $.RC_HI);
    var hi = StrongRowView.rateColour(true, 18.0, $.RC_LO, $.RC_HI);
    if (lo != Gfx.COLOR_GREEN || hi != Gfx.COLOR_GREEN) {
        logger.error("both band edges are INSIDE the band: lo-edge -> " + lo +
                     ", hi-edge -> " + hi + ", expected " + Gfx.COLOR_GREEN);
        return false;
    }
    return true;
}

// Phrased as a negative so it survives the epoch change: whatever colour
// out-of-band takes, it must be neither white (which would erase the signal
// entirely) nor green (which would invert it). Green against the old orange
// and against the new blue/red alike.
(:test) function test_rate_outOfBandIsNotWhiteOrGreen(logger) {
    var below = StrongRowView.rateColour(true, 14.0, $.RC_LO, $.RC_HI);
    var above = StrongRowView.rateColour(true, 22.0, $.RC_LO, $.RC_HI);
    if (below == Gfx.COLOR_WHITE || below == Gfx.COLOR_GREEN ||
        above == Gfx.COLOR_WHITE || above == Gfx.COLOR_GREEN) {
        logger.error("out-of-band must be neither white nor green: " +
                     "below -> " + below + ", above -> " + above);
        return false;
    }
    return true;
}
