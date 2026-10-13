//
// RuuviConfigTest.mc
//
// Unit tests for RuuviConfig (sensor list handling and helpers). Run with
//
//   monkeyc -d montana7xx -f monkey.jungle -o bin/RuuviSensorTest.prg -y <key> --unit-test
//   monkeydo bin/RuuviSensorTest.prg montana7xx /t
//
// (:test) code is left out of normal builds, so it costs the device nothing.
// The list tests use the app's real Application.Storage; each one saves the
// stored sensor list first and restores it after.
//
import Toybox.Application;
import Toybox.Lang;
import Toybox.Test;

(:test)
module RuuviConfigTest {

    const MAC_A = "EF1E4A22BBF3";
    const MAC_B = "C0FFEE000001";
    const MAC_C = "C0FFEE000002";

    //! Saves the stored sensor list, then clears it.
    //! @return [devices] as stored before the test
    function begin() as Array {
        var saved = [Application.Storage.getValue(RuuviConfig.DEVICES_KEY)];
        Application.Storage.deleteValue(RuuviConfig.DEVICES_KEY);
        return saved;
    }

    //! Restores what begin() saved.
    //! @param saved Return value of begin()
    function end(saved as Array) as Void {
        restore(RuuviConfig.DEVICES_KEY, saved[0]);
    }

    //! @param key   Storage key
    //! @param value Value to store, or null to delete the key
    function restore(key as String, value) as Void {
        if (value == null) {
            Application.Storage.deleteValue(key);
        } else {
            Application.Storage.setValue(key, value as Application.PropertyValueType);
        }
    }

    //! @return MACs of the stored list, in order, e.g. "A,B"
    function macs() as String {
        var devices = RuuviConfig.loadDevices();
        var out = "";
        for (var i = 0; i < devices.size(); i++) {
            out += ((i > 0) ? "," : "") + devices[i][RuuviConfig.F_MAC];
        }
        return out;
    }

    // ---------------------------------------------------------------------
    // Pure helpers
    // ---------------------------------------------------------------------

    (:test)
    function findDeviceByMac(logger as Logger) as Boolean {
        var devices = [[MAC_A, "a", 1], [MAC_B, "b", 1]] as Array<Array>;
        return RuuviConfig.findDevice(devices, MAC_B) == 1
            && RuuviConfig.findDevice(devices, MAC_C) == -1
            && RuuviConfig.findDevice([] as Array<Array>, MAC_A) == -1;
    }

    (:test)
    function visibleIndicesKeepsListOrder(logger as Logger) as Boolean {
        var devices = [[MAC_A, "a", 1, false], [MAC_B, "b", 1, true], [MAC_C, "c", 1, true]] as Array<Array>;
        var shown = RuuviConfig.visibleIndices(devices);
        var none = RuuviConfig.visibleIndices([[MAC_A, "a", 1, false]] as Array<Array>);
        return shown.size() == 2 && shown[0] == 1 && shown[1] == 2
            && none.size() == 0
            && RuuviConfig.visibleIndices([] as Array<Array>).size() == 0;
    }

    (:test)
    function formatMacInsertsColons(logger as Logger) as Boolean {
        return RuuviConfig.formatMac(MAC_A).equals("EF:1E:4A:22:BB:F3")
            && RuuviConfig.formatMac("ABC").equals("ABC");
    }

    (:test)
    function choiceLabelClampsIndex(logger as Logger) as Boolean {
        var labels = RuuviConfig.PRESSURE_UNIT_LABELS;
        return RuuviConfig.choiceLabel(labels, RuuviConfig.PRESSURE_INHG).equals("inHg")
            && RuuviConfig.choiceLabel(labels, -1).equals("hPa")
            && RuuviConfig.choiceLabel(labels, 3).equals("hPa");
    }

    (:test)
    function trimRemovesSpacesAndTabs(logger as Logger) as Boolean {
        return RuuviConfig.trim("  Balloon 1\t").equals("Balloon 1")
            && RuuviConfig.trim("Tag").equals("Tag")
            && RuuviConfig.trim(" \t ").equals("");
    }

    // ---------------------------------------------------------------------
    // Sensor list in Storage
    // ---------------------------------------------------------------------

    (:test)
    function loadDevicesEmptyWhenUnset(logger as Logger) as Boolean {
        var saved = begin();
        var ok = RuuviConfig.loadDevices().size() == 0;
        end(saved);
        return ok;
    }

    (:test)
    function loadDevicesDropsMalformedRows(logger as Logger) as Boolean {
        var saved = begin();
        Application.Storage.setValue(RuuviConfig.DEVICES_KEY, [
            [MAC_A, "a", 1],
            "not a row",
            [MAC_B, "short row"],
            [MAC_C, 42, 1],          // name is not a string
            [MAC_B, "b", "1"],       // show is not a number
            [MAC_C, "c", 2, false, "extra"] // extra fields are dropped
        ]);
        var devices = RuuviConfig.loadDevices();
        logger.debug("loaded " + devices.toString());
        var ok = devices.size() == 2
            && macs().equals(MAC_A + "," + MAC_C)
            && devices[1].size() == 4
            && devices[1][RuuviConfig.F_VISIBLE] == false;
        end(saved);
        return ok;
    }

