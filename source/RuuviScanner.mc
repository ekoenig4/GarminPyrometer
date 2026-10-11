//
// RuuviScanner.mc
//
// BLE delegate that listens for RuuviTag broadcasts. Ruuvi firmware (and
// Ruuvi-based sensors such as the HOTAIR pyrometer) put temperature,
// humidity, pressure and the tag's MAC address in the advertisement's
// manufacturer data (company 0x0499, data format 5 / RAWv2), so nothing is
// ever paired or connected: the scanner decodes scan results directly.
//
//   * Readings are kept for the tags in the sensor list (RuuviConfig), keyed
//     by MAC address, which is what locks a list entry to a physical tag.
//   * Every tag heard is remembered and saved to Application.Storage every
//     PUBLISH_INTERVAL_MS, so the settings menu's "Add sensor" list can offer
//     it without using BLE itself.
//   * Data fields cannot rely on Timer.Timer, so periodic work runs from
//     tick(), which the view calls once per second from compute().
//   * Simulator builds (sim.jungle) replace BLE with RuuviFakeSource, which
//     feeds made-up adverts to processAdvert() from tick().
//
import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
using Toybox.BluetoothLowEnergy as Ble;

class RuuviScanner extends Ble.BleDelegate {

    // Timing (milliseconds).
    private const SEEN_EXPIRY_MS      = 30000;   // drop nearby tags after this
    private const PUBLISH_INTERVAL_MS = 10000;   // nearby list -> Storage
    private const RELOAD_INTERVAL_MS  = 10000;   // re-read the sensor list
    private const SCAN_RETRY_MS       = 5000;    // re-request a stopped scan

    // Cap on remembered nearby tags.
    private const SEEN_MAX = 20;

    // Sensor list rows [mac, name, show] (see RuuviConfig).
    private var mDevices as Array<Array>;

    // MAC chosen under Display ("" if none: the first sensor is shown).
    private var mActive as String = "";

    // Latest readings of listed tags:
    // mac => [tempC, humidity, hPa, timerMs, batteryVolts?].
    private var mReadings as Dictionary<String, Array>;

    // Every tag heard: mac => [label, rssi, timerMs].
    private var mSeen as Dictionary<String, Array>;

    // Scan bookkeeping.
    private var mScanning as Boolean = false;
    private var mScanError as String? = null;   // shown on the field
    private var mEnded as Boolean = false;      // shutdown() called
    private var mLastScanRequestMs as Number = 0;
    private var mLastPublishMs as Number = 0;
    private var mLastReloadMs as Number = 0;

    // Made-up tags instead of BLE (simulator builds only), else null.
    private var mFake;

    //! Constructor. Loads the sensor list.
    function initialize() {
        BleDelegate.initialize();
        mDevices = RuuviConfig.loadDevices();
        mActive = RuuviConfig.getActive();
        mReadings = {} as Dictionary<String, Array>;
        mSeen = {} as Dictionary<String, Array>;
        mLastReloadMs = System.getTimer();
        mFake = createFakeSource();
    }

    // ---------------------------------------------------------------------
    // Public API
    // ---------------------------------------------------------------------

    //! @return true if tags are made up (simulator build): BLE is not used
    function isFake() as Boolean {
        return mFake != null;
    }

    //! Starts scanning (call after Ble.setDelegate(), unless isFake()).
    function start() as Void {
        setScanning(true);
    }

    //! Stops scanning for good. Called from AppBase.onStop().
    function shutdown() as Void {
        mEnded = true;
        setScanning(false);
    }

    //! Re-reads the sensor list (after a settings change).
    function reloadDevices() as Void {
        mDevices = RuuviConfig.loadDevices();
        mActive = RuuviConfig.getActive();
        mLastReloadMs = System.getTimer();
    }

