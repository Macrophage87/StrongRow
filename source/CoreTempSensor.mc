using Toybox.Ant;
using Toybox.System;
using Toybox.Timer;

// Constants shared between CoreTempSensor and its static, (:test)-able
// helpers. At module (global) scope because a Monkey C class `const` is an
// instance member -- unreachable from a static method or via the class name --
// whereas a module const resolves from static, instance, and test code alike.
// Same reason the RR_* consts sit at module scope in StrongRowView.mc.
//
// DEVICE_TYPE / RF_FREQ / PERIOD_A / PERIOD_B deliberately stay class consts:
// they are used only from instance methods, so they need no hoist.
const CT_FRESH_MS = 30000;        // a reading is treated as current this long

// Plausibility clamps. These are what actually reject an invalid frame today
// (see the sentinel note on decodeCoreC), and they remain the only defence
// against a page layout that has not been measured on air -- see #88.
const CT_CORE_MIN_C = 25.0;
const CT_CORE_MAX_C = 45.0;
const CT_SKIN_MIN_C = 15.0;
const CT_SKIN_MAX_C = 45.0;

// Invalid marker for the 12-bit signed skin field: the most-negative code
// point, which is why the documented range is +/-102.35 (2047/20) rather than
// +/-102.40. Tested on the raw pattern BEFORE sign extension.
const CT_SKIN_INVALID = 0x800;

// ---- Heat Strain Index, page 1 byte 1 (#80) --------------------------------
//
// EVIDENCE CLASS FIRST, because it governs what may be written about this
// field anywhere in the repository.
//
// The offset, the 0.1 scale and the 0xFF invalid code point are DOCUMENT
// AGREEMENT, not measurement. They come from greenTEG's own condensed page
// table plus three independent third-party decoders (one Python, one C++, one
// Monkey C) that agree exactly -- but all three trace back to that same vendor
// document, so it is one source corroborated three times, not three
// observations of the air. The formally authoritative ANT+ device profile is
// behind an adopter login and was NOT read. NO CORE POD WAS INVOLVED IN ANY OF
// THIS. #81 is the capture that would upgrade it, and until that capture
// exists no comment here or downstream may state what a pod transmits or what
// a decoder renders -- only what this code READS.
//
// SIGNEDNESS IS UNRESOLVED IN THE VENDOR DOCUMENT ITSELF, and this file does
// not resolve it: the value column of the row says "Signed Integer 1 Byte
// (SINT8)" while the range column of the SAME row says "0 to 25.4", which
// needs an unsigned byte. The two readings agree over 0x00..0x7F and diverge
// only above it. Read unsigned here, matching all three implementations and
// the vendor's own BLE typing of the identical field -- but that is a CHOICE
// among two documented readings, not a fact, and #81 question 4 is what would
// settle it.
//
// NO PLAUSIBILITY CLAMP IS POSSIBLE, and that is a real difference from core
// and skin rather than an omission. Every code point except the invalid marker
// maps into the documented 0.0..25.4 range by construction, so there is no
// out-of-domain value a clamp could reject -- a decode reading the WRONG BYTE
// would produce an in-range, plausible-looking strain index and nothing here
// could tell. The invalid marker is the only guard this field has.
const CT_HSI_INVALID = 0xFF;      // documented "invalid" code point
const CT_HSI_SCALE   = 0.1;       // documented units, a.u.

// Retry pacing for the ANT search. Wired up at the #26 commit; the ladder
// itself is a pure function so it is (:test)-able on its own.
const CT_BURST_TRIES     = 4;     // back-to-back searches before backoff starts
const CT_BACKOFF_BASE_MS = 30000;
const CT_BACKOFF_MAX_MS  = 300000;

// ---- #122: the post-loss listen duty ---------------------------------------
//
// THE SEARCH WINDOW, hoisted out of the DeviceConfig literal below so that the
// duty arithmetic in this file is computed from the SAME number the radio is
// actually told. The two used to be a literal 12 and a comment saying "30 s",
// which is precisely the shape of claim this repository keeps having to
// withdraw. searchTimeoutLowPriority counts units of 2.5 s, so the pair is
// nailed together by test_cr_c1_theSearchWindowIsTheOneTheRadioIsTold rather
// than by a constant expression the compiler might or might not fold.
const CT_SEARCH_TIMEOUT_LP = 12;      // DeviceConfig units: 2.5 s each
const CT_SEARCH_WINDOW_MS  = 30000;   // == CT_SEARCH_TIMEOUT_LP * 2500
//
// THE MEASUREMENT THIS EXISTS TO FIX. Two real rows recorded on v0.7.1, read
// out of their ct_diag arrays:
//
//   i174014735 (2x15, 38 min): 22 broadcasts, 19 valid decodes, 13 closures
//   i178249719 (8x3,  50 min):  3 broadcasts,  3 valid decodes, 24 closures,
//                               maxFails 11
//
// Three broadcast frames in fifty minutes. With maxFails 11 the ladder sat at
// CT_BACKOFF_MAX_MS for most of the row, and
//
//   ctDutyPerMille(CT_SEARCH_WINDOW_MS, CT_BACKOFF_MAX_MS) = 91
//
// i.e. 9.1 % -- roughly thirty seconds of listening in every 330. A pod that
// stops broadcasting and later resumes is therefore likely to be missed, and
// the worst-case blind gap (a pod resuming just after a window closes) is the
// whole CT_BACKOFF_MAX_MS: 300 s.
//
// THE TENSION IS REAL. Before #26 the post-loss branch re-searched forever at
// ~100 % duty; that found a returning pod at once and held the radio open all
// session, which is what #26 was filed about. Reverting is not available.
//
// WHAT THIS BRANCH DOES: keep #26's ladder exactly as it is for a pod that has
// never been heard from, and CAP it lower once a broadcast frame has actually
// been tracked this session. The two ladders, in ms:
//
//   never near:  0, 0, 0, 30000, 60000, 120000, 240000, 300000, 300000, ...
//   pod near:    0, 0, 0, 30000, 60000,  60000,  60000,  60000,  60000, ...
//
//   ctDutyPerMille(CT_SEARCH_WINDOW_MS, CT_BACKOFF_MAX_MS)      =  91  (9.1 %)
//   ctDutyPerMille(CT_SEARCH_WINDOW_MS, CT_BACKOFF_NEAR_MAX_MS) = 333 (33.3 %)
//
// so the steady-state blind gap for a pod that was there falls 300 s -> 60 s
// and the listen duty rises 9.1 % -> 33.3 %, which is still a third of the
// pre-#26 behaviour rather than a return to it. Both figures are computed by
// ctDutyPerMille from the constants in this file and pinned by
// test_cr_c1_theDutyArithmeticIsTheOneStatedHere -- no number in this comment
// is a hand calculation.
//
// BATTERY IS NOT MEASURED AND IS NOT CLAIMED. Every figure above is a DUTY
// CYCLE: the fraction of wall-clock time the search window is open. Nothing in
// this repository has measured milliamp-hours on any watch, and 33.3 % duty is
// not "3.7x the battery cost" of 9.1 % -- radio current is not proportional to
// search-window occupancy in any way this code has evidence for.
//
// THE COST, stated rather than left to be discovered: the gate is STICKY for
// the life of the sensor, so a pod that is heard once and then removed holds
// the shorter cap for the rest of the app run. A decaying gate would need a
// clock on the ANT callback path and a second tunable, and what it would buy --
// falling back to the 300 s cap after a long absence -- is exactly the
// behaviour #122 was filed against. The bound that would actually fit is a
// recording-state gate (search hard while recording, relax after stopAndSave),
// which needs a lifecycle hook in StrongRowView and is #11's coordination
// point; it is deliberately not built here.
const CT_BACKOFF_NEAR_MAX_MS = 60000;

// ---- #102 diagnostic counters ----------------------------------------------
//
// A 68-minute row logged core_temperature = 0.0 in all 4109 records and the
// file could not say WHY: no pod in range, a channel that never opened, and
// frames that arrived and were discarded are three failures with three
// different fixes and one identical footprint. These counters exist to
// separate them, and nothing else -- they must never change a decoded value,
// a clamp, a freshness window or the retry ladder.
//
// They are read out ONCE, in stopAndSave, into a single session-scope UINT16
// ARRAY developer field ("ct_diag", id 10, :count => CT_DIAG_SLOTS). One array
// rather than ~20 scalars: developer field ids 0-9 are already allocated and
// #77 is open on whether the SDK caps fields per session, so this costs ONE
// more id instead of twenty, and one field_description message instead of
// twenty -- while every slot stays an ordinary readable integer, which a
// bit-packed encoding would not. Slot 0 carries the layout version so a future
// reader can tell which key below applies.
//
// MEASURED, in the SIMULATOR on fr965 / SDK 9.2.0 (treat hardware and other
// SDKs as expected-same but unmeasured): a session-scope UINT16 field with
// :count is created without throwing, setData on it after session.stop() and
// before session.save() does not throw, and the values survive to the file --
// a saved activity driven through the real startSession/stopAndSave path
// decoded with fitparse carrying all CT_DIAG_SLOTS values in order, unscaled,
// under native_mesg_num='session', alongside all ten pre-existing developer
// fields. Whether a real device agrees, and whether it caps developer fields
// below 11, is NOT measured; #77 owns that question.
//
// Counters are plain 32-bit Number increments on the ANT callback path: no
// saturation test, no allocation, no branch beyond the ones already present.
// A 4 Hz channel for 24 h is ~3.5e5 increments, nearly four orders of
// magnitude below the 2^31-1 overflow, so clamping to the UINT16 range happens
// ONCE at readout instead. A slot reading CT_DIAG_MAX therefore means "at
// least CT_DIAG_MAX": the READOUT clamp bites long before overflow does --
// 65535 messages is ~4.6 h at PERIOD_B, ~9.1 h at PERIOD_A. Only quantitative
// ratios degrade there; every discrimination below turns on zero versus
// non-zero, which survives any session length.
const CT_DIAG_SLOTS   = 25;
const CT_DIAG_MAX     = 65535;    // UINT16 ceiling; readout clamps, not the counter
const CT_DIAG_NONE    = 0xFFFF;   // "never observed" for the page-byte slots

