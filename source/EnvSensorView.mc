//
// EnvSensorView.mc
//
// SimpleDataField that shows temperature, humidity and pressure from the
// configured BLE sensors. A simple data field renders a single value, so when
// several devices are configured the view rotates through them every
// ROTATE_INTERVAL_MS, e.g.:
//
//     Balloon 1 | T:23.5 H:61 P:1013
//     Balloon 2 | SCAN
//     Balloon 3 | ---
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

    // BLE delegate (null if the product has no BLE support).
    private var mBle as EnvSensorBleDelegate?;

    // Index into the delegate's slot array of the device currently shown.
    private var mActiveSlot as Number = 0;

    // System.getTimer() value when mActiveSlot was last advanced.
    private var mLastRotateMs as Number = 0;

    //! Constructor.
    //! @param bleDelegate Shared BLE delegate, or null if BLE is unavailable
    function initialize(bleDelegate as EnvSensorBleDelegate?) {
        SimpleDataField.initialize();
        label = "ENV DATA";
        mBle = bleDelegate;
        mLastRotateMs = System.getTimer();
    }

    //! Called once per second by the activity. Drives BLE housekeeping and
    //! returns the text for the active device.
    //! @param info Activity info (unused; data comes from BLE)
    //! @return Formatted display string
    function compute(info as Activity.Info) {
        var ble = mBle;
        if (ble == null) {
            return "NO BLE";
        }

        try {
            // Timeouts, reconnects and cycling run on the compute() cadence.
            ble.tick();

            var slots = ble.getSlots();
            var active = selectActiveSlot(slots);
            if (active == null) {
                // Still scanning, so the settings menu can list nearby devices.
                return "NO SENSORS " + ble.getScanStatus();
            }
            return formatSlot(active);
        } catch (e) {
            // Never let a display problem crash the data field.
            System.println("EnvSensor: compute error: " + e.getErrorMessage());
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

    //! Formats one device as "<name> | <values>".
    //!   SCAN <status>   : searching / pairing, never connected since config;
    //!                     <status> is EnvSensorBleDelegate.getScanStatus()
    //!   ---             : link lost (auto-reconnect in progress)
    //!   WAIT            : connected, first packet not received yet
    //!   T:x H:y P:z     : latest readings ("?" suffix when stale)
    //! @param slot Device state
    //! @return Display string
    private function formatSlot(slot as EnvDeviceState) as String {
        var prefix = slot.displayName + " | ";

        if (slot.state == EnvDeviceState.STATE_SCANNING) {
            var ble = mBle;
            return prefix + "SCAN" + ((ble != null) ? (" " + ble.getScanStatus()) : "");
        }
        if (slot.state != EnvDeviceState.STATE_CONNECTED) {
            // Unavailable (or any unexpected state): configured but no link.
            return prefix + "---";
        }

        var t = slot.temperature;
        var h = slot.humidity;
        var p = slot.pressure;
        if (t == null || h == null || p == null) {
            return prefix + "WAIT";
        }

        var text = prefix
            + "T:" + t.format("%.1f")
            + " H:" + h.format("%.0f")
            + " P:" + p.format("%.0f");

        if ((System.getTimer() - slot.lastDataMs) > STALE_DATA_MS) {
            text += "?";
        }
        return text;
    }
}