    //! Periodic housekeeping; called once per second by the view.
    function tick() as Void {
        var now = System.getTimer();

        var fake = mFake;
        if (fake != null) {
            fake.tick(self, now);
        }

        // ---- Keep scanning: broadcasts are the only data source ----
        if (!mScanning && !mEnded && (now - mLastScanRequestMs) >= SCAN_RETRY_MS) {
            setScanning(true);
        }

        // ---- Share heard tags with the settings menu ----
        if ((now - mLastPublishMs) >= PUBLISH_INTERVAL_MS) {
            mLastPublishMs = now;
            publishNearby(now);
        }

        // ---- Pick up list changes made in the settings menu ----
        if ((now - mLastReloadMs) >= RELOAD_INTERVAL_MS) {
            reloadDevices();
        }
    }

    //! @return Sensor list rows [mac, name, show] (read-only)
    function getDevices() as Array<Array> {
        return mDevices;
    }

    //! @return MAC chosen under Display, or "" if none was chosen
    function getActive() as String {
        return mActive;
    }

    //! @param mac 12 hex digits
    //! @return [tempC, humidity, hPa, timerMs, batteryVolts?] or null if not
    //!         heard yet
    function getReading(mac as String) as Array? {
        return mReadings.hasKey(mac) ? mReadings[mac] : null;
    }

    //! Short scan status for the data field:
    //!   "OFF"         not scanning (retrying)
    //!   "ERR n"       the system refused to scan (status n)
    //!   "3 found"     3 Ruuvi tags heard in the last 30 s
    //! @return Status text
    function getStatus() as String {
        var err = mScanError;
        if (err != null) {
            return err;
        }
        if (!mScanning) {
            return "OFF";
        }
        return countRecent(System.getTimer()) + " found";
    }

    // ---------------------------------------------------------------------
    // BleDelegate callbacks
    // ---------------------------------------------------------------------

    //! Scan state confirmation from the system.
    //! @param scanState New scan state
    //! @param status    Ble.STATUS_SUCCESS on success
    function onScanStateChange(scanState as Ble.ScanState, status as Ble.Status) as Void {
        mScanning = (status == Ble.STATUS_SUCCESS && scanState == Ble.SCAN_STATE_SCANNING);
        if (status == Ble.STATUS_SUCCESS) {
            mScanError = null;
        } else {
            System.println("RuuviSensor: scan state change failed, status " + status);
            mScanError = "ERR " + status;
        }
    }

    //! Decodes every Ruuvi broadcast in the batch.
    //! @param scanResults Iterator of Ble.ScanResult
    function onScanResults(scanResults as Ble.Iterator) as Void {
        var now = System.getTimer();
        for (var result = scanResults.next(); result != null; result = scanResults.next()) {
            if (!(result instanceof Ble.ScanResult)) {
                continue;
            }
            var raw = null;
            try {
                raw = result.getRawData();
            } catch (e) {
                continue;
            }
            var rssi = result.getRssi();
            processAdvert(raw, result.getDeviceName(), (rssi != null) ? rssi : -127, now);
        }
    }

    //! Records one advert if it is a valid Ruuvi data format 5 broadcast.
    //! Public so RuuviFakeSource can feed made-up adverts.
    //! @param raw  Raw advertising bytes
    //! @param name Device name from the scan result, or null
    //! @param rssi Signal strength (dBm)
    //! @param now  System.getTimer()
    function processAdvert(raw as Lang.ByteArray?, name as String?, rssi as Number, now as Number) as Void {
        var vals = RuuviDecode.decodeFormat5(RuuviDecode.manufacturerData(raw));
        if (vals == null) {
            return;
        }
        var mac = vals[RuuviDecode.V_MAC] as String;

        // The name usually sits in the scan response, which this product
        // does not receive; fall back to Ruuvi's own "Ruuvi XXXX" naming
        // (last 4 hex digits of the MAC).
        var label = (name != null && name.length() > 0) ? name : ("Ruuvi " + mac.substring(8, 12));
        recordSeen(mac, label, rssi, now);

        if (RuuviConfig.findDevice(mDevices, mac) >= 0) {
            mReadings[mac] = [vals[RuuviDecode.V_TEMP], vals[RuuviDecode.V_HUMIDITY],
                vals[RuuviDecode.V_PRESSURE], now, vals[RuuviDecode.V_BATTERY]];
        }
    }

