using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Sensor;
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
// Optional built-in interval workout (default 5 x 4:00 at 16-18 spm, 2:00
// rest, press-START gate after each rest). Everything is configurable from the
// Connect IQ app settings in Garmin Connect, including turning the workout off
// entirely for a plain free row.
//
// Note: only the watch accelerometer is available - Connect IQ cannot read an
// external chest strap's accelerometer (HRM 600 etc.), so stroke detection is
// wrist-based.
//
class StrongRowView extends Ui.View {

    // step types
    hidden const STEP_WORK = 0;
    hidden const STEP_REST = 1;
    hidden const STEP_GATE = 2;
    hidden const STEP_DONE = 3;

    // ---- workout params (loaded from settings) ----
    hidden var mWorkoutEnabled;
    hidden var mNumWork;
    hidden var mWorkSec;
    hidden var mRestSec;
    hidden var mTgtLo;
    hidden var mTgtHi;
    hidden var mGate;

    // ================= stroke detector tunables =============================
    hidden const REQ_RATE = 25;
    hidden const MIN_RATE = 6.0;
    hidden const MAX_RATE = 50.0;
    hidden const FC_SLOW = 0.10;
    hidden const FC_FAST = 1.80;
    hidden const FC_ENV  = 0.30;
    hidden const THR_K    = 0.60;
    hidden const THR_LO_K = 0.40;
    hidden const MIN_THR  = 40.0;
    hidden const NPER = 3;

    hidden var mDt;
    hidden var mAlphaSlow;
    hidden var mAlphaFast;
    hidden var mAlphaEnv;
    hidden var mCoeffReady;
    hidden var mGravity;
    hidden var mLp;
    hidden var mEnv;
    hidden var mArmed;
    hidden var mSampleIdx;
    hidden var mLastStrokeT;
    hidden var mLastPeriod;
    hidden var mPeriods;
    hidden var mPIdx;
    hidden var mPCount;
    hidden var mRate;
    hidden var mStrokeCount;

    // ================= app / workout state ==================================
    hidden var mSensorOk;
    hidden var mTimer;
    hidden var mSession;
    hidden var mFitField;
    hidden var mStartMs;

    hidden var mSteps;
    hidden var mStepIdx;
    hidden var mStarted;
    hidden var mPaused;
    hidden var mStepStartMs;
    hidden var mPausedAt;

    function initialize() {
        View.initialize();
        resetDetector();
        mCoeffReady = false;
        mSensorOk   = false;
        mSession    = null;
        mFitField   = null;
        mStartMs    = 0;
        mStarted    = false;
        mPaused     = false;
        mStepIdx    = 0;
        mStepStartMs = 0;
        mPausedAt   = 0;
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
        mGate = getProp("pressToContinue", true);
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
        mSteps.add({ :type => STEP_DONE });
    }

    hidden function resetDetector() {
        mGravity     = 1000.0;
        mLp          = 0.0;
        mEnv         = 0.0;
        mArmed       = true;
        mSampleIdx   = 0;
        mLastStrokeT = -100.0;
        mLastPeriod  = 0.0;
        mPeriods     = new [NPER];
        mPIdx        = 0;
        mPCount      = 0;
        mRate        = 0.0;
        mStrokeCount = 0;
    }

    function onLayout(dc) {
        startSensor();
        mTimer = new Timer.Timer();
        mTimer.start(method(:onTick), 250, true);
    }

