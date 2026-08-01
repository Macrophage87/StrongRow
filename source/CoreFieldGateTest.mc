using Toybox.Test;

// Unit tests for issue #75: the three CORE developer fields (core_temperature,
// skin_temperature, max_core_temperature) are created ONCE, inside
// startSession(), and were gated on the pod having already been heard. A pod
// acquired one second after START therefore logged nothing for the whole row,
// unrecoverably, because startSession() is guarded by `if (mSession == null)`
// and togglePause() resumes with mSession.start() without ever re-entering it.
//
// startSession() itself is not reachable in-process -- it calls
// Rec.createSession and every interesting statement operates on a real
// ActivityRecording.Session. So the DECISION is extracted into the pure
// class-scope static StrongRowView.coreFieldsWanted() and pinned here, the
// same seam RrRecordTest.mc uses for filterRr/packRr/rrIsFresh/rrGapExceeded.
//
// SCOPE, stated rather than implied: these tests pin the PREDICATE, not the
// call site. The line `if (coreFieldsWanted(mCoreSensor))` in startSession()
// is covered by review only -- a regression that reverted that one line would
// leave all four tests green. Fuller coverage of startSession() via a
// protected-subclass probe is tracked in #55.
//
// Execution note: the run-tests CI job runs these headlessly in the simulator
// on every PR (`monkeydo <prg> fr965 -t`, judged by a fail-closed parser),
// with the test names pinned in scripts/expected_tests.txt -- update that
// file in the same commit as any (:test) change here. See docs/CI.md.

// -- Stub ---------------------------------------------------------------------
// Duck-typed stand-in for CoreTempSensor. coreFieldsWanted's parameter is
// deliberately untyped, so runtime duck typing applies and this needs only the
// one member the predicate calls.
//
// CONSTRUCTOR-PARAMETERISED ON THE FLAG, on purpose. A stub hardwired to true
// would make the two #75 differentials pass against the OLD predicate, and the
// red evidence would silently not exist; a stub hardwired to false would red
// the pod-seen pin instead. Both epochs must be expressible from one stub.
//
// Referenced only from (:test) functions, so it drops out of the shipping
// build -- same argument as DspProbe in DspTimeBaseTest.mc.
class FakeCoreSensor {
    hidden var mSeen;
    function initialize(seen) { mSeen = seen; }
    function everSeen() { return mSeen; }
}

// -- Tests --------------------------------------------------------------------

// The null term must SURVIVE the #75 fix. It is defensive, not a crash guard:
// onTick:388/:392 dereference mCoreSensor guarded only by the field handle, so
// keeping this term keeps the invariant `mFitCore != null => mCoreSensor !=
// null` justified by one adjacent line instead of a whole-file lifecycle
// argument. Green in both epochs by construction -- it is here so that a fix
// which drops BOTH terms rather than just everSeen() is caught.
(:test) function test_core_gateFalseWhenSensorNull(logger) {
    if (StrongRowView.coreFieldsWanted(null) != false) {
        logger.error("coreFieldsWanted(null) must stay false: the null term is " +
                     "what keeps mFitCore != null => mCoreSensor != null local");
        return false;
    }
    return true;
}

// No regression for the case that already worked: a pod heard BEFORE START.
// Green in both epochs.
(:test) function test_core_gateTrueWhenPodSeen(logger) {
    if (StrongRowView.coreFieldsWanted(new FakeCoreSensor(true)) != true) {
        logger.error("a pod already heard at START must still get the CORE fields");
        return false;
    }
    return true;
}
