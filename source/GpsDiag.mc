// ---------------------------------------------------------------------------
// gps_diag -- the POSITIONING receive-path diagnostic, and the pure decisions
// the GPS enable ladder and the status pip are built on (#211).
//
// WHY THIS EXISTS, and it is the same argument ct_diag and rr_diag were built
// on, one subsystem over. Activity i185890690 (v0.9.2, fenix 9 Pro 51 mm,
// firmware 6.38) carried position on records 0-16 of 2,625 -- 11:50:41 to
// 11:50:57 -- and on none of the rest. The watch's own native gps_metadata
// messages agree: 17, in the same window. The rower's report was "GPS is no
// longer working on this app, despite the GPS circle being green".
//
// THAT FILE CANNOT SAY WHY, and neither can this module. The candidates have
// different fixes and none of them is proven:
//
//   * the legacy enableLocationEvents form on a configuration-driven chipset;
//   * early firmware on a watch published three weeks before the row;
//   * a system power policy;
//   * an interaction with this app's other radios;
//   * the SDK's own multitasking note on enableLocationEvents, quoted in full
//     because its second clause is the load-bearing one: "Multitasking:
//     Location events will be disabled when app enters inacitve state [sic],
//     and re-enabled when is active again. These state changes are denoted by
//     calls to AppBase.onActive() and AppBase.onInactive()." As documented
//     this is a TRANSIENT, SELF-RESTORING disable, so for it to explain a
//     43-minute silence the re-enable half would have to have failed, which
//     the note does not say and nothing here has measured. This app implements
//     neither onActive nor onInactive, so it cannot currently observe the
//     transition; the watchdog covers the consequence generically and not the
//     mechanism by name.
//
// The lap marker is NOT among them: lap 1 began at 11:50:46 and the stream
// stopped at 11:50:57, eleven seconds INTO the lap rather than at its edge,
// and native total_cycles on lap 1 is 70 (~23 spm), so the accelerometer path
// was live throughout. The fenix 6 family ran the identical code for months
// without this. These counters exist to let the NEXT row decide between the
// candidates, and nothing here asserts one.
//
// EVERYTHING HERE LIVES INSIDE `module GpsDiag`, and that is a hard constraint
// rather than a taste, for the reason source/RrDiag.mc:30-36 states: the fenix6
// family caps module `globals` at 253 members and a --unit-test build of this
// repository is close to it (the CEILING note in source/RrHrvTest.mc carries
// the measurement); ~20 file-scope consts would cost ~20 members, a module
// block costs ONE between all of them. The two freshness windows below are
// inside it for the same reason, which is why they are $.GpsDiag.GPS_FRESH_MS
// rather than file-scope siblings of $.HR_FRESH_MS.
//
// SHAPE, and it follows rr_diag deliberately so a reader who has decoded one
// can decode the other: a documented slot map beside the constants, a layout
// VERSION in slot 0, counters that SATURATE at readout rather than wrap, and a
// createField `:count` that reads $.GpsDiag.SLOTS -- never a literal. A setData
// array LONGER than :count is an uncatchable System Error ("setData input array
// too long for allocated space") that kills the app at save time and takes the
// whole activity with it; that failure was MEASURED for ct_diag (simulator,
// fr965 / SDK 9.2.0) and is quoted at CoreTempSensor.diagSnapshot.
//
// WHAT NO (:test) HERE CAN SHOW, stated so nobody reads more into a green run.
// No (:test) can obtain a Session, so `createField` is unreachable from the
// suite and nothing here proves that an 11-slot session-scope UINT16 array is
// accepted, saved or decodable. Nor does anything here call
// Position.enableLocationEvents: chooseForm and nextFormFrom decide WHICH form
// to ask for, and say nothing about whether any form acquires a fix on any
// device. The [Local] issue filed with this change owns both.
//
// A LAYOUT VERSION, NOT A GUESS ABOUT THE FUTURE. Slot indices ARE the wire
// format: renumbering one without bumping VERSION silently re-keys every file
// already recorded. GpsFix.test_gps_c1_theSlotKeyIsZeroToTen nails every index
// to its literal number for exactly that reason -- ct_diag shipped three
// versions with only a prefix of its indices pinned, and a permutation confined
// to the unpinned tail would have re-keyed three slots of every file with the
// whole suite green (found in that file's round-4 review, and not repeated
// here).
// ---------------------------------------------------------------------------
module GpsDiag {

// The value stored in slot I_VERSION. Bump it for ANY change to the slot
// numbering, the slot count, or what a slot counts.
const VERSION = 1;

// The number of slots, and the ONE constant both this module's snapshot builder
// and the createField `:count` in StrongRowView read. Do not substitute a
// literal in either -- see the System Error quoted above.
const SLOTS = 11;

// The largest value any slot may carry, and it is 0xFFFE rather than 0xFFFF ON
// PURPOSE.
//
// THIS IS A DELIBERATE DEPARTURE FROM rr_diag AND ct_diag, which both clamp at
// 65535, and the reason is the FIT base type rather than taste: 0xFFFF is the
// UINT16 INVALID value, which source/StrongRowView.mc states at the RR_INVALID
// constant ("0xFFFF is the UINT16 invalid value") and relies on for
// rr_interval's no-data sentinel. A counter clamped to 0xFFFF in a UINT16
// developer field is therefore indistinguishable, to a decoder that honours
// the base type's invalid value, from a slot that was never written. Clamping
// one below it keeps every saturated slot a READABLE number.
//
// WHAT THAT COSTS, stated rather than glossed: a slot reading 65534 means "at
// least 65534", exactly as rr_diag's MAXV note says of its own ceiling. The
// difference is only that this one cannot be mistaken for absence.
//
// THIS IS NOT A CLAIM ABOUT WHAT A DECODER DOES with rr_diag's or ct_diag's
// saturated slots -- nothing in this repository decodes a file this app wrote
// (docs/agents/FACTS.md section 3.2), and those two fields are NOT changed
// here. The adjacent question is filed rather than folded in.
//
// WHEN EACH KIND OF SLOT CLAMPS, per rate, because one figure over all of them
// would be wrong:
//   the callback counters (1, 2, 3)
//       Position delivers LOCATION_CONTINUOUS events at about 1 Hz -- measured
//       only as a cadence in one recording (i185890690 carried 17 position
//       records across the 16 s window 11:50:41-11:50:57, and 17 native
//       gps_metadata messages in the same window), never as a documented rate
//       -- so a per-callback counter reaches 65534 after ~18.2 h.
//   the two SECONDS slots (4, 5)
//       65534 s is 18.2 h of row. Neither can be reached by any plausible
//       session, which is why truncation to whole seconds costs nothing here.
//   I_REARMS (6)
//       bounded by construction at one per GPS_REARM_MS, so 65534 needs 45.5
//       days of continuous staleness.
//   I_ENABLE_THROW (8)
//       one per failed rung per enable attempt: at most two per startGps().
const MAXV = 65534;

// -- the freshness windows --------------------------------------------------

// How long after the last onPosition callback the status pip keeps reporting a
// fix. Past it the pip shows the no-data colour instead of the last accuracy.
//
// 5000 ms, and both halves of that are stated because neither alone would
// justify it:
//   * the DELIVERY CADENCE. Position events arrive at about 1 Hz -- the only
//     measurement this repository has is the one quoted at MAXV above, a
//     cadence read off one recording, not a documented rate. 5000 ms is
//     therefore about five missed deliveries, which is a dropout rather than a
//     jitter.
//   * the FAMILY'S CONVENTION. RR_DISPLAY_FRESH_MS and HR_FRESH_MS are both
//     5000, so the three status indicators go grey on the same schedule and a
//     reader learns one rule rather than three. #40's split is the precedent
//     for keeping them SEPARATE CONSTANTS that happen to agree: retuning the
//     GPS pip must not move the RR pip.
//
// A COSMETIC RESPONSIVENESS CHOICE, like RR_DISPLAY_FRESH_MS and unlike
// RR_REC_FRESH_MS: nothing written to the FIT file keys on this window.
const GPS_FRESH_MS = 5000;

// How long the stream must have been silent before the watchdog re-enables
// positioning, and -- the same number in its other role -- the minimum
// interval between two re-enables.
//
// 60000 ms. What bounds it from BELOW is the risk the re-enable itself
// carries: enableLocationEvents re-arms the receiver, and a re-arm issued
// while an acquisition is in progress may reset that acquisition. Cold
// acquisition on a modern multi-band watch is tens of seconds, and THIS
// REPOSITORY HAS NOT MEASURED IT on any device -- so the interval is chosen to
// sit above the plausible range rather than derived from a number. What bounds
// it from ABOVE is the row: at 60 s a 43.8-minute session like i185890690 gets
// at most 43 attempts, and a stream that died 17 s in is retried 43 times
// rather than never.
//
// TWELVE TIMES GPS_FRESH_MS, and the two are deliberately not one constant:
// the pip must tell the rower within five seconds, and the radio must not be
// poked every five seconds. Collapsing them would force one of those two to
// give.
const GPS_REARM_MS = 60000;

// -- the slot map -----------------------------------------------------------
const I_VERSION      = 0;

// The three CALLBACK counters. Together they answer the question i185890690
// could not: did onPosition keep being called at all?
//   CB_TOTAL == 0                      the callback never fired. Read I_FORM
//                                      and I_ENABLE_THROW next.
//   CB_TOTAL ~ the session's seconds    the stream lived for the whole row.
//   CB_TOTAL small and I_LAST_CB_S
//   small                              the stream stopped early -- the shape
//                                      this field was built for.
//   CB_TOTAL > 0 with CB_USABLE == 0    callbacks arrived and never carried a
//                                      usable fix, which is a DIFFERENT
//                                      failure from delivery stopping.
const I_CB_TOTAL     = 1;   // onPosition entries, whatever they carried
const I_CB_USABLE    = 2;   // ... of which accuracy >= Position.QUALITY_USABLE
const I_CB_GOOD      = 3;   // ... of which accuracy == Position.QUALITY_GOOD

// Whole seconds from the START of the row to the LAST callback. DERIVED at
// readout from the arrival stamp and the session baseline, not accumulated --
// see StrongRowView.gpsDiagSnapshot.
//
// 0 MEANS TWO THINGS and they are separated by I_CB_TOTAL: no callback at all
// (CB_TOTAL == 0), or a last callback at or before the session baseline. Never
// read this slot without that one.
//
// THE GAP THIS SLOT DOES NOT CONTAIN is the one from the last callback to the
// END of the row, because no callback exists to record it. A reader computes
// it from the FIT's own session total_elapsed_time minus this slot -- which is
// exactly the 43.8 min minus 17 s that i185890690 would have reported.
const I_LAST_CB_S    = 4;

// The longest silence BETWEEN two callbacks, in whole seconds, measured from
// the LATER of the previous arrival and the start of the row.
//
// That baseline is not decoration, and the reason is rr_diag's (see
// I_MAXGAP_BATCH there): positioning is enabled from onLayout, the arrival
// stamp deliberately SURVIVES a session boundary, and these counters are zeroed
// at START -- so without a baseline, a silence that straddled START would be
// loaded whole into this slot and the running max would make it stick.
//
// Truncated, not rounded, so the slot never overstates the gap.
const I_MAXGAP_S     = 5;

// How many times the watchdog re-enabled positioning during this row. Bounded
// at one per GPS_REARM_MS by construction.
//   REARMS == 0 with a long I_MAXGAP_S   the stream never went stale long
//                                        enough, or no usable fix was ever seen
//                                        (the watchdog will not re-arm before
//                                        the first one -- see gpsRearmDue).
//   REARMS > 0 and callbacks RESUMED     the re-arm worked. That is the single
//                                        most informative reading this field
//                                        can produce.
const I_REARMS       = 6;

// WHICH enable form actually succeeded -- a FORM_* value below. Written by
// startGps and NOT zeroed at the session boundary, because the enable happens
// at onLayout, before any session exists; zeroing it would delete the answer
// exactly where it is needed. Same for I_ENABLE_THROW and I_FLAGS.
const I_FORM         = 7;

// How many enable attempts threw and fell through to the next rung. At most two
// per startGps() call, and it accumulates across watchdog re-arms.
const I_ENABLE_THROW = 8;

// The accuracy value carried by the LAST callback, as Position reported it
// (Position.QUALITY_* is 0..4). Read it only with I_CB_TOTAL > 0: this slot is
// zeroed at the session boundary, and 0 is also QUALITY_NOT_AVAILABLE.
//
// WRITTEN ONLY ON A NON-NULL ACCURACY, which is why a reader comparing this
// slot to I_CB_TOTAL can find them disagreeing. A callback carrying no accuracy
// at all still counts into I_CB_TOTAL, still refreshes the pip's freshness
// stamp, and leaves both this slot and mGpsQual holding the last GRADED
// reading. So a stream that degrades to delivering accuracy-free callbacks
// keeps the pip on a grade no live callback carried -- bounded by
// GPS_FRESH_MS, not by the length of the degradation, and pinned as the
// shipped latch by the c0 null-accuracy case. Found in round 1 review.
const I_LAST_ACC     = 9;

const I_FLAGS        = 10;

// -- flag bits of I_FLAGS ---------------------------------------------------
// All three are read in startGps, at the moment the form is chosen, and are not
// latched afterwards -- the capabilities of a device do not change within a
// run. They survive the session boundary with I_FORM, for the same reason.
//
// THE FIRST TWO ARE SEPARATE ON PURPOSE. "The API is absent" and "the API is
// present and said no" are different facts about a device, and a single bit
// would conflate them -- which is precisely the discrimination the fenix 9
// question needs, since its device definitions declare nothing but SatIQ modes
// while hasConfigurationSupport's own documented device list (SDK 9.2.0,
// doc/Toybox/Position.html) predates the family and does not name it.
const F_CFG_API   = 1;   // Position has :hasConfigurationSupport
const F_SATIQ_OK  = 2;   // ... and hasConfigurationSupport(SAT_IQ) returned true
const F_CONST_API = 4;   // the three CONSTELLATION_* symbols are all present

// -- the enable forms -------------------------------------------------------
// The VALUES ARE THE WIRE FORMAT of slot I_FORM. Do not renumber without
// bumping VERSION.
//
// NONE is 0 so that an untouched slot reads as "no form succeeded", which is
// the honest answer for a row whose every rung threw.
const FORM_NONE   = 0;
const FORM_LEGACY = 1;   // enableLocationEvents(LOCATION_CONTINUOUS, cb)
const FORM_CONST  = 2;   // the options dictionary with :constellations
const FORM_CONFIG = 3;   // the options dictionary with :configuration

// Pure: which enable form to ask for FIRST, given what the device can do.
//
// The order is most-specific-first, which is the order Garmin's own example in
// doc/Toybox/Position.html uses: the configuration form where the device
// reports configuration support, the constellation list where it does not, and
// the legacy single-argument call where neither is available.
//
// TAKES BOOLEANS, NOT THE Position MODULE, so the decision is reachable from a
// (:test) with no GNSS chipset and no device -- the same reason
// StrongRowView's filterRr, rrIsFresh and coreFieldsWanted are statics. The
// two capability reads live in StrongRowView.gpsCapSatIq and
// gpsCapConstellations, which a probe overrides.
function chooseForm(satIqOk, constOk) {
    if (satIqOk) { return FORM_CONFIG; }
    if (constOk) { return FORM_CONST; }
    return FORM_LEGACY;
}

// Pure: the next rung down after `form` threw, or FORM_NONE when the ladder is
// exhausted.
//
// TAKES constOk TOO, so a device with no CONSTELLATION_* symbols skips that
// rung instead of attempting a call that cannot work and charging the attempt
// to I_ENABLE_THROW. A throw counter that also counted "did not try" would
// make the slot unreadable.
function nextFormFrom(form, constOk) {
    if (form == FORM_CONFIG) { return constOk ? FORM_CONST : FORM_LEGACY; }
    if (form == FORM_CONST)  { return FORM_LEGACY; }
    return FORM_NONE;
}

// Clamp a counter into the range this field can carry, once, at readout -- so
// the receive path carries no saturation test. Mirrors RrDiag.clamp, including
// the null and negative guards, because a snapshot must never hand setData
// something the field cannot hold. The ceiling differs; see MAXV.
function clamp(v) {
    if (v == null) { return 0; }
    if (v < 0)     { return 0; }
    if (v > MAXV)  { return MAXV; }
    return v;
}

// Pure: whole seconds from `fromMs` to `toMs`, clamped into the slot range.
//
// A never-seen stamp (0) is 0 seconds, not a duration since device boot -- the
// same sentinel convention laterStamp holds for the RR gap baselines. A
// NEGATIVE difference is 0 as well rather than a wrap: it means the stamps are
// out of order (a callback before the session baseline), and 0 with
// I_CB_TOTAL == 0 beside it is already the readable answer.
//
// TRUNCATES rather than rounds, so a seconds slot never overstates its gap.
function secsBetween(fromMs, toMs) {
    // BOTH stamps carry the never-seen sentinel and BOTH are guarded. toMs
    // is mLastGpsMs at the one call site, and that is 0 for a row that got
    // no callback at all -- exactly the row this field exists to explain.
    // With a NEGATIVE session baseline (System.getTimer() is negative for
    // 25 of every 50 days of uptime) `0 - fromMs` is positive, so the
    // `d < 0` guard below does not fire and the slot would report
    // |fromMs| / 1000, clamped at MAXV. That is a fabricated duration, not
    // a measurement, and it lands on the mute row specifically.
    if (fromMs == 0 || toMs == 0) { return 0; }
    var d = toMs - fromMs;
    if (d < 0) { return 0; }
    return clamp(d / 1000);
}

// A fresh, all-zero counter array with the layout version already in slot 0.
// Called once at construction, so the allocation is off every hot path.
function newCounters() {
    var a = new [SLOTS];
    for (var i = 0; i < SLOTS; i++) { a[i] = 0; }
    a[I_VERSION] = VERSION;
    return a;
}

// Zero the SESSION-SCOPED slots in place and leave the rest alone.
//
// WHICH SLOTS SURVIVE IS THE WHOLE POINT OF THIS FUNCTION, and it is a function
// rather than six lines in startSession so that the answer exists in exactly
// one place and a (:test) can call it. The ct_diag lesson is that counters
// running from onLayout cannot tell before-START from during, so the receive
// path is zeroed here; the ENABLE happens at onLayout and is the one thing a
// reader of a mute row needs most, so I_FORM, I_ENABLE_THROW and I_FLAGS are
// deliberately NOT zeroed.
//
// I_LAST_CB_S is absent from both lists because it is DERIVED at readout from
// the arrival stamp and the session baseline (see gpsDiagSnapshot); it is never
// accumulated into the array at all.
function resetSession(a) {
    a[I_CB_TOTAL]  = 0;
    a[I_CB_USABLE] = 0;
    a[I_CB_GOOD]   = 0;
    a[I_MAXGAP_S]  = 0;
    a[I_REARMS]    = 0;
    a[I_LAST_ACC]  = 0;
    return a;
}

}
