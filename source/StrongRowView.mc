using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Sensor;
using Toybox.Position;
using Toybox.System;
using Toybox.Math;
using Toybox.Timer;
using Toybox.Attention;
using Toybox.Activity;
using Toybox.ActivityRecording as Rec;
using Toybox.FitContributor as Fit;
using Toybox.Application as App;
using Toybox.Lang;

//
// StrongRow - strength-focused rowing app that derives stroke rate from the raw wrist
// accelerometer at ~25 Hz, tuned for LOW rates and shown to a tenth of a spm.
//
// Stroke detection works on the SIGNED band-passed signal of the dominant
// accelerometer axis (not the rectified magnitude): the drive and the recovery
// produce opposite-going lobes there, so only one of them is a positive peak.
// On top of that, an autocorrelation estimate of the true cycle period gates
// the peak detector, so the mid-cycle recovery surge cannot be counted as a
// second stroke (the bug that made v1 read ~2x the real rate).
//
// GPS is enabled for the whole session, so the FIT file carries position,
// speed and distance; the display shows the /500 m split and metres per
// stroke, and both stroke rate and distance-per-stroke are written to the FIT
// as developer fields.
//
// R-R / HRV: beat-to-beat intervals from the active heart-rate source are
// logged explicitly to the FIT (raw rr_interval arrays per record, a rolling
// artifact-filtered rMSSD per record, and a session-average rMSSD), without
// depending on the watch's "Log HRV" device setting.
//
// Optional built-in interval workout (default 5 x 4:00 at 16-18 spm, 2:00
// rest, press-START gate after each rest) wrapped in untimed WARM UP and
// COOL DOWN steps that only advance on a START press - so launching and
// docking are recorded without eating into the intervals. Everything is
// configurable from the Connect IQ app settings in Garmin Connect.
//
// Note: only the watch accelerometer is available - Connect IQ cannot read an
// external chest strap's accelerometer (HRM 600 etc.), so stroke detection is
// wrist-based.
//
// R-R / HRV constants shared between StrongRowView and its static, (:test)-able
// helpers filterRr()/packRr(). At module (global) scope because a Monkey C class
// `const` is an instance member -- unreachable from a static method or via the
// class name -- whereas a module const resolves from static, instance, and test
// code alike.
const RR_MIN_MS  = 250;    // physiological beat interval range (ms), inclusive
const RR_MAX_MS  = 2500;
const RR_PER_REC = 4;      // raw intervals logged per FIT record
// FIT "no data" sentinel for the rr_interval field. Bound to that field's
// DATA_TYPE_UINT16 base type (0xFFFF is the UINT16 invalid value) AND to the
// field having no :scale/:offset (see mFitRr creation), so a stored 0xFFFF is
// emitted verbatim as "no data". Revisit if the base type, scale, or offset change.
const RR_INVALID = 0xFFFF;
// R-R freshness window (ms). Used both by the display "RR streaming" indicator
// (keyed off batch arrival, mLastRrMs) and by the rMSSD logging gate (keyed off
// the last RANGE-accepted beat, mLastBeatMs) so a dropout stops polluting avg_rmssd.
const RR_FRESH_MS = 5000;

// Footer states (#74). Module scope rather than class `hidden const` for the
// same reason STEP_WORK is passed to rateColour as a boolean: a static cannot
// resolve an instance member, and footState must be reachable from a (:test).
const FOOT_NO_ACCEL = 0;   // the accelerometer never came up -- nothing works
const FOOT_NO_REC   = 1;   // START was pressed and recording did NOT begin
const FOOT_PAUSED   = 2;
const FOOT_REC      = 3;
const FOOT_IDLE     = 4;   // not started yet

// ============ the STROKE-RATE OUTPUT STAGE (#149) =========================
// FOUR consts moved out of the class here -- MIN_RATE, MAX_RATE, LOCK_SNAP_K
// and FAST_NEEDS_LOCK, i.e. exactly the four declared immediately below and
// exactly the four the companion note at updateAutocorr's caller names. Written
// as an inventory rather than as a bare count because the bare count was wrong
// ("five") from the commit that introduced it, and a reader who trusts it goes
// hunting for a fifth relocated const that never existed. The #149 constants
// under the next header down are NET-NEW and were never class members.
//
// They are module (global) consts now for the reason the R-R and FOOT_* blocks
// above give: a Monkey C class `const` is
// an INSTANCE member, unreachable from a static method, and #149 requires the
// output stage's whole decision to be a pure static so a (:test) can reach it
// with plain numbers instead of through a built view and an event loop. A
// module-scope const costs nothing in the fenix6 `globals` budget -- it is
// inlined (measured; see the ceiling note at the top of scripts/list_tests.py).
//
// The VALUES are unchanged from the class consts they replace.
const MIN_RATE = 6.0;             // slowest period the detector will accept
const MAX_RATE = 40.0;            // hard ceiling on anything that reaches the file
const LOCK_SNAP_K = 0.30;         // a locked rate deviating more snaps to the lock
const FAST_NEEDS_LOCK = 30.0;     // the ABSOLUTE no-lock gate, in spm

// ---- the RELATIVE no-lock gate (#149) ------------------------------------
// THE DEFECT, as measured on the two decoded rows and recorded in #149:
// FAST_NEEDS_LOCK is an absolute threshold guarding an error -- a doubled
// stroke period -- that is RELATIVE to the athlete.
//
//     row            baseline    30.0 in units of this rower's own rate
//     calm 4x15'     20.3 spm    1.48x
//     choppy 8x3'    15.2 spm    1.98x
//
// A 20 spm rower was guarded at 1.5x; a 15 spm rower only past a full doubling.
// The weakest guard went to the low-rate work this app exists for.
//
// LOCK_REF_RATE is the rate the absolute constant was IMPLICITLY calibrated at,
// and LOCK_REL_K is the multiple that follows from it. Written as two constants
// with the identity FAST_NEEDS_LOCK == LOCK_REL_K * LOCK_REF_RATE stated
// (and pinned, in source/LockGuardTest.mc) rather than as a bare 1.5, so the
// provenance of the number survives the next reader.
const LOCK_REF_RATE = 20.0;
const LOCK_REL_K    = 1.5;        // == FAST_NEEDS_LOCK / LOCK_REF_RATE

// A FLOOR under the relative gate, and it is a safety device rather than a
// tuning knob. The gate ZEROES a reading, and a zeroed reading does not feed
// the baseline (see nextRateBase), so a baseline that has drifted far below the
// rate the athlete is about to row at could otherwise reject every reading of
// the next interval with nothing able to lift it back. The recorded workout is
// 8 x 3' with 2' rests and the rests ARE rowed, so a baseline at rest cadence
// meeting a work interval is the ordinary case, not an edge case.
//
// 20.0 spm is LOCK_REF_RATE: at or below the rate the absolute constant was
// calibrated at, the gate stops tracking down and holds where a 20 spm rower's
// guard has always been. It binds only for baselines under
// LOCK_GATE_FLOOR / LOCK_REL_K = 13.33 spm; #149's worked example (a 15 spm
// rower, gated at 22.5) is above it and is unaffected.
const LOCK_GATE_FLOOR = 20.0;

// THE ESTABLISHED-RATE BASELINE, in spm, updated once per REGISTERED STROKE --
// never per call and never per tick. outputRate() is called several times a
// frame (the FIT write, distPerStroke, correctiveRate, the numeral, the cue),
// so a baseline advanced from there would have a time constant set by how many
// consumers happened to read it. One update per stroke is a physical clock the
// call graph cannot retune.
//
// TWO RATES, and the asymmetry is the whole design:
//   * LOCK_BASE_A_OK  applies when the guard ACCEPTED the reading. Fast enough
//     (a ~4-stroke time constant) that an ordinary ramp keeps its own gate
//     ahead of it: the gate only fires when the reading jumps past
//     LOCK_REL_K x baseline in a single step of a FIVE-PERIOD MEDIAN, which
//     needs three of the last five periods to have halved -- the phantom-burst
//     signature, not a ramp.
//   * LOCK_BASE_A_REJ applies when the guard REJECTED it, and exists so
//     rejection can never be permanent. A genuinely sustained step up (a racing
//     start from a low paddle) lifts the baseline slowly until it is accepted;
//     a 26 s burst -- the longest excursion #149 measured -- does not last long
//     enough to. Without it the guard has a deadlock: reject, so the baseline
//     never moves, so reject.
//
// NEITHER FIGURE IS MEASURED ON THE WATER. They are chosen so the two
// behaviours above hold arithmetically, and #149 cannot validate them until the
// lock-state diagnostics land and one more row is recorded. Do not quote them
// as tuned.
const LOCK_BASE_A_OK  = 0.25;
const LOCK_BASE_A_REJ = 0.02;

// ---- the LOCK-STATE DIAGNOSTICS (#149) -----------------------------------
// #149's own words: "whether the lock was even up during these excursions is
// exactly what I cannot tell from the recordings", and every account of the
// over-reads -- including the one the change above rests on -- is inference
// until it can be. Three record-scope fields answer it from one more row.
//
// WHAT "NO LOCK" IS WRITTEN AS, decided deliberately rather than by omission,
// because RECORD-SCOPE FIELDS LATCH: once setData has been called even once, a
// record committing without a new setData RE-EMITS the last value (#36,
// byte-level, fr965 / SDK 9.2.0; reconfirmed by #48's probe_skip). So
// WITHHOLDING A WRITE DOES NOT PRODUCE A GAP -- it fabricates a lock that was
// not there, which is the exact opposite of what these fields are for. All
// three are therefore written on EVERY tick under the mStarted && !mPaused
// gate, and "no lock" gets an encoding instead of a silence.
//
//   LOCK_RATE_NONE   0.0 spm. This is NOT the #86 / #107 trap of rendering
//                    absence as a legal value: updateAutocorr searches lags in
//                    [60/MAX_RATE, 60/MIN_RATE] only, so a lock IS a rate in
//                    [6.0, 40.0] spm by construction and 0.0 lies outside it.
//                    Same argument the core/skin 0.0 lines already make, and it
//                    is pinned (LOCK_RATE_NONE < MIN_RATE) rather than asserted
//                    in prose.
//
//   LOCK_CONF_NONE   -1.0. Here 0.0 WOULD be the trap: a confidence of zero is
//                    an ordinary reading (an uncorrelated signal), so it cannot
//                    also mean "no estimate was computed". The computed value
//                    is a ratio of a correlation to an energy and is
//                    non-negative by construction, so a negative sentinel
//                    cannot collide with one.
//
//   the run counter  written verbatim, SATURATED. mAcLowConf counts consecutive
//                    low-confidence estimates and is never reset except by a
//                    confident one, so it grows without bound on a long
//                    unlocked row. LOCK_LOW_MAX is one below 0xFFFF because
//                    0xFFFF is the UINT16 "no data" pattern (the same fact
//                    RR_INVALID records) -- saturating ONTO it would turn a
//                    long unlocked row into an apparent absence.
const LOCK_RATE_NONE = 0.0;
const LOCK_CONF_NONE = -1.0;
const LOCK_LOW_MAX   = 65534;

// ---- the GATE-INPUT DIAGNOSTICS (#149, part 2) ----------------------------
// The three fields above record what the LOCK was doing. These two record what
// the GATE WAS GIVEN, and without them a decoded row still does not determine
// what the detector did:
//
//   * row_stroke_rate is the gate's OUTPUT (outputRate() -> gatedRate). A
//     reading the gate ZEROED and a tick with no median are the same 0.0 in it,
//     and a reading the lock SNAPPED is indistinguishable from one that passed
//     through. So the file shows the gate's RESULT and never the gate firing.
//
//   * the gate's own threshold at any instant is fastGate(mRateBase), and
//     mRateBase IS NOT RECONSTRUCTIBLE OFFLINE. nextRateBase consumes the
//     PRE-GATE median, which is exactly the number no field carries, so the
//     recursion cannot be replayed from the file -- inverting the recorded
//     output is not available either, because the zeroed and snapped cases
//     discard the median outright.
//
//   rate_raw    mRate, the pre-gate median -- gatedRate's `raw`
//   rate_base   mRateBase, the established baseline fastGate keys on
//
// THE ENCODING QUESTION IS ASKED SEPARATELY FOR THESE TWO rather than inherited
// from LOCK_RATE_NONE, because the two arguments are not the same shape.
//
// lock_rate's 0.0 is a SUBSTITUTED MARKER. When no lock is up there is no rate
// to write at all (60.0/0.0 is not a number), so lockRateOf has to invent one,
// and 0.0 is safe because a lock is a rate in [MIN_RATE, MAX_RATE] by
// construction.
//
// THESE TWO INVENT NOTHING. mRate and mRateBase hold a value at every tick, and
// in the "nothing" state that value IS 0.0 -- assigned by recomputeRate when
// the period ring is empty, by the stroke-ring timeout in onSensorData, and by
// resetDetector. So the question is not "which marker do we choose" but "is the
// variable's own 0.0 ambiguous", and the discriminating test is the one
// lock_confidence FAILS:
//
//     IS THERE A STATE IN WHICH THE QUANTITY IS LEGITIMATELY 0.0 AND THAT STATE
//     IS NOT THE NOTHING STATE?
//
//   lock_confidence  YES. A correlation of zero over a real energy is an
//                    ORDINARY READING -- an uncorrelated signal -- and that is a
//                    different state from "no estimate was computed". Hence
//                    LOCK_CONF_NONE = -1.0.
//
//   rate_raw         NO. registerStroke accepts only periods in
//                    [60/MAX_RATE, 60/MIN_RATE]; the median of such periods is
//                    in that band; mRate = 60/median. So a median rate lies in
//                    [MIN_RATE, MAX_RATE]. Motion too slow or too fast for the
//                    band does not yield a SMALL rate -- the period is DROPPED
//                    and mRate is not touched at all, which is what keeps 0.0
//                    from ever meaning "a very slow reading".
//
//   rate_base        NO. nextRateBase establishes from a PUBLISHED reading
//                    (in band) and thereafter returns an EMA between two in-band
//                    numbers, which stays between them. Its only assignments of
//                    0.0 are resetDetector and the ring timeout.
//
// So for these two, 0.0 is NOT the #86 / #107 defect of absence rendered as a
// legal value: it is the quantity's own value, and it is out of band for a
// reading. A negative sentinel would buy no distinction that does not already
// exist and would cost the faithfulness -- the field would stop being the
// variable and start being an encoding of it, and every future reader would
// have to know which.
//
// PINNED RATHER THAN ASSERTED IN PROSE, and the pin is deliberately the STEP
// BEHIND the inequality: sub-band motion driven through the SHIPPING
// registerStroke leaves both quantities at exactly 0.0 rather than at a small
// rate (Lock.test_lock_theNoDataZeroIsTheDetectorsOwnValue, which also asserts
// RATE_RAW_NONE < MIN_RATE and RATE_BASE_NONE < MIN_RATE). If a later change
// ever lets either quantity take a value in (0, MIN_RATE), that case reds and
// this argument has to be re-made instead of quietly outliving its evidence.
//
// AND THEY ARE STILL WRITTEN ON EVERY TICK, for the reason the three above are:
// record-scope fields LATCH, so withholding the write on a no-data tick
// re-emits the last median and reports rowing that did not happen.
//
// WHAT THIS ARGUMENT DOES NOT COVER. Every sentence above is about the app's own
// arithmetic. Whether a decoder RENDERS a record-scope float32 0.0 as the number
// 0 -- rather than folding it into "no data" -- is unmeasured, and #53 already
// records that Connect's rendering of an unusual float32 pattern is untested. If
// it cannot, the encoding is still correct in-app and the diagnostic is
// unreadable in practice. #159 is the [Local] decode that settles it; do not
// restate any of this as a fact about a file until it has run.
const RATE_RAW_NONE  = 0.0;
const RATE_BASE_NONE = 0.0;

// #110 -- left-edge heart-rate arc. At module (global) scope for exactly the
// reason the R-R constants above are: a Monkey C class `const` is an instance
// member, unreachable from a static method, and every decision this feature
// makes is a class-scope static so a (:test) can reach it without a Dc.
//
// DISPLAY RANGE, in bpm, mapped linearly onto the arc sweep. These two are ALSO
// the bounds loadSettings clamps hrLo/hrHi to, and that identity is deliberate:
// it makes "the band marker always lands on the track" an invariant of
// loadSettings instead of a hope.
//
// 80-190 rather than a wider span, and the reason is RESOLUTION, not taste.
// drawArc truncates to whole degrees, so one degree is the finest distinction
// the geometry can draw, and one degree costs (HI-LO)/sweep bpm. Over the 56
// degree sweep below, 80-190 gives 0.509 deg/bpm, i.e. ONE DEGREE IS 1.96 BPM.
// A 60-200 range over the same sweep would make it 2.5 bpm. Both ends are still
// outside any plausible rowing target -- the reference session ran 97-147 --
// and a reading beyond either end clamps VISIBLY rather than silently, so the
// cost of the narrower span is paid in a state the display announces.
const HR_DISP_LO = 80;
const HR_DISP_HI = 190;
// SWEEP, in drawArc degrees. 0 is 3 o'clock, 90 is 12, 180 is 9, 270 is 6, so
// this is the left edge centred on 9 o'clock: low bpm at the bottom
// (HR_ARC_BOT), high at the top (HR_ARC_TOP), +/-28 degrees of horizontal.
// SYMMETRIC about 180 by construction, and pinned as such
// (test_hr_sweepIsSymmetricAboutNineOclock): every clearance below was computed
// from a single half-sweep, which only describes the drawn shape while the two
// ends are equidistant from horizontal.
//
// MEASURED, NOT DERIVED, and the distinction is the whole history of this
// constant. It was once +/-30, chosen by arithmetic against the height
// fractions of the rows above and below, and that arithmetic was wrong in two
// ways at once: it tracked the CENTRELINE of each primitive rather than its
// outermost pixel, and it assumed text widths instead of measuring them. The
// arc overlapped rendered text on 11 of the 12 manifest devices -- by 21 px on
// fr965 and 23 px on fenix843mm. It then shipped at +/-22, which was not a
// conservative choice: against the layout of the day it was close to the
// ceiling, because the pace row sat at h*0.70.
//
// #108 REMOVES THE PACE ROW FROM THE WORK VIEW, and that is what buys this.
// The widening and the strip are one change for that reason and must not be
// separated.
//
// WHAT DECIDED +/-28. MEASURED END TO END ON THE SHIPPING DRAW PATH: every
// primitive onUpdate issues, recorded through a Dc that keeps its geometry and
// expanded to its PEN WIDTH, against every string onUpdate draws, each measured
// with getTextWidthInPixels and getFontHeight on a REAL Dc -- and against the
// MIRROR of the drawn region about the vertical centreline, so #123's
// right-edge arc keeps a lane of equal width. Worst signed separation, in
// pixels, on the three devices that bind:
//
//     half-sweep   fenix6spro   fenix843mm   fr965
//       +/-22         19.0         20.7       17.0
//       +/-26         13.3         10.2       11.9
//       +/-28         10.6          5.0        8.6   <- landed
//       +/-30          8.2          0.7        3.2
//       +/-32          6.2         -4.2       -0.2   <- overlaps
//       +/-35          3.5         -9.3       -5.4   <- overlaps
//
// The ceiling is fenix843mm and it sits between +/-30 and +/-32. +/-28 is the
// last whole degree with more than four pixels on every device.
//
// THE +/-35 THAT #110's GEOMETRY SECTION PROPOSED DOES NOT FIT. It overlaps by
// 9.3 px on fenix843mm and 5.4 px on fr965. That estimate looked only at the
// h*0.78 caption row on one device; what actually binds is the REST screen --
// its pace row, and once the #109 grid is up, the grid's "interval m" label.
//
// Over all TWELVE devices at +/-28, with the #109 grid rendered, the worst is
// 4.95 px on fenix843mm, and the mirrored lane clears by the same 4.95 px. The
// tightest device once the grid is up is fenix6spro at 8.95 px.
//
// THE CONVENTION IS THE FONT BOX, NOT THE INK, and that is what makes 4.95 px a
// conservative number rather than a thin one. A string is taken to occupy
// dc.getFontHeight() vertically -- the same convention drawSetGrid uses -- and
// for a FONT_NUMBER_* face that box is far taller than any digit drawn in it.
// Nothing in this repository can measure glyph ink, so the larger true
// clearance is NOT claimed. The claim is the one that was measured: no drawn
// arc pixel enters any string's font box.
//
// None of that says anything about how the result looks. It says pixels do not
// share coordinates.
const HR_ARC_TOP = 152;
const HR_ARC_BOT = 208;
// MINIMUM DRAWN SWEEP, in whole degrees, for every arc this feature draws.
// SDK 9.2.0 documents drawArc as truncating its parameters toward zero and
// drawing A COMPLETE CIRCLE when degreeStart and degreeEnd are equal. So a band
// narrower than one truncated degree, or a fill of zero length, is not a short
// arc -- it is a ring across the entire screen. The guard has to be applied to
// the TRUNCATED values, because that is where the hazard lives: 185.2 and 185.8
// are different heart rates and the same degree.
const HR_ARC_MIN_D = 2;
// FRESHNESS WINDOW (ms) for the heart-rate read. Its own constant rather than
// RR_FRESH_MS on purpose: the RR pip keys off R-R BATCH ARRIVAL (mLastRrMs) and
// this keys off a bpm read. Different signals, independently tunable, and #110
// requires the two no-data states to stay independent.
//
// SCOPE, stated rather than implied: this measures the age of the last non-null
// read BY THIS APP. It does not measure the age of the underlying beat --
// Connect IQ exposes no timestamp for that -- so if the platform latches a
// stale value into currentHeartRate, nothing in-app can see it.
const HR_FRESH_MS = 5000;
// ZONE CODES. A code, not a colour. "No data" has to be a distinct KIND of
// answer rather than a colour that happens to differ, or the no-data case
// becomes a palette decision one edit away from collapsing into "below band" --
// which is the #86 / #107 defect class this repository has already shipped
// twice.
// ============ #123: the right-edge distance-per-stroke arc ================
// MIRRORED from the heart-rate arc, and the mirror is exact: the same radii,
// the same pen widths, the same bezel inset, the same minimum drawn sweep. Two
// arcs of visibly different size on the two edges would read as a defect.
//
// The sweep is HR_ARC_TOP/BOT reflected about the vertical axis: an angle a on
// the left maps to 180 - a on the right. 152 -> 28 and 208 -> -28, and -28 is
// written 332 because drawArc takes degrees in [0, 360).
const DPS_ARC_TOP = 28;    // upper end, mirror of HR_ARC_TOP
const DPS_ARC_BOT = 332;   // lower end, mirror of HR_ARC_BOT

// DISPLAY RANGE, as a PERCENTAGE of the configured benchmark. Not absolute
// metres: the whole point of the arc is position relative to what this athlete
// is trying to hold, and an absolute scale would need re-tuning per boat.
//
// 60..140 rather than 0..200 because the useful resolution is near the
// benchmark. 80 points across 56 degrees is 1.43% of benchmark per degree ON
// AVERAGE -- but drawArc TRUNCATES, so the bin containing a given angle is what
// the athlete actually sees, and the bin containing angle 0 spans 2.857%,
// double the average, because truncation toward zero makes it twice as wide as
// its neighbours. That bin is centred on 100%, the one transition this arc
// exists to show, so the figure to quote is 2.86% and not 1.43%. Over 0..200
// the same bin would span 7.1%, which is coarser than the difference between a
// good and a bad piece.
const DPS_DISP_LO = 60;
const DPS_DISP_HI = 140;

// THE FOUR STATES. Four, not a continuum, and that is a glance decision rather
// than a palette one: at a fraction of a second the eye resolves a colour
// CATEGORY, not a position on a ramp. More gradation buys resolution nobody can
// read at that exposure while adding collision risk.
const DPSZ_NONE  = -1;
const DPSZ_FAR   = 0;   // <= 85% of benchmark
const DPSZ_UNDER = 1;   // 85-100%
const DPSZ_AT    = 2;   // 100-125%  -- "at or above", the arc stops talking
const DPSZ_OVER  = 3;   // > 125%    -- a reward tier, not a warning

// The two boundaries inside the display range, in percent.
const DPS_FAR_PCT  = 85;
const DPS_OVER_PCT = 125;

// ============ ERG MODE: work and power units ================================
// Module (global) scope for the reason every block above gives: a Monkey C
// class `const` is an INSTANCE member, unreachable from a static method, and
// every decision this feature makes is a pure static so a (:test) can reach it
// with plain numbers instead of through a built view and an event loop.
//
// THE TICK PERIOD, in milliseconds. It was a literal at exactly one call site
// (onLayout's t.start) and is now named, because this feature adds a
// TIME-INTEGRATED quantity -- work, the integral of power over time -- and an
// integrator keyed on a period the timer does not actually run at is wrong by
// exactly that ratio with nothing on screen to say so. Named here so the timer
// and the integrator read the same number by construction.
//
// mCorrAccum's own `/ 240.0` at onTick is NOT rewritten in terms of this. That
// divisor is 60 * 1000 / 250 for a quantity in strokes per minute, so the
// substitution is not a rename, and rewriting a shipped accumulator was not in
// this change's scope. Named as a known duplication rather than left to be
// discovered.
const TICK_MS = 250;

// THE JOULES-PER-STROKE BENCHMARK the right-edge arc is read against in erg
// mode -- the exact analogue of dpsBenchmark, and clamped IN CODE for exactly
// the reason mDpsBench is: #21 is the defect of a range declared in
// settings.xml and enforced nowhere, and Connect IQ Properties survive an app
// update while a .set file is not re-clamped on load.
//
// THE DEFAULT IS NOT MEASURED AND IS NOT PRESENTED AS IF IT WERE. No power
// figure exists anywhere in this repository, so any watts number chosen here is
// an invention; what follows is the derivation of the invention, so the next
// reader can disagree with the premise rather than with a bare number.
//
//   * the app's OWN shipping defaults are a 16-18 spm target band (midpoint
//     17 spm) and a 116-130 bpm heart-rate band, i.e. aerobic durability work;
//   * work per stroke = watts * 60 / rate, so 400 J/stroke at 17 spm is
//     113 W -- an ordinary recreational aerobic output, consistent with that
//     heart-rate band;
//   * the arc spans 60-140% of benchmark, so the default covers 240-560
//     J/stroke, and a reading outside that CLAMPS VISIBLY (dpsIsClamped) rather
//     than silently.
//
// NOTE the erg and the water are not on the same scale and this constant must
// never be derived from dpsBenchmark. 6.0 m/stroke at 17 spm is 1.70 m/s, which
// on a Concept2's published pace-power relation (P = 2.80 / pace^3, pace in
// s/m) is 13.8 W -- absurd for an erg, and perfectly ordinary for a boat. The
// two figures describe different machines, which is the whole reason the
// maintainer asked for a unit switch instead of a relabel.
//
// EXPECTED TO BE SET PER ATHLETE AND PER MACHINE after the first instrumented
// session, exactly as the note on the heart-rate band says of its own defaults.
const JOULE_BENCH_DEF = 400.0;
// The clamp band. 50 J/stroke is below any rate/power pair a rowing machine
// produces while someone is on it (50 W at 40 spm is 75 J/stroke); 2000
// J/stroke is above any human (400 W at 12 spm is 2000 J/stroke, and 400 W
// sustained is elite). Wide enough that no real configuration hits either end,
// narrow enough that a corrupted property cannot put the benchmark somewhere
// the arc becomes meaningless.
const JOULE_BENCH_MIN = 50.0;
const JOULE_BENCH_MAX = 2000.0;

// ---- the interval work integrator's SAMPLE-COVERAGE FLOOR ------------------
// WHY A FLOOR EXISTS AT ALL. Interval work is an INTEGRAL of instantaneous
// samples, and that makes it unlike every other latched total on this screen.
// mSetHrSum is immune to a dropout because mSetHrN counts the samples actually
// taken and setAvgBpm divides by it; mLastSetDist is immune because
// latchWorkAccum takes an ODOMETER DELTA, which cannot lose a sample by
// construction. An integral has neither defence: a tick with no power sample
// contributes nothing and, without a count, leaves no trace that it happened.
// The result is a total that is under-reported by exactly the fraction of the
// interval the source was down, rendered as a value with nothing saying so --
// which is the same shape as the defect latchWorkAccum's own note records ("a
// 20% under-report on glance priority 1, rendered as a value rather than a
// dash").
//
// THE VALUE IS DERIVED FROM THE ARC'S OWN FAR BOUNDARY, not chosen. 0.85 is
// DPS_FAR_PCT / 100. The consequence, stated exactly and no stronger: an
// interval that clears this floor can be under-reported by at most 15%, so a
// reading that was AT the benchmark (100%) can be pushed no lower than 85% --
// and dpsZone's boundaries are inclusive upward, so 85% is UNDER and NOT FAR.
// A covered interval therefore cannot turn "you are on benchmark" into "far
// below benchmark, row harder". It CAN still move AT to UNDER, and it can move
// an already-UNDER reading into FAR; neither of those is a reversal of the
// instruction, which is what this floor is chosen to prevent.
//
// BELOW THE FLOOR THE ANSWER IS A DASH, never a scaled-up estimate.
// Extrapolating the measured mean across the unmeasured time would invent work
// the app never saw and present it with the same authority as work it did.
//
// THE FLOOR IS APPLIED TO THE DISPLAYED figures ONLY, and not to
// erg_work_total. See the note at that write for why the FIT record does not
// need it and would be made worse by it.
const WORK_COVER_MIN = 0.85;

// ---- the REST GRID's two erg cells: their display clamps -------------------
// The same argument PACE_W_MAX makes for the pace row, applied to the grid --
// and it had to be made here separately because the grid formatted its two erg
// cells RAW. The comment in drawSetGrid claimed maxima ("9999" J/stroke,
// "999.9" kJ) that nothing enforced and no case pinned: settings.xml declares
// workMinutes up to 60, and 60 minutes at 278 W is 1 000 800 J, which the
// unclamped cell renders as "1000.8" -- six characters where the "18000" it
// replaces is five.
//
// GRID_KJ_HI is not a constant because it is not a policy: 1000.0 appears once,
// inside gridKjStr, as the point where "%.1f" would grow a sixth character. See
// that function for why the format changes there rather than the value being
// clamped there.
const GRID_J_MAX  = 9999;    // J/stroke, "%d"   -> at most 4 characters
const GRID_KJ_MAX = 9999;    // kJ,       see gridKjStr -> at most 5 characters

// ---- the erg FIT encodings -------------------------------------------------
// RECORD-SCOPE FIELDS LATCH. Once setData has been called even once, a record
// committing without a new setData RE-EMITS the last value (#36, byte level,
// fr965 / SDK 9.2.0; reconfirmed by #48's probe_skip). So WITHHOLDING A WRITE
// DOES NOT PRODUCE A GAP -- on these fields it would fabricate a power reading
// that was not taken, which is the exact opposite of what they are for. All
// three record-scope erg fields are therefore written on EVERY tick under the
// mStarted && !mPaused gate, and "no power source" gets an ENCODING instead of
// a silence.
//
// THE DISCRIMINATING QUESTION, asked separately for each field rather than
// inherited, is the one the #149 block states: IS THERE A STATE IN WHICH THE
// QUANTITY IS LEGITIMATELY 0.0 AND THAT STATE IS NOT THE NOTHING STATE?
//
//   erg_power   YES. ZERO WATTS IS A LEGAL READING ON AN ERG -- between
//               strokes, on the recovery, or with the athlete sitting at the
//               catch. So 0.0 cannot also mean "no power source", and a
//               sentinel is required. -1.0 because power is non-negative by
//               construction, so a negative value cannot collide with a
//               reading. This is lock_confidence's argument, not
//               lock_rate's.
//
//   erg_jps     YES, and for the same reason one step downstream: 0 W at a real
//               stroke rate is 0.0 J/stroke, an ordinary reading. Same
//               sentinel, same argument.
//
//   erg_cadence YES. A cadence of 0 spm is what a machine broadcasts while the
//               handle is stationary, and it is exactly the reading that would
//               tell a machine source from a wrist one. Same sentinel, same
//               argument -- cadence is non-negative by construction.
//
// WHAT THIS ARGUMENT DOES NOT COVER, stated so it is not read as more than it
// is. Every sentence above is about the app's own arithmetic. Whether a decoder
// RENDERS a record-scope float32 -1.0 as the number -1 -- rather than folding
// it into something else -- is unmeasured here, and #53 already records that
// Connect's rendering of an unusual float32 pattern is untested. Do not restate
// any of this as a fact about a file until a [Local] decode has run.
const ERG_POWER_NONE = -1.0;
const ERG_JPS_NONE   = -1.0;
const ERG_CAD_NONE   = -1.0;

// ---- the erg INSTRUMENTATION bitfield --------------------------------------
// THE POINT OF THE FIRST SESSION. The whole feature rests on an assumption
// nobody has measured: that Activity.Info.currentPower is populated for a
// Connect IQ WATCH APP when a rowing machine is paired. These bits are what let
// ONE session settle it -- and settle the questions that immediately follow
// from it -- without a second trip:
//
//   * was currentPower non-null, and was it ever positive;
//   * do currentSpeed and elapsedDistance populate FROM THE MACHINE? They may,
//     if it broadcasts as fitness equipment, and if they do then the
//     distance-based figures still work on an erg and this feature's premise
//     changes;
//   * does currentCadence populate AT ALL on an erg?
//
// WHAT THE CADENCE BITS CANNOT SAY, corrected here because an earlier revision
// of this block claimed they answered "does currentCadence populate from the
// MACHINE rather than from the wrist" and they cannot. THE WRIST ALREADY
// POPULATES THAT FIELD WITH NO MACHINE PRESENT, and this repository has
// measured it: the Potomac row in README.md records native cadence at 89-109
// blade movements against 66-68 drives, which is the measurement
// correctiveRate() is built on, taken on the water. So CAD_OK|CAD_POS set is
// the EXPECTED reading on an erg whichever source feeds it, and only CAD_OK
// CLEAR would be informative -- it would say the indoor context suppressed the
// wrist counter. The power, speed and distance bits do not share this problem,
// because none of those three is known to populate without a machine.
//
// SO THE SOURCE QUESTION IS ANSWERED BY THE VALUE, NOT BY THE BITS. erg_cadence
// (id 16) carries ai.currentCadence itself, so it can be differenced against
// row_stroke_rate off the file -- which correctiveRate() cannot be used for,
// because it clamps the difference at zero and so destroys exactly the sign of
// interest (a machine cadence BELOW the wrist-derived drive rate). Even then a
// decisive read needs a protocol rather than a passive comparison: during
// ordinary erg rowing both candidate sources track the same strokes. Hands off
// the handle while moving the arm is the discriminator -- a machine source goes
// to zero there and a wrist source does not. That protocol is #168's, not this
// field's.
//
// This mirrors what ct_diag does for the CORE pod and what #149's lock fields
// did for the stroke detector: both turned an argument into a measurement.
//
// ONE UINT16 rather than eight scalar fields, for ct_diag's reason -- it costs
// one developer field id and one field_description instead of eight, and every
// slot stays an ordinary readable integer.
//
// THE ALIVE BIT IS ALWAYS SET, and it is not decoration. It does two things at
// once, and both are about telling a written value from an unwritten one:
//   * a written value can never be 0x0000, so "everything absent" (the answer
//     this field exists to be able to give) is 0x8000 and is unmistakably a
//     RECORDED answer rather than a blank;
//   * bits 0x0400..0x4000 are RESERVED ZERO, so the largest value this code can
//     ever write is 0x83FF -- which means a written value can never be 0xFFFF,
//     the UINT16 never-set invalid pattern (the same fact RR_INVALID records).
// Widening the bit set past 0x0200 must therefore stop short of 0x0400 or
// re-make this argument.
const ERGD_ALIVE   = 0x8000;   // always set; see above
const ERGD_PWR_OK  = 0x0001;   // Activity.Info.currentPower was non-null
const ERGD_PWR_POS = 0x0002;   // ... and greater than zero
const ERGD_SPD_OK  = 0x0004;   // currentSpeed was non-null
const ERGD_SPD_POS = 0x0008;
const ERGD_DST_OK  = 0x0010;   // elapsedDistance was non-null
const ERGD_DST_POS = 0x0020;
// "was it populated", NOT "was it the machine". See the correction above: only
// CAD_OK CLEAR carries information, because the wrist populates this field on
// its own. erg_cadence (id 16) is what carries the source question.
const ERGD_CAD_OK  = 0x0040;   // currentCadence was non-null
const ERGD_CAD_POS = 0x0080;
const ERGD_ERGMODE = 0x0100;   // the ergMode setting was ON for this record
const ERGD_WORKUNI = 0x0200;   // work units were SELECTED for this record
// 0x0400 .. 0x4000 reserved zero -- see the ALIVE note above.
const ERGD_MAX     = 0x83FF;

// ---- the erg PACE ROW's display clamps -------------------------------------
// The pace row's string is DATA-DEPENDENT and it sits at h*0.70 in FONT_XTINY,
// a position and a font this row has shipped with on all twelve devices. What
// changes in erg mode is the STRING, so what has to be bounded is its length.
//
// Both figures are clamped to four digits, which makes "9999W  9999J/str" -- 16
// characters -- the widest string paceWorkStr can ever return, against the 20
// characters of the "-:--/500m  12.5m/str" form it replaces.
//
// CHARACTERS ARE NOT PIXELS and that bound is not claimed as a clearance. No
// (:test) that runs in CI can obtain a font metric (#121), so the pixel
// measurement is a [Local] one; what is asserted here and pinned in
// source/ErgUnitsTest.mc is the character bound alone.
//
// A CLAMP IS A LIE AT THE TOP END, deliberately accepted and stated: a machine
// reporting more than 9999 W is broken, the FIT file carries the true value
// through erg_power, and the alternative -- an unbounded string on a glance
// surface -- is the failure this row cannot survive.
const PACE_W_MAX = 9999;
const PACE_J_MAX = 9999;

const HRZ_NONE  = -1;
const HRZ_BELOW = 0;
const HRZ_IN    = 1;
const HRZ_ABOVE = 2;

// ============ the DISPLAY CUE's zone codes ==================================
// The stroke-rate colour, treated as an INSTRUCTION rather than as a rendering
// of the measurement. In the maintainer's words: "the in row measurement is
// designed to just tell me whether I should increase or decrease my rate. Have
// it keep the actual measurement in the file though."
//
// A CODE, never a colour, for the same reason HRZ_* is: "nothing to say" has to
// be a different KIND of answer, or it collapses into "below band" one palette
// edit later -- the #86 / #107 defect class.
//
// Module scope, like every constant a class-scope static must reach: a Monkey C
// class `const` is an instance member and a static cannot resolve it.
const CUEZ_NONE  = -1;   // no reading -- the numeral is "--.-"
const CUEZ_BELOW = 0;    // row harder
const CUEZ_IN    = 1;    // hold
const CUEZ_ABOVE = 2;    // ease off

// ============ the cue's three tunables ======================================
// CHOSEN BY REPLAY AGAINST TWO RECORDED ROWS, not by feel -- and every figure
// below is REGENERABLE IN ONE COMMAND:
//
//     python3 scripts/cue_replay.py
//
// That harness drives THE RULE BELOW (cueBandZone / cueTarget / cueStep,
// transcribed into Python, with the transcription pinned against the same
// numeric vectors source/CueZoneTest.mc asserts against this file) over the work
// laps of both recordings, which are committed as
// scripts/fixtures/cue_work_laps.txt. scripts/test_cue_replay.py re-derives
// every number quoted here and reds if any of them moves, so this comment can no
// longer drift away from the data.
//
// RETRACTION, kept rather than edited away because the retracted claims were
// load-bearing for the whole design. An earlier revision of this block quoted
// figures produced by a DIFFERENT machine from the one that shipped: a two-stage
// replay whose deadband ran free on every sample, whose persistence window was
// chosen by the zone being LEFT rather than by the candidate, and which counted
// SAMPLES rather than milliseconds. Replaying the shipped rule instead retracts
// four claims, each corrected in place below:
//   * the choppy row's false-high improvement. Advertised 6.9% -> 4.5%. It is
//     actually UNCHANGED. This is the sentence the design was sold on.
//   * the flicker figures (2.88 -> 1.41 calm, 2.92 -> 1.94 choppy).
//   * a lap-median "walk" of 16.5 -> 15.0 -> 14.2 -> 13.2, which was a selective
//     subsequence of a series that is not monotone.
//   * "the calm row never exceeds 1.5x", which it does.
// No CODE was wrong; the evidence quoted for it was.
//
// THE TWO ROWS, work laps only, from the row_stroke_rate developer field. A zero
// is the app's no-data sentinel (drawRate renders it "--.-"), so it is an
// ABSENCE and not a slow stroke, and it is excluded from every figure here:
//
//   4x15' durability, calm water, target 18-20 spm
//     laps over 600 s: 4 laps, 3522 recorded seconds, 3496 carrying a reading
//   8x3'  strength-endurance, choppy water, target 16-18 spm
//     laps within 5 s of 180: 8 laps, 1442 recorded seconds, 1436 with a reading
//
// THE FAILURE BEING FIXED IS TRANSIENT SPIKES, not a biased median. Against its
// own row median the choppy row reads above 1.25x on 8.7% of its reading-seconds
// and peaks at 37.5 spm (2.43x); the calm row reads above 1.25x on 4.0% and
// peaks at 31.9 spm (1.60x). (Not "never exceeds 1.5x": the calm row does, on 2
// of 3496 seconds. The earlier absolute claim is withdrawn -- the difference
// between the rows is a factor of two on the 1.25x statistic, which is the real
// point and does not need an absolute to stand on.)
//
// THE CHOPPY ROW'S EIGHT WORK-LAP MEDIANS, in full, against a 16-18 target:
//
//     16.5, 15.0, 14.2, 15.2, 13.2, 14.3, 16.1, 16.0
//
// FIVE of the eight sit below band and the middle of the session sags to 13.2 --
// the athlete easing off against a cue that was lying -- before the last two
// intervals recover into band. The series is NOT monotone and it DOES recover;
// the retracted "16.5 -> 15.0 -> 14.2 -> 13.2" was laps 1, 2, 3 and 5 with lap 4
// dropped from the middle and laps 6-8 dropped from the end.
//
// THE DRIVER IS WATER STATE RATHER THAN CADENCE, but the within-row evidence for
// that is weaker than an earlier revision claimed, so it is restated rather than
// quietly kept. Per calm work lap, the share of reading-seconds above 1.25x THAT
// LAP's own median is 1.0%, 5.5%, 1.3%, 3.5%; the 3.5% lap is the one abandoned
// early for chop. The earlier revision quoted "3.5% against 1.0% and 1.3%" and
// left out the 5.5% lap -- which is spikier than the chop lap and breaks the
// comparison. What the recordings do support is the BETWEEN-row difference:
// 8.7% choppy against 4.0% calm, same statistic, same definition.
//
// SCORED BY DIRECTION OF ERROR, because the damaging error is FALSE-HIGH:
// telling the athlete to ease off while they are actually in the band. TRUTH is
// a 31 s CENTRED median of the measurement put through the plain band; a FLIP is
// a zone change between consecutive SCORED seconds. Every definition and every
// denominator is in scripts/cue_replay.py in code rather than in prose, because
// their absence is precisely why the superseded figures could not be checked.
//
//   row     metric        raw (before)   shipped cueStep (after)
//   calm    FALSE-HIGH        11.8%              2.6%
//   calm    false-low          7.1%              1.8%
//   calm    missed-HIGH        6.2%             15.3%
//   calm    flips/min          2.87              1.10
//   calm    lag                 0 s               1 s
//   choppy  FALSE-HIGH         6.9%              6.9%
//   choppy  false-low         18.1%              3.0%
//   choppy  missed-HIGH        1.5%              2.5%
//   choppy  flips/min          2.30              1.17
//   choppy  lag                 0 s               5 s
//
// WHAT THAT TABLE SAYS, INCLUDING THE PART THAT WAS SOLD WRONG. On the CALM row
// the cue does what it was chosen to do: FALSE-HIGH 11.8% -> 2.6%. On the CHOPPY
// row it does not reduce false-high AT ALL -- 28 of 403 truth-in-band seconds
// either way, and only 18 of those are the same seconds, so it relocates them
// rather than removing them. The choppy row's real and reproducible gains are
// FALSE-LOW 18.1% -> 3.0% and flicker 2.30 -> 1.17 flips/min. A later strategy
// comparison should be scored against those, never against the 4.5% this block
// used to advertise. Whether the choppy row's residual false-high wants a
// further change is a live question and NOT settled here.
//
// FLICKER roughly halves on both rows, and by more than was advertised: 2.87 ->
// 1.10 flips/min calm, 2.30 -> 1.17 choppy.
//
// THE COST, ACCEPTED DELIBERATELY: missed-HIGH rises from 6.2% to 15.3% of
// scored seconds (calm) and 1.5% to 2.5% (choppy), and the median lag on a
// genuine zone change goes from 0 s to 1 s (calm) and 5 s (choppy). A late
// warning is far cheaper than a false one, and the deadband is only 1 spm, so a
// genuine overshoot past +1 still arrives -- four seconds later.
//
// DO NOT "IMPROVE" THIS BY SMOOTHING THE NUMBER. Pre-smoothing the displayed
// rate and taking the zone from the smoothed value makes BOTH rows worse on
// FALSE-HIGH. Re-measured on the SHIPPED rule with CAUSAL (trailing) filters,
// which is the only kind a live display could run:
//
//   pre-filter          calm false-high   choppy false-high
//   none (shipped)            2.6%              6.9%
//   median-5                  3.4%              9.7%
//   median-9                  4.7%             13.2%
//   Hampel (7, 3 MAD)         2.9%              6.9%
//
// The Hampel row is the instructive one: it moves the choppy figure not at all,
// because it does not suppress the 37.5 spm spike. That spike is SIX CONSECUTIVE
// SECONDS at the very first second of a work lap, so a trailing window has
// nothing but the spike in it -- its own median is 37.5 and its MAD is zero, and
// a trailing median-5 passes all six through unchanged. An outlier rejector
// cannot reject what it has only ever seen. FILTER THE ZONE, NOT THE NUMBER: the
// displayed number stays raw outputRate() because it is the measurement, and the
// colour carries the instruction.
//
// WHAT NONE OF THIS MEASURES: how the result reads on a wrist mid-stroke. These
// figures are a replay of two recordings against a decision function. They say
// the cue would have lied less often on the calm row and flickered less on both;
// they do not say the athlete would have rowed better.
const CUE_DEADBAND = 1.0;         // spm, paid on EXIT from the band only
const CUE_PERSIST_OUT_MS = 4000;  // ms a change to an out-of-band cue must hold
const CUE_PERSIST_IN_MS  = 1000;  // ms a change back into the band must hold

// ---- #80: the status row and the heat-strain pip ----------------------------
//
// MEASURED FIRST, because the design that #80's own text proposed does not
// survive measurement and the numbers are the reason this row is laid out the
// way it is.
//
// Method: dc.getTextDimensions and dc.getFontHeight called from a throwaway
// app under SDK 9.2.0, on ALL TWELVE manifest devices. Every one of them
// reports screenShape == SCREEN_SHAPE_ROUND with w == h, so the visible area is
// the circle inscribed in the display box and the row's usable width at height
// y is a chord, not w. The method reproduces a figure this file already
// records ("-:--/500m  12.5m/str" at 277 px on the 454 px devices) to the
// pixel, which is the cross-check that it is measuring the same thing earlier
// work did.
//
// THE STATUS ROW IS ALREADY FULL. At the row's text-box top the chord runs from
// 0.2927w to 0.7073w -- 188.1 px on a 454 px device, 172.5 on fenix843mm,
// 99.5 on fenix6spro -- and today's three labels leave the following clearance
// to it:
//
//   device          GPS left   CT right      (px, box corner to the circle)
//   454 px family      1.04       1.97
//   fenix843mm         0.55       1.60
//   epix2pro47mm       7.55       5.60
//   fenix7/7pro/6/6pro 3.85       3.30
//   fenix6spro         2.55       2.35
//   fenix6xpro         5.15       4.65
//
// So #80 section 4's proposal -- "a fourth pip at ~w*0.80 fits the existing row
// with no layout rework" -- IS FALSE, and not marginally: 0.80w is outside the
// display entirely at this height on every device. That claim is retracted
// here rather than quietly not implemented.
//
// FOUR TEXT PIPS DO NOT FIT EITHER. Laying "GPS RR CT HS" out with equal gaps
// across the whole chord leaves 2.5 px between labels on fenix843mm and 5.8 px
// on fenix6spro, against 21.6 px and 15.6 px today; lowering the row to the
// last pixel the h*0.13 title allows buys 1.4 px more. A one-character label
// ("H") reaches 8.2 px on the worst device. None of that is a spacing this row
// can carry, so the heat-strain indicator is NOT a text pip.
//
// WHAT SHIPS: a small circular mark, right-aligned against the chord, with the
// CT label moved left just enough to make room. Its cost is the RR-to-CT gap.
//
// THE TABLE BELOW WAS WRONG AND IS CORRECTED HERE (#141). The shipped geometry
// was and is fine; only these numbers were wrong -- which is the harder defect
// to catch, because nothing renders differently and a table of plausible pixel
// figures reads as a measurement.
//
// HOW MANY ROWS WERE WRONG DEPENDS ON THE TOLERANCE, and both counts are
// DERIVED rather than asserted. The six pairs the old table claimed are carried
// below as machine-readable CLAIMED rows, and scripts/check_pip_geometry.py
// compares each against its own derivation and counts the disagreements itself.
// At half a pixel -- the precision the old one-decimal table was written to --
// FOUR of the six disagree, which is #141's figure. At the 0.05 px the
// corrected rows carry, FIVE do: the 454 px family joins them, out by 0.44 and
// 0.39. Only fenix6spro was right under either reading.
//
// ONE COPY OF EACH NUMBER, which is why there is no claimed/derived table in
// prose here any more. An earlier revision carried one beside the marked rows;
// two copies of a figure are exactly the drift this change exists to stop. The
// claimed pairs are the CLAIMED rows, the derived pairs are the PIPGEOM rows,
// and the checker prints them side by side.
//
// The dangerous one is fenix7/7pro/6/6pro: the claimed headroom after the move
// was 12.7 px where the real figure is 10.00, so a future author spending that
// "headroom" lands the gap under the 5.0 px floor this row works to.
//
// WHAT THE CLAIMED COLUMN SHOWS, taken only as far as the numbers carry it.
// gap_today is ct_today*w - ct/2 - (rr_x*w + rr/2), which with rr == ct reduces
// to 0.14w - ct: STRICTLY INCREASING in w at a fixed ct. Yet FIVE of the six
// rows share their claimed gap_today with another row -- across three different
// widths in one group, and across two different MEASURED CT widths in the other
// -- so at least one cell in each of those rows cannot have been derived for
// that row's own width. The claimed gap_after column repeats NOTHING: six
// distinct values. Both counts are derived by the checker from the CLAIMED rows
// and pinned by the DISAGREE line, so this paragraph cannot drift from them
// either.
//
// HOW THOSE CELLS GOT THERE IS NOT RECORDED ANYWHERE IN THIS REPOSITORY. The
// table entered the tree complete in one commit whose own message says the
// figures were measured. An earlier revision of this paragraph asserted that
// three rows "had simply been copied from a neighbour"; that is RETRACTED -- it
// is an unverifiable claim about another author's process, and it is the one
// sentence a reader could not check in a block whose whole subject is claims
// outrunning their evidence.
//
// HOW THE DERIVED COLUMN IS PRODUCED, and why prose cannot drift from it
// again. scripts/check_pip_geometry.py recomputes every row from the SHIPPED
// constants and the SHIPPED formulas -- pipChordXMax, pipDotR, pipGap,
// pipDotCx, pipCtCx, whose bodies it also pins, so an edit to any of them fails
// the check instead of silently invalidating this table -- and compares them
// against the machine-readable rows below. That is the same move
// scripts/check_ceiling_notes.py makes for the globals notes: prose keeps the
// argument, one marked line per row carries the arithmetic.
//
//   gap    = (CT box left) - (RR box right), both labels centre-justified at
//            FONT_XTINY, taken at the row's text-box TOP where the chord is
//            narrowest
//   edge   = (chord limit) - (CT box right), the label's own bezel clearance
//   today  = the pre-#80 layout, CT centred at 0.66w
//   after  = CT centred at pipCtCx(w, h)
//
//   PIPGEOM-BASE ct_today=0.66
//   PIPGEOM 454px-family       w=454 ct=39 rr=39 gap_today=24.56 gap_after=8.61 edge_today=1.98 edge_after=17.93
//   PIPGEOM fenix843mm         w=416 ct=36 rr=36 gap_today=22.24 gap_after=9.20 edge_today=1.68 edge_after=14.72
//   PIPGEOM epix2pro47mm       w=416 ct=28 rr=28 gap_today=30.24 gap_after=17.20 edge_today=5.68 edge_after=18.72
//   PIPGEOM fenix7-7pro-6-6pro w=260 ct=18 rr=18 gap_today=18.40 gap_after=10.00 edge_today=3.30 edge_after=11.70
//   PIPGEOM fenix6spro         w=240 ct=18 rr=18 gap_today=15.60 gap_after=7.15 edge_today=2.35 edge_after=10.80
//   PIPGEOM fenix6xpro         w=280 ct=18 rr=18 gap_today=21.20 gap_after=12.85 edge_today=4.25 edge_after=12.60
//
//   THE CLAIMED PAIRS, kept as data rather than as prose so the counts in the
//   paragraph above are derived from them. These are HISTORY: they are not
//   derivable from anything, and they are NOT expected to match the rows above.
//
//   PIPGEOM-CLAIMED 454px-family       gap_today=25.0 gap_after=9.0
//   PIPGEOM-CLAIMED fenix843mm         gap_today=22.3 gap_after=9.9
//   PIPGEOM-CLAIMED epix2pro47mm       gap_today=22.3 gap_after=21.9
//   PIPGEOM-CLAIMED fenix7-7pro-6-6pro gap_today=15.6 gap_after=12.7
//   PIPGEOM-CLAIMED fenix6spro         gap_today=15.6 gap_after=7.2
//   PIPGEOM-CLAIMED fenix6xpro         gap_today=15.6 gap_after=12.9
//   PIPGEOM-DISAGREE half_px=4 tight=5 today_dupes=5 after_dupes=0
//
// ONE INPUT IS ASSUMED RATHER THAN MEASURED, and it is called out here because
// every figure above depends on it: `rr` is the rendered width of the "RR"
// label, and NO MEASUREMENT OF IT EXISTS IN THIS REPOSITORY. Only the "CT"
// widths were measured (see PIP_CT_W_FRAC). Both labels are two upper-case
// characters at FONT_XTINY, so each row assumes rr == ct. If that is ever
// measured and differs, every gap figure shifts by (rr - ct)/2 uniformly and
// the rows above must be re-derived -- the marked rows carry `rr` explicitly so
// that correction is one edit per device rather than a re-derivation. A
// [Local] issue owns the measurement.
//
// The CT label itself gains bezel clearance (it moves inward, from 1.68-5.68 px
// to 10.80-18.72); the mark takes the tight end. Nothing here says how any of
// it looks on a wrist.
const PIP_ROW_Y_FRAC = 0.045;   // top of the status row's text box, in h

// Upper BOUND on the rendered width of the "CT" label, in w. MEASURED at
// FONT_XTINY on all twelve devices: 39/454, 36/416 (fenix843mm), 28/416
// (epix2pro47mm), 18/280, 18/260, 18/240 -- the largest is 0.0865w. Used as a
// bound rather than a value on purpose: the label is centre-justified, so
// over-estimating its width can only move it further from the bezel, and that
// keeps this a compile-time constant instead of a per-frame text measurement.
const PIP_CT_W_FRAC = 0.09;

// The heat-strain mark. Fractions of display width with integer floors, the
// same shape every arc dimension in this file uses, so the smallest display
// still draws something rather than collapsing to nothing.
const PIP_DOT_R_FRAC = 0.014;
const PIP_DOT_R_MIN  = 3;
const PIP_GAP_FRAC   = 0.009;   // between the CT label and the mark
const PIP_GAP_MIN    = 2;

// ============ THE STEP MARKS: step_type and interval_num =====================
//
// THE PROBLEM, measured on a real file rather than imagined. In the FIT this
// app writes, A LAP IS JUST A LAP: activity i178249719 carries 17 laps and
// nothing in the file distinguishes the eight 180 s work pieces from the rests,
// the warm-up or the cool-down. Every downstream consumer has to GUESS from
// duration, and the analyses in #124 and #149 all did exactly that -- filtering
// laps on "170 <= duration <= 190". That heuristic is wrong in both directions:
//
//   * it DROPS a shortened piece. One interval was aborted for chop at 820 s of
//     a planned 900 and simply vanished from the analysis;
//   * it MISCLASSIFIES a rest that happens to run a work piece's length, which
//     on a 3'/3' session is every rest.
//
// So the app writes down what it already knows. mStepIdx, the STEP_* kinds and
// the per-interval counter mSetNum are all live at every tick; two developer
// fields carry them into the file.
//
// THE WIRE MAPPING. These numbers ARE the format: a code whose meaning lives
// only in a commit message is useless to whoever reads a file in a year, and
// renumbering one silently re-labels every second already recorded.
//
//   step_type   id 17, RECORD scope, UINT8
//
//     0  SFIT_NONE   no workout step is in force: FREE-ROW mode, for the
//                    whole length of the row, and nothing else. THERE IS NO
//                    PRE-START RECORD TO CARRY IT, and an earlier revision of
//                    this row said there was ("any record committed before
//                    START") -- retracted. Recording does not exist before
//                    mSession.start(), and both writers of this field are gated
//                    on mStarted: the record write sits inside onTick's
//                    `if (mStarted && !mPaused)`, and markLap runs only from
//                    paths that have already set it. stepTypeCode's `!started`
//                    arm is therefore DEFENSIVE ONLY -- pinned by
//                    StepMark.test_sm_c1_theWireMappingIsTheDocumentedTable,
//                    unreachable from a file. Records that commit before the
//                    session's FIRST setData carry the type's NEVER-SET pattern
//                    instead; #48 measured that pattern for FLOAT (0xFFFFFFFF,
//                    REC 1 included) and it is expected-same but UNMEASURED for
//                    UINT8 and UINT16, so a consumer must treat "absent" and 0
//                    as distinct. Neither is SFIT_WORK, so the acceptance
//                    criterion is unaffected either way.
//
//                    0 IS A VALUE, NOT A SILENCE, and the reason has two halves
//                    that are NOT the same reason. WITHIN A WORKOUT ROW the
//                    latch does the work: record-scope fields LATCH (#36/#48,
//                    byte level on fr965 / SDK 9.2.0), so a withheld write on a
//                    non-work step re-emits the previous step and fabricates
//                    work seconds -- see the write site's own note. ON A FREE
//                    ROW THE LATCH CANNOT APPLY: the fields are created fresh
//                    per session (startSession opens one only when mSession is
//                    null, and stopAndSave nulls it), so with no write anywhere
//                    in the file EVERY record would carry the never-set
//                    pattern, not a previous row's value. An earlier revision
//                    justified the free-row write BY the latch, and that is
//                    retracted too. It is written anyway because the never-set
//                    pattern's meaning is an open [Local] question this file
//                    declines to call "absence", while 0 decodes to a stated
//                    value -- and because it lets a consumer tell a free row
//                    from a workout row FROM THE FILE (see the createField
//                    block's note). 0 is out of band for every real step
//                    because the codes below start at 1.
//     1  SFIT_WARM   STEP_WARM   warm-up, user-ended
//     2  SFIT_WORK   STEP_WORK   a work interval -- THE PIECES
//     3  SFIT_REST   STEP_REST   timed rest between pieces
//     4  SFIT_GATE   STEP_GATE   press-START gate BETWEEN pieces.
//                    buildWorkout emits it on `if (mGate)` ALONE --
//                    pressToContinue, DEFAULT TRUE -- independently of
//                    restMinutes. So on the shipped defaults (restMinutes 2) a
//                    gate follows EVERY rest, and these are real seconds
//                    between every pair of pieces rather than a restMinutes = 0
//                    artefact: the default sequence is WARM, WORK1, REST1,
//                    GATE1, WORK2 ... An earlier revision of this row read
//                    "(restMinutes = 0)" and is RETRACTED. Gate seconds are
//                    RECOVERY, not work: a consumer summing recovery must add
//                    codes 3 AND 4, while the work-seconds criterion (code 2)
//                    is unaffected either way. The independence is pinned by
//                    MUTATION rather than by prose: nesting buildWorkout's
//                    gate arm under `mRestSec <= 0` reds five cases on fr965,
//                    among them
//                    StepMark.test_sm_c2_aScriptedWorkoutWritesTheDocumentedSequence
//                    ("at GATE1 the record marks must be (4, 0); wrote (2, 2)").
//     5  SFIT_COOL   STEP_COOL   cool-down, user-ended
//     6  SFIT_DONE   STEP_DONE   finished, waiting for BACK
//
//   interval_num  id 18, RECORD scope, UINT16
//
//     0            IVL_NONE. NOT in a work interval -- warm-up, rest, gate,
//                  cool-down, done, and free row. Unambiguous because interval
//                  numbers are 1-based by construction (buildWorkout counts i
//                  from 1). There is no "before START" case here either, for
//                  the reason the SFIT_NONE row above gives: this value has the
//                  same two writers, gated the same way.
//     1..65534     the 1-based work interval this record belongs to.
//     65535        NEVER WRITTEN. It is the UINT16 "no data" pattern -- the
//                  same fact RR_INVALID records -- so intervalNumOf saturates
//                  at IVL_MAX one below it rather than letting a sideloaded
//                  numIntervals turn a real interval into an apparent absence.
//                  (loadSettings clamps numIntervals only at the LOW end; that
//                  is #21, and this does not depend on it being fixed.)
//
// THE FIT CODES ARE NOT THE CLASS ORDINALS, deliberately. STEP_WORK is 0
// internally, and a 0 that means "the pieces" cannot also mean "no workout at
// all" -- which is the encoding a latching record field most needs. The two
// numbering schemes are bridged by stepTypeCode alone, and the mirror it reads
// (SFIT_ORD_*) is pinned against the shipping class constants by
// StepMark.test_sm_c1_theMirroredOrdinalsAreTheShippingConstants, so a reorder
// of the internal enum reds a test instead of silently re-labelling the file.
//
// WHAT IS NOT CLAIMED. Everything above is about what this code CALLS. No
// (:test) can obtain a Session, so nothing in this repository observes a
// field_description message, a record's bytes or what any decoder renders --
// the acceptance criterion is proved on the QUERY side by
// scripts/fit_step_marks.py against a synthetic file, and the [Local] issue
// filed with this change owns the simulator session and the real decode.
const SFIT_NONE = 0;
const SFIT_WARM = 1;
const SFIT_WORK = 2;
const SFIT_REST = 3;
const SFIT_GATE = 4;
const SFIT_COOL = 5;
const SFIT_DONE = 6;

// The class-scope STEP_* ordinals, mirrored at module scope because a `static`
// cannot name an instance member -- the same constraint rateColour states for
// its boolean parameter, met here with a mirror instead because the mapping is
// six-way and a boolean cannot carry it. PINNED against the real constants; a
// mirror nothing checks is a copy waiting to drift.
const SFIT_ORD_WORK = 0;
const SFIT_ORD_REST = 1;
const SFIT_ORD_GATE = 2;
const SFIT_ORD_DONE = 3;
const SFIT_ORD_WARM = 4;
const SFIT_ORD_COOL = 5;

const IVL_NONE = 0;
const IVL_MAX  = 65534;

// ---- #130: the DONE screen's grid base --------------------------------------
//
// How far UP the set-summary grid moves on STEP_DONE, as a fraction of display
// height. One number, applied to all four of drawSetGrid's row fractions, so
// DONE renders the SAME table shifted -- not a second table that could drift
// from the first.
//
// WHY DONE NEEDS A BASE OF ITS OWN. The grid's shipping rows (0.44 / 0.533 /
// 0.655 / 0.749) were laid out for REST and GATE, where the sub row STANDS
// DOWN and the band below the grid is free. On DONE the sub row must survive:
// "BACK to save" at h*0.78 is the only text in the app telling the athlete how
// to write the FIT. At the shipping rows the bottom value row's box runs to
// 0.749 + 0.1115 = 0.8605h, straight through it.
//
// WHAT BUYS THE SPACE: DONE draws no countdown. onUpdate's countdown chain
// covers WORK/REST (mmss), WARM/COOL (mmssUp), GATE ("PRESS START") and the
// pre-start screen, and DONE matches none of them -- so the band starts under
// the TITLE rather than under a FONT_NUMBER_MILD numeral.
//
// DERIVED FROM THE MEASURED FONT TABLE, not chosen. Worst-case getFontHeight
// over all twelve manifest devices, the same sweep drawSetGrid's own note
// records: FONT_XTINY 0.0817h, FONT_TINY 0.1115h, FONT_SMALL 0.1214h.
//
//   band top     the title is FONT_SMALL at 0.13h, so its box ends at 0.2514h
//   band bottom  the sub row is at 0.78h
//   band         0.5286h of usable height
//   grid ink     first label row anchor to bottom value row box end
//                = (0.749 - 0.44) + 0.1115 = 0.4205h
//   slack        0.5286 - 0.4205 = 0.1081h, split evenly = 0.054h each side
//   first row    0.2514 + 0.054 = 0.3054h  ->  dy = 0.3054 - 0.44 = -0.1346
//
// Rounded to -0.135, which puts the grid's rows at 0.305 / 0.398 / 0.520 /
// 0.614 h and its ink inside 0.305h .. 0.7255h: 0.0536h clear of the title's
// box and 0.0545h clear of the sub row. The admissible range for this constant
// is [-0.1886, -0.0805] -- outside it one end or the other collides -- and
// GridGate.test_gg_c2_theDoneGridClearsTheTitleAndTheSubRow reds if a later
// edit leaves it.
//
// CHARACTERS AND BOXES ARE NOT INK (#121). Every figure above is a FONT BOX
// taken from a local per-device measurement; no (:test) in CI can obtain a font
// metric, so this is the same convention drawSetGrid and the #110 arc use and
// it is conservative in the same way. Nothing here claims how the screen looks.
const GRID_DONE_DY = -0.135;

class StrongRowView extends Ui.View {

    // step types
    hidden const STEP_WORK = 0;
    hidden const STEP_REST = 1;
    hidden const STEP_GATE = 2;
    hidden const STEP_DONE = 3;
    hidden const STEP_WARM = 4;
    hidden const STEP_COOL = 5;

    // ---- workout params (loaded from settings) ----
    hidden var mWorkoutEnabled;
    hidden var mNumWork;
    hidden var mWorkSec;
    hidden var mRestSec;
    hidden var mTgtLo;
    hidden var mTgtHi;
    hidden var mGate;
    hidden var mWarmCool;
    // #110: the HEART-RATE target band, in bpm. Named apart from mTgtLo/mTgtHi
    // (which are stroke rate, in spm) because confusing the two is the exact
    // failure #110 calls out.
    // #123: the distance-per-stroke benchmark, in metres. CLAMPED IN CODE and
    // not only in settings.xml -- #21 is precisely the defect of a range
    // declared there and enforced nowhere, and Connect IQ Properties survive an
    // app update while a .set file is not re-clamped on load.
    hidden var mDpsBench;
    hidden var mHrLo;
    hidden var mHrHi;
    // ERG MODE. THREE settings, and the split between the first two is the
    // maintainer's own: ergMode says the athlete is on a machine, ergPowerUnits
    // says what to show while they are. The second defaults ON and only means
    // anything when the first is on -- which is why the predicate that reads
    // them is a named static (useWorkUnits) rather than an `&&` at three call
    // sites free to disagree.
    //
    // ALL THREE ARE CLAMPED IN CODE, never only in settings.xml (#21).
    hidden var mErgMode;
    hidden var mErgPowerUnits;
    hidden var mJouleBench;

    // ================= stroke detector tunables =============================
    hidden const REQ_RATE = 25;
    // MIN_RATE / MAX_RATE / FAST_NEEDS_LOCK / LOCK_SNAP_K moved to MODULE scope
    // (top of this file, the #149 block) so the pure statics of the output
    // stage can name them. A class `const` is an instance member and a static
    // cannot resolve one. Values unchanged; the sites below now read `$.NAME`.
    hidden const FC_SLOW = 0.10;
    hidden const FC_FAST = 1.80;
    hidden const FC_ENV  = 0.30;
    hidden const FC_VAR  = 0.03;
    hidden const THR_K    = 0.60;
    hidden const THR_LO_K = 0.40;
    hidden const MIN_THR  = 40.0;
    hidden const NPER = 5;
    hidden const QUIET_S = 5.0;       // no strokes while filters settle at boot
    // autocorrelation period gate
    hidden const AC_HZ       = 5.0;   // decimated sample rate
    hidden const AC_BUF      = 128;   // ~25 s of history
    hidden const AC_WIN      = 64;    // products per lag
    hidden const AC_MIN_N    = 40;    // don't estimate before ~8 s of data
    hidden const AC_MIN_CONF = 0.35;  // below this: no period lock
    hidden const AC_SUB_K    = 0.50;  // subharmonic must reach this vs best
    hidden const REFRACT_FRAC = 0.72; // fraction of locked period a peak is ignored
    // R-R / HRV. RR_MIN_MS/RR_MAX_MS/RR_PER_REC/RR_INVALID live at module scope
    // (top of file) so the static helpers filterRr()/packRr() and the unit tests
    // can reference them -- a Monkey C class `const` is an instance member, not
    // reachable from a static method or via the class name.
    hidden const RR_ART_K  = 0.30;    // reject successive jumps > 30% as artifacts
    hidden const RR_NDIFF  = 90;      // rMSSD window: last ~90 beat pairs

    hidden var mDt;
    hidden var mAlphaSlow;
    hidden var mAlphaFast;
    hidden var mAlphaEnv;
    hidden var mAlphaVar;
    // per-axis filter state (gravity, band-pass, activity variance)
    hidden var mGravX; hidden var mGravY; hidden var mGravZ;
    hidden var mLpX;   hidden var mLpY;   hidden var mLpZ;
    hidden var mVarX;  hidden var mVarY;  hidden var mVarZ;
    hidden var mAxis;
    hidden var mEnv;
    hidden var mArmed;
    hidden var mSampleIdx;
    hidden var mLastStrokeT;
    hidden var mLastPeriod;
    hidden var mPeriods;
    hidden var mPIdx;
    hidden var mPCount;
    hidden var mRate;
    // #149: the rate this athlete has ESTABLISHED, in spm, or 0.0 for "none
    // yet". Advanced once per registered stroke (updateRateBase) and cleared
    // when the stroke ring times out, so a long gap degrades to the absolute
    // gate rather than to a stale baseline from a previous piece.
    hidden var mRateBase;
    // #149 round 2: strokes still to be withheld from the baseline. Set to NPER
    // whenever a stroke registers DURING A PAUSE and counted down after the
    // resume, because mPeriods survives the pause and the first medians after it
    // are still the pause's. See updateRateBase for the measurement.
    hidden var mBaseHold;
    hidden var mStrokeCount;

    // #125: strokes taken ON A PIECE, as against mStrokeCount's every stroke of
    // the recording. TWO counters rather than one re-gated counter, and the
    // reason is that both numbers are wanted and only one fits on the footer.
    //
    // WHAT EACH ONE MEANS, so a later reader does not have to infer it:
    //
    //   mStrokeCount  every stroke the detector accepted while recording and
    //                 unpaused, whatever step was in force. Session-cumulative.
    //                 It is what mSetStrokeBase / mLastSetStrokes take their
    //                 delta from, so its gate must NOT be narrowed: the
    //                 per-interval figure is a difference between two readings
    //                 of THIS counter.
    //   mWorkStrokes  the subset taken while the athlete was on a piece --
    //                 inside a WORK interval, or anywhere at all in free-row
    //                 mode, which has no steps and where every stroke is the
    //                 piece. See strokeCounts, which is the whole rule.
    //
    // WHY THE FOOTER SHOWS THE SECOND. #125's own words: "those strokes are
    // mainly to position the boat into a good heading and location for the
    // intervals, and tend to be quicker and lower force. The values we want to
    // track are the drive strokes during the intervals." Positioning and rest
    // paddling bias a session stroke count UP, and hardest on the short
    // sessions where they are the largest fraction of it.
    //
    // WORK ONLY, NOT WORK+REST, which is the open question #125 asks to be
    // settled before implementing. The boundary chosen is the one the app
    // ALREADY uses for every other per-interval aggregate -- `mSetNum > 0`,
    // which gates the heart-rate fold and the erg work integrator in onTick and
    // is bounded by beginWorkAccum / latchWorkAccum. One boundary for every
    // aggregate means the footer can never disagree with the grid about what an
    // interval was; two boundaries would guarantee that it eventually does.
    // Rest paddling is as unrepresentative as positioning paddling, which is
    // the reading #125 calls "literal to 'the drive strokes during the
    // intervals'".
    //
    // WARM, GATE, COOL and DONE are excluded under either reading, and are
    // named here rather than left to be inferred: none of them is inside a work
    // interval, so none of them reaches this counter.
    //
    // NOT DISPLAYED IS NOT NOT RECORDED, and neither counter is a FIT value.
    // Every per-record field is written exactly as before -- this changes one
    // string on one row of the display and nothing that reaches the file. The
    // session-scope total_corrective_strokes is the OTHER half of #125 and is
    // deliberately untouched here: it is a recorded aggregate, so narrowing it
    // changes what a shipped field means, and that needs its own decision
    // rather than riding along with a display fix.
    hidden var mWorkStrokes;

    // ---- per-work-interval accumulators (#109) --------------------------
    // RAW TOTALS ONLY. Every figure the rest view shows is derived at read
    // time from these by a pure static, so two cells on the same screen can
    // never disagree about the interval they describe -- which is exactly what
    // latching derived values would allow.
    //
    // "Base" members are the reading at the interval's start; the interval's
    // own total is the delta. Activity.Info exposes no lap-scoped distance and
    // mStrokeCount is session-cumulative, so a delta is the only way to get
    // either one per-step.
    hidden var mSetNum;          // 1-based work interval currently accumulating, 0 = none
    hidden var mSetDistBase;     // elapsedDist() when the interval began
    hidden var mSetPausedDist;   // distance accrued while paused, to subtract
    hidden var mPauseDistAt;     // elapsedDist() at the moment of the pause
    hidden var mSetStrokeBase;   // mStrokeCount when the interval began
    hidden var mSetHrSum;
    hidden var mSetHrN;
    // ERG: WORK, in joules, integrated from the power samples of THIS interval.
    //
    // AN ACCUMULATOR, NOT A BASE-AND-DELTA, and that is forced rather than
    // stylistic: Activity.Info exposes no cumulative work reading to take a
    // delta of, so the only way to get interval work is to integrate the power
    // samples. It is reset at WORK entry and read at WORK exit, which is what
    // excludes rest-interval samples for the same reason mSetHrSum excludes
    // them -- and it is accumulated under the SAME `mSetNum > 0` gate the
    // heart-rate sum uses, so a rest tick never reaches it in the first place.
    //
    // A SUM AND A COUNT, exactly like mSetHrSum / mSetHrN above -- and the
    // COUNT is the half an earlier revision of this comment left out while
    // claiming parity with the heart-rate pair. That omission was the whole
    // defect: mSetHrN is what makes the HR mean immune to a dropout (setAvgBpm
    // divides by the samples actually taken), and mLastSetDist is immune for a
    // different reason again (latchWorkAccum takes an odometer delta, which
    // cannot lose a sample). An INTEGRAL of instantaneous samples has neither
    // defence, so it needs its own count. See WORK_COVER_MIN.
    //
    // mErgWorkN IS THE PRESENCE TEST, never `mErgWorkJ > 0.0`. Zero joules with
    // samples taken is an athlete who produced no work; zero joules with NO
    // samples is an athlete with no power meter, and the two must not render
    // the same. That distinction is the whole of #86 / #107. `mErgWorkN > 0` is
    // exactly the boolean this member replaced, so nothing about presence
    // changed when the count arrived -- what the count adds is COVERAGE, which
    // a boolean cannot express.
    hidden var mErgWorkJ;
    hidden var mErgWorkN;

    // The LATCH: the last completed work interval, frozen at its boundary.
    hidden var mLastSetValid;
    hidden var mLastSetNum;
    hidden var mLastSetSec;
    hidden var mLastSetDist;
    hidden var mLastSetStrokes;
    hidden var mLastSetHrSum;
    hidden var mLastSetHrN;
    // ERG: the interval's work and its sample COUNT, latched together with the
    // rest. BOTH, never just the number -- latching the joules alone would make
    // "no power source" indistinguishable from "no work done" at read time,
    // which is the trap this pair exists to close, and it would also lose the
    // coverage the count carries. Read against mLastSetSec by workCoverOk.
    hidden var mLastSetWorkJ;
    hidden var mLastSetWorkN;

    // autocorrelation state
    hidden var mDecim;
    hidden var mAcDt;
    hidden var mAcBuf;
    hidden var mAcIdx;
    hidden var mAcCount;
    hidden var mAcAccum;
    hidden var mAcAccumN;
    hidden var mAcBatch;
    hidden var mAcPeriod;
    hidden var mAcLowConf;
    // #149: the LAST COMPUTED autocorrelation confidence, or LOCK_CONF_NONE
    // when none has been computed (before the first estimate, and whenever the
    // signal window carries no energy at all). Written by updateAutocorr, read
    // only by the diagnostic write in onTick -- it gates nothing.
    //
    // "LAST COMPUTED", precisely: updateAutocorr returns early when there is
    // not yet enough history, when the lag range collapses, or when the window
    // is too short. Those rounds compute nothing and leave this standing, which
    // is what makes the field's name honest.
    hidden var mAcConf;

    // #110 heart-rate state. THREE fields, and the split is the whole point:
    //   mHrBpm     the last VALID reading. Never consulted for presence.
    //   mLastHrMs  when that reading was taken (System.getTimer()).
    //   mHrEver    explicit "have we ever had a reading". Never DERIVED from
    //              mHrBpm.
    // Presence is (mHrEver AND fresh), never (mHrBpm > 0) -- because unlike
    // outputRate(), which genuinely returns 0.0 when nothing is measured (the
    // premise rateColour's guard rests on), the last bpm SURVIVES in the field
    // after the heart-rate source drops. Deriving absence from the value there
    // is the #86 / #107 defect class.
    hidden var mHrBpm;
    hidden var mLastHrMs;
    hidden var mHrEver;

    // ---- display-cue state ------------------------------------------------
    // THREE fields, and none of them is a rate. The cue is a ZONE -- the
    // instruction "row harder / hold / ease off" -- and the rate it was derived
    // from is deliberately not kept, so nothing downstream can start reading a
    // filtered NUMBER out of this layer. The number on screen and the number in
    // the file both come straight from outputRate().
    //
    //   mCueZone   the zone currently DISPLAYED (a CUEZ_* code)
    //   mCueCand   the zone the raw rate has been asking for
    //   mCueSince  when it started asking, on the nowMs() clock (ms)
    //
    // Advanced ONLY from onUpdate. Nothing on the onTick path -- the path that
    // writes row_stroke_rate, dist_per_stroke and corrective_rate -- reads or
    // writes any of them, which is what makes "the file is unaffected" a
    // structural property rather than a promise.
    hidden var mCueZone;
    hidden var mCueCand;
    hidden var mCueSince;

    // R-R / HRV state
    hidden var mRrOk;
    hidden var mLastRrMs;     // last R-R BATCH arrival (display indicator)
    hidden var mLastBeatMs;   // last RANGE-accepted beat (rMSSD freshness + gap reset)
    hidden var mRrLast;
    hidden var mDiffSq;
    hidden var mDiffIdx;
    hidden var mDiffCount;
    hidden var mRmssd;
    hidden var mRmssdSum;
    hidden var mRmssdN;

    // ================= app / workout state ==================================
    hidden var mSensorOk;
    hidden var mGpsQual;
    hidden var mTimer;
    hidden var mSession;
    hidden var mFitRate;
    hidden var mFitDps;
    hidden var mFitRr;
    hidden var mFitRmssd;
    hidden var mFitAvgRmssd;
    hidden var mFitCorr;
    hidden var mFitCorrTotal;
    hidden var mCorrAccum;
    hidden var mCoreSensor;
    hidden var mFitCore;
    hidden var mFitSkin;
    hidden var mFitMaxCore;
    hidden var mFitCtDiag;
    hidden var mFitHsi;
    // #149's lock-state diagnostics, record scope, ids 20-22.
    hidden var mFitLockRate;
    hidden var mFitLockConf;
    hidden var mFitLockLow;
    // #149 part 2's gate-input diagnostics, record scope, ids 23-24.
    hidden var mFitRateRaw;
    hidden var mFitRateBase;
    // The STEP MARKS. Record scope, ids 17-18; lap scope, ids 25-26.
    hidden var mFitStepType;
    hidden var mFitIvlNum;
    hidden var mFitLapStep;
    hidden var mFitLapIvl;
    // ERG MODE's fields, ids 12-16. Four record-scope, one session-scope.
    hidden var mFitErgPower;
    hidden var mFitErgJps;
    hidden var mFitErgDiag;
    hidden var mFitErgWork;
    hidden var mFitErgCad;
    // SESSION-scope work, in joules, and its sample count. Separate from the
    // per-interval pair above because the two have different lifetimes: the
    // interval accumulator is reset at every WORK entry, this one at every
    // START, and only this one survives a rest.
    //
    // Reset in startSession() alongside mCorrAccum, mMaxCore and the #13 flags,
    // because startSession is where the SESSION-scope FIT field this feeds
    // comes into existence.
    //
    // AN EARLIER REVISION OF THIS COMMENT JUSTIFIED THE PLACEMENT WITH A FALSE
    // CLAIM ABOUT CONTROL FLOW -- that "beginSessionAccum is called from
    // startWorkout only, so the FREE-ROW path never reaches it". It is not
    // true, in both directions: onPrimary's free-row arm calls
    // beginSessionAccum(), and so does initialize(), which startSession has no
    // analogue for. The file already said so correctly at beginWorkAccum's
    // caller note ("beginSessionAccum(), which every recording-start path
    // calls"), so the branch briefly held two mutually exclusive statements
    // about one function. beginSessionAccum WOULD reset this correctly; the
    // real reason it does not live there is that that function owns the
    // INTERVAL-scope accumulators, and a session-scope reset in it would blur
    // the boundary the two lifetimes depend on.
    hidden var mErgSessJ;
    hidden var mErgSessN;
    hidden var mMaxCore;
    // #13. "Has a real reading ever been written to this record field in this
    // session?" -- one flag per field, not one for the pair, because #17 gave
    // core and skin SEPARATE freshness stamps precisely so they can go stale
    // independently. A shared flag would let the first core reading license a
    // skin dropout marker on a field that had never carried a measurement.
    //
    // These are about WRITES, not about the pod: they are updated in the same
    // onTick block as the setData they gate, from the same sample, so a tick
    // the recording gate skipped cannot advance them. See ctTempWritable.
    hidden var mCoreEver;
    hidden var mSkinEver;
    hidden var mStartMs;

    hidden var mSteps;
    hidden var mStepIdx;
    hidden var mStarted;
    // #74: "START was pressed and recording did NOT begin". Distinct from
    // !mStarted, which also covers "not pressed yet" -- conflating the two would
    // tell the athlete to press a button they have already pressed. Read only by
    // footState; never gates recording logic.
    hidden var mRecFailed;
    hidden var mPaused;
    hidden var mStepStartMs;
    hidden var mPausedAt;

    function initialize() {
        View.initialize();
        resetDetector();
        // #8: the time base is now a pure function of compile-time constants,
        // computed once here. It can never be derived from runtime data again.
        // Must run AFTER resetDetector(), which owns the rest of the DSP state.
        computeCoeffs();
        mSensorOk   = false;
        mGpsQual    = 0;
        // Explicit, though Monkey C already defaults an unassigned member to
        // null. shutdown()'s `if (mTimer != null)` and onLayout's idempotency
        // guard both read this before anything writes it, and a precondition
        // that load-bearing should be a statement in this file rather than a
        // language default a reader has to know. Behaviour-identical.
        mTimer      = null;
        mSession    = null;
        mFitRate    = null;
        mFitDps     = null;
        mFitRr      = null;
        mFitRmssd   = null;
        mFitAvgRmssd = null;
        mFitCorr    = null;
        mFitCorrTotal = null;
        mCorrAccum  = 0.0;
        mCoreSensor = null;
        mFitCore    = null;
        mFitSkin    = null;
        mFitMaxCore = null;
        mFitCtDiag  = null;
        mFitHsi     = null;
        mFitLockRate = null;
        mFitLockConf = null;
        mFitLockLow  = null;
        mFitRateRaw  = null;
        mFitRateBase = null;
        mFitErgPower = null;
        mFitErgJps   = null;
        mFitErgDiag  = null;
        mFitErgWork  = null;
        mFitErgCad   = null;
        mErgSessJ    = 0.0;
        mErgSessN    = 0;
        mMaxCore    = 0.0;
        mCoreEver   = false;      // #13
        mSkinEver   = false;      // #13
        mHrBpm      = 0;
        mLastHrMs   = 0;
        mHrEver     = false;
        // No cue until a work step has produced a reading. CUEZ_NONE is the
        // "nothing to say" state, not a zone that happens to be off the band.
        mCueZone    = $.CUEZ_NONE;
        mCueCand    = $.CUEZ_NONE;
        mCueSince   = 0;
        mRrOk       = false;
        mLastRrMs   = 0;
        mLastBeatMs = 0;
        mRrLast     = 0;
        mDiffSq     = new [RR_NDIFF];
        mDiffIdx    = 0;
        mDiffCount  = 0;
        mRmssd      = 0.0;
        mRmssdSum   = 0.0;
        mRmssdN     = 0;
        mStartMs    = 0;
        mStarted    = false;
        mRecFailed  = false;
        mPaused     = false;
        mStepIdx    = 0;
        mStepStartMs = 0;
        mPausedAt   = 0;
        // #126: mStrokeCount was reset ONLY in resetDetector(), whose sole
        // caller is this function -- so it was app-lifetime while the footer
        // rendered it as the recording's count. Row twice without relaunching
        // and the second row's footer included the first row's strokes.
        // Initialised here, and reset per session in beginSessionAccum().
        mStrokeCount = 0;
        // #125: initialised beside mStrokeCount and reset per session in
        // beginSessionAccum() beside it, for the identical #126 reason -- a
        // counter reset only in resetDetector() is app-lifetime, and the second
        // row of an unrelaunched app inherits the first row's strokes.
        mWorkStrokes = 0;
        beginSessionAccum();
        loadSettings();
        buildWorkout();
    }

    // ---- settings ----
    hidden function getProp(key, dflt) {
        var v = dflt;
        try {
            var p = App.Properties.getValue(key);
            if (p != null) { v = p; }
        } catch (e) {}
        return v;
    }

    hidden function loadSettings() {
        mWorkoutEnabled = getProp("workoutEnabled", true);
        mNumWork = getProp("numIntervals", 5).toNumber();
        if (mNumWork < 1) { mNumWork = 1; }
        var wm = getProp("workMinutes", 4.0);
        var rm = getProp("restMinutes", 2.0);
        mWorkSec = (wm * 60.0).toNumber();
        mRestSec = (rm * 60.0).toNumber();
        if (mWorkSec < 5) { mWorkSec = 5; }
        if (mRestSec < 0) { mRestSec = 0; }
        mTgtLo = getProp("targetLo", 16).toNumber();
        mTgtHi = getProp("targetHi", 18).toNumber();
        if (mTgtHi < mTgtLo) { var t = mTgtLo; mTgtLo = mTgtHi; mTgtHi = t; }
        // #110: the HEART-RATE band, in bpm. Defaults 116-130 are the
        // maintainer's measured target (a stated ~123 bpm intent on a 68-minute
        // durability row, +/-7), not a guess and not doctrine -- they are
        // configuration and are expected to be set per athlete.
        //
        // CLAMPED IN CODE, unlike the four settings #21 is open about. The
        // bounds are HR_DISP_LO/HR_DISP_HI, i.e. the arc's own display range,
        // which is what makes "the band marker always lands on the track" an
        // invariant rather than a hope: no persisted or sideloaded value can
        // put a mark off the end of the scale. Connect IQ Properties survive an
        // app update and a .set file is not re-clamped on load, so declaring
        // the range in settings.xml is not enough on its own -- that is exactly
        // #21's finding, and this does not add to it.
        mDpsBench = getProp("dpsBenchmark", 6.0).toFloat();
        if (mDpsBench < 1.0)  { mDpsBench = 1.0; }
        if (mDpsBench > 20.0) { mDpsBench = 20.0; }
        var hb = hrClampBand(getProp("hrLo", 116).toNumber(),
                             getProp("hrHi", 130).toNumber());
        mHrLo = hb[0];
        mHrHi = hb[1];
        mGate = getProp("pressToContinue", true);
        mWarmCool = getProp("warmupCooldown", true);
        // ERG MODE. CLAMPED IN CODE, all three, and that is #21's finding
        // applied rather than restated: a range declared in settings.xml is
        // enforced by the Garmin Connect UI and by nothing else. Connect IQ
        // Properties survive an app update and a sideloaded .set file is not
        // re-clamped on load, so a value this code refuses to accept is the
        // only kind that cannot arrive.
        //
        // THE TWO BOOLEANS GO THROUGH ergFlag, which is not defensive noise.
        // useWorkUnits evaluates `a && b`, and Monkey C's `&&` on a
        // non-Boolean is not a safe operation -- a property corrupted to a
        // Number would take the display path down at 4 Hz. ergFlag makes both
        // members Booleans by construction, so the predicate is total.
        mErgMode       = ergFlag(getProp("ergMode", false), false);
        mErgPowerUnits = ergFlag(getProp("ergPowerUnits", true), true);
        // THROUGH jouleClampBench, not inline: an inline clamp here is
        // unreachable from every (:test) in the repository, and the case that
        // claimed to pin it was pinning a copy inside the test probe instead.
        // See that function.
        mJouleBench = jouleClampBench(
            getProp("jouleBenchmark", $.JOULE_BENCH_DEF).toFloat());
    }

    // reload from Garmin Connect settings (only when not mid-session)
    function reloadSettings() {
        if (mStarted) { return; }
        loadSettings();
        buildWorkout();
        Ui.requestUpdate();
    }

    hidden function buildWorkout() {
        mSteps = [];
        if (mWarmCool) {
            mSteps.add({ :type => STEP_WARM });
        }
        for (var i = 1; i <= mNumWork; i++) {
            mSteps.add({ :type => STEP_WORK, :dur => mWorkSec, :idx => i });
            if (i < mNumWork) {
                if (mRestSec > 0) {
                    mSteps.add({ :type => STEP_REST, :dur => mRestSec, :nextn => i + 1 });
                }
                if (mGate) {
                    mSteps.add({ :type => STEP_GATE, :nextn => i + 1 });
                }
            }
        }
        if (mWarmCool) {
            mSteps.add({ :type => STEP_COOL });
        }
        mSteps.add({ :type => STEP_DONE });
    }

    hidden function resetDetector() {
        mGravX = 0.0; mGravY = 0.0; mGravZ = 0.0;
        mLpX   = 0.0; mLpY   = 0.0; mLpZ   = 0.0;
        mVarX  = 0.0; mVarY  = 0.0; mVarZ  = 0.0;
        mAxis        = 0;
        mEnv         = 0.0;
        mArmed       = true;
        mSampleIdx   = 0;
        mLastStrokeT = -100.0;
        mLastPeriod  = 0.0;
        mPeriods     = new [NPER];
        mPIdx        = 0;
        mPCount      = 0;
        mRate        = 0.0;
        mRateBase    = 0.0;
        mBaseHold    = 0;
        // #126: mStrokeCount is deliberately NOT reset here. resetDetector runs
        // ONCE PER APP LAUNCH -- initialize() is its only caller -- and owns DSP
        // state; the stroke count is session-scoped and is reset by
        // beginSessionAccum(), which every recording-start path calls.
        // mDecim / mAcDt deliberately NOT seeded here (#8): computeCoeffs() is
        // their single source of truth and runs immediately after this in
        // initialize(). The old hardcoded 5 / 0.2 duplicated computeCoeffs(25)
        // exactly, and duplicated constants are what drift.
        mAcBuf       = new [AC_BUF];
        for (var i = 0; i < AC_BUF; i++) { mAcBuf[i] = 0.0; }
        mAcIdx       = 0;
        mAcCount     = 0;
        mAcAccum     = 0.0;
        mAcAccumN    = 0;
        mAcBatch     = 0;
        mAcPeriod    = 0.0;
        mAcLowConf   = 0;
        mAcConf      = $.LOCK_CONF_NONE;   // #149: nothing computed yet
    }

    // Allocation seams for the two app-lifetime resources onLayout owns. Split
    // out for exactly the reason CoreTempSensor.makeChannel is
    // (CoreTempSensor.mc:171-174): the real constructors are unreachable from a
    // (:test). A real Timer.Timer would keep firing onTick inside the test
    // process for the rest of the run, and a real CoreTempSensor's ANT
    // allocation always throws under the headless simulator and drives the
    // retry ladder -- so without this seam nothing can reach the code that
    // decides WHETHER to allocate, which is the whole of #11.
    //
    // `hidden` is protected in Monkey C, so a probe subclass substitutes
    // counting stubs. The calls in onLayout below are UNQUALIFIED on purpose so
    // they dispatch to the override -- the trap CoreProbe.scheduleReopen
    // documents at CoreTempSensorTest.mc:79-81.
    hidden function makeCoreSensor() { return new CoreTempSensor(); }
    hidden function makeTimer()      { return new Timer.Timer(); }

    // #11: the two allocations below are guarded, so a repeat onLayout cannot
    // orphan the previous Timer or the previous CORE ANT channel.
    //
    // REACHABILITY IS UNVERIFIED, IN BOTH DIRECTIONS, and this comment claims
    // neither answer: nothing in this repository has produced a second onLayout
    // on a live view, and nothing here shows one is impossible. Settling it
    // needs a human-driven simulator session -- the [Local] issue linked from
    // #11. The guards are correct under either answer, which is why they land
    // ahead of it:
    //   * if a second onLayout is reachable, they stop a second 250 ms timer
    //     that would double every onTick from then on. mCorrAccum integrates
    //     across the whole recording, so the total_corrective_strokes
    //     stopAndSave derives from it is inflated by a factor strictly between
    //     1x and 2x -- 2x only if the second onLayout lands before START, and
    //     approaching 1x the later it lands. (An earlier revision of this
    //     comment said "exactly 2x" unconditionally, which is true only for
    //     the pre-START case.) The previous CoreTempSensor's ANT channel also
    //     keeps searching with nothing left able to close() it;
    //   * if it is not reachable, behaviour is identical -- one call, one
    //     allocation -- for two null comparisons per app launch.
    //
    // PRESERVE, do not tear down and rebuild. #11 suggests either. Rebuilding
    // the sensor mid-row would release a tracking ANT channel and reset the
    // retry ladder (CoreTempSensor.mc:341-348), trading a leak for a data
    // dropout; the timer is guarded the same way for the same reason.
    // shutdown() stays the single teardown point.
    //
    // mTimer.start is INSIDE the guard, not after it: restarting a timer that
    // is already running is the same defect measured from the other end.
    //
    // startSensor()/startGps() are deliberately NOT guarded. Neither allocates
    // something that can be orphaned: Sensor.unregisterSensorDataListener()
    // takes no argument (see shutdown), which is what says Connect IQ holds a
    // single listener slot rather than a list, so a second registration
    // replaces; and enableLocationEvents sets a mode. Guarding them would also
    // destroy the only path that could ever recover from the double
    // registration failure startSensor handles by setting mSensorOk = false.
    // BUILD, THEN PUBLISH -- the allocation-side half of the rule shutdown()
    // states for teardown. There, a handle is cleared BEFORE the release call
    // that might throw; here, a handle is assigned only AFTER the call that
    // arms it has succeeded. Both say the same thing: a field must never hold
    // something the guard would read as live but which is not.
    //
    // `mTimer = makeTimer()` followed by `mTimer.start(...)` published a Timer
    // that was not yet armed, so a throw from start() left a non-null,
    // never-started Timer -- and the guard above reads that as live and never
    // re-arms, for the life of the app. On base main the same throw was
    // harmless: onLayout allocated unconditionally, so the next call simply
    // tried again. The guard is what converts "retry next time" into "never
    // again", which is why the protection belongs here.
    //
    // mCoreSensor needs no equivalent and deliberately does not get one:
    // `mCoreSensor = makeCoreSensor()` assigns only if the constructor
    // returns, so a throw from the ANT channel open leaves the field null and
    // the next onLayout retries. (That such a throw also skips the timer block
    // is base main's behaviour, unchanged by the guards, so it is not fixed
    // here.)
    //
    // The throw still PROPAGATES; no catch is added. shutdown() swallows
    // because a throw there would lose the recorded row -- allocation has no
    // such asset to protect, and silently continuing without a tick timer would
    // hide an app that cannot function. Base main propagated it too.
    function onLayout(dc) {
        startSensor();
        startGps();
        if (mCoreSensor == null) { mCoreSensor = makeCoreSensor(); }
        if (mTimer == null) {
            var t = makeTimer();
            // $.TICK_MS, not a literal 250: this period is now the divisor of a
            // time-integrated quantity (erg work), and the timer and the
            // integrator must read the same number by construction rather than
            // by two people remembering. Behaviour-identical -- TICK_MS is 250.
            t.start(method(:onTick), $.TICK_MS, true);
            mTimer = t;
        }
    }

    // #110: sample the heart rate. UNCONDITIONAL, so the reading is CURRENT the
    // moment a WORK or REST step resumes rather than a tick stale -- sampling
    // continues while paused and during every step type, including the ones the
    // arc is not drawn on.
    //
    // (The arc itself is drawn only on STEP_WORK and STEP_REST; see the gate in
    // onUpdate. Sampling and drawing are deliberately not the same set.)
    //
    // Wrapped in try/catch because this is the only platform call the arc makes
    // and a throw here must not cost the tick everything below it. The
    // shipping-code rule this follows is getProp's (above), not onLayout's:
    // onLayout deliberately propagates because an app with no tick timer should
    // not run silently, whereas a heart rate is an ornament on two priorities
    // that must keep working without it.
    //
    // THE GUARD SPANS THE WHOLE BODY, not just the platform read. sampleHr() is
    // the FIRST statement of onTick, so a throw anywhere in here skips every
    // FitContributor setData for that tick -- and record-scope fields LATCH, so
    // a skipped write silently re-emits the previous value rather than leaving
    // a gap. A narrower guard would have made the comment above false for the
    // comparison and the toNumber() conversion, which are exactly the two
    // operations an unexpected type would throw on.
    hidden function sampleHr() {
        try {
            var bpm = null;
            var ai = Activity.getActivityInfo();
            if (ai != null) { bpm = ai.currentHeartRate; }
            // `bpm > 0` HERE is a validity filter on a READING -- zero bpm is
            // not a living heart -- and it is emphatically NOT the absence
            // test. Absence is carried by mHrEver and mLastHrMs, which is the
            // distinction #110 requires and the one #86 and #107 each got wrong.
            if (bpm != null && bpm > 0) {
                // Ordered so the three fields cannot be torn: mHrEver is set
                // LAST, so hrHave can never see "ever seen" against a stamp
                // that was not written.
                mHrBpm    = bpm.toNumber();
                mLastHrMs = System.getTimer();
                mHrEver   = true;
            }
        } catch (e) {}
    }

    function onTick() as Void {
        sampleHr();
        // #109: fold the reading into the current work interval. Gated on the
        // SAME freshness test the arc uses, so a dropout contributes nothing
        // rather than dragging the mean toward a stale value -- and gated on
        // !mPaused so a rest taken mid-interval is not averaged in as work.
        if (mSetNum > 0 && mStarted && !mPaused
                && hrHave(mHrEver, mLastHrMs, nowMs(), $.HR_FRESH_MS)) {
            mSetHrSum += mHrBpm;
            mSetHrN   += 1;
        }
        if (mStarted && !mPaused) {
            if (mFitRate != null) { mFitRate.setData(outputRate()); }
            if (mFitDps != null)  { mFitDps.setData(distPerStroke(currentSpeed())); }
            // #15: only log/accumulate rMSSD while beats are actually fresh
            // (keyed off the last RANGE-accepted beat, not batch arrival).
            //
            // What this definitively fixes: avg_rmssd. The accumulator is pure
            // in-app arithmetic, so a dropout contributes nothing to the mean.
            //
            // What it does NOT fix: the per-record rmssd trace. Record-scope
            // FitContributor fields LATCH once setData has been called even
            // once -- confirmed byte-exact by #36 and reconfirmed by #48's
            // probe_skip (SIMULATOR, fr965 / SDK 9.2.0 -- treat hardware and
            // other SDKs as expected-same but unmeasured): from then on a
            // skipped write re-emits the last value on every subsequent
            // record. Only records BEFORE the first write carry the type's
            // never-set invalid pattern (#48 measured 0xFFFFFFFF exactly
            // where a field had NOT YET BEEN SET AS OF THAT RECORD -- REC 1
            // included, since that record committed before any setData).
            // That is a byte-pattern fact; what a decoder RENDERS for such a
            // record is still a [Local] question, so do not upgrade it to
            // "absence". Once a real value HAS been written in the
            // session, a dropout leaves the trace carrying the last
            // pre-dropout value and NO in-app change can do better:
            //   * writing 0.0 is an in-band lie ("perfect regularity") -- and
            //     note the write below has no value guard while the
            //     accumulator does, so 0.0 IS logged today; #68 enumerates
            //     five such windows (four reachable today) and owns the fix.
            //     That defect is FIXABLE (the guard leaves the field unset in
            //     the not-yet-written windows, so they carry the invalid
            //     pattern instead of 0.0) and is distinct from the
            //     latched-value case above;
            //   * writing NaN is not an absence encoding for a FLOAT field:
            //     #48 measured setData(NaN) landing as 0xFFC00000, a
            //     DIFFERENT pattern from never-set invalid (0xFFFFFFFF) --
            //     it reads as data, not absence, and a NaN can poison
            //     averages, min/max and any downstream aggregate that does
            //     not guard for it, so it is WORSE than the latch, not
            //     merely no better. (Connect's rendering of 0xFFC00000 is
            //     untested -- tracked in #53.)
            //   * setData(null) is NEVER an option: #48 observed it as an
            //     uncatchable native error that escapes try/catch and kills
            //     the app -- a crash, not a no-op.
            // Skipping is still the right call (it is no worse, and writing
            // 0.0 would be an in-band lie). The LATCHED-VALUE half of #15's
            // trace defect is confirmed unfixable in-app and accepted as such
            // (#47, Option B); the 0.0 half is #68's to fix, and the
            // rr_interval analogue is #46's. Do not restate a "gap" claim
            // until a [Local] decode proves it -- and note no open [Local]
            // issue covers rmssd itself (#53 tracks Connect's rendering of
            // the NaN pattern, which is a different question).
            if (rrIsFresh(System.getTimer(), mLastBeatMs, $.RR_FRESH_MS)) {
                if (mFitRmssd != null) { mFitRmssd.setData(mRmssd); }   // see #68
                if (mRmssd > 0.0) {
                    mRmssdSum += mRmssd;
                    mRmssdN++;
                }
            }
            if (mFitCorr != null) {
                var cr = correctiveRate();
                mFitCorr.setData(cr);
                mCorrAccum += cr / 240.0;   // spm integrated over a 250 ms tick
            }
            // #149: the lock state, WRITTEN UNCONDITIONALLY, which is the
            // opposite of the heat-strain line below and the asymmetry is
            // forced rather than stylistic.
            //
            // heat_strain_index withholds its write because 0.0 a.u. is an
            // ordinary reading on that scale and writing it would fabricate a
            // measurement. THESE THREE HAVE OUT-OF-BAND ENCODINGS FOR ABSENCE
            // (LOCK_RATE_NONE lies outside [MIN_RATE, MAX_RATE]; LOCK_CONF_NONE
            // is negative and a confidence never is), so the fabrication runs
            // the OTHER WAY here: record-scope fields LATCH, so skipping the
            // write on a dropped lock would re-emit the last good lock rate and
            // report a lock that was not up -- on precisely the rows these
            // fields exist to explain. Withholding is not caution here.
            //
            // Every value is a plain in-app read; nothing on this path can
            // throw, so no try/catch is added that would only hide a defect.
            if (mFitLockRate != null) {
                mFitLockRate.setData(lockRateOf(mAcPeriod));
            }
            if (mFitLockConf != null) {
                mFitLockConf.setData(mAcConf);
            }
            if (mFitLockLow != null) {
                mFitLockLow.setData(lockLowClamp(mAcLowConf));
            }
            // #149 part 2: the gate's own INPUTS, written unconditionally
            // alongside the three above and for the identical reason. The
            // mFitRate line at the top of this block records the gate's OUTPUT;
            // these two record what produced it, so a reading the gate zeroed
            // or the lock snapped is visible as a decision rather than only as
            // a result.
            //
            // rate_base is here rather than left to be inferred because it
            // CANNOT be inferred: nextRateBase consumes the pre-gate median, so
            // the recursion is not replayable from a file that lacks it, and
            // the zeroed and snapped cases discard the median outright so
            // row_stroke_rate cannot be inverted either.
            //
            // Both are plain in-app reads through pure statics; nothing on this
            // path can throw, so no try/catch is added that would only hide a
            // defect.
            if (mFitRateRaw != null) {
                mFitRateRaw.setData(rateRawOf(mRate));
            }
            if (mFitRateBase != null) {
                mFitRateBase.setData(rateBaseOf(mRateBase));
            }
            // THE STEP MARKS, written on EVERY tick under this same gate.
            //
            // Unconditional for the reason the lock and gate diagnostics above
            // are: record-scope fields LATCH, so a withheld write re-emits the
            // previous step rather than leaving a gap -- and here that would
            // fabricate work seconds that did not happen, which is the exact
            // opposite of what these two fields exist to prevent. Both have an
            // in-band value for "no workout step" (SFIT_NONE, IVL_NONE), so
            // absence has an encoding and does not need a silence.
            //
            // ONE READ of every input BOTH fields derive from, hoisted into
            // the four locals below, so the kind and the interval number in a
            // record cannot describe two different instants. That is the same
            // rule the erg block states for its power sample.
            //
            // STATED AS A PROPERTY OF THE CODE, because an earlier revision
            // stated it as one the code did not have: it hoisted the step type
            // alone and claimed the pair was safe because of it, while
            // intervalNumOf read mSetNum straight from the field and shared
            // nothing with the hoist. What protected the pair then was
            // ADJACENCY -- nothing running between the two writes -- which is a
            // weaker guarantee and a different one. Retracted; all four inputs
            // are now taken once, above both writes, so inserting a call
            // between the hoists and the writes cannot tear the pair.
            //
            // The hoisted block is pinned by scripts/check_step_fields.py, so
            // un-hoisting it fails by name instead of quietly restoring the
            // torn-pair window.
            //
            // THE BOUNDARY IS ONE TICK COARSE, and that is stated rather than
            // glossed: onTick advances the step machine AFTER this block, so
            // the tick in which a step ends still carries the outgoing step.
            // A record therefore lands on the correct side of a boundary to
            // within one 250 ms tick -- and records commit on the engine's own
            // schedule, not this one, so the true granularity is the record
            // interval. Nothing in the acceptance criterion depends on
            // sub-record alignment.
            var stepT = curStepType();
            var setN  = mSetNum;
            var wEn   = mWorkoutEnabled;
            var sted  = mStarted;
            if (mFitStepType != null) {
                mFitStepType.setData(stepTypeCode(stepT, wEn, sted));
            }
            if (mFitIvlNum != null) {
                mFitIvlNum.setData(intervalNumOf(wEn, sted, setN));
            }
            // ---- ERG MODE: the power sample, its record, and two integrators.
            //
            // ONE READ of the power for the whole tick, so the recorded watts,
            // the recorded joules per stroke and both accumulators describe the
            // same instant. Two reads could straddle a sample boundary and
            // record a work increment the power field does not account for.
            //
            // WRITTEN UNCONDITIONALLY, like the #149 diagnostics above and for
            // the identical reason: record-scope fields LATCH, so skipping the
            // write on a tick with no power source would RE-EMIT the last real
            // reading and report power the athlete did not produce -- on
            // precisely the rows these fields exist to explain. Both sentinels
            // are out of band (negative, and power is non-negative by
            // construction), so absence has an encoding and does not need a
            // silence. Withholding is not caution here.
            //
            // The handles are null unless erg mode was on at START, so a water
            // row reaches none of these three lines.
            //
            // Every value is a plain in-app read through pure statics; nothing
            // on this path can throw, so no try/catch is added that would only
            // hide a defect.
            var ergW = currentPower();
            if (mFitErgPower != null) {
                mFitErgPower.setData(ergPowerOf(ergW));
            }
            if (mFitErgJps != null) {
                mFitErgJps.setData(ergJpsOf(joulesPerStroke(ergW, outputRate())));
            }
            // ONE ergSample() for the diagnostic word AND the cadence value, so
            // the bit and the number describe the same instant. Two reads could
            // record a CAD_OK bit against a cadence the field says was absent.
            var es = ergSample();
            if (mFitErgDiag != null) {
                mFitErgDiag.setData(ergDiagBits(es, mErgMode,
                                    useWorkUnits(mErgMode, mErgPowerUnits)));
            }
            if (mFitErgCad != null) {
                mFitErgCad.setData(ergCadOf(es[3]));
            }
            // THE SESSION TOTAL takes every tick of the recording, rests
            // included -- it is the whole row's work, which is what the
            // maintainer's "work over the session" asks for.
            mErgSessJ = workAccumStep(mErgSessJ, ergW, $.TICK_MS);
            mErgSessN = workCountAfter(mErgSessN, ergW);
            // THE INTERVAL TOTAL takes only ticks inside a WORK interval, under
            // the SAME `mSetNum > 0` gate the heart-rate sum above uses -- which
            // is what excludes rest and gate samples for the same reason they
            // are excluded from the interval's stroke rate. Free-row mode never
            // opens an interval, so mSetNum stays 0 and this never runs there.
            //
            // NOT gated on erg mode: the latch is then always meaningful, so a
            // setting flipped between rows cannot leave the grid reading an
            // interval that was never accumulated.
            //
            // THE COUNT IS INCREMENTED HERE WITH THE SUM, from the same
            // sample, which is what makes coverage knowable at the latch. It
            // counts SAMPLES TAKEN, not ticks elapsed: a tick with no reading
            // adds nothing to either, and the difference between the count and
            // the interval's own duration IS the dropout. See WORK_COVER_MIN.
            if (mSetNum > 0) {
                mErgWorkJ = workAccumStep(mErgWorkJ, ergW, $.TICK_MS);
                mErgWorkN = workCountAfter(mErgWorkN, ergW);
            }
            // #13. Each field decides for itself, from its own sample and its
            // own "ever written" flag -- core and skin carry SEPARATE freshness
            // stamps since #17, so one field's first reading must not license
            // the other's dropout marker. ctTempWritable carries the whole
            // argument for why the two windows get opposite answers.
            //
            // SCOPE, stated rather than implied: these six lines are covered by
            // review only. The predicates are pinned in
            // source/CoreDropoutTest.mc; a regression that rewired the CALL
            // would leave every one of those cases green. #55 owns fuller
            // in-process coverage of onTick.
            if (mFitCore != null) {
                var ct = mCoreSensor.coreTemp();
                if (ctTempWritable(mCoreEver, ct)) { mFitCore.setData(ct); }
                // Latched from the SAME sample the write decision read, in the
                // same block: that is what keeps the flag from running ahead of
                // an actual write.
                mCoreEver = ctTempEverAfter(mCoreEver, ct);
                // Unchanged in behaviour from `if (ct > mMaxCore) { ... }`; see
                // ctMaxCoreAfter for why it is a named function now and why it
                // is deliberately outside the write gate.
                mMaxCore  = ctMaxCoreAfter(mMaxCore, ct);
            }
            if (mFitSkin != null) {
                var sk = mCoreSensor.skinTemp();
                if (ctTempWritable(mSkinEver, sk)) { mFitSkin.setData(sk); }
                mSkinEver = ctTempEverAfter(mSkinEver, sk);
            }
            // #80: the heat strain index. WRITTEN ONLY WHEN THERE IS ONE, which
            // is the opposite of the core/skin lines above it, and the asymmetry
            // is forced rather than stylistic.
            //
            // coreTemp()/skinTemp() return 0.0 when nothing is current, and 0.0
            // is outside the accepted 25-45 C band by construction, so a reader
            // can recognise it. THE STRAIN SCALE HAS NO SUCH VALUE: 0.0 a.u.
            // means "no thermal strain", an ordinary reading, so writing it on
            // a dropout would fabricate a measurement that no downstream
            // consumer could tell from a real one. hsiWritable is the one line
            // that decides this, and it exists so a later "why is this not
            // guarded like max_core_temperature" edit has to red a test first.
            //
            // WHAT SKIPPING ACTUALLY PRODUCES, stated at the strength the
            // evidence supports and no further. Record-scope developer fields
            // LATCH -- #36 measured, byte level on fr965 / SDK 9.2.0, that a
            // skipped setData re-emits the previous value on the next record
            // rather than leaving a gap. So:
            //
            //   * before the first write the records carry the type's never-set
            //     invalid pattern (#48 measured 0xFFFFFFFF). THIS is what a
            //     podless row, or a pod that withholds byte 1 for the whole
            //     session, produces: the field exists and is never populated.
            //     That is the fail-safe outcome #80 asks for, and it was
            //     MEASURED for this field rather than inferred (SIMULATOR,
            //     fr965 / SDK 9.2.0): a session that declared
            //     heat_strain_index and never called setData on it saved
            //     normally, kept its field_description, and its record carried
            //     the slot as ABSENT rather than as a number. The companion run
            //     that did write carried every value including a leading real
            //     0.0. Hardware is unmeasured, and what Garmin Connect RENDERS
            //     for the absent case is still untested (#53's territory).
            //   * after a value HAS been written, a dropout leaves the trace
            //     carrying the last pre-dropout value. For a strain index that
            //     reads as SUSTAINED STRAIN, which is a specific and misleading
            //     failure, and NO Monkey C call does better: setData(NaN) lands
            //     as 0xFFC00000, which a decoder reads as a datum (#48), and
            //     setData(null) is an uncatchable native error that kills the
            //     app. There is no per-record gap to be had.
            //
            // Do not restate this as "the field is gapped during a dropout".
            // The byte patterns above are measured; what a DECODER renders for
            // either of them is not, and no [Local] issue covers this field yet.
            if (mFitHsi != null) {
                var hs = mCoreSensor.heatIndex();
                if (hsiWritable(hs)) { mFitHsi.setData(hs); }
            }
        }
        if (mWorkoutEnabled && mStarted && !mPaused) {
            var st = mSteps[mStepIdx];
            var t = st[:type];
            if ((t == STEP_WORK || t == STEP_REST) && stepRemaining() <= 0.0) {
                advanceStep();
            }
        }
        Ui.requestUpdate();
    }

    // ================= sensor / detector ===================================
    hidden function startSensor() {
        var accOpt = { :enabled => true, :sampleRate => REQ_RATE };
        // ask for beat-to-beat (R-R) intervals along with the accelerometer;
        // fall back to accelerometer-only on devices/firmware without them
        try {
            Sensor.registerSensorDataListener(method(:onSensorData), {
                :period => 1,
                :accelerometer => accOpt,
                :heartBeatIntervals => { :enabled => true }
            });
            mSensorOk = true;
            mRrOk = true;
        } catch (e) {
            try {
                Sensor.registerSensorDataListener(method(:onSensorData), {
                    :period => 1,
                    :accelerometer => accOpt
                });
                mSensorOk = true;
                mRrOk = false;
            } catch (e2) {
                mSensorOk = false;
                mRrOk = false;
            }
        }
    }

    // GPS on for the whole app lifetime, so a fix is ready before START and
    // the recording session logs position / speed / distance.
    hidden function startGps() {
        try {
            Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
        } catch (e) {}
    }

    function onPosition(info as Position.Info) as Void {
        if (info != null && info.accuracy != null) {
            mGpsQual = info.accuracy;
        }
    }

    // Derive the DSP time base from REQ_RATE -- the rate the accelerometer is
    // CONFIGURED to deliver (see accOpt), which is the only trustworthy source:
    // CIQ exposes no achieved-sample-rate field, and a batch's size is a delivery
    // artifact of :period => 1, not a rate.
    //
    // Deliberately NO parameter (#8). This used to take a `rate` argument and was
    // called as computeCoeffs(n) with n = the first batch's SAMPLE COUNT, which
    // silently rescaled the entire synthetic clock for the whole session. With no
    // parameter, reintroducing that call is an arity error caught at compile time
    // by the 12-device compile-unit-test job. (The (:test) suite is ALSO executed
    // in CI these days -- the run-tests job, #42 -- but a compile-time guard needs
    // no simulator and fails on every device at once, so it stays the first line.)
    hidden function computeCoeffs() {
        mDt = 1.0 / REQ_RATE;
        mAlphaSlow = mDt / (mDt + 1.0 / (2.0 * Math.PI * FC_SLOW));
        mAlphaFast = mDt / (mDt + 1.0 / (2.0 * Math.PI * FC_FAST));
        mAlphaEnv  = mDt / (mDt + 1.0 / (2.0 * Math.PI * FC_ENV));
        mAlphaVar  = mDt / (mDt + 1.0 / (2.0 * Math.PI * FC_VAR));
        mDecim = (REQ_RATE / AC_HZ + 0.5).toNumber();
        if (mDecim < 1) { mDecim = 1; }
        mAcDt = mDt * mDecim;
    }

    function onSensorData(sensorData as Sensor.SensorData) as Void {
        if (mRrOk && (sensorData has :heartRateData) && sensorData.heartRateData != null) {
            handleRr(sensorData.heartRateData.heartBeatIntervals);
        }
        var accel = sensorData.accelerometerData;
        if (accel == null) { return; }
        var xs = accel.x;
        var ys = accel.y;
        var zs = accel.z;
        // #20: all three axis arrays are read below, so all three must be
        // guarded here. A null or SHORT y/z drops the whole batch rather than
        // processing the common prefix: mSampleIdx is the synthetic time base
        // (t = mSampleIdx * mDt) and nothing resyncs it, so partial credit
        // would leave the clock slow and every derived rate silently high.
        // Dropping is what the three guards around this one already do.
        // `<` and not `!=`: a LONGER y/z is still processed, tail ignored,
        // exactly as before -- so behaviour changes only on inputs that used
        // to throw.
        if (xs == null || ys == null || zs == null) { return; }
        var n = xs.size();
        if (ys.size() < n || zs.size() < n) { return; }
        if (n <= 0) { return; }
        // NOTE (#8): `n` is a batch SIZE and must never reach computeCoeffs().
        // The time base is fixed at init; nothing here may recompute it.

        // dynamic refractory: once the autocorrelation has locked the cycle
        // period, a new peak within REFRACT_FRAC of it is the recovery surge
        // of the SAME stroke, not a new stroke.
        var refract = 60.0 / $.MAX_RATE;
        if (mAcPeriod > 0.0) {
            var r2 = mAcPeriod * REFRACT_FRAC;
            if (r2 > refract) { refract = r2; }
        }

        for (var i = 0; i < n; i++) {
            var fx = xs[i].toFloat();
            var fy = ys[i].toFloat();
            var fz = zs[i].toFloat();

            // seed the gravity trackers so the first seconds don't produce a
            // huge phantom transient while the filters converge from zero
            if (mSampleIdx == 0) {
                mGravX = fx;
                mGravY = fy;
                mGravZ = fz;
            }

            // per-axis gravity removal + band-pass + activity variance
            mGravX += mAlphaSlow * (fx - mGravX);
            var hx = fx - mGravX;
            mLpX += mAlphaFast * (hx - mLpX);
            mVarX += mAlphaVar * (mLpX * mLpX - mVarX);

            mGravY += mAlphaSlow * (fy - mGravY);
            var hy = fy - mGravY;
            mLpY += mAlphaFast * (hy - mLpY);
            mVarY += mAlphaVar * (mLpY * mLpY - mVarY);

            mGravZ += mAlphaSlow * (fz - mGravZ);
            var hz = fz - mGravZ;
            mLpZ += mAlphaFast * (hz - mLpZ);
            mVarZ += mAlphaVar * (mLpZ * mLpZ - mVarZ);

            // SIGNED signal of the dominant axis: drive and recovery lobes
            // have opposite sign here, unlike in the rectified magnitude.
            var sig = (mAxis == 0) ? mLpX : ((mAxis == 1) ? mLpY : mLpZ);

            var a = (sig < 0.0) ? -sig : sig;
            mEnv += mAlphaEnv * (a - mEnv);
            var thr = mEnv * THR_K;
            if (thr < MIN_THR) { thr = MIN_THR; }
            var thrLo = thr * THR_LO_K;

            var t = mSampleIdx * mDt;
            if (mArmed && sig > thr && (t - mLastStrokeT) > refract && t > QUIET_S) {
                registerStroke(t);
                mArmed = false;
            } else if (sig < thrLo) {
                mArmed = true;
            }

            // decimate for the autocorrelation buffer
            mAcAccum += sig;
            mAcAccumN++;
            if (mAcAccumN >= mDecim) {
                mAcBuf[mAcIdx] = mAcAccum / mAcAccumN;
                mAcIdx = (mAcIdx + 1) % AC_BUF;
                if (mAcCount < AC_BUF) { mAcCount++; }
                mAcAccum = 0.0;
                mAcAccumN = 0;
            }
            mSampleIdx++;
        }

        // switch dominant axis only on a clear (1.5x) win, to avoid flapping
        var cur = (mAxis == 0) ? mVarX : ((mAxis == 1) ? mVarY : mVarZ);
        var b = mAxis;
        var bv = cur * 1.5;
        if (mVarX > bv) { b = 0; bv = mVarX; }
        if (mVarY > bv) { b = 1; bv = mVarY; }
        if (mVarZ > bv) { b = 2; bv = mVarZ; }
        if (b != mAxis) {
            mAxis = b;
            mArmed = true;
        }

        mAcBatch++;
        if (mAcBatch >= 2) {
            mAcBatch = 0;
            updateAutocorr();
        }

        var now = mSampleIdx * mDt;
        var timeout = 4.0;
        if (mLastPeriod > 0.0) {
            timeout = mLastPeriod * 2.2;
            if (timeout < 4.0)  { timeout = 4.0; }
            if (timeout > 12.0) { timeout = 12.0; }
        }
        if (mRate > 0.0 && (now - mLastStrokeT) > timeout) {
            mRate = 0.0;
            mPCount = 0;
            mPIdx = 0;
            // #149: the ESTABLISHED rate goes with the ring it was built from.
            // This is the "after a long gap" degrade: the next piece starts
            // against the absolute gate -- never looser than what shipped
            // before -- instead of against a baseline describing a piece that
            // has ended. Keeping it would carry a warm-up cadence into a work
            // interval, or a rest paddle into a sprint.
            mRateBase = 0.0;
        }
    }

    // Estimate the stroke cycle period from the autocorrelation of the
    // decimated band-passed signal. The signal is periodic at the TRUE cycle
    // length; at half a cycle the drive lobe lands on the (differently
    // shaped, opposite-going) recovery lobe, so the half-period correlation
    // stays well below the fundamental and cannot be picked.
    hidden function updateAutocorr() {
        var n = mAcCount;
        if (n < AC_MIN_N) { return; }

        // linearize the newest n samples, oldest first
        var buf = new [n];
        var start = (mAcIdx - n + AC_BUF) % AC_BUF;
        for (var i = 0; i < n; i++) {
            buf[i] = mAcBuf[(start + i) % AC_BUF];
        }

        var minLag = ((60.0 / $.MAX_RATE) / mAcDt + 0.5).toNumber();
        var maxLag = ((60.0 / $.MIN_RATE) / mAcDt + 0.5).toNumber();
        if (minLag < 2) { minLag = 2; }
        if (maxLag > n - 8) { maxLag = n - 8; }
        if (maxLag <= minLag) { return; }

        var w = AC_WIN;
        if (w > n - maxLag) { w = n - maxLag; }
        if (w < 20) { return; }

        var e = 0.0;
        for (var k = n - w; k < n; k++) { e += buf[k] * buf[k]; }
        // #149: a window with no energy admits no confidence at all, so the
        // sentinel goes in rather than the previous round's number. That is a
        // DIFFERENT state from "computed, and it was zero", and the two must
        // not be written the same way.
        if (e <= 0.0) { mAcPeriod = 0.0; mAcConf = $.LOCK_CONF_NONE; return; }

        var rr = new [maxLag + 1];
        var best = 0.0;
        var bestL = 0;
        for (var lag = minLag; lag <= maxLag; lag++) {
            var s = 0.0;
            for (var k = n - w; k < n; k++) { s += buf[k] * buf[k - lag]; }
            rr[lag] = s;
            if (s > best) { best = s; bestL = lag; }
        }

        // #149: record the confidence the gate below is about to be taken on.
        // e > 0.0 is established above and `best` starts at 0.0 and only grows,
        // so lockConf here is exactly `best / e` -- the substitution in the
        // condition below is an equality, not a re-tuning.
        mAcConf = lockConf(best, e);

        // three consecutive low-confidence evaluations to unlock, so a brief
        // lull mid-piece can't drop the period gate and let artifacts through
        if (bestL == 0 || mAcConf < AC_MIN_CONF) {
            mAcLowConf++;
            if (mAcLowConf >= 3) { mAcPeriod = 0.0; }
            return;
        }
        mAcLowConf = 0;

        // subharmonic correction: the global best can land on an integer
        // multiple of the true period (lag quantization favors whichever
        // multiple falls closest to a bin). Try bestL/6 .. bestL/2 and take
        // the largest divisor whose lag is still a strong peak. At the true
        // HALF-period the drive lobe correlates with the opposite-going
        // recovery lobe, so r stays near zero there and this can never
        // select the double-count rate.
        var chosen = bestL;
        for (var div = 6; div >= 2; div--) {
            var c = ((bestL * 1.0) / div + 0.5).toNumber();
            if (c < minLag) { continue; }
            var cBest = rr[c];
            var cLag = c;
            if (c + 1 <= maxLag && rr[c + 1] > cBest) { cBest = rr[c + 1]; cLag = c + 1; }
            if (c - 1 >= minLag && rr[c - 1] > cBest) { cBest = rr[c - 1]; cLag = c - 1; }
            if (cBest >= AC_SUB_K * best) {
                chosen = cLag;
                break;
            }
        }

        var p = chosen * mAcDt;
        var d = p - mAcPeriod;
        if (d < 0.0) { d = -d; }
        if (mAcPeriod > 0.0 && d < 0.35 * mAcPeriod) {
            mAcPeriod += 0.4 * (p - mAcPeriod);
        } else {
            mAcPeriod = p;
        }
    }

    // ================= R-R / HRV ===========================================
    // Beat-to-beat intervals are range-validated to [RR_MIN_MS, RR_MAX_MS]
    // before logging: undecodable (negative after toNumber) and non-physiological
    // values are dropped so they can never land in the UINT16 rr_interval field,
    // and unused slots are padded with RR_INVALID (0xFFFF, the FIT "no data"
    // sentinel) rather than a fake 0 ms. The extra artifact-rejection gate
    // (RR_ART_K) is applied ONLY to the rMSSD path -- mRmssd and the rmssd /
    // avg_rmssd fields derived from it -- never to the logged rr_interval
    // intervals. (Earlier text here read "only to the on-watch rMSSD, not to
    // the logged values"; mRmssd has no UI consumer, so both halves of that
    // were wrong -- the rMSSD path is itself a logged path.)
    // filterRr() is the single range gate shared by the record and rMSSD paths.
    //
    // NOTE (#14): the rr_interval field is NOT a complete raw R-R stream. It is a
    // fixed-count developer RECORD field, so per ~1 Hz record it carries only the
    // first up-to-RR_PER_REC in-range intervals of the LATEST batch before the
    // record commits. Beats are therefore lost silently in TWO WAYS, and the
    // number lost is UNBOUNDED (it grows with heart rate and callback frequency):
    // any beat past RR_PER_REC within a batch (see packRr), and every beat of an
    // earlier batch whose setData() is overwritten by a later handleRr in the
    // same record window. Do not treat this field as a beat count. A watch app
    // can't carry the full stream -- FitContributor exposes only developer
    // fields, and the native FIT hrv message (#78) is not writable from CIQ.

    // Pure: the encodable, in-range intervals from `ivals`, as Numbers, in
    // arrival order. No instance state, so it is (:test)-able without a Session.
    static function filterRr(ivals) {
        var out = [];
        if (ivals == null) { return out; }
        for (var i = 0; i < ivals.size(); i++) {
            var rr = ivals[i];
            if (rr == null) { continue; }
            rr = rr.toNumber();
            if (rr >= $.RR_MIN_MS && rr <= $.RR_MAX_MS) { out.add(rr); }
        }
        return out;
    }

    // Pure: pack the first RR_PER_REC valid intervals into a fixed-length record
    // array, padding the rest with RR_INVALID. Extras beyond RR_PER_REC are
    // dropped -- one of the two documented rr_interval loss modes (see #14 note
    // above); the field is a per-record sample, not the complete raw series.
    static function packRr(valid) {
        var cap = $.RR_PER_REC;
        var arr = new [cap];
        for (var j = 0; j < cap; j++) { arr[j] = $.RR_INVALID; }
        var k = valid.size();
        if (k > cap) { k = cap; }
        for (var j = 0; j < k; j++) { arr[j] = valid[j]; }
        return arr;
    }

    // Pure: is a timestamp `tsMs` fresh at `nowMs` within `threshMs`? Strict `<`
    // so it is behavior-preserving for the display indicator's old `< 5000` test.
    // A never-seen stamp (0) is not fresh.
    static function rrIsFresh(nowMs, tsMs, threshMs) {
        return tsMs > 0 && (nowMs - tsMs) < threshMs;
    }

    // Pure: has the gap since the last RANGE-accepted beat exceeded `threshMs`, so
    // the next beat cannot be its consecutive successor? Strict `>` (gap == thresh is
    // not a gap). A never-seen stamp (0) is not a gap -- the first beat just seeds.
    static function rrGapExceeded(nowMs, lastBeatMs, threshMs) {
        return lastBeatMs > 0 && (nowMs - lastBeatMs) > threshMs;
    }

    // Pure: should startSession() declare the three CORE developer fields?
    // Extracted from the inline condition it replaces so the decision is
    // reachable from a (:test) without an ActivityRecording.Session -- the
    // same reason filterRr/packRr/rrIsFresh/rrGapExceeded above are statics.
    //
    // Two deliberate declaration choices, neither cosmetic:
    //   * `static`, NOT `hidden`. `hidden` is protected in Monkey C, so a
    //     hidden static compiles and then fails to resolve from
    //     CoreFieldGateTest.mc. Every static above is public for the same
    //     reason.
    //   * the parameter is UNTYPED, so runtime duck typing applies and a stub
    //     exposing only everSeen() can stand in for CoreTempSensor.
    //
    // #75: this deliberately does NOT consult everSeen(). startSession() runs
    // once per row, so gating on "has a pod been heard yet" made the answer
    // permanent for the whole session -- see the block at the call site.
    //
    // The null term is DEFENSIVE, not a crash guard. onTick's core/skin writes
    // dereference mCoreSensor guarded only by the field handle, so keeping it
    // holds the invariant `mFitCore != null => mCoreSensor != null` local to
    // one adjacent line instead of resting on a whole-file lifecycle argument.
    // WHAT MAINTAINS IT, stated as a rule rather than as a census of call
    // sites. Every previous version of this paragraph was an enumeration, and
    // every one of them went stale or overreached (see the corrections below),
    // so it is deliberately phrased as something that cannot be invalidated by
    // adding code elsewhere:
    //
    //   Clearing mFitCore / mFitSkin ALONE is always safe -- it makes the
    //   antecedent false, so the implication holds trivially. Only an
    //   assignment that nulls mCoreSensor can break the invariant. The rule is
    //   therefore one line:
    //
    //       never null mCoreSensor without nulling mFitCore and mFitSkin in
    //       the same breath.
    //
    // Two places null mCoreSensor and both obey it: initialize(), which sets
    // all of them null together, and shutdown()'s finally, which clears the
    // three as a unit precisely so a throw partway through stopAndSave cannot
    // leave a field set with the sensor gone -- pinned by
    // test_life_shutdownKeepsCoreFieldInvariantOnThrow. Sites that clear only
    // the field handles (stopAndSave; startSession's createField catch) need no
    // audit under the rule above, which is the point of phrasing it that way.
    //
    // The stakes, unchanged: onTick dereferences mCoreSensor guarded only by
    // mFitCore, so a violation is a HARD FAULT, not a catchable throw. The null
    // term here is what keeps that coupling visible at one line.
    //
    // Corrections, kept rather than edited away, because the pattern -- one
    // comment, one claim outrunning its evidence, once per review round -- is
    // itself the thing worth recording:
    //   1. "assigned null only in initialize()"          -- #11 made it false.
    //   2. justified the window by single-threaded dispatch and a shared event
    //      loop                                          -- two platform
    //      properties nothing in this repository measures.
    //   3. "unreachable BY CONSTRUCTION"                 -- the try/finally
    //      added in the same round falsified it, and review measured the
    //      violation.
    //   4. "the only three sites that assign either to null" -- false; the
    //      createField catch in startSession is a fourth. Behaviourally
    //      harmless, but the sentence's whole job was to be exhaustive.
    // A fifth revision that merely recounted the sites would fail the same way,
    // which is why this one states an invariant-preserving rule instead. No
    // count of revisions appears in this paragraph, because that count is one
    // more thing that would need updating and did in fact go stale once.
    static function coreFieldsWanted(sensor) {
        return sensor != null;
    }

    // ---- #80: heat-strain plumbing, as pure decisions -----------------------
    // Same seam as coreFieldsWanted/rateColour/footState above: the decision is
    // reachable from a (:test) with no Dc, no Session and no ANT channel.

    // May this heat-strain reading be written to the FIT?
    //
    // Exists to be ONE line, and specifically to be the one line a future
    // "tidy-up" has to red before it can turn this into `v > 0.0`. That guard
    // is correct for max_core_temperature (0 C is impossible) and CATASTROPHIC
    // here: 0.0 a.u. means "no thermal strain", so suppressing it would delete
    // every genuine low-strain sample and leave the field carrying only the
    // hard parts of the row, with nothing in the file to say so.
    //
    // Null is the only absence the scale has, so null is the only rejection.
    static function hsiWritable(v) {
        return v != null;
    }

    // ---- #13: what a CORE dropout records ----------------------------------
    // Same seam as coreFieldsWanted / hsiWritable above: pure, class-scope
    // static, untyped parameters, reachable from a (:test) with no Session, no
    // ANT channel and no clock. source/CoreDropoutTest.mc holds the cases.
    //
    // THE INPUT. `tempC` is whatever coreTemp() / skinTemp() returned this
    // tick: a clamp-accepted reading while one is current, and EXACTLY 0.0
    // once it is not (CoreTempSensor coreTempAt / skinTempAt). So the sample
    // carries its own freshness and this gate needs no second call into the
    // sensor -- one System.getTimer() read per tick instead of two, and no
    // window in which freshness can flip between the two calls.
    //
    // That is a COUPLING to the getters' stale-return convention, stated
    // rather than hidden, and it is guarded: test_ct_staleReturnsZero pins
    // "stale coreTemp/skinTemp is 0.0", and CoreDrop's two c0 sweeps pin
    // "nothing decodeCoreC or decodeSkinC accepts is at or below 0.0 C" over
    // the raw domain. Change either end and a named test reds.
    //
    // `everWritten` is the caller's per-field flag (mCoreEver / mSkinEver):
    // has a real reading already been written to THIS record field in THIS
    // session?
    //
    // WHY THE TWO WINDOWS GET OPPOSITE ANSWERS. Record-scope FitContributor
    // fields LATCH -- #36 measured, byte level on fr965 / SDK 9.2.0, that a
    // skipped setData re-emits the previous value on the next record rather
    // than leaving a gap. There is no per-record gap available in Monkey C at
    // all: setData(NaN) lands as 0xFFC00000, which a decoder reads as a datum
    // (#48; how Garmin Connect renders it is open in #53), and setData(null)
    // is an uncatchable native error that kills the app (#48). So:
    //
    //   * BEFORE the first write, withholding is free -- there is no previous
    //     value to re-emit. The records carry the FLOAT never-set pattern
    //     instead of a fabricated 0.0 C. This is the half that fixes the
    //     4109-record podless row #102 was filed on, and the half #75's
    //     "such a row logs 0.0" note pointed here for.
    //   * AFTER a real reading has been written, withholding would republish
    //     that reading for the rest of the row -- a flat, entirely plausible
    //     37.4 C trace no consumer could tell from a pod that stayed on. So
    //     the write CONTINUES, and a dropout records 0.0 C, which cannot
    //     collide with a measurement because both accepted bands start above
    //     zero by construction (25-45 C core, 15-45 C skin). An out-of-band
    //     marker beats an in-band lie. #13's own suggested fix -- skip while
    //     stale -- is the in-band lie, and CoreDrop's c1 case
    //     test_ctw_c1_theDropoutMarkerSurvivesTheLatchTrap is what a future
    //     edit to `return tempC > 0.0` has to red before it can land.
    //
    // WHAT IS MEASURED AND WHAT IS NOT, at the strength the evidence supports.
    // The latch (#36) and the never-set FLOAT pattern (#48) were measured on
    // rmssd and rr_interval, and #80 re-measured the never-set case for
    // heat_strain_index. NEITHER WAS MEASURED ON core_temperature OR
    // skin_temperature: that they behave the same is expected and unverified.
    // #150 is the [Local] decode with byte-exact pass criteria that would
    // upgrade it, and it can falsify this design -- if a withheld write does
    // not produce the never-set pattern for these two fields, the silent
    // prefix buys nothing and this comment must be corrected here, at its
    // source. Nothing in this repository can decode a .fit, so no claim about
    // what a decoder or Garmin Connect SEES appears above; only what this code
    // calls.
    static function ctTempWritable(everWritten, tempC) {
        // Never hand null to setData: #48 measured it as an uncatchable native
        // error that escapes try/catch and kills the app.
        //
        // It also stops a throw one step EARLIER than the setData it is named
        // for, which was measured rather than assumed: with this line removed
        // and nothing else changed, test_ctw_c2_nullIsNeverHandedToSetData
        // reports ERROR, not FAIL -- `null > 0.0` on the next line throws.
        //
        // Unreachable from today's getters (coreTempAt/skinTempAt return a
        // clamped value or the literal 0.0) and guarded anyway: heatIndexAt
        // already returns null for its absent case, so a "make these
        // consistent" edit is a plausible next step.
        if (tempC == null) { return false; }
        // A current reading, always. Nothing either decoder accepts is at or
        // below 0.0 C (pinned by CoreDrop's two c0 sweeps), so this is exactly
        // "the sample is a measurement".
        if (tempC > 0.0)   { return true; }
        // A dropout. Writing the 0.0 marker is right only once a real value
        // has been written -- before that there is nothing for the latch to
        // re-emit and silence is strictly more honest.
        return everWritten;
    }

    // The `everWritten` flag's next value. Latches on the first real reading
    // and never clears within a session -- startSession resets it.
    //
    // Split out as a pure function rather than left inline so the lockstep
    // property is pinnable: the flag turns true only on a sample that
    // ctTempWritable also accepted, so "ever written" can never run ahead of
    // an actual write. test_ctw_c1_everNeverRunsAheadOfAWrite asserts that
    // over a tick sequence by calling BOTH functions, not by restating either.
    static function ctTempEverAfter(everWritten, tempC) {
        if (everWritten) { return true; }
        return tempC != null && tempC > 0.0;
    }

    // The session maximum's next value, given this tick's sample.
    //
    // BEHAVIOUR-IDENTICAL to the `if (ct > mMaxCore) { mMaxCore = ct; }` it
    // replaces -- same comparison, same direction. Extracted only so the
    // property can be pinned, because #13 asks whether stale reads pollute the
    // maximum and the answer needs to be a test rather than an argument:
    // mMaxCore starts at 0.0 (initialize and startSession), a dropout sample
    // IS 0.0, and 0.0 > 0.0 is false, so a dropout can neither raise nor lower
    // it. That is what keeps `mMaxCore > 0.0` in stopAndSave the sole and
    // still-necessary guard against writing a bogus 0 C max_core_temperature
    // on a podless row.
    //
    // Deliberately NOT gated on ctTempWritable: the maximum is an in-app
    // accumulator, not a FIT write, and coupling it to the write gate would
    // make a future change to the gate silently move a session aggregate.
    static function ctMaxCoreAfter(prevMax, tempC) {
        if (tempC == null)     { return prevMax; }
        if (tempC > prevMax)   { return tempC; }
        return prevMax;
    }

    // The rightmost x a mark may occupy at height `yTop`, for a display whose
    // visible area is the circle inscribed in `w` x `h`.
    //
    // MEASURED PREMISE, not an assumption: all twelve manifest devices report
    // SCREEN_SHAPE_ROUND with w == h under SDK 9.2.0. On any other shape the
    // inscribed circle is contained in the visible area, so this stays a valid
    // (merely conservative) bound rather than becoming wrong.
    //
    // Computed rather than tabulated as a fraction so it cannot drift from the
    // row's actual y: change PIP_ROW_Y_FRAC and the bound follows.
    static function pipChordXMax(w, h, yTop) {
        var r  = (w < h) ? w / 2.0 : h / 2.0;
        var dy = h / 2.0 - yTop;
        if (dy < 0)  { dy = -dy; }
        if (dy >= r) { return w / 2.0; }
        return w / 2.0 + Math.sqrt(r * r - dy * dy);
    }

    static function pipDotR(w) {
        var r = (w * $.PIP_DOT_R_FRAC).toNumber();
        return (r < $.PIP_DOT_R_MIN) ? $.PIP_DOT_R_MIN : r;
    }

    static function pipGap(w) {
        var g = (w * $.PIP_GAP_FRAC).toNumber();
        return (g < $.PIP_GAP_MIN) ? $.PIP_GAP_MIN : g;
    }

    // x of the heat-strain mark's centre: hard against the row's right-hand
    // chord limit, one pixel inside it. The mark takes the tight end because it
    // is the element whose width this code controls exactly; the label, whose
    // width is a measured bound rather than a value, is given the slack.
    static function pipDotCx(w, h) {
        return pipChordXMax(w, h, $.PIP_ROW_Y_FRAC * h) - 1 - pipDotR(w);
    }

    // x of the CT label's centre, once the mark has taken the row's right end.
    // Uses the WIDTH BOUND, so the true label always sits at or inside this.
    static function pipCtCx(w, h) {
        return pipDotCx(w, h) - pipDotR(w) - pipGap(w) - (w * $.PIP_CT_W_FRAC) / 2.0;
    }

    // y of the mark's centre: the middle of the label's text box.
    //
    // This is what makes pipDotCx's bound conservative rather than merely
    // approximate. The bound is taken at the box TOP, where the chord is
    // narrowest in this row; the mark's own topmost pixel is fontH/2 - r BELOW
    // that, and fontH/2 exceeds r on every manifest device (smallest fontH is
    // 19 px where r is 3), so the mark sits strictly inside the width the bound
    // allowed.
    static function pipDotCy(h, fontH) {
        return $.PIP_ROW_Y_FRAC * h + fontH / 2.0;
    }

    // Pure: the colour of the big stroke-rate numeral, extracted verbatim from
    // the inline expression in onUpdate so the decision is reachable from a
    // (:test) without a Dc and without a fully-built view -- the same seam
    // filterRr/packRr/rrIsFresh/rrGapExceeded/coreFieldsWanted above use.
    //
    // `isWork` is a BOOLEAN, not the step type, and that is forced rather than
    // stylistic: STEP_WORK is a class `hidden const`, i.e. an instance member,
    // so a static cannot resolve it. Compiling `return STEP_WORK;` inside a
    // static on this class fails with
    //   ERROR: StrongRowView.mc: Cannot find symbol ':STEP_WORK' on type 'self'
    // (measured against SDK 9.2.0 for fr965), which is the same fact the module
    // -scope R-R consts at the top of this file were introduced for.
    //
    // SCOPE, stated rather than implied: this pins the PREDICATE, not the call
    // site. The `type == STEP_WORK` comparison in onUpdate is covered by review
    // only -- a regression that swapped it for STEP_REST would leave every test
    // here green. Same caveat as coreFieldsWanted (see CoreFieldGateTest.mc).
    //
    // The `rate > 0.0` term is the no-data guard and is load-bearing: drawRate
    // renders "--.-" for rate <= 0.0, so a rate of 0.0 means "nothing measured
    // yet", NOT "rowing very slowly". Colouring it as below-band would be the
    // same defect class as the 0.0 skin temperature in #86.
    //
    // Parameters are UNTYPED on purpose, matching every static above: `rate`
    // arrives as a Float from outputRate() and `lo`/`hi` as Numbers from the
    // app settings, and Monkey C compares those directly.
    //
    // #107: THREE-way, not binary. The old selector returned COLOR_ORANGE for
    // both sides of the band, so it answered "am I wrong" without answering
    // "which way do I correct" -- rowing 14 and rowing 22 rendered identically.
    //
    // Constant choice, and the one that is easy to get backwards: Gfx.COLOR_BLUE
    // is 0x00AAFF and Gfx.COLOR_DK_BLUE is 0x0000FF. Garmin's naming is inverted
    // relative to the obvious reading, and the difference decides legibility on
    // the six 8 bpp transflective MIP devices in the manifest. Against the black
    // background onUpdate clears to, WCAG contrast is:
    //     COLOR_GREEN   00FF00  15.30:1
    //     COLOR_BLUE    00AAFF   8.19:1   <- chosen
    //     COLOR_ORANGE  FF5500   6.55:1   <- what this replaces
    //     COLOR_RED     FF0000   5.25:1   <- chosen
    //     COLOR_DK_BLUE 0000FF   2.44:1   <- rejected, below the 3:1 floor
    // So the blue used here is BRIGHTER than the orange it replaces. All three
    // are exact entries in the 64-colour palette those devices declare (the
    // 4x4x4 cube over {00,55,AA,FF}), so nothing is dithered or snapped.
    // What none of that settles is how they read on a wrist in sunlight; that
    // needs a device, not arithmetic.
    //
    // Boundary inclusivity is unchanged from the binary predicate: `rate == lo`
    // is neither `< lo` nor `> hi`, so it is green, and likewise `rate == hi`.
    static function rateColour(isWork, rate, lo, hi) {
        if (isWork && rate > 0.0) {
            if (rate < lo) { return Gfx.COLOR_BLUE; }   // below band: rate up
            if (rate > hi) { return Gfx.COLOR_RED; }    // above band: rate down
            return Gfx.COLOR_GREEN;                     // in band: hold
        }
        return Gfx.COLOR_WHITE;
    }

    // ============ the DISPLAY CUE ==========================================
    // A layer that sits BETWEEN outputRate() and the colour, and reaches
    // nothing else. It consumes the estimator's output and is read only by the
    // draw path.
    //
    // WHAT IT MUST NOT TOUCH, listed because the whole instruction turns on it:
    // outputRate(), recomputeRate(), registerStroke() and distPerStroke() are
    // unchanged, so the three FIT writes computed from them --
    // mFitRate.setData(outputRate()), mFitDps.setData(distPerStroke(...)) and
    // correctiveRate()'s use of outputRate() -- record exactly what they
    // recorded before. The displayed NUMBER is unchanged too: drawRate formats
    // outputRate(). Only the COLOUR passes through here.
    //
    // rateColour above is left in place and unmodified. It is still the
    // definition of "which colour does this rate deserve"; cueColour below
    // agrees with it exactly on the memoryless mapping, and a (:test) sweeps
    // the two against each other so the vocabulary cannot fork.

    // Pure: the zone a rate falls in, with no memory at all. The band
    // comparison and nothing else.
    //
    // Boundary inclusivity is rateColour's: `rate == lo` is neither `< lo` nor
    // `> hi`, so it is IN, and likewise `rate == hi`.
    //
    // `rate <= 0.0` is CUEZ_NONE and not "very slow". outputRate() genuinely
    // returns 0.0 when nothing has been measured and drawRate renders that as
    // "--.-", so a zone here would be a colour on a dash.
    static function cueBandZone(rate, lo, hi) {
        if (rate <= 0.0) { return $.CUEZ_NONE; }
        if (rate < lo)   { return $.CUEZ_BELOW; }
        if (rate > hi)   { return $.CUEZ_ABOVE; }
        return $.CUEZ_IN;
    }

    // Pure: the zone the raw rate is ASKING for, given the zone on screen.
    //
    // Separate from cueBandZone because the two answer different questions --
    // "where is this rate" against "does this rate justify changing the
    // instruction" -- and only the second one is allowed to depend on what is
    // already displayed.
    //
    // THE DEADBAND IS PAID ON EXIT ONLY, and the asymmetry is the design rather
    // than an oversight. Leaving the band means starting to shout at the
    // athlete, so it costs CUE_DEADBAND; coming back means saying "you're fine",
    // which the athlete can afford to hear early, so it costs nothing and the
    // rate has only to REACH the edge. A deadband applied on re-entry would make
    // the default 16-18 band effectively 17-17 to get back into, and an athlete
    // who corrected exactly onto the edge would be told to keep correcting.
    //
    // Implemented as a WIDENED BAND while the display says IN, which is exactly
    // "leaving requires rate > hi + DEADBAND or rate < lo - DEADBAND" and keeps
    // the no-data and boundary rules in one place instead of two.
    static function cueTarget(rate, lo, hi, cur) {
        if (cur == $.CUEZ_IN) {
            return cueBandZone(rate, lo - $.CUE_DEADBAND, hi + $.CUE_DEADBAND);
        }
        return cueBandZone(rate, lo, hi);
    }

    // Pure: one step of the cue's state machine.
    //
    //   rate   the raw estimator output (outputRate())
    //   lo/hi  the target band, in spm
    //   cur    the zone currently displayed
    //   cand   the zone that has been asking to replace it
    //   since  when it started asking, on the caller's clock (ms)
    //   now    the caller's clock, in ms
    //
    // Returns [zone, candidate, since]. The caller stores all three and passes
    // them back next frame; the function itself holds nothing.
    //
    // A STEP FUNCTION AND NOT A METHOD, so the whole decision is reachable from
    // a (:test) with plain numbers -- the seam rateColour, pauseFlags,
    // footState, hrZone and dpsZone all use. A (:test) never yields to the
    // simulator event loop, so a decision buried in onUpdate is reachable only
    // through a Dc and a fully-built view; this one is not.
    //
    // TIME IS A PARAMETER, not System.getTimer(). The caller passes nowMs(),
    // which a probe overrides. A stamp synthesised from getTimer() inside a
    // test would depend on how long the device has been up -- and CI's
    // simulator is seconds old while a desktop one is hours old, so such a case
    // passes where it is written and reds where it is judged.
    //
    // MEASURED IN MILLISECONDS, NEVER IN CALLS. onUpdate runs off a 250 ms tick,
    // so a window counted in callbacks would make CUE_PERSIST_OUT_MS = 4 mean
    // one second rather than four -- and it would silently retune itself if the
    // tick period ever changed, or if the platform coalesced updates.
    //
    // WHICH WINDOW APPLIES IS DECIDED BY THE CANDIDATE, not by the zone being
    // left, and that is the generalisation the measured result asks for: any
    // out-of-band candidate is the EXPENSIVE claim ("ease off" / "row harder")
    // and pays CUE_PERSIST_OUT_MS, whether it replaces IN or the other side of
    // the band; a candidate of IN is the cheap claim and pays
    // CUE_PERSIST_IN_MS.
    static function cueStep(rate, lo, hi, cur, cand, since, now) {
        var want = cueTarget(rate, lo, hi, cur);

        // Already showing what the rate asks for: nothing is pending, and the
        // candidate is reset so that persistence means CONTINUOUS. Without this
        // an intermittent spike would bank credit across the gaps between its
        // appearances, which is a total rather than a persistence test.
        if (want == cur) { return [cur, cur, now]; }

        // CUEZ_NONE IS ADOPTED WITHOUT DELAY, in both directions.
        //   into NONE:  drawRate switches the numeral to "--.-" on this very
        //               frame, and a colour outliving the number it described is
        //               a claim with nothing behind it.
        //   out of NONE: there is no displayed instruction to protect, so the
        //               first reading is the best answer available and delaying
        //               it buys nothing. This is also what makes a work interval
        //               start clean -- see the parking branch in onUpdate.
        if (want == $.CUEZ_NONE || cur == $.CUEZ_NONE) {
            return [want, want, now];
        }

        // A DIFFERENT candidate from last frame starts its own clock.
        if (want != cand) { return [cur, want, now]; }

        // A CLOCK THAT WENT BACKWARDS restarts the timer instead of adopting or
        // stalling. Compared directly rather than through the difference, so no
        // subtraction can overflow on the way to the test.
        //
        // SCOPE, stated because the neighbouring hazard is an open question here:
        // System.getTimer() is a 32-bit millisecond counter and WRAPS, but
        // whether a wrap presents as a backwards step or as correct two's
        // -complement arithmetic depends on Monkey C's overflow semantics, which
        // nothing in this repository measures -- #70 owns that for the
        // pre-existing rrIsFresh / hrHave pair and this does not add to it. The
        // guard is written so either answer is safe: worst case one window's
        // delay, once every 24.85 days.
        if (now < since) { return [cur, want, now]; }

        var need = (want == $.CUEZ_IN) ? $.CUE_PERSIST_IN_MS
                                       : $.CUE_PERSIST_OUT_MS;
        if ((now - since) >= need) { return [want, want, now]; }
        return [cur, cand, since];
    }

    // Pure: the colour for a cue zone.
    //
    // The SAME three constants rateColour uses, and the identity is pinned by a
    // (:test) that sweeps cueColour(isWork, cueBandZone(r, lo, hi)) against
    // rateColour(isWork, r, lo, hi). Two vocabularies that merely happen to
    // agree today would be one edit from disagreeing.
    //
    // `isWork` is a BOOLEAN for the reason rateColour states: STEP_WORK is a
    // class `hidden const`, i.e. an instance member, so a static cannot resolve
    // it.
    static function cueColour(isWork, zone) {
        if (!isWork) { return Gfx.COLOR_WHITE; }
        if (zone == $.CUEZ_BELOW) { return Gfx.COLOR_BLUE; }   // row harder
        if (zone == $.CUEZ_ABOVE) { return Gfx.COLOR_RED; }    // ease off
        if (zone == $.CUEZ_IN)    { return Gfx.COLOR_GREEN; }  // hold
        return Gfx.COLOR_WHITE;                                // CUEZ_NONE
    }

    // Pure: the [paused, recFailed] pair a toggle should leave behind, given
    // what the athlete pressed, what the recorder reports, and what the failure
    // flag already was (#74).
    //
    // Extracted because this mapping has regressed THREE times under review and
    // the call site is not reachable from a (:test) -- the same argument
    // footState makes, and the same seam rateColour and coreFieldsWanted use.
    //
    // THE RULE, in one line: mPaused drives the FIT write gate and the step
    // machine, so it must NEVER fail closed; mRecFailed drives the footer
    // claim, so it must.
    //
    // `live` COMES FROM A FAIL-CLOSED PROBE. sessionLive() returns false for a
    // dead session, a null handle AND a throw, so live == false PROVES NOTHING
    // and only live == true is evidence. That asymmetry is why the third
    // argument exists:
    //
    //   resume attempt   -> [false, !live]     gates open either way; the claim
    //                                          is honest about the doubt
    //   pause, refused   -> [false, false]     live == true is real evidence:
    //                                          keep writing, and clear the flag
    //   pause, taken     -> [true,  recFailed] PRESERVE it. An earlier revision
    //                                          cleared it here, reasoning that a
    //                                          deliberate pause is not a
    //                                          failure. But this arm is reached
    //                                          on live == false, which cannot
    //                                          tell "my stop took" from "it was
    //                                          already dead" -- so clearing was
    //                                          a no-op on every healthy path
    //                                          and erased the truth on the only
    //                                          unhealthy one. One press out of
    //                                          NOT RECORDING bought a
    //                                          reassuring PAUSED over a dead
    //                                          recorder.
    static function pauseFlags(wasPaused, live, recFailed) {
        if (wasPaused)  { return [false, !live]; }
        if (live)       { return [false, false]; }
        return [true, recFailed];
    }

    // ============ #109: the rest view's numbers, as pure decisions =========
    // Each takes RAW TOTALS and returns the derived figure, or NULL when there
    // is nothing to say. Null rather than 0.0 on purpose: this repository has
    // already shipped a zero that read as data (#86/#107), and a rest cell
    // showing 0.0 m/str is a claim about the interval, not an absence.
    //
    // Callers must render the null as its own thing -- a dash, never a number.

    // Strokes per minute over the interval. Not an average of the live rate
    // estimator: that lags, and averaging a lagging estimator compounds it.
    static function setAvgSpm(strokes, sec) {
        if (sec == null || sec <= 0.0) { return null; }
        if (strokes == null || strokes <= 0) { return null; }
        return strokes * 60.0 / sec;
    }

    // Metres per stroke over the interval: interval distance / interval
    // strokes. NOT the live distPerStroke(), which is an instantaneous ratio
    // of two smoothed estimators and a different quantity entirely (#123).
    static function setAvgDps(dist, strokes) {
        if (strokes == null || strokes <= 0) { return null; }
        if (dist == null || dist <= 0.0) { return null; }
        return dist / strokes;
    }

    // Mean heart rate over the interval, from the sum and the sample count.
    static function setAvgBpm(hrSum, hrN) {
        if (hrN == null || hrN <= 0) { return null; }
        return hrSum * 1.0 / hrN;
    }

    // Interval distance in whole metres, or null. Separate from the raw member
    // so the "nothing to say" rule is applied in one place for every cell.
    static function setDistM(dist) {
        if (dist == null || dist <= 0.0) { return null; }
        return dist;
    }

    // ============ ERG MODE: the new decisions, as pure statics =============
    // Every one of them is a class-scope static for the reason the setAvg*
    // family and rateColour are: the call sites need a built view, a Dc or a
    // Session, and no (:test) can supply any of the three. A (:test) is
    // synchronous and never yields to the event loop, so a pure seam is the
    // only genuinely testable form.

    // Pure: coerce a property to a real Boolean.
    //
    // NOT paranoia about types. loadSettings feeds these into `&&`, and a
    // Connect IQ property is whatever the last writer left there -- an app
    // update, a sideloaded .set file, or a settings schema that changed shape
    // between versions. #21's finding is that a range declared in settings.xml
    // is enforced nowhere else; the same is true of a declared TYPE.
    //
    // Anything that is not a Boolean becomes the default, rather than being
    // coerced by truthiness: 1 and "true" are not statements about a toggle the
    // athlete set, they are evidence the property is not what this code thinks
    // it is, and the shipped default is the honest answer to that.
    //
    // AN `instanceof` TEST AND NOT A VALUE COMPARISON, and that is measured
    // rather than stylistic. The first form of this function was
    // `if (v == true) ... if (v == false) ... return dflt`, which reads as an
    // exact-match test and is not one: MEASURED on SDK 9.2.0 in the CI
    // container's fr965 simulator, `0 == false` evaluates TRUE in Monkey C, so
    // that form silently accepted a Number 0 as a set toggle and never reached
    // its own default. The case that caught it is
    // Erg.test_erg_c1_aCorruptedToggleFallsBackToItsDefault, which red with
    // "junk 0 must fall back to the TRUE default" before this line changed.
    static function ergFlag(v, dflt) {
        if (v instanceof Lang.Boolean) { return v; }
        return dflt;
    }

    // Pure: are WORK/POWER units selected?
    //
    // THE MAINTAINER'S TWO-SETTING SHAPE, in one place. ergPowerUnits defaults
    // ON and "only means anything when ergMode is on" -- so this is an AND, and
    // it is a named function rather than an `&&` repeated at the arc, the pace
    // row and the grid, because three copies of a rule are three things that
    // can disagree after one edit.
    static function useWorkUnits(ergMode, powerUnits) {
        return ergFlag(ergMode, false) && ergFlag(powerUnits, false);
    }

    // Pure: joules of work in one stroke, or NULL.
    //
    // watts * 60 / rate: power is joules per second, 60/rate is seconds per
    // stroke.
    //
    // NULL, NEVER 0.0, FOR EVERY ABSENT INPUT, and this is the single most
    // load-bearing line of the feature. The right-edge arc maps its input
    // through dpsPct, and dpsPct's low end renders RED -- "far below
    // benchmark". An athlete whose watch reports no power at all would be told,
    // in the one glance the app is designed around, to row harder. That is the
    // #86 / #107 class with an instruction attached.
    //
    // A REAL ZERO IS NOT ABSENCE and is deliberately allowed through as 0.0:
    // zero watts is a legal reading on an erg (the recovery, or sitting at the
    // catch), and this function's job is to be faithful, not to editorialise.
    // What the ARC does with a faithful 0.0 is dpsPct's existing decision --
    // `<= 0.0` becomes null, so it renders as no-data grey rather than as red.
    // That is a listed consequence, not an accident: it fails toward absence,
    // which is the safe direction, and at zero watts with a real stroke rate
    // there is no correction to instruct anyway.
    //
    // A NEGATIVE READING IS ABSENCE, not a small one. Power is non-negative by
    // construction, so a negative value is evidence the source is not what this
    // code thinks it is -- the same judgement ergFlag makes about a type.
    static function joulesPerStroke(watts, rate) {
        if (watts == null || watts < 0.0) { return null; }
        if (rate == null || rate <= 0.0)  { return null; }
        return watts * 60.0 / rate;
    }

    // Pure: one step of the work integrator, in joules.
    //
    // A MISSING SAMPLE CONTRIBUTES NOTHING AND IS NOT A ZERO SAMPLE. Adding
    // 0.0 would be arithmetically identical here and semantically fatal one
    // function over: it is workCountAfter, not the accumulated value, that
    // decides whether the interval has anything to say, and an accumulator that
    // "absorbed" null samples would still read 0.0 J with a count of zero.
    // Keeping the two facts in two places is what stops a later reader deriving
    // presence from the number.
    //
    // tickMs IS A PARAMETER rather than $.TICK_MS read inside, so a case can
    // drive the arithmetic at a period of its choosing and so the call site
    // has to name the period it believes it is running at.
    static function workAccumStep(prevJ, watts, tickMs) {
        if (prevJ == null) { return 0.0; }
        if (watts == null || watts < 0.0) { return prevJ; }
        if (tickMs == null || tickMs <= 0) { return prevJ; }
        return prevJ + watts * tickMs / 1000.0;
    }

    // Pure: HOW MANY real samples this accumulator has taken.
    //
    // A COUNT AND NOT A BOOLEAN, and the two are not interchangeable even
    // though `n > 0` is exactly the boolean this replaced. The boolean answers
    // "did this interval carry any measurement at all"; only the count answers
    // "how much of it did", which is what workCoverOk needs and what a partial
    // dropout silently destroys. mSetHrN is the same member for the same
    // reason, one accumulator up.
    //
    // MONOTONIC: it never decreases, which is the property the boolean's
    // "latches true" was expressing. A tick with no sample returns the count
    // unchanged rather than resetting it, because the question is cumulative.
    //
    // A REAL ZERO COUNTS. `watts >= 0.0` and not `> 0.0`: 0 W between strokes
    // is a sample the source produced, and treating it as a dropout would make
    // an athlete on the recovery look like an athlete with no power meter.
    static function workCountAfter(n, watts) {
        var c = (n == null) ? 0 : n;
        if (watts != null && watts >= 0.0) { return c + 1; }
        return c;
    }

    // Pure: did enough of the interval actually carry a power sample for its
    // work total to be worth showing?
    //
    // WHY THIS IS NOT PARANOIA. `n * tickMs / 1000` is the number of SECONDS
    // covered by real samples; `sec` is the interval's own pause-corrected
    // duration. Their ratio is the fraction of the interval the power source
    // was up, and the work total is under-reported by exactly one minus that
    // ratio -- an integral of instantaneous samples cannot notice its own gaps
    // the way a mean over a counted sum or an odometer delta can. The whole
    // argument, and the derivation of the 0.85, is at WORK_COVER_MIN.
    //
    // FALSE WHEN THE DURATION IS UNKNOWN OR ZERO: coverage is a ratio, and a
    // zero denominator is not a full interval, it is an unanswerable question.
    //
    // tickMs IS A PARAMETER for workAccumStep's reason -- the call site names
    // the period it believes it is running at, rather than this reading a
    // constant the timer may not honour.
    static function workCoverOk(n, sec, tickMs) {
        if (n == null || sec == null || tickMs == null) { return false; }
        if (sec <= 0.0 || tickMs <= 0) { return false; }
        if (n <= 0) { return false; }
        return (n * tickMs / 1000.0) >= ($.WORK_COVER_MIN * sec);
    }

    // Pure: the interval's work in KILOJOULES, or null.
    //
    // `measured` IS THE SOLE PRESENCE TEST, and `joules > 0.0` is deliberately
    // NOT one. setDistM refuses a zero distance because a zero-distance
    // interval on the water is not a thing that happens; a zero-WORK interval
    // is, and refusing it would render an honest 0.0 kJ identically to a
    // missing power meter. This is setAvgBpm's shape (the count decides
    // presence, the value may be anything) rather than setDistM's.
    //
    // WHAT `measured` MEANS IS THE CALLER'S DECISION, and the two live callers
    // answer it differently on purpose: the grid passes workCoverOk (enough of
    // the interval carried a sample), stopAndSave passes `n > 0` (any sample at
    // all). Both reasons are written at their call sites; this function only
    // refuses to invent a number when told there is none.
    static function setWorkKJ(joules, measured) {
        if (measured != true) { return null; }
        if (joules == null || joules < 0.0) { return null; }
        return joules / 1000.0;
    }

    // Pure: mean joules per stroke over a completed interval -- interval work
    // over interval strokes.
    //
    // The erg analogue of setAvgDps, and NOT an average of the live
    // joulesPerStroke: that is an instantaneous ratio of two smoothed
    // estimators and a different quantity entirely, which is the distinction
    // setAvgDps's own note makes.
    // `measured` carries setWorkKJ's meaning verbatim -- see the note there.
    static function setAvgJps(joules, strokes, measured) {
        if (measured != true) { return null; }
        if (strokes == null || strokes <= 0) { return null; }
        if (joules == null || joules < 0.0)  { return null; }
        return joules / strokes;
    }

    // Pure: the erg pace row's string.
    //
    // "150W  500J/str", and "--W  --J/str" when there is nothing to say. NOT a
    // dropped term: the distance form omits its m/str term when absent, which
    // is safe there because the /500 m split still labels the row -- here BOTH
    // figures come from the same source, so dropping them would leave a row
    // that says nothing about why. An explicit dash says the source is missing.
    //
    // CLAMPED TO FOUR DIGITS EACH, so the widest string this can return is
    // "9999W  9999J/str" -- 16 characters, against the 20 of the form it
    // replaces. See the PACE_W_MAX note for why a clamp is preferred to an
    // unbounded string and what it costs.
    static function paceWorkStr(watts, jps) {
        return ergNum(watts, $.PACE_W_MAX) + "W  " +
               ergNum(jps, $.PACE_J_MAX) + "J/str";
    }

    // Pure: the REST grid's accumulated-work cell, in kilojoules, or "--".
    //
    // WHY THIS IS NOT JUST `kj.format("%.1f")`. The grid's format table claimed
    // the kJ cell was never wider than the "18000" (five characters) it
    // replaces, on an assumed maximum of "999.9". Nothing enforced that and no
    // case pinned it: settings.xml allows a 60-minute work interval, and 60
    // minutes at 278 W is 1 000 800 J -- "1000.8", six characters. The claimed
    // bound was an assumption about athlete power printed in the same table as
    // the format strings.
    //
    // THE SWITCH POINT IS 999.95 AND NOT 1000.0, and that is a measurement
    // rather than a nicety: "%.1f" ROUNDS, so 999.96 formats as "1000.0" --
    // six characters, the exact overrun this function exists to prevent. Found
    // by the sweep in test_erg_c1_theKilojouleCellIsBoundedToFiveCharacters,
    // which is why that case sweeps instead of checking three examples.
    //
    // THE FORMAT CHANGES AT ~1000 kJ RATHER THAN THE VALUE BEING CLAMPED THERE,
    // because 1000 kJ is a real interval and clamping it would be a lie about a
    // legitimate reading -- unlike PACE_W_MAX, whose 9999 W is a broken
    // machine. A tenth of a kilojoule is the useful resolution below 1000 kJ
    // and is meaningless above it, so dropping it there costs nothing and buys
    // the character bound outright: "999.9" is five, "1000" is four, "9999" is
    // four. FIVE CHARACTERS IS THEREFORE THE MAXIMUM, which is exactly the
    // width of the "18000" this cell replaces.
    //
    // GRID_KJ_MAX is still a clamp, and it is PACE_W_MAX's argument verbatim:
    // 9999 kJ in one interval is 2775 W sustained for the full hour
    // settings.xml allows, so the top end is a broken machine and the FIT file
    // carries the true total through erg_work_total.
    //
    // CHARACTERS ARE NOT PIXELS. No (:test) that runs in CI can obtain a font
    // metric (#121), so five characters is a character bound and not a
    // clearance; the pixel measurement is #169's.
    static function gridKjStr(kj) {
        if (kj == null || kj < 0.0) { return "--"; }
        if (kj < 999.95) { return kj.format("%.1f"); }
        var n = (kj + 0.5).toNumber();
        if (n > $.GRID_KJ_MAX) { n = $.GRID_KJ_MAX; }
        return n.format("%d");
    }

    // Pure: the joules-per-stroke benchmark, clamped to its declared band.
    //
    // SPLIT OUT OF loadSettings FOR hrClampBand's REASON, which is the whole
    // point: the clamp itself has to be reachable from a (:test), and
    // loadSettings is not -- it needs App.Properties and a built view. While
    // this lived inline in loadSettings, the case named
    // theJouleBenchmarkIsClampedInCode was in fact exercising a private COPY of
    // the comparison inside the test probe, and deleting both real clamp lines
    // left all 308 cases green (measured, in the CI container, on fr965). That
    // is this repository's own named failure "a test that re-implements logic
    // instead of calling it pins nothing", landing on exactly the #21 defect
    // class the clamp exists to close.
    static function jouleClampBench(v) {
        if (v == null) { return $.JOULE_BENCH_DEF; }
        var b = v * 1.0;
        if (b < $.JOULE_BENCH_MIN) { b = $.JOULE_BENCH_MIN; }
        if (b > $.JOULE_BENCH_MAX) { b = $.JOULE_BENCH_MAX; }
        return b;
    }

    // Pure: a whole-number figure for a glance surface, or "--".
    //
    // Rounds rather than truncates (%d on 149.9 renders 149) and clamps at
    // `cap`. Shared by both halves of paceWorkStr so the two cannot diverge on
    // what absence looks like.
    static function ergNum(v, cap) {
        if (v == null || v < 0.0) { return "--"; }
        var n = (v + 0.5).toNumber();
        if (n > cap) { n = cap; }
        return n.format("%d");
    }

    // Pure: which FIT sub-sport this row should declare.
    //
    // SUB_SPORT_INDOOR_ROWING exists at API level 3.2.0, which is the manifest's
    // own minApiLevel, and is confirmed present in SDK 9.2.0's symbol table.
    //
    // SCOPE, stated because it is exactly the overreach this repository keeps
    // making: this function decides the VALUE. That startSession passes the
    // value to Rec.createSession, and that a decoder then renders the row as
    // indoor rowing, are two further claims -- the first is covered by review
    // (no (:test) can obtain a Session) and the second by a [Local] decode.
    static function subSportFor(ergMode) {
        if (ergFlag(ergMode, false)) { return Activity.SUB_SPORT_INDOOR_ROWING; }
        return Activity.SUB_SPORT_GENERIC;
    }

    // ---- the erg FIT encodings, one static per field ----------------------
    // Same shape as #149's lockRateOf / lockConf / lockLowClamp, and for the
    // same reason: what a field CARRIES becomes a reviewable decision with a
    // name, and the no-data encodings can be pinned without a Session -- which
    // no (:test) in this repository can obtain.

    // Pure: the watts to record, or ERG_POWER_NONE when there was no reading.
    // Zero watts is a LEGAL reading on an erg, so the sentinel has to be
    // negative; see the ERG_POWER_NONE block at the top of this file.
    static function ergPowerOf(watts) {
        if (watts == null || watts < 0.0) { return $.ERG_POWER_NONE; }
        return watts * 1.0;
    }

    // Pure: the joules per stroke to record, or ERG_JPS_NONE. Takes the value
    // joulesPerStroke already computed, so the field and the screen cannot
    // disagree about what the number was.
    static function ergJpsOf(jps) {
        if (jps == null || jps < 0.0) { return $.ERG_JPS_NONE; }
        return jps * 1.0;
    }

    // Pure: the native cadence to record, or ERG_CAD_NONE.
    //
    // THIS IS THE FIELD THAT ANSWERS THE SOURCE QUESTION, and the erg_diag
    // cadence BITS are not. See the correction in the ERGD_CAD_OK block: the
    // wrist populates ai.currentCadence with no machine present -- measured, on
    // the water, in the README's Potomac row -- so a set bit is the expected
    // reading either way and only the VALUE can be differenced against
    // row_stroke_rate. correctiveRate() cannot serve, because it clamps that
    // difference at zero and so discards the one sign that would be evidence.
    //
    // SENTINEL, NOT SILENCE, for the record-scope latch reason all three of
    // these encoders share; negative because cadence is non-negative by
    // construction and 0 spm is a real reading.
    static function ergCadOf(cad) {
        if (cad == null || cad < 0) { return $.ERG_CAD_NONE; }
        return cad * 1.0;
    }

    // Pure: one bit if a nullable reading was present, another if it was
    // positive. Two bits rather than one because "the field exists but reads
    // zero" and "the field is not populated" are exactly the two states this
    // instrumentation was built to tell apart.
    static function ergDiagFlag(v, okBit, posBit) {
        if (v == null) { return 0; }
        return okBit | ((v > 0) ? posBit : 0);
    }

    // Pure: the instrumentation word for one tick.
    //
    // `s` is [power, speed, distance, cadence] with NULLS PRESERVED -- which is
    // why ergSample() exists at all rather than this reading currentSpeed() and
    // friends, all of which collapse null to 0.0 and would make the field
    // unable to answer its own question.
    //
    // ALIVE is set unconditionally: see the ERGD_ALIVE note for why a written
    // value must never be 0x0000 and must never be 0xFFFF.
    static function ergDiagBits(s, ergMode, workUnits) {
        var b = $.ERGD_ALIVE;
        if (s != null && s.size() >= 4) {
            b |= ergDiagFlag(s[0], $.ERGD_PWR_OK, $.ERGD_PWR_POS);
            b |= ergDiagFlag(s[1], $.ERGD_SPD_OK, $.ERGD_SPD_POS);
            b |= ergDiagFlag(s[2], $.ERGD_DST_OK, $.ERGD_DST_POS);
            b |= ergDiagFlag(s[3], $.ERGD_CAD_OK, $.ERGD_CAD_POS);
        }
        if (ergFlag(ergMode, false))   { b |= $.ERGD_ERGMODE; }
        if (ergFlag(workUnits, false)) { b |= $.ERGD_WORKUNI; }
        return b;
    }

    // Pure: which of the five footer states is showing (#74).
    //
    // WHERE THE GUARANTEE ACTUALLY LIVES, stated precisely because the obvious
    // reading of this function is wrong: footState does NOT consult mSession,
    // and adding a session parameter would not help. What fixed #74 is that
    // startSession() REPORTS whether a started session exists, both callers set
    // mStarted from that report, and togglePause sets mRecFailed from
    // isRecording() rather than from the keypress.
    //
    // THE EXACT INVARIANT, no stronger. mStarted means "a session was recording
    // when startSession last returned". It is NOT a live reading, and nothing
    // here re-checks the session. What makes the footer honest is that the two
    // places which can invalidate it -- a failed start and a failed resume --
    // both raise mRecFailed, and mRecFailed outranks everything below it. A
    // session that dies for some third reason would still render as REC; no
    // such path is known, and if one is found it belongs in mRecFailed too
    // rather than in a new parameter here.
    //
    // WHY IT EXISTS. The footer used to be gated on mStarted alone, and
    // mStarted was set unconditionally. A startSession() that threw left
    // mSession null while both callers set mStarted = true
    // regardless, so the watch rendered an ordinary red "REC 12:34 2.10km
    // 240str" row -- live timer, live distance, live stroke count -- for a row
    // that would produce no FIT file at all. The athlete finished the piece
    // believing it recorded. That is the whole of #74, and it is worse than a
    // crash: a crash is visible.
    //
    // Extracted as a pure static because startSession() itself is NOT reachable
    // from a (:test) (CoreFieldGateTest.mc:10-12) while this decision is -- the
    // same seam rateColour and coreFieldsWanted use.
    //
    // ORDER IS LOAD-BEARING. recFailed is tested before paused because in the
    // failure state mPaused is whatever the previous session left behind, and a
    // stale "PAUSED" would hide the failure behind a plausible-looking state.
    // sensorOk stays first: with no accelerometer nothing downstream is true.
    //
    // Colour and layout only -- never a tone, vibration or flash (#114).
    static function footState(sensorOk, paused, started, recFailed) {
        if (!sensorOk)  { return $.FOOT_NO_ACCEL; }
        if (recFailed)  { return $.FOOT_NO_REC; }
        if (paused)     { return $.FOOT_PAUSED; }
        if (started)    { return $.FOOT_REC; }
        return $.FOOT_IDLE;
    }

    // ============ #108: the work view's own decisions ========================
    // The layout split itself needs no new state -- onUpdate already branches
    // on the step type -- so what is extracted here is the two things the split
    // ADDS: the work-remaining arithmetic and the rule that decides which
    // footer states survive the strip. Both are class-scope statics for the
    // same reason footState, rateColour and the setAvg* family are: the call
    // site needs a Dc and a fully-built view, and no (:test) can supply either.

    // Pure: seconds of WORK and REST still to come, including whatever is left
    // of the current step.
    //
    // A LOWER BOUND. buildWorkout attaches :dur to exactly two step types --
    // STEP_WORK (mWorkSec) and STEP_REST (mRestSec). STEP_WARM, STEP_GATE,
    // STEP_COOL and STEP_DONE end on a USER PRESS: onPrimary advances them, and
    // onTick's auto-advance fires only for WORK and REST. A gate can therefore
    // sit unfinished for an unbounded time, so TOTAL SESSION TIME IS NOT
    // COMPUTABLE and this figure must never be presented as one. That is what
    // workLeftCaption below exists to enforce.
    //
    // Three further undercounts, all deliberate and all covered by the caption:
    //   1. PAUSE. togglePause shifts mStepStartMs forward by the paused span,
    //      so stepRemaining() is pause-corrected -- but the pause still adds
    //      wall-clock time to the finish that this cannot know about.
    //   2. GATES, as above.
    //   3. OVERRUN. stepRemaining() clamps at 0.0, and the auto-advance runs
    //      only while mStarted && !mPaused.
    //
    // `curRemain` is a PARAMETER rather than a call to stepRemaining(), and
    // that is forced rather than stylistic: stepRemaining() reads
    // System.getTimer(), which would make every case here time-dependent --
    // the failure mode HrProbe.nowMs was introduced for.
    //
    // Steps with no :dur key contribute zero. During WARM, GATE and COOL the
    // current-step term is itself zero (stepRemaining() returns 0.0 for a step
    // with no :dur), so the figure there is the future sum with no current-step
    // term. That is the intended reading, not a bug: those steps have no clock
    // to count down, so there is nothing of them to include.
    //
    // ABOVE 60 MINUTES, decided rather than discovered. mmss formats an
    // unbounded minute count with no hour rollover, and loadSettings enforces
    // only the LOWER bounds settings.xml declares (that is #21). At the
    // declared maxima -- 30 intervals of 60 minutes with 29 rests of 60 --
    // this returns 212400 s and the caption reads "3540:00 work left". That is
    // 17 characters at FONT_XTINY, which MEASURES at 238 px on the four 454 px
    // devices against a 375 px chord at this row, so it fits; the row it
    // occupies is the one the pace numerals vacate, and the widest string that
    // row carries today is wider still. No rollover is introduced.
    static function workLeftSec(steps, idx, curRemain) {
        var t = curRemain;
        if (steps == null) { return t; }
        for (var i = idx + 1; i < steps.size(); i++) {
            var s = steps[i];
            if (s != null && s.hasKey(:dur)) { t += s[:dur]; }
        }
        return t;
    }

    // Pure: the caption that goes with that figure.
    //
    // "work left", and NOT "session", "total" or "remaining" standing alone --
    // #108's acceptance criterion, and an honesty requirement rather than a
    // style one. Gates carry no :dur, so the number is a lower bound; any of
    // those three words would make it read as a true session total, which is
    // the one thing it provably is not.
    //
    // Its own function so the wording is pinnable. A bare figure with no
    // caption fails the criterion, and so does a caption edited later.
    static function workLeftCaption(mmssStr) {
        return mmssStr + " work left";
    }

    // Pure: the step_type code for a record or a lap.
    //
    // `type` is the class-scope STEP_* ordinal of the step in force, or
    // anything else (curStepType returns -1) when there is none. The wire
    // mapping and the reason the codes are not the ordinals are on the SFIT_*
    // block; this function is the ONLY bridge between the two numbering
    // schemes.
    //
    // NO WORKOUT IS A VALUE, NOT A SILENCE. Free-row mode and the pre-START
    // window both return SFIT_NONE, and the caller writes it on every tick,
    // because record-scope fields LATCH: withholding the write would re-emit
    // the previous row's step rather than leaving a gap.
    //
    // AN UNKNOWN ORDINAL FALLS TO SFIT_NONE rather than to a guess. If a step
    // kind is ever added and this table is not extended, the file says "not a
    // workout step" -- which is wrong but honest and cannot be mistaken for a
    // work interval. The alternative (passing the ordinal through) would make a
    // new kind indistinguishable from an existing code.
    static function stepTypeCode(type, workoutEnabled, started) {
        if (!workoutEnabled || !started) { return $.SFIT_NONE; }
        if (type == $.SFIT_ORD_WARM) { return $.SFIT_WARM; }
        if (type == $.SFIT_ORD_WORK) { return $.SFIT_WORK; }
        if (type == $.SFIT_ORD_REST) { return $.SFIT_REST; }
        if (type == $.SFIT_ORD_GATE) { return $.SFIT_GATE; }
        if (type == $.SFIT_ORD_COOL) { return $.SFIT_COOL; }
        if (type == $.SFIT_ORD_DONE) { return $.SFIT_DONE; }
        return $.SFIT_NONE;
    }

    // Pure: the interval_num for a record or a lap.
    //
    // `setNum` is mSetNum -- the SAME quantity that gates the heart-rate fold,
    // the erg work integrator and the footer's stroke count. That identity is
    // the point rather than a convenience: the file's notion of "inside a work
    // interval" is then the app's own notion by construction, so a consumer
    // selecting on this field selects exactly the seconds the app itself
    // counted as work.
    //
    // 0 IS "NOT IN AN INTERVAL" AND IS UNAMBIGUOUS: buildWorkout numbers
    // intervals from 1, so no real interval can collide with it.
    //
    // SATURATES AT IVL_MAX, one below the UINT16 no-data pattern 0xFFFF. A
    // sideloaded numIntervals is not re-clamped on load (#21), so this is not
    // an unreachable branch by anything this file can prove -- and saturating
    // ONTO 0xFFFF would turn a real interval into an apparent absence, which is
    // the same trap LOCK_LOW_MAX avoids on the run counter.
    static function intervalNumOf(workoutEnabled, started, setNum) {
        if (!workoutEnabled || !started) { return $.IVL_NONE; }
        if (setNum <= 0)                 { return $.IVL_NONE; }
        if (setNum > $.IVL_MAX)          { return $.IVL_MAX; }
        return setNum;
    }

    // Pure: does this stroke belong to the figure the footer reports?
    //
    // #125's whole boundary, in one place and reachable from a (:test) -- the
    // call site is inside registerStroke, which needs a built view and a live
    // accelerometer stream, so the decision is extracted for the same reason
    // footState, rateColour and the setAvg* family are.
    //
    // TWO ARMS, and the free-row one is not an afterthought:
    //
    //   WORKOUT MODE   the stroke counts only inside a WORK interval. `setNum`
    //                  is mSetNum, which beginWorkAccum raises to the 1-based
    //                  interval number and latchWorkAccum returns to 0 -- so
    //                  positioning before the first interval, rest paddling,
    //                  the warm-up, the gates and the cool-down are all
    //                  excluded, and excluded by the SAME boundary that bounds
    //                  every other per-interval aggregate in this file.
    //   FREE ROW       every stroke counts. There are no steps at all, so there
    //                  is no "before the interval" to exclude: the whole row IS
    //                  the piece. A rule that returned false here would leave
    //                  the footer reading 0 for the entire row, which is the
    //                  failure mode a naive `mSetNum > 0` gate produces --
    //                  free-row mode never opens an interval, so mSetNum stays
    //                  0 for its whole lifetime.
    //
    // TAKES mSetNum RATHER THAN A BOOLEAN so the call site cannot get the
    // comparison wrong in one place and right in another; the "> 0" lives here,
    // once, next to the paragraph that justifies it.
    static function strokeCounts(workoutEnabled, setNum) {
        if (!workoutEnabled) { return true; }
        return setNum > 0;
    }

    // Pure: does this screen draw the footer at all?
    //
    // #108 removes the REC footer from the work view, and the cost is accepted
    // there rather than glossed: mid-interval there is no recording assurance
    // on the screen at all. What must NOT go with it is a HARD FAILURE.
    //
    // FOOT_NO_ACCEL is #108's own acceptance criterion. With no accelerometer
    // the stroke rate is meaningless, so the one numeral the stripped work view
    // exists to show is a lie, and that has to stay visible.
    //
    // FOOT_NO_REC IS KEPT TOO, and this is a listed departure from #108's
    // element table rather than a quiet one. #108 enumerates "the REC footer"
    // and does not mention NOT RECORDING. But NO_REC is reachable during work
    // -- togglePause sets mRecFailed from a resume that isRecording() could not
    // confirm -- and it is precisely #74's defect: a row that looks like it is
    // recording and produces no FIT file. Suppressing it on the screen the
    // athlete spends most of the session on would re-create #74 in a new place,
    // which is a worse outcome than the one element of scope creep.
    //
    // The other three states need no exception. PAUSED is already surfaced
    // independently as the title, REC is the part #108 accepts losing, and IDLE
    // cannot occur inside a step (mStarted is what puts the view in one).
    //
    // Colour and layout only -- never a tone, vibration or flash (#114).
    static function workFootVisible(isWork, fs) {
        if (!isWork) { return true; }
        return fs == $.FOOT_NO_ACCEL || fs == $.FOOT_NO_REC;
    }

    // Pure: the REC footer's distance token, or a dash.
    //
    // THE ONE DISTANCE STRING THE UNIT SWITCH DID NOT REACH. Every other
    // distance figure on screen became conditional when erg mode landed -- the
    // pace row, both grid labels, both grid values -- and this one was left as
    // an unconditional `(dist / 1000.0).format("%.2f") + "km"`. Its input is
    // elapsedDist(), which collapses an absent reading to 0.0; the note at
    // currentPower() calls that collapse safe because a zero there "is either
    // harmless at the call site or out of band". THIS IS THE CALL SITE WHERE IT
    // IS NEITHER: on an erg elapsedDistance may have no source at all (that is
    // what ERGD_DST_OK exists to find out), so the footer rendered a fabricated
    // "0.00km", with a unit label, on a glance surface, in the mode this
    // feature ships. drawSetGrid's own header states the standard it broke: a
    // dash is a distinct answer, a zero is a claim.
    //
    // GATED ON ERG MODE ALONE, NOT ON useWorkUnits, and that is deliberate: the
    // footer's kilometres are not a UNIT question -- kilometres are kilometres
    // whichever units the arc is in -- they are a SOURCE question. Whether a
    // distance source exists is decided by whether the athlete is on a machine,
    // not by which figures they asked the arc to show. An athlete who turns the
    // units toggle off is asking for distance FIGURES, not for a fabricated
    // one.
    //
    // `dist <= 0.0` RATHER THAN A BARE NULL TEST, because it is not known
    // whether an absent distance arrives as null or as 0.0 -- and elapsedDist()
    // has already erased the difference by the time it gets here. This dashes
    // in both cases and SELF-HEALS: if the machine does broadcast as fitness
    // equipment, dist goes positive after the first few metres and the km token
    // returns, which is the correct reading of that situation.
    //
    // The null branch is unreachable from today's only caller (elapsedDist()
    // never returns null) and is stated as defence for a future one rather than
    // as a fix for anything observed.
    static function footDistStr(dist, ergMode) {
        if (dist == null) { return "--"; }
        if (ergFlag(ergMode, false) && dist <= 0.0) { return "--"; }
        return (dist / 1000.0).format("%.2f") + "km";
    }

    // ============ #110: the heart-rate arc, as pure decisions ================
    // Every judgement the left-edge arc makes lives here, as a class-scope
    // static taking plain numbers and booleans -- the same seam filterRr /
    // rrIsFresh / coreFieldsWanted / rateColour above use, and for the same
    // reason: the drawing itself needs a Dc and a fully-built view, which no
    // (:test) can supply.
    //
    // SCOPE, stated rather than implied, exactly as rateColour states it above:
    // these pin the PREDICATES, not the call site. The step-type test that
    // decides whether the arc is drawn at all, and the order of the draw calls,
    // are covered by review only.

    // Pure: is there a heart rate to show?
    //
    // TWO independent conditions, and #110 requires both: an EXPLICIT
    // "have we ever had a reading" flag, AND freshness. Never `bpm > 0`.
    // `lastMs > 0` is a third, cheap consistency check on the stamp itself --
    // it is not the presence test, it backs one up.
    //
    // Two corrections to an earlier revision of this comment, both mine:
    // System.getTimer() counts from DEVICE start, not app start, and it is a
    // 32-bit millisecond counter, so it WRAPS. Around a wrap `nowMs - lastMs`
    // goes large-negative and `< threshMs` reads as fresh -- measured,
    // hrHave(true, 2147483000, -2147483000, 5000) is true.
    //
    // NOT FIXED HERE, deliberately. rrIsFresh above is byte-for-byte the same
    // shape and predates this change, so this is an existing repository-wide
    // pattern rather than something #110 introduces, and **#70** owns it.
    // Fixing it in one of the two would leave the pair disagreeing about a
    // shared hazard, which is worse than a consistent one that is tracked. If
    // #70 is taken, a `(nowMs - lastMs) >= 0` term closes it in both.
    //
    // SECOND WRAP DIRECTION, and #70's stated scope does NOT close it. The
    // `lastMs > 0` term reads a LIVE heart rate as absent across the whole
    // negative half of the counter's cycle: on the same premise used above,
    // mLastHrMs = System.getTimer() is itself negative there, so the term is
    // false however fresh the reading is, and hrHave returns false on every
    // subsequent frame. A `>= 0` difference term does not help -- the guard
    // that fails is the timestamp's own sign.
    //
    // Left as-is on purpose. It fails to NO-DATA, which is the correct
    // direction to fail and is visually distinct; the opposite error would
    // render a stale reading as live. Recorded here so #70 sees both
    // directions rather than only the one it was filed for.
    //
    // Shaped like rrIsFresh above, deliberately not calling it: the RR pip's
    // freshness is about R-R batch arrival and this is about a bpm read. Two
    // signals that happen to share a shape today and must be free to diverge.
    // #123: the metres-per-stroke the arc should show, or null.
    //
    // TWO SOURCES, and which applies is the whole of the maintainer's rest
    // instruction: during WORK the live figure, during REST the average of the
    // interval just completed.
    //
    // The live source is deliberately NOT distPerStroke()'s return used
    // directly. That function answers 0.0 for its no-data case -- safe where
    // drawPace gates on `> 0.0`, and NOT safe here, because 0.0 maps to the
    // bottom of the range and renders RED, "far below benchmark". Absence
    // rendered as a value is the #86/#107 failure class and this arc's
    // acceptance list forbids it by name. The 0.0 becomes null once, here.
    //
    // The rest source is the LATCHED interval average from #109 -- interval
    // distance over interval strokes -- not an average of the live estimator.
    hidden function dpsForArc(type, spd) {
        if (type == STEP_REST) {
            if (!mLastSetValid) { return null; }
            return setAvgDps(mLastSetDist, mLastSetStrokes);
        }
        var live = distPerStroke(spd);
        if (live <= 0.0) { return null; }
        return live;
    }

    // The PERCENTAGE the right-edge arc is drawn from, or null.
    //
    // Extracted from onUpdate so the arc's whole input -- the value AND the
    // benchmark it is read against -- is one named decision a (:test) can
    // reach. onUpdate cannot be reached with a chosen unit system and then
    // interrogated about what it passed to drawDpsArc; this can.
    //
    // The GEOMETRY is deliberately untouched by any of this. dpsPct normalises
    // to a percentage of whatever benchmark it is given, so switching units
    // switches the numerator and the denominator together and every angle,
    // sweep, zone boundary and colour downstream is the shipped one. Re-deriving
    // the geometry for a second unit system is exactly what the #123 comment
    // block warns against at length.
    hidden function arcPct(type, spd) {
        if (useWorkUnits(mErgMode, mErgPowerUnits)) {
            return dpsPct(jpsForArc(type), mJouleBench);
        }
        return dpsPct(dpsForArc(type, spd), mDpsBench);
    }

    // The JOULES PER STROKE the arc should show in erg mode, or null.
    //
    // THE SAME TWO-SOURCE RULE dpsForArc states for distance, and it is the
    // maintainer's rest instruction rather than a symmetry for its own sake:
    // during WORK the live figure, during REST the average of the interval just
    // completed.
    //
    // The live source is joulesPerStroke(), which is ALREADY null for an absent
    // power reading -- so unlike dpsForArc, which has to convert
    // distPerStroke()'s 0.0 into a null here, this one has nothing to convert.
    // That is the whole reason currentPower() propagates a null where its three
    // neighbours collapse one to 0.0.
    //
    // The rest source is the LATCHED interval pair, and BOTH halves of it: the
    // joules and the flag that says a measurement was taken. Passing the joules
    // alone would render a powerless interval as 0.0 J/stroke, which maps to
    // the bottom of the arc and renders RED.
    hidden function jpsForArc(type) {
        if (type == STEP_REST) {
            if (!mLastSetValid) { return null; }
            // COVERAGE, not merely presence. `mLastSetWorkN > 0` would let an
            // interval whose power source was down for a quarter of its length
            // reach this arc under-reported by a quarter -- which maps an
            // on-benchmark athlete into the FAR zone and instructs them to row
            // harder. workCoverOk refuses; the arc then takes the null it
            // already handles as DPSZ_NONE.
            return setAvgJps(mLastSetWorkJ, mLastSetStrokes,
                             workCoverOk(mLastSetWorkN, mLastSetSec,
                                         $.TICK_MS));
        }
        return joulesPerStroke(currentPower(), outputRate());
    }

    // ============ #123: the distance-per-stroke arc, as pure decisions =====

    // Pure: metres per stroke as a PERCENTAGE of the benchmark, or null.
    //
    // Null, never 0.0, and this one has a specific trap behind it. The live
    // distPerStroke() returns 0.0 for its no-data case -- harmless where
    // drawPace gates on `> 0.0`, and NOT harmless here: 0.0 would map to the
    // bottom of the range and render RED, "far below benchmark", which is the
    // #86/#107 failure class this arc's own acceptance list forbids. So the
    // caller must hand this a value it has already established is real, and
    // this function refuses anything that is not.
    static function dpsPct(mPerStroke, benchmark) {
        if (mPerStroke == null || mPerStroke <= 0.0) { return null; }
        if (benchmark  == null || benchmark  <= 0.0) { return null; }
        return mPerStroke * 100.0 / benchmark;
    }

    // Pure: which of the four states a percentage is in.
    //
    // Boundaries are INCLUSIVE UPWARD -- exactly 100% is AT, not UNDER, because
    // the benchmark is a floor being cleared rather than a line being crossed.
    // Exactly 85% is UNDER rather than FAR for the same reason.
    static function dpsZone(pct) {
        if (pct == null)             { return $.DPSZ_NONE; }
        if (pct <  $.DPS_FAR_PCT)    { return $.DPSZ_FAR; }
        if (pct <  100)              { return $.DPSZ_UNDER; }
        if (pct <= $.DPS_OVER_PCT)   { return $.DPSZ_AT; }
        return $.DPSZ_OVER;
    }

    // Pure: the colour for a state. A CODE goes in, a colour comes out -- the
    // same shape hrZoneColour uses, so "no data" stays a different KIND of
    // answer rather than a colour that happens to differ.
    //
    // THE PALETTE, and why it is not the spectral ramp originally proposed.
    // Blue means "below target" on the heart-rate arc and on the stroke-rate
    // numeral, both shipped. A spectral ramp reaches blue at ~120% of
    // benchmark, i.e. GOOD -- and at a fraction of a second the eye reads the
    // colour before it locates which edge the arc is on, so position cannot
    // disambiguate. Blue is spent.
    //
    //   FAR    COLOR_RED    FF0000   losing the catch
    //   UNDER  COLOR_ORANGE FF5500   approaching
    //   AT     COLOR_GREEN  00FF00   at or above -- nothing to say
    //   OVER   COLOR_PURPLE AA00FF   exceptional
    //
    // All four are exact {00,55,AA,FF} cube entries, so they render identically
    // on the 64-colour fenix models and the AMOLEDs with no dither or hue
    // shift. Green spans everything from the benchmark upward, so on clearing
    // it the arc STOPS CHANGING -- the strongest available statement that
    // nothing is wrong. Purple is a reward tier rather than a gradient
    // position, and AA00FF is about as far from COLOR_BLUE's 00AAFF as the cube
    // allows.
    //
    // ORANGE FF5500 AND NOT YELLOW FFAA00, which is what the design comment
    // originally specified. MEASURED relative luminance separation:
    //
    //             vs GREEN   vs RED
    //   FFAA00      1.43x     2.35x
    //   FF5500      2.58x     1.31x
    //
    // The two boundaries are not worth the same. 85% separates "losing the
    // catch" from "approaching" -- both are below the benchmark and both mean
    // the same corrective action, so confusing them costs nothing. 100% IS THE
    // BENCHMARK: it is the one transition this arc exists to show, and it is
    // the expensive error. So separation from green is bought at red's
    // expense, deliberately.
    //
    // Note this is a LUMINANCE argument, not a hue one, which is what makes it
    // survive deuteranopia -- where FFAA00 and 00FF00 both read as yellowish
    // and 1.43x is not enough to part them.
    //
    // The fill's edge against the track is weak for THREE of the four --
    // purple 1.47:1, red 1.86:1, orange 2.33:1; only green at 5.43:1 clears the
    // 3:1 floor this file applies elsewhere. The swap argued above is what put
    // orange there: FFAA00 was 3.91:1 and cleared it. A second, accepted cost
    // of the swap, paid for the same reason -- stated because an earlier
    // revision counted two and named the wrong pair.
    //
    // ACCEPTED, not overlooked: per the correction on #119, position is carried
    // by the head tick in its OWN radial lane at 21:1 against black, not by the
    // fill's chromatic edge. Copy the lane.
    //
    // RED NOW MEANS OPPOSITE THINGS ON THE TWO EDGES, and the premise that
    // spent blue applies here too. On the left arc red is HRZ_ABOVE -- too
    // high, ease off. On this arc red is DPSZ_FAR -- too low, put more in. Both
    // are drawn at the same instant, mirrored, at identical radii, and by that
    // same premise the colour is read before the edge is located.
    //
    // Kept anyway, as a LISTED DECISION rather than an oversight: red-for-bad
    // is the strongest convention this palette has, both readings mean
    // "something needs correcting", and which correction is obvious from the
    // stroke rate the athlete is already looking at. If it proves confusable on
    // the water it is the DPS side that should move, because the heart-rate
    // arc's red is shared with the REC footer and the GPS pip and is therefore
    // the more expensive one to change.
    static function dpsZoneColour(zone) {
        if (zone == $.DPSZ_FAR)   { return Gfx.COLOR_RED; }
        if (zone == $.DPSZ_UNDER) { return Gfx.COLOR_ORANGE; }
        if (zone == $.DPSZ_AT)    { return Gfx.COLOR_GREEN; }
        if (zone == $.DPSZ_OVER)  { return Gfx.COLOR_PURPLE; }
        return Gfx.COLOR_DK_GRAY;
    }

    // Pure: where a percentage sits on the sweep, in whole degrees.
    //
    // Mirrored from hrAngle, and the mirror is why the arithmetic looks
    // inverted: on the RIGHT edge a bigger value is a bigger angle measured up
    // from DPS_ARC_BOT, whereas on the left a bigger value was a SMALLER angle.
    // Clamped to [0,1] before mapping, so the return is always inside the
    // sweep and a wild reading cannot draw outside it.
    //
    // Returns a value in [DPS_ARC_BOT-360, DPS_ARC_TOP] = [-28, 28] rather than
    // wrapping through 332, because the caller needs a MONOTONIC number to
    // compare and to sweep between. Only the draw call needs the wrap.
    static function dpsAngle(pct) {
        var f = (pct - $.DPS_DISP_LO) * 1.0 / ($.DPS_DISP_HI - $.DPS_DISP_LO);
        if (f < 0.0) { f = 0.0; }
        if (f > 1.0) { f = 1.0; }
        var lo = $.DPS_ARC_BOT - 360;      // -28
        return (lo + f * ($.DPS_ARC_TOP - lo)).toNumber();
    }

    // Pure: the same angle as drawArc wants it -- [0,360).
    static function dpsWrap(deg) {
        if (deg < 0) { return deg + 360; }
        return deg;
    }

    // Pure: how many whole degrees of fill a percentage asks for, from the
    // bottom of the sweep.
    static function dpsFillSweep(pct) {
        return dpsAngle(pct) - ($.DPS_ARC_BOT - 360);
    }

    // Pure: is the fill worth drawing at all?
    //
    // Same hazard as the HR arc's: drawArc draws a COMPLETE CIRCLE when its two
    // angles are equal, so a zero-degree fill is a ring across the whole
    // display rather than a mark nobody notices.
    //
    // WHAT THIS COSTS, stated because the HR arc's equivalent comment had to be
    // corrected for glossing it: the fill is the sole carrier of the zone
    // colour, so suppressing it suppresses the colour too. At the shipping
    // constants the first percentage with a visible fill is 62% of benchmark,
    // so 0-61% renders uncoloured. That band is "far below" for any benchmark,
    // where the head tick still marks the position.
    static function dpsFillVisible(pct) {
        return dpsFillSweep(pct) >= $.HR_ARC_MIN_D;
    }

    // Pure: is the reading pinned at an end of the display range?
    static function dpsIsClamped(pct) {
        return pct < $.DPS_DISP_LO || pct > $.DPS_DISP_HI;
    }

    static function hrHave(ever, lastMs, nowMs, threshMs) {
        return ever && lastMs > 0 && (nowMs - lastMs) < threshMs;
    }

    // The freshness clock, as one overridable call.
    //
    // Exists because System.getTimer() counts from DEVICE start, so any
    // render-level staleness case had to synthesise a stamp far enough in the
    // past to be stale AND still positive -- which needs 10 * HR_FRESH_MS of
    // device uptime. A CI simulator is seconds old when the suite runs, so
    // such a case is not merely flaky, it is reliably RED there and green on a
    // long-lived desktop simulator. That asymmetry is the worst kind: it
    // passes where it is written and fails where it is judged.
    //
    // A probe overrides this and the case becomes deterministic on any device.
    hidden function nowMs() {
        return System.getTimer();
    }

    // Pure: which zone is this heart rate in?
    //
    // Returns a CODE, never a colour, so that "no data" is a different kind of
    // answer rather than a different colour -- see the HRZ_* constants.
    //
    // Boundary inclusivity matches rateColour: `bpm == lo` is neither `< lo`
    // nor `> hi`, so it is in band, and likewise `bpm == hi`.
    //
    // PRESENCE IS THE FLAG, NEVER THE VALUE, and the difference is the whole
    // reason this function takes hasHr at all. `bpm > 0` -- the guard
    // rateColour uses two hundred lines above -- is SOUND there, because
    // outputRate() genuinely returns 0.0 when nothing has been measured. It is
    // unsound here: the last bpm SURVIVES in mHrBpm after the heart-rate source
    // drops, so gating on it keeps painting a stale reading, and the moment
    // that reading sits under the band it paints BELOW BAND -- telling the
    // rower to work harder on the strength of a number that no longer exists.
    // #86 shipped a 0.0 skin temperature that way and #107 shipped "--.-" that
    // way; this is the third time the same premise has been checked, and the
    // first time it does not hold.
    //
    // A caller passing hasHr = true with bpm <= 0 gets a zone rather than
    // HRZ_NONE. That combination is unreachable -- sampleHr stamps mHrEver only
    // for a reading it has already validated as > 0 -- and it is deliberately
    // NOT given a second guard here, because a redundant `bpm > 0` term is
    // exactly what would let a future reader conclude the value is what decides
    // presence.
    static function hrZone(hasHr, bpm, lo, hi) {
        if (!hasHr) { return $.HRZ_NONE; }
        if (bpm < lo) { return $.HRZ_BELOW; }
        if (bpm > hi) { return $.HRZ_ABOVE; }
        return $.HRZ_IN;
    }

    // Pure: the fill colour for a zone. Identical constants to rateColour, so
    // the arc and the stroke-rate numeral share one vocabulary rather than two
    // that happen to agree today.
    //
    // HRZ_NONE maps to the track colour and is never actually painted as a
    // fill: the no-data state draws no fill at all. It is returned so that the
    // function is total.
    static function hrZoneColour(zone) {
        if (zone == $.HRZ_BELOW) { return Gfx.COLOR_BLUE; }
        if (zone == $.HRZ_IN)    { return Gfx.COLOR_GREEN; }
        if (zone == $.HRZ_ABOVE) { return Gfx.COLOR_RED; }
        return Gfx.COLOR_DK_GRAY;
    }

    // Pure: the arc angle, in whole degrees, for a heart rate.
    //
    // The `* 1.0` is load-bearing and not decoration: both operands are Numbers
    // and Monkey C would do INTEGER division, pinning every rate below the top
    // of the range to the bottom of the arc.
    //
    // Returns a Number because drawArc truncates its arguments anyway --
    // doing it here means every caller, and every test, sees the value the
    // renderer will actually use.
    static function hrAngle(bpm) {
        var f = (bpm - $.HR_DISP_LO) * 1.0 / ($.HR_DISP_HI - $.HR_DISP_LO);
        if (f < 0.0) { f = 0.0; }
        if (f > 1.0) { f = 1.0; }
        return ($.HR_ARC_BOT - f * ($.HR_ARC_BOT - $.HR_ARC_TOP)).toNumber();
    }

    // Pure: how many whole degrees of fill a heart rate asks for, measured from
    // the bottom of the sweep. Zero at or below the bottom of the display
    // range, which is the case the full-circle hazard lives in.
    static function hrFillSweep(bpm) {
        return $.HR_ARC_BOT - hrAngle(bpm);
    }

    // Pure: should the fill arc be drawn at all?
    //
    // The test is on the SWEEP, not on the heart rate, because the hazard is
    // geometric: drawArc draws a COMPLETE CIRCLE when its two angles are equal,
    // so a fill of zero degrees is a ring across the whole display rather than
    // a mark nobody notices. One degree is not zero but is not drawable either,
    // so the floor is the same HR_ARC_MIN_D the band marker uses.
    //
    // WHAT THIS COSTS, stated rather than waved past. An earlier revision said
    // "nothing is lost except an arc that could not have been seen". That is
    // false: the fill is the SOLE carrier of the blue / green / red zone
    // colour, so suppressing it suppresses the colour too. At the shipping
    // constants the first heart rate with a visible fill is 82 bpm --
    // MEASURED, by walking hrAngle over 0..260 -- so every reading from 0
    // through 81 renders with no zone colour at all. (#108's wider sweep moved
    // that threshold down from 83: a degree is worth less bpm now, so the
    // second drawable degree arrives sooner.)
    //
    // Accepted, for two reasons. The head tick still marks the position, so
    // the reading is not invisible, only uncoloured. And the suppressed band
    // is "far below target" for any plausible target, where the colour would
    // be telling the athlete something the numeral and the tick position
    // already say. It is worth knowing because the case where blue would
    // matter most is exactly the case that does not render it.
    //
    // Note what this does NOT decide: whether there is a heart rate at all.
    // That is hrHave's job, and drawHrArc conjoins the two.
    static function hrFillVisible(bpm) {
        return hrFillSweep(bpm) >= $.HR_ARC_MIN_D;
    }

    // Pure: the target band as a drawArc counter-clockwise pair,
    // [degreeStart, degreeEnd], with degreeStart the HIGH-bpm end because
    // degrees decrease as bpm rises.
    //
    // Ordered defensively even though loadSettings already swaps inverted
    // input: this is a public static and its post-condition should not depend
    // on a caller elsewhere in the file.
    //
    // POST-CONDITION: degreeEnd - degreeStart >= HR_ARC_MIN_D, always. That is
    // not a nicety. drawArc draws a COMPLETE CIRCLE when its two angles are
    // equal, so a band whose ends land on the same truncated degree is a ring
    // across the entire display, over every other element on the screen.
    //
    // The widening is applied to the TRUNCATED degrees, and it has to be:
    // 120-121 bpm is a legitimate one-bpm band whose two angles truncate one
    // degree apart, and one more bpm of narrowing collapses them. Checking the
    // bpm instead would miss both.
    //
    // Widening is symmetric about the midpoint, then pushed back inside the
    // sweep if it overran an end. With a 56-degree sweep and a 2-degree floor
    // it cannot overrun both, so the second correction cannot undo the first.
    static function hrBandArc(lo, hi) {
        var a1 = hrAngle(hi);
        var a2 = hrAngle(lo);
        if (a2 < a1) { var t = a1; a1 = a2; a2 = t; }
        if (a2 - a1 < $.HR_ARC_MIN_D) {
            var mid = (a1 + a2) / 2;
            a1 = mid - $.HR_ARC_MIN_D / 2;
            a2 = a1 + $.HR_ARC_MIN_D;
            if (a1 < $.HR_ARC_TOP) {
                a1 = $.HR_ARC_TOP;
                a2 = $.HR_ARC_TOP + $.HR_ARC_MIN_D;
            }
            if (a2 > $.HR_ARC_BOT) {
                a2 = $.HR_ARC_BOT;
                a1 = $.HR_ARC_BOT - $.HR_ARC_MIN_D;
            }
        }
        return [a1, a2];
    }

    // Pure: is this reading off the end of the display range, so that the arc
    // is showing an endpoint rather than a position? #110 requires the clamp to
    // be visible -- 210 bpm and 200 bpm must not render identically, and
    // neither must 50 and 60.
    //
    // BOTH ends, and the low one is the point: an above-range reading is the
    // case everyone thinks of, and a below-range one is the case that quietly
    // parks the marker at the bottom of the scale and calls it a heart rate.
    static function hrIsClamped(bpm) {
        return bpm < $.HR_DISP_LO || bpm > $.HR_DISP_HI;
    }

    // Pure: how many segments the grey track is drawn in.
    //
    // The track's CONTINUITY is one of the three independent channels that
    // separate "no data" from any reading -- the others being the absent fill
    // and the absent head tick. One continuous arc means "there is a heart
    // rate"; more than one means there is not.
    //
    // Three segments rather than two: an even count puts a gap at the exact
    // middle of the sweep, where the default band sits, and the gap would then
    // read as a feature of the band rather than of the track.
    //
    // Why the track needs its own channel at all: "no fill" and "a fill too
    // short to see" are the same picture, so withholding the fill cannot on its
    // own say "there is no heart rate".
    static function hrTrackParts(hasHr) {
        return hasHr ? 1 : 3;
    }

    // Pure: the width in degrees of one drawn segment of the broken track.
    //
    // FLOAT division, deliberately. `parts` segments separated by `parts - 1`
    // gaps of the same width is `2 * parts - 1` equal slices of the sweep, and
    // at the shipping constants that is 56 / 5. Integer arithmetic truncates
    // that to 11 and leaves a FIVE-DEGREE TAIL WITH NO TRACK AT ALL -- the arc
    // simply stops short of its own end. (At the previous 44-degree sweep the
    // same defect truncated 8.8 to 8 and left a four-degree tail, drawing
    // [158,166] [174,182] [190,198].) 56 / 5.0 = 11.2 spans the sweep exactly,
    // ending the last segment on HR_ARC_BOT.
    //
    // The MIN_D floor is kept for the degenerate case where a future `parts`
    // would slice the sweep below the minimum drawable arc; when it fires the
    // segments no longer span the sweep, which is correct -- a floor that
    // stretched them would be a lie about how many parts were drawn.
    static function hrTrackSeg(parts) {
        if (parts <= 1) { return ($.HR_ARC_BOT - $.HR_ARC_TOP) * 1.0; }
        var seg = ($.HR_ARC_BOT - $.HR_ARC_TOP) / (2.0 * parts - 1.0);
        if (seg < $.HR_ARC_MIN_D) { seg = $.HR_ARC_MIN_D * 1.0; }
        return seg;
    }

    // Pure: the heart-rate band, swapped if inverted and clamped to the arc's
    // display range at BOTH ends.
    //
    // Split out from loadSettings rather than written inline for the usual
    // reason -- loadSettings needs App.Properties and a built view, so no
    // (:test) can reach the clamp there -- and because #21 is precisely the
    // defect of a clamp that exists in settings.xml and nowhere in code.
    static function hrClampBand(lo, hi) {
        if (hi < lo) { var t = lo; lo = hi; hi = t; }
        if (lo < $.HR_DISP_LO) { lo = $.HR_DISP_LO; }
        if (lo > $.HR_DISP_HI) { lo = $.HR_DISP_HI; }
        if (hi < $.HR_DISP_LO) { hi = $.HR_DISP_LO; }
        if (hi > $.HR_DISP_HI) { hi = $.HR_DISP_HI; }
        return [lo, hi];
    }

    // ----------------- R-R / HRV state model (epic #59) ---------------------
    // One row per piece of state, ONE MEANING per row. Any PR that changes
    // this model updates its own row(s) here in the same commit -- this table
    // is the model; the code below implements it.
    //
    //   mLastRrMs    "did a batch arrive?"  Stamped on every non-empty batch,
    //                before filtering. Init 0, never reset. Sole consumer: the
    //                display RR pip (drawGps). Not a data-validity signal.
    //   mLastBeatMs  "was a beat RANGE-accepted?" Stamped for every such
    //                beat (batch-arrival time -- all beats in a batch share
    //                one stamp). Init 0, never reset; 0 <=> no beat ever
    //                RANGE-accepted. Consumers: the rrGapExceeded gap reset,
    //                and onTick's rMSSD freshness gate (#15).
    //   mRrLast      "what is the adjacency reference?" The last
    //                RANGE-accepted beat's INTERVAL in ms -- a value, not a
    //                timestamp, unlike the rows above (RR_ART_K * mRrLast
    //                only parses that way). ARTIFACT-rejected beats still
    //                advance it. Zeroed on an inter-batch gap (#16) so the
    //                next beat seeds instead of diffing; init 0; no
    //                session-boundary reset today -- PR-C of epic #59 ADDS
    //                one (#59; #68 window 1 for why). Known gap: intra-batch
    //                RANGE rejections do not reset it (#37).
    //   mDiffSq / mDiffIdx / mDiffCount
    //                The rMSSD window: the last ~RR_NDIFF SQUARED
    //                ARTIFACT-accepted successive differences -- the ring
    //                stores d*d, not d, so recomputeRmssd sums it directly.
    //                Fixed-size OVERWRITING ring -- oldest evicted once full,
    //                ~90 pairs retained; init empty; never cleared on a gap
    //                (#39) and no session-boundary reset today -- PR-C of
    //                epic #59 ADDS one (#59). The code depends on
    //                mDiffIdx == mDiffCount while filling (entries beyond
    //                mDiffCount are null).
    //   mRmssd       Cached rMSSD over the ring; 0.0 is BOTH the
    //                "insufficient data" sentinel (mDiffCount < 5) and the
    //                honest value of a fully flat ring (sqrt(0) -- #68's
    //                window 3). Init 0.0; no session-boundary reset today --
    //                PR-C of epic #59 ADDS one (#59). Consumers: onTick's
    //                trace write and accumulator -- with asymmetric guards
    //                today; #68. There is no UI consumer: mRmssd is a LOGGED
    //                value, not an on-watch one.
    //
    // "PR-C ADDS", precisely: stopAndSave has never reset mRrLast, the ring,
    // or mRmssd, so PR-C INTRODUCES those resets rather than restoring them.
    // #39 is the dropout ring-clear -- a different question from session
    // boundaries, which are #59's plan (see #68 window 1).
    //
    // Two DIFFERENT accept gates appear above, named consistently:
    // RANGE-accepted means the interval survives [RR_MIN_MS, RR_MAX_MS]
    // after toNumber (filterRr); ARTIFACT-accepted means the successive
    // difference also cleared RR_ART_K. Every row advances regardless of
    // mStarted/mPaused -- handleRr runs whenever batches arrive -- which is
    // what makes #68's window 1 a race today rather than a certainty.
    // Freshness is keyed on RANGE-accepted BEATS, not ARTIFACT-accepted
    // DIFFS, so sustained artifact rejection still reads "fresh" (#38);
    // and both freshness gates share the single RR_FRESH_MS constant --
    // splitting it is #40.
    // Clock caveat: NEITHER freshness helper has been analysed across a
    // System.getTimer() rollover (~24.9 days IF the counter is signed 32-bit
    // -- itself unmeasured), and by inspection the two would NOT fail alike
    // (the tsMs > 0 guards cut opposite ways); treat rollover behaviour as
    // unspecified -- #70.
    // -------------------------------------------------------------------------
    hidden function handleRr(ivals) {
        if (ivals == null) { return; }
        if (ivals.size() <= 0) { return; }
        var now = System.getTimer();
        mLastRrMs = now;   // batch-arrival stamp (drives the display indicator)

        // #16: if the gap since the last RANGE-accepted beat exceeds one max
        // interval, a beat was missed -- the next beat is not a consecutive
        // successor, so drop the stale reference (using the OLD mLastBeatMs,
        // before this batch restamps it). The `if (mRrLast > 0)` guard below
        // then makes the first post-gap beat seed only, injecting no bogus
        // rMSSD difference.
        if (rrGapExceeded(now, mLastBeatMs, $.RR_MAX_MS)) { mRrLast = 0; }

        var valid = filterRr(ivals);   // single in-range source for both paths

        // rMSSD: same in-range set, plus the artifact gate (rMSSD-only). Runs
        // regardless of recording state; only the FIT write below is gated.
        for (var i = 0; i < valid.size(); i++) {
            var rr = valid[i];
            if (mRrLast > 0) {
                var d = rr - mRrLast;
                if (d < 0) { d = -d; }
                if (d <= RR_ART_K * mRrLast) {
                    mDiffSq[mDiffIdx] = (d * 1.0) * d;
                    mDiffIdx = (mDiffIdx + 1) % RR_NDIFF;
                    if (mDiffCount < RR_NDIFF) { mDiffCount++; }
                }
            }
            mRrLast = rr;
            mLastBeatMs = now;   // #15/#16: last RANGE-accepted beat (batch beats share `now`)
        }

        // FIT record: first RR_PER_REC valid intervals, padded with RR_INVALID.
        // An all-invalid batch (valid empty) skips the write -- and the field
        // LATCHES (the RECORD-SCOPE FIELDS LATCH block in startSession, above
        // the createField calls, carries that fact; the state model above
        // carries the R-R state, not the latch): the record re-emits the last
        // written array, or stays never-set before any write. An earlier
        // version of this comment claimed the field is left "absent for that
        // record"; #36 disproved that. The dropout sentinel fix is #46's
        // scope.
        if (valid.size() > 0 && mFitRr != null && mStarted && !mPaused) {
            mFitRr.setData(packRr(valid));
        }
        recomputeRmssd();
    }

    hidden function recomputeRmssd() {
        if (mDiffCount < 5) { mRmssd = 0.0; return; }
        var s = 0.0;
        for (var i = 0; i < mDiffCount; i++) { s += mDiffSq[i]; }
        mRmssd = Math.sqrt(s / mDiffCount);
    }

    hidden function registerStroke(t) {
        if (mLastStrokeT > -50.0) {
            var p = t - mLastStrokeT;
            if (p >= 60.0 / $.MAX_RATE && p <= 60.0 / $.MIN_RATE) {
                mPeriods[mPIdx] = p;
                mPIdx = (mPIdx + 1) % NPER;
                if (mPCount < NPER) { mPCount++; }
                mLastPeriod = p;
                // #109: the counter stops while paused, so that all FOUR raw
                // totals treat a pause the same way. Seconds exclude it (via
                // the pause-corrected mStepStartMs), distance excludes it (via
                // mSetPausedDist) and the HR fold is gated on !mPaused -- and an
                // earlier revision left this one running, which did not remove
                // the error, it INVERTED it. The accelerometer listener runs
                // independently of recording, so drinking, wiping down or
                // gesturing during a pause registers as strokes: 63 real
                // strokes plus ten such movements latched 73 over a 240 s
                // denominator, 18.25 spm.
                //
                // BOTH REFERENCES, because 15.75 is not the truth -- it is the
                // gated counter still carrying the -1 bias documented at the
                // latch. The athlete rowed 16.0. So it is a 16% over-report
                // against what this app would otherwise show and 14% against
                // reality, and either way it crosses the default 16-18 band.
                //
                // mRate and the DSP ring above are left running because
                // clearing them would blank the numeral for NPER strokes after
                // every resume.
                //
                // THAT IS A TRADE, NOT A CLEAN WIN, and the cost follows from
                // the same premise as the paragraph above: sustained motion at
                // a 1.5-10 s cadence during a pause holds the median at a rate
                // no COUNTED stroke produced, and it survives the first strokes
                // after the resume because NPER is 5. It reaches FOUR things,
                // and they do NOT share a bound:
                //
                //   THE THREE THAT ARE BOUNDED. outputRate feeds the numeral,
                //   distPerStroke (and so mFitDps), rateColour's band and
                //   correctiveRate's session-scope mCorrAccum -- all under
                //   onTick's mStarted && !mPaused gate, so they take the
                //   contamination only AFTER the resume and only until the
                //   median clears, which is a couple of strokes because NPER
                //   is 5. Pre-existing behaviour, unchanged here.
                //
                //   mRateBase (#149) IS NOT ONE OF THEM, and that is why
                //   updateRateBase carries a pause gate and a post-resume hold
                //   of its own -- see its note. The baseline is an EMA, so it
                //   does not "clear" when the median does; and it sets the
                //   NO-LOCK GATE, so a baseline dragged down by a phantom
                //   cadence ZEROES the athlete's own rate rather than merely
                //   misreporting it, in the FILE. Left ungated it cost tens of
                //   strokes of row_stroke_rate and dist_per_stroke reading 0.0
                //   over real rowing (measured; the figures are in
                //   updateRateBase's note). The gate and the hold are NEW in
                //   #149, not pre-existing, and they close the whole of that
                //   fourth cost -- not the three above it.
                //
                // A quiet pause is safe for all four: the ring times out after
                // 4-12 s and takes the baseline with it. Recorded so the next
                // reader does not take any of this for deliberate correctness.
                if (!mPaused) {
                    mStrokeCount++;
                    // #125: the footer's figure. The SESSION counter above is
                    // deliberately left counting everything -- mLastSetStrokes
                    // is a delta between two readings of it, so narrowing its
                    // gate would move every per-interval figure the grid shows.
                    if (strokeCounts(mWorkoutEnabled, mSetNum)) {
                        mWorkStrokes++;
                    }
                }
                recomputeRate();
            }
        }
        mLastStrokeT = t;
    }

    // rate from the MEDIAN of the last NPER stroke periods: one bad period
    // (missed or spurious peak) cannot move the readout
    hidden function recomputeRate() {
        if (mPCount <= 0) { mRate = 0.0; return; }
        var tmp = new [mPCount];
        for (var i = 0; i < mPCount; i++) { tmp[i] = mPeriods[i]; }
        for (var i = 1; i < mPCount; i++) {
            var v = tmp[i];
            var j = i - 1;
            while (j >= 0 && tmp[j] > v) { tmp[j + 1] = tmp[j]; j--; }
            tmp[j + 1] = v;
        }
        var med = tmp[mPCount / 2];
        if (mPCount % 2 == 0) { med = (med + tmp[mPCount / 2 - 1]) / 2.0; }
        if (med > 0.0) { mRate = 60.0 / med; }
        // #149: one baseline update per REGISTERED STROKE. This is the ONLY
        // caller, and registerStroke is the only caller of this -- so the
        // baseline advances on a physical clock rather than on however many
        // consumers happen to read outputRate() in a given frame.
        updateRateBase();
    }

    // ================= the OUTPUT STAGE (#149) =============================
    // THIS STAGE CHANGES A RECORDED VALUE, DELIBERATELY, AND THAT IS NOT THE
    // THING THE MAINTAINER'S RULE FORBIDS. Read this before "restoring" it.
    //
    // outputRate() feeds three FIT writes -- row_stroke_rate (onTick),
    // dist_per_stroke (via distPerStroke) and corrective_rate (via
    // correctiveRate) -- so a change here moves what lands in the file. The rule
    // is "the in-row measurement is a cue, but keep the ACTUAL measurement in
    // the file", and the distinction it draws is between:
    //
    //   FILTERING THE FILE FOR DISPLAY -- forbidden. Smoothing, hysteresis or
    //   any other treatment applied because it reads better on a wrist. That is
    //   what the DISPLAY CUE (the CUE_* block below) exists to hold, and why
    //   the cue keeps no rate at all: it produces a ZONE, and the number on
    //   screen and the number in the file both come straight from here.
    //
    //   CORRECTING A DETECTOR ERROR -- required. The over-reads are measured
    //   against an INDEPENDENT witness: across the seconds reading above 1.25x
    //   their own lap's median rate, the hull sits at 0.814x (calm row) and
    //   0.692x (choppy row) of that lap's median speed, while the seconds that
    //   are NOT over-reads sit at 0.989x and 0.997x. enhanced_speed is recorded
    //   independently of this detector and a genuine rate rise pushes speed UP,
    //   so these are wrong readings -- and leaving a wrong reading in the file
    //   is not fidelity. Every figure in this paragraph is printed by
    //   `python3 scripts/speed_witness.py` from two committed fixtures and
    //   pinned by scripts/test_speed_witness.py; the control in the second
    //   clause is what separates "the hull is slower HERE" from an artefact of
    //   the statistic.
    //
    //   RETRACTION. This paragraph previously read "0.851x (calm) and 0.916x
    //   (choppy)", with no committed witness of any kind -- the repository's
    //   only extract of these two rows carries stroke rate and nothing else,
    //   and says so in its own header. Those two figures are WITHDRAWN: the
    //   harness sweeps 48 definitions per row and gets 0.7890-0.8666 for the
    //   calm row, which brackets 0.851, and 0.5630-0.7866 for the choppy row,
    //   which never reaches 0.916. So the published pair cannot have come from
    //   one consistent definition and 0.916 is unsupported by anything these
    //   recordings contain. What survives is the direction, and it survives
    //   with room to spare: all 96 sweep values are well under 1.0.
    //
    // Nothing here consults the display, the cue, or any zone. It consults the
    // detector's own two witnesses -- the autocorrelation lock and the rate the
    // athlete has actually been holding -- and it is the same value that then
    // reaches the screen and the file. If a future change makes this stage read
    // anything a screen owns, that is the line being crossed.

    // Pure: the spm above which a reading needs the autocorrelation lock to
    // corroborate it, given the rate this athlete has established.
    //
    //     gate(base) = min( FAST_NEEDS_LOCK,
    //                       max( LOCK_GATE_FLOOR, LOCK_REL_K * base ) )
    //     gate(none) = FAST_NEEDS_LOCK
    //
    // Read outward from the middle term:
    //
    //   LOCK_REL_K * base   is the change. The same MULTIPLE for every athlete
    //                       -- the one a 20 spm rower already had -- instead of
    //                       a fixed 30.0 that is 1.48x for one rower and 1.98x
    //                       for another (#149, measured on two decoded rows).
    //
    //   max(FLOOR, ...)     stops the gate tracking below the rate the absolute
    //                       constant was calibrated at. A ZEROED READING DOES
    //                       NOT ESTABLISH THE BASELINE, so without this a
    //                       baseline left at a rest cadence could reject an
    //                       entire work interval. Binds only under 13.33 spm.
    //
    //   min(ABSOLUTE, ...)  is #149's first bar as an invariant of the code
    //                       rather than of the tuning: at NO baseline can this
    //                       return more than what shipped, so no reading that
    //                       used to be zeroed can now pass.
    //
    //   base <= 0.0         is "nothing established yet" -- APP LAUNCH, or
    //                       after the stroke ring timed out. NOT session start,
    //                       and the difference is reachable rather than
    //                       pedantic: mRateBase is zeroed in exactly two places,
    //                       resetDetector (whose ONLY caller is initialize --
    //                       the file states that at resetDetector itself) and
    //                       the ring timeout. onLayout registers the
    //                       accelerometer listener, registerStroke has no
    //                       mStarted gate, and neither startSession nor
    //                       beginSessionAccum touches detector state -- so a
    //                       warm-up or a paddle to the start ESTABLISHES the
    //                       baseline before START is pressed, and a session
    //                       reaches this state only if the ring has timed out
    //                       first (mLastPeriod * 2.2, clamped to 4-12 s, of
    //                       quiet). That is deliberate, not a defect: the note
    //                       at the ring timeout argues it, and the outer min
    //                       keeps the gate never looser than what shipped
    //                       either way. It is NOT "no guard": it falls back to
    //                       exactly the rule that shipped. Null is handled for
    //                       the same reason every other predicate in this file
    //                       handles it: an absent value must not be arithmetic.
    //
    // WHAT THIS IS NOT. It is not validated on the water. What is established is
    // that the over-reads are real detector errors -- the hull sits at 0.814x /
    // 0.692x of its own lap's median speed across them against 0.989x / 0.997x
    // across every other second, and speed is recorded independently of this
    // detector (regenerate with scripts/speed_witness.py) -- and that the
    // absolute gate is relative-blind. It is NOT established that the gate is
    // what lets them through: whether the autocorrelation lock was even up
    // during those excursions is unanswerable from any recording that exists,
    // which is what the lock_* diagnostic fields are for. This ships as a
    // reasoned correction to a guard that is wrong on its own terms, not as a
    // measured fix for the reported symptom.
    static function fastGate(base) {
        if (base == null || base <= 0.0) { return $.FAST_NEEDS_LOCK; }
        var g = $.LOCK_REL_K * base;
        if (g < $.LOCK_GATE_FLOOR)   { g = $.LOCK_GATE_FLOOR; }
        if (g > $.FAST_NEEDS_LOCK)   { g = $.FAST_NEEDS_LOCK; }
        return g;
    }

    // Pure: the whole output-stage decision, as a function of the three inputs
    // it actually has.
    //
    //   raw        the detector's median rate, spm (mRate)
    //   acPeriod   the autocorrelation lock period in seconds, 0.0 for NO LOCK
    //   base       the established rate, spm, 0.0 for NONE YET
    //
    // A STATIC AND NOT A METHOD, so the decision is reachable from a (:test)
    // with plain numbers -- the seam rateColour, cueStep, footState, hrZone and
    // dpsZone all use. A (:test) never yields to the simulator event loop, so a
    // decision reachable only through a built view and a Dc is a decision only
    // a render case can see.
    static function gatedRate(raw, acPeriod, base) {
        var r = raw;
        if (acPeriod > 0.0) {
            var ac = 60.0 / acPeriod;
            if (r > 0.0) {
                var dev = r - ac;
                if (dev < 0.0) { dev = -dev; }
                if (dev > $.LOCK_SNAP_K * ac) { r = ac; }
            }
        } else if (r > fastGate(base)) {
            r = 0.0;
        }
        if (r > $.MAX_RATE) { r = $.MAX_RATE; }
        return r;
    }

    // Pure: the established-rate baseline after one stroke.
    //
    //   base       the baseline before this stroke, 0.0 for NONE YET
    //   guarded    what the OUTPUT STAGE PUBLISHED for this stroke, i.e. what
    //              gatedRate returned. 0.0 means it published nothing.
    //   raw        the detector's median for this stroke
    //
    // THE BASELINE FOLDS IN WHAT THE APP BELIEVED, NOT WHAT THE DETECTOR SAID.
    // That distinction is the whole of this function and it was got wrong once
    // (round 2, finding 5/6), so it is written out. gatedRate has THREE
    // outcomes, not two:
    //
    //   PASSED THROUGH   guarded == raw. The ordinary case.
    //   ZEROED           guarded == 0.0. No lock corroborated a reading above
    //                    fastGate(base), so nothing was published.
    //   CORRECTED        guarded > 0.0 AND guarded != raw -- the lock SNAP
    //                    (gatedRate, the LOCK_SNAP_K branch), and the MAX_RATE
    //                    clamp. The output stage has just declared `raw` wrong
    //                    and substituted its own answer.
    //
    // The earlier revision tested only `guarded > 0.0` and then folded in `raw`,
    // so a CORRECTED reading counted as corroboration and the discarded median
    // set the bar. Measured, on this tree: a first-stroke median of 38.0 spm
    // against a 20.0 spm lock snapped to 20.0 and still established a baseline
    // of 38.0, which fastGate maps to FAST_NEEDS_LOCK exactly -- the relative
    // gate collapsing to the absolute constant it exists to replace, disarmed
    // by the very readings the snap flagged as errors.
    //
    // THE FIRST PUBLISHED READING ESTABLISHES THE BASELINE OUTRIGHT rather than
    // easing a zero toward it, because an EMA started from 0.0 would spend its
    // first strokes claiming the athlete rows at 4 spm and would gate them at
    // the floor for no reason.
    //
    // A ZEROED READING STILL MOVES THE BASELINE, slowly, and that clause is the
    // escape hatch rather than an oversight: see the LOCK_BASE_A_REJ note at the
    // top of this file. Without it the guard can deadlock -- reject, so the
    // baseline never moves, so reject -- and the deadlock is permanent because a
    // rejected reading is exactly the one that would have lifted the bar. With
    // it, a sustained genuine step up wins after some tens of strokes and a
    // burst does not last long enough to. It is the ONE path that still reads
    // `raw`, and it must: nothing was published, so there is no other number.
    //
    // A ZERO RAW IS NOT A READING. mRate is 0.0 when the stroke ring has timed
    // out or nothing has been measured, and folding that in would drag the
    // baseline toward a rate nobody rowed.
    static function nextRateBase(base, guarded, raw) {
        if (raw == null || raw <= 0.0) { return base; }
        if (guarded > 0.0) {
            if (base == null || base <= 0.0) { return guarded; }
            return base + $.LOCK_BASE_A_OK * (guarded - base);
        }
        // Nothing was published. Establishing here would let the first phantom
        // burst of a session set the bar it is then measured against, so a
        // zeroed reading may creep an EXISTING baseline and may not create one.
        if (base == null || base <= 0.0) { return base; }
        return base + $.LOCK_BASE_A_REJ * (raw - base);
    }

    // final cleaned rate for display and FIT: fast readings need the
    // autocorrelation lock to agree (kills phantom bursts from non-rowing
    // hand motion), and a locked reading that disagrees with the lock by
    // more than 30% snaps to it (kills residual half/double readings)
    hidden function outputRate() {
        return gatedRate(mRate, mAcPeriod, mRateBase);
    }

    // ---- the lock-state diagnostic encodings (#149) ----------------------
    // Three pure statics, one per field, so what each field CARRIES is a
    // reviewable decision with a name rather than an expression buried in a
    // setData argument -- and so the no-lock encodings can be pinned without a
    // Session, which no (:test) in this repository can obtain.

    // Pure: the LOCKED stroke rate in spm, or LOCK_RATE_NONE when no lock is
    // up. See the LOCK_RATE_NONE note at the top of this file for why 0.0 is
    // not an in-band value here: updateAutocorr searches only lags in
    // [60/MAX_RATE, 60/MIN_RATE], so a lock is a rate in [MIN_RATE, MAX_RATE].
    static function lockRateOf(acPeriod) {
        if (acPeriod == null || acPeriod <= 0.0) { return $.LOCK_RATE_NONE; }
        return 60.0 / acPeriod;
    }

    // Pure: the autocorrelation confidence -- the best lag's correlation as a
    // fraction of the window's energy -- or LOCK_CONF_NONE when the window
    // carries no energy and no confidence exists to report.
    //
    // The clamp at zero is defensive and not reachable from updateAutocorr
    // (`best` starts at 0.0 and only grows), and it is here so the field's
    // contract -- "a real confidence is never negative, so a negative value is
    // the sentinel" -- is a property of THIS function rather than of its one
    // caller.
    static function lockConf(best, e) {
        if (best == null || e == null || e <= 0.0) { return $.LOCK_CONF_NONE; }
        var c = best / e;
        return (c < 0.0) ? 0.0 : c;
    }

    // Pure: the consecutive low-confidence run, saturated for a UINT16 field.
    //
    // mAcLowConf is never reset except by a confident estimate, so it grows
    // without bound on a long unlocked row. SATURATING ONE BELOW 0xFFFF is the
    // point: 0xFFFF is the UINT16 "no data" pattern (the same fact RR_INVALID
    // records), so saturating onto it would turn the longest unlocked rows --
    // the ones this field exists to show -- into an apparent absence.
    static function lockLowClamp(n) {
        if (n == null || n < 0) { return 0; }
        if (n > $.LOCK_LOW_MAX) { return $.LOCK_LOW_MAX; }
        return n;
    }

    // ---- the gate-input diagnostic encodings (#149 part 2) ----------------
    // Two more pure statics, for the reasons the three above are static: so
    // what each field CARRIES is a named, reviewable decision rather than an
    // expression buried in a setData argument, and so it can be pinned without
    // a Session -- which no (:test) in this repository can obtain.
    //
    // BOTH ARE THE IDENTITY OVER THE WHOLE REACHABLE DOMAIN, and that is the
    // point rather than an oversight: the encoding decision recorded at
    // RATE_RAW_NONE is that 0.0 is the quantity's OWN no-data value and needs no
    // substitution. What these add is the normalisation of null and of a
    // negative neither quantity can hold today, so the field's contract -- "a
    // recorded value below MIN_RATE means there was no median / no baseline" --
    // is a property of THIS function instead of a property of the invariants of
    // its one caller. lockLowClamp carries a negative clamp it can never be
    // handed for exactly the same reason.
    //
    // The `<= 0.0` test is not a free choice for rateBaseOf: it is the SAME
    // predicate fastGate uses to decide "nothing established yet", so the set of
    // states recorded as RATE_BASE_NONE is exactly the set the gate treats as
    // having no baseline. That identity is what makes the field reproduce the
    // threshold the app actually used, and it is pinned as such
    // (Lock.test_lock_theRecordedInputsReproduceThePublishedRate) rather than
    // left to be inferred from the two functions sitting near each other.

    // Pure: the PRE-GATE median in spm, or RATE_RAW_NONE when the detector has
    // no median. See the RATE_RAW_NONE block at the top of this file.
    static function rateRawOf(rate) {
        if (rate == null || rate <= 0.0) { return $.RATE_RAW_NONE; }
        return rate;
    }

    // Pure: the established-rate baseline in spm, or RATE_BASE_NONE when none is
    // established. See the RATE_BASE_NONE block at the top of this file.
    static function rateBaseOf(base) {
        if (base == null || base <= 0.0) { return $.RATE_BASE_NONE; }
        return base;
    }

    // Advance the baseline. Called from recomputeRate() and nowhere else.
    //
    // Reads the guard's answer through the SHIPPING outputRate(), computed
    // against the OLD baseline, so what the output stage PUBLISHED for this
    // stroke -- not the median it may have corrected or discarded -- is what
    // moves the bar. nextRateBase owns that distinction; see its note.
    //
    // FROZEN WHILE PAUSED, AND FOR NPER STROKES AFTER THE RESUME. That is
    // #109's rule -- an athlete-state accumulator does not advance while the
    // athlete is not rowing -- applied to the one such accumulator this change
    // adds. registerStroke gates only the stroke COUNTER on !mPaused and calls
    // recomputeRate() unconditionally, on purpose (the numeral must not blank
    // for NPER strokes after every resume), so nothing else stops pause-time
    // motion from setting the guard's reference.
    //
    // WHY THE PAUSE FLAG ALONE IS NOT ENOUGH, and this is measured rather than
    // argued. mPeriods survives the pause too, so the first medians AFTER the
    // resume are still the pause's, and the baseline is an EMA: it takes them at
    // LOCK_BASE_A_OK (a quarter of the gap per stroke) and can only creep back
    // at LOCK_BASE_A_REJ (a fiftieth), because the guard never REJECTS a reading
    // for being too slow. Driven through the shipping
    // registerStroke/recomputeRate/outputRate path on fr965 (SDK 9.2.0), a 20
    // spm rower whose pause was gestured at 8 spm and who resumed at 24 spm with
    // no lock lost 15 strokes of row_stroke_rate and dist_per_stroke to 0.0 with
    // the pause flag alone -- three post-resume medians still reading 8.0 pulled
    // the baseline 20.0 -> 17.0 -> 14.75 -> 13.06, and 0.02-of-the-gap steps
    // needed twelve more strokes to reopen the gate. At a 26 spm resume it was
    // 24 strokes. Holding for NPER strokes -- the ring length that causes it --
    // makes both zero, and costs nothing: what the baseline holds during the
    // hold is the rate the athlete rowed BEFORE the pause, which is the right
    // reference for the interval about to start.
    //
    // Pinned end to end by test_lock_theBaselineFreezesWhileTheSessionIsPaused
    // (the freeze) and test_lock_theResumeIsNotGuardedByThePausesCadence (the
    // hold, over four row/pause/resume timelines, asserting the OUTCOME -- that
    // no stroke of the resumed piece comes out as 0.0 -- rather than this
    // mechanism, so a better implementation is free to replace it).
    //
    // The long-gap clear at the stroke-ring timeout is NOT affected: a quiet
    // pause still times the ring out and takes the baseline with it, which is
    // the intended "nothing established yet" degrade. A quiet pause also sets no
    // hold, because no stroke registers to set one.
    hidden function updateRateBase() {
        if (mPaused) { mBaseHold = NPER; return; }
        if (mBaseHold > 0) { mBaseHold--; return; }
        mRateBase = nextRateBase(mRateBase, outputRate(), mRate);
    }

    // ================= speed / distance helpers ============================
    hidden function currentSpeed() {
        var ai = Activity.getActivityInfo();
        if (ai != null && ai.currentSpeed != null) { return ai.currentSpeed; }
        return 0.0;
    }

    hidden function elapsedDist() {
        var ai = Activity.getActivityInfo();
        if (ai != null && ai.elapsedDistance != null) { return ai.elapsedDistance; }
        return 0.0;
    }

    hidden function distPerStroke(spd) {
        var r = outputRate();
        if (spd > 0.3 && r > 0.0) { return spd * 60.0 / r; }
        return 0.0;
    }

    // ================= erg: the power source ===============================

    // The machine's instantaneous power in watts, or NULL.
    //
    // NULL, and that is the one thing separating this reader from its three
    // neighbours. currentSpeed(), elapsedDist() and nativeCadence() all collapse
    // an absent reading to 0.0, which is safe for each of them because a zero
    // there is either harmless at the call site or out of band. It is NOT safe
    // here: zero watts is a LEGAL reading on an erg, so a 0.0 return would make
    // "no power meter" and "on the recovery" the same answer -- and the arc
    // would render the first of them RED.
    //
    // So the null is propagated all the way to the display and to the FIT
    // encoding, and every consumer has to decide what to do with it.
    hidden function currentPower() {
        var ai = Activity.getActivityInfo();
        if (ai != null && ai.currentPower != null) {
            return ai.currentPower.toFloat();
        }
        return null;
    }

    // The INSTRUMENTATION read: [power, speed, distance, cadence] from ONE
    // Activity.Info, WITH NULLS PRESERVED.
    //
    // A separate reader rather than four calls to the existing three, because
    // those three answer 0.0 for absent -- so a diagnostic built on them could
    // never distinguish "the machine broadcasts a speed of zero" from "the
    // machine broadcasts no speed at all", which is precisely the question the
    // first erg session has to settle.
    //
    // ONE Activity.Info for all four, so the four bits describe the same
    // instant. currentPower() above takes its own read, so the recorded power
    // VALUE and the recorded power BIT can in principle come from two reads a
    // few microseconds apart; at a 250 ms tick that is accepted and is stated
    // here rather than left to be discovered.
    hidden function ergSample() {
        var ai = Activity.getActivityInfo();
        if (ai == null) { return [null, null, null, null]; }
        return [ai.currentPower, ai.currentSpeed, ai.elapsedDistance,
                ai.currentCadence];
    }

    // the watch's own cadence, which counts every blade movement
    hidden function nativeCadence() {
        var ai = Activity.getActivityInfo();
        if (ai != null && ai.currentCadence != null) { return ai.currentCadence.toFloat(); }
        return 0.0;
    }

    // corrective-stroke rate: native blade movements minus our true drives.
    // Field testing showed the native counter registers steering taps and
    // boat-handling motion that the drive detector correctly ignores, so the
    // difference is a boat-handling workload measure (spm). Clamped at zero
    // because the native counter also lags to zero at lap boundaries.
    hidden function correctiveRate() {
        var c = nativeCadence() - outputRate();
        if (c < 0.0) { c = 0.0; }
        return c;
    }

    // ================= session / workout control ===========================
    hidden function startSession() {
        if (mSession == null) {
            try {
                mSession = Rec.createSession({
                    :name => "StrongRow",
                    :sport => Activity.SPORT_ROWING,
                    // ERG MODE labels the FIT correctly at its source. Read
                    // ONCE, here: reloadSettings refuses to run while mStarted
                    // (see its guard), so mErgMode cannot change under a live
                    // recording and the sub-sport declared at START is the one
                    // the whole row is recorded under.
                    //
                    // What a decoder or Garmin Connect RENDERS for
                    // SUB_SPORT_INDOOR_ROWING is not claimed here; that is a
                    // [Local] question.
                    :subSport => subSportFor(mErgMode)
                });
                // RECORD-SCOPE FIELDS LATCH -- this governs every
                // MESG_TYPE_RECORD field created below, mFitRr included.
                // Once setData has been called even once, a record committing
                // without a new setData RE-EMITS the last value; only records
                // BEFORE the first write carry the type's never-set invalid
                // pattern (#48 measured 0xFFFFFFFF exactly where a field had
                // NOT YET BEEN SET AS OF THAT RECORD -- REC 1 included, where
                // every field read invalid because that record committed
                // before the first setData). That is a byte-pattern fact;
                // what a decoder RENDERS for such a record is a [Local]
                // question, so do not upgrade it to "absence". Confirmed
                // byte-exact by #36 and reconfirmed by #48's probe_skip, in
                // the SIMULATOR on fr965 / SDK 9.2.0 -- treat hardware and
                // other SDKs as expected-same but unmeasured.
                //
                // Time base, as measured rather than assumed: record commits
                // track STAGED DATA, not a schedule this code controls.
                // #36's first run staged nothing during its skipped ticks and
                // got no record message at all for them (8 records / 14
                // ticks); it added a per-tick `beat` field IN THE PROBE as
                // the control that separates "no record committed" from "no
                // write staged". StrongRow's analogue is mFitRate/mFitDps,
                // staged on every 250 ms onTick WHILE STARTED AND UNPAUSED
                // (the mStarted && !mPaused gate) -- so under that gate a
                // record commits regardless of R-R state, which is how the
                // latch reaches the file here. The engine's own cadence is
                // NOT established: #36's ~1/s is its own probe's write rate
                // (#48 states no cadence at all), and #48's REC 1 committed
                // before any setData.
                //
                // Two hard rules from #48. Rule 1 is a prohibition and holds
                // for every field here whatever its type or scope; rule 2 is
                // a BYTE-PATTERN fact measured on RECORD-SCOPE FLOAT fields
                // only -- #48's probes were all record-scope, and what
                // setData does on a session-scope field is open (#76), which
                // matters because three MESG_TYPE_SESSION fields are created
                // below (avg_rmssd, total_corrective_strokes,
                // max_core_temperature):
                //   * NEVER call setData(null): it is an uncatchable native
                //     error that escapes try/catch and kills the app.
                //   * NaN is not an absence encoding for a record-scope
                //     FLOAT field: setData(NaN) lands as 0xFFC00000,
                //     distinct from never-set invalid 0xFFFFFFFF -- it reads
                //     as data, not absence, and can poison averages, min/max
                //     and any downstream aggregate that does not guard for
                //     it (#48; Connect's rendering is untested, tracked
                //     in #53).
                // #74: this pair had no inner try of its own, unlike all four
                // later groups. A throw from either reached only the outer
                // catch, whose whole body is `mSession = null` -- so it
                // DISCARDED a session that had already been created, rather
                // than nulling the handles that failed. Worse, a throw from the
                // SECOND create left mFitRate non-null and pointing into that
                // discarded session, and onTick then wrote into it at 4 Hz for
                // the entire row.
                try {
                    mFitRate = mSession.createField(
                        "row_stroke_rate", 0, Fit.DATA_TYPE_FLOAT,
                        { :mesgType => Fit.MESG_TYPE_RECORD, :units => "spm" });
                    mFitDps = mSession.createField(
                        "dist_per_stroke", 1, Fit.DATA_TYPE_FLOAT,
                        { :mesgType => Fit.MESG_TYPE_RECORD, :units => "m" });
                } catch (e) {
                    mFitRate = null;
                    mFitDps = null;
                }
                // explicit R-R / HRV logging, independent of the watch's
                // "Log HRV" device setting
                try {
                    // No :scale/:offset: RR_INVALID (0xFFFF) is emitted verbatim
                    // as the UINT16 "no data" sentinel (see handleRr / RR_INVALID).
                    mFitRr = mSession.createField(
                        "rr_interval", 2, Fit.DATA_TYPE_UINT16,
                        { :mesgType => Fit.MESG_TYPE_RECORD, :units => "ms", :count => $.RR_PER_REC });
                    mFitRmssd = mSession.createField(
                        "rmssd", 3, Fit.DATA_TYPE_FLOAT,
                        { :mesgType => Fit.MESG_TYPE_RECORD, :units => "ms" });
                    mFitAvgRmssd = mSession.createField(
                        "avg_rmssd", 4, Fit.DATA_TYPE_FLOAT,
                        { :mesgType => Fit.MESG_TYPE_SESSION, :units => "ms" });
                } catch (e) {
                    mFitRr = null;
                    mFitRmssd = null;
                    mFitAvgRmssd = null;
                }
                mRmssdSum = 0.0;
                mRmssdN = 0;
                // boat-handling workload: blade movements the drive detector
                // correctly ignores (steering taps, corrections)
                try {
                    mFitCorr = mSession.createField(
                        "corrective_rate", 5, Fit.DATA_TYPE_FLOAT,
                        { :mesgType => Fit.MESG_TYPE_RECORD, :units => "spm" });
                    mFitCorrTotal = mSession.createField(
                        "total_corrective_strokes", 6, Fit.DATA_TYPE_UINT16,
                        { :mesgType => Fit.MESG_TYPE_SESSION, :units => "strokes" });
                } catch (e) {
                    mFitCorr = null;
                    mFitCorrTotal = null;
                }
                // #149: the LOCK-STATE DIAGNOSTICS. Record scope, ids 20-22.
                //
                // ITS OWN try/catch, per #74 and for the reason every group
                // above gives for theirs: a throw here must not null handles
                // that were already created successfully.
                //
                // OUTSIDE the coreFieldsWanted gate, unlike ct_diag: these
                // describe the STROKE DETECTOR, which runs on every row, and a
                // podless row is not a row without a stroke rate.
                //
                // WHY THE IDS START AT 20 rather than at 12. Another branch is
                // in flight adding fields of its own, and a duplicate developer
                // field id is a SEMANTIC collision git cannot see: two branches
                // both taking 12 merge cleanly and produce one file in which
                // the id means two things. Every id currently in this file was
                // enumerated before choosing (0..11: row_stroke_rate,
                // dist_per_stroke, rr_interval, rmssd, avg_rmssd,
                // corrective_rate, total_corrective_strokes, core_temperature,
                // skin_temperature, max_core_temperature, ct_diag,
                // heat_strain_index), and 20 leaves the contiguous block free
                // for that branch.
                //
                // WHAT IS NOT MEASURED, and it is deliberately not claimed.
                // #77 measured eleven fields created and saved on fr965 /
                // SDK 9.2.0, found no cap below 256, and found that AT id 256
                // the SDK raises an uncatchable System Error that escapes this
                // try. #80 measured twelve. FIFTEEN fields, and a
                // NON-CONTIGUOUS id set, are beyond both -- so this is
                // EXPECTED to behave and has not been observed to. A [Local]
                // issue owns the simulator session and the decode; do not
                // upgrade the expectation in this comment without one.
                try {
                    mFitLockRate = mSession.createField(
                        "lock_rate", 20, Fit.DATA_TYPE_FLOAT,
                        { :mesgType => Fit.MESG_TYPE_RECORD, :units => "spm" });
                    mFitLockConf = mSession.createField(
                        "lock_confidence", 21, Fit.DATA_TYPE_FLOAT,
                        { :mesgType => Fit.MESG_TYPE_RECORD, :units => "a.u." });
                    // UINT16, not UINT8: the run is unbounded (see
                    // lockLowClamp) and a UINT8 would wrap inside an ordinary
                    // unlocked row. No :scale/:offset, so the saturating value
                    // reaches the file verbatim and stays below 0xFFFF.
                    mFitLockLow = mSession.createField(
                        "lock_lowconf_run", 22, Fit.DATA_TYPE_UINT16,
                        { :mesgType => Fit.MESG_TYPE_RECORD, :units => "n" });
                } catch (e) {
                    mFitLockRate = null;
                    mFitLockConf = null;
                    mFitLockLow = null;
                }
                // #149 part 2: the GATE-INPUT diagnostics. Record scope, ids
                // 23-24.
                //
                // ITS OWN try/catch, per #74 and for the reason every group
                // above gives for theirs: a throw here must not null handles
                // that were already created successfully -- and these two are
                // the newest, therefore the likeliest to fail, and the three
                // lock fields they sit beside are already shipped.
                //
                // OUTSIDE the coreFieldsWanted gate, for the same reason the
                // lock fields are: they describe the STROKE DETECTOR, which
                // runs on every row, and a podless row is not a row without a
                // stroke rate.
                //
                // WHY 23 AND 24. Every developer field id in this file was
                // enumerated before choosing: 0..11 (row_stroke_rate,
                // dist_per_stroke, rr_interval, rmssd, avg_rmssd,
                // corrective_rate, total_corrective_strokes, core_temperature,
                // skin_temperature, max_core_temperature, ct_diag,
                // heat_strain_index) and 20..22 (lock_rate, lock_confidence,
                // lock_lowconf_run). 23-24 continue the lock block's run
                // contiguously and leave 12..19 free, which is the reservation
                // the block above made for another branch in flight. A
                // duplicate id is a SEMANTIC collision git cannot see: two
                // branches both taking 23 merge cleanly and produce one file in
                // which the id means two things.
                //
                // No :scale/:offset on either, so what lockRateOf's siblings
                // hand setData is what the field carries.
                //
                // WHAT IS NOT MEASURED, and it is deliberately not claimed.
                // #77 measured eleven fields created and saved on fr965 /
                // SDK 9.2.0, found no cap below 256, and found that AT id 256
                // the SDK raises an uncatchable System Error that escapes this
                // try. #80 measured twelve. SEVENTEEN fields, and a
                // non-contiguous id set, are beyond both -- so this is EXPECTED
                // to behave and has not been observed to. No in-process test
                // can settle it: a (:test) cannot obtain a Session, so every
                // case in source/LockGuardTest.mc observes the ARGUMENT of a
                // setData call and nothing about a field_description message or
                // a record's bytes.
                //
                // #154 owns whether creation and save survive this count and
                // this id gap; #159 owns what the two VALUES decode to, and in
                // particular whether their deliberate 0.0 no-data encoding
                // reads back as the number 0 rather than as absence. Do not
                // upgrade the expectation in this comment without one of them.
                try {
                    mFitRateRaw = mSession.createField(
                        "rate_raw", 23, Fit.DATA_TYPE_FLOAT,
                        { :mesgType => Fit.MESG_TYPE_RECORD, :units => "spm" });
                    mFitRateBase = mSession.createField(
                        "rate_base", 24, Fit.DATA_TYPE_FLOAT,
                        { :mesgType => Fit.MESG_TYPE_RECORD, :units => "spm" });
                } catch (e) {
                    mFitRateRaw = null;
                    mFitRateBase = null;
                }
                // ---- THE STEP MARKS. Record scope, ids 17-18. Lap scope,
                // ids 25-26.
                //
                // ITS OWN try/catch, per #74 and for the reason every group
                // above gives for theirs: a throw here must not null handles
                // that were already created successfully.
                //
                // NOT GATED ON THE WORKOUT BEING ENABLED, unlike the erg and
                // CORE blocks. A free row records step_type = SFIT_NONE on
                // every record, and that is a value worth having rather than a
                // cost: a consumer holding a stack of files can then tell a
                // free row from a workout row FROM THE FILE, instead of
                // inferring it from the absence of a field.
                //
                // THE COST HAS TWO TERMS, AND THE MESSAGES ARE THE SMALL ONE.
                // An earlier revision of this paragraph said "the cost is two
                // field_description messages on a free row"; that is RETRACTED
                // twice over. It is FOUR descriptions, not two -- 17 and 18
                // here plus the lap copies 25 and 26 below, none of the four
                // gated -- and the messages are not the term that dominates.
                // The LARGE term is the per-record pair itself, UINT8 + UINT16
                // = 3 bytes on EVERY record, which on a 68-minute 1 Hz row is
                // 4080 * 3 = about 12 KiB. Four field_descriptions are a few
                // hundred bytes at most (scripts/fit_step_marks.py's own
                // encoder lays each out in 34 bytes; the device's encoder
                // chooses its own string sizes and has NOT been measured), so
                // the ratio is roughly two orders of magnitude. The 12 KiB is
                // what the sentence above buys: absence gets an encoding on
                // every record instead of a silence.
                //
                // BOTH COUNTS ARE DERIVED, NOT TRANSCRIBED.
                // scripts/check_step_fields.py counts the createField calls in
                // this block and adds up their declared FIT types, and fails if
                // the marked line disagrees with the code:
                //
                //   STEPFIELDS descs=4 rec_bytes=3 lap_bytes=3 total_fields=26
                //
                // It also fails if this block is ever moved inside a
                // workout-enabled or erg-mode branch. That matters more than it
                // looks: no (:test) can obtain a Session, so gating CREATION is
                // the one edit here that nothing in the suite could see.
                //
                // WHY 17 AND 18, and why the lap copies are NOT 19 and 20.
                // Every developer field id in this file was enumerated before
                // choosing: 0..11 (row_stroke_rate, dist_per_stroke,
                // rr_interval, rmssd, avg_rmssd, corrective_rate,
                // total_corrective_strokes, core_temperature, skin_temperature,
                // max_core_temperature, ct_diag, heat_strain_index), 12..16
                // (erg_power, erg_joules_per_stroke, erg_diag, erg_work_total,
                // erg_cadence) and 20..24 (lock_rate, lock_confidence,
                // lock_lowconf_run, rate_raw, rate_base). 17..19 were the free
                // run and the record pair takes the first two of it.
                //
                // A DEVELOPER FIELD ID IS UNIQUE PER FIELD_DESCRIPTION, so the
                // lap-scope copies cannot reuse 17 and 18 -- they need ids of
                // their own, and one free id (19) is not two. They take 25-26,
                // the next contiguous pair above the lock block's 24, which
                // keeps them adjacent to each other and leaves 19 free.
                //
                // MESG_TYPE_LAP IS AVAILABLE AND THAT WAS CHECKED, NOT ASSUMED.
                // Compiled for fr965 and fenix6 under SDK 9.2.0, and its value
                // read at runtime in the simulator: Fit.MESG_TYPE_LAP == 19,
                // against MESG_TYPE_RECORD == 20 and MESG_TYPE_SESSION == 18 --
                // which are the FIT global message numbers for lap, record and
                // session, so the symbol means what its name says. What is NOT
                // established by that: whether createField ACCEPTS lap scope at
                // runtime, and whether a lap message in a saved file carries
                // the value. Both are [Local] questions and the issue filed
                // with this change owns them; if the answer is no, the catch
                // below nulls the two handles and the record-scope pair -- the
                // more robust half anyway -- is unaffected.
                //
                // WHAT IS NOT MEASURED, and it is deliberately not claimed.
                // #77 measured eleven developer fields created and saved on
                // fr965 / SDK 9.2.0 and found no cap below 256; #80 measured
                // twelve. TWENTY-SIX fields, with a non-contiguous id set, is
                // beyond both -- so this is EXPECTED to behave and has not been
                // observed to. #154 owns the field-count question.
                try {
                    mFitStepType = mSession.createField(
                        "step_type", 17, Fit.DATA_TYPE_UINT8,
                        { :mesgType => Fit.MESG_TYPE_RECORD, :units => "n" });
                    mFitIvlNum = mSession.createField(
                        "interval_num", 18, Fit.DATA_TYPE_UINT16,
                        { :mesgType => Fit.MESG_TYPE_RECORD, :units => "n" });
                } catch (e) {
                    mFitStepType = null;
                    mFitIvlNum   = null;
                }
                // A SECOND try, not the same one. The record pair is the half
                // the acceptance criterion rests on and the half whose scope is
                // already proven in this file; the lap pair uses a message type
                // this app has never written. A throw from the lap createField
                // must not take the record handles down with it.
                try {
                    mFitLapStep = mSession.createField(
                        "lap_step_type", 25, Fit.DATA_TYPE_UINT8,
                        { :mesgType => Fit.MESG_TYPE_LAP, :units => "n" });
                    mFitLapIvl = mSession.createField(
                        "lap_interval_num", 26, Fit.DATA_TYPE_UINT16,
                        { :mesgType => Fit.MESG_TYPE_LAP, :units => "n" });
                } catch (e) {
                    mFitLapStep = null;
                    mFitLapIvl  = null;
                }
                // ---- ERG MODE's fields. Record scope, ids 12-14 and 16;
                // session scope, id 15.
                //
                // ITS OWN try/catch, per #74 and for the reason every group
                // above gives for theirs: a throw here must not null handles
                // that were already created successfully -- and these five are
                // the newest, therefore the likeliest to fail, and everything
                // they sit beside is already shipped.
                //
                // WHY 12-16. Every developer field id in this file was
                // enumerated before choosing: 0..11 (row_stroke_rate,
                // dist_per_stroke, rr_interval, rmssd, avg_rmssd,
                // corrective_rate, total_corrective_strokes, core_temperature,
                // skin_temperature, max_core_temperature, ct_diag,
                // heat_strain_index) and 20..24 (lock_rate, lock_confidence,
                // lock_lowconf_run, rate_raw, rate_base). 12..19 were free, and
                // the #149 block above says in as many words that it started at
                // 20 to leave that contiguous run "free for that branch". THIS
                // IS THAT BRANCH. 17..19 stay free.
                //
                // GATED ON ERG MODE, unlike the lock fields and like the CORE
                // block. #166's first acceptance criterion is that with erg
                // mode off -- the default -- every FIT value is what it is
                // today, and five extra field_description messages on every
                // water row is not that. The cost is a real one and is stated
                // rather than hidden: a WATER row records no control sample, so
                // "currentPower is null off an erg" is not measured by this
                // change. Nothing rests on it being measured.
                //
                // WHAT IS NOT MEASURED, and it is deliberately not claimed.
                // #77 measured eleven fields created and saved on fr965 /
                // SDK 9.2.0, found no cap below 256, and found that AT id 256
                // the SDK raises an uncatchable System Error that escapes this
                // try. #80 measured twelve. TWENTY-TWO fields, and a
                // non-contiguous id set, are beyond both -- so this is EXPECTED
                // to behave and has not been observed to. No in-process test
                // can settle it: a (:test) cannot obtain a Session, so every
                // case in source/ErgUnitsTest.mc observes the ARGUMENT of a
                // setData call and nothing about a field_description message or
                // a record's bytes. #154 owns the field-count question; the
                // [Local] erg session owns what these five decode to.
                //
                // erg_cadence is the twenty-second and it was added in review,
                // knowingly against that unmeasured ceiling: without the VALUE
                // the maintainer's third question -- does cadence come from
                // the machine or from the wrist -- cannot be answered from one
                // session at all, because the diag BITS read the same either
                // way. One more field against an untested count, or a second
                // trip; #168 carries the risk either way.
                //
                // No :scale/:offset on any of them, so what the encoders hand
                // setData is what the field carries -- which the sentinels and
                // the ERGD_MAX argument both depend on.
                if (mErgMode) {
                    try {
                        mFitErgPower = mSession.createField(
                            "erg_power", 12, Fit.DATA_TYPE_FLOAT,
                            { :mesgType => Fit.MESG_TYPE_RECORD, :units => "W" });
                        mFitErgJps = mSession.createField(
                            "erg_joules_per_stroke", 13, Fit.DATA_TYPE_FLOAT,
                            { :mesgType => Fit.MESG_TYPE_RECORD, :units => "J" });
                        // UINT16 and no :scale/:offset, so the bitmask reaches
                        // the file verbatim -- the ERGD_ALIVE / reserved-band
                        // argument that a written word is never 0x0000 and
                        // never 0xFFFF is about the value this call carries.
                        mFitErgDiag = mSession.createField(
                            "erg_diag", 14, Fit.DATA_TYPE_UINT16,
                            { :mesgType => Fit.MESG_TYPE_RECORD, :units => "n" });
                        mFitErgWork = mSession.createField(
                            "erg_work_total", 15, Fit.DATA_TYPE_FLOAT,
                            { :mesgType => Fit.MESG_TYPE_SESSION, :units => "kJ" });
                        // THE FIELD THAT ANSWERS THE CADENCE SOURCE QUESTION.
                        // erg_diag's CAD bits cannot: the wrist populates
                        // ai.currentCadence with no machine present, so a set
                        // bit is the expected reading either way. Only the
                        // VALUE can be differenced against row_stroke_rate --
                        // and corrective_rate cannot serve, because it clamps
                        // that difference at zero. Id 16, the first of the four
                        // still free (16-19).
                        mFitErgCad = mSession.createField(
                            "erg_cadence", 16, Fit.DATA_TYPE_FLOAT,
                            { :mesgType => Fit.MESG_TYPE_RECORD, :units => "spm" });
                    } catch (e) {
                        mFitErgPower = null;
                        mFitErgJps   = null;
                        mFitErgDiag  = null;
                        mFitErgWork  = null;
                        mFitErgCad   = null;
                    }
                }
                mCorrAccum = 0.0;
                // ERG: the SESSION work accumulator, reset here with mCorrAccum
                // and for the identical reason -- startSession is where the
                // session-scope FIT field this feeds comes into existence, so
                // its lifetime and the accumulator's are the same lifetime.
                //
                // NOT because beginSessionAccum() misses a path: it does not.
                // An earlier revision of this comment said "the free-row path
                // ... never reaches beginSessionAccum()", which is false --
                // onPrimary's free-row arm calls it, and so does initialize().
                // See the member declaration for the corrected reasoning.
                //
                // The COUNT is reset with the value, or a second row with no
                // power source would inherit the first row's claim.
                mErgSessJ = 0.0;
                mErgSessN = 0;
                // Per-session accumulator, reset with the others above. It used
                // to be reset INSIDE the CORE block below, which made its
                // correctness depend on whether fields were created.
                mMaxCore = 0.0;
                // #13, reset HERE with mMaxCore and for the same reason: the
                // "has this field ever been written" flags describe THIS
                // session's record fields, and startSession is where those
                // fields come into existence. Resetting them inside the
                // coreFieldsWanted block below would make their correctness
                // depend on whether the createFields succeeded -- the exact
                // coupling the mMaxCore line above was moved out to avoid.
                mCoreEver = false;
                mSkinEver = false;
                // Core temperature (#75). These fields are declared WITHOUT
                // asking whether a pod has been heard yet. The previous gate
                // (`... && mCoreSensor.everSeen()`) was evaluated exactly once,
                // here: startSession()'s body is guarded by `mSession == null`,
                // its only callers are onPrimary/startWorkout, and togglePause
                // resumes with mSession.start() without re-entering it. So a
                // pod acquired one second after START had no field to write to
                // for the rest of the row, and nothing re-checked. The ANT
                // search starts at onLayout, but searchTimeoutLowPriority gives
                // ~30 s per attempt with the period alternating between
                // attempts, so pressing START before the first valid broadcast
                // is the ordinary case, not an edge case.
                //
                // CORRECTION (#13), kept in place rather than edited away
                // because the sentence it replaces was the pointer a reader
                // would have followed. This paragraph used to read:
                //
                //     "a row with no pod now declares these three fields and
                //      writes core/skin every tick ... so such a row logs 0.0
                //      rather than leaving the fields unwritten. That is #13's
                //      territory ...; do not pre-empt it here."
                //
                // That accepted cost is no longer paid, and the second half is
                // now FALSE. #13 landed: onTick withholds the write until the
                // first current reading of the session, so a row with no pod
                // declares these fields and writes NOTHING to core/skin at all.
                // What such a row's records carry instead is the FLOAT
                // never-set pattern -- expected-same and unmeasured for these
                // two fields, which is #150's [Local] decode to settle.
                //
                // The clause that survives unchanged, because the whole design
                // rests on it: 0.0 cannot collide with a real reading -- the
                // 25-45 C / 15-45 C clamps in CoreTempSensor put it outside the
                // accepted band by construction, swept and pinned by
                // CoreDrop.test_ctw_c0_noAcceptedCoreIsZeroOrBelow and its skin
                // twin. That is what lets 0.0 serve as the dropout marker AFTER
                // a real reading has been written. See ctTempWritable.
                //
                // CONSEQUENCE FOR stopAndSave, do not "simplify" it away: with
                // these fields now created on every row, `mFitMaxCore != null`
                // there is always true, so `mMaxCore > 0.0` is the SOLE
                // remaining guard against writing a bogus 0 C
                // max_core_temperature on a podless row. It is not redundant.
                //
                // The inner try/catch below stays this block's own: merging it
                // with an earlier group's would let a throw here null handles
                // that were already created successfully. It is now reachable
                // on every row rather than only rows with a pod (whether a
                // createField throw is reachable at all is #76).
                if (coreFieldsWanted(mCoreSensor)) {
                    try {
                        mFitCore = mSession.createField(
                            "core_temperature", 7, Fit.DATA_TYPE_FLOAT,
                            { :mesgType => Fit.MESG_TYPE_RECORD, :units => "C" });
                        mFitSkin = mSession.createField(
                            "skin_temperature", 8, Fit.DATA_TYPE_FLOAT,
                            { :mesgType => Fit.MESG_TYPE_RECORD, :units => "C" });
                        mFitMaxCore = mSession.createField(
                            "max_core_temperature", 9, Fit.DATA_TYPE_FLOAT,
                            { :mesgType => Fit.MESG_TYPE_SESSION, :units => "C" });
                    } catch (e) {
                        mFitCore = null;
                        mFitSkin = null;
                        mFitMaxCore = null;
                    }
                    // #102: the ANT diagnostic counters, in their OWN
                    // try/catch. Per #74 a shared try lets one throw null
                    // another group's already-created handles -- which is
                    // exactly the argument the block above makes for itself,
                    // and it applies with more force here: if the three CORE
                    // creates throw, the diagnostics explaining why are the one
                    // thing that must survive.
                    //
                    // ONE array field rather than ~20 scalars. Ids 0-9 are
                    // taken and #77 is open on whether the SDK caps fields per
                    // session, so this costs one more id and one more
                    // field_description instead of twenty, while every slot
                    // stays an ordinary readable integer -- see the CT_DIAG_*
                    // block in CoreTempSensor.mc for the slot key.
                    //
                    // Inside the coreFieldsWanted gate on purpose: the field
                    // has nothing to report without a sensor to read, and it
                    // keeps `mFitCtDiag != null => mCoreSensor != null` true
                    // for the write in stopAndSave.
                    //
                    // No :scale/:offset -- the slots are raw counts, and a
                    // session-scope UINT16 array field was measured landing in
                    // the file verbatim (SIMULATOR, fr965 / SDK 9.2.0; treat
                    // hardware and other SDKs as expected-same but unmeasured).
                    //
                    // :count MUST stay $.CT_DIAG_SLOTS, the same constant
                    // diagSnapshot() sizes its array from -- never a literal.
                    // MEASURED: a setData array longer than :count raises an
                    // UNCATCHABLE "System Error: setData input array too long
                    // for allocated space" that escapes try/catch and kills the
                    // app at save time, losing the whole activity. See the
                    // fuller note on diagSnapshot in CoreTempSensor.mc.
                    try {
                        mFitCtDiag = mSession.createField(
                            "ct_diag", 10, Fit.DATA_TYPE_UINT16,
                            { :mesgType => Fit.MESG_TYPE_SESSION, :units => "n",
                              :count => $.CT_DIAG_SLOTS });
                    } catch (e) {
                        mFitCtDiag = null;
                    }
                    // #80: the heat strain index, record scope, developer field
                    // id 11.
                    //
                    // ITS OWN try/catch, per #74 and for the reason the two
                    // groups above give for theirs: a throw here must not null
                    // handles that were already created. This one is the newest
                    // and therefore the likeliest to fail, and the three CORE
                    // temperature fields it sits behind are already shipped.
                    //
                    // Name, units and type match the vendor's own FIT guidance
                    // for this quantity (record scope, "a.u.", float, no native
                    // field number -- so a developer field is the only option).
                    //
                    // Id 11 because 0-10 are taken and ct_diag holds 10. #77
                    // measured eleven fields (ids 0-9 plus ct_diag) created and
                    // saved in one session on fr965 / SDK 9.2.0, found no cap
                    // below 256, and found that AT id 256 the SDK raises an
                    // uncatchable System Error that escapes this try and aborts
                    // the VM.
                    //
                    // Twelve fields is one more than #77 measured, so it was
                    // MEASURED for this change rather than extrapolated
                    // (SIMULATOR, fr965 / SDK 9.2.0; hardware unmeasured). A
                    // session declaring exactly these twelve ids created every
                    // one of them, wrote record- and session-scope values, and
                    // saved without throwing; the resulting file decodes with
                    // all twelve field_description messages present, this one
                    // as id 11, name "heat_strain_index", units "a.u.",
                    // fit_base_type float32.
                    //
                    // NO SESSION-SCOPE COMPANION. A max or mean heat strain is
                    // worth having and is deliberately not in this change: it
                    // needs an explicit seen-flag guard (never `> 0.0`, which
                    // would suppress the field for any row whose true maximum
                    // strain was zero and leave a reader unable to tell
                    // suppression from absence), and #11's double-onLayout
                    // hazard rules out any time-integrated form until that
                    // lands. Filed rather than folded in.
                    try {
                        mFitHsi = mSession.createField(
                            "heat_strain_index", 11, Fit.DATA_TYPE_FLOAT,
                            { :mesgType => Fit.MESG_TYPE_RECORD, :units => "a.u." });
                    } catch (e) {
                        mFitHsi = null;
                    }
                }
            } catch (e) {
                mSession = null;
            }
        }
        // #74: returns TRUE only if a session exists AND start() returned
        // normally. Both callers set mStarted from this instead of setting it
        // unconditionally, which is what turned every throw above into a row
        // that looked like it was recording and produced no FIT file.
        //
        // Guarding start() also closes a path the issue does not enumerate: it
        // used to sit outside the outer try, so a throw propagated out of
        // startSession into onPrimary. mStarted was never set -- but mSession
        // stayed NON-null, so every later START press found `mSession == null`
        // false, skipped the whole creation block, fell through to this line
        // and threw again. The app became permanently unstartable.
        //
        // Caught rather than nulling mSession, deliberately: if start() DID
        // take effect before throwing, nulling the handle would strand a live
        // recording that stopAndSave() could no longer reach. Leaving it lets
        // the next START press retry start() on the same session.
        //
        // ASK THE SESSION, do not infer from the throw. A throw that arrives
        // AFTER start() took effect would otherwise report failure over a LIVE
        // recording, and that is not a cosmetic lie: onTick gates every
        // FitContributor write on mStarted, so the row would save with none of
        // this app's fields in it -- the exact inverse of #74 and, for a
        // training app, just as useless. isRecording() is the same handle
        // stopAndSave already trusts to decide whether to call stop().
        if (mSession == null) { return false; }
        try {
            mSession.start();
        } catch (e) {
            return sessionLive();
        }
        return true;
    }

    // The class-scope STEP_* ordinal of the step in force, or -1 when there is
    // none -- free-row mode, or a workout that has not been started.
    //
    // ONE reader for a condition that had two copies. onUpdate computed
    // `(mWorkoutEnabled && mStarted) ? mSteps[mStepIdx] : null` inline, and the
    // step marks need the identical question at a different call site; two
    // copies of it would be two places for a future edit to disagree about what
    // "no step" means -- and here that disagreement would land IN THE FILE,
    // where a decoder cannot see that it happened.
    hidden function curStepType() {
        if (!mWorkoutEnabled || !mStarted) { return -1; }
        return mSteps[mStepIdx][:type];
    }

    hidden function stepRemaining() {
        var st = mSteps[mStepIdx];
        if (!st.hasKey(:dur)) { return 0.0; }
        var el = (System.getTimer() - mStepStartMs) / 1000.0;
        var r = st[:dur] - el;
        return (r < 0.0) ? 0.0 : r;
    }

    hidden function stepElapsed() {
        return (System.getTimer() - mStepStartMs) / 1000.0;
    }

    function onPrimary() {
        if (!mWorkoutEnabled) {
            if (!mStarted) {
                // #74: observe the outcome. A failed start leaves mStarted
                // false and raises mRecFailed, so the footer says NOT RECORDING
                // rather than REC. Pressing START again retries.
                mStarted = startSession();
                mRecFailed = !mStarted;
                if (!mStarted) { return; }
                mPaused = false;
                mStartMs = System.getTimer();
                beginSessionAccum();
                // FREE ROW's one lap gets a mark too, and it is SFIT_NONE by
                // construction (mWorkoutEnabled is false here). A file whose
                // laps all read "no workout step" is a free row, stated in the
                // file rather than inferred from a missing field.
                markLap();
                alert(STEP_WORK);
            } else {
                togglePause();
            }
            return;
        }
        if (!mStarted) {
            startWorkout();
            return;
        }
        var st = mSteps[mStepIdx];
        var t = st[:type];
        if (t == STEP_GATE || t == STEP_WARM || t == STEP_COOL) {
            advanceStep();
        } else if (t == STEP_DONE) {
            return;
        } else {
            togglePause();
        }
    }

    hidden function startWorkout() {
        // #74: same contract as the free-row path in onPrimary. The workout is
        // NOT advanced when recording failed -- returning before mStepIdx = 0
        // keeps the step machine where it was, so a retry starts the workout
        // from the top rather than from a half-entered state.
        mStarted = startSession();
        mRecFailed = !mStarted;
        if (!mStarted) { return; }
        mPaused = false;
        mStepIdx = 0;
        mStartMs = System.getTimer();
        mStepStartMs = mStartMs;
        beginSessionAccum();
        // See beginWorkAccum: with warmupCooldown off, mSteps[0] IS a work
        // interval and never passes through advanceStep.
        var s0 = mSteps[0];
        if (s0[:type] == STEP_WORK) { beginWorkAccum(s0[:idx]); }
        // The session's FIRST lap is opened by createSession, not by addLap, so
        // it gets its mark here -- after beginWorkAccum, which is what sets
        // mSetNum when mSteps[0] is a work interval (warmupCooldown off).
        // Without this the first lap would carry whatever a lap-scope field
        // reads before any write, which is precisely the "absence or a stale
        // value" ambiguity these fields exist to remove.
        markLap();
        alert(mSteps[0][:type]);
    }

    hidden function advanceStep() {
        // #109: latch BEFORE the index moves, while mSteps[mStepIdx] still
        // names the step that is ending.
        var out = mSteps[mStepIdx];
        if (out[:type] == STEP_WORK) { latchWorkAccum(); }
        mStepIdx++;
        var st = mSteps[mStepIdx];
        var t = st[:type];
        // WHICH STEPS OPEN A LAP is unchanged -- WORK, REST and COOL -- and
        // the flag exists only so the step marks can be written at the same
        // three moments without a second copy of the condition.
        var opened = (t == STEP_WORK || t == STEP_REST || t == STEP_COOL);
        if (opened) {
            if (mSession != null) { try { mSession.addLap(); } catch (e) {} }
            mStepStartMs = System.getTimer();
        }
        if (t == STEP_WORK) { beginWorkAccum(st[:idx]); }
        // AFTER beginWorkAccum, because that is what sets mSetNum, and AFTER
        // addLap, because addLap CLOSES the outgoing lap -- so this writes into
        // the lap that has just been opened rather than into the one that just
        // ended.
        if (opened) { markLap(); }
        alert(t);
    }

    // Stamp the lap now in progress with the step that OPENED it.
    //
    // LAP SCOPE IS THE CONVENIENCE HALF, and its limits are stated here rather
    // than discovered later. A lap is labelled by the step it STARTED in, and
    // the app opens a lap only for WORK, REST and COOL -- so:
    //
    //   * A GATE NEVER OPENS A LAP, and buildWorkout adds one on
    //     pressToContinue ALONE -- `if (mGate)`, independent of mRestSec. So on
    //     the SHIPPED DEFAULTS (restMinutes 2, pressToContinue on) the sequence
    //     is WORK/REST/GATE/WORK, and the gate's seconds fall inside the
    //     PRECEDING REST lap, which still reads SFIT_REST. Lap-derived REST
    //     durations are therefore inflated by the gate dwell, and that dwell is
    //     UNBOUNDED -- a gate ends only on a user press (see stepRemaining).
    //     Work laps are clean in this configuration, so the work-seconds
    //     criterion is unaffected; what a lap-level consumer must not do is
    //     read the recovery duration off the REST lap alone;
    //   * with pressToContinue OFF and restMinutes > 0 every step gets its own
    //     lap and the label is exact. THAT, and not restMinutes alone, is the
    //     condition for exactness. An earlier revision of this note said "with
    //     restMinutes > 0 every step gets its own lap and the label is exact",
    //     which is false on the shipped defaults, and it is RETRACTED;
    //   * with restMinutes = 0 the sequence is WORK/GATE/WORK, no lap is opened
    //     for the gate, and the gate's seconds fall inside the PRECEDING WORK
    //     lap. That lap reads SFIT_WORK, which is what it started as and not
    //     what all of it was;
    //   * STEP_DONE likewise falls inside the cool-down lap (or the last work
    //     lap when there is no cool-down).
    //
    // The default-configuration row is PINNED rather than merely stated:
    // StepMark.test_sm_c2_theLapMarkNamesTheStepThatOpenedTheLap drives the
    // shipped defaults through the real advanceStep, states mRestSec > 0 and
    // mGate ON as an asserted premise, and requires the lap count NOT to move
    // across the gate. Nesting the gate arm under `mRestSec <= 0` -- the shape
    // the retracted bullet described -- reds it and four others.
    //
    // That is exactly why the RECORD-scope pair is the primary one and the one
    // the acceptance criterion is written against: per-record marks do not
    // depend on lap boundaries aligning with steps, and here they demonstrably
    // do not always align. A consumer wanting the work seconds should select on
    // step_type per record; a consumer wanting a quick lap-level cut can read
    // the lap field and accept the gate seconds inside it.
    //
    // Handles are null when creation failed or lap scope was refused, so this
    // is a no-op on those devices rather than a throw.
    hidden function markLap() {
        var t = curStepType();
        if (mFitLapStep != null) {
            mFitLapStep.setData(stepTypeCode(t, mWorkoutEnabled, mStarted));
        }
        if (mFitLapIvl != null) {
            mFitLapIvl.setData(intervalNumOf(mWorkoutEnabled, mStarted, mSetNum));
        }
    }

    // ---- #109 accumulator lifecycle --------------------------------------

    // A new RECORDING begins. Clears the session-scoped stroke count (#126) and
    // discards any latched interval from a previous row.
    hidden function beginSessionAccum() {
        mStrokeCount   = 0;
        // #125: cleared WITH the session total, never separately. Two stroke
        // counters that reset on different events would let the footer report a
        // work count from the previous row against this row's session.
        mWorkStrokes   = 0;
        mSetNum        = 0;
        mSetDistBase   = 0.0;
        mSetPausedDist = 0.0;
        mPauseDistAt   = 0.0;
        mSetStrokeBase = 0;
        mSetHrSum      = 0;
        mSetHrN        = 0;
        mLastSetValid  = false;
        mLastSetNum    = 0;
        mLastSetSec    = 0.0;
        mLastSetDist   = 0.0;
        mLastSetStrokes = 0;
        mLastSetHrSum  = 0;
        mLastSetHrN    = 0;
        // ERG: both the live interval accumulator and its latch. The COUNTS are
        // what actually clear the previous row's claim -- a stale
        // mLastSetWorkN over a fresh zero would render 0.0 kJ for an interval
        // that has not happened yet.
        mErgWorkJ     = 0.0;
        mErgWorkN     = 0;
        mLastSetWorkJ = 0.0;
        mLastSetWorkN = 0;
    }

    // A WORK interval begins.
    //
    // MUST be called from BOTH startWorkout and advanceStep, and that is not
    // defensive symmetry -- it is a real bug otherwise. With warmupCooldown
    // false, buildWorkout makes mSteps[0] a STEP_WORK, so interval 1 is entered
    // directly by startWorkout and never passes through advanceStep at all.
    // Wiring only advanceStep would leave set 1 accumulating against an
    // uninitialised baseline.
    hidden function beginWorkAccum(num) {
        mSetNum        = num;
        mSetDistBase   = elapsedDist();
        mSetPausedDist = 0.0;
        mSetStrokeBase = mStrokeCount;
        mSetHrSum      = 0;
        mSetHrN        = 0;
        // ERG: the interval's work restarts here, WITH its sample count. An
        // accumulator reset without its count would carry the previous
        // interval's "a measurement was taken" into one where none was -- and,
        // since the count is also the coverage numerator, would credit this
        // interval with the previous one's samples.
        mErgWorkJ = 0.0;
        mErgWorkN = 0;
    }

    // A WORK interval ends: freeze its raw totals.
    //
    // Called from the TOP of advanceStep, before mStepIdx++, while
    // mSteps[mStepIdx] still names the outgoing step.
    hidden function latchWorkAccum() {
        if (mSetNum <= 0) { return; }
        var dist = elapsedDist() - mSetDistBase - mSetPausedDist;
        if (dist < 0.0) { dist = 0.0; }
        mLastSetNum     = mSetNum;
        // ONE CLOCK, and it is the pause-corrected one. An earlier revision
        // stamped its own mSetStartMs from System.getTimer() and latched a raw
        // wall-clock delta -- while the distance was pause-corrected and the HR
        // was gated on !mPaused. Seconds was then the only total carrying
        // paused time, so a 60 s pause in a 4-minute set latched 300 s and
        // avg spm read 12.6 where the athlete rowed 15.75. A 20% under-report
        // on glance priority 1, rendered as a value rather than a dash.
        //
        // stepElapsed() reads mStepStartMs, which togglePause already credits
        // the paused span to (#74). latchWorkAccum runs at the top of
        // advanceStep while mStepIdx still names the outgoing WORK, and
        // mStepStartMs is stamped at every WORK entry, so this IS the
        // interval's unpaused duration with no second clock to keep in sync.
        mLastSetSec     = stepElapsed();
        mLastSetDist    = dist;
        // MINUS-ONE-STROKE BIAS, stated rather than left to be rediscovered as
        // a defect. registerStroke only counts a stroke whose period falls in
        // the valid window, so the FIRST stroke after every rest gap is
        // rejected -- a 4-minute set at 16 spm latches 63, not 64. That is
        // ~1.6% high on m/stroke and 0.25 spm low on the rate. ACCEPTED here
        // rather than corrected, because a +1 fudge would be wrong for an
        // interval entered mid-stroke and there is no way to tell the two
        // apart from the count alone.
        mLastSetStrokes = mStrokeCount - mSetStrokeBase;
        mLastSetHrSum   = mSetHrSum;
        mLastSetHrN     = mSetHrN;
        // ERG: the interval's work, frozen with EVERYTHING ELSE and as a PAIR.
        // Latching the joules without the count would make "no power meter" and
        // "no work done" the same latched state, which is exactly the
        // distinction the pair exists to carry -- and it would leave the
        // coverage unknowable, because mLastSetSec alone cannot say how much of
        // the interval carried a sample.
        mLastSetWorkJ = mErgWorkJ;
        mLastSetWorkN = mErgWorkN;
        mLastSetValid   = true;
        mSetNum         = 0;
    }

    // ---- #74 pause / resume ----------------------------------------------

    // #74: these are the SAME two SDK calls on the SAME handle that
    // startSession guards, and they were left bare here. Leaving them bare
    // would have had the file making two contradictory claims about whether
    // ActivityRecording.start() can throw -- defended in one place, unprotected
    // eighty lines away.
    //
    // And here the consequence is worse than the bug #74 is about. There is no
    // try/catch anywhere in the frames above this one -- togglePause is reached
    // from onPrimary, which is called from StrongRowDelegate.onSelect -- so a
    // throw terminates the app, and stopAndSave() is the ONLY caller of
    // mSession.save(). #74 loses a row that never started; an unguarded throw
    // here loses a REAL row, mid-piece, with every field already recorded.
    //
    // Swallowed rather than surfaced: a throw here must not cost the row.
    //
    // BUT mPaused IS DERIVED FROM THE RECORDER, NOT FROM THE BUTTON, and that
    // distinction is the whole of #74. An earlier revision of this function
    // swallowed the throw and then set mPaused from the keypress anyway,
    // justifying it as "the view stays consistent with what the athlete
    // pressed". That re-created this issue's exact lie in a new place: a resume
    // that threw left mStarted true, mPaused false and mRecFailed false, which
    // footState reads as FOOT_REC -- a red REC row over a session that is not
    // recording, and onTick writing into it for the rest of the piece.
    //
    // The failed STOP direction is just as bad and less obvious: a stop that
    // did not take leaves the session emitting records while onTick's
    // `!mPaused` gate gives up writing, and record-scope fields LATCH, so every
    // record for the rest of the stall re-emits the last live value. Stale data
    // that decodes as real is worse than a gap.
    //
    // So both branches ask isRecording() and set the flags from the answer.
    hidden function togglePause() {
        var now = System.getTimer();
        if (mPaused) {
            if (mSession != null) {
                try { mSession.start(); } catch (e) {}
            }
            // #109/#127: charge any distance that accrued while paused to
            // mSetPausedDist so latchWorkAccum can subtract it.
            //
            // CORRECT WHETHER OR NOT elapsedDistance FREEZES while the session
            // is stopped, which is what #127 exists to measure. If it freezes,
            // this delta is zero and the correction is a no-op. If it does not,
            // this is exactly the drift that would otherwise inflate the
            // interval's distance and its metres-per-stroke -- in the
            // flattering direction, which is the direction least likely to be
            // questioned. Cheap enough that waiting for the measurement to
            // decide would have been the worse trade.
            if (mSetNum > 0) {
                var drift = elapsedDist() - mPauseDistAt;
                if (drift > 0.0) { mSetPausedDist += drift; }
            }
            var live = sessionLive();

            // THE PAUSED SPAN IS CREDITED ON BOTH PATHS, because mPaused goes
            // false on both. An earlier revision credited it only when the
            // resume was confirmed, which sounds careful and was a regression:
            // clearing mPaused un-freezes the step machine (onTick gates on
            // !mPaused), so an uncredited resume charges the whole pause to the
            // running interval. A three-minute pause in a two-minute WORK step
            // ends that step on the next tick -- a lap boundary in the wrong
            // place, and alert() firing a vibration and a tone for a transition
            // nobody earned, on an app whose first rule is never to alarm.
            //
            // mPausedAt is SPENT here, not preserved. There is no later entry
            // to this branch to preserve it for: mPaused is set true in exactly
            // one place below, and that same arm overwrites mPausedAt.
            mStepStartMs += (now - mPausedAt);
            mPaused = false;

            // mPaused does THREE jobs -- the footer claim, onTick's FIT write
            // gate, and the step machine -- and only the FIRST of them should
            // follow a fail-closed answer. So the claim rides on mRecFailed
            // instead, and the other two ride on mPaused.
            //
            // Why the write gate must not fail closed: a resume that SUCCEEDED
            // while isRecording() threw would otherwise freeze every setData
            // over a live session, and record-scope fields LATCH, so every
            // record for the rest of the piece would re-emit the last
            // pre-pause value. Stale data that decodes as real.
            //
            // footState tests recFailed BEFORE paused, so an unconfirmed resume
            // still reads NOT RECORDING and the claim stays honest.
            //
            // The asymmetry favours writing, though not as strongly as an
            // earlier revision of this comment asserted: whether setData on a
            // stopped session is a harmless no-op is #76's open question and is
            // NOT established here. What is established is the other side --
            // withholding writes from a live session corrupts the row through
            // the latch, measured in #36 and #48.
            mRecFailed = pauseFlags(true, live, mRecFailed)[1];
        } else {
            if (mSession != null) {
                try { mSession.stop(); } catch (e) {}
            }
            if (sessionLive()) {
                // The stop did not take. Staying unpaused is correct, not a
                // concession: records ARE still being emitted, so onTick must
                // keep writing real values into them.
                //
                // And CLEAR mRecFailed -- sessionLive() has just proved the
                // recorder is live, so a stale failure flag would leave the
                // footer reading NOT RECORDING over a healthy row with no way
                // out except a press that stops the healthy row.
                var f = pauseFlags(false, true, mRecFailed);
                mPaused    = f[0];
                mRecFailed = f[1];
            } else {
                // Stopped, OR unanswerable. Unlike the resume branch these two
                // do not need separating: pausing is what the athlete asked
                // for, and if an unanswerable session is in fact still
                // recording the cost is a latched span -- the same cost the
                // unconditional assignment this replaced always had. Stated
                // rather than glossed, because "both branches derive the flags
                // from isRecording()" is only true when isRecording() answers.
                //
                // mRecFailed is PRESERVED, not cleared. This arm is reached on
                // a fail-closed false, which cannot distinguish "the stop took"
                // from "the session was already dead" -- and since the flag is
                // only ever true after a failure, clearing it here was a no-op
                // on every healthy path and a lie on the one unhealthy one.
                var g = pauseFlags(false, false, mRecFailed);
                mPauseDistAt = elapsedDist();
                mPausedAt  = now;
                mPaused    = g[0];
                mRecFailed = g[1];
            }
        }
    }

    // "Is a recording actually running right now?" -- false for no session and
    // false for a session that cannot answer.
    //
    // Failing closed on a throw is deliberate: every caller uses this to decide
    // whether to CLAIM the app is recording, and an unanswerable session is not
    // a claim worth making.
    hidden function sessionLive() {
        if (mSession == null) { return false; }
        try {
            return mSession.isRecording();
        } catch (e) {
            return false;
        }
    }

    function stopAndSave() {
        if (mSession != null) {
            // #74: guarded, because everything that matters is BELOW it. An
            // isRecording() that throws here propagates out through
            // StrongRowDelegate.onBack and kills the app before save() at the
            // bottom of this function -- and save() is the only call that
            // writes the FIT. The whole row would be lost to a probe of the
            // session's own state.
            //
            // Reusing sessionLive() rather than a bare try: it already fails
            // closed, and "cannot answer" must not be read as "still
            // recording" and then handed to stop().
            if (sessionLive()) {
                try { mSession.stop(); } catch (e) {}
            }
            if (mFitAvgRmssd != null && mRmssdN > 0) {
                mFitAvgRmssd.setData(mRmssdSum / mRmssdN);
            }
            if (mFitCorrTotal != null) {
                mFitCorrTotal.setData((mCorrAccum + 0.5).toNumber());
            }
            if (mFitMaxCore != null && mMaxCore > 0.0) {
                mFitMaxCore.setData(mMaxCore);
            }
            // #102. Unguarded by value, unlike max_core_temperature above: an
            // all-quiet row is exactly the case this field exists to explain,
            // so there is no reading here that would be better left unwritten.
            // Once per session, so the snapshot's array allocation is off every
            // hot path -- see diagSnapshot.
            //
            // The mCoreSensor term holds the invariant local to one line rather
            // than resting on a whole-file lifecycle argument, matching the
            // reasoning recorded on coreFieldsWanted.
            if (mFitCtDiag != null && mCoreSensor != null) {
                mFitCtDiag.setData(mCoreSensor.diagSnapshot());
            }
            // ERG: the session's total work, in kilojoules.
            //
            // GUARDED BY THE PRESENCE FLAG AND NEVER BY `> 0.0`. A `> 0.0`
            // guard would suppress the field for a row whose true total work
            // was zero and leave a reader unable to tell suppression from
            // absence -- which is the reasoning #80 records for declining a
            // session-scope heat-strain companion, applied rather than
            // repeated. Routed through setWorkKJ so the file and the grid cell
            // use the ONE decision about what counts as a measurement.
            //
            // Withheld rather than written as a sentinel, and that is the
            // opposite of the record-scope fields above. The latch argument
            // does not apply: a session-scope field is written at most once, so
            // there is no previous value for a skipped write to re-emit. What a
            // never-written session-scope field carries is #76's open question
            // and is not claimed here.
            //
            // NO COVERAGE FLOOR HERE, and that is a decision rather than an
            // omission. WORK_COVER_MIN dashes the two GRID cells when too
            // little of the interval carried a sample, because a glance figure
            // has no way to carry its own caveat. A session-scope FIT field
            // does: erg_diag writes ERGD_PWR_OK on EVERY record, so an offline
            // reader can count the covered records directly and scale or
            // discard this total for itself. Withholding it would destroy that
            // option and leave "the source dropped out" indistinguishable from
            // "the field was never created".
            var ergKJ = setWorkKJ(mErgSessJ, mErgSessN > 0);
            if (mFitErgWork != null && ergKJ != null) {
                mFitErgWork.setData(ergKJ);
            }
            mSession.save();
            mSession = null;
            mFitRate = null;
            mFitDps = null;
            mFitRr = null;
            mFitRmssd = null;
            mFitAvgRmssd = null;
            mFitCorr = null;
            mFitCorrTotal = null;
            mFitCore = null;
            mFitSkin = null;
            mFitMaxCore = null;
            mFitCtDiag = null;
            mFitHsi = null;
            // #149. No session-scope companion and no save-time write: these
            // are per-record diagnostics, and a session aggregate of a lock
            // state would need a seen-flag guard of its own to avoid reporting
            // "never locked" and "locked at 0.0" the same way.
            mFitLockRate = null;
            mFitLockConf = null;
            mFitLockLow = null;
            // #149 part 2, cleared with the three above and for the same
            // reason: they are per-record diagnostics with no session-scope
            // companion, so there is nothing to write at save time.
            mFitRateRaw = null;
            mFitRateBase = null;
            // ERG. Cleared with the rest: these handles point into a session
            // that no longer exists, and startSession only re-creates them when
            // erg mode is on -- so a row taken with erg mode OFF after one
            // taken with it on must not inherit live-looking handles.
            mFitErgPower = null;
            mFitErgJps = null;
            mFitErgDiag = null;
            mFitErgWork = null;
            mFitErgCad = null;
        }
        mStarted = false;
        // #74: the attempt is over either way, so the footer goes back to
        // "START to record" rather than latching NOT RECORDING past the row it
        // described. A successful retry would clear this anyway (mRecFailed is
        // assigned from every startSession outcome); this covers the path where
        // the athlete stops instead of retrying.
        mRecFailed = false;
    }

    // #11: release, then CLEAR. Clearing is not tidiness -- these two fields
    // are what onLayout's guards read, so "non-null" has to mean "live".
    // Leaving a stopped Timer and a closed CoreTempSensor in them would make a
    // later onLayout decline to allocate and leave the app with ZERO live
    // timers where the unguarded code left two: the defect's mirror image,
    // reachable under exactly the same unverified condition, which is why both
    // halves ship together. It also means a second shutdown() cannot re-stop
    // the timer, re-close the sensor or re-save the session -- those three are
    // guarded by the handles, rather than relying on each tolerating a repeat
    // call. That is narrower than "idempotent by construction", which an
    // earlier revision of this comment claimed and which is not true of the
    // whole function: mSensorOk is never reset, so
    // unregisterSensorDataListener() re-runs on every call, and the
    // enableLocationEvents(LOCATION_DISABLE) below is unconditional. Both are
    // wrapped in try/catch -- i.e. they rely on exactly the tolerance that
    // sentence disowned. shutdown() IS idempotent in observed behaviour; only
    // the "by construction" part was stronger than the evidence.
    //
    // ORDER IS LOAD-BEARING, and the sensor's clear is deliberately the LAST
    // statement rather than sitting next to its close(). Three constraints have
    // to hold at once:
    //
    //   1. close() must PRECEDE stopAndSave(). #103 latches its ANT diagnostics
    //      at close() for exactly this reason ("Flags latched at close(),
    //      because shutdown() calls close() BEFORE stopAndSave()"): reading the
    //      live channel state at readout would report "released, closed" and
    //      say nothing about the state the session ended in.
    //   2. mCoreSensor must still be READABLE while stopAndSave() runs.
    //      stopAndSave() is where every session-scope field is written, and
    //      #103's ct_diag write is guarded `mFitCtDiag != null && mCoreSensor
    //      != null` -- so clearing the handle first does not fail loudly, it
    //      silently skips the write. That breaks ONLY the onStop path, because
    //      BACK reaches stopAndSave() through the delegate without entering
    //      shutdown() -- and the onStop path is the entire reason shutdown()
    //      calls stopAndSave() at all.
    //   3. mCoreSensor must be null once shutdown() RETURNS, or onLayout's
    //      guard reads a closed sensor as live and never re-opens the channel.
    //
    // Clearing after stopAndSave() is the only order that satisfies all three.
    // An earlier revision of this PR cleared it immediately after close(),
    // which satisfied 1 and 3 and broke 2; nothing caught it, because each
    // suite alone is blind to it -- this file has no ct_diag and #103's has no
    // lifecycle probe. test_life_shutdownKeepsSensorReadableUntilSaved pins all
    // three parts now.
    //
    // This ordering also removes a window rather than arguing it unreachable.
    // Clearing before stopAndSave() left an interval in which mStarted &&
    // mFitCore != null && mCoreSensor == null, which onTick dereferences
    // guarded only by mFitCore. That was defensible only via two platform
    // properties nothing here measures (single-threaded dispatch, and timer
    // callbacks sharing this event loop), and the window did not exist before
    // this PR. stopAndSave() nulls mFitCore, so after the reorder mFitCore and
    // mCoreSensor go null together and the window is gone by construction --
    // which is a better argument than an unreachability claim.
    //
    // mTimer.stop() stays FIRST: it is what stops new onTick work from being
    // scheduled during the rest of the teardown.
    //
    // There is deliberately NO onHide counterpart. Tearing down when the view
    // is merely backgrounded -- a menu, a notification overlay -- would stop
    // the tick timer and silently stop writing every FIT field mid-row, which
    // is a worse defect than the one being fixed. StrongRowApp.onStop ->
    // shutdown() is the single teardown point.
    // UNWIND DISCIPLINE. shutdown() has three points where a release call can
    // fail -- stop(), close() and stopAndSave() -- and every one of them is
    // upstream of work that must still happen, so none may abort the teardown.
    // This was learned one point at a time across three review rounds; the rule
    // below is what all three collapse to.
    //
    //   RULE: clear a handle so the clear cannot be skipped, and let the
    //   release call fail without taking the rest of the teardown with it.
    //
    // Swallowing a teardown failure is this file's existing convention (see
    // addLap, unregisterSensorDataListener, enableLocationEvents) and it is
    // load-bearing here rather than merely conventional: a throw from stop() or
    // close() would otherwise skip stopAndSave() and LOSE THE ROW, which is a
    // far worse outcome than an unreported failure to release a resource the
    // app is finished with anyway.
    function shutdown() {
        // Cleared BEFORE stop(), not after. `mTimer = null` inside this block
        // after the call made the clear conditional on stop() returning
        // normally, and the onLayout guard added by #11 then reads a stopped
        // Timer as live and never re-arms -- zero live timers, permanently.
        // On base main that same throw was harmless (onLayout allocated
        // unconditionally, so recovery still worked), which is exactly why the
        // protection belongs to this PR.
        //
        // The residual cost, stated rather than hidden: if stop() throws, the
        // timer may still be running and its reference is now gone. That orphan
        // is unavoidable -- the timer could not be stopped -- and it is the
        // lesser evil, because the alternative forfeits re-arming AND the save.
        if (mTimer != null) {
            var t = mTimer;
            mTimer = null;
            try { t.stop(); } catch (e) {}
        }
        if (mSensorOk) {
            try { Sensor.unregisterSensorDataListener(); } catch (e) {}
        }
        try { Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition)); } catch (e) {}
        // close() must precede stopAndSave (constraint 1, #103's latch), and it
        // must not be able to prevent it: unwrapped, a throw here skipped the
        // save and the clear below, exactly as a throwing stop() did.
        try {
            if (mCoreSensor != null) { mCoreSensor.close(); }
        } catch (e) {}
        // The sensor's clear cannot move up here -- stopAndSave has to read it
        // (constraint 2) -- so it goes in a finally instead, where a throw
        // cannot skip it.
        //
        // mFitCore/mFitSkin are cleared WITH it, and that is not tidiness.
        // onTick dereferences mCoreSensor guarded only by mFitCore, so
        // `mFitCore != null && mCoreSensor == null` is an uncatchable fault
        // rather than an exception. A throw partway through stopAndSave --
        // before it reaches its own `mFitCore = null` -- would leave exactly
        // that pairing. Clearing all three together is what keeps the invariant
        // `mFitCore != null => mCoreSensor != null` true on the failure path as
        // well as the success path. Redundant on the success path, where
        // stopAndSave has already nulled both.
        //
        // Unlike stop() and close(), a throw from stopAndSave PROPAGATES: it
        // means the row may not have been saved, which the caller should see.
        // Nothing is swallowed here.
        try {
            stopAndSave();
        } finally {
            mFitCore = null;
            mFitSkin = null;
            // #80: the same invariant, for the same reason, one field later.
            // onTick dereferences mCoreSensor guarded only by a field handle,
            // so every record-scope CORE handle has to be cleared in the SAME
            // breath as the sensor -- see the rule stated on coreFieldsWanted.
            mFitHsi = null;
            mCoreSensor = null;
        }
    }

    hidden function alert(stepType) {
        if (!(Toybox has :Attention)) { return; }
        if (Attention has :vibrate) {
            var v;
            if (stepType == STEP_REST || stepType == STEP_DONE || stepType == STEP_COOL) {
                v = [ new Attention.VibeProfile(75, 300),
                      new Attention.VibeProfile(0, 150),
                      new Attention.VibeProfile(75, 300) ];
            } else {
                v = [ new Attention.VibeProfile(75, 250) ];
            }
            try { Attention.vibrate(v); } catch (e) {}
        }
        if (Attention has :playTone) {
            var tone = Attention.TONE_LAP;
            if (stepType == STEP_REST)      { tone = Attention.TONE_ALERT_HI; }
            else if (stepType == STEP_GATE) { tone = Attention.TONE_ALERT_LO; }
            else if (stepType == STEP_COOL) { tone = Attention.TONE_ALERT_HI; }
            else if (stepType == STEP_DONE) { tone = Attention.TONE_STOP; }
            try { Attention.playTone(tone); } catch (e) {}
        }
    }

    // ================= render ==============================================
    hidden function mmss(secs) {
        var s = Math.ceil(secs).toNumber();
        var m = s / 60;
        var r = s % 60;
        return m.format("%d") + ":" + r.format("%02d");
    }

    hidden function mmssUp(secs) {
        var s = secs.toNumber();
        var m = s / 60;
        var r = s % 60;
        return m.format("%d") + ":" + r.format("%02d");
    }

    hidden function totalElapsed() {
        var secs = (System.getTimer() - mStartMs) / 1000;
        var m = secs / 60;
        var s = secs % 60;
        return m.format("%d") + ":" + s.format("%02d");
    }

    hidden function paceStr(spd) {
        if (spd <= 0.3) { return "-:--"; }
        var secs = 500.0 / spd;
        if (secs > 3599.0) { return "-:--"; }
        var m = (secs / 60).toNumber();
        var r = (secs - m * 60).toNumber();
        return m.format("%d") + ":" + r.format("%02d");
    }

    hidden function drawGps(dc, w, h) {
        var col = Gfx.COLOR_RED;
        if (mGpsQual >= 3)      { col = Gfx.COLOR_GREEN;  }   // usable / good
        else if (mGpsQual == 2) { col = Gfx.COLOR_YELLOW; }   // poor
        dc.setColor(col, Gfx.COLOR_TRANSPARENT);
        dc.drawText(w * 0.36, h * 0.045, Gfx.FONT_XTINY, "GPS", Gfx.TEXT_JUSTIFY_CENTER);
        // RR: green while beat intervals are streaming in
        var rcol = Gfx.COLOR_DK_GRAY;
        if (mRrOk && rrIsFresh(System.getTimer(), mLastRrMs, $.RR_FRESH_MS)) {
            rcol = Gfx.COLOR_GREEN;
        }
        dc.setColor(rcol, Gfx.COLOR_TRANSPARENT);
        dc.drawText(w * 0.52, h * 0.045, Gfx.FONT_XTINY, "RR", Gfx.TEXT_JUSTIFY_CENTER);
        // CT: green while a CORE pod's TEMPERATURE data is fresh.
        //
        // Moved left from the 0.66w it used to sit at, to make room for the
        // heat-strain mark at the row's right end. It is not a free move and
        // the per-device numbers are on the PIP_* constants.
        //
        // BOTH RANGES IN THIS PARAGRAPH WERE WRONG AND ARE CORRECTED (#141).
        // It used to read "the gap to the RR pip falls to 7.15-21.9 px from
        // 15.6-25.0, while this label's own clearance to the display edge
        // IMPROVES, from 0.7-2.4 px to 4.06-7.04". Both UPPER gap bounds were
        // wrong -- 21.9 and 25.0 against the 17.20 and 30.24 the shipped
        // constants give -- and the clearance pair could not be reproduced by
        // any derivation from those constants at all, so it is replaced rather
        // than adjusted. The retracted figures are quoted here rather than
        // deleted, because a reader who remembers them needs to know they were
        // withdrawn.
        //
        // The line below is the checked one: scripts/check_pip_geometry.py
        // derives it from the same functions and constants this comment names
        // and fails if the prose and the code disagree.
        //
        //   PIPGEOM-RANGE gap_today=15.60-30.24 gap_after=7.15-17.20 edge_today=1.68-5.68 edge_after=10.80-18.72
        //
        // In words: the gap to the RR pip falls to 7.15-17.20 px from
        // 15.60-30.24, while this label's own clearance to the display edge
        // IMPROVES, from 1.68-5.68 px to 10.80-18.72. GPS and RR do not move at
        // all.
        var ccol = Gfx.COLOR_DK_GRAY;
        if (mCoreSensor != null && mCoreSensor.isFresh()) {
            ccol = Gfx.COLOR_GREEN;
        }
        dc.setColor(ccol, Gfx.COLOR_TRANSPARENT);
        dc.drawText(pipCtCx(w, h), h * $.PIP_ROW_Y_FRAC, Gfx.FONT_XTINY, "CT",
                    Gfx.TEXT_JUSTIFY_CENTER);

        // #80: the heat-strain mark, immediately right of CT so it reads as
        // part of the same CORE group rather than as a fourth unrelated
        // indicator.
        //
        // A MARK, NOT A LABEL, and that is measured rather than preferred. Four
        // text pips do not fit this row on any of the twelve devices: laid out
        // with equal gaps across the chord, "GPS RR CT HS" leaves 2.5 px between
        // labels on fenix843mm against 21.6 px today, and even a
        // one-character label reaches only 8.2 px. The full measurement is on
        // the PIP_* constants.
        //
        // TWO CHANNELS, deliberately, because colour alone is the weaker half:
        //   * SHAPE -- outline for no reading, filled for a current one;
        //   * COLOUR -- the same dark-grey / green vocabulary the RR and CT pips
        //     already use, so a reader learns one rule rather than three.
        // On the two smallest displays the mark is 3 px in radius, so the
        // shape channel there is a handful of pixels and colour carries most of
        // the load. Stated rather than dressed up.
        //
        // THE MARK IS DRAWN IN BOTH STATES -- hollow for no reading, solid for
        // a current one -- and that is the point rather than a detail. A marker
        // that disappears with its data cannot be read against, which is the
        // same rule the distance-per-stroke arc's benchmark tick states; here
        // it also means "this watch is looking for a heat index" stays legible
        // on a row where no pod has ever been heard.
        //
        // ONE primitive either way, never an outline with a fill inside it.
        // Two circle calls for one mark would make "exactly one mark on the
        // status row" unassertable, and that count is what stops a second mark
        // appearing somewhere the status row's own suppression cannot reach.
        //
        // A REAL 0.0 RENDERS AS PRESENT. hsiFresh() is asked, not the value:
        // 0.0 a.u. is an ordinary reading and must not fall into the no-data
        // state. This is the same trap as the FIT write, reached by a different
        // path, and both are pinned.
        //
        // NO NUMBER. There is no row to put one in: h*0.70 is the pace row or
        // #108's work-left caption, h*0.78 is the sub row or #109's grid,
        // h*0.87 is the footer, and this row is at its chord limit. A readout
        // on the pace row would also be invisible during WORK, which is where
        // heat strain is worth reading, so it would be the wrong trade even if
        // it fitted.
        var hsOn = (mCoreSensor != null && mCoreSensor.hsiFresh());
        var hsR  = pipDotR(w);
        var hsX  = pipDotCx(w, h);
        var hsY  = pipDotCy(h, dc.getFontHeight(Gfx.FONT_XTINY));
        dc.setColor(hsOn ? Gfx.COLOR_GREEN : Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
        // Pen width set explicitly: this function runs before the arcs on every
        // frame that reaches it, but nothing guarantees the Dc arrives at 1.
        dc.setPenWidth(1);
        if (hsOn) {
            dc.fillCircle(hsX, hsY, hsR);
        } else {
            dc.drawCircle(hsX, hsY, hsR);
        }
    }

    hidden function drawRate(dc, w, h, col) {
        var valFont = (w >= 300) ? Gfx.FONT_NUMBER_THAI_HOT : Gfx.FONT_NUMBER_HOT;
        var r = outputRate();
        var val = (r > 0.0) ? r.format("%.1f") : "--.-";
        dc.setColor(col, Gfx.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.52, valFont, val,
                    Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
    }

    // The pace row, in whichever units are selected.
    //
    // SAME y, SAME FONT, SAME JUSTIFICATION -- only the STRING changes. h*0.70
    // and FONT_XTINY are a position and a face this row has shipped with on all
    // twelve devices, and nothing here re-derives either; the #123 comment
    // block's warning about re-deriving measured geometry applies to a row as
    // much as to an arc.
    //
    // WHAT IS AND IS NOT ESTABLISHED ABOUT THE NEW STRING'S WIDTH. paceWorkStr
    // is clamped so its widest possible return is "9999W  9999J/str", 16
    // characters, against the 20 of "-:--/500m  12.5m/str". That character
    // bound is pinned in source/ErgUnitsTest.mc. CHARACTERS ARE NOT PIXELS: no
    // (:test) that runs in CI can obtain a font metric (#121), so this is an
    // argument that the erg form is the less demanding of the two and NOT a
    // measured clearance. The per-device measurement is a [Local] one.
    hidden function drawPace(dc, w, h, spd) {
        var txt;
        if (useWorkUnits(mErgMode, mErgPowerUnits)) {
            // ONE read of the power for both terms, so the watts on screen and
            // the joules per stroke derived from them describe the same
            // instant -- two calls could straddle a sample boundary and put a
            // number next to a figure it did not produce.
            var pw = currentPower();
            txt = paceWorkStr(pw, joulesPerStroke(pw, outputRate()));
        } else {
            var dps = distPerStroke(spd);
            txt = paceStr(spd) + "/500m";
            if (dps > 0.0) { txt += "  " + dps.format("%.1f") + "m/str"; }
        }
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.70, Gfx.FONT_XTINY, txt, Gfx.TEXT_JUSTIFY_CENTER);
    }

    // #109: the completed interval, as a 2x2 grid.
    //
    // All four cells come from ONE set of latched raw totals, derived here by
    // the pure statics. That is why the totals are latched rather than the
    // figures: a grid makes any disagreement between cells immediately
    // visible, and deriving them together is what stops it.
    //
    // Every cell renders a dash for null. A dash is a distinct answer; a zero
    // is a claim about the interval. Pinned on the RENDER PATH by
    // GridGate.test_gg_c1_aNullCellRendersADashNeverAZero; until #142 that arm
    // had never executed in CI, because every case latched an interval whose
    // four cells all derived to a value.
    //
    // `dyFrac` SHIFTS THE WHOLE TABLE, in fractions of h, and it is the only
    // thing that differs between the REST/GATE rendering (0.0) and the DONE one
    // ($.GRID_DONE_DY, negative). ONE table with an offset rather than two
    // tables: a second copy of four row fractions is a copy that can drift, and
    // the measured pitch between the rows -- which is the part that took two
    // regressions to get right -- must be identical on every screen that draws
    // the grid. The offset's own derivation lives on GRID_DONE_DY.
    hidden function drawSetGrid(dc, w, h, dyFrac) {
        // MEASURED, both axes. An earlier revision measured only the columns
        // and took the rows from a design mockup: at FONT_MEDIUM the value rows
        // overran the row beneath them by 12-18 px on every device, ink on ink
        // in the same column, because the pitch was 0.09h against a font
        // 0.132h-0.143h tall.
        //
        // getFontHeight over all 12 manifest devices gives XTINY <= 0.0817h,
        // TINY <= 0.1115h (29/260 on the fenix6/6pro/7/7pro family, which is
        // also where the 2.46 px worst vertical gap below comes from) and
        // FONT_NUMBER_MILD <= 0.2476h. The countdown is
        // VCENTER at 0.30h so its box ends at 0.4238h, and the footer starts at
        // 0.87h -- 0.446h of usable band. Two label+value pairs need
        // 2*(0.0817 + 0.1107) = 0.385h of ink, which fits only at TINY, and
        // only with the REST sub row suppressed (see onUpdate). At FONT_MEDIUM
        // or FONT_SMALL it does not fit at any row positions.
        //
        // Worst clearances across all 12 devices, measured not derived:
        //   vertical  2.46 px (fenix6 / 6pro / 7 / 7pro)
        //   label gap 8.12 px (fenix843mm)
        //   left edge 13.4 px to the #110 arc (fenix6spro)
        //   right     15.4 px reserved for #123's arc (fenix6spro)
        //
        // #130: `dyFrac` is added to each row fraction and to nothing else,
        // and it is non-zero on DONE ALONE -- onUpdate's single call site
        // passes $.GRID_DONE_DY for STEP_DONE and 0.0 for everything else.
        //
        // THE COLUMNS DO NOT MOVE, AND ON REST THAT IS A LIVE CONSTRAINT
        // RATHER THAN A MOOT ONE. The left/right clearances measured above are
        // to the two edge arcs, and on REST -- the grid's original and most
        // frequent screen -- BOTH ARCS ARE DRAWN WITH THE GRID: onUpdate's arc
        // gate is `type == STEP_WORK || type == STEP_REST` and its grid gate
        // includes STEP_REST, which is why those two figures were measured at
        // all. dpsForArc makes the pairing explicit -- on STEP_REST it feeds
        // the right-hand arc the SAME latched interval this grid is showing.
        // GATE and DONE draw no arc, so the slack there is theirs alone and
        // #130's VERTICAL shift inherits nothing it should not. A HORIZONTAL
        // shift would need its own measurement against the arcs ON REST rather
        // than inheriting this one.
        //
        // An earlier revision of this paragraph said the two edge arcs were
        // drawn on no screen the grid appears on. RETRACTED: that was true of
        // GATE and DONE and generalised from them, and REST is the
        // counterexample. Pinned by
        // GridGate.test_gg_c3_aLatchedRestDrawsTheGridWithBothEdgeArcs, which
        // renders a latched REST through the shipping onUpdate and requires the
        // grid and an arc on EACH edge in the same render.
        var lx = w * 0.34;
        var rx = w * 0.66;
        var lblY1 = h * (0.44  + dyFrac);
        var valY1 = h * (0.533 + dyFrac);
        var lblY2 = h * (0.655 + dyFrac);
        var valY2 = h * (0.749 + dyFrac);

        // ERG MODE swaps the two RIGHT-hand-derived cells and nothing else.
        // "avg spm" and "avg bpm" are unit-free and stay exactly where they
        // are; what moves is the per-stroke cell (metres -> joules) and the
        // accumulated cell (interval metres -> interval kilojoules), each
        // keeping the SEMANTICS of the cell it replaces. Every cell still comes
        // from ONE set of latched raw totals derived here by the pure statics,
        // so the grid cannot disagree with itself about which interval it
        // describes.
        var wu   = useWorkUnits(mErgMode, mErgPowerUnits);
        var spm  = mLastSetValid ? setAvgSpm(mLastSetStrokes, mLastSetSec) : null;
        var bpm  = mLastSetValid ? setAvgBpm(mLastSetHrSum, mLastSetHrN) : null;
        // The per-stroke cell and the accumulated cell, in the selected units.
        // BOTH halves of the latched work pair go in -- the joules AND the flag
        // saying a measurement was taken -- because the joules alone cannot
        // distinguish "no work done" from "no power meter", and rendering the
        // second as 0.0 is the #86 / #107 defect.
        var per = null;
        var acc = null;
        if (mLastSetValid) {
            if (wu) {
                // ONE coverage decision for BOTH cells, so they cannot
                // disagree about whether the interval is reportable -- the same
                // reason all four cells come from one set of latched totals.
                var cov = workCoverOk(mLastSetWorkN, mLastSetSec, $.TICK_MS);
                per = setAvgJps(mLastSetWorkJ, mLastSetStrokes, cov);
                acc = setWorkKJ(mLastSetWorkJ, cov);
            } else {
                per = setAvgDps(mLastSetDist, mLastSetStrokes);
                acc = setDistM(mLastSetDist);
            }
        }

        // THE LABELS MOVE WITH THE UNITS. A number whose label still says
        // metres is worse than no number.
        //
        // "work kJ" rather than "interval kJ", and the choice is a width one:
        // "interval m" is the label it replaces and "work kJ" is three
        // characters shorter, so this row cannot become the binding constraint
        // on a grid whose measured worst label gap is 8.12 px (fenix843mm, the
        // #109 measurement above). "avg J/str" is exactly as long as the
        // "avg m/str" it replaces. CHARACTERS ARE NOT PIXELS -- #121 puts the
        // font metric out of CI's reach -- so this is an argument that neither
        // label is more demanding than the one it replaces, not a measurement.
        dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(lx, lblY1, Gfx.FONT_XTINY, "avg spm", Gfx.TEXT_JUSTIFY_CENTER);
        dc.drawText(rx, lblY1, Gfx.FONT_XTINY,
                    wu ? "avg J/str" : "avg m/str",  Gfx.TEXT_JUSTIFY_CENTER);
        dc.drawText(lx, lblY2, Gfx.FONT_XTINY,
                    wu ? "work kJ"   : "interval m", Gfx.TEXT_JUSTIFY_CENTER);
        dc.drawText(rx, lblY2, Gfx.FONT_XTINY, "avg bpm", Gfx.TEXT_JUSTIFY_CENTER);

        // toNumber() BEFORE %d. Both of these are Floats -- mLastSetDist comes
        // from Activity.Info.elapsedDistance and setAvgBpm multiplies by 1.0 --
        // and every other %d in this file is applied to a Number obtained by an
        // explicit conversion. drawSetGrid is not inside the try/catch that
        // wraps drawHrArc, so a type surprise here would take the whole screen
        // at 4 Hz. Rounded rather than truncated: %d on 147.9 renders 147.
        //
        // THE TWO SWAPPED CELLS ALSO SWAP THEIR FORMATS, and both erg formats
        // are CLAMPED so that neither cell is wider IN CHARACTERS than the
        // distance cell it replaces:
        //   per-stroke   metres "%.1f" (up to "999.9", 5)  joules ergNum (4)
        //   accumulated  metres "%d"   (up to "18000", 5)  kJ gridKjStr (5)
        //
        // THE CLAMPS ARE NEW AND THE OLD TABLE WAS WRONG, recorded rather than
        // quietly replaced. It claimed the same two bounds with nothing
        // enforcing them and no case pinning them: settings.xml allows a
        // 60-minute work interval, and 60 minutes at 278 W is 1 000 800 J,
        // which the unclamped cell rendered as "1000.8" -- six characters
        // against the five of "18000". The stated maximum was an assumption
        // about athlete power printed in the same table as the format strings.
        // The pace row's analogous bound was enforced (ergNum against
        // PACE_W_MAX) and pinned in characters from the start; the grid had
        // neither.
        //
        // A tenth of a joule per stroke is below anything a rower can act on; a
        // tenth of a kilojoule is the useful resolution below 1000 kJ and is
        // meaningless above it, which is exactly where gridKjStr drops it.
        //
        // CHARACTERS ARE NOT PIXELS (#121). Five characters is a character
        // bound, not a clearance; the per-device measurement is #169's.
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(lx, valY1, Gfx.FONT_TINY,
                    (spm == null) ? "--" : spm.format("%.1f"), Gfx.TEXT_JUSTIFY_CENTER);
        dc.drawText(rx, valY1, Gfx.FONT_TINY,
                    wu ? ergNum(per, $.GRID_J_MAX)
                       : ((per == null) ? "--" : per.format("%.1f")),
                    Gfx.TEXT_JUSTIFY_CENTER);
        dc.drawText(lx, valY2, Gfx.FONT_TINY,
                    wu ? gridKjStr(acc)
                       : ((acc == null) ? "--"
                                        : (acc + 0.5).toNumber().format("%d")),
                    Gfx.TEXT_JUSTIFY_CENTER);
        dc.drawText(rx, valY2, Gfx.FONT_TINY,
                    (bpm == null) ? "--" : (bpm + 0.5).toNumber().format("%d"),
                    Gfx.TEXT_JUSTIFY_CENTER);
    }

    // #108: `fs` is now a PARAMETER rather than computed here, and the reason is
    // that onUpdate has to make a decision about it before it can decide whether
    // to call this at all -- the work view draws the footer only for a hard
    // failure. Computing footState in both places would let the gate and the
    // rendered claim be derived from two evaluations; passing it makes them one
    // by construction. Behaviour is identical everywhere the footer is drawn.
    hidden function drawFoot(dc, w, h, dist, fs) {
        var foot;
        var fcol = Gfx.COLOR_LT_GRAY;
        // THROUGH footDistStr, and gated on ERG MODE alone rather than on
        // useWorkUnits: see that function. This was the one distance string on
        // screen that the unit switch did not reach.
        var km = footDistStr(dist, mErgMode);
        // #74: the chain that used to live here was gated on mStarted alone and
        // never consulted whether a session exists. It is now the pure
        // footState(), pinned in FootStateTest.mc; this switch only maps a state
        // to text and colour.
        if (fs == $.FOOT_NO_ACCEL) {
            foot = "NO ACCEL"; fcol = Gfx.COLOR_RED;
        } else if (fs == $.FOOT_NO_REC) {
            // ORANGE, not red: red is what a healthy REC row shows, and the two
            // must not be confusable at a glance. Colour and layout only -- no
            // tone, no vibration, no flash (#114).
            foot = "NOT RECORDING"; fcol = Gfx.COLOR_ORANGE;
        // #125: THE FIGURE IS mWorkStrokes, NOT mStrokeCount, and the token
        // says so. The rule is on strokeCounts; the short version is that the
        // strokes taken before the first interval are positioning strokes --
        // "quicker and lower force", in the maintainer's words -- and rest
        // paddling is the same, so a session count of every stroke biases the
        // figure UP and hardest on the short sessions.
        //
        // "wk" RATHER THAN "str", because the number's meaning changed and a
        // label that no longer describes its number is worse than no label --
        // the rule drawSetGrid states for the metres cells, applied here.
        // Two characters where three stood, so the widest footer this app
        // COULD draw before this edit ("REC 199:59 12.35km 9999str") got
        // NARROWER by one character. The widest form it draws now is
        // "REC 199:59 12.35km 9999wk".
        // That is a CHARACTER bound and not a clearance: no (:test) that runs
        // in CI can obtain a font metric (#121), so nothing here claims a
        // measured margin -- only that this row cannot have become the binding
        // constraint by this edit.
        //
        // BOTH FORMS, deliberately. A paused footer reporting one set of
        // strokes and a recording footer reporting another would be a defect
        // the athlete meets on the same screen seconds apart.
        } else if (fs == $.FOOT_PAUSED) {
            foot = "PAUSED  " + mWorkStrokes.toString() + "wk"; fcol = Gfx.COLOR_YELLOW;
        } else if (fs == $.FOOT_REC) {
            foot = "REC " + totalElapsed() + " " + km + " " + mWorkStrokes.toString() + "wk";
            fcol = Gfx.COLOR_RED;
        } else {
            foot = "START to record";
        }
        dc.setColor(fcol, Gfx.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.87, Gfx.FONT_XTINY, foot, Gfx.TEXT_JUSTIFY_CENTER);
    }

    // #110: one radial line segment at `deg`, from radius r0 to radius r1.
    // Screen y grows downward while drawArc's degrees grow counter-clockwise,
    // hence the minus on the sine.
    hidden function radialTick(dc, cx, cy, deg, r0, r1) {
        var rad = deg * Math.PI / 180.0;
        var c = Math.cos(rad);
        var s = Math.sin(rad);
        dc.drawLine(cx + r0 * c, cy - r0 * s, cx + r1 * c, cy - r1 * s);
    }

    // #110: the left-edge heart-rate arc. Glance priority 3 -- "is my heart
    // rate in target?" -- answered in peripheral vision while the eye is on the
    // stroke rate.
    //
    // THREE CHANNELS, and only one of them is HUE:
    //
    //   1. the FILL length carries MAGNITUDE. Colour alone cannot distinguish
    //      105 bpm from 138 bpm when both are below the band.
    //
    //      STATED CORRECTLY, because an earlier revision of this comment
    //      overclaimed it as "colour-independent": the fill is drawn at the
    //      SAME radius and the SAME pen width as the track, with no
    //      setPenWidth between them, so it is exactly coincident with the
    //      track and has no geometric edge of its own. Its extent is read as a
    //      CHROMATIC boundary against the track, not as a shape.
    //
    //      AND THAT BOUNDARY IS WEAK, measured against the right pair. An
    //      earlier revision of this correction cited green 15.30:1, blue
    //      8.19:1 and red 5.25:1 -- but those are each colour against BLACK,
    //      not against the track, so they said nothing about the boundary the
    //      sentence was about. Against COLOR_DK_GRAY the fill contrasts at
    //      green 5.43:1, blue 2.91:1, RED 1.86:1. Blue and red sit BELOW the
    //      3:1 floor this file applies at :1092 to reject a colour outright.
    //
    //      So the fill is a REDUNDANT cue, not a load-bearing one, and the
    //      design does not rest on it: the head tick carries the position.
    //      Read the fill as "roughly how far, and which zone" -- at red in
    //      particular its endpoint is nearly unreadable against the track.
    //
    //      AND STATE THE HEAD TICK'S OWN PAIR CORRECTLY, since getting this
    //      wrong twice in one comment would be its own lesson. The head tick
    //      is NOT white-on-track at 7.46:1 -- it never touches the track. It
    //      is drawn in its own annulus at rHd0..rHd1, two pixels OUTSIDE
    //      rTkOut, per the layering invariant below. Its background is the
    //      black onUpdate clears to, so the pair that actually occurs is
    //      white-on-black at 21:1 -- the strongest contrast the display has.
    //
    //      That is also the real lesson for #123's distance-per-stroke arc,
    //      and it is stronger than "contrast against the filled track": this
    //      arc solves the problem by putting its position mark in a SEPARATE
    //      RADIAL LANE, where the fill's colour cannot reach it at all. Copy
    //      the lane, not a contrast requirement;
    //   2. the BAND is drawn ON THE TRACK -- a light rail inside the track
    //      spanning exactly the target band, closed by a radial tick at each
    //      end that crosses both the rail and the track. This is what carries
    //      below / in / above in GEOMETRY, and it is the only channel that can
    //      answer "how much room do I have?", which colour cannot express at
    //      all;
    //   3. COLOUR carries the zone, with the same constants as rateColour.
    //
    // WHAT THE GEOMETRIC CHANNEL DOES AND DOES NOT RESOLVE, stated at the
    // strength it holds. An earlier revision of this comment said below / in /
    // above is readable from geometry "with all colour information removed",
    // full stop. That is FALSE near the band edges and the correction is mine.
    // drawArc truncates to whole degrees, so the finest distinction the
    // geometry can draw is one degree, which at the constants above is 2.5 bpm
    // -- and the head tick and the band tick each have a pen width of their
    // own on top of that. So within roughly a 2-3 bpm collar around each edge,
    // geometry alone cannot say which side of the edge the reading is on;
    // colour still can, because the predicate behind it is exact.
    //
    // The design is unchanged by that, because the claim it actually rests on
    // is weaker and survives: geometry plus colour beats colour alone. Red and
    // green are the commonest colour-vision deficiency pair, and under
    // simulated deuteranopia the blue and red used here separate by only about
    // 1.2:1 in luminance -- so with no geometric channel at all the DIRECTION
    // cue rests entirely on the blue/yellow axis, and "how much room" cannot be
    // expressed at any precision whatsoever. A 2-3 bpm ambiguity at the edge is
    // a different thing from no answer.
    //
    // LAYERING INVARIANT: nothing but the head tick is drawn beyond radius
    // r + pw/2 + 2. That is what keeps the head tick unmistakable in monochrome
    // (it is the only outward mark) and what keeps the fill from ever occluding
    // it.
    //
    // NO TEXT. Deliberate: adding a variable-width string would put this inside
    // #22, whose rule 2 obliges a getTextWidthInPixels() measurement, and there
    // is not one call to that anywhere in this repository. The cost, stated
    // plainly, is that the arc never tells you the number.
    //
    // NO ALARM, at either extreme -- no vibration, no tone, no flashing, no
    // takeover. That is the recorded decision on #114 with its reasoning:
    // alarms fire at extremes, and at extremes the rower already knows.
    //
    // Every dimension derives from dc.getWidth(); .toNumber() truncates toward
    // zero, and the clearances against the h*0.13 and h*0.78 rows and against a
    // 4 px bezel inset were computed with that same truncation for all twelve
    // manifest devices. None of that arithmetic says anything about how this
    // looks on a wrist, and nothing here claims it does.

    // #123: the right-edge distance-per-stroke arc.
    //
    // GEOMETRY IS THE HEART-RATE ARC'S, MIRRORED, and nothing is re-derived:
    // every radius, pen width, bezel inset and minimum sweep is computed by the
    // identical expression. Two arcs of visibly different size on the two edges
    // would read as a defect, and re-deriving them is how they would drift.
    //
    // THREE CHANNELS, and the lesson from #119 is applied rather than
    // rediscovered:
    //
    //   1. the FILL length, which is a LUMINANCE boundary against the track and
    //      not a geometric one -- it is drawn at the same radius and pen width
    //      as the track, so it has no edge of its own. THREE of the four states
    //      contrast weakly there: purple 1.47:1, red 1.86:1, orange 2.33:1;
    //      only green at 5.43:1 clears the 3:1 floor. That is accepted, because
    //      the fill is a redundant cue -- see the head tick below;
    //   2. the BENCHMARK TICK, marking 100% -- the fixed reference
    //      the fill is read against. Fill beyond it means the benchmark is
    //      cleared, which is the geometric statement colour cannot make;
    //   3. the HEAD TICK, in its OWN RADIAL LANE outside the track, white on
    //      black at 21:1. THIS is what carries position. It does not touch the
    //      track, so the fill's weak edge cannot degrade it -- copy the lane,
    //      not a contrast requirement.
    //
    // Wrapped by its caller for the same reason drawHrArc is: this is an
    // ornament on two priorities that must keep working without it.
    hidden function drawDpsArc(dc, w, h, pct) {
        var cx  = w / 2;
        var cy  = h / 2;
        var pw  = (w * 0.030).toNumber(); if (pw  < 4) { pw  = 4; }
        var pwb = (w * 0.020).toNumber(); if (pwb < 3) { pwb = 3; }
        var gap = (w * 0.010).toNumber(); if (gap < 2) { gap = 2; }
        var ptk = (w * 0.008).toNumber(); if (ptk < 2) { ptk = 2; }
        var phd = (w * 0.012).toNumber(); if (phd < 3) { phd = 3; }
        var bez = (w * 0.012).toNumber(); if (bez < 4) { bez = 4; }

        var rHd1   = cx - bez;
        var rHd0   = rHd1 - pw - 2;
        var r      = rHd0 - 2 - pw / 2;
        var rTkOut = r + pw / 2;
        var rBand  = r - pw / 2 - gap - pwb / 2;
        var rTkIn  = rBand - pwb / 2 - 2;

        var have     = (pct != null);
        var showFill = have && dpsFillVisible(pct);

        var bot = dpsWrap($.DPS_ARC_BOT - 360);   // 332
        var top = $.DPS_ARC_TOP;                  // 28

        // ---- the track ----
        dc.setPenWidth(pw);
        dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
        var parts = hrTrackParts(have);
        if (parts <= 1) {
            dc.drawArc(cx, cy, r, Gfx.ARC_CLOCKWISE, top, bot);
        } else {
            // A BROKEN track is the no-data state's own channel, exactly as on
            // the left edge. Same segment arithmetic, so the two edges break
            // identically and a reader learns one rule rather than two.
            var span = ($.DPS_ARC_TOP - ($.DPS_ARC_BOT - 360)) * 1.0;
            var seg  = span / (2 * parts - 1);
            if (seg < $.HR_ARC_MIN_D) { seg = $.HR_ARC_MIN_D * 1.0; }
            // BOTH ENDS WRAPPED. An earlier revision wrapped only a0, and the
            // third segment's a1 is 28 - 4*11.2 = -16.8 -> -16: a NEGATIVE
            // degreeStart handed to drawArc, from the one function written to
            // prevent exactly that, at the one place it was needed.
            //
            // The segment ends are also computed from the BOTTOM upward rather
            // than the top downward, so the last one lands exactly on
            // DPS_ARC_BOT the way the mirror's lands on HR_ARC_BOT. Computing
            // downward from the top left it at 333, one degree short, because
            // the accumulated float error fell on the wrong side of toNumber's
            // truncation.
            var lo = ($.DPS_ARC_BOT - 360) * 1.0;
            for (var i = 0; i < parts; i++) {
                var b0 = lo + i * 2.0 * seg;
                if (b0 >= $.DPS_ARC_TOP) { break; }
                var b1 = b0 + seg;
                // TOLERANCE, not equality. -28 + 4*11.2 + 11.2 is
                // 27.999999999999996 in Float, and toNumber truncates toward
                // zero, so a bare `> TOP` test leaves the last segment one
                // degree short of the sweep's end. The heart-rate mirror lands
                // exactly on HR_ARC_BOT only because its accumulated error
                // happens to fall the other way -- which is luck, not a
                // property, and is not something to rely on twice.
                if (b1 > $.DPS_ARC_TOP - 0.001) { b1 = $.DPS_ARC_TOP * 1.0; }
                dc.drawArc(cx, cy, r, Gfx.ARC_CLOCKWISE,
                           dpsWrap(b1.toNumber()), dpsWrap(b0.toNumber()));
            }
        }

        // ---- the fill: magnitude, coloured by state ----
        if (showFill) {
            dc.setColor(dpsZoneColour(dpsZone(pct)), Gfx.COLOR_TRANSPARENT);
            dc.drawArc(cx, cy, r, Gfx.ARC_COUNTER_CLOCKWISE,
                       bot, dpsWrap(dpsAngle(pct)));
        }

        // ---- the benchmark tick at 100% ----
        //
        // NO RAIL on this edge, deliberately, and the earlier comment saying
        // "on the rail" was describing the heart-rate arc. The left arc's rail
        // spans a BAND with two ends; a benchmark is a single value, so a tick
        // crossing the track is the whole of it.
        //
        // Drawn WHATEVER the reading, including when there is none: it is the
        // scale, not a reading, and a scale that disappears with the data
        // cannot be read against.
        var aB = dpsAngle(100);
        dc.setPenWidth(ptk);
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        radialTick(dc, cx, cy, dpsWrap(aB), rTkIn, rTkOut);

        // ---- the head tick: position, in its own lane ----
        if (have) {
            var ah = dpsAngle(pct);
            dc.setPenWidth(phd);
            dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
            radialTick(dc, cx, cy, dpsWrap(ah), rHd0, rHd1);
            if (dpsIsClamped(pct)) {
                // A second tick just inside the first says "the reading is past
                // the end of the scale", and it turns INWARD so it cannot leave
                // the sweep. Same construction as the heart-rate arc's.
                var d = (pct > $.DPS_DISP_HI) ? -3 : 3;
                radialTick(dc, cx, cy, dpsWrap(ah + d), rHd0, rHd1);
            }
        }
    }
    hidden function drawHrArc(dc, w, h) {
        var cx  = w / 2;
        var cy  = h / 2;
        var pw  = (w * 0.030).toNumber(); if (pw  < 4) { pw  = 4; }
        var pwb = (w * 0.020).toNumber(); if (pwb < 3) { pwb = 3; }
        var gap = (w * 0.010).toNumber(); if (gap < 2) { gap = 2; }
        var ptk = (w * 0.008).toNumber(); if (ptk < 2) { ptk = 2; }
        var phd = (w * 0.012).toNumber(); if (phd < 3) { phd = 3; }
        var bez = (w * 0.012).toNumber(); if (bez < 4) { bez = 4; }

        // Built OUTWARD-IN from the bezel rather than from a radius fraction,
        // and that inversion is the geometric core of the collision fix. On a
        // round display the arc's horizontal position at a given height obeys
        // x = cx - sqrt(r^2 - (cy-y)^2): a LARGER radius puts the arc FURTHER
        // LEFT at every height it reaches. Hugging the bezel is therefore the
        // cheapest clearance there is, and deriving every radius from the
        // outermost allowed pixel is what banks it.
        var rHd1   = cx - bez;                     // outermost drawn pixel
        var rHd0   = rHd1 - pw - 2;                // head tick: outside, alone
        var r      = rHd0 - 2 - pw / 2;            // the track
        var rTkOut = r + pw / 2;
        var rBand  = r - pw / 2 - gap - pwb / 2;   // band rail: inside the track
        var rTkIn  = rBand - pwb / 2 - 2;          // band ticks cross rail+track

        var hasHr = hrHave(mHrEver, mLastHrMs, nowMs(), $.HR_FRESH_MS);
        var bpm   = mHrBpm;
        // TWO gates, not one, and they are deliberately different.
        //
        //   hasHr    is there a heart rate at all? Gates the HEAD TICK, which
        //            is the mark that says "this is where you are".
        //   showFill is the fill long enough to be an arc rather than a ring?
        //            Gates only the fill.
        //
        // Conflating them would drop the head tick for a reading at the very
        // bottom of the display range -- a real heart rate, rendered as no
        // heart rate, which is the failure this whole file is about, reached
        // from the other side.
        var showFill = hasHr && hrFillVisible(bpm);

        // ---- the scale ----
        dc.setPenWidth(pw);
        dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
        var parts = hrTrackParts(hasHr);
        if (parts <= 1) {
            dc.drawArc(cx, cy, r, Gfx.ARC_COUNTER_CLOCKWISE, $.HR_ARC_TOP, $.HR_ARC_BOT);
        } else {
            // A BROKEN track is the no-data state's own channel: `parts`
            // segments separated by gaps of the same width. Nothing else in
            // this widget draws a discontinuous arc.
            var seg = hrTrackSeg(parts);
            for (var i = 0; i < parts; i++) {
                var a0 = $.HR_ARC_TOP + i * 2.0 * seg;
                if (a0 >= $.HR_ARC_BOT) { break; }
                var a1 = a0 + seg;
                // CLAMP rather than break. The last segment ends on HR_ARC_BOT
                // by construction, and float rounding can put it a hair past;
                // the `if (a0 + seg > BOT) break` this replaces would then have
                // dropped that segment entirely, silently drawing two parts
                // where three were asked for.
                if (a1 > $.HR_ARC_BOT) { a1 = $.HR_ARC_BOT * 1.0; }
                dc.drawArc(cx, cy, r, Gfx.ARC_COUNTER_CLOCKWISE,
                           a0.toNumber(), a1.toNumber());
            }
        }

        // ---- the fill: magnitude, coloured by zone ----
        if (showFill) {
            dc.setColor(hrZoneColour(hrZone(hasHr, bpm, mHrLo, mHrHi)),
                        Gfx.COLOR_TRANSPARENT);
            dc.drawArc(cx, cy, r, Gfx.ARC_CLOCKWISE, $.HR_ARC_BOT, hrAngle(bpm));
        }

        // ---- the band, drawn ON the track ----
        // Drawn whether or not there is a heart rate: showing where the target
        // sits costs nothing and is honest.
        var ba = hrBandArc(mHrLo, mHrHi);
        dc.setPenWidth(pwb);
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawArc(cx, cy, rBand, Gfx.ARC_COUNTER_CLOCKWISE, ba[0], ba[1]);
        dc.setPenWidth(ptk);
        radialTick(dc, cx, cy, ba[0], rTkIn, rTkOut);
        radialTick(dc, cx, cy, ba[1], rTkIn, rTkOut);

        // ---- the head: where the reading actually is ----
        if (hasHr) {
            var ah = hrAngle(bpm);
            dc.setPenWidth(phd);
            dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
            radialTick(dc, cx, cy, ah, rHd0, rHd1);
            if (hrIsClamped(bpm)) {
                // A SECOND parallel tick, turned inward from the endpoint: the
                // reading is off the end of the scale, so 210 bpm and 200 bpm
                // do not render identically.
                var d = (bpm > $.HR_DISP_HI) ? 3 : -3;
                radialTick(dc, cx, cy, ah + d, rHd0, rHd1);
            }
        }
    }

    function onUpdate(dc) {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_BLACK);
        dc.clear();

        var spd = currentSpeed();
        var dist = elapsedDist();

        // ================= #108: the per-step-type layout split ==============
        //
        // NOT DISPLAYED IS NOT THE SAME AS NOT RECORDED. Read this before
        // "restoring" any numeral the work branch below leaves out, because
        // that restoration is the predictable next edit and it would be
        // undoing the feature rather than fixing a data loss:
        //
        //   * THE FIT FILE IS THE RECORD AND HAS NO ATTENTION BUDGET. onTick
        //     writes row_stroke_rate, dist_per_stroke, rr_interval, rmssd and
        //     corrective_rate every 250 ms regardless of what is on the
        //     screen -- and core_temperature / skin_temperature every 250 ms
        //     from the first current reading of the session onward (#13; before
        //     that they are deliberately left unwritten). And the
        //     session-scope aggregates land in stopAndSave. The per-interval
        //     accumulators (#109) run off onTick and advanceStep, not off the
        //     draw path. NOTHING below changes any of that: removing an
        //     element here removes a drawText and nothing else.
        //   * THE WATCH SCREEN IS A GLANCE SURFACE AND HAS A HARD ATTENTION
        //     BUDGET. The maintainer's constraint is a fraction of a second
        //     between strokes. Six elements competing with the two that are
        //     being read is the defect; five of them are useful at a rest
        //     break, which is where they now live.
        //
        // So pruning the WORK screen is free of data cost, and that is the
        // justification for it rather than a mitigation of it.
        //
        // WHAT IS NOT FREE, recorded as a decision and not an oversight: there
        // is no recording assurance mid-interval any more. drawFoot is the only
        // thing that says REC. PAUSED survives as the title, and both HARD
        // FAILURES survive as the footer (workFootVisible) -- REC itself is the
        // part that genuinely disappears.
        //
        // The split needs NO NEW STATE. `type` below is the whole of it.
        //
        // Computed before drawGps because the status pips are one of the groups
        // the work view drops. In free-row mode mWorkoutEnabled is false, so
        // `st` is null, `type` is -1 and `isWork` is false -- the pips are drawn
        // exactly as before and the early return below is untouched. Free row
        // has no step types at all, so none of this applies to it.
        var st = (mWorkoutEnabled && mStarted) ? mSteps[mStepIdx] : null;
        // curStepType() is the same condition as the line above, and the two
        // are deliberately kept as one question: `st` is still needed here for
        // st[:idx] and st[:nextn], so the dictionary lookup stays, but the TYPE
        // now comes from the one reader the FIT step marks also use.
        var type = curStepType();
        var isWork = (type == STEP_WORK);
        var fs = footState(mSensorOk, mPaused, mStarted, mRecFailed);

        if (!isWork) { drawGps(dc, w, h); }

        // ---- free-row mode (workout disabled) ----
        if (!mWorkoutEnabled) {
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.13, Gfx.FONT_SMALL, "ROW SPM", Gfx.TEXT_JUSTIFY_CENTER);
            drawRate(dc, w, h, Gfx.COLOR_WHITE);
            drawPace(dc, w, h, spd);
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.78, Gfx.FONT_XTINY, "free row", Gfx.TEXT_JUSTIFY_CENTER);
            drawFoot(dc, w, h, dist, fs);
            return;
        }

        // ---- workout mode ----

        // #110: the heart-rate arc, drawn during WORK and REST and nowhere
        // else. Drawn BEFORE every text element on purpose -- it sits in a
        // left-edge annulus no text occupies, but if that assumption is ever
        // wrong the text wins rather than the geometry.
        //
        // Free-row mode never reaches here (the early return above), and WARM /
        // COOL / DONE / pre-start are unchanged, per #110's acceptance list.
        // PAUSED does reach here: pausing does not change the step type, so the
        // arc stays up and sampleHr keeps feeding it (onTick calls it
        // unconditionally). That is a decision, not an oversight -- a paused
        // rower still has a heart rate.
        //
        // STEP_GATE IS DELIBERATELY EXCLUDED, and #110's acceptance list asks
        // for it, so this is a listed departure rather than a quiet one.
        //
        // Measured: the GATE headline is "PRESS START" in FONT_MEDIUM, centred
        // and vertically centred at h*0.30, and it is enormous relative to the
        // screen -- on fenix843mm it spans 74% of the display width. Any
        // left-edge widget of usable size intersects it. Keeping the arc on
        // that one screen would have forced the sweep down to about +/-16
        // degrees on every device to satisfy it, which is a 32 degree sweep
        // where 44 is already tight: at 32 degrees one truncated degree is
        // 3.4 bpm against 2.5 today, so the band marker gets coarser
        // EVERYWHERE to serve the one screen where nobody is rowing.
        //
        // What is given up is real and is not dressed down: GATE is a recovery
        // moment and a heart rate is worth seeing there. What is kept is the
        // resolution of the marker during the intervals, which is what the
        // feature is for. The arc's own premise -- a peripheral answer while
        // the eye is on the stroke rate -- also does not hold at a gate, where
        // there is no stroke rate and the screen's whole job is one instruction.
        //
        // Both halves of that trade are enforced by source/HrLayoutTest.mc,
        // which still renders GATE and still requires it to be clear. If a
        // later change puts the arc back on that screen, the case reds.
        //
        // WRAPPED, and the wrap is the whole point of drawing it first. The
        // z-order rationale above wants the arc under the text; that same
        // ordering means an unguarded throw from any primitive here takes the
        // title, the countdown, the stroke rate, the pace row, the sub row and
        // the footer with it -- measured: 9 text elements become 3. The wrap
        // keeps the ordering and removes the blast radius.
        //
        // This is the SAME posture sampleHr states for the read side and the
        // OPPOSITE of onLayout's, deliberately: onLayout propagates because an
        // app running with no tick timer should not do so silently, whereas the
        // heart-rate arc is an ornament on two priorities that must keep
        // working without it. Losing the arc is a degradation; losing the
        // stroke rate mid-interval is the failure this whole feature is
        // supposed to avoid causing.
        //
        // REACHABILITY IS UNVERIFIED, IN BOTH DIRECTIONS, and this comment
        // claims neither answer: no input has been found that makes a Dc
        // primitive throw here, and nothing shows none can. The guard is
        // correct under either answer, which is why it lands ahead of the
        // question -- this is the first drawArc in the codebase, it compiles
        // for twelve devices, and it has never run on hardware.
        //
        // Swallowed rather than logged: onUpdate runs at 4 Hz, so a throw that
        // recurred would emit four log lines a second for the life of the app.
        if (type == STEP_WORK || type == STEP_REST) {
            try {
                drawHrArc(dc, w, h);
            } catch (e) {
            }
            // #123: the right edge, on the same two step types. ITS OWN try:
            // a throw in one arc must not cost the other, and neither may cost
            // the stroke rate or the countdown above them.
            try {
                drawDpsArc(dc, w, h, arcPct(type, spd));
            } catch (e) {
            }
        }

        var title;
        if (!mStarted)              { title = mNumWork.toString() + "x" + (mWorkSec / 60).toString() + "'"; }
        else if (mPaused)           { title = "PAUSED"; }
        else if (type == STEP_WARM) { title = "WARM UP"; }
        else if (type == STEP_WORK) { title = "WORK " + st[:idx].toString() + "/" + mNumWork.toString(); }
        else if (type == STEP_REST) {
            // #109: the set number rides in the title, because the sub row that
            // used to carry it stands down while the grid is up.
            title = mLastSetValid ? ("REST - SET " + mLastSetNum.toString()) : "REST";
        }
        else if (type == STEP_GATE) {
            // #109: the sub row that said "to start WORK n" stands down while
            // the grid is up, so the number rides here instead.
            // ABBREVIATED, and measured against ONE reference: the chord
            // half-width at the title row, taken at the lower of the text
            // box's two edges.
            //
            //   "READY - WORK 30"  margin  -7.3 / -29.1 / -28.3 px  (240/416/454)
            //   "READY - W30"      margin  16.2 /  16.4 /  20.7 px
            //   "REST - SET 30"    margin  10.7 /   7.9 /  11.2 px
            //
            // An earlier revision quoted the overrun and the clearance as if
            // they shared a reference; they are both margins against the chord,
            // and the gap between the two strings is a fixed ~47 px of glyph.
            //
            // "30" is the range settings.xml DECLARES, not one the code
            // enforces: loadSettings clamps numIntervals only at the low end,
            // and the #21 note in that same function is about exactly this --
            // a persisted or sideloaded value is not re-clamped on load. The
            // abbreviated form still clears at three digits.
            title = mLastSetValid ? ("READY - W" + st[:nextn].toString())
                                  : "READY";
        }
        else if (type == STEP_COOL) { title = "COOL DOWN"; }
        else                        { title = "DONE"; }
        // #108's element table asks for the interval label to be "kept, dimmed
        // further" during work. IT IS KEPT AND IT IS NOT DIMMED, and that is a
        // listed departure with an arithmetic reason rather than a preference.
        //
        // The only step below COLOR_LT_GRAY in the 64-colour palette these
        // devices declare is COLOR_DK_GRAY (0x555555). Against the black
        // onUpdate clears to, WCAG contrast is 9.04:1 for LT_GRAY and 2.82:1
        // for DK_GRAY -- BELOW the 3:1 floor this file applies at rateColour to
        // reject COLOR_DK_BLUE outright. Six of the twelve manifest devices are
        // 8 bpp transflective MIP, where a sunlight-readable label matters most.
        //
        // Dimming a glance element below the floor the file already enforces
        // would be trading a real legibility loss for a hierarchy gain that the
        // strip already delivers by removing five competing elements. (Note the
        // #109 grid labels DO ship at DK_GRAY; that inconsistency is
        // pre-existing and is named in the pull request rather than changed
        // here.)
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.13, Gfx.FONT_SMALL, title, Gfx.TEXT_JUSTIFY_CENTER);

        if (type == STEP_WORK || type == STEP_REST) {
            dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.30, Gfx.FONT_NUMBER_MILD, mmss(stepRemaining()),
                        Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
        } else if (type == STEP_WARM || type == STEP_COOL) {
            dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.30, Gfx.FONT_NUMBER_MILD, mmssUp(stepElapsed()),
                        Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
        } else if (type == STEP_GATE) {
            dc.setColor(Gfx.COLOR_YELLOW, Gfx.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.30, Gfx.FONT_MEDIUM, "PRESS START",
                        Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
        } else if (!mStarted) {
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.30, Gfx.FONT_TINY, "START to begin",
                        Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
        }

        // THE NUMBER AND THE INSTRUCTION, from here on, are two different
        // things computed from one estimator reading:
        //   dispRate  goes to drawRate untouched -- it is the measurement.
        //   col       comes from the cue zone -- it is the instruction.
        var dispRate = outputRate();
        var cue;
        if (isWork) {
            cue = cueStep(dispRate, mTgtLo, mTgtHi,
                          mCueZone, mCueCand, mCueSince, nowMs());
        } else {
            // Off the WORK step nothing is being cued, so nothing is carried.
            // Parking at CUEZ_NONE rather than leaving the machine running is
            // what stops a zone derived from rest-cadence strokes appearing the
            // instant the next work interval starts -- and it means the first
            // work frame shows the true zone at once, with no cue in front of
            // it to protect.
            cue = [$.CUEZ_NONE, $.CUEZ_NONE, nowMs()];
        }
        mCueZone  = cue[0];
        mCueCand  = cue[1];
        mCueSince = cue[2];
        var col = cueColour(isWork, mCueZone);
        // #109: on the RECOVERY screens the grid IS the screen -- there is no
        // stroke to correct, so the live numeral earns nothing, while the
        // interval just finished is the thing worth reading.
        //
        // REST **AND GATE**, which is what #109's acceptance criteria asked for
        // and what an earlier revision narrowed to REST alone. `restMinutes = 0`
        // is legal (loadSettings clamps it to >= 0, buildWorkout emits a REST
        // step only when it is > 0), so a rest-free workout is WORK/GATE/WORK
        // and a REST-only gate would never have rendered the grid at all.
        //
        // NOT every non-WORK step, which the revision after that over-corrected
        // to. COOL DOWN is ACTIVE ROWING -- it gets its own lap and step clock,
        // its instruction is "START when docked", and warmupCooldown defaults
        // to true -- so replacing its live rate, pace and m/str with a frozen
        // summary of an interval that already ended is a downgrade on the
        // default path. WARM is active for the same reason and precedes any
        // latch anyway.
        //
        // **AND DONE** (#130), which is the third screen and the one this gate
        // was WRONG to exclude. buildWorkout emits a REST or GATE step only
        // inside `if (i < mNumWork)`, so the LAST work interval is followed by
        // COOL or DONE and never by a REST: its summary latched correctly and
        // nothing ever rendered it. The hardest interval of the session was the
        // one whose summary the athlete could not see.
        //
        // The paragraph this replaces said DONE "is left showing the live
        // values too: its band is laid out for the sub row that tells the
        // athlete to press BACK, and losing that is worse than gaining a
        // summary". The premise was right and the conclusion did not follow --
        // BOTH fit, because DONE draws no countdown and the grid can start
        // 0.135h higher. The sub row is NOT suppressed here (see the gate below
        // it, which stays on REST and GATE alone), so "BACK to save" survives
        // with the grid up. What DONE does give up is the LIVE rate and pace
        // row, and that is the trade rather than an oversight: the piece is
        // over, there is no stroke to correct, and the interval just finished
        // is the thing worth reading.
        //
        // Pinned by GridGate.test_gg_c2_theGridIsUpOnEveryRecoveryStepAndNowhereElse
        // (the whole table, WORK included) and by
        // GridGate.test_gg_c2_doneShowsTheFinalIntervalAndKeepsBackToSave.
        if ((type == STEP_REST || type == STEP_GATE || type == STEP_DONE)
                && mLastSetValid) {
            // DONE is the only screen with a base of its own; see GRID_DONE_DY
            // for the arithmetic that produced -0.135 and the range it may move
            // in before something collides.
            drawSetGrid(dc, w, h, (type == STEP_DONE) ? $.GRID_DONE_DY : 0.0);
        } else {
            drawRate(dc, w, h, col);
            // #108: the pace / metres-per-stroke row stands down during WORK.
            // Two independent reasons, and the second is what makes it
            // inseparable from the arc widening in this change:
            //   * the maintainer reads those two numbers at a rest break, not
            //     between strokes;
            //   * it occupied h*0.70, which is the row the arc's lower end
            //     reaches first. With it there the sweep was already near its
            //     ceiling at +/-22; without it the measured ceiling is +/-28.
            // The row is not left empty -- the work-left figure takes it, at
            // the same y and with a strictly narrower string.
            if (!isWork) {
                drawPace(dc, w, h, spd);
            } else {
                // #108 section B. A LOWER BOUND, captioned as one.
                //
                // AT h*0.70, WHICH IS THE PACE ROW'S OWN y, and that placement
                // is evidence rather than taste. Every clearance this row needs
                // -- against the stroke-rate numeral above it and the caption
                // below it -- is one the pace row has shipped with on all
                // twelve devices, and the string is narrower than the one it
                // replaces. MEASURED at FONT_XTINY on the four 454 px devices,
                // which are the widest: "1800:00 work left" is 238 px against
                // "-:--/500m  12.5m/str" at 277 px. The declared maximum,
                // "3540:00 work left" (30 intervals of 60 minutes plus 29 rests
                // of 60), has the same character count. So this row is strictly
                // less demanding than the one it replaces, on both axes.
                //
                // The alternative -- tucking it directly under the countdown --
                // does not fit: at h*0.42 it lands inside the stroke-rate
                // numeral's font box on the 454 px devices, and this repository
                // has no way to measure glyph ink, so "the ink probably clears"
                // is not a claim it can make.
                dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
                dc.drawText(w / 2, h * 0.70, Gfx.FONT_XTINY,
                            workLeftCaption(mmss(
                                workLeftSec(mSteps, mStepIdx, stepRemaining()))),
                            Gfx.TEXT_JUSTIFY_CENTER);
            }
        }

        var sub;
        if (type == STEP_WARM)      { sub = "START to begin work 1"; }
        else if (type == STEP_WORK) { sub = "target " + mTgtLo.toString() + "-" + mTgtHi.toString() + " spm"; }
        else if (type == STEP_REST) { sub = "next: WORK " + st[:nextn].toString(); }
        else if (type == STEP_GATE) { sub = "to start WORK " + st[:nextn].toString(); }
        else if (type == STEP_COOL) { sub = "START when docked"; }
        else if (type == STEP_DONE) { sub = "BACK to save"; }
        else                        { sub = "target " + mTgtLo.toString() + "-" + mTgtHi.toString() + " spm"; }
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        // #109: the grid needs the whole band between the countdown and the
        // footer, so the sub row stands down on exactly the two screens the
        // grid occupies -- and NOWHERE else. An earlier revision suppressed it
        // on every non-WORK step, which silently deleted "START when docked"
        // from COOL and "BACK to save" from DONE. The second is the only text
        // on the app telling the athlete how to write the FIT.
        //
        // What the suppressed rows carried, stated exactly rather than
        // generously. GATE's number IS preserved -- its title uses the same
        // st[:nextn] the row used. REST's is SUBSTITUTED, not preserved: the
        // row said "next: WORK i+1" and the title says the completed set i, so
        // a forward-looking number becomes a backward-looking one.
        //
        // And NEITHER survives a pause: the `mPaused` title branch is tested
        // before the type branches, so a paused REST reads "PAUSED" with no
        // number anywhere. Adding !mPaused to this gate would restore the row
        // and re-create the overlap it was suppressed for, so the number is
        // accepted as lost on that one screen.
        //
        // #130: THIS GATE IS DELIBERATELY NARROWER THAN THE GRID'S, and the
        // difference is the whole point rather than an inconsistency. The grid
        // now draws on DONE as well, and DONE KEEPS ITS SUB ROW -- "BACK to
        // save" is the only text in the app telling the athlete how to write
        // the FIT, and the grid clears it there because DONE draws no countdown
        // and takes a base 0.135h higher (GRID_DONE_DY). Suppressing the row
        // "wherever the grid appears" is exactly #109's second review
        // regression, so the two gates must not be merged into one.
        if (!((type == STEP_REST || type == STEP_GATE) && mLastSetValid)) {
            dc.drawText(w / 2, h * 0.78, Gfx.FONT_XTINY, sub, Gfx.TEXT_JUSTIFY_CENTER);
        }

        // #108: the footer stands down during WORK for every state EXCEPT a
        // hard failure. The rule and its argument live on workFootVisible; the
        // short version is that REC is the element the strip removes, PAUSED is
        // already the title, and NO ACCEL / NOT RECORDING are failures that
        // make the rest of this screen untrue.
        if (workFootVisible(isWork, fs)) {
            drawFoot(dc, w, h, dist, fs);
        }
    }
}
