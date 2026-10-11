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
//
import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;
using Toybox.BluetoothLowEnergy as Ble;

class EnvSensorApp extends Application.AppBase {

    // Number of configurable device slots (matches properties.xml).
    public static const MAX_DEVICES = 3;

    // BLE delegate; null when the product has no BLE support.
    private var mBleDelegate as EnvSensorBleDelegate?;

    // True once the delegate is registered with the BLE subsystem.
    private var mBleStarted as Boolean = false;

    //! Constructor. The BLE delegate is created here (rather than in onStart)
    //! so it exists before getInitialView() builds the view.
    function initialize() {
        AppBase.initialize();

        if (Toybox has :BluetoothLowEnergy) {
            mBleDelegate = new EnvSensorBleDelegate();
        } else {
            System.println("EnvSensor: BluetoothLowEnergy not supported on this product");
        }
    }

    //! Called when the app starts, both as a data field and when the
    //! on-device settings menu is opened. BLE is started later, from
    //! getInitialView() or getSettingsView(), because the two modes need it
    //! set up differently.
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
        startBle(false);
        return [new EnvSensorView(mBleDelegate)];
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
    //! Connect shows app settings only for store installs.
    //! @return [Menu2, Menu2InputDelegate]
    function getSettingsView() {
        // Discovery only: scan for nearby sensors so the "Choose sensor" list
        // is populated, but never register a profile or pair from here.
        startBle(true);
        return [new EnvSettingsMenu(), new EnvSettingsMenuDelegate()];
    }

    //! Re-reads all properties and pushes them to the BLE delegate. Called
    //! from onSettingsChanged() and by the on-device settings menu after it
    //! writes a property (Properties.setValue() does not fire
    //! onSettingsChanged()).
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

    //! @return The BLE delegate, or null if BLE is unsupported
    function getBleDelegate() as EnvSensorBleDelegate? {
        return mBleDelegate;
    }

    //! Registers the BLE delegate and applies the stored settings. Idempotent.
    //! @param discovery true for the settings menu (scan only, no profile, no
    //!                  pairing); false for the data field (normal operation)
    private function startBle(discovery as Boolean) as Void {
        var delegate = mBleDelegate;
        if (delegate == null || mBleStarted) {
            return;
        }
        try {
            Ble.setDelegate(delegate);
            mBleStarted = true;
            if (discovery) {
                // Must precede applyConfig() so no profile gets registered.
                delegate.setDiscovery(true);
            }
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