    // ---------------------------------------------------------------------
    // Nearby tags
    // ---------------------------------------------------------------------

    //! Remembers a heard tag. When the list is full, expired entries are
    //! dropped first, then the weakest if the new tag is stronger.
    //! @param mac   12 hex digits
    //! @param label Name to show in the "Add sensor" list
    //! @param rssi  Signal strength (dBm)
    //! @param now   System.getTimer()
    private function recordSeen(mac as String, label as String, rssi as Number, now as Number) as Void {
        if (!mSeen.hasKey(mac) && mSeen.size() >= SEEN_MAX) {
            var keys = mSeen.keys();
            var weakest = null;
            var weakestRssi = 0;
            for (var i = 0; i < keys.size(); i++) {
                var entry = mSeen[keys[i]];
                if (entry == null || (now - (entry[2] as Number)) > SEEN_EXPIRY_MS) {
                    mSeen.remove(keys[i]);
                } else if (weakest == null || (entry[1] as Number) < weakestRssi) {
                    weakest = keys[i];
                    weakestRssi = entry[1] as Number;
                }
            }
            if (mSeen.size() >= SEEN_MAX) {
                if (weakest == null || rssi <= weakestRssi) {
                    return;
                }
                mSeen.remove(weakest);
            }
        }
        mSeen[mac] = [label, rssi, now];
    }

    //! @param now System.getTimer()
    //! @return Number of tags heard in the last SEEN_EXPIRY_MS
    private function countRecent(now as Number) as Number {
        var count = 0;
        var keys = mSeen.keys();
        for (var i = 0; i < keys.size(); i++) {
            var entry = mSeen[keys[i]];
            if (entry != null && (now - (entry[2] as Number)) <= SEEN_EXPIRY_MS) {
                count++;
            }
        }
        return count;
    }

    //! Saves recently heard tags to Storage (NEARBY_KEY), strongest first, as
    //! rows [mac, label, rssi, epochSeconds]. Only written when non-empty.
    //! @param now System.getTimer()
    private function publishNearby(now as Number) as Void {
        var stamp = Time.now().value();
        var rows = [];
        var keys = mSeen.keys();
        for (var i = 0; i < keys.size(); i++) {
            var entry = mSeen[keys[i]];
            if (entry == null || (now - (entry[2] as Number)) > SEEN_EXPIRY_MS) {
                continue;
            }
            var row = [keys[i], entry[0], entry[1], stamp];
            // Insertion sort by RSSI (descending); lists are tiny.
            var pos = rows.size();
            while (pos > 0 && ((rows[pos - 1] as Array)[2] as Number) < (entry[1] as Number)) {
                pos--;
            }
            rows = rows.slice(0, pos).addAll([row]).addAll(rows.slice(pos, null));
        }
        if (rows.size() == 0) {
            return;
        }
        try {
            Application.Storage.setValue(RuuviConfig.NEARBY_KEY, rows);
        } catch (e) {
            System.println("RuuviSensor: cannot save nearby list: " + e.getErrorMessage());
        }
    }

    // ---------------------------------------------------------------------
    // Scanning
    // ---------------------------------------------------------------------

    //! Requests a scan state change if it differs from the current one.
    //! @param on true to scan
    private function setScanning(on as Boolean) as Void {
        // Never start a scan once the app is closing.
        if (on == mScanning || (on && mEnded)) {
            return;
        }
        mLastScanRequestMs = System.getTimer();
        if (mFake != null) {
            // Made-up tags are always "heard"; BLE is never touched.
            mScanning = on;
            return;
        }
        try {
            Ble.setScanState(on ? Ble.SCAN_STATE_SCANNING : Ble.SCAN_STATE_OFF);
            // Optimistic; onScanStateChange() confirms the real state.
            mScanning = on;
        } catch (e) {
            System.println("RuuviSensor: setScanState failed: " + e.getErrorMessage());
            mScanError = "ERR";
        }
    }
}
