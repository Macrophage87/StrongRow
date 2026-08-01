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
    hidden var mTries;
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
        mTries      = 0;
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
    // NOTE: this reads bytes 4-5 and scales by 0.01, which is what the shipped
    // code has always done. It is extracted here UNCHANGED so this commit is
    // behaviour-preserving; the byte positions and the scale are corrected in a
    // later commit (#86), guarded by tests added before that change.
    static function decodeSkinC(p) {
        var rawS = (p[4] & 0xFF) + 256 * (p[5] & 0xFF);
        if (rawS == 0xFFFF) { return null; }
        var s = rawS * 0.01;
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

    // Re-open the channel after `delayMs`. Behaviour-preserving for now: the
    // delay is ignored and the reopen is immediate, exactly as the direct call
    // it replaces. The timer is wired up at the #26 commit.
    hidden function scheduleReopen(delayMs) {
        openChannel();
    }

    // Cancel a pending reopen. A no-op until a timer exists.
    hidden function cancelReopen() {
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

        var c = decodeCoreC(p);
        if (c != null) {
            var now = System.getTimer();
            mCore     = c;
            mLastMs   = now;
            mCoreMs   = now;
            mSkinMs   = now;   // stamped together for now; split at the #17 commit
            mEverSeen = true;
        }

        var s = decodeSkinC(p);
        if (s != null) { mSkin = s; }
    }

    // Search timed out or the pod dropped. Keep trying forever for a pod we
    // have already seen (mid-row dropout); otherwise a few attempts,
    // alternating the channel period in case the pod broadcasts at the other
    // rate.
    hidden function onChannelClosed() {
        if (mEverSeen || mTries < 3) {
            mTries++;
            if (!mEverSeen) {
                mPeriod = (mPeriod == PERIOD_A) ? PERIOD_B : PERIOD_A;
            }
            scheduleReopen(0);
        }
    }

    // ---- accessors ----------------------------------------------------------
    // The *At(nowMs) forms take the clock as a parameter so tests are
    // deterministic; the public no-argument forms are the shipping API.

    hidden function coreFreshAt(nowMs) { return ctIsFresh(nowMs, mCoreMs, $.CT_FRESH_MS); }
    hidden function skinFreshAt(nowMs) { return ctIsFresh(nowMs, mSkinMs, $.CT_FRESH_MS); }

    hidden function coreTempAt(nowMs) {
        return ctIsFresh(nowMs, mLastMs, $.CT_FRESH_MS) ? mCore : 0.0;
    }

    hidden function skinTempAt(nowMs) {
        return ctIsFresh(nowMs, mLastMs, $.CT_FRESH_MS) ? mSkin : 0.0;
    }

    hidden function isFreshAt(nowMs) {
        return ctIsFresh(nowMs, mLastMs, 15000);
    }

    function coreFresh() { return coreFreshAt(System.getTimer()); }
    function skinFresh() { return skinFreshAt(System.getTimer()); }

    function coreTemp() { return coreTempAt(System.getTimer()); }
    function skinTemp() { return skinTempAt(System.getTimer()); }
    function isFresh()  { return isFreshAt(System.getTimer()); }

    function everSeen() { return mEverSeen; }

    function close() {
        discardChannel();
    }
}
