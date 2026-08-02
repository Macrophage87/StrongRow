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

// Retry pacing for the ANT search. Wired up at the #26 commit; the ladder
// itself is a pure function so it is (:test)-able on its own.
const CT_BURST_TRIES     = 4;     // back-to-back searches before backoff starts
const CT_BACKOFF_BASE_MS = 30000;
const CT_BACKOFF_MAX_MS  = 300000;

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
// a saved probe activity decoded with fitparse carried all 16 written values
// in order, unscaled, under native_mesg_num='session'. Whether a real device
// agrees, and whether it caps developer fields below 11, is NOT measured; #77
// owns that question.
//
// Counters are plain 32-bit Number increments on the ANT callback path: no
// saturation test, no allocation, no branch beyond the ones already present.
// A 4 Hz channel for 24 h is ~3.5e5 increments, five orders of magnitude below
// overflow, so clamping to the UINT16 range happens ONCE at readout instead.
// A slot reading CT_DIAG_MAX therefore means "at least CT_DIAG_MAX".
const CT_DIAG_SLOTS   = 21;
const CT_DIAG_MAX     = 65535;    // UINT16 ceiling; readout clamps, not the counter
const CT_DIAG_NONE    = 0xFFFF;   // "never observed" for the page-byte slots

// Slot indices. These ARE the wire format: renumbering one without bumping
// CT_DIAG_VERSION silently mis-labels every field already recorded.
const CT_DIAG_VERSION = 1;        // value stored in slot CT_DIAG_I_VERSION

const CT_DIAG_I_VERSION       = 0;
const CT_DIAG_I_OPEN_ATTEMPTS = 1;   // openChannel() entries
const CT_DIAG_I_OPEN_OK       = 2;   // openChannel() completed without throwing
const CT_DIAG_I_OPEN_THROW    = 3;   // openChannel()'s catch entered
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