// Slot indices. These ARE the wire format: renumbering one without bumping
// CT_DIAG_VERSION silently mis-labels every field already recorded.
//
// VERSION 2 (#80) adds slots 21-23 for the heat-strain index and changes
// NOTHING about slots 0-20 -- test_ct_c0_diagSlotKeyIsZeroToTwenty nails those
// to their literal indices, so a v1 reader's key still applies to the prefix of
// a v2 array. The version bump is what tells a reader the array is 24 long
// rather than 21; the growth is why $.CT_DIAG_SLOTS must remain the single
// constant BOTH diagSnapshot() and the createField `:count` read (a setData
// array longer than :count is an uncatchable System Error at save time).
//
// VERSION 4 (#165) ADDS ONE SLOT, CT_DIAG_I_PAGE0 at index 24, and NINE BITS to
// CT_DIAG_I_FLAGS. Slots 0-23 keep their numbers and their meanings, and every
// v1/v2/v3 flag bit keeps its value, so an older key still answers every
// question it could answer before -- test_cr_c0_theFourFlagBitsKeepTheirValues
// and test_ct_c0_diagSlotKeyIsZeroToTwenty are the pins that force that.
//
// THE LENGTH GREW, so this is the version bump that actually matters: the
// createField `:count` in StrongRowView reads $.CT_DIAG_SLOTS, and a setData
// array LONGER than :count is an uncatchable System Error that kills the app at
// save time and takes the whole activity with it. Both sites read the one
// constant; neither may substitute a literal.
//
// WHY A SLOT FOR THE PAGE-0 COUNT AND BITS FOR THE REST. The count is a tally,
// and a tally packed into bits stops being an ordinary readable integer, which
// is the property the whole array was designed around. The two things page 0x00
// says about itself -- a 1-4 quality code and a 0-3 heart-rate-support code --
// are small enums, and what a reader wants of them is WHICH VALUES WERE EVER
// SEEN, which is a bitmask by nature. Nine free bits of an existing slot cost no
// array growth and no :count risk.
//
// A MASK RATHER THAN "THE LAST VALUE" OR "THE WORST VALUE", and that is a
// deliberate refusal to guess. #165 calls the quality field "a 0-4 reliability
// rating" and nothing here knows its POLARITY -- whether 4 is good or bad. A
// "worst observed" slot would have to assume one. A mask assumes nothing: it
// reports exactly which codes the pod emitted, and the polarity question can be
// settled later from a row without re-recording anything.
//
// VERSION 3 ADDED NO SLOT. CT_DIAG_SLOTS stayed 24 and every index below kept
// its number, so the createField `:count` was untouched and the uncatchable
// too-long-array failure above was not in play. What changed is that
// CT_DIAG_I_FLAGS carries one more bit -- CT_DIAG_F_RETRY_LOST, "a deferred
// retry was dropped for want of a Timer". Every v2 bit keeps its meaning, so a
// v2 key applied to a v3 array still answers every question it could answer
// before; the bump exists so that a reader who sees bit 3 set knows it is a
// documented signal rather than residue, and so that this decision is visible
// in the file rather than only here (test_ct_diagLayoutConstants is the pin
// that forces it to be deliberate).
const CT_DIAG_VERSION = 4;        // value stored in slot CT_DIAG_I_VERSION

const CT_DIAG_I_VERSION       = 0;
const CT_DIAG_I_OPEN_ATTEMPTS = 1;   // openChannel() entries
const CT_DIAG_I_OPEN_OK       = 2;   // open() RETURNED TRUE -- the channel opened
const CT_DIAG_I_OPEN_THROW    = 3;   // openChannel()'s catch entered
// openAttempts - openOk - openThrow is the QUIET-FAILURE count: open() returned
// false without throwing. Reading openOk as "did not throw" is the misdiagnosis
// this key exists to prevent -- a quietly failed open is not a podless row.
const CT_DIAG_I_MSG_TOTAL     = 4;   // onMessage() entries -- any ANT message
const CT_DIAG_I_BCAST         = 5;   // broadcast payloads reaching onBroadcast
const CT_DIAG_I_SHORT_PAY     = 6;   // rejected: null or fewer than 8 bytes
const CT_DIAG_I_PAGE1         = 7;   // page byte == 0x01
const CT_DIAG_I_PAGE_OTHER    = 8;   // page byte != 0x01 -- the page-filter reject
const CT_DIAG_I_CORE_OK       = 9;   // decodeCoreC returned a value
const CT_DIAG_I_CORE_SENTINEL = 10;  // rejected: raw16 == 0xFFFF
const CT_DIAG_I_CORE_CLAMP    = 11;  // rejected: outside CT_CORE_MIN_C..MAX_C
const CT_DIAG_I_SKIN_OK       = 12;  // decodeSkinC returned a value
const CT_DIAG_I_SKIN_SENTINEL = 13;  // rejected: raw12 == CT_SKIN_INVALID
const CT_DIAG_I_SKIN_CLAMP    = 14;  // rejected: outside CT_SKIN_MIN_C..MAX_C
const CT_DIAG_I_CHAN_CLOSED   = 15;  // onChannelClosed() entries
const CT_DIAG_I_MAX_FAILS     = 16;  // HIGHEST mFails reached (mFails itself resets)
const CT_DIAG_I_FLAGS         = 17;  // see CT_DIAG_F_* below
const CT_DIAG_I_PAGE_FIRST    = 18;  // first page byte ever observed
const CT_DIAG_I_PAGE_OTHER_LAST = 19; // most recent page byte != 0x01
const CT_DIAG_I_ACQ_PERIOD    = 20;  // mPeriod at the FIRST broadcast frame (#84)
// ---- v2, #80: the heat-strain index -----------------------------------------
// These three exist because the heat-strain feature's central open question --
// does a real pod put anything in page-1 byte 1? -- is otherwise invisible in a
// saved activity. A never-populated heat_strain_index field says "no value was
// ever written" but cannot say whether that is because the pod withheld it or
// because nothing was ever fresh at a record boundary. These slots separate the
// two from the file alone, with no ANT sniffer.
const CT_DIAG_I_HSI_OK        = 21;  // decodeHsi returned a value
const CT_DIAG_I_HSI_INVALID   = 22;  // rejected: byte 1 == CT_HSI_INVALID
// HIGHEST raw byte-1 code point ACCEPTED (so 0xFF is excluded by construction),
// or CT_DIAG_NONE when none ever was. Two questions in one slot:
//   * CT_DIAG_NONE with page1 > 0 means byte 1 was the invalid marker on every
//     page-1 frame -- the "this pod does not broadcast HSI" answer;
//   * a value above 0x7F is the only evidence that could settle the vendor
//     document's SINT8-versus-range contradiction (#81 question 4). Its ABSENCE
//     settles nothing and must not be read as evidence of signedness.
const CT_DIAG_I_HSI_MAX_RAW   = 23;
// ---- v4, #165: page 0x00 ----------------------------------------------------
// Frames whose page byte is 0x00 -- the CBT general-information page, which
// carries the pod's own data-quality rating and its heart-rate-support state.
//
// It is a SEPARATE tally from CT_DIAG_I_PAGE_OTHER, not a replacement for it.
// Slot 8's key is "page byte != 0x01" and page 0x00 still satisfies it, so
// every key ever written against an already-recorded file keeps working, and
// pageOther - page0 is the count of pages that are still genuinely unknown.
//
// Zero here with pageOther > 0 says the non-page-1 traffic was something else
// entirely; zero here with pageOther == 0 says the pod sent nothing but page 1.
// The two are different findings and neither is recoverable from the flag bits,
// which is why this is a slot and not another bit.
const CT_DIAG_I_PAGE0         = 24;
// Slot 20 answers #84 in the AFFIRMATIVE ONLY. PERIOD_A is always tried first,
// so 16384 proves nothing about the fallback; only 8192 is evidence that
// PERIOD_B can acquire. And it reads 0 on precisely the zero-frame rows where
// the question bites, because it is set inside onBroadcast. A value seen in a
// synthetic run shows the slot populates and reaches the file -- it is not
// evidence that a pod acquired at 4 Hz.

// Bits of CT_DIAG_I_FLAGS.
const CT_DIAG_F_CHANNEL_HELD = 1;   // a channel handle was still held at readout
const CT_DIAG_F_CLOSED       = 2;   // close() had run
const CT_DIAG_F_EVER_SEEN    = 4;   // a reading was accepted at some point
// v3: a deferred retry was DROPPED because no Timer could be armed. Set in
// exactly one place -- scheduleReopen's catch -- and never cleared, so it means
// "this happened at least once this session", not "it is happening now". Sticky
// is the only form that survives the latch close() takes (see mDiagFlags).
//
// It is the ONLY thing in this array that separates "the ladder is waiting for a
// retry that will arrive" from "the ladder stopped and nothing will re-enter
// openChannel() again". Those two differ otherwise by one openAttempt that has
// not happened YET -- an absence, and a diagnosis resting on an absence is
// exactly what #102 exists to stop.
const CT_DIAG_F_RETRY_LOST   = 8;

