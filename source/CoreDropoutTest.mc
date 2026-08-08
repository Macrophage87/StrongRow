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