// Bits of CT_DIAG_I_FLAGS.
const CT_DIAG_F_CHANNEL_HELD = 1;   // a channel handle was still held at readout
const CT_DIAG_F_CLOSED       = 2;   // close() had run
const CT_DIAG_F_EVER_SEEN    = 4;   // a reading was accepted at some point

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
    hidden var mLastMs;
    hidden var mCoreMs;
    hidden var mSkinMs;
    hidden var mEverSeen;
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
        mLastMs     = 0;
        mCoreMs     = 0;
        mSkinMs     = 0;
        mEverSeen   = false;
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
            mChannel.setDeviceConfig(new Ant.DeviceConfig({
                :deviceNumber => 0,              // wildcard: first pod found
                :deviceType => DEVICE_TYPE,
                :transmissionType => 0,
                :messagePeriod => mPeriod,
                :radioFrequency => RF_FREQ,
                :searchTimeoutLowPriority => 12, // 30 s per attempt
                :searchThreshold => 0
            }));
            mChannel.open();
            // #102: reached only when nothing above threw. openAttempts minus
            // openOk is not the throw count -- openThrow is counted explicitly
            // below -- because that difference has to stay readable even if a
            // future edit adds a return path between here and the catch.
            mDiagOpenOk++;
        } catch (e) {
            // #102: the counter this issue was filed on. This catch was
            // completely silent, so a channel that could never be acquired and
            // a channel that opened and heard nothing left identical files.
            mDiagOpenThrow++;

            // Hand the channel back before dropping the reference. ANT channels
            // are a scarce hardware resource, and the `if (mChannel == null)`
            // guard above only protects the ALLOCATION -- setDeviceConfig() and
            // open() run on every call, so a throw on the re-search path
            // discards an already-assigned channel too. Once the reference is
            // gone close() can no longer release it. #18.
            discardChannel();

            // ...and schedule a retry, because releasing alone fixes the leak
            // but not the outage: after this catch mChannel is null, so no
            // further CHANNEL_CLOSED can arrive and nothing re-enters
            // openChannel() -- CORE would stay dead for the rest of the app
            // run. This is also why #18 and #26 must ship together: the ladder
            // re-enters openChannel(), which against the un-fixed catch would
            // have turned a one-shot leak into one orphaned channel per retry.
            mFails++;
            // #102 high-water mark. mFails is reset to 0 by any tracked page-1
            // frame, so at save time it carries the CURRENT ladder depth and
            // says nothing about the depth reached. Two copies of this line
            // exist (here and in onChannelClosed) because mFails is incremented
            // in exactly those two places; keep them together.
            if (mFails > mDiagMaxFails) { mDiagMaxFails = mFails; }
            scheduleReopen(ctBackoffMs(mFails));
        }
    }

    // Re-open the channel after `delayMs`. A zero delay reopens synchronously,
    // which is what the first CT_BURST_TRIES searches do, so discovery keeps
    // exactly today's timing. A non-zero delay defers via a one-shot timer,
    // which is what stops a permanently absent pod from holding the radio open.
    hidden function scheduleReopen(delayMs) {
        if (mClosed) { return; }
        cancelReopen();
        if (delayMs <= 0) {
            openChannel();
            return;
        }
        try {
            mRetryTimer = new Timer.Timer();
            mRetryTimer.start(method(:onRetry), delayMs, false);
        } catch (e) {
            // No timer available: fall back to today's behaviour rather than
            // silently dropping the retry and leaving CORE dead.
            mRetryTimer = null;
            openChannel();
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
        // #102: every ANT message, before any dispatch. This is the counter
        // that says the radio was alive at all -- a row with no pod still
        // receives channel-response events as each search times out, so
        // msgTotal > 0 with bcast == 0 reads as "no pod", where
        // msgTotal == 0 with openOk == 0 reads as "the channel never opened".
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

        if (p == null || p.size() < 8) { mDiagShortPay++; return; }

        // Behaviour-identical to the single expression this replaces; the local
        // exists so the page byte can be recorded as well as tested. A
        // truncated frame and a wrong page are counted separately because they
        // point at different defects.
        var page = p[0] & 0xFF;
        if (mDiagPageFirst == $.CT_DIAG_NONE) { mDiagPageFirst = page; }
        if (page != 0x01) {                      // CBT data page 1 only
            mDiagPageOther++;
            mDiagPageOtherLast = page;
            return;
        }
        mDiagPage1++;

        var now = System.getTimer();

        // Any tracked page-1 frame resets the search pacing, not merely an
        // ACCEPTED reading: a pod broadcasting undonned is fully tracked while
        // producing zero readings that clear the plausibility clamps, and the
        // counter should mean what its name says.
        mFails = 0;

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
        scheduleReopen(ctBackoffMs(mFails));
    }

    // ---- accessors ----------------------------------------------------------
    // The *At(nowMs) forms take the clock as a parameter so tests are
    // deterministic; the public no-argument forms are the shipping API.

    hidden function coreFreshAt(nowMs) { return ctIsFresh(nowMs, mCoreMs, $.CT_FRESH_MS); }
    hidden function skinFreshAt(nowMs) { return ctIsFresh(nowMs, mSkinMs, $.CT_FRESH_MS); }

    hidden function coreTempAt(nowMs) {
        return coreFreshAt(nowMs) ? mCore : 0.0;
    }

    hidden function skinTempAt(nowMs) {
        return skinFreshAt(nowMs) ? mSkin : 0.0;
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

    function coreTemp() { return coreTempAt(System.getTimer()); }
    function skinTemp() { return skinTempAt(System.getTimer()); }
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
        return f;
    }

    // The whole diagnostic state as one CT_DIAG_SLOTS-element array, ready for
    // the ct_diag developer field. Called ONCE per session, from stopAndSave,
    // so the array allocation here is not on any hot path -- which is the
    // entire reason the counters are named fields and the packing lives here.
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