// v4, #165: WHICH page-0x00 codes were ever observed. Two contiguous runs of
// four, so ctQualityBit / ctHrSupportBit can shift rather than branch; the
// contiguity is pinned by test_cr_c1_theNewFlagBitsAreContiguousAndDistinct
// because the shift depends on it.
//
// A MASK, not a latest-value nibble, and not a "worst seen" code. #165 calls
// the quality field a 0-4 reliability rating and NOTHING HERE KNOWS ITS
// POLARITY -- whether 4 means "trust this" or "disregard this" is not settled
// by anything this repository has read. A worst-seen encoding would have to
// assume one; a mask assumes nothing and lets the question be answered later
// from a row that has already been recorded.
//
// Q1..Q4 are the codes (payload[2] & 0x03) + 1 can produce. The
// PARENTHESISATION IS LOAD-BEARING: the vendor example #165 was read from writes
// `payload[2] & 0x03 + 1`, which under C-family precedence binds as
// `payload[2] & 4` -- their defect, deliberately not reproduced, and
// test_cr_c1_theQualityTableAvoidsTheVendorPrecedenceBug is what would catch it
// coming back.
const CT_DIAG_F_Q1        = 0x0010;
const CT_DIAG_F_Q2        = 0x0020;
const CT_DIAG_F_Q3        = 0x0040;
const CT_DIAG_F_Q4        = 0x0080;
// payload[2] == 0xFF: the pod's own "disregard this broadcast" marker. ITS OWN
// BIT rather than a fifth quality code, because it is an ABSENCE of a rating,
// not a rating -- the same distinction #86/#107 cost this repository twice, and
// the same reason decodeHsi returns null instead of 25.5.
const CT_DIAG_F_Q_NONE    = 0x0100;
// heartRateSupport = (payload[3] & 0xC0) >> 6, one bit per observed code.
// Per #165: 1 means the pod is REQUESTING a heart rate and is running its
// estimate without one; 2 means it has one. 0 and 3 are given no meaning by
// anything read for #165, so they are recorded and not interpreted.
//
// HR1 set on a row is the evidence for the transmit-path follow-up: it says the
// pod asked, on this row, and got no answer. NOTHING IN THIS BRANCH REPLIES --
// see the scope note on notePageZero.
const CT_DIAG_F_HR0       = 0x0200;
const CT_DIAG_F_HR1       = 0x0400;
const CT_DIAG_F_HR2       = 0x0800;
const CT_DIAG_F_HR3       = 0x1000;

// ---- #165: page 0x00, the general-information page --------------------------
//
// EVIDENCE CLASS FIRST, because it governs what may be written about these
// fields anywhere in the repository.
//
// The byte offsets, the masks and the 0xFF marker are DOCUMENT AGREEMENT with a
// single source: greenTEG's own Connect IQ example for this profile, read for
// facts only (it carries no licence file, and no code from it is in this
// repository). That example's last code commit predates CORE 2 entirely. The
// formally authoritative ANT+ device profile is behind an adopter login and was
// NOT read. NO CORE POD WAS INVOLVED. So nothing here or downstream may state
// what a pod transmits -- only what this code READS.
//
// It is a strictly weaker evidence class than page 1's, which at least has
// three independent decoders agreeing plus one real row of decodes behind it.
// That is precisely why this branch RECORDS these values into the diagnostic
// array and changes no decoded value, no clamp and no freshness window with
// them: if the layout is wrong, the cost is two meaningless flag bits.
const CT_PAGE_GENERAL     = 0x00;   // the page byte this block is about
const CT_PAGE_TEMPERATURE = 0x01;   // the page decodeCoreC/decodeSkinC read
const CT_PAGE0_Q_INVALID  = 0xFF;   // byte 2: "disregard this broadcast"

// Listens for a CORE (greenTEG) body-temperature pod over a generic ANT+
// channel (ANT+ Core Body Temperature profile, device type 127). Connect IQ's
// AntPlus module has no CBT profile and a watch app cannot host the official
// CORE data field, so the broadcast pages are decoded directly. ANT is
// broadcast, so listening here does not disturb other receivers paired to
// the same pod.
class CoreTempSensor {

    hidden const DEVICE_TYPE = 127;
    hidden const RF_FREQ = 57;
    hidden const PERIOD_A = 16384;   // 2 Hz
    hidden const PERIOD_B = 8192;    // 4 Hz, tried alternately while searching

    hidden var mChannel;
    hidden var mPeriod;
    hidden var mCore;
    hidden var mSkin;
    // #80. NULL, not 0.0, and that is the whole difference between this field
    // and the two above it. 0.0 is an ordinary Heat Strain Index meaning "no
    // thermal strain", so there is no in-domain value that can stand for "no
    // reading" -- a zero default would be indistinguishable from a real
    // measurement of zero strain at every layer that touched it.
    hidden var mHsi;
    hidden var mLastMs;
    hidden var mCoreMs;
    hidden var mSkinMs;
    hidden var mHsiMs;
    hidden var mEverSeen;
    // #122. "A broadcast frame has reached this sensor at some point during this
    // app run", which is the evidence the search pacing should turn on: it means
    // the carrier was TRACKED, so a pod is -- or was -- physically in range.
    //
    // DELIBERATELY NOT mEverSeen, and the difference is not cosmetic. mEverSeen
    // means "a temperature cleared the plausibility clamps", which is strictly
    // narrower: a pod broadcasting undonned is fully tracked while producing
    // nothing that clears them. And mEverSeen gates the PERIOD_A/PERIOD_B
    // alternation in onChannelClosed, so widening what sets it would change
    // radio behaviour on a path nothing in this repository can measure -- the
    // same argument the heat-strain block in onBroadcast makes for not touching
    // it either.
    //
    // Sticky for the life of the sensor; see the CT_BACKOFF_NEAR_MAX_MS block
    // for why, and for what that costs.
    hidden var mPodEverNear;
    hidden var mFails;
    hidden var mClosed;
    hidden var mRetryTimer;

    // #102 diagnostic counters. Plain Numbers, incremented bare on the ANT
    // callback path and clamped once at readout -- see the CT_DIAG_* block at
    // the top of this file. Named fields rather than one array so each
    // increment site names what it counts and costs a single field store.
    hidden var mDiagOpenAttempts;
    hidden var mDiagOpenOk;
    hidden var mDiagOpenThrow;
    hidden var mDiagMsgTotal;
    hidden var mDiagBcast;
    hidden var mDiagShortPay;
    hidden var mDiagPage1;
    hidden var mDiagPageOther;
    hidden var mDiagCoreOk;
    hidden var mDiagCoreSentinel;
    hidden var mDiagCoreClamp;
    hidden var mDiagSkinOk;
    hidden var mDiagSkinSentinel;
    hidden var mDiagSkinClamp;
    hidden var mDiagChanClosed;
    hidden var mDiagMaxFails;
    hidden var mDiagPageFirst;
    hidden var mDiagPageOtherLast;
    hidden var mDiagAcqPeriod;
    hidden var mDiagHsiOk;
    hidden var mDiagHsiInvalid;
    hidden var mDiagHsiMaxRaw;
    // #165. Page-0x00 frames reaching the decoder, and the OR of every
    // ctQualityBit/ctHrSupportBit ever observed on one. Accumulated rather than
    // latest-wins, and sticky like mDiagRetryLost, for the reason the
    // CT_DIAG_F_Q1 block gives: the question is which codes the pod ever
    // emitted, not which one it emitted last.
    hidden var mDiagPage0;
    hidden var mDiagPage0Flags;
    // Set once and never cleared when scheduleReopen could not arm a retry
    // timer; read out as CT_DIAG_F_RETRY_LOST. A plain Boolean rather than a
    // counter: one more slot would be a wire-format growth, and the question
    // this answers ("did the ladder stop?") is a yes/no.
    hidden var mDiagRetryLost;
    // Flags latched at close(), because shutdown() calls close() BEFORE
    // stopAndSave() (StrongRowView.shutdown) -- reading the live channel state
    // at readout would therefore always report "released, closed" and say
    // nothing about the state the session actually ended in. Negative means
    // "not latched", in which case the readout computes them live.
    hidden var mDiagFlags;

    function initialize() {
        mChannel    = null;
        mPeriod     = PERIOD_A;
        mCore       = 0.0;
        mSkin       = 0.0;
        mHsi        = null;      // #80: never 0.0 -- see the field declaration
        mLastMs     = 0;
        mCoreMs     = 0;
        mSkinMs     = 0;
        mHsiMs      = 0;
        mEverSeen   = false;
        mPodEverNear = false;    // #122
        mFails      = 0;
        mClosed     = false;
        mRetryTimer = null;
        // Diagnostics MUST be zeroed before openChannel() below: the
        // constructor's own open attempt is a real attempt and has to be
        // counted, so initialising after it would silently discard it.
        resetDiag();
        openChannel();
    }

    // Zero every diagnostic counter. Split out of initialize() so the ordering
    // note above is enforced by one call rather than by field order, and so a
    // test can re-baseline without reconstructing the sensor.
    hidden function resetDiag() {
        mDiagOpenAttempts  = 0;
        mDiagOpenOk        = 0;
        mDiagOpenThrow     = 0;
        mDiagMsgTotal      = 0;
        mDiagBcast         = 0;
        mDiagShortPay      = 0;
        mDiagPage1         = 0;
        mDiagPageOther     = 0;
        mDiagCoreOk        = 0;
        mDiagCoreSentinel  = 0;
        mDiagCoreClamp     = 0;
        mDiagSkinOk        = 0;
        mDiagSkinSentinel  = 0;
        mDiagSkinClamp     = 0;
        mDiagChanClosed    = 0;
        mDiagMaxFails      = 0;
        mDiagPageFirst     = $.CT_DIAG_NONE;
        mDiagPageOtherLast = $.CT_DIAG_NONE;
        mDiagAcqPeriod     = 0;
        mDiagHsiOk         = 0;
        mDiagHsiInvalid    = 0;
        mDiagHsiMaxRaw     = $.CT_DIAG_NONE;
        mDiagPage0         = 0;
        mDiagPage0Flags    = 0;
        mDiagRetryLost     = false;
        mDiagFlags         = -1;
    }

    // ---- pure helpers -------------------------------------------------------
    // All parameter-based and free of instance state, so they are (:test)-able
    // without an ANT channel, a Session, or a clock -- the same reason
    // StrongRowView's filterRr/packRr/rrIsFresh are statics. `now` is a
    // parameter, not System.getTimer(), so freshness tests are deterministic.

    // Is a timestamp `tsMs` fresh at `nowMs` within `threshMs`? Strict `<`; a
    // never-seen stamp (0 or negative) is not fresh. Mirrors rrIsFresh exactly.
    static function ctIsFresh(nowMs, tsMs, threshMs) {
        return tsMs > 0 && (nowMs - tsMs) < threshMs;
    }

