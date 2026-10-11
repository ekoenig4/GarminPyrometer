//
// EnvSensorView.mc
//
// SimpleDataField that shows temperature, humidity and/or pressure from the
// configured BLE sensors. The field's label (header) is the device's display
// name and the value is the quantity chosen in that device's "Show" setting:
//
//     header      value
//     Balloon 1   T:23.5 H:61 P:1013     (Show = All)
//     Balloon 1   23.5°C                 (Show = Temperature)
//     Balloon 2   SCAN 5 dev RUUVI
//     Balloon 3   ---
//
// A simple data field renders a single value, so when several devices are
// configured the view rotates through them every ROTATE_INTERVAL_MS.
//
import Toybox.Activity;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

class EnvSensorView extends WatchUi.SimpleDataField {

    // How long each device stays on screen when several are configured.
    private const ROTATE_INTERVAL_MS = 3000;

    // Readings older than this are flagged with "?" (sensor went quiet).
    private const STALE_DATA_MS = 30000;

    // Header when no device is configured.
    private const APP_LABEL = "RuuviSensor";

    // BLE delegate, obtained from the app once BLE has started.
    private var mBle as EnvSensorBleDelegate?;

    // Index into the delegate's slot array of the device currently shown.
    private var mActiveSlot as Number = 0;

    // System.getTimer() value when mActiveSlot was last advanced.
    private var mLastRotateMs as Number = 0;

    //! Constructor.
    function initialize() {
        SimpleDataField.initialize();
        label = initialLabel();
        mLastRotateMs = System.getTimer();
    }

    //! Header before BLE starts: the first configured device's display name
    //! (some products only read the label once, at start-up).
    //! @return Label text
    private function initialLabel() as String {
        for (var i = 0; i < EnvSensorApp.MAX_DEVICES; i++) {
            if (EnvSettings.getBleId(i).length() > 0) {
                return EnvSettings.getDisplayName(i);
            }
        }
        return APP_LABEL;
    }

    //! Called once per second by the activity. Drives BLE housekeeping and
    //! returns the text for the active device.
    //! @param info Activity info (unused; data comes from BLE)
    //! @return Formatted display string
    function compute(info as Activity.Info) {
        // BLE starts a few seconds after the field does (see EnvSensorApp).
        var app = getApp();
        var ble = app.ensureBle();
        mBle = ble;
        if (ble == null) {
            return app.hasBle() ? "STARTING" : "NO BLE";
        }

        try {
            // Timeouts, reconnects and cycling run on the compute() cadence.
            ble.tick();

            var slots = ble.getSlots();
            var active = selectActiveSlot(slots);
            if (active == null) {
                // Still scanning, so the settings menu can list nearby devices.
                label = APP_LABEL;
                return "NO SENSORS " + ble.getScanStatus();
            }
            label = active.displayName;
            return formatSlot(active);
        } catch (e) {
            // Never let a display problem crash the data field.
            System.println("RuuviSensor: compute error: " + e.getErrorMessage());
            return "---";
        }
    }

    //! Picks the device to display, advancing to the next enabled slot every
    //! ROTATE_INTERVAL_MS. Copes with slots being enabled / disabled by a
    //! mid-activity settings change.
    //! @param slots All device slots
    //! @return Active slot, or null if no slot is enabled
    private function selectActiveSlot(slots as Array<EnvDeviceState>) as EnvDeviceState? {
        var count = slots.size();
        if (count == 0) {
            return null;
        }
        if (mActiveSlot >= count) {
            mActiveSlot = 0;
        }

        var now = System.getTimer();
        var rotate = (now - mLastRotateMs) >= ROTATE_INTERVAL_MS;
        if (rotate) {
            mLastRotateMs = now;
        }

        // Start from the next slot when rotating, else from the current one,
        // and take the first enabled slot found.
        var start = rotate ? (mActiveSlot + 1) % count : mActiveSlot;
        for (var n = 0; n < count; n++) {
            var idx = (start + n) % count;
            if (slots[idx].isEnabled()) {
                mActiveSlot = idx;
                return slots[idx];
            }
        }
        return null;
    }

    //! Formats the value for one device (its name is in the header).
    //!   SCAN <status>   : searching / pairing, never connected since config;
    //!                     <status> is EnvSensorBleDelegate.getScanStatus()
    //!   ---             : link lost / broadcasts stopped
    //!   WAIT            : connected, first packet not received yet
    //!   readings        : per the device's Show setting ("?" suffix when stale)
    //! @param slot Device state
    //! @return Display string
    private function formatSlot(slot as EnvDeviceState) as String {
        if (slot.state == EnvDeviceState.STATE_SCANNING) {
            var ble = mBle;
            return "SCAN" + ((ble != null) ? (" " + ble.getScanStatus()) : "");
        }
        if (slot.state != EnvDeviceState.STATE_CONNECTED) {
            // Unavailable (or any unexpected state): configured but no data.
            return "---";
        }

        var t = slot.temperature;
        var h = slot.humidity;
        var p = slot.pressure;
        if (t == null || h == null || p == null) {
            return "WAIT";
        }

        // Convert to the configured units (sensor data is °C and hPa).
        var app = getApp();
        var tempText = (app.useFahrenheit() ? (t * 9.0 / 5.0 + 32.0) : t).format("%.1f");
        var tempUnit = app.useFahrenheit() ? "°F" : "°C";
        var presUnit = app.getPressureUnit();
        var presText;
        var presSuffix;
        if (presUnit == EnvSettings.PRESSURE_INHG) {
            presText = (p * 0.0295300).format("%.2f");
            presSuffix = " inHg";
        } else if (presUnit == EnvSettings.PRESSURE_MMHG) {
            presText = (p * 0.750062).format("%.0f");
            presSuffix = " mmHg";
        } else {
            presText = p.format("%.0f");
            presSuffix = " hPa";
        }

        var text;
        if (slot.show == EnvDeviceState.SHOW_TEMPERATURE) {
            text = tempText + tempUnit;
        } else if (slot.show == EnvDeviceState.SHOW_HUMIDITY) {
            text = h.format("%.0f") + "%RH";
        } else if (slot.show == EnvDeviceState.SHOW_PRESSURE) {
            text = presText + presSuffix;
        } else {
            text = "T:" + tempText
                + " H:" + h.format("%.0f")
                + " P:" + presText;
        }

        if ((System.getTimer() - slot.lastDataMs) > STALE_DATA_MS) {
            text += "?";
        }
        return text;
    }
}
