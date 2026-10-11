//
// EnvSensorApp.mc
//
// Application entry point for the EnvSensor BLE data field.
//
// Responsibilities:
//   * Create the BLE delegate and register it with the BLE subsystem.
//   * Read the user settings (Application.Properties) and hand them to the
//     delegate as a plain configuration dictionary.
//   * Re-apply settings at runtime from onSettingsChanged() so devices can be
//     added, removed or renamed mid-activity without restarting the app.
//   * Provide the on-device settings menu (getSettingsView()), which is the
//     only way to configure the field when it was side-loaded over USB.
//     The settings menu never touches BLE: on the Montana, BLE activity in
//     that context caused a System Error when the menu closed. BLE is set up
//     only when the app runs as a data field (getInitialView()).
//
import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;
using Toybox.BluetoothLowEnergy as Ble;

class EnvSensorApp extends Application.AppBase {

    // Number of configurable device slots (matches properties.xml).
    public static const MAX_DEVICES = 3;

    // BLE delegate; created by startBle() in data field mode only, so it
    // stays null in the settings menu and on products without BLE.
    private var mBleDelegate as EnvSensorBleDelegate?;

    // BLE is started this long after the data field view is created. When
    // the on-device settings menu closes, the Montana restarts the data
    // field immediately; touching BLE before the previous instance has been
    // cleaned up left the field stuck on its icon until a reboot.
    private const BLE_START_DELAY_MS = 3000;

    // System.getTimer() when getInitialView() ran (0 = not in data field mode).
    private var mViewStartMs as Number = 0;

    //! Constructor.
    function initialize() {
        AppBase.initialize();
    }

    //! Called when the app starts, both as a data field and when the
    //! on-device settings menu is opened. BLE is started later, from the data
    //! field's compute() via ensureBle(), so the settings menu never uses it.
    //! @param state Startup arguments (unused)
    function onStart(state as Dictionary?) as Void {
    }

    //! Called when the data field is removed or the activity ends.
    //! Stops scanning and releases all paired sensors.
    //! @param state Shutdown arguments (unused)
    function onStop(state as Dictionary?) as Void {
        var delegate = mBleDelegate;
        if (delegate != null) {
            delegate.shutdown();
        }
    }

    //! Returns the initial view for the data field.
    //! @return Array containing the EnvSensorView
    function getInitialView() {
        mViewStartMs = System.getTimer();
        return [new EnvSensorView()];
    }

    //! Called by the system when the user edits the settings in Garmin Connect
    //! (or Garmin Express) while the data field is running. Re-reads every
    //! property and pushes the new scan filter list / UUIDs to the delegate.
    function onSettingsChanged() as Void {
        System.println("EnvSensor: settings changed");
        applySettings();
    }

    //! Returns the on-device settings menu. On the device this is reached from
    //! the Connect IQ / data field menu ("Settings" under EnvSensor BLE). It is
    //! the only way to configure a side-loaded (USB) install, because Garmin
    //! Connect shows app settings only for store installs. The sensor list it
    //! offers comes from Application.Storage, written by the data field.
    //! @return [Menu2, Menu2InputDelegate]
    function getSettingsView() {
        return [new EnvSettingsMenu(), new EnvSettingsMenuDelegate()];
    }

    //! Re-reads all properties and pushes them to the BLE delegate. Called
    //! from onSettingsChanged() and by the on-device settings menu after it
    //! writes a property. In the settings menu there is no delegate, so this
    //! only requests a redraw.
    function applySettings() as Void {
        var delegate = mBleDelegate;
        if (delegate != null) {
            try {
                delegate.applyConfig(readConfig());
            } catch (e) {
                System.println("EnvSensor: failed to apply settings: " + e.getErrorMessage());
            }
        }

        // Ask the view to redraw with the new labels as soon as possible.
        WatchUi.requestUpdate();
    }

    //! Returns the BLE delegate, starting BLE once BLE_START_DELAY_MS has
    //! passed since the data field view was created. Called by the view on
    //! every compute().
    //! @return Delegate, or null while waiting / when BLE is unsupported
    function ensureBle() as EnvSensorBleDelegate? {
        if (mBleDelegate == null && mViewStartMs != 0
                && (System.getTimer() - mViewStartMs) >= BLE_START_DELAY_MS) {
            startBle();
        }
        return mBleDelegate;
    }

    //! @return true if this product supports Connect IQ BLE
    function hasBle() as Boolean {
        return (Toybox has :BluetoothLowEnergy);
    }

    //! Creates and registers the BLE delegate, then applies the stored
    //! settings (starts scanning). Data field mode only. Idempotent.
    private function startBle() as Void {
        if (mBleDelegate != null) {
            return;
        }
        var hasBle = (Toybox has :BluetoothLowEnergy);
        if (hasBle == false) {
            System.println("EnvSensor: BluetoothLowEnergy not supported on this product");
            return;
        }
        try {
            var delegate = new EnvSensorBleDelegate();
            Ble.setDelegate(delegate);
            mBleDelegate = delegate;
            delegate.applyConfig(readConfig());
        } catch (e) {
            System.println("EnvSensor: BLE start failed: " + e.getErrorMessage());
        }
    }

    //! Reads all user settings into a plain configuration dictionary:
    //!   :bleIds       => Array<String>  (MAX_DEVICES entries, "" = slot disabled)
    //!   :displayNames => Array<String>  (MAX_DEVICES entries, never empty)
    //!   :serviceUuid  => String         ("" = use Nordic UART default)
    //!   :charUuid     => String         ("" = use Nordic UART TX default)
    //! @return Configuration dictionary
    private function readConfig() as Dictionary {
        var bleIds = new [MAX_DEVICES];
        var names = new [MAX_DEVICES];

        for (var i = 0; i < MAX_DEVICES; i++) {
            var n = i + 1;
            bleIds[i] = readStringProperty("Device" + n + "BleId");

            var name = readStringProperty("Device" + n + "DisplayName");
            // Fall back to a generic label so the screen is never blank.
            names[i] = (name.length() > 0) ? name : ("Sensor " + n);
        }

        return {
            :bleIds       => bleIds,
            :displayNames => names,
            :serviceUuid  => readStringProperty("CustomServiceUuid"),
            :charUuid     => readStringProperty("CustomCharUuid")
        };
    }

    //! Safely reads a string property. Missing keys, null values and
    //! non-string values all collapse to "" so callers never see null.
    //! Leading/trailing whitespace is removed.
    //! @param key Property identifier from properties.xml
    //! @return Trimmed string value, or "" if unavailable
    private function readStringProperty(key as String) as String {
        var value = null;
        try {
            value = Application.Properties.getValue(key);
        } catch (e) {
            // InvalidKeyException: property missing (e.g. stale settings).
            System.println("EnvSensor: missing property " + key);
        }

        if (value == null) {
            return "";
        }
        return EnvSensorUtil.trim(value.toString());
    }
}

//! Returns the running application instance.
function getApp() as EnvSensorApp {
    return Application.getApp() as EnvSensorApp;
}
