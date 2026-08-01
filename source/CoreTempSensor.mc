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
        openChannel();
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
    static function decodeCoreC(p) {
        var raw = (p[6] & 0xFF) + 256 * (p[7] & 0xFF);
        if (raw == 0xFFFF) { return null; }
        var t = raw * 0.01;
        if (t < $.CT_CORE_MIN_C || t > $.CT_CORE_MAX_C) { return null; }
        return t;
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
        } catch (e) {
            mChannel = null;
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
        if (p == null || p.size() < 8) { return; }
        if ((p[0] & 0xFF) != 0x01) { return; }   // CBT data page 1 only

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
            mCore     = c;
            mCoreMs   = now;
            mLastMs   = now;
            mEverSeen = true;
        }

        var s = decodeSkinC(p);
        if (s != null) {
            mSkin     = s;
            mSkinMs   = now;
            mLastMs   = now;
            mEverSeen = true;
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
        mFails++;
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

    function close() {
        // mClosed FIRST, then cancel, then release. If release() synchronously
        // delivers CHANNEL_CLOSED, the handler would otherwise run after the
        // cancel and re-arm the search after shutdown. The old
        // `mEverSeen || mTries < 3` predicate was an accidental brake on that;
        // removing it removes the brake, so the guard is explicit now.
        mClosed = true;
        cancelReopen();
        discardChannel();
    }
}