    // Assemble the 12-bit skin-temperature field from its two source bytes:
    // byte 3 carries bits 0:7 and byte 4 bits 4:7 carry bits 8:11. Byte 4's low
    // nibble belongs to the Reserved field and must not leak in.
    static function skinRaw12(b3, b4) {
        return (b3 & 0xFF) | ((b4 & 0xF0) << 4);
    }

    // Sign-extend a 12-bit two's-complement value. The inner parentheses are
    // load-bearing: under C-style precedence `v & 0x800 == 0x800` binds as
    // `v & (0x800 == 0x800)`.
    static function sext12(v) {
        return ((v & 0x800) != 0) ? v - 4096 : v;
    }

    // Backoff before the next ANT search, given the number of consecutive
    // failed searches. The first CT_BURST_TRIES run back-to-back, then the
    // interval doubles to a cap -- so discovery stays exactly as fast as it is
    // today while a permanently absent pod stops holding the radio open.
    static function ctBackoffMs(fails) {
        if (fails < $.CT_BURST_TRIES) { return 0; }
        var ms = $.CT_BACKOFF_BASE_MS;
        for (var i = $.CT_BURST_TRIES; i < fails; i++) {
            ms = ms * 2;
            if (ms >= $.CT_BACKOFF_MAX_MS) { return $.CT_BACKOFF_MAX_MS; }
        }
        return ms;
    }

    // THE DELAY THE SHIPPING CODE ACTUALLY ASKS FOR (#122): the ladder above,
    // capped lower once a broadcast frame has been tracked this session. See the
    // CT_BACKOFF_NEAR_MAX_MS block at the top of this file for the duty
    // arithmetic and for what is and is not claimed about battery.
    //
    // A SEPARATE FUNCTION rather than a second parameter on ctBackoffMs, for two
    // reasons that are both about evidence. ctBackoffMs is #26's ladder and is
    // pinned by name in three places; leaving it byte-identical is what lets
    // test_cr_c0_theColdLadderIsUnchanged be a characterization pin rather than
    // a rewrite of one. And the clamp is the whole of the change, so it can be
    // read, tested and reverted on its own.
    //
    // #161'S BOUND SURVIVES BY CONSTRUCTION, not by inspection of a table. This
    // returns 0 if and only if ctBackoffMs returns 0: the clamp branch is
    // reachable only when ms is already ABOVE CT_BACKOFF_NEAR_MAX_MS, and it
    // returns CT_BACKOFF_NEAR_MAX_MS, which is positive. So the zero-delay
    // reopen -- the one that re-enters openChannel() from inside its own failure
    // handler -- still happens for exactly the first CT_BURST_TRIES failures and
    // never again, whatever podNear says.
    // test_cr_c1_theNearLadderNeverAsksForZeroPastTheBurst is the pin.
    static function ctSearchDelayMs(fails, podNear) {
        var ms = ctBackoffMs(fails);
        if (podNear && ms > $.CT_BACKOFF_NEAR_MAX_MS) { return $.CT_BACKOFF_NEAR_MAX_MS; }
        return ms;
    }

    // The listening DUTY, in parts per thousand, of a search that listens for
    // `searchMs` and then waits `idleMs` before listening again. Rounded to
    // nearest, so 9.1 % reads 91 rather than the 90 plain integer truncation
    // would give -- the figure #122 states, reproduced rather than approximated.
    //
    // It exists so the duty figures in this file's comments are EXECUTED by a
    // test instead of being hand arithmetic that a later edit to a constant
    // would silently falsify. That is the only thing it is for: it says nothing
    // about current draw, and a duty cycle is not a battery measurement.
    static function ctDutyPerMille(searchMs, idleMs) {
        var period = searchMs + idleMs;
        if (period <= 0) { return 0; }
        return (1000 * searchMs + period / 2) / period;
    }

    // Core temperature in C from a page-1 payload, or null when the frame
    // carries no usable value. This states what the code READS -- bytes 6-7
    // little endian, hundredths of a degree -- not what a pod is known to
    // transmit; nothing here has been measured on air (see #88).
    //
    // The 0xFFFF test does not match the marker the vendor table documents for
    // this field (0x8000). The CT_CORE_MIN_C..CT_CORE_MAX_C clamp below is what
    // actually rejects an invalid frame, and it admits only values where a
    // signed and an unsigned reading agree, so the divergence is unreachable
    // rather than merely harmless. See #87; no behaviour change is intended.
    // The raw 16-bit core field: bytes 6-7, little endian. Extracted (#102) so
    // the diagnostic sentinel classifier below and decodeCoreC read the SAME
    // expression -- two hand-copied assemblies is exactly how the two would
    // drift apart. Behaviour-preserving: the body is the line it replaces.
    static function coreRaw16(p) {
        return (p[6] & 0xFF) + 256 * (p[7] & 0xFF);
    }

    static function decodeCoreC(p) {
        var raw = coreRaw16(p);
        if (raw == 0xFFFF) { return null; }
        var t = raw * 0.01;
        if (t < $.CT_CORE_MIN_C || t > $.CT_CORE_MAX_C) { return null; }
        return t;
    }

    // The raw Heat Strain Index code point: page-1 byte 1, masked to eight
    // bits. Extracted for the same reason coreRaw16 was -- the decoder and the
    // diagnostic classifier must read the SAME expression, because two
    // hand-copied assemblies are exactly how the two drift apart.
    //
    // `& 0xFF` rather than a sign-extending read: see the CT_HSI_* block for
    // why that is a documented CHOICE between two readings of a self-
    // contradictory vendor table and not a settled fact.
    static function hsiRaw8(p) {
        return p[1] & 0xFF;
    }

    // Heat Strain Index in a.u. from a page-1 payload, or null when the frame
    // carries no usable value.
    //
    // This states what the code READS -- byte 1, tenths of an arbitrary unit,
    // with 0xFF as the invalid marker. It states nothing about what a pod
    // transmits; nothing here has been measured on air (#81).
    //
    // NULL, never a number, for the invalid case. The scale's whole domain is
    // legal: 0.0 means "no thermal strain", so the usual trick of returning a
    // physiologically impossible number as an in-band sentinel is unavailable.
    // Every caller therefore has to carry the absent case explicitly.
    //
    // The marker is tested BEFORE the scale is applied, mirroring
    // decodeSkinC's ordering. Here that ordering is not merely tidy: 0xFF * 0.1
    // is 25.5, which sits just outside the documented range and would be an
    // entirely plausible-looking reading -- the exact defect one of the
    // published implementations ships.
    static function decodeHsi(p) {
        var raw = hsiRaw8(p);
        if (raw == $.CT_HSI_INVALID) { return null; }
        return raw * $.CT_HSI_SCALE;
    }

    // ---- #102 diagnostic helpers -------------------------------------------
    // Pure, so they are (:test)-able without a channel and so the classifier
    // and the decoder cannot disagree about what a sentinel is.

    // Did decodeCoreC reject this payload because of the invalid marker rather
    // than the plausibility clamp? Only meaningful when decodeCoreC returned
    // null -- it does NOT re-check the clamp. The distinction cannot be
    // recovered from the return value (both are null), which is why #102 has
    // to ask the question separately instead of instrumenting the decoder and
    // changing its behaviour.
    static function ctCoreSentinel(p) {
        return coreRaw16(p) == 0xFFFF;
    }

    // The skin analogue. Tested on the RAW 12-bit pattern BEFORE sign
    // extension, for the same reason decodeSkinC does: afterwards 0x800 has
    // become -2048 and the comparison can never fire.
    static function ctSkinSentinel(p) {
        return skinRaw12(p[3], p[4]) == $.CT_SKIN_INVALID;
    }

    // ---- #165 page-0x00 field extraction ------------------------------------
    // Pure and parameter-based, so the whole of what this branch understands
    // about page 0x00 is (:test)-able without a channel, a clock or a pod --
    // which matters more here than anywhere else in this file, because the
    // layout rests on ONE unmeasured source (see the CT_PAGE_GENERAL block).

    // The pod's own data-quality code from a page-0x00 payload: 1..4, or NULL
    // when byte 2 is the 0xFF "disregard" marker.
    //
    // NULL, NOT A NUMBER, for the marker. Every value the expression can produce
    // is a legal rating, so there is no in-band code point that could stand for
    // "the pod told us not to trust this frame" -- the same argument decodeHsi
    // makes for its own scale, and the same trap (#86/#107) this repository has
    // fallen into twice by rendering absence as a value.
    //
    // THE PARENTHESES ARE LOAD-BEARING. The vendor example this layout was read
    // from writes `payload[2] & 0x03 + 1`, which under C-family precedence binds
    // as `payload[2] & (0x03 + 1)` -- i.e. `payload[2] & 4`, a completely
    // different function that returns 0 or 4 and never 1, 2 or 3. That is their
    // defect; it is not reproduced here, and
    // test_cr_c1_theQualityTableAvoidsTheVendorPrecedenceBug is the case that
    // separates the two functions on a code point where they disagree.
    static function ctPage0Quality(p) {
        var raw = p[2] & 0xFF;
        if (raw == $.CT_PAGE0_Q_INVALID) { return null; }
        return (raw & 0x03) + 1;
    }

    // The heart-rate-support code from a page-0x00 payload: byte 3, bits 6:7.
    //
    // Per #165, 1 means the pod is REQUESTING a heart rate and is running its
    // core-temperature estimate without one, and 2 means it has one. 0 and 3
    // are given no meaning by the source this was read from, so they are
    // recorded and not interpreted.
    //
    // The shift is applied to the MASKED byte, and the mask is parenthesised,
    // for the reason stated on sext12: `p[3] & 0xC0 >> 6` would bind as
    // `p[3] & (0xC0 >> 6)` = `p[3] & 3` and read the UTC-request field instead.
    static function ctPage0HrSupport(p) {
        return (p[3] & 0xC0) >> 6;
    }

