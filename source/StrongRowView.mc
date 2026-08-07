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
// the geometry can draw, and one degree costs (HI-LO)/sweep bpm. Over the 44
// degree sweep below, 80-190 gives 0.4 deg/bpm, i.e. ONE DEGREE IS 2.5 BPM. A
// 60-200 range over the same sweep would make it 3.2 bpm. Both ends are still
// outside any plausible rowing target -- the reference session ran 97-147 --
// and a reading beyond either end clamps VISIBLY rather than silently, so the
// cost of the narrower span is paid in a state the display announces.
const HR_DISP_LO = 80;
const HR_DISP_HI = 190;
// SWEEP, in drawArc degrees. 0 is 3 o'clock, 90 is 12, 180 is 9, 270 is 6, so
// this is the left edge centred on 9 o'clock: low bpm at the bottom
// (HR_ARC_BOT), high at the top (HR_ARC_TOP), +/-22 degrees of horizontal.
//
// +/-22 IS MEASURED, NOT DERIVED, and the distinction is the whole history of
// this constant. It was +/-30, chosen by arithmetic against the height
// fractions of the rows above and below, and that arithmetic was wrong in two
// ways at once: it tracked the CENTRELINE of each primitive rather than its
// outermost pixel, and it assumed text widths instead of measuring them. The
// arc overlapped rendered text on 11 of the 12 manifest devices -- by 21 px on
// fr965 and 23 px on fenix843mm.
//
// The bound now comes from source/HrLayoutTest.mc, which renders every screen
// this view can draw into a recording Dc, measures every string with the real
// font metrics of a real Dc, expands every primitive to its PEN WIDTH, and
// reports the worst separation. At +/-22 the worst margin over every step type,
// every band settable in the declared range and every heart-rate state is
// +13.4 px, on fenix6spro. Widening to +/-26 drops fenix843mm to 6.5 px, which
// is why it is not wider.
//
// None of that says anything about how the result looks. It says pixels do not
// share coordinates.
const HR_ARC_TOP = 158;
const HR_ARC_BOT = 202;
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
const HRZ_NONE  = -1;
const HRZ_BELOW = 0;
const HRZ_IN    = 1;
const HRZ_ABOVE = 2;

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
    hidden var mHrLo;
    hidden var mHrHi;

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
    hidden var mMaxCore;
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
        mMaxCore    = 0.0;
        mHrBpm      = 0;
        mLastHrMs   = 0;
        mHrEver     = false;
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
        var hb = hrClampBand(getProp("hrLo", 116).toNumber(),
                             getProp("hrHi", 130).toNumber());
        mHrLo = hb[0];
        mHrHi = hb[1];
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
            t.start(method(:onTick), 250, true);
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
            if (mFitCore != null) {
                var ct = mCoreSensor.coreTemp();
                mFitCore.setData(ct);
                if (ct > mMaxCore) { mMaxCore = ct; }
            }
            if (mFitSkin != null) { mFitSkin.setData(mCoreSensor.skinTemp()); }
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

    static function hrHave(ever, lastMs, nowMs, threshMs) {
        return ever && lastMs > 0 && (nowMs - lastMs) < threshMs;
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
    // constants the first heart rate with a visible fill is 83 bpm --
    // MEASURED, by walking hrAngle over 0..200 -- so every reading from 0
    // through 82 renders with no zone colour at all.
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
    // sweep if it overran an end. With a 44-degree sweep and a 2-degree floor
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
    // at the shipping constants that is 44 / 5. Computed in INTEGER arithmetic
    // that truncates to 8, which drew [158,166] [174,182] [190,198] and left a
    // FOUR-DEGREE TAIL WITH NO TRACK AT ALL -- the arc simply stopped short of
    // its own end. 44 / 5.0 = 8.8 spans the sweep exactly, ending the last
    // segment on HR_ARC_BOT.
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
                mFitRate = mSession.createField(
                    "row_stroke_rate", 0, Fit.DATA_TYPE_FLOAT,
                    { :mesgType => Fit.MESG_TYPE_RECORD, :units => "spm" });
                mFitDps = mSession.createField(
                    "dist_per_stroke", 1, Fit.DATA_TYPE_FLOAT,
                    { :mesgType => Fit.MESG_TYPE_RECORD, :units => "m" });
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
                mCorrAccum = 0.0;
                // Per-session accumulator, reset with the others above. It used
                // to be reset INSIDE the CORE block below, which made its
                // correctness depend on whether fields were created.
                mMaxCore = 0.0;
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
                // Accepted cost, stated so it is a decision and not a surprise:
                // a row with no pod now declares these three fields and writes
                // core/skin every tick. coreTemp()/skinTemp() return 0.0 when
                // nothing is fresh, so such a row logs 0.0 rather than leaving
                // the fields unwritten. That is #13's territory (it owns the
                // guard, and the freshness model it depends on); do not
                // pre-empt it here. Note 0.0 cannot collide with a real reading
                // -- the 25-45 C / 15-45 C clamps in CoreTempSensor put it
                // outside the accepted band by construction in this code.
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
                }
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
        }
        mStarted = false;
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
        // CT: green while a CORE pod's data is fresh
        var ccol = Gfx.COLOR_DK_GRAY;
        if (mCoreSensor != null && mCoreSensor.isFresh()) {
            ccol = Gfx.COLOR_GREEN;
        }
        dc.setColor(ccol, Gfx.COLOR_TRANSPARENT);
        dc.drawText(w * 0.66, h * 0.045, Gfx.FONT_XTINY, "CT", Gfx.TEXT_JUSTIFY_CENTER);
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
        }

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

        var dispRate = outputRate();
        var col = rateColour(type == STEP_WORK, dispRate, mTgtLo, mTgtHi);
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