    function onTick() as Void {
        if (mFitField != null && !mPaused && mStarted) {
            mFitField.setData(mRate);
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
        try {
            var options = {
                :period => 1,
                :accelerometer => { :enabled => true, :sampleRate => REQ_RATE }
            };
            Sensor.registerSensorDataListener(method(:onAccel), options);
            mSensorOk = true;
        } catch (e) {
            mSensorOk = false;
        }
    }

    hidden function computeCoeffs(rate) {
        mDt = 1.0 / rate;
        mAlphaSlow = mDt / (mDt + 1.0 / (2.0 * Math.PI * FC_SLOW));
        mAlphaFast = mDt / (mDt + 1.0 / (2.0 * Math.PI * FC_FAST));
        mAlphaEnv  = mDt / (mDt + 1.0 / (2.0 * Math.PI * FC_ENV));
        mCoeffReady = true;
    }

    function onAccel(sensorData as Sensor.SensorData) as Void {
        var accel = sensorData.accelerometerData;
        if (accel == null) { return; }
        var xs = accel.x;
        var ys = accel.y;
        var zs = accel.z;
        if (xs == null) { return; }
        var n = xs.size();
        if (n <= 0) { return; }
        if (!mCoeffReady) { computeCoeffs(n); }

        for (var i = 0; i < n; i++) {
            var fx = xs[i];
            var fy = ys[i];
            var fz = zs[i];
            var s = Math.sqrt(fx * fx + fy * fy + fz * fz);

            mGravity += mAlphaSlow * (s - mGravity);
            var hp = s - mGravity;
            mLp += mAlphaFast * (hp - mLp);
            var sig = mLp;

            var a = (sig < 0.0) ? -sig : sig;
            mEnv += mAlphaEnv * (a - mEnv);
            var thr = mEnv * THR_K;
            if (thr < MIN_THR) { thr = MIN_THR; }
            var thrLo = thr * THR_LO_K;

            var t = mSampleIdx * mDt;
            if (mArmed && sig > thr && (t - mLastStrokeT) > (60.0 / MAX_RATE)) {
                registerStroke(t);
                mArmed = false;
            } else if (sig < thrLo) {
                mArmed = true;
            }
            mSampleIdx++;
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
        }
    }

    hidden function registerStroke(t) {
        if (mLastStrokeT > -50.0) {
            var p = t - mLastStrokeT;
            if (p >= 60.0 / MAX_RATE && p <= 60.0 / MIN_RATE) {
                mPeriods[mPIdx] = p;
                mPIdx = (mPIdx + 1) % NPER;
                if (mPCount < NPER) { mPCount++; }
                mLastPeriod = p;
                mStrokeCount++;
                recomputeRate();
            }
        }
        mLastStrokeT = t;
    }

    hidden function recomputeRate() {
        if (mPCount <= 0) { mRate = 0.0; return; }
        var sum = 0.0;
        for (var i = 0; i < mPCount; i++) { sum += mPeriods[i]; }
        var avg = sum / mPCount;
        if (avg > 0.0) { mRate = 60.0 / avg; }
    }

    // ================= session / workout control ===========================
    hidden function startSession() {
        if (mSession == null) {
            try {
                mSession = Rec.createSession({
                    :name => "StrongRow",
                    :sport => Activity.SPORT_ROWING,
                    :subSport => Activity.SUB_SPORT_GENERIC
                });
                mFitField = mSession.createField(
                    "row_stroke_rate", 0, Fit.DATA_TYPE_FLOAT,
                    { :mesgType => Fit.MESG_TYPE_RECORD, :units => "spm" });
            } catch (e) {
                mSession = null;
            }
        }
        if (mSession != null) { mSession.start(); }
    }

    hidden function stepRemaining() {
        var st = mSteps[mStepIdx];
        if (!st.hasKey(:dur)) { return 0.0; }
        var el = (System.getTimer() - mStepStartMs) / 1000.0;
        var r = st[:dur] - el;
        return (r < 0.0) ? 0.0 : r;
    }

    function onPrimary() {
        if (!mWorkoutEnabled) {
            if (!mStarted) {
                startSession();
                mStarted = true;
                mPaused = false;
                mStartMs = System.getTimer();
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
        if (t == STEP_GATE) {
            advanceStep();
        } else if (t == STEP_DONE) {
            return;
        } else {
            togglePause();
        }
    }

    hidden function startWorkout() {
        startSession();
        mStarted = true;
        mPaused = false;
        mStepIdx = 0;
        mStartMs = System.getTimer();
        mStepStartMs = mStartMs;
        alert(STEP_WORK);
    }

    hidden function advanceStep() {
        mStepIdx++;
        var st = mSteps[mStepIdx];
        var t = st[:type];
        if (t == STEP_WORK || t == STEP_REST) {
            if (mSession != null) { try { mSession.addLap(); } catch (e) {} }
            mStepStartMs = System.getTimer();
        }
        alert(t);
    }

    hidden function togglePause() {
        var now = System.getTimer();
        if (mPaused) {
            mStepStartMs += (now - mPausedAt);
            if (mSession != null) { mSession.start(); }
            mPaused = false;
        } else {
            mPausedAt = now;
            if (mSession != null) { mSession.stop(); }
            mPaused = true;
        }
    }

    function stopAndSave() {
        if (mSession != null) {
            if (mSession.isRecording()) { mSession.stop(); }
            mSession.save();
            mSession = null;
            mFitField = null;
        }
        mStarted = false;
    }

    function shutdown() {
        if (mTimer != null) { mTimer.stop(); }
        if (mSensorOk) {
            try { Sensor.unregisterSensorDataListener(); } catch (e) {}
        }
        stopAndSave();
    }

    hidden function alert(stepType) {
        if (!(Toybox has :Attention)) { return; }
        if (Attention has :vibrate) {
            var v;
            if (stepType == STEP_REST || stepType == STEP_DONE) {
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

    hidden function totalElapsed() {
        var secs = (System.getTimer() - mStartMs) / 1000;
        var m = secs / 60;
        var s = secs % 60;
        return m.format("%d") + ":" + s.format("%02d");
    }

    hidden function drawRate(dc, w, h, col) {
        var valFont = (w >= 300) ? Gfx.FONT_NUMBER_THAI_HOT : Gfx.FONT_NUMBER_HOT;
        var val = (mRate > 0.0) ? mRate.format("%.1f") : "--.-";
        dc.setColor(col, Gfx.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.55, valFont, val,
                    Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
    }

    hidden function drawFoot(dc, w, h) {
        var foot;
        var fcol = Gfx.COLOR_LT_GRAY;
        if (!mSensorOk) {
            foot = "NO ACCEL"; fcol = Gfx.COLOR_RED;
        } else if (mPaused) {
            foot = "PAUSED  " + mStrokeCount.toString() + " str"; fcol = Gfx.COLOR_YELLOW;
        } else if (mStarted) {
            foot = "REC " + totalElapsed() + "  " + mStrokeCount.toString() + " str";
            fcol = Gfx.COLOR_RED;
        } else {
            foot = "START to record";
        }
        dc.setColor(fcol, Gfx.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.87, Gfx.FONT_XTINY, foot, Gfx.TEXT_JUSTIFY_CENTER);
    }

    function onUpdate(dc) {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_BLACK);
        dc.clear();

        // ---- free-row mode (workout disabled) ----
        if (!mWorkoutEnabled) {
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.12, Gfx.FONT_SMALL, "ROW SPM", Gfx.TEXT_JUSTIFY_CENTER);
            drawRate(dc, w, h, Gfx.COLOR_WHITE);
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.75, Gfx.FONT_XTINY, "free row", Gfx.TEXT_JUSTIFY_CENTER);
            drawFoot(dc, w, h);
            return;
        }

        // ---- workout mode ----
        var st = mStarted ? mSteps[mStepIdx] : null;
        var type = (st != null) ? st[:type] : -1;

        var title;
        if (!mStarted)              { title = mNumWork.toString() + "x" + (mWorkSec / 60).toString() + "'"; }
        else if (mPaused)           { title = "PAUSED"; }
        else if (type == STEP_WORK) { title = "WORK " + st[:idx].toString() + "/" + mNumWork.toString(); }
        else if (type == STEP_REST) { title = "REST"; }
        else if (type == STEP_GATE) { title = "READY"; }
        else                        { title = "DONE"; }
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.12, Gfx.FONT_SMALL, title, Gfx.TEXT_JUSTIFY_CENTER);

        if (type == STEP_WORK || type == STEP_REST) {
            dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.30, Gfx.FONT_NUMBER_MILD, mmss(stepRemaining()),
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

        var col = Gfx.COLOR_WHITE;
        if (type == STEP_WORK && mRate > 0.0) {
            col = (mRate >= mTgtLo && mRate <= mTgtHi) ? Gfx.COLOR_GREEN : Gfx.COLOR_ORANGE;
        }
        drawRate(dc, w, h, col);

        var sub;
        if (type == STEP_WORK)      { sub = "target " + mTgtLo.toString() + "-" + mTgtHi.toString() + " spm"; }
        else if (type == STEP_REST) { sub = "next: WORK " + st[:nextn].toString(); }
        else if (type == STEP_GATE) { sub = "to start WORK " + st[:nextn].toString(); }
        else if (type == STEP_DONE) { sub = "BACK to save"; }
        else                        { sub = "target " + mTgtLo.toString() + "-" + mTgtHi.toString() + " spm"; }
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.75, Gfx.FONT_XTINY, sub, Gfx.TEXT_JUSTIFY_CENTER);

        drawFoot(dc, w, h);
    }
}
