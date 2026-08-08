using Toybox.Test;

// ---------------------------------------------------------------------------
// #13 -- what core_temperature / skin_temperature record during a CORE pod
// dropout.
//
// EVERYTHING IN THIS FILE LIVES IN `module CoreDrop`, and that is a hard
// constraint rather than a taste. The fenix6 family caps module `globals` at
// 253 members and a --unit-test build of this repository is close to it; a
// file-scope (:test) costs one member each, a module block costs ONE between
// all of them. The simulator prints these cases as `CoreDrop.test_ctw_...`,
// which is the name scripts/list_tests.py emits and the name
// scripts/expected_tests.txt must therefore carry. See the ceiling note at the
// top of scripts/list_tests.py.
//
// Two helpers are REUSED from source/CoreTempSensorTest.mc rather than
// redeclared here -- `ctPayload` (build a page-0x01 payload from field values)
// and `ctAlmostEq` (null-safe float compare). Both are file-scope there, so
// they already cost their globals member; a private copy would cost a second
// one and could drift from the layout the other suite pins.
//
// THE DEFECT, at 0d69b83 source/StrongRowView.mc:1025-1030:
//
//     if (mFitCore != null) {
//         var ct = mCoreSensor.coreTemp();
//         mFitCore.setData(ct);                          // unconditional
//         if (ct > mMaxCore) { mMaxCore = ct; }
//     }
//     if (mFitSkin != null) { mFitSkin.setData(mCoreSensor.skinTemp()); }
//
// coreTemp()/skinTemp() return 0.0 when nothing is current (CoreTempSensor
// coreTempAt/skinTempAt), so a row whose pod is never acquired writes 0.0 C
// into EVERY record -- the 4109-record row #102 was filed on -- and a dropout
// mid-row writes 0.0 for as long as it lasts.
//
// WHY THIS IS NOT "SKIP THE WRITE", which is what #13's own body proposes.
// Record-scope FitContributor fields LATCH: #36 measured, byte level on
// fr965 / SDK 9.2.0, that a skipped setData re-emits the previous value on the
// next record. So after one real reading, skipping republishes 37.4 C for the
// rest of the row -- a flat, plausible trace no consumer can tell from a pod
// that stayed on. There is no per-record gap available in Monkey C at all:
// setData(NaN) lands as 0xFFC00000, which a decoder reads as a datum (#48,
// and how Garmin Connect renders it is still open in #53), and setData(null)
// is an uncatchable native error that kills the app (#48).
//
// So the two windows get OPPOSITE answers, and StrongRowView.ctTempWritable is
// the one line that keeps them apart:
//
//   * before the field has ever been written -- write nothing, so the records
//     carry the FLOAT never-set pattern rather than a fabricated 0.0 C;
//   * after a real reading has been written -- keep writing, so a dropout
//     records 0.0 C, which cannot collide with a measurement because both
//     accepted bands start above zero BY CONSTRUCTION (25-45 C core,
//     15-45 C skin). The c0 sweeps below are what pin that premise.
//
// WHAT NO TEST IN THIS FILE CAN SHOW. Nothing here touches a FIT file. These
// cases pin what the code CALLS -- which samples reach setData and which do
// not -- and say nothing about what a decoder or Garmin Connect SEES for
// either window. #150 is the [Local] decode that would measure it, with
// byte-exact pass criteria; until it reports, every claim about the never-set
// pattern for these two fields is "expected-same, unmeasured" and is hedged
// to that strength wherever it appears.
// ---------------------------------------------------------------------------
module CoreDrop {

// ===========================================================================
// c0 -- characterization pins on the SHIPPED decoders.
// ===========================================================================
// Both cases below are green on 0d69b83, before any part of this change, and
// green after it. They exist because the whole design rests on one premise --
// 0.0 C is out of band for both fields, so it can serve as a dropout marker
// that no measurement can imitate -- and that premise is a property of the
// DECODERS, not of a comment.
//
// Asserted by sweeping the raw code points THROUGH decodeCoreC / decodeSkinC
// rather than by restating CT_CORE_MIN_C and CT_SKIN_MIN_C. A test that
// re-read the constants would agree with any future edit that lowered them,
// including one that made 0.0 C an accepted reading and silently turned the
// marker into data.

// Every core code point that decodeCoreC ACCEPTS is strictly above 0.0 C.
//
// Swept over raw 0..5000 (0.00..50.00 C, the accepted 2500..4500 band with
// ~25 C of margin either side) plus the 0xFFFF sentinel, one code point at a
// time. Values above 5000 are all far above the clamp and cannot be the ones
// that reach zero, so the sweep is bounded where the question is.
(:test) function test_ctw_c0_noAcceptedCoreIsZeroOrBelow(logger) {
    var ok = true;
    for (var raw = 0; raw <= 5000; raw++) {
        var t = CoreTempSensor.decodeCoreC($.ctPayload(660, 0x0C8, raw));
        if (t != null && t <= 0.0) {
            logger.error("decodeCoreC accepted raw " + raw + " as " + t +
                         " C, which is at or below the 0.0 dropout marker -- " +
                         "#13's marker can no longer be told from a reading");
            ok = false;
        }
    }
    if (CoreTempSensor.decodeCoreC($.ctPayload(660, 0x0C8, 0xFFFF)) != null) {
        logger.error("the 0xFFFF core sentinel must stay rejected");
        ok = false;
    }
    return ok;
}

// The skin analogue, swept over the WHOLE 12-bit domain (0..4095) because it
// is small enough to cover exhaustively -- and because sext12 makes half of it
// negative, so "accepted implies above zero" is a stronger statement here than
// for core.
(:test) function test_ctw_c0_noAcceptedSkinIsZeroOrBelow(logger) {
    var ok = true;
    var accepted = 0;
    for (var raw = 0; raw < 4096; raw++) {
        var s = CoreTempSensor.decodeSkinC($.ctPayload(raw, 0x0C8, 3742));
        if (s != null) {
            accepted++;
            if (s <= 0.0) {
                logger.error("decodeSkinC accepted raw12 " + raw + " as " + s +
                             " C, at or below the 0.0 dropout marker");
                ok = false;
            }
        }
    }
    // Fail closed: a decoder that rejected EVERYTHING would satisfy the loop
    // above vacuously, and the sweep's whole job is to say what the accepted
    // set looks like.
    if (accepted == 0) {
        logger.error("decodeSkinC accepted no code point at all -- the sweep " +
                     "proved nothing about the accepted set");
        ok = false;
    }
    return ok;
}

}