    // The CT_DIAG_I_FLAGS bit for a quality code, or 0 for anything outside
    // 1..4 (including the null the marker produces). The shift depends on
    // CT_DIAG_F_Q1..Q4 being contiguous, which
    // test_cr_c1_theNewFlagBitsAreContiguousAndDistinct pins.
    static function ctQualityBit(q) {
        if (q == null || q < 1 || q > 4) { return 0; }
        return $.CT_DIAG_F_Q1 << (q - 1);
    }

    // The CT_DIAG_I_FLAGS bit for a heart-rate-support code, or 0 outside 0..3.
    // The range guard is not decorative: the extractor above masks to two bits
    // so it cannot exceed 3 today, and this function must stay total if a future
    // edit widens the field.
    static function ctHrSupportBit(h) {
        if (h == null || h < 0 || h > 3) { return 0; }
        return $.CT_DIAG_F_HR0 << h;
    }

    // Clamp a counter into the UINT16 range for the ct_diag field. Applied
    // once at readout rather than per increment, so the ANT callback path
    // carries no saturation test -- see the CT_DIAG_* block. A value that
    // saturates reads as "at least CT_DIAG_MAX", never as a wrapped number.
    static function ctDiagClamp(v) {
        if (v == null)         { return 0; }
        if (v < 0)             { return 0; }
        if (v > $.CT_DIAG_MAX) { return $.CT_DIAG_MAX; }
        return v;
    }

    // Skin temperature in C from a page-1 payload, or null when the frame
    // carries no usable value.
    //
    // This states what the code READS: byte 3 plus byte 4 bits 4:7 as a 12-bit
    // signed field, scaled by 1/20 (0.05 C), with 0x800 as the invalid marker.
    // Nothing here has been measured on air -- the layout is document agreement
    // across the vendor's own Connect IQ sample and two independent third-party
    // decoders, not an observation. See #88.
    //
    // Previously this read bytes 4-5 and scaled by 0.01, which is the Reserved
    // field plus skin's top nibble: the result barely moved with real skin
    // temperature (25.60 C and 38.30 C both decoded to the same number) and
    // tracked Reserved instead. #86.
    //
    // Two traps, both present in the published implementations and both avoided
    // here. The invalid marker is tested on the RAW 12-bit pattern BEFORE sign
    // extension -- afterwards 0x800 has become -2048, and a comparison against
    // -32768 can never fire. And every & used in a boolean context is fully
    // parenthesised, because `v & 0x800 == 0x800` binds as `v & (0x800 == 0x800)`.
    static function decodeSkinC(p) {
        var raw = skinRaw12(p[3], p[4]);
        if (raw == $.CT_SKIN_INVALID) { return null; }
        var s = sext12(raw) / 20.0;
        // Plausibility clamp, retained. It is no longer the thing that rejects
        // the invalid marker, but it is the only defence against a layout that
        // has not been measured. A clamp rejection leaves mSkin untouched AND
        // leaves mSkinMs unstamped, so skinTemp() reports 0.0 rather than
        // republishing a stale reading as fresh -- which is why this and the
        // per-field stamps must ship together.
        if (s < $.CT_SKIN_MIN_C || s > $.CT_SKIN_MAX_C) { return null; }
        return s;
    }

    // ---- channel lifecycle --------------------------------------------------

    // Allocation split out so a test can substitute a channel it controls: the
    // real constructor always throws "Unable to acquire ANT Channel" under the
    // headless simulator, so without this seam no test can reach the code that
    // runs after a successful allocation.
    hidden function makeChannel() {
        return new Ant.GenericChannel(method(:onMessage),
            new Ant.ChannelAssignment(Ant.CHANNEL_TYPE_RX_NOT_TX, Ant.NETWORK_PLUS));
    }

    // Release the channel if we hold one, and drop the reference. Shared by
    // close() and, from the #18 commit, the failure path -- so the release rule
    // exists in exactly one place.
    hidden function discardChannel() {
        if (mChannel != null) {
            try { mChannel.release(); } catch (e) {}
            mChannel = null;
        }
    }

    hidden function openChannel() {
        mDiagOpenAttempts++;
        try {
            if (mChannel == null) {
                mChannel = makeChannel();
            }
            // setDeviceConfig() ALSO returns a documented Boolean ("Returns
            // Boolean true on success, otherwise false" -- SDK 9.2.0
            // api.debug.xml), and so does release(), called from
            // discardChannel(). Neither return is counted, and that is a
            // decision rather than an oversight:
            //
            //   * every free slot would be a NEW slot, and a new slot is a
            //     wire-format change requiring a CT_DIAG_VERSION bump -- not
            //     something to fold into a revision of the counter whose
            //     meaning was just corrected;
            //   * folding a false setDeviceConfig into openOk would redefine
            //     openOk a second time, silently, with no version change to
            //     signal it -- worse for a reader of an existing file than
            //     leaving the gap visible here.
            //
            // The consequence, stated so it is not rediscovered as a surprise:
            // a config that quietly fails and is then followed by an open()
            // returning true reads as openOk > 0. That is a KNOWN BLIND SPOT of
            // this layout, tracked separately; it is not covered by the
            // quiet-failure arithmetic above, which sees only open().
            mChannel.setDeviceConfig(new Ant.DeviceConfig({
                :deviceNumber => 0,              // wildcard: first pod found
                :deviceType => DEVICE_TYPE,
                :transmissionType => 0,
                :messagePeriod => mPeriod,
                :radioFrequency => RF_FREQ,
                // #122: the constant, not a literal with a
                // comment claiming what it means. CT_SEARCH_WINDOW_MS is
                // derived from it and is what the duty arithmetic reads.
                :searchTimeoutLowPriority => $.CT_SEARCH_TIMEOUT_LP,
                :searchThreshold => 0
            }));
            // Ant.GenericChannel.open() reports failure TWO ways: it throws,
            // and it returns false ("Returns Boolean true on success,
            // otherwise false" -- SDK 9.2.0 api.debug.xml). #102 counted only
            // the first, so a channel that failed quietly was recorded as a
            // success and produced a snapshot identical in all 21 slots to a
            // row with no pod in range -- the key would have named the wrong
            // hypothesis, inside the discriminator built to prevent exactly
            // that.
            //
            // #103 counted this return and DELIBERATELY DID NOT ACT ON IT --
            // "no retry is scheduled, no channel released, nothing that was not
            // done before" -- which was the right scope for a diagnostics change
            // and left the recovery gap #151 was filed on.
            //
            // #151 CLOSES IT: a false return is answered exactly as a throw is,
            // through the SAME handler. See the note on noteOpenFailure. Two
            // things the gap cost, both fixed by that one call:
            //
            //   * the retry ladder never engaged. Nothing else can re-enter
            //     openChannel(): no MSG_CODE_EVENT_CHANNEL_CLOSED can arrive on
            //     a channel that never opened, and onChannelClosed is the only
            //     other route in. CORE was dead for the rest of the app run,
            //     with nothing on the screen to say so.
            //   * mChannel stayed non-null, so the `if (mChannel == null)` guard
            //     above would hand the channel that just failed straight back to
            //     the next attempt. Releasing it matters as much as scheduling
            //     the retry, and noteOpenFailure does both, in that order.
            //
            // NOT MEASURED: whether open() ever actually returns false on this
            // path. There is no ANT radio in any environment this repository
            // can run, so the false-return branch has never been observed -- the
            // API documents it and the pre-#103 code assumed it away.
            // i174014735's open_attempts 13 against open_ok 12 is a residual of
            // one that is CONSISTENT with it and does not prove it.
            var opened = mChannel.open();

            // #102: reached only when nothing above threw. openAttempts minus
            // openOk is not the throw count -- openThrow is counted explicitly
            // below -- because that difference has to stay readable even if a
            // future edit adds a return path between here and the catch.
            //
            // attempts - openOk - openThrow is STILL exactly the quiet-failure
            // count after #151, and only its magnitude moves: every retry a
            // quiet failure now causes is another attempt with no openOk and no
            // openThrow, so the residual counts all of them rather than the
            // single one that used to end the run.
            if (opened) {
                mDiagOpenOk++;
            } else {
                noteOpenFailure();
            }
        } catch (e) {
            // #102: the counter this issue was filed on. This catch was
            // completely silent, so a channel that could never be acquired and
            // a channel that opened and heard nothing left identical files.
            //
            // Counted HERE rather than inside noteOpenFailure(): openThrow means
            // "the catch was entered", and the handler below is shared with a
            // failure that does not throw. Folding the increment into the shared
            // handler would redefine slot 3 silently, which is the exact defect
            // the openOk key was corrected for.
            mDiagOpenThrow++;
            noteOpenFailure();
        }
    }

    // THE SINGLE ANSWER TO A FAILED OPEN, extracted (#151) so that the two ways
    // Ant.GenericChannel.open() can fail cannot drift apart. Behaviour-
    // preserving at the commit that introduces it: the body is exactly the four
    // statements it replaces, in the same order, and openChannel's catch is its
    // only caller. What changes later is that a SECOND caller appears.
    //
    // Hand the channel back before dropping the reference. ANT channels are a
    // scarce hardware resource, and the `if (mChannel == null)` guard in
    // openChannel only protects the ALLOCATION -- setDeviceConfig() and open()
    // run on every call, so a failure on the re-search path leaves an
    // already-assigned channel behind too. Once the reference is gone close()
    // can no longer release it. #18.
    //
    // ...and schedule a retry, because releasing alone fixes the leak but not
    // the outage: afterwards mChannel is null, so no further CHANNEL_CLOSED can
    // arrive and nothing re-enters openChannel() -- CORE would stay dead for the
    // rest of the app run. This is also why #18 and #26 had to ship together:
    // the ladder re-enters openChannel(), which against the un-fixed catch would
    // have turned a one-shot leak into one orphaned channel per retry.
    //
    // THE RECURSION BOUND LIVES HERE and is arithmetic, not structural.
    // scheduleReopen(0) calls openChannel() straight back, and the chain unwinds
    // only because mFails rises on every pass and the ladder stops returning 0
    // once the burst is spent -- so the depth is capped at CT_BURST_TRIES
    // frames. #161 is the stack overflow that happened when a path could ask for
    // an immediate reopen forever. Any new caller of this function inherits that
    // bound and must be pinned against it.
    hidden function noteOpenFailure() {
        discardChannel();
        mFails++;
        // #102 high-water mark. mFails is reset to 0 by a tracked frame, so at
        // save time it carries the CURRENT ladder depth and says nothing about
        // the depth reached. Two copies of this line exist (here and in
        // onChannelClosed) because mFails is incremented in exactly those two
        // places; keep them together.
        if (mFails > mDiagMaxFails) { mDiagMaxFails = mFails; }
        // #122. Once a broadcast frame has been tracked this session the ladder
        // is capped at CT_BACKOFF_NEAR_MAX_MS instead of CT_BACKOFF_MAX_MS --
        // see the block at the top of this file for the duty arithmetic and for
        // what is and is not claimed about battery.
        scheduleReopen(ctSearchDelayMs(mFails, mPodEverNear));
    }

