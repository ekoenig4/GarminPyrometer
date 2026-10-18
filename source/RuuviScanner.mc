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
//   * Scan watchdog: if no displayed sensor (switched on under Display) has
//     been heard for STALL_MS, the scan is restarted (off, then on at the
//     next tick), in case the system stopped delivering results without
//     saying so. Sensors that are only logged never trigger a restart. Restarts back off
//     (RuuviWatchdog) while nothing is heard, so tags that are simply out of
//     range do not keep the scan restarting every few seconds.
//   * Diagnostics go to the app log (trace()): scan state changes,
//     restarts, a sensor heard again after a gap, and a summary every
//     STATS_INTERVAL_MS.
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
    private const SCAN_RETRY_MS       = 2000;    // re-request a stopped scan
    private const GAP_LOG_MS          = 10000;   // log sensors back after this gap
    private const STATS_INTERVAL_MS   = 30000;   // scan summary in the log

    // Cap on remembered nearby tags.
    private const SEEN_MAX = 20;

    // Ruuvi manufacturer data: company id 0x0499 (little endian 0x99 0x04).
    private const RUUVI_COMPANY_LO = 0x99;
    private const RUUVI_COMPANY_HI = 0x04;
    private const RUUVI_FORMAT_5   = 0x05;

    // Sensor list rows [mac, name, show, visible] (see RuuviConfig).
    private var mDevices as Array<Array>;

    // Latest readings of listed tags: mac => [tempC, humidity, hPa, timerMs].
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

    // Watchdog: whether any sensor is displayed, last advert from a
    // displayed sensor, last restart, restarts since a displayed sensor was
    // last heard, and an off -> on restart in progress (the scan is switched
    // back on at the next tick).
    private var mHasShown as Boolean = false;
    private var mLastShownMs as Number = 0;
    private var mLastRestartMs as Number = 0;
    private var mFailedRestarts as Number = 0;
    private var mRestartPending as Boolean = false;

    // Diagnostics: totals since the last summary, and restarts overall.
    private var mAdverts as Number = 0;          // every scan result
    private var mRuuviAdverts as Number = 0;     // Ruuvi format 5 broadcasts
    private var mListedAdverts as Number = 0;    // from listed sensors
    private var mRestarts as Number = 0;
    private var mLastStatsMs as Number = 0;

    //! Constructor. Loads the sensor list.
    function initialize() {
        BleDelegate.initialize();
        mDevices = RuuviConfig.loadDevices();
        mReadings = {} as Dictionary<String, Array>;
        mSeen = {} as Dictionary<String, Array>;
        var now = System.getTimer();
        mLastReloadMs = now;
        mHasShown = RuuviConfig.visibleIndices(mDevices).size() > 0;
        mLastShownMs = now;
        mLastRestartMs = now;
        mLastStatsMs = now;
    }

    // ---------------------------------------------------------------------
    // Public API
    // ---------------------------------------------------------------------

    //! Starts scanning (call after Ble.setDelegate()).
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
        var now = System.getTimer();
        mDevices = RuuviConfig.loadDevices();
        mLastReloadMs = now;
        var hasShown = RuuviConfig.visibleIndices(mDevices).size() > 0;
        if (hasShown && !mHasShown) {
            // A sensor was just switched on: give it STALL_MS before the
            // watchdog counts it as silent.
            mLastShownMs = now;
            mFailedRestarts = 0;
        }
        mHasShown = hasShown;
    }

    //! Periodic housekeeping; called once per second by the view.
    function tick() as Void {
        var now = System.getTimer();

        // ---- Scan summary in the log (before any restart below) ----
        if ((now - mLastStatsMs) >= STATS_INTERVAL_MS) {
            logStats(now);
        }

        // ---- Keep scanning: broadcasts are the only data source ----
        if (mRestartPending) {
            // Second half of a watchdog restart: switch the scan back on.
            mRestartPending = false;
            setScanning(true);
        } else if (!mScanning && !mEnded && (now - mLastScanRequestMs) >= SCAN_RETRY_MS) {
            setScanning(true);
        } else if (mScanning && !mEnded && mHasShown
                && RuuviWatchdog.restartDue(now, mLastShownMs, mLastRestartMs, mFailedRestarts)) {
            restartScan(now);
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

    //! @return Sensor list rows [mac, name, show, visible] (read-only)
    function getDevices() as Array<Array> {
        return mDevices;
    }

    //! @param mac 12 hex digits
    //! @return [tempC, humidity, hPa, timerMs] or null if not heard yet
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
        if (mEnded) {
            // Late confirmation of the final SCAN_STATE_OFF: nothing to update.
            mScanning = false;
            return;
        }
        trace("scan state " + ((scanState == Ble.SCAN_STATE_SCANNING) ? "on" : "off")
            + " status " + status);
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
        if (mEnded) {
            return;   // results still queued when the app stopped
        }
        var now = System.getTimer();
        for (var result = scanResults.next(); result != null; result = scanResults.next()) {
            if (!(result instanceof Ble.ScanResult)) {
                continue;
            }
            mAdverts++;
            var vals = decodeRuuvi(result);
            if (vals == null) {
                continue;
            }
            mRuuviAdverts++;
            var mac = vals[3] as String;

            // The name usually sits in the scan response, which this product
            // does not receive; fall back to Ruuvi's own "Ruuvi XXXX" naming
            // (last 4 hex digits of the MAC).
            var name = result.getDeviceName();
            var label = (name != null && name.length() > 0) ? name : ("Ruuvi " + mac.substring(8, 12));
            var rssi = result.getRssi();
            recordSeen(mac, label, (rssi != null) ? rssi : -127, now);

            var idx = RuuviConfig.findDevice(mDevices, mac);
            if (idx >= 0) {
                noteListedAdvert(idx, mac, now);
                mReadings[mac] = [vals[0], vals[1], vals[2], now];
            }
        }
    }

    // ---------------------------------------------------------------------
    // Ruuvi decoding
    // ---------------------------------------------------------------------

    //! Decodes a Ruuvi data format 5 (RAWv2) broadcast from the raw
    //! advertising data. Layout after the 0x0499 company id:
    //!   [0] 0x05  [1-2] temp int16 x0.005 C  [3-4] humidity uint16 x0.0025 %
    //!   [5-6] pressure uint16 +50000 Pa  ...  [18-23] MAC address
    //! @param result Scan result
    //! @return [temperatureC, humidityPct, pressureHpa, macHex] or null if
    //!         this is not a valid Ruuvi format 5 broadcast
    private function decodeRuuvi(result as Ble.ScanResult) as Array? {
        var data = null;
        try {
            data = ruuviManufacturerData(result.getRawData());
        } catch (e) {
            return null;
        }
        if (data == null || data.size() < 24 || data[0] != RUUVI_FORMAT_5) {
            return null;
        }

        var t = (data[1] << 8) | data[2];
        var h = (data[3] << 8) | data[4];
        var p = (data[5] << 8) | data[6];
        // 0x8000 / 0xFFFF mark "not available" in format 5.
        if (t == 0x8000 || h == 0xFFFF || p == 0xFFFF) {
            return null;
        }
        if (t >= 0x8000) {
            t -= 0x10000;   // int16 sign
        }

        var mac = "";
        for (var i = 18; i < 24; i++) {
            mac += data[i].format("%02X");
        }

        var hum = h * 0.0025;
        if (hum > 100.0) {
            hum = 100.0;
        }
        return [t * 0.005, hum, (p + 50000) / 100.0, mac];
    }

    //! Finds the Ruuvi manufacturer data in raw advertising data, which is a
    //! sequence of [length][type][payload...] structures (type 0xFF =
    //! manufacturer specific, payload starts with the company id).
    //! @param raw Raw advertising bytes (may be null)
    //! @return Bytes after the company id, or null if not a Ruuvi advert
    private function ruuviManufacturerData(raw as Lang.ByteArray?) as Lang.ByteArray? {
        if (raw == null) {
            return null;
        }
        var i = 0;
        while (i + 1 < raw.size()) {
            var len = raw[i];
            if (len == 0 || i + len >= raw.size()) {
                return null;
            }
            if (raw[i + 1] == 0xFF && len >= 3
                    && raw[i + 2] == RUUVI_COMPANY_LO && raw[i + 3] == RUUVI_COMPANY_HI) {
                return raw.slice(i + 4, i + 1 + len);
            }
            i += len + 1;
        }
        return null;
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

    //! Bookkeeping for a broadcast from a listed sensor: displayed sensors
    //! reset the watchdog; any listed sensor's first broadcast and its
    //! return after a gap of GAP_LOG_MS or more are logged.
    //! @param idx Index in the sensor list
    //! @param mac 12 hex digits
    //! @param now System.getTimer()
    private function noteListedAdvert(idx as Number, mac as String, now as Number) as Void {
        mListedAdverts++;
        if (mDevices[idx][RuuviConfig.F_VISIBLE] == true) {
            mLastShownMs = now;
            mFailedRestarts = 0;
        }
        var prev = mReadings[mac];
        if (prev == null) {
            trace(mDevices[idx][RuuviConfig.F_NAME] + " first heard");
        } else if ((now - (prev[3] as Number)) >= GAP_LOG_MS) {
            trace(mDevices[idx][RuuviConfig.F_NAME] + " heard again after "
                + ((now - (prev[3] as Number)) / 1000) + " s");
        }
    }

    //! Watchdog: switches the scan off; tick() switches it back on next
    //! time (about a second later).
    //! @param now System.getTimer()
    private function restartScan(now as Number) as Void {
        trace("scan restart, no displayed sensor heard for " + ((now - mLastShownMs) / 1000)
            + " s (restart " + (mFailedRestarts + 1) + " in a row)");
        mRestarts++;
        mFailedRestarts++;
        mLastRestartMs = now;
        mRestartPending = true;
        setScanning(false);
    }

    //! Logs a scan summary and starts a new counting period.
    //! @param now System.getTimer()
    private function logStats(now as Number) as Void {
        trace("scan " + (mScanning ? "on" : "off") + " adverts " + mAdverts + " ruuvi " + mRuuviAdverts
            + " listed " + mListedAdverts + " in " + ((now - mLastStatsMs) / 1000) + " s, restarts "
            + mRestarts + ", last displayed " + ((now - mLastShownMs) / 1000) + " s ago");
        mAdverts = 0;
        mRuuviAdverts = 0;
        mListedAdverts = 0;
        mLastStatsMs = now;
    }

    //! Requests a scan state change if it differs from the current one.
    //! @param on true to scan
    private function setScanning(on as Boolean) as Void {
        // Never start a scan once the app is closing.
        if (on == mScanning || (on && mEnded)) {
            return;
        }
        mLastScanRequestMs = System.getTimer();
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

//! Restart policy of the scan watchdog (see RuuviScanner.tick()).
module RuuviWatchdog {

    // No broadcast from any displayed sensor for this long counts as a stall.
    const STALL_MS = 6000;
    // Time between restarts: RESTART_MIN_MS, doubling with each restart that
    // brings nothing back, up to RESTART_MAX_MS.
    const RESTART_MIN_MS = 10000;
    const RESTART_MAX_MS = 30000;

    //! @param failed Restarts in a row with no displayed sensor heard since
    //! @return Minimum time since the last restart before the next one
    function restartInterval(failed as Number) as Number {
        var ms = RESTART_MIN_MS;
        for (var i = 0; i < failed && ms < RESTART_MAX_MS; i++) {
            ms *= 2;
        }
        return (ms > RESTART_MAX_MS) ? RESTART_MAX_MS : ms;
    }

    //! @param now           System.getTimer()
    //! @param lastShownMs   Last broadcast from a displayed sensor (or scan
    //!                      start, or when one was switched on)
    //! @param lastRestartMs Last restart (or scan start)
    //! @param failed        Restarts in a row with nothing heard since
    //! @return true if the scan should be restarted now
    function restartDue(now as Number, lastShownMs as Number, lastRestartMs as Number,
            failed as Number) as Boolean {
        return (now - lastShownMs) >= STALL_MS && (now - lastRestartMs) >= restartInterval(failed);
    }
}