module CoreDrop {

// ===========================================================================
// c1 -- green pins on the new symbols.
// ===========================================================================
// Green from the commit that introduces ctTempWritable / ctTempEverAfter /
// ctMaxCoreAfter onward, INCLUDING the commit where ctTempWritable still
// carries main's unconditional decision. They assert what must NOT move while
// the fix lands, which is why they belong here and not among the c2
// differentials.
//
// A dropout sample is the literal 0.0 that coreTempAt / skinTempAt return, so
// every case below uses 0.0 for "nothing current" and a clamp-plausible value
// for "a reading". CTW_READING is 37.42 C, the same figure #150's decode
// script writes, so a byte pattern reported there can be matched to a case
// here without a conversion step.
const CTW_READING = 37.42;
const CTW_DROPOUT = 0.0;

// A current reading is written whatever the flag says. This is the case a
// "fix" that gated on the flag alone would break, and it is the one that keeps
// the feature working at all.
(:test) function test_ctw_c1_aCurrentReadingIsAlwaysWritable(logger) {
    var ok = true;
    if (StrongRowView.ctTempWritable(false, CTW_READING) != true) {
        logger.error("the FIRST reading of a session must be written, or the " +
                     "field never carries a value at all");
        ok = false;
    }
    if (StrongRowView.ctTempWritable(true, CTW_READING) != true) {
        logger.error("a reading after an earlier write must still be written");
        ok = false;
    }
    return ok;
}

// THE LATCH TRAP, and the reason this case exists as a pin rather than as a
// paragraph. #13's own body proposes skipping setData while stale. Record-
// scope fields LATCH (#36), so after one real reading that would republish
// that reading for the rest of the row -- a flat, plausible trace no consumer
// could tell from a pod that stayed on.
//
// This is the case that reds when ctTempWritable is "tidied" to
// `return tempC > 0.0`. It is green in every epoch of this branch, which is
// the point: the trap has to be crossed deliberately, over a named failure.
(:test) function test_ctw_c1_theDropoutMarkerSurvivesTheLatchTrap(logger) {
    if (StrongRowView.ctTempWritable(true, CTW_DROPOUT) != true) {
        logger.error("a dropout AFTER a real reading must still be written: " +
                     "skipping re-emits the last value (#36), which fabricates " +
                     "a steady temperature instead of leaving a gap");
        return false;
    }
    return true;
}

// The session maximum is a running maximum: it rises with a higher sample and
// ignores a lower one.
(:test) function test_ctw_c1_theMaximumIsARunningMaximum(logger) {
    var ok = true;
    if (!$.ctAlmostEq(StrongRowView.ctMaxCoreAfter(0.0, CTW_READING), CTW_READING)) {
        logger.error("the first reading must become the maximum");
        ok = false;
    }
    if (!$.ctAlmostEq(StrongRowView.ctMaxCoreAfter(CTW_READING, 36.10), CTW_READING)) {
        logger.error("a lower sample must not lower the maximum");
        ok = false;
    }
    if (!$.ctAlmostEq(StrongRowView.ctMaxCoreAfter(CTW_READING, 38.10), 38.10)) {
        logger.error("a higher sample must raise the maximum");
        ok = false;
    }
    return ok;
}

// #13 asks whether stale reads pollute mMaxCore. They do not, and this is the
// answer as a test rather than as an argument: a dropout sample can neither
// raise the maximum nor lower an existing one, and on a podless row the
// maximum stays exactly 0.0 -- which is what keeps `mMaxCore > 0.0` in
// stopAndSave the sole and still-necessary guard against writing a bogus 0 C
// max_core_temperature.
(:test) function test_ctw_c1_aDropoutNeitherRaisesNorLowersTheMaximum(logger) {
    var ok = true;
    if (!$.ctAlmostEq(StrongRowView.ctMaxCoreAfter(CTW_READING, CTW_DROPOUT), CTW_READING)) {
        logger.error("a dropout lowered the session maximum to the marker");
        ok = false;
    }
    if (!$.ctAlmostEq(StrongRowView.ctMaxCoreAfter(0.0, CTW_DROPOUT), 0.0)) {
        logger.error("a podless row must leave the maximum at 0.0 so " +
                     "stopAndSave's `mMaxCore > 0.0` still suppresses the write");
        ok = false;
    }
    return ok;
}

// The flag latches on a real reading, never on a dropout, and never clears
// once set (startSession is the only reset).
(:test) function test_ctw_c1_everLatchesOnlyOnARealReading(logger) {
    var ok = true;
    if (StrongRowView.ctTempEverAfter(false, CTW_DROPOUT) != false) {
        logger.error("a dropout must not count as a written reading");
        ok = false;
    }
    if (StrongRowView.ctTempEverAfter(false, CTW_READING) != true) {
        logger.error("a real reading must latch the flag");
        ok = false;
    }
    if (StrongRowView.ctTempEverAfter(true, CTW_DROPOUT) != true) {
        logger.error("the flag must not un-latch on a dropout");
        ok = false;
    }
    if (StrongRowView.ctTempEverAfter(true, CTW_READING) != true) {
        logger.error("the flag must stay latched on a further reading");
        ok = false;
    }
    return ok;
}

// THE LOCKSTEP PROPERTY, over a tick sequence, calling BOTH functions the way
// onTick calls them. The flag must never be true without a write having
// happened -- if it could, a dropout marker would be licensed by a reading
// that was never recorded, and the file would carry 0.0 for a field whose
// records are otherwise never-set.
//
// Written as a sequence rather than as a truth table on purpose: the property
// is about the two functions AGREEING as state advances, which no single-call
// assertion can express. The vector mixes both windows in both orders.
(:test) function test_ctw_c1_everNeverRunsAheadOfAWrite(logger) {
    var samples = [CTW_DROPOUT, CTW_DROPOUT, CTW_READING, CTW_DROPOUT,
                   CTW_READING, 38.01, CTW_DROPOUT, CTW_DROPOUT];
    var ever   = false;
    var writes = 0;
    for (var i = 0; i < samples.size(); i++) {
        var wrote = StrongRowView.ctTempWritable(ever, samples[i]);
        if (wrote) { writes++; }
        var next = StrongRowView.ctTempEverAfter(ever, samples[i]);
        if (next && !ever && !wrote) {
            logger.error("tick " + i + ": the flag latched on a sample that " +
                         "was NOT written -- 'ever written' has run ahead of " +
                         "the writes it is supposed to describe");
            return false;
        }
        ever = next;
    }
    if (ever && writes == 0) {
        logger.error("the flag ended latched with no write in the whole run");
        return false;
    }
    return true;
}

}