    // Allocation split out so a test can substitute a timer it controls --
    // exactly the seam makeChannel() above is, and for a sharper reason than
    // symmetry. CoreProbe (CoreTempSensorTest.mc) overrides scheduleReopen
    // wholesale, and its own comment says why: "a real Timer breaks that cycle
    // by deferring". That holds whenever the Timer WORKS, which is precisely
    // why no existing test can reach the catch that runs when it does not --
    // nothing in this repository can make Timer.start() fail, and a test that
    // let the real Timer arm would leave a live callback firing back into
    // openChannel() thirty seconds later, in the middle of some other suite.
    hidden function makeRetryTimer() {
        return new Timer.Timer();
    }

    // Re-open the channel after `delayMs`. A zero delay reopens synchronously,
    // which is what the first CT_BURST_TRIES searches do, so discovery keeps
    // exactly today's timing. A non-zero delay defers via a one-shot timer,
    // which is what stops a permanently absent pod from holding the radio open.
    hidden function scheduleReopen(delayMs) {
        if (mClosed) { return; }
        cancelReopen();
        if (delayMs <= 0) {
            // The burst, reopening now so discovery keeps exactly the timing it
            // had before #26. This IS a re-entry into openChannel() from inside
            // openChannel()'s own catch, and it unwinds only because mFails
            // rises on every pass and ctBackoffMs stops returning 0 once the
            // burst is spent -- an ARITHMETIC bound, capped at CT_BURST_TRIES
            // frames, not a structural one. It therefore has a test standing in
            // front of it: RetryBound.test_rb_c0_onlyTheBurstEverAsksForZeroDelay.
            openChannel();
            return;
        }
        try {
            mRetryTimer = makeRetryTimer();
            mRetryTimer.start(method(:onRetry), delayMs, false);
        } catch (e) {
            // Hand the timer back before dropping the reference -- the rule #18
            // states for the ANT channel, applied to the other scarce resource
            // this class allocates. cancelReopen() is where that rule already
            // lives for timers, so it is REUSED rather than restated, the same
            // way discardChannel() is shared by close() and #18's failure path.
            // It matters beyond tidiness: a start() that threw may still have
            // armed the timer, and `mRetryTimer = null` would leave that
            // callback live with nothing able to stop it -- including close().
            cancelReopen();

            // AND DELIBERATELY DO NOT REOPEN. This line used to be
            // openChannel(), and that was an UNBOUNDED MUTUAL RECURSION:
            // openChannel()'s catch calls this function, this function called
            // openChannel() back, and this branch is reachable only at
            // mFails >= CT_BURST_TRIES where ctBackoffMs never returns 0 again
            // -- so the ladder could never break the cycle by growing. MEASURED
            // on fr965 / SDK 9.2.0: the simulator aborts with "Error: Stack
            // Overflow Error / Details: Failed invoking <symbol>" on a stack
            // alternating scheduleReopen and openChannel down to initialize().
            // initialize() is reached from onLayout, so the app DIES at the
            // start of the row and the recording goes with it. The comment that
            // stood here reasoned correctly that dropping the retry leaves CORE
            // dead, and then made the wrong trade: it exchanged a dead heat
            // sensor for a dead application.
            //
            // WHAT IS LOST, stated rather than hidden: this retry, and with it
            // in practice every later one. When the catch was entered from
            // openChannel() the channel is already discarded, so no further
            // CHANNEL_CLOSED can arrive and nothing else re-enters
            // openChannel(); when it was entered from onChannelClosed() the
            // search has ended and will not re-arm itself. Either way CORE
            // temperature, skin temperature and the heat index are absent for
            // the rest of the app run. That is one row's heat trace against the
            // whole activity, and the priority order says which way to fall: an
            // app that does not crash comes first.
            //
            // AND IT IS NOT SILENT. CT_DIAG_F_RETRY_LOST is set here and nowhere
            // else, and diagSnapshot() ORs it into slot CT_DIAG_I_FLAGS -- so a
            // reader gets "the ladder stopped for want of a timer" as positive
            // evidence instead of inferring it from an openAttempt that never
            // came. Read it with the neighbouring counters: with openOk == 0 the
            // channel never opened at all, and with openOk > 0 and
            // chanClosed > 0 the pod was being searched for and the search was
            // not re-armed. A bit, not a new slot, so the array length -- and
            // the createField `:count` that must match it -- does not move.
            //
            // Scope of that claim, because this file is strict about it: what is
            // asserted here is what the CODE WRITES. That slot 17 reaches a
            // saved file at all is the simulator measurement recorded in the
            // CT_DIAG_* block above (fr965 / SDK 9.2.0, decoded with fitparse);
            // this particular bit has never been seen in a decoded file, and
            // whether a real watch agrees is #77's question, not an assumption
            // made here.
            //
            // NOT MEASURED, and not claimed: whether Timer.start() ever fails
            // here on a watch. The one real-row ct_diag readout available (#122)
            // reached this branch with 22 of 22 opens succeeding, so neither
            // failing resource has been seen in the field. This is a defensive
            // fix on a path that is reachable by construction and whose
            // pre-fix outcome is measured above.
            mDiagRetryLost = true;
        }
    }

    function onRetry() as Void {
        mRetryTimer = null;
        if (mClosed) { return; }
        openChannel();
    }

    // Cancel a pending reopen.
    hidden function cancelReopen() {
        if (mRetryTimer != null) {
            try { mRetryTimer.stop(); } catch (e) {}
            mRetryTimer = null;
        }
    }

    // ---- message handling ---------------------------------------------------

    function onMessage(msg as Ant.Message) as Void {
        // #102: every ANT message, before any dispatch -- the counter that
        // says the radio produced traffic at all.
        //
        // CORROBORATING, not load-bearing. openOk alone separates "the channel
        // opened and nothing broadcast" from "the channel never opened": if a
        // real podless row turns out to deliver no channel-response events at
        // all, the first reads (openOk > 0, 0, 0) and the second still reads
        // (0, 0, 0). That matters because whether a podless row generates
        // those events on-watch is NOT measured -- see the readout key.
        mDiagMsgTotal++;
        var id = msg.messageId;
        if (id == Ant.MSG_ID_BROADCAST_DATA) {
            onBroadcast(msg.getPayload());
        } else if (id == Ant.MSG_ID_CHANNEL_RESPONSE_EVENT) {
            var p = msg.getPayload();
            if (p == null || p.size() < 2) { return; }
            if ((p[0] & 0xFF) == Ant.MSG_ID_RF_EVENT
                && (p[1] & 0xFF) == Ant.MSG_CODE_EVENT_CHANNEL_CLOSED) {
                onChannelClosed();
            }
        }
    }

