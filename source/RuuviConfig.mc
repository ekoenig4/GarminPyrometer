//
// RuuviConfig.mc
//
// Shared configuration for RuuviSensor:
//   * The sensor list, kept in Application.Storage under DEVICES_KEY as an
//     array of rows [mac, name, show, visible]:
//       mac     - 12 upper-case hex digits of the tag's MAC address (the lock)
//       name    - display name, shown as the sensor's header in the field
//       show    - which quantity the field displays (SHOW_*)
//       visible - true if the field shows this sensor (chosen under Display)
//     Rows saved by older versions have no visible flag; they load as
//     visible. Storage (not Properties) is used because the list has a
//     variable length; it is edited from the on-device settings menu.
//   * The nearby-tag list the running data field saves for the settings
//     menu (NEARBY_KEY, rows [mac, label, rssi, epochSeconds]).
//   * Display units, kept in Properties (TempUnit / PressureUnit) so they can
//     also be set from Garmin Connect for store installs.
//
import Toybox.Application;
import Toybox.Lang;
import Toybox.System;

module RuuviConfig {

    // ---- Sensor list ----
    const MAX_DEVICES = 8;
    const DEVICES_KEY = "devices";
    const F_MAC = 0;
    const F_NAME = 1;
    const F_SHOW = 2;
    const F_VISIBLE = 3;

    // ---- Nearby tags saved by the data field ----
    const NEARBY_KEY = "nearbyTags";   // new key: older builds used "nearby" with another layout

    // ---- What a sensor's field shows ----
    const SHOW_ALL = 0;           // "T:20.3 H:37 P:795"
    const SHOW_TEMPERATURE = 1;   // "20.3 °C" (default)
    const SHOW_HUMIDITY = 2;      // "37 %RH"
    const SHOW_PRESSURE = 3;      // "795 hPa"
    const SHOW_LABELS = ["All", "Temperature", "Humidity", "Pressure"];

    // ---- Display units (Properties) ----
    const TEMP_UNIT_KEY = "TempUnit";
    const TEMP_DEVICE = 0;        // follow the device's own unit setting
    const TEMP_C = 1;
    const TEMP_F = 2;
    const TEMP_UNIT_LABELS = ["Device setting", "°C", "°F"];

    const PRESSURE_UNIT_KEY = "PressureUnit";
    const PRESSURE_HPA = 0;
    const PRESSURE_INHG = 1;
    const PRESSURE_MMHG = 2;
    const PRESSURE_UNIT_LABELS = ["hPa", "inHg", "mmHg"];

    // ---------------------------------------------------------------------
    // Sensor list
    // ---------------------------------------------------------------------

    //! Loads the sensor list, dropping malformed rows.
    //! @return Array of [mac, name, show, visible] rows (possibly empty)
    function loadDevices() as Array<Array> {
        var out = [] as Array<Array>;
        var raw = null;
        try {
            raw = Application.Storage.getValue(DEVICES_KEY);
        } catch (e) {
            System.println("RuuviSensor: cannot read sensor list: " + e.getErrorMessage());
        }
        if (raw instanceof Array) {
            var rows = raw as Array;
            for (var i = 0; i < rows.size() && out.size() < MAX_DEVICES; i++) {
                var row = rows[i];
                if (row instanceof Array) {
                    var r = row as Array;
                    if (r.size() >= 3 && r[F_MAC] instanceof String && r[F_NAME] instanceof String
                            && r[F_SHOW] instanceof Number) {
                        var visible = (r.size() > F_VISIBLE && r[F_VISIBLE] instanceof Boolean)
                            ? r[F_VISIBLE] : true;
                        out.add([r[F_MAC], r[F_NAME], r[F_SHOW], visible]);
                    }
                }
            }
        }
        return out;
    }

    //! Saves the sensor list.
    //! @param devices Array of [mac, name, show, visible] rows
    function saveDevices(devices as Array<Array>) as Void {
        try {
            Application.Storage.setValue(DEVICES_KEY, devices);
        } catch (e) {
            System.println("RuuviSensor: cannot save sensor list: " + e.getErrorMessage());
        }
    }

    //! @param devices Sensor list
    //! @param mac     12 hex digits
    //! @return Index of the row locked to mac, or -1
    function findDevice(devices as Array<Array>, mac as String) as Number {
        for (var i = 0; i < devices.size(); i++) {
            if (mac.equals(devices[i][F_MAC])) {
                return i;
            }
        }
        return -1;
    }