module CoreDrop {

// ===========================================================================
// c2 -- the red differentials.
// ===========================================================================
// EVERY case below FAILS against the commit before the fix, where
// ctTempWritable still carries main's unconditional `return true`, and passes
// once the predicate lands. They are the only cases on this branch that move
// between those two commits; the c0 and c1 sections are green on both sides.
//
// Assertions are written so a wrong result reports as FAIL rather than ERROR:
// an ERROR says the case blew up, not which behaviour is wrong.

// THE DEFECT, at its smallest. Before this field has ever been written there
// is no previous value for the latch to re-emit, so withholding the write is
// free -- and it is the difference between a record carrying the FLOAT
// never-set pattern and a record carrying a fabricated 0.0 C.
(:test) function test_ctw_c2_theSilentPrefixWritesNothing(logger) {
    if (StrongRowView.ctTempWritable(false, CTW_DROPOUT) != false) {
        logger.error("#13: a dropout sample BEFORE any real reading must not " +
                     "be written -- there is no previous value to latch, so " +
                     "writing 0.0 here fabricates a measurement for free");
        return false;
    }
    return true;
}

// The row this issue is really about: #102's 68-minute session logged
// core_temperature = 0.0 in all 4109 records because no pod was ever
// acquired. Driven as a sequence of the length that actually happened, not as
// a single call, so the case states the outcome in the units the file is
// counted in.
(:test) function test_ctw_c2_aPodlessRowWritesNothingAtAll(logger) {
    var ever   = false;
    var writes = 0;
    for (var i = 0; i < 4109; i++) {
        if (StrongRowView.ctTempWritable(ever, CTW_DROPOUT)) { writes++; }
        ever = StrongRowView.ctTempEverAfter(ever, CTW_DROPOUT);
    }
    if (writes != 0) {
        logger.error("a podless row wrote " + writes + " samples of 0.0 C; " +
                     "#102's real row logged exactly this, 4109 records of a " +
                     "physiologically impossible temperature");
        return false;
    }
    if (ever) {
        logger.error("the flag latched on a row that never had a reading");
        return false;
    }
    return true;
}

// The whole timeline in one case: silent start, a pod, a dropout, the pod
// back. This is Session A of #150's decode script, tick for tick, so a byte
// pattern reported there lines up with an index here.
//
//   ticks  0- 9  nothing current      -> no write at all
//   ticks 10-19  37.42 C              -> written; the FIRST write of the row
//   ticks 20-29  dropped out          -> written, as the 0.0 marker
//   ticks 30-39  36.90 C              -> written
(:test) function test_ctw_c2_theFirstValueEverWrittenIsARealReading(logger) {
    var samples = new [40];
    for (var i = 0; i < 40; i++) {
        if (i < 10)      { samples[i] = CTW_DROPOUT; }
        else if (i < 20) { samples[i] = CTW_READING; }
        else if (i < 30) { samples[i] = CTW_DROPOUT; }
        else             { samples[i] = 36.90; }
    }
    var ever       = false;
    var writes     = 0;
    var firstIdx   = -1;
    var firstValue = null;
    for (var i = 0; i < 40; i++) {
        if (StrongRowView.ctTempWritable(ever, samples[i])) {
            writes++;
            if (firstIdx < 0) { firstIdx = i; firstValue = samples[i]; }
        }
        ever = StrongRowView.ctTempEverAfter(ever, samples[i]);
    }
    var ok = true;
    if (firstIdx != 10) {
        logger.error("the first write landed at tick " + firstIdx +
                     ", expected 10: every record before the first real " +
                     "reading must stay unwritten");
        ok = false;
    }
    if (!$.ctAlmostEq(firstValue, CTW_READING)) {
        logger.error("the first value ever written was " + firstValue +
                     ", expected " + CTW_READING + " -- the first thing in the " +
                     "trace must be a measurement, not a marker");
        ok = false;
    }
    if (writes != 30) {
        logger.error("wrote " + writes + " of 40 ticks, expected 30 (ticks " +
                     "10-39): the ten silent ticks are withheld and every " +
                     "tick after the first reading is written, dropout or not");
        ok = false;
    }
    return ok;
}

// setData(null) is an uncatchable native error that escapes try/catch and
// kills the app (#48), so null must never reach it.
//
// UNREACHABLE FROM TODAY'S GETTERS, stated so the case is not read as
// describing live behaviour: coreTempAt / skinTempAt return a clamp-accepted
// value or the literal 0.0, never null. This pins the guard against a future
// getter -- heatIndexAt already returns null for its absent case (#80), so a
// "make the temperature getters consistent with it" edit is a plausible next
// step, and it must not be able to reach setData through this gate.
(:test) function test_ctw_c2_nullIsNeverHandedToSetData(logger) {
    var ok = true;
    if (StrongRowView.ctTempWritable(false, null) != false) {
        logger.error("null must never be writable (never written epoch)");
        ok = false;
    }
    if (StrongRowView.ctTempWritable(true, null) != false) {
        logger.error("null must never be writable (already written epoch): " +
                     "setData(null) is an uncatchable native error, #48");
        ok = false;
    }
    return ok;
}

}