    // Decode one broadcast payload. Split out of onMessage so a test can feed
    // synthetic bytes directly at the decoder.
    hidden function onBroadcast(p) {
        // #102. Counted here rather than in onMessage's broadcast branch so
        // that bcast means "a broadcast payload reached the decoder", which is
        // the same number either way and is reachable from a test that feeds
        // bytes directly.
        mDiagBcast++;
        // The period a frame FIRST arrived on -- #84 asks whether the 4 Hz
        // PERIOD_B fallback ever acquires, and mPeriod keeps alternating while
        // nothing has been seen, so its value at save time is the last period
        // TRIED. Set before the guards below: a payload arriving at all means
        // the carrier was tracked, however unusable its contents.
        if (mDiagAcqPeriod == 0) { mDiagAcqPeriod = mPeriod; }

        // #122, set for the same reason and at the same place: a payload
        // arriving at all means the carrier was tracked, however unusable its
        // contents, so this is the earliest honest point for "a pod is in
        // range".
        mPodEverNear = true;

        // #122. THE SEARCH PACING RESETS HERE, above every guard below it.
        //
        // It used to sit after the page-0x01 test, so only a temperature frame
        // cleared it. That was too narrow twice over, and this comment used to
        // argue only the first of the two:
        //
        //   * it is not about an ACCEPTED reading. A pod broadcasting undonned
        //     is fully tracked while producing nothing that clears the
        //     plausibility clamps. (That much the old placement already got
        //     right, and it is preserved.)
        //   * it is not about the PAGE either, and that is the correction.
        //     mFails counts consecutive FAILED SEARCHES -- it is the ladder's
        //     input, and the ladder paces the search. A payload arriving at all
        //     means the search FOUND the pod, whatever page the frame carried.
        //     A pod broadcasting only the general-information page (#165) left
        //     the ladder climbing to five minutes while its frames were
        //     arriving.
        //
        // Deliberately above the length guard too: a null or short payload still
        // reached onBroadcast, which means the radio delivered a broadcast on
        // this channel, which means the search succeeded. Counting that as a
        // failed search would be counting the frame's contents, not the search.
        mFails = 0;

        if (p == null || p.size() < 8) { mDiagShortPay++; return; }

        // Behaviour-identical to the single expression this replaces; the local
        // exists so the page byte can be recorded as well as tested. A
        // truncated frame and a wrong page are counted separately because they
        // point at different defects.
        var page = p[0] & 0xFF;
        if (mDiagPageFirst == $.CT_DIAG_NONE) { mDiagPageFirst = page; }
        if (page != $.CT_PAGE_TEMPERATURE) {     // CBT data page 1 only
            mDiagPageOther++;
            mDiagPageOtherLast = page;
            // #165. Page 0x00 stays counted above -- slot 8's key is "page byte
            // != 0x01" and must keep meaning that, or every key ever written
            // against an already-recorded file changes under a reader's feet.
            // What is added is a SECOND, narrower record, so pageOther - page0
            // is the count of pages that are still genuinely unknown.
            if (page == $.CT_PAGE_GENERAL) { notePageZero(p); }
            return;
        }
        mDiagPage1++;

        var now = System.getTimer();

        // Each field stamps its OWN clock, inside its own acceptance gate. The
        // stamp used to live only inside the core-valid branch, so a frame with
        // valid skin but invalid or implausible core advanced nothing:
        // skinTemp() returned 0.0, everSeen() stayed false, and the skin FIT
        // field was never created. #17.
        //
        // Separate stamps rather than one shared clock advanced by either
        // field, which is the other option #17 offers: with a shared clock a
        // valid core frame would keep republishing a stale mSkin as fresh every
        // time the skin field was rejected -- a staleness lie that does not
        // exist today and must not be introduced while fixing this.
        var c = decodeCoreC(p);
        if (c != null) {
            mDiagCoreOk++;
            mCore     = c;
            mCoreMs   = now;
            mLastMs   = now;
            mEverSeen = true;
        } else if (ctCoreSentinel(p)) {
            // #102: decodeCoreC returns null for BOTH the invalid marker and a
            // clamp rejection, so the cause has to be recovered here. The
            // classifier calls coreRaw16 -- the same assembly the decoder uses
            // -- so the two cannot disagree about what the marker is. Runs only
            // on the rejection path, and changes nothing the decoder decided.
            mDiagCoreSentinel++;
        } else {
            mDiagCoreClamp++;
        }

        var s = decodeSkinC(p);
        if (s != null) {
            mDiagSkinOk++;
            mSkin     = s;
            mSkinMs   = now;
            mLastMs   = now;
            mEverSeen = true;
        } else if (ctSkinSentinel(p)) {
            mDiagSkinSentinel++;
        } else {
            mDiagSkinClamp++;
        }

        // #80: the heat strain index, on its own stamp for the reason the
        // core/skin split above states -- warm-up is exactly when a pod is
        // most likely to withhold a core temperature and exactly when a strain
        // index is most interesting, so coupling the two would lose the field
        // where it matters most.
        //
        // TWO THINGS IT DELIBERATELY DOES NOT DO, both scope boundaries rather
        // than omissions:
        //
        //   * it does not set mEverSeen. That flag gates the ANT search
        //     period's alternation in onChannelClosed, and widening it would
        //     change radio behaviour on a path nothing in this repository can
        //     measure. It costs nothing here: the FIT field is created behind
        //     coreFieldsWanted, which does not consult everSeen (#75).
        //   * it does not touch mLastMs, which no code reads -- it has been
        //     write-only since #17 split the stamps. A fourth writer to a dead
        //     field would be noise, and the two that exist are left alone
        //     rather than tidied as a side effect of this feature.
        //
        // The rejection branch stamps NOTHING, which is what keeps "no heat
        // index yet" distinct from "the last one, republished as current".
        var hs = decodeHsi(p);
        if (hs != null) {
            mDiagHsiOk++;
            // Running maximum of the ACCEPTED raw, so the invalid marker can
            // never be counted as an observation. The CT_DIAG_NONE test comes
            // first because that marker (0xFFFF) is numerically above every
            // reachable raw, so a bare `>` would never replace it.
            var raw = hsiRaw8(p);
            if (mDiagHsiMaxRaw == $.CT_DIAG_NONE || raw > mDiagHsiMaxRaw) {
                mDiagHsiMaxRaw = raw;
            }
            mHsi   = hs;
            mHsiMs = now;
        } else {
            mDiagHsiInvalid++;
        }
    }

    // #165: record what a page-0x00 (general information) frame said about
    // itself. Called only from onBroadcast's non-page-1 branch, on a payload
    // already known to be at least 8 bytes long.
    //
    // READ-ONLY, AND THAT IS THE SCOPE BOUNDARY RATHER THAN AN OMISSION. The
    // pod uses these fields to ASK for things -- a heart rate for its own
    // core-temperature estimate, and a UTC time -- and answering means sending
    // an acknowledged message, which is a TRANSMIT path on the ANT channel.
    // Nothing in this class has ever transmitted. That change is materially
    // bigger than this one, carries its own risks, and needs a real row to
    // validate; it has its own issue. What this function does is make the ask
    // VISIBLE in the saved file, which is the thing that was missing: a reader
    // could not previously tell that the pod had been running its estimate
    // without a heart rate the watch had all along.
    //
    // THE UTC-REQUEST FIELD, byte 3 bits 2:3, is deliberately not extracted.
    // It is the same shape of ask, it would need the same transmit path to
    // answer, and recording it would spend two more flag bits on a question the
    // follow-up issue owns. It is named in that issue instead.
    //
    // NOTHING HERE FEEDS A DECODED VALUE, A CLAMP OR A FRESHNESS WINDOW. The
    // page-0x00 layout rests on one unmeasured source (see the CT_PAGE_GENERAL
    // block); if it is wrong, the cost is two meaningless flag bits and a
    // correct frame count.
    hidden function notePageZero(p) {
        mDiagPage0++;
        // The quality code, or null when the pod said to disregard the frame.
        // The null case gets its OWN bit rather than a code, because it is an
        // absence of a rating and not a rating -- ctQualityBit answers 0 for it,
        // so the OR below cannot smuggle it in as a value.
        var q = ctPage0Quality(p);
        if (q == null) {
            mDiagPage0Flags |= $.CT_DIAG_F_Q_NONE;
        } else {
            mDiagPage0Flags |= ctQualityBit(q);
        }
        // ...and which heart-rate-support state the pod reported. Accumulated,
        // not latest-wins: the question a reader has is which states occurred
        // during the row, and "the pod asked for a heart rate at some point" is
        // exactly the evidence the transmit follow-up needs.
        mDiagPage0Flags |= ctHrSupportBit(ctPage0HrSupport(p));
    }

    // Search timed out or the pod dropped.
    //
    // This used to be `if (mEverSeen || mTries < 3)`, and BOTH branches were
    // wrong. Post-acquisition the left disjunct was permanently true, so the
    // channel re-searched forever with no backoff -- ~30 s of radio per cycle,
    // continuing through stopAndSave() until the app exited. Pre-acquisition,
    // mTries allowed one open plus three retries and then permanent silence at
    // ~120 s, so donning a pod after rigging yielded no CORE data for the whole
    // session.
    //
    // The fix is a DUTY-CYCLE bound, not an attempt-count bound. An attempt cap
    // is what made the pre-acquisition branch broken in the first place;
    // replacing one cap with a larger cap would only move the threshold. The
    // ladder paces retries instead, and never gives up:
    //
    //   searches at 0-30, 30-60, 60-90, 90-120 s  -- identical to today --
    //   then 150-180, 240-270, 390-420, 660-690, 990-1020, every 330 s after.
    //
    // A pod donned at t=5 min is acquired in the 390-420 s window where today
    // it never would be, and steady-state radio duty after a permanent loss
    // falls from ~100 % to 30/330 = 9.1 %. Battery drain in mAh is NOT measured
    // and is not claimed; this is a duty-cycle argument only.
    //
    // A recording-state gate is deliberately NOT added here: it needs a
    // lifecycle hook in StrongRowView, which is #11's coordination point.
    hidden function onChannelClosed() {
        if (mClosed) { return; }
        // #102: counted after the mClosed guard, so this means "a search timed
        // out or the pod dropped and we re-armed", not "a close event arrived
        // after shutdown".
        mDiagChanClosed++;
        mFails++;
        // See the note on the identical pair in openChannel's catch.
        if (mFails > mDiagMaxFails) { mDiagMaxFails = mFails; }
        if (!mEverSeen) {
            mPeriod = (mPeriod == PERIOD_A) ? PERIOD_B : PERIOD_A;
        }
        // #122. The site that matters most: this is the post-loss re-search, and
        // it is where the 9.1 % duty was measured. See noteOpenFailure.
        scheduleReopen(ctSearchDelayMs(mFails, mPodEverNear));
    }

    // ---- accessors ----------------------------------------------------------
    // The *At(nowMs) forms take the clock as a parameter so tests are
    // deterministic; the public no-argument forms are the shipping API.

    hidden function coreFreshAt(nowMs) { return ctIsFresh(nowMs, mCoreMs, $.CT_FRESH_MS); }
    hidden function skinFreshAt(nowMs) { return ctIsFresh(nowMs, mSkinMs, $.CT_FRESH_MS); }
    // #80. Its OWN stamp and the SAME window, for the reason #17 gives for the
    // core/skin split: a shared clock advanced by either field would let a
    // valid core frame keep republishing a stale heat index as current every
    // time byte 1 was withheld. And the window is CT_FRESH_MS, the one #19
    // unified, so the getter and any indicator built on it can never disagree
    // about what "current" means.
    hidden function hsiFreshAt(nowMs) { return ctIsFresh(nowMs, mHsiMs, $.CT_FRESH_MS); }

    hidden function coreTempAt(nowMs) {
        return coreFreshAt(nowMs) ? mCore : 0.0;
    }

    hidden function skinTempAt(nowMs) {
        return skinFreshAt(nowMs) ? mSkin : 0.0;
    }

    // #80. Returns NULL when there is no current heat index -- deliberately not
    // the 0.0 that coreTempAt/skinTempAt return, and the divergence is the
    // point rather than an inconsistency to tidy away. 0.0 C is impossible, so
    // a temperature getter can use it as an out-of-band "nothing here"; 0.0
    // a.u. is an ordinary reading, so the same shape here would emit a
    // fabricated "no thermal strain" for every dropout and for every podless
    // row. Null is the only absence this scale has.
    hidden function heatIndexAt(nowMs) {
        return hsiFreshAt(nowMs) ? mHsi : null;
    }

