using Toybox.Application as App;

// Entry point for the StrongRow watch app.
//
// This is a *watch app*, not a data field, on purpose: Connect IQ forbids
// high-frequency accelerometer access (Sensor.registerSensorDataListener)
// from data fields ("Will cause an app crash if called from a data field
// app"). A watch app may read the raw 25 Hz accelerometer, which is what the
// low-rate stroke detector needs.
class StrongRowApp extends App.AppBase {

    hidden var mView;

    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() {
        mView = new StrongRowView();
        return [ mView, new StrongRowDelegate(mView) ];
    }

    function onStop(state) {
        if (mView != null) {
            mView.shutdown();
        }
    }

    // Fired when the user changes settings in Garmin Connect.
    function onSettingsChanged() {
        if (mView != null) {
            mView.reloadSettings();
        }
    }
}
