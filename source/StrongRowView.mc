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

    // ================= stroke detector tunables =============================
    hidden const REQ_RATE = 25;
    hidden const MIN_RATE = 6.0;
    hidden const MAX_RATE = 40.0;
    hidden const FC_SLOW = 0.10;
    hidden const FC_FAST = 1.80;
    hidden const FC_ENV  = 0.30;
    hidden const FC_VAR  = 0.03;
    hidden const THR_K    = 0.60;
    hidden const THR_LO_K = 0.40;
    hidden const MIN_THR  = 40.0;
    hidden const NPER = 5;
    hidden const QUIET_S = 5.0;       // no strokes while filters settle at boot
    hidden const FAST_NEEDS_LOCK = 30.0; // rates above this need an autocorr lock
    hidden const LOCK_SNAP_K = 0.30;  // locked rate deviating more snaps to lock
    // autocorrelation period gate
    hidden const AC_HZ       = 5.0;   // decimated sample rate
    hidden const AC_BUF      = 128;   // ~25 s of history
    hidden const AC_WIN      = 64;    // products per lag
    hidden const AC_MIN_N    = 40;    // don't estimate before ~8 s of data
    hidden const AC_MIN_CONF = 0.35;  // below this: no period lock
    hidden const AC_SUB_K    = 0.50;  // subharmonic must reach this vs best
    hidden const REFRACT_FRAC = 0.72; // fraction of locked period a peak is ignored
    // R-R / HRV
    hidden const RR_MIN_MS = 250;     // physiological beat interval range
    hidden const RR_MAX_MS = 2500;
    hidden const RR_ART_K  = 0.30;    // reject successive jumps > 30% as artifacts
    hidden const RR_NDIFF  = 90;      // rMSSD window: last ~90 beat pairs
    hidden const RR_PER_REC = 4;      // raw intervals logged per record

    hidden var mDt;
    hidden var mAlphaSlow;
    hidden var mAlphaFast;
    hidden var mAlphaEnv;
    hidden var mAlphaVar;
    hidden var mCoeffReady;
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
    hidden var mStrokeCount;
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

    // R-R / HRV state
    hidden var mRrOk;
    hidden var mLastRrMs;
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
        mGpsQual    = 0;
        mSession    = null;
        mFitRate    = null;
        mFitDps     = null;
        mFitRr      = null;
        mFitRmssd   = null;
        mFitAvgRmssd = null;
        mFitCorr    = null;
        mFitCorrTotal = null;
        mCorrAccum  = 0.0;
        mRrOk       = false;
        mLastRrMs   = 0;
        mRrLast     = 0;
        mDiffSq     = new [RR_NDIFF];
        mDiffIdx    = 0;
        mDiffCount  = 0;
        mRmssd      = 0.0;
        mRmssdSum   = 0.0;
        mRmssdN     = 0;
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
        mWarmCool = getProp("warmupCooldown", true);
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
        mStrokeCount = 0;
        mDecim       = 5;
        mAcDt        = 0.2;
        mAcBuf       = new [AC_BUF];
        for (var i = 0; i < AC_BUF; i++) { mAcBuf[i] = 0.0; }
        mAcIdx       = 0;
        mAcCount     = 0;
        mAcAccum     = 0.0;
        mAcAccumN    = 0;
        mAcBatch     = 0;
        mAcPeriod    = 0.0;
        mAcLowConf   = 0;
    }

    function onLayout(dc) {
        startSensor();
        startGps();
        mTimer = new Timer.Timer();
        mTimer.start(method(:onTick), 250, true);
    }

    function onTick() as Void {
        if (mStarted && !mPaused) {
            if (mFitRate != null) { mFitRate.setData(outputRate()); }
            if (mFitDps != null)  { mFitDps.setData(distPerStroke(currentSpeed())); }
            if (mFitRmssd != null) { mFitRmssd.setData(mRmssd); }
            if (mRmssd > 0.0) {
                mRmssdSum += mRmssd;
                mRmssdN++;
            }
            if (mFitCorr != null) {
                var cr = correctiveRate();
                mFitCorr.setData(cr);
                mCorrAccum += cr / 240.0;   // spm integrated over a 250 ms tick
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

    hidden function computeCoeffs(rate) {
        mDt = 1.0 / rate;
        mAlphaSlow = mDt / (mDt + 1.0 / (2.0 * Math.PI * FC_SLOW));
        mAlphaFast = mDt / (mDt + 1.0 / (2.0 * Math.PI * FC_FAST));
        mAlphaEnv  = mDt / (mDt + 1.0 / (2.0 * Math.PI * FC_ENV));
        mAlphaVar  = mDt / (mDt + 1.0 / (2.0 * Math.PI * FC_VAR));
        mDecim = (rate / AC_HZ + 0.5).toNumber();
        if (mDecim < 1) { mDecim = 1; }
        mAcDt = mDt * mDecim;
        mCoeffReady = true;
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
        if (xs == null) { return; }
        var n = xs.size();
        if (n <= 0) { return; }
        if (!mCoeffReady) { computeCoeffs(n); }

        // dynamic refractory: once the autocorrelation has locked the cycle
        // period, a new peak within REFRACT_FRAC of it is the recovery surge
        // of the SAME stroke, not a new stroke.
        var refract = 60.0 / MAX_RATE;
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

        var minLag = ((60.0 / MAX_RATE) / mAcDt + 0.5).toNumber();
        var maxLag = ((60.0 / MIN_RATE) / mAcDt + 0.5).toNumber();
        if (minLag < 2) { minLag = 2; }
        if (maxLag > n - 8) { maxLag = n - 8; }
        if (maxLag <= minLag) { return; }

        var w = AC_WIN;
        if (w > n - maxLag) { w = n - maxLag; }
        if (w < 20) { return; }

        var e = 0.0;
        for (var k = n - w; k < n; k++) { e += buf[k] * buf[k]; }
        if (e <= 0.0) { mAcPeriod = 0.0; return; }

        var rr = new [maxLag + 1];
        var best = 0.0;
        var bestL = 0;
        for (var lag = minLag; lag <= maxLag; lag++) {
            var s = 0.0;
            for (var k = n - w; k < n; k++) { s += buf[k] * buf[k - lag]; }
            rr[lag] = s;
            if (s > best) { best = s; bestL = lag; }
        }

        // three consecutive low-confidence evaluations to unlock, so a brief
        // lull mid-piece can't drop the period gate and let artifacts through
        if (bestL == 0 || best / e < AC_MIN_CONF) {
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
    // Raw beat-to-beat intervals go into the FIT unfiltered (offline tools do
    // their own cleaning); the on-watch rMSSD uses only artifact-free pairs.
    hidden function handleRr(ivals) {
        if (ivals == null) { return; }
        var n = ivals.size();
        if (n <= 0) { return; }
        mLastRrMs = System.getTimer();

        var arr = new [RR_PER_REC];
        for (var j = 0; j < RR_PER_REC; j++) { arr[j] = 0; }
        var k = 0;
        for (var i = 0; i < n; i++) {
            var rr = ivals[i];
            if (rr == null) { continue; }
            rr = rr.toNumber();
            if (k < RR_PER_REC) { arr[k] = rr; k++; }
            if (rr >= RR_MIN_MS && rr <= RR_MAX_MS) {
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
            }
        }
        if (k > 0 && mFitRr != null && mStarted && !mPaused) {
            mFitRr.setData(arr);
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
    }

    // final cleaned rate for display and FIT: fast readings need the
    // autocorrelation lock to agree (kills phantom bursts from non-rowing
    // hand motion), and a locked reading that disagrees with the lock by
    // more than 30% snaps to it (kills residual half/double readings)
    hidden function outputRate() {
        var r = mRate;
        if (mAcPeriod > 0.0) {
            var ac = 60.0 / mAcPeriod;
            if (r > 0.0) {
                var dev = r - ac;
                if (dev < 0.0) { dev = -dev; }
                if (dev > LOCK_SNAP_K * ac) { r = ac; }
            }
        } else if (r > FAST_NEEDS_LOCK) {
            r = 0.0;
        }
        if (r > MAX_RATE) { r = MAX_RATE; }
        return r;
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
                    :subSport => Activity.SUB_SPORT_GENERIC
                });
                mFitRate = mSession.createField(
                    "row_stroke_rate", 0, Fit.DATA_TYPE_FLOAT,
                    { :mesgType => Fit.MESG_TYPE_RECORD, :units => "spm" });
                mFitDps = mSession.createField(
                    "dist_per_stroke", 1, Fit.DATA_TYPE_FLOAT,
                    { :mesgType => Fit.MESG_TYPE_RECORD, :units => "m" });
                // explicit R-R / HRV logging, independent of the watch's
                // "Log HRV" device setting
                try {
                    mFitRr = mSession.createField(
                        "rr_interval", 2, Fit.DATA_TYPE_UINT16,
                        { :mesgType => Fit.MESG_TYPE_RECORD, :units => "ms", :count => RR_PER_REC });
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
                mCorrAccum = 0.0;
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

    hidden function stepElapsed() {
        return (System.getTimer() - mStepStartMs) / 1000.0;
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
        if (t == STEP_GATE || t == STEP_WARM || t == STEP_COOL) {
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
        alert(mSteps[0][:type]);
    }

    hidden function advanceStep() {
        mStepIdx++;
        var st = mSteps[mStepIdx];
        var t = st[:type];
        if (t == STEP_WORK || t == STEP_REST || t == STEP_COOL) {
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
            if (mFitAvgRmssd != null && mRmssdN > 0) {
                mFitAvgRmssd.setData(mRmssdSum / mRmssdN);
            }
            if (mFitCorrTotal != null) {
                mFitCorrTotal.setData((mCorrAccum + 0.5).toNumber());
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
        }
        mStarted = false;
    }

    function shutdown() {
        if (mTimer != null) { mTimer.stop(); }
        if (mSensorOk) {
            try { Sensor.unregisterSensorDataListener(); } catch (e) {}
        }
        try { Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition)); } catch (e) {}
        stopAndSave();
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
        dc.drawText(w * 0.42, h * 0.045, Gfx.FONT_XTINY, "GPS", Gfx.TEXT_JUSTIFY_CENTER);
        // RR: green while beat intervals are streaming in
        var rcol = Gfx.COLOR_DK_GRAY;
        if (mRrOk && mLastRrMs > 0 && (System.getTimer() - mLastRrMs) < 5000) {
            rcol = Gfx.COLOR_GREEN;
        }
        dc.setColor(rcol, Gfx.COLOR_TRANSPARENT);
        dc.drawText(w * 0.60, h * 0.045, Gfx.FONT_XTINY, "RR", Gfx.TEXT_JUSTIFY_CENTER);
    }

    hidden function drawRate(dc, w, h, col) {
        var valFont = (w >= 300) ? Gfx.FONT_NUMBER_THAI_HOT : Gfx.FONT_NUMBER_HOT;
        var r = outputRate();
        var val = (r > 0.0) ? r.format("%.1f") : "--.-";
        dc.setColor(col, Gfx.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.52, valFont, val,
                    Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
    }

    hidden function drawPace(dc, w, h, spd) {
        var dps = distPerStroke(spd);
        var txt = paceStr(spd) + "/500m";
        if (dps > 0.0) { txt += "  " + dps.format("%.1f") + "m/str"; }
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.70, Gfx.FONT_XTINY, txt, Gfx.TEXT_JUSTIFY_CENTER);
    }

    hidden function drawFoot(dc, w, h, dist) {
        var foot;
        var fcol = Gfx.COLOR_LT_GRAY;
        var km = (dist / 1000.0).format("%.2f") + "km";
        if (!mSensorOk) {
            foot = "NO ACCEL"; fcol = Gfx.COLOR_RED;
        } else if (mPaused) {
            foot = "PAUSED  " + mStrokeCount.toString() + "str"; fcol = Gfx.COLOR_YELLOW;
        } else if (mStarted) {
            foot = "REC " + totalElapsed() + " " + km + " " + mStrokeCount.toString() + "str";
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

        var spd = currentSpeed();
        var dist = elapsedDist();

        drawGps(dc, w, h);

        // ---- free-row mode (workout disabled) ----
        if (!mWorkoutEnabled) {
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.13, Gfx.FONT_SMALL, "ROW SPM", Gfx.TEXT_JUSTIFY_CENTER);
            drawRate(dc, w, h, Gfx.COLOR_WHITE);
            drawPace(dc, w, h, spd);
            dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.78, Gfx.FONT_XTINY, "free row", Gfx.TEXT_JUSTIFY_CENTER);
            drawFoot(dc, w, h, dist);
            return;
        }

        // ---- workout mode ----
        var st = mStarted ? mSteps[mStepIdx] : null;
        var type = (st != null) ? st[:type] : -1;

        var title;
        if (!mStarted)              { title = mNumWork.toString() + "x" + (mWorkSec / 60).toString() + "'"; }
        else if (mPaused)           { title = "PAUSED"; }
        else if (type == STEP_WARM) { title = "WARM UP"; }
        else if (type == STEP_WORK) { title = "WORK " + st[:idx].toString() + "/" + mNumWork.toString(); }
        else if (type == STEP_REST) { title = "REST"; }
        else if (type == STEP_GATE) { title = "READY"; }
        else if (type == STEP_COOL) { title = "COOL DOWN"; }
        else                        { title = "DONE"; }
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

        var col = Gfx.COLOR_WHITE;
        var dispRate = outputRate();
        if (type == STEP_WORK && dispRate > 0.0) {
            col = (dispRate >= mTgtLo && dispRate <= mTgtHi) ? Gfx.COLOR_GREEN : Gfx.COLOR_ORANGE;
        }
        drawRate(dc, w, h, col);
        drawPace(dc, w, h, spd);

        var sub;
        if (type == STEP_WARM)      { sub = "START to begin work 1"; }
        else if (type == STEP_WORK) { sub = "target " + mTgtLo.toString() + "-" + mTgtHi.toString() + " spm"; }
        else if (type == STEP_REST) { sub = "next: WORK " + st[:nextn].toString(); }
        else if (type == STEP_GATE) { sub = "to start WORK " + st[:nextn].toString(); }
        else if (type == STEP_COOL) { sub = "START when docked"; }
        else if (type == STEP_DONE) { sub = "BACK to save"; }
        else                        { sub = "target " + mTgtLo.toString() + "-" + mTgtHi.toString() + " spm"; }
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.78, Gfx.FONT_XTINY, sub, Gfx.TEXT_JUSTIFY_CENTER);

        drawFoot(dc, w, h, dist);
    }
}
