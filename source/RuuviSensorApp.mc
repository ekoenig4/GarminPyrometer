//
// RuuviSensorApp.mc
//
// Application entry point for the RuuviSensor data field.
//
//   * Data field mode (getInitialView()): BLE is started a few seconds after
//     the field starts (see ensureScanner()) and the scanner decodes Ruuvi
//     broadcasts for the sensors in the list.
//   * Settings mode (getSettingsView()): the on-device menu edits the sensor
//     list and units. It never touches BLE: on the Montana, BLE activity in
//     that context caused a System Error when the menu closed.
//
import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;
using Toybox.BluetoothLowEnergy as Ble;

class RuuviSensorApp extends Application.AppBase {

    // BLE is started this long after the data field view is created, so the
    // previous instance's BLE state has been cleaned up first.
    private const BLE_START_DELAY_MS = 3000;

    // Scanner; created in data field mode only.
    private var mScanner as RuuviScanner?;

    // System.getTimer() when getInitialView() ran (0 = not in data field mode).
    private var mViewStartMs as Number = 0;

    // Display units, cached from the settings (see loadUnits()).
    private var mFahrenheit as Boolean = false;
    private var mPressureUnit as Number = 0;   // RuuviConfig.PRESSURE_*

    //! Constructor.
    function initialize() {
        AppBase.initialize();
    }

    //! Called when the app starts (data field or settings menu).
    //! @param state Startup arguments (unused)
    function onStart(state as Dictionary?) as Void {
    }

    //! Called when the data field is removed or the activity ends.
    //! @param state Shutdown arguments (unused)
    function onStop(state as Dictionary?) as Void {
        var scanner = mScanner;
        if (scanner != null) {
            scanner.shutdown();
        }
    }

    //! Returns the data field view.
    //! @return Array containing the RuuviSensorView
    function getInitialView() {
        mViewStartMs = System.getTimer();
        loadUnits();
        return [new RuuviSensorView()];
    }

    //! Returns the on-device settings menu (sensor list and units). On the
    //! device it is reached from the Connect IQ data field menu.
    //! @return [Menu2, Menu2InputDelegate]
    function getSettingsView() {
        return [new RuuviMainMenu(), new RuuviMainMenuDelegate()];
    }

    //! Called when settings are changed from Garmin Connect (store installs).
    function onSettingsChanged() as Void {
        applySettings();
    }

    //! Re-reads units and the sensor list.
    function applySettings() as Void {
        loadUnits();
        var scanner = mScanner;
        if (scanner != null) {
            scanner.reloadDevices();
        }
        WatchUi.requestUpdate();
    }

    //! Returns the scanner, starting BLE once BLE_START_DELAY_MS has passed
    //! since the data field view was created. Called by the view on every
    //! compute().
    //! @return Scanner, or null while waiting / when BLE is unsupported
    function ensureScanner() as RuuviScanner? {
        if (mScanner == null && mViewStartMs != 0
                && (System.getTimer() - mViewStartMs) >= BLE_START_DELAY_MS) {
            startScanner();
        }
        return mScanner;
    }

    //! @return true if this product supports Connect IQ BLE
    function hasBle() as Boolean {
        return (Toybox has :BluetoothLowEnergy);
    }

    //! @return true to show temperatures in °F
    function useFahrenheit() as Boolean {
        return mFahrenheit;
    }

    //! @return Pressure unit (RuuviConfig.PRESSURE_*)
    function getPressureUnit() as Number {
        return mPressureUnit;
    }

    //! Creates the scanner, registers it and starts scanning. Idempotent.
    private function startScanner() as Void {
        if (mScanner != null || !hasBle()) {
            return;
        }
        try {
            var scanner = new RuuviScanner();
            // Simulator builds feed fake tags and never touch BLE.
            if (!scanner.isFake()) {
                Ble.setDelegate(scanner);
            }
            mScanner = scanner;
            scanner.start();
        } catch (e) {
            System.println("RuuviSensor: BLE start failed: " + e.getErrorMessage());
        }
    }

    //! Caches the display units so compute() does not read properties every
    //! second.
    private function loadUnits() as Void {
        mFahrenheit = RuuviConfig.useFahrenheit();
        mPressureUnit = RuuviConfig.getNumber(RuuviConfig.PRESSURE_UNIT_KEY, RuuviConfig.PRESSURE_HPA);
    }
}

//! Returns the running application instance.
function getApp() as RuuviSensorApp {
    return Application.getApp() as RuuviSensorApp;
}
