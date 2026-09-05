// ---------------------------------------------------------------------------
// rr_diag -- the R-R RECEIVE-PATH diagnostic (epic #59, added to #46's scope).
//
// WHY THIS EXISTS, and it is the same argument ct_diag was built on one sensor
// over. A row recorded with v0.7.1 (activity i180658540, "8x3 choppy"; the
// athlete's note was "HRM seemed to cut in and out") carried 2,476 records, and
// 1,730 of them -- 69.9% -- repeated the PREVIOUS record's rr_interval array
// byte for byte. The longest unbroken run was 185 records; across it Garmin's
// own heart_rate field was present on 185 of 185 and varying between 101 and
// 133 bpm, so nothing in the file looks wrong. At ~120 bpm an interval is about
// 500 ms and four slots hold about two seconds of beats, so 185 seconds of the
// same four values is not data.
//
// That file CANNOT distinguish the two explanations, and they have different
// fixes:
//
//   * R-R never reached the watch. heart_rate staying live proves the strap was
//     connected and sending SOMETHING; it does not prove R-R was among it. Some
//     straps deliver HR without R-R intermittently, and Connect IQ delivers
//     R-R only through Sensor.registerSensorDataListener's heartBeatIntervals.
//   * R-R reached the watch and was not consumed -- rejected by the range gate,
//     dropped past the RR_PER_REC cap, or (the defect #46 names) simply never
//     written, so the record-scope field LATCHED the previous batch.
//
// These counters separate them, and nothing else. They must never change a
// decoded interval, a range bound, a freshness window or an rMSSD difference.
// Fixing the latch without them leaves the next row just as mute about which
// half was broken.
//
// EVERYTHING HERE LIVES INSIDE `module RrDiag`, and that is a hard constraint
// rather than a taste. The fenix6 family caps module `globals` at 253 members
// and a --unit-test build of this repository is close to it (the CEILING note
// in source/RrHrvTest.mc carries the measurement); ~30 file-scope consts would
// cost ~30 members, a module block costs ONE between all of them. That is also
// why the CT_DIAG_* block in source/CoreTempSensor.mc cannot be copied
// literally: it predates the squeeze and spends a member per constant.
//
// SHAPE, and it follows ct_diag deliberately so a reader who has decoded one
// can decode the other: a documented slot map beside the constants, a layout
// VERSION in slot 0, counters that SATURATE at readout rather than wrap, and a
// createField `:count` that reads $.RrDiag.SLOTS -- never a literal. A setData
// array LONGER than :count is an uncatchable System Error ("setData input array
// too long for allocated space") that kills the app at save time and takes the
// whole activity with it; that failure was MEASURED for ct_diag (simulator,
// fr965 / SDK 9.2.0) and is quoted at CoreTempSensor.diagSnapshot.
//
// WHAT NO (:test) HERE CAN SHOW, stated so nobody reads more into a green run.
// No (:test) can obtain a Session, so `createField` is unreachable from the
// suite and nothing here proves that a 21-slot session-scope UINT16 array is
// accepted, saved, or decodable. ct_diag's 25-slot equivalent WAS measured on
// fr965 / SDK 9.2.0, which is why this shape was chosen rather than invented --
// but a measurement of ct_diag is not a measurement of rr_diag, and 27
// developer fields is past every field-count observation this repository has
// (#77 measured eleven, #80 twelve, #154 owns the question). Treat the file
// behaviour as expected-same and unmeasured until a [Local] decode reports.
//
// A LAYOUT VERSION, NOT A GUESS ABOUT THE FUTURE. Slot indices ARE the wire
// format: renumbering one without bumping VERSION silently re-keys every file
// already recorded. test_rr_c1_diagSlotKeyIsZeroToTwenty nails every index to
// its literal number for exactly that reason -- ct_diag shipped three versions
// with only a prefix of its indices pinned, and a permutation confined to the
// unpinned tail would have re-keyed three slots of every file with the whole
// suite green (found in that file's round-4 review, and not repeated here).
// ---------------------------------------------------------------------------
module RrDiag {

// The value stored in slot I_VERSION. Bump it for ANY change to the slot
// numbering, the slot count, or what a slot counts.
const VERSION = 1;

// The number of slots, and the ONE constant both this module's snapshot builder
// and the createField `:count` in StrongRowView read. Do not substitute a
// literal in either -- see the System Error quoted above.
const SLOTS = 21;

// UINT16 ceiling. Counters are plain 32-bit Number increments -- no saturation
// test, no allocation, no branch -- and are clamped ONCE at readout, exactly as
// ct_diag does. A slot reading MAXV therefore means "at least MAXV", never a
// wrapped number.
//
// WHEN EACH KIND OF SLOT CLAMPS, per rate, because ONE figure over all of them
// was wrong. ct_diag states its two rates separately and this map copied only
// the sentence after them; round-2 review of #59 found the result.
//
//   the receive-path callback counters (1-15, 18, 19)
//       startSensor registers with :period => 1, so a per-callback counter
//       reaches 65535 after 65535 s ~ 18.2 h. The per-BEAT counters in that
//       range advance faster: at 120 bpm that is 2/s, so ~32,768 s ~ 9.1 h.
//   I_REC_STAGED (16) and I_REC_INVALID (17)
//       NOT on the receive path. They are incremented in StrongRowView's
//       onTick, which runs on the TICK_MS = 250 timer, so each advances at
//       4 Hz while started and unpaused and clamps after 65535/4 = 16,383.75 s
//       ~ 4.55 h of recording.
//
// AND ct_diag's EXCLUSION, which this map dropped and needs more than ct_diag
// did: "Only quantitative ratios degrade there." Most discriminations here turn
// on zero versus non-zero and survive any session length, but TWO do not, and
// they are named rather than left for a reader to notice:
//   * the 16:17 ratio documented at I_REC_STAGED below -- once either slot
//     clamps the ratio is unrecoverable and each slot reads "at least";
//   * the BEATS partition equality documented at I_BEATS -- it stops closing as
//     soon as any of the five slots in it clamps.
const MAXV = 65535;

// -- the slot map -----------------------------------------------------------
const I_VERSION      = 0;

// The two callback-level counters. Together they answer the question the row
// above could not: did the platform deliver R-R at all?
//   SENSOR_CB == 0            the sensor listener never fired (or R-R was never
//                             registered -- read F_RR_REGISTERED).
//   HR_ABSENT == SENSOR_CB    it fired every second and NEVER carried heart-rate
//                             data. That is "the strap sent HR without R-R", or
//                             sent neither; a live native heart_rate field in
//                             the same file then means the watch's own HR
//                             pipeline had a reading this app's listener did not.
const I_SENSOR_CB    = 1;   // onSensorData entries while mRrOk
const I_HR_ABSENT    = 2;   // ... of which carried no heartRateData

// Batch-level. BATCH_NULL and BATCH_EMPTY are handleRrAt's two early returns,
// counted separately because they are different platform behaviours: a null
// heartBeatIntervals member and a present-but-empty array.
const I_BATCH_NULL   = 3;
const I_BATCH_EMPTY  = 4;
const I_BATCH_OK     = 5;   // batches carrying at least one element

// Beat-level. BEATS is every element examined; the four below partition it
// exactly -- BEAT_ACCEPT + REJ_NULL + REJ_LOW + REJ_HIGH == BEATS, which is a
// consistency check a reader can run on the file itself, and which stops
// closing as soon as any of the five clamps (see the rate table at MAXV).
const I_BEATS        = 6;
const I_BEAT_ACCEPT  = 7;   // rrAccept returned A_OK (RANGE-accepted)
const I_REJ_NULL     = 8;   // the element was null
const I_REJ_LOW      = 9;   // below RR_MIN_MS after toNumber -- a split beat
const I_REJ_HIGH     = 10;  // above RR_MAX_MS after toNumber -- a SUM of beats

// Difference-level: the second gate, which only the rMSSD path applies.
const I_DIFF_ACCEPT  = 11;  // stored in the mDiffSq ring
const I_DIFF_REJ_ART = 12;  // rejected by RR_ART_K

// Adjacency and ring events.
const I_ADJ_GAP      = 13;  // inter-batch gap reset of mRrLast (#16)
const I_ADJ_INTRA    = 14;  // intra-batch adjacency break (#37)
const I_RING_CLEAR   = 15;  // gap clears that discarded at least one entry (#39)

// What the rr_interval field was actually asked to record. STAGED + INVALID is
// the number of setData calls on that field, and the ratio is a PROXY for the
// defect the row above showed -- the number to read FIRST on the next choppy
// row, with two caveats that keep it a proxy rather than a measurement.
//
//   * THESE COUNT TICK-LEVEL setData CALLS, at 4 Hz, while a FIT record commits
//     only the LAST write in its ~1 s window. The branch's own
//     test_rr_c2_theRecordFieldIsWrittenOnEveryTick pins exactly that: three
//     writes inside one record window, and "a record committing between writes
//     would carry whatever the last write left behind". So the tick ratio
//     equals the RECORD ratio only for dropouts that are long relative to a
//     record -- which the measured runs above (5 s, 30 s, 185 s) are, and a
//     one-tick flicker is not. The 1,730-of-2,476 figure above is a count of
//     RECORDS; this pair is a count of CALLS. They are not the same quantity.
//   * PAST ~4.55 h either slot may read MAXV (see the rate table at MAXV), at
//     which point the ratio is unrecoverable and each slot must be read as "at
//     least", never as a fraction.
const I_REC_STAGED   = 16;
const I_REC_INVALID  = 17;

// Longest observed gaps, in WHOLE SECONDS. Seconds rather than milliseconds
// because a UINT16 of milliseconds saturates at 65.5 s, which is shorter than
// the 185 s run this field exists to measure; in seconds the same slot reaches
// 18 h. Truncated, not rounded, so the slot never overstates the gap.
//
// TWO gaps, not one, and the pair is the discrimination: BATCH is the gap
// between arrivals of any non-empty batch, BEAT the gap between RANGE-accepted
// beats. BATCH small with BEAT large means batches kept arriving and carried
// nothing usable; both large means delivery stopped.
//
// BOTH ARE MEASURED FROM THE LATER OF their own previous stamp and THE START OF
// THE ROW. That baseline is not decoration: the receive path runs from onLayout
// onward and its two arrival stamps deliberately SURVIVE a session boundary,
// while these counters are zeroed at startSession -- so without it, a silence
// that straddled START, or one that fell between two rows of a single app run,
// was loaded whole into these two slots and the running max made it stick. A
// reader would then have read a delivery failure the row never had, which is
// the opposite of the discrimination above. Found in round-2 review of #59;
// the baseline is StrongRowView's mRrGapBaseMs, written by rrDiagSessionReset
// and by nothing else.
//
// One consequence, stated because it is a change rather than a side effect: a
// row whose FIRST batch arrives well after START now records that opening
// silence, where before both slots would have read 0 for want of a reference.
// 0 there would have said "no gaps" about a row that had nothing else.
const I_MAXGAP_BATCH = 18;
const I_MAXGAP_BEAT  = 19;

const I_FLAGS        = 20;

// -- flag bits of I_FLAGS ---------------------------------------------------
// The first two are read at readout, not latched, because both are set
// synchronously in startSensor and never change afterwards.
const F_RR_REGISTERED = 1;   // registerSensorDataListener accepted heartBeatIntervals
const F_SENSOR_OK     = 2;   // a sensor listener of either shape was registered

// #70. The SIGN of System.getTimer() at the moment START was pressed.
//
// LATCHED, unlike the two above, and that is forced rather than chosen: this
// records a property of ONE instant -- session start -- and the counter moves
// afterwards, so reading it at stopAndSave would answer a different question.
// StrongRowView.rrDiagSessionReset is the only writer.
//
// WHY A BIT AT ALL. System.getTimer() is a signed 32-bit millisecond count from
// DEVICE start, so between 24.855 and 49.71 days of uptime every stamp the app
// takes is negative. Activity i183553852 (v0.9) was rowed inside that band and
// showed the consequence -- rr_diag REC_STAGED = 0 with REC_INVALID = 13335
// while BEAT_ACCEPT = 1597 -- but the file could only be read that way by
// INFERENCE, from the device's uptime. This bit makes the next such row say so
// directly.
//
// WHAT IT DOES NOT SAY, stated because a diagnostic that is over-read is worse
// than none: it is the sign at START only. A row that STRADDLES the wrap (a
// one-minute-in-49.7-days event) reads exactly as one that did not, and this
// change does not fix that crossing -- see #70.
const F_CLOCK_NEG     = 4;   // System.getTimer() was NEGATIVE at session start

// -- rrAccept's classification codes ----------------------------------------
// These live HERE, beside the counters they feed, and that placement is the
// point rather than an accident: the reject taxonomy IS the diagnostic's
// taxonomy, and a predicate and a counter map that could disagree about what
// "rejected low" means would make the field say something the code did not do.
//
// The three reject classes are NOT justified identically, and the difference
// matters to whoever reads a row: a sub-RR_MIN_MS element is a FALSE BEAT
// SPLITTING one true interval, so its two neighbours are two halves of one
// interval; an over-RR_MAX_MS element is a SUM of real intervals across missed
// beats, so its flanking survivors are genuine but not adjacent. Both break
// adjacency (#37), for opposite reasons.
const A_OK   = 0;
const A_NULL = 1;
const A_LOW  = 2;
const A_HIGH = 3;

// The RrDiag.I_REJ_* slot for a rrAccept code, or I_BEAT_ACCEPT for A_OK. One
// mapping, so the counter a reject lands in cannot drift from the code the
// predicate returned.
function slotFor(code) {
    if (code == A_NULL) { return I_REJ_NULL; }
    if (code == A_LOW)  { return I_REJ_LOW; }
    if (code == A_HIGH) { return I_REJ_HIGH; }
    return I_BEAT_ACCEPT;
}

// Clamp a counter into the UINT16 range, once, at readout -- so the receive
// path carries no saturation test. Mirrors CoreTempSensor.ctDiagClamp,
// including the null and negative guards, because a snapshot must never hand
// setData something the field cannot hold.
function clamp(v) {
    if (v == null) { return 0; }
    if (v < 0)     { return 0; }
    if (v > MAXV)  { return MAXV; }
    return v;
}

// A fresh, all-zero counter array with the layout version already in slot 0.
// Called once per session (startSession) and once at construction, so the
// allocation is off every hot path.
function newCounters() {
    var a = new [SLOTS];
    for (var i = 0; i < SLOTS; i++) { a[i] = 0; }
    a[I_VERSION] = VERSION;
    return a;
}

}