    (:test)
    function loadDevicesOldRowsAreVisible(logger as Logger) as Boolean {
        var saved = begin();
        // Rows saved before the visible flag existed, and a bad flag.
        Application.Storage.setValue(RuuviConfig.DEVICES_KEY, [[MAC_A, "a", 1], [MAC_B, "b", 1, 7]]);
        var devices = RuuviConfig.loadDevices();
        var ok = devices.size() == 2
            && devices[0][RuuviConfig.F_VISIBLE] == true
            && devices[1][RuuviConfig.F_VISIBLE] == true;
        end(saved);
        return ok;
    }

    (:test)
    function loadDevicesIgnoresNonArray(logger as Logger) as Boolean {
        var saved = begin();
        Application.Storage.setValue(RuuviConfig.DEVICES_KEY, "garbage");
        var ok = RuuviConfig.loadDevices().size() == 0;
        end(saved);
        return ok;
    }

    (:test)
    function addDeviceAppendsWithDefaultShow(logger as Logger) as Boolean {
        var saved = begin();
        var ok = RuuviConfig.addDevice(MAC_A, "Balloon 1")
            && RuuviConfig.addDevice(MAC_B, "Balloon 2")
            && macs().equals(MAC_A + "," + MAC_B);
        var dev = RuuviConfig.getDevice(MAC_B);
        ok = ok && dev != null
            && (dev[RuuviConfig.F_NAME] as String).equals("Balloon 2")
            && dev[RuuviConfig.F_SHOW] == RuuviConfig.SHOW_TEMPERATURE
            && dev[RuuviConfig.F_VISIBLE] == true;
        end(saved);
        return ok;
    }

    (:test)
    function addDeviceRejectsDuplicate(logger as Logger) as Boolean {
        var saved = begin();
        RuuviConfig.addDevice(MAC_A, "first");
        var ok = !RuuviConfig.addDevice(MAC_A, "again")
            && RuuviConfig.loadDevices().size() == 1
            && ((RuuviConfig.getDevice(MAC_A) as Array)[RuuviConfig.F_NAME] as String).equals("first");
        end(saved);
        return ok;
    }

    (:test)
    function addDeviceStopsAtMax(logger as Logger) as Boolean {
        var saved = begin();
        var ok = true;
        for (var i = 0; i < RuuviConfig.MAX_DEVICES; i++) {
            ok = ok && RuuviConfig.addDevice("C0FFEE00010" + i, "tag " + i);
        }
        ok = ok && !RuuviConfig.addDevice(MAC_A, "one too many")
            && RuuviConfig.loadDevices().size() == RuuviConfig.MAX_DEVICES
            && RuuviConfig.getDevice(MAC_A) == null;
        end(saved);
        return ok;
    }

    (:test)
    function loadDevicesCapsAtMax(logger as Logger) as Boolean {
        var saved = begin();
        var rows = [];
        for (var i = 0; i < RuuviConfig.MAX_DEVICES + 3; i++) {
            rows.add(["C0FFEE00020" + i, "tag " + i, 1]);
        }
        Application.Storage.setValue(RuuviConfig.DEVICES_KEY, rows);
        var ok = RuuviConfig.loadDevices().size() == RuuviConfig.MAX_DEVICES;
        end(saved);
        return ok;
    }

    (:test)
    function removeDeviceKeepsOrder(logger as Logger) as Boolean {
        var saved = begin();
        RuuviConfig.addDevice(MAC_A, "a");
        RuuviConfig.addDevice(MAC_B, "b");
        RuuviConfig.addDevice(MAC_C, "c");
        RuuviConfig.removeDevice(MAC_B);
        var ok = macs().equals(MAC_A + "," + MAC_C);
        RuuviConfig.removeDevice("000000000000");   // not listed: no change
        ok = ok && macs().equals(MAC_A + "," + MAC_C);
        end(saved);
        return ok;
    }

    (:test)
    function updateDeviceChangesOneField(logger as Logger) as Boolean {
        var saved = begin();
        RuuviConfig.addDevice(MAC_A, "a");
        RuuviConfig.addDevice(MAC_B, "b");
        RuuviConfig.updateDevice(MAC_B, RuuviConfig.F_SHOW, RuuviConfig.SHOW_PRESSURE);
        RuuviConfig.updateDevice(MAC_B, RuuviConfig.F_NAME, "renamed");
        RuuviConfig.updateDevice(MAC_B, RuuviConfig.F_VISIBLE, false);
        RuuviConfig.updateDevice(MAC_C, RuuviConfig.F_NAME, "not listed");
        var a = RuuviConfig.getDevice(MAC_A) as Array;
        var b = RuuviConfig.getDevice(MAC_B) as Array;
        var ok = (b[RuuviConfig.F_NAME] as String).equals("renamed")
            && b[RuuviConfig.F_SHOW] == RuuviConfig.SHOW_PRESSURE
            && b[RuuviConfig.F_VISIBLE] == false
            && a[RuuviConfig.F_VISIBLE] == true
            && (a[RuuviConfig.F_NAME] as String).equals("a")
            && a[RuuviConfig.F_SHOW] == RuuviConfig.SHOW_TEMPERATURE
            && RuuviConfig.getDevice(MAC_C) == null;
        end(saved);
        return ok;
    }
}