    // ONE freshness definition, shared with the getters. This used to test a
    // hard-coded 15000 while coreTemp()/skinTemp() used CT_FRESH_MS, so between
    // 15 s and 30 s stale the CT pip greyed out while onTick was still writing
    // that same reading to the FIT as current (#19).
    //
    // Unified UP to CT_FRESH_MS rather than pulling the getters down: pulling
    // them down would start writing 0.0 fifteen seconds sooner, which is #13's
    // defect made worse to fix this one. The cost is that the pip's
    // dropout-detection latency doubles, 15 s -> 30 s, and the pip is the only
    // CORE indicator on the display.
    //
    // Pod-level (either field fresh), matching the pip's own "a CORE pod's data
    // is fresh". #13 must NOT gate both setData calls on this: use coreFresh()
    // for the core field and skinFresh() for the skin field, or a skin-only
    // frame licenses a core_temperature = 0.0 write.
    hidden function isFreshAt(nowMs) {
        return coreFreshAt(nowMs) || skinFreshAt(nowMs);
    }

    function coreFresh() { return coreFreshAt(System.getTimer()); }
    function skinFresh() { return skinFreshAt(System.getTimer()); }
    function hsiFresh()  { return hsiFreshAt(System.getTimer()); }

    function coreTemp() { return coreTempAt(System.getTimer()); }
    function skinTemp() { return skinTempAt(System.getTimer()); }
    // #80. DELIBERATELY NOT folded into isFresh() above: that predicate means
    // "this pod's TEMPERATURE data is current" and is what the CT indicator
    // renders. Heat strain is a separate quantity that the same frame can carry
    // or withhold independently, so widening isFresh() would make one indicator
    // answer two questions and leave neither answerable. The heat-strain
    // indicator reads this getter instead.
    function heatIndex() { return heatIndexAt(System.getTimer()); }
    function isFresh()  { return isFreshAt(System.getTimer()); }

    function everSeen() { return mEverSeen; }

    // ---- #102 diagnostic readout --------------------------------------------

    // Terminal channel state as a bit set. Live form; close() latches it (see
    // mDiagFlags) because shutdown() releases the channel before stopAndSave
    // reads the counters.
    hidden function diagFlagsNow() {
        var f = 0;
        if (mChannel != null) { f |= $.CT_DIAG_F_CHANNEL_HELD; }
        if (mClosed)          { f |= $.CT_DIAG_F_CLOSED; }
        if (mEverSeen)        { f |= $.CT_DIAG_F_EVER_SEEN; }
        // Unlike the three above, this one is not a live reading of state: it
        // is already sticky, so latching it at close() loses nothing.
        if (mDiagRetryLost)   { f |= $.CT_DIAG_F_RETRY_LOST; }
        // #165: already sticky, so latching it at close() loses nothing --
        // exactly the argument the line above makes for itself.
        f |= mDiagPage0Flags;
        return f;
    }

    // ---- reading a ct_diag tuple -------------------------------------------
    //
    // The discriminator is (openOk, msgTotal, bcast). Each row states what the
    // COUNTERS OBSERVED; the equipment verdict in brackets is the inference a
    // reader draws, and is only as good as the alternatives having been
    // excluded. Keeping those two apart is not pedantry -- stating the
    // inference as though it were the observation is how a channel whose
    // open() returned false came to be recorded as "no pod".
    //
    //   (0,  0,  0)  nothing opened, nothing arrived
    //                [the channel could not be acquired; openThrow and
    //                 maxFails say how hard it tried]
    //   (>0, >0,  0)  the channel opened, the radio produced traffic, nothing
    //                 broadcast on it  [no pod in range]
    //   (>0, >0, >0)  the channel opened and frames arrived  [something
    //                 broadcast and was discarded] -- then shortPay, or
    //                 pageOther with pageFirst/pageOtherLast naming the actual
    //                 page byte, or the four core/skin reason slots, say which
    //                 gate dropped it
    //
    // openOk is the load-bearing leg: it alone separates the first two rows.
    // The separation therefore does NOT depend on the unmeasured premise that
    // a podless row generates channel-response events -- if it generates none,
    // row two reads (>0, 0, 0) and is still distinct from row one. msgTotal
    // corroborates.
    //
    // A fourth reading exists and is not in the table because it is not a
    // hypothesis about the pod: openOk > 0 with msgTotal == 0 AND
    // chanClosed == 0 means the channel opened and then went silent. The retry
    // ladder is predicated on MSG_CODE_EVENT_CHANNEL_CLOSED arriving, so if it
    // never does the ladder never advances. That has not been measured either;
    // it is left visible rather than assumed away.
    //
    // The whole diagnostic state as one CT_DIAG_SLOTS-element array, ready for
    // the ct_diag developer field. Called ONCE per session, from stopAndSave,
    // so the array allocation here is not on any hot path -- which is the
    // entire reason the counters are named fields and the packing lives here.
    //
    // THE LENGTH IS SAFETY-CRITICAL, not merely tidy. MEASURED (simulator,
    // fr965 / SDK 9.2.0): calling setData with an array LONGER than the
    // field's :count raises
    //
    //   Error: System Error
    //   Details: setData input array too long for allocated space
    //
    // which is NOT catchable -- it escapes an enclosing try/catch and aborts,
    // exactly as setData(null) does (#48). A shorter array is accepted without
    // complaint. So if this size and the :count at the createField call in
    // StrongRowView ever diverge upward, the app dies at save time, taking the
    // whole activity with it -- a far worse outcome than a mis-recorded
    // counter. Both sites read $.CT_DIAG_SLOTS and must keep doing so; do not
    // substitute a literal in either. test_ct_diagSnapshotShape pins this
    // side's length, and CT_DIAG_VERSION exists so a deliberate change is
    // visible in the file rather than silent.
    //
    // Every slot is clamped into the UINT16 range on the way out; the counters
    // themselves are unclamped 32-bit Numbers.
    function diagSnapshot() {
        var a = new [$.CT_DIAG_SLOTS];
        a[$.CT_DIAG_I_VERSION]         = $.CT_DIAG_VERSION;
        a[$.CT_DIAG_I_OPEN_ATTEMPTS]   = ctDiagClamp(mDiagOpenAttempts);
        a[$.CT_DIAG_I_OPEN_OK]         = ctDiagClamp(mDiagOpenOk);
        a[$.CT_DIAG_I_OPEN_THROW]      = ctDiagClamp(mDiagOpenThrow);
        a[$.CT_DIAG_I_MSG_TOTAL]       = ctDiagClamp(mDiagMsgTotal);
        a[$.CT_DIAG_I_BCAST]           = ctDiagClamp(mDiagBcast);
        a[$.CT_DIAG_I_SHORT_PAY]       = ctDiagClamp(mDiagShortPay);
        a[$.CT_DIAG_I_PAGE1]           = ctDiagClamp(mDiagPage1);
        a[$.CT_DIAG_I_PAGE_OTHER]      = ctDiagClamp(mDiagPageOther);
        a[$.CT_DIAG_I_CORE_OK]         = ctDiagClamp(mDiagCoreOk);
        a[$.CT_DIAG_I_CORE_SENTINEL]   = ctDiagClamp(mDiagCoreSentinel);
        a[$.CT_DIAG_I_CORE_CLAMP]      = ctDiagClamp(mDiagCoreClamp);
        a[$.CT_DIAG_I_SKIN_OK]         = ctDiagClamp(mDiagSkinOk);
        a[$.CT_DIAG_I_SKIN_SENTINEL]   = ctDiagClamp(mDiagSkinSentinel);
        a[$.CT_DIAG_I_SKIN_CLAMP]      = ctDiagClamp(mDiagSkinClamp);
        a[$.CT_DIAG_I_CHAN_CLOSED]     = ctDiagClamp(mDiagChanClosed);
        a[$.CT_DIAG_I_MAX_FAILS]       = ctDiagClamp(mDiagMaxFails);
        a[$.CT_DIAG_I_FLAGS]           = ctDiagClamp((mDiagFlags >= 0) ? mDiagFlags : diagFlagsNow());
        a[$.CT_DIAG_I_PAGE_FIRST]      = ctDiagClamp(mDiagPageFirst);
        a[$.CT_DIAG_I_PAGE_OTHER_LAST] = ctDiagClamp(mDiagPageOtherLast);
        a[$.CT_DIAG_I_ACQ_PERIOD]      = ctDiagClamp(mDiagAcqPeriod);
        a[$.CT_DIAG_I_HSI_OK]          = ctDiagClamp(mDiagHsiOk);
        a[$.CT_DIAG_I_HSI_INVALID]     = ctDiagClamp(mDiagHsiInvalid);
        a[$.CT_DIAG_I_HSI_MAX_RAW]     = ctDiagClamp(mDiagHsiMaxRaw);
        a[$.CT_DIAG_I_PAGE0]           = ctDiagClamp(mDiagPage0);
        return a;
    }

    function close() {
        // mClosed FIRST, then cancel, then release. If release() synchronously
        // delivers CHANNEL_CLOSED, the handler would otherwise run after the
        // cancel and re-arm the search after shutdown. The old
        // `mEverSeen || mTries < 3` predicate was an accidental brake on that;
        // removing it removes the brake, so the guard is explicit now.
        mClosed = true;
        // #102: latch the terminal state HERE, after mClosed is set and before
        // the channel is released. StrongRowView.shutdown calls close() before
        // stopAndSave, so a readout that computed these live would report
        // "no channel held, closed" on every row ever recorded and carry no
        // information. The other stopAndSave caller (onBack) runs without a
        // preceding close(), and there diagSnapshot's live fallback is the
        // correct answer -- the channel really is still up.
        mDiagFlags = diagFlagsNow();
        cancelReopen();
        discardChannel();
    }
}