    //! Adds a sensor locked to mac (no-op if present or the list is full).
    //! New sensors show temperature and are visible.
    //! @param mac  12 hex digits
    //! @param name Display name
    //! @return true if added
    function addDevice(mac as String, name as String) as Boolean {
        var devices = loadDevices();
        if (devices.size() >= MAX_DEVICES || findDevice(devices, mac) >= 0) {
            return false;
        }
        devices.add([mac, name, SHOW_TEMPERATURE, true]);
        saveDevices(devices);
        return true;
    }

    //! Removes the sensor locked to mac.
    //! @param mac 12 hex digits
    function removeDevice(mac as String) as Void {
        var devices = loadDevices();
        var kept = [] as Array<Array>;
        for (var i = 0; i < devices.size(); i++) {
            if (!mac.equals(devices[i][F_MAC])) {
                kept.add(devices[i]);
            }
        }
        saveDevices(kept);
    }

    //! Changes one field (F_NAME, F_SHOW or F_VISIBLE) of the sensor locked
    //! to mac.
    //! @param mac   12 hex digits
    //! @param field F_NAME, F_SHOW or F_VISIBLE
    //! @param value New value
    function updateDevice(mac as String, field as Number, value) as Void {
        var devices = loadDevices();
        var idx = findDevice(devices, mac);
        if (idx >= 0) {
            devices[idx][field] = value;
            saveDevices(devices);
        }
    }

    //! @param devices Sensor list
    //! @return Indices of the sensors the field shows, in list order
    function visibleIndices(devices as Array<Array>) as Array<Number> {
        var out = [] as Array<Number>;
        for (var i = 0; i < devices.size(); i++) {
            if (devices[i][F_VISIBLE] == true) {
                out.add(i);
            }
        }
        return out;
    }

    //! @param mac 12 hex digits
    //! @return Stored row for mac, or null
    function getDevice(mac as String) as Array? {
        var devices = loadDevices();
        var idx = findDevice(devices, mac);
        return (idx >= 0) ? devices[idx] : null;
    }

    //! @param mac 12 hex digits
    //! @return "EF:1E:4A:22:BB:F3"
    function formatMac(mac as String) as String {
        if (mac.length() != 12) {
            return mac;
        }
        var out = mac.substring(0, 2);
        for (var i = 2; i < 12; i += 2) {
            out += ":" + mac.substring(i, i + 2);
        }
        return out;
    }

    // ---------------------------------------------------------------------
    // Units
    // ---------------------------------------------------------------------

    //! Reads a number property.
    //! @param key      Property id
    //! @param fallback Value when missing or not a number
    //! @return Stored value or fallback
    function getNumber(key as String, fallback as Number) as Number {
        try {
            var value = Application.Properties.getValue(key);
            if (value instanceof Number) {
                return value as Number;
            }
        } catch (e) {
            System.println("RuuviSensor: missing property " + key);
        }
        return fallback;
    }

    //! Writes a number property.
    //! @param key   Property id
    //! @param value New value
    function setNumber(key as String, value as Number) as Void {
        try {
            Application.Properties.setValue(key, value);
        } catch (e) {
            System.println("RuuviSensor: cannot save " + key + ": " + e.getErrorMessage());
        }
    }

    //! @return true if temperatures should be shown in °F, taking "Device
    //! setting" from the device's own temperature unit setting
    function useFahrenheit() as Boolean {
        var unit = getNumber(TEMP_UNIT_KEY, TEMP_DEVICE);
        if (unit == TEMP_F) {
            return true;
        }
        if (unit == TEMP_C) {
            return false;
        }
        var ds = System.getDeviceSettings();
        return (ds has :temperatureUnits) && ds.temperatureUnits == System.UNIT_STATUTE;
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    //! @param labels Choice labels
    //! @param index  Stored choice
    //! @return Label for the choice (first label if out of range)
    function choiceLabel(labels as Array<String>, index as Number) as String {
        return (index >= 0 && index < labels.size()) ? labels[index] : labels[0];
    }

    //! Removes leading and trailing spaces and tabs.
    //! @param s Input string
    //! @return Trimmed string
    function trim(s as String) as String {
        var chars = s.toCharArray();
        var start = 0;
        var end = chars.size();
        while (start < end && (chars[start] == ' ' || chars[start] == '\t')) {
            start++;
        }
        while (end > start && (chars[end - 1] == ' ' || chars[end - 1] == '\t')) {
            end--;
        }
        return s.substring(start, end);
    }
}
