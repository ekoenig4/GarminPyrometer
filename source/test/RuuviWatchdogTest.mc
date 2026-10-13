//
// RuuviWatchdogTest.mc
//
// Unit tests for the scan watchdog's restart policy (RuuviWatchdog). See
// RuuviConfigTest.mc for how to run them.
//
import Toybox.Lang;
import Toybox.Test;

(:test)
module RuuviWatchdogTest {

    (:test)
    function intervalBacksOffToMax(logger as Logger) as Boolean {
        return RuuviWatchdog.restartInterval(0) == 10000
            && RuuviWatchdog.restartInterval(1) == 20000
            && RuuviWatchdog.restartInterval(2) == 30000
            && RuuviWatchdog.restartInterval(50) == 30000;
    }

    (:test)
    function noRestartWhileSensorsHeard(logger as Logger) as Boolean {
        // Last broadcast 5 s ago: not a stall, however long since a restart.
        return !RuuviWatchdog.restartDue(100000, 95000, 0, 0);
    }

    (:test)
    function restartAfterStall(logger as Logger) as Boolean {
        // Nothing for 6 s, last restart 10 s ago: restart.
        return RuuviWatchdog.restartDue(100000, 94000, 90000, 0)
            && !RuuviWatchdog.restartDue(100000, 94001, 90000, 0);
    }

    (:test)
    function restartsAreSpacedOut(logger as Logger) as Boolean {
        // Stalled for a minute: the gap since the last restart decides.
        return !RuuviWatchdog.restartDue(100000, 40000, 91000, 0)
            && RuuviWatchdog.restartDue(100000, 40000, 80000, 1)
            && !RuuviWatchdog.restartDue(100000, 40000, 80001, 1)
            && RuuviWatchdog.restartDue(100000, 40000, 70000, 5);
    }

    (:test)
    function handlesTimerWrap(logger as Logger) as Boolean {
        // System.getTimer() wraps; differences still work across the wrap.
        var now = -2147483648 + 3000;     // 3 s after the wrap
        var last = 2147483647 - 9000;     // about 12 s before now
        return RuuviWatchdog.restartDue(now, last, last, 0);
    }
}
