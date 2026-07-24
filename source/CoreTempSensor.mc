using Toybox.Ant;
using Toybox.System;

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
    hidden const FRESH_MS = 30000;

    hidden var mChannel;
    hidden var mPeriod;
    hidden var mCore;
    hidden var mSkin;
    hidden var mLastMs;
    hidden var mEverSeen;
    hidden var mTries;

    function initialize() {
        mChannel  = null;
        mPeriod   = PERIOD_A;
        mCore     = 0.0;
        mSkin     = 0.0;
        mLastMs   = 0;
        mEverSeen = false;
        mTries    = 0;
        openChannel();
    }

    hidden function openChannel() {
        try {
            if (mChannel == null) {
                mChannel = new Ant.GenericChannel(method(:onMessage),
                    new Ant.ChannelAssignment(Ant.CHANNEL_TYPE_RX_NOT_TX, Ant.NETWORK_PLUS));
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

    function onMessage(msg as Ant.Message) as Void {
        var id = msg.messageId;
        if (id == Ant.MSG_ID_BROADCAST_DATA) {
            var p = msg.getPayload();
            if (p == null || p.size() < 8) { return; }
            if ((p[0] & 0xFF) != 0x01) { return; }   // CBT data page 1 only
            // core temperature: uint16 LE in 0.01 C, 0xFFFF = invalid
            var raw = (p[6] & 0xFF) + 256 * (p[7] & 0xFF);
            if (raw != 0xFFFF) {
                var t = raw * 0.01;
                if (t >= 25.0 && t <= 45.0) {
                    mCore = t;
                    mLastMs = System.getTimer();
                    mEverSeen = true;
                }
            }
            // skin temperature: uint16 LE in 0.01 C, sanity-clamped
            var rawS = (p[4] & 0xFF) + 256 * (p[5] & 0xFF);
            if (rawS != 0xFFFF) {
                var s = rawS * 0.01;
                if (s >= 15.0 && s <= 45.0) { mSkin = s; }
            }
        } else if (id == Ant.MSG_ID_CHANNEL_RESPONSE_EVENT) {
            var p = msg.getPayload();
            if (p == null || p.size() < 2) { return; }
            if ((p[0] & 0xFF) == Ant.MSG_ID_RF_EVENT
                && (p[1] & 0xFF) == Ant.MSG_CODE_EVENT_CHANNEL_CLOSED) {
                // Search timed out or the pod dropped. Keep trying forever for
                // a pod we have already seen (mid-row dropout); otherwise a few
                // attempts, alternating the channel period in case the pod
                // broadcasts at the other rate.
                if (mEverSeen || mTries < 3) {
                    mTries++;
                    if (!mEverSeen) {
                        mPeriod = (mPeriod == PERIOD_A) ? PERIOD_B : PERIOD_A;
                    }
                    openChannel();
                }
            }
        }
    }

    function coreTemp() {
        if (mLastMs > 0 && (System.getTimer() - mLastMs) < FRESH_MS) { return mCore; }
        return 0.0;
    }

    function skinTemp() {
        if (mLastMs > 0 && (System.getTimer() - mLastMs) < FRESH_MS) { return mSkin; }
        return 0.0;
    }

    function isFresh() {
        return mLastMs > 0 && (System.getTimer() - mLastMs) < 15000;
    }

    function everSeen() {
        return mEverSeen;
    }

    function close() {
        if (mChannel != null) {
            try { mChannel.release(); } catch (e) {}
            mChannel = null;
        }
    }
}
