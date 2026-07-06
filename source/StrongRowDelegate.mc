using Toybox.WatchUi as Ui;

// START/STOP drives the workout (begin / pause-resume / continue-through-gate);
// BACK saves the row and exits.
class StrongRowDelegate extends Ui.BehaviorDelegate {

    hidden var mView;

    function initialize(view) {
        BehaviorDelegate.initialize();
        mView = view;
    }

    function onSelect() {
        mView.onPrimary();
        return true;
    }

    function onBack() {
        mView.stopAndSave();
        return false;
    }
}
