//
// EnvSensorBleDelegate.mc
//
// BLE delegate for the EnvSensor data field. Scans for up to three
// environmental sensors by advertised name, pairs with them, subscribes to the
// UART TX characteristic and parses "<temperature>,<humidity>,<pressure>"
// notifications into per-device state objects.
//
// Design notes:
//   * Connect IQ BLE is callback driven and data fields cannot rely on
//     Timer.Timer, so all timeouts / retries are driven by tick(), which the
//     view calls once per second from compute().
//   * The delegate itself keeps only BLE plumbing state (scan / request queue).
//     Everything that describes a sensor lives in EnvDeviceState objects, which
//     the view reads but never mutates.
//   * Connect IQ allows only one outstanding GATT request at a time, so CCCD
//     writes are serialized through a small queue.
//   * If the product supports fewer simultaneous connections than there are
//     configured devices, connected devices are rotated out periodically so
//     every sensor gets a turn (sequential cycling).
//   * RuuviTags (and Ruuvi-firmware sensors such as the HOTAIR pyrometer)
//     broadcast temperature, humidity and pressure in their advertisement
//     (manufacturer data 0x0499, data format 5). Those are decoded straight
//     from scan results with no connection; a slot is bound to a tag by the
//     MAC address carried in that data.
//   * Nearby advertisers heard while scanning are saved to Application.Storage
//     so the on-device settings menu can list them without using BLE itself
//     (BLE use from the settings menu crashed the Montana on exit).
//
import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.StringUtil;
import Toybox.Time;
import Toybox.WatchUi;
using Toybox.BluetoothLowEnergy as Ble;

//! Per-device state. One instance exists per configured slot.
class EnvDeviceState {

    // Connection lifecycle states.
    enum {
        STATE_DISABLED,     // Slot has no BLE id configured
        STATE_SCANNING,     // Searching / pairing; never connected since config
        STATE_CONNECTED,    // Link up (data may not have arrived yet)
        STATE_UNAVAILABLE   // Was connected, link lost; reconnecting
    }

    public var bleId as String = "";        // Advertised name to match
    public var displayName as String = "";  // Label shown on screen
    public var state as Number = STATE_DISABLED;

    // Last known good readings (null until the first valid packet).
    public var temperature as Float? = null;  // degrees C
    public var humidity as Float? = null;     // % RH
    public var pressure as Float? = null;     // hPa
    public var lastDataMs as Number = 0;      // System.getTimer() of last good packet

    // BLE plumbing (owned by the delegate).
    public var device as Ble.Device? = null;          // Paired device handle
    public var scanResult as Ble.ScanResult? = null;  // Result used for pairing
    public var stateSinceMs as Number = 0;            // When the current state began
    public var pairStartMs as Number = 0;             // When pairDevice() was issued (0 = idle)
    public var notifying as Boolean = false;          // CCCD written successfully
    public var cooldownUntilMs as Number = 0;         // Ignore adverts until then (cycling)

    // Advertisement-only sensors (Ruuvi): readings come from broadcasts.
    public var advertMode as Boolean = false;         // true once bound to a broadcaster
    public var boundMac as String? = null;            // 12 hex digits of the bound tag

    //! Constructor.
    //! @param id   Advertised BLE name ("" disables the slot)
    //! @param name Display name
    function initialize(id as String, name as String) {
        bleId = id;
        displayName = name;
        state = (id.length() > 0) ? STATE_SCANNING : STATE_DISABLED;
        stateSinceMs = System.getTimer();
    }

    //! @return true when the slot has a BLE id configured
    function isEnabled() as Boolean {
        return state != STATE_DISABLED;
    }

    //! @return true when at least one valid packet has been received
    function hasData() as Boolean {
        return temperature != null && humidity != null && pressure != null;
    }

    //! Moves the slot to a new lifecycle state and records the time.
    //! @param newState One of the STATE_* values
    function setState(newState as Number) as Void {
        state = newState;
        stateSinceMs = System.getTimer();
    }
}

class EnvSensorBleDelegate extends Ble.BleDelegate {

    // Nordic UART Service defaults.
    public static const DEFAULT_SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
    public static const DEFAULT_TX_CHAR_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

    // BLE id meaning "any sensor that advertises the service UUID".
    public static const WILDCARD_ID = "*";

    // Timing (milliseconds).
    private const PAIR_TIMEOUT_MS      = 20000;   // pairDevice() -> connected
    private const RECONNECT_TIMEOUT_MS = 30000;   // system auto-reconnect window
    private const REQUEST_TIMEOUT_MS   = 5000;    // outstanding GATT request
    private const CYCLE_INTERVAL_MS    = 60000;   // min connected time before rotation
    private const SEEN_EXPIRY_MS       = 30000;   // drop nearby-device entries after this
    private const SEEN_MAX             = 20;      // cap on remembered nearby devices
    private const PUBLISH_INTERVAL_MS  = 10000;   // nearby list -> Storage
    private const PROFILE_RETRY_MS     = 10000;   // no onProfileRegister() -> retry
    private const PROFILE_MAX_ATTEMPTS = 3;
    private const ADVERT_LOST_MS       = 60000;   // broadcaster silent -> "---"

    // Ruuvi manufacturer data: company id 0x0499 (little endian 0x99 0x04).
    private const RUUVI_COMPANY_LO = 0x99;
    private const RUUVI_COMPANY_HI = 0x04;
    private const RUUVI_FORMAT_5   = 0x05;

    // Application.Storage key of the nearby-device list (read by settings).
    public static const NEARBY_KEY = "nearby";

    // CCCD value enabling notifications.
    private const CCCD_ENABLE_NOTIFY = [0x01, 0x00]b;

    // Sanity limits for parsed values; out-of-range packets are rejected.
    private const TEMP_MIN = -100.0;
    private const TEMP_MAX = 150.0;
    private const HUM_MIN = 0.0;
    private const HUM_MAX = 100.0;
    private const PRES_MIN = 1.0;
    private const PRES_MAX = 1200.0;

    // Device slots (always EnvSensorApp.MAX_DEVICES entries).
    private var mSlots as Array<EnvDeviceState>;

    // Same objects as mSlots, keyed by display name (for name lookups).
    private var mStateByName as Dictionary<String, EnvDeviceState>;

    // Active GATT UUIDs.
    private var mServiceUuid as Ble.Uuid?;
    private var mCharUuid as Ble.Uuid?;

    // String forms of profiles registered with the system (max 3 per app).
    private var mRegisteredProfiles as Array<String>;
    private var mProfileReady as Boolean = false;

    // Scan / pairing bookkeeping.
    private var mScanning as Boolean = false;
    private var mPairingSlot as Number = -1;   // slot index with pairDevice() in flight

    // Nearby advertisers heard while scanning, for the settings menu.
    // Name => [rssi, lastSeenMs, advertisesService].
    private var mSeen as Dictionary<String, Array>;
    private var mLastPublishMs as Number = 0;   // last Storage write

    // Diagnostics for adverts that carry no name (common when the name is
    // only in the scan response): last time / RSSI of any unnamed advert and
    // of an unnamed advert listing the service UUID, plus the last time any
    // advert listed the service UUID.
    private var mUnnamedMs as Number = 0;
    private var mUnnamedSvcMs as Number = 0;
    private var mUnnamedSvcRssi as Number = -127;
    private var mServiceSeenMs as Number = 0;
    private var mRuuviSeenMs as Number = 0;   // last Ruuvi broadcast heard

    // True when the GATT profile could not be registered (no pairing possible).
    private var mProfileFailed as Boolean = false;

    // True once registerProfile() has been attempted for the active UUIDs.
    private var mProfileRequested as Boolean = false;
    private var mProfileRequestMs as Number = 0;   // time of the last attempt
    private var mProfileAttempts as Number = 0;    // attempts for these UUIDs

    // Why the last scan request failed (shown on the data field), or null.
    private var mScanError as String? = null;

    // True after shutdown(): no further scans are started.
    private var mEnded as Boolean = false;

    // Serialized GATT request queue (slot indices awaiting a CCCD write).
    private var mNotifyQueue as Array<Number>;
    private var mRequestSlot as Number = -1;   // slot with a request in flight
    private var mRequestStartMs as Number = 0;

    //! Constructor. Starts with all slots disabled until applyConfig() runs.
    function initialize() {
        BleDelegate.initialize();

        mSlots = [] as Array<EnvDeviceState>;
        for (var i = 0; i < EnvSensorApp.MAX_DEVICES; i++) {
            mSlots.add(new EnvDeviceState("", "Sensor " + (i + 1)));
        }
        mStateByName = {} as Dictionary<String, EnvDeviceState>;
        mRegisteredProfiles = [] as Array<String>;
        mNotifyQueue = [] as Array<Number>;
        mSeen = {} as Dictionary<String, Array>;
    }

    // ---------------------------------------------------------------------
    // Public API (used by EnvSensorApp / EnvSensorView)
    // ---------------------------------------------------------------------

    //! Applies a configuration dictionary built by EnvSensorApp.readConfig().
    //! Safe to call repeatedly (e.g. from onSettingsChanged()):
    //!   * A changed UUID releases every device and re-registers the profile.
    //!   * A changed BLE id releases only that slot.
    //!   * A changed display name only relabels the slot (readings are kept).
    //! @param config Configuration dictionary
    function applyConfig(config as Dictionary) as Void {
        var bleIds = config[:bleIds] as Array<String>;
        var names = config[:displayNames] as Array<String>;

        // ---- Resolve UUIDs, falling back to Nordic UART on bad input ----
        var svc = parseUuid(config[:serviceUuid] as String, DEFAULT_SERVICE_UUID);
        var chr = parseUuid(config[:charUuid] as String, DEFAULT_TX_CHAR_UUID);

        var oldSvc = mServiceUuid;
        var oldChr = mCharUuid;
        var uuidChanged = (oldSvc == null) || (oldChr == null)
            || !svc.toString().equals(oldSvc.toString())
            || !chr.toString().equals(oldChr.toString());

        if (uuidChanged) {
            // Existing pairings were discovered against the old profile.
            for (var i = 0; i < mSlots.size(); i++) {
                releaseSlot(i);
            }
            mServiceUuid = svc;
            mCharUuid = chr;
            mProfileRequested = false;
            mProfileReady = false;
            mProfileFailed = false;
            mProfileAttempts = 0;
            // Registered lazily, when a device to connect to is first found
            // (Ruuvi broadcasters never need it).
        }

        // ---- Update slots ----
        mStateByName = {} as Dictionary<String, EnvDeviceState>;
        for (var i = 0; i < mSlots.size(); i++) {
            var slot = mSlots[i];
            var newId = (i < bleIds.size() && bleIds[i] != null) ? bleIds[i] : "";
            var newName = (i < names.size() && names[i] != null) ? names[i] : ("Sensor " + (i + 1));

            if (!newId.equals(slot.bleId)) {
                // Different physical sensor: drop link and readings.
                releaseSlot(i);
                mSlots[i] = new EnvDeviceState(newId, newName);
                slot = mSlots[i];
            } else {
                // Same sensor: just relabel, keep link and readings.
                slot.displayName = newName;
            }

            if (slot.isEnabled()) {
                mStateByName[slot.displayName] = slot;
            }
        }

        updateScanState();
    }

    //! Periodic housekeeping; called once per second by the view.
    //! Handles pairing / reconnect / request timeouts and connection cycling.
    function tick() as Void {
        var now = System.getTimer();

        // ---- onProfileRegister() never arrived: retry, then give up ----
        if (!mEnded && mProfileRequested && !mProfileReady && !mProfileFailed
                && (now - mProfileRequestMs) > PROFILE_RETRY_MS) {
            if (mProfileAttempts < PROFILE_MAX_ATTEMPTS) {
                System.println("EnvSensor: no profile confirmation, retrying");
                registerProfile();
            } else {
                System.println("EnvSensor: profile never confirmed, giving up");
                mProfileFailed = true;
            }
        }

        // ---- Share the nearby-device list with the settings menu ----
        if ((now - mLastPublishMs) >= PUBLISH_INTERVAL_MS) {
            mLastPublishMs = now;
            publishNearby();
        }

        // ---- Stuck GATT request: drop it and move on ----
        if (mRequestSlot >= 0 && (now - mRequestStartMs) > REQUEST_TIMEOUT_MS) {
            System.println("EnvSensor: GATT request timed out (slot " + mRequestSlot + ")");
            var stuck = mRequestSlot;
            mRequestSlot = -1;
            // Retry once the queue drains, if the device is still up.
            if (mSlots[stuck].state == EnvDeviceState.STATE_CONNECTED && !mSlots[stuck].notifying) {
                mNotifyQueue.add(stuck);
            }
            processNotifyQueue();
        }

        for (var i = 0; i < mSlots.size(); i++) {
            var slot = mSlots[i];

            // ---- Pairing never produced a connection ----
            if (slot.pairStartMs != 0 && slot.state != EnvDeviceState.STATE_CONNECTED
                    && (now - slot.pairStartMs) > PAIR_TIMEOUT_MS) {
                System.println("EnvSensor: pairing timeout for " + slot.displayName);
                var keepState = slot.state;
                releaseSlot(i);
                slot.setState(keepState);
            }

            // ---- Broadcaster went quiet: show "---" until it is heard again ----
            if (slot.advertMode && slot.state == EnvDeviceState.STATE_CONNECTED
                    && (now - slot.lastDataMs) > ADVERT_LOST_MS) {
                System.println("EnvSensor: no broadcasts from " + slot.displayName);
                slot.setState(EnvDeviceState.STATE_UNAVAILABLE);
            }

            // ---- Lost link that the system failed to restore: start over ----
            if (slot.state == EnvDeviceState.STATE_UNAVAILABLE && slot.device != null
                    && (now - slot.stateSinceMs) > RECONNECT_TIMEOUT_MS) {
                System.println("EnvSensor: reconnect timeout for " + slot.displayName + ", rescanning");
                releaseSlot(i);
                // Stay "unavailable" (shows ---) while we rescan for it.
                slot.setState(EnvDeviceState.STATE_UNAVAILABLE);
            }
        }

        cycleConnectionsIfNeeded(now);
        updateScanState();
    }

    //! Stops scanning and releases every device. Called from AppBase.onStop().
    function shutdown() as Void {
        mEnded = true;
        for (var i = 0; i < mSlots.size(); i++) {
            releaseSlot(i);
        }
        setScanning(false);
    }

    //! Short scan diagnostic for the data field, shown after "SCAN":
    //!   " NO PROFILE" GATT profile registration failed (no pairing possible)
    //!   "PAIR"        a matching device was found and is being paired
    //!   "OFF"         scanning is not running although a device is wanted
    //!   "IDLE"        scanning is not needed (all devices paired or off)
    //!   "SCAN ERR n"  the system refused to scan (status n), see the log
    //!   " setup"      GATT profile not confirmed yet (pairing waits for it)
    //!   "5 dev"       5 named devices heard in the last 30 s
    //!   "+?"          unnamed adverts are also being heard
    //!   " UART"       some advert lists the service UUID
    //!   " RUUVI"      a Ruuvi data-format-5 broadcast was heard
    //! @return Status text
    function getScanStatus() as String {
        if (mPairingSlot >= 0) {
            return "PAIR";
        }
        if (!mScanning) {
            var err = mScanError;
            if (err != null) {
                return err;
            }
            return (hasUnpairedSlot() || !hasEnabledSlot()) ? "OFF" : "IDLE";
        }
        var now = System.getTimer();
        var named = 0;
        var keys = mSeen.keys();
        for (var i = 0; i < keys.size(); i++) {
            var entry = mSeen[keys[i]];
            if (entry != null && (now - (entry[1] as Number)) <= SEEN_EXPIRY_MS) {
                named++;
            }
        }
        var text = named + " dev";
        if (mUnnamedMs != 0 && (now - mUnnamedMs) <= SEEN_EXPIRY_MS) {
            text += "+?";
        }
        if (mServiceSeenMs != 0 && (now - mServiceSeenMs) <= SEEN_EXPIRY_MS) {
            text += " UART";
        }
        if (mRuuviSeenMs != 0 && (now - mRuuviSeenMs) <= SEEN_EXPIRY_MS) {
            text += " RUUVI";
        }
        // Scanning works without the profile, but pairing needs it.
        if (mProfileFailed) {
            text += " NO PROFILE";
        } else if (mProfileRequested && !mProfileReady) {
            text += " setup";
        }
        return text;
    }

    //! Returns nearby named advertisers seen in the last SEEN_EXPIRY_MS,
    //! strongest signal first. Each entry is
    //! { :name => String, :rssi => Number, :hasService => Boolean }.
    //! If an advert listing the service UUID but carrying no name was heard,
    //! the first entry is { :name => "(unnamed sensor)", :auto => true, ... }:
    //! such a device cannot be stored by name, so choosing it selects auto
    //! connect instead.
    //! @return Array of dictionaries
    function getNearbyDevices() as Array<Dictionary> {
        var now = System.getTimer();
        var out = [] as Array<Dictionary>;
        var keys = mSeen.keys();
        for (var i = 0; i < keys.size(); i++) {
            var entry = mSeen[keys[i]];
            if (entry == null || (now - (entry[1] as Number)) > SEEN_EXPIRY_MS) {
                continue;
            }
            var item = { :name => keys[i], :rssi => entry[0], :hasService => entry[2] };
            // Insertion sort by RSSI (descending); lists are tiny.
            var pos = out.size();
            while (pos > 0 && ((out[pos - 1][:rssi] as Number) < (entry[0] as Number))) {
                pos--;
            }
            out = out.slice(0, pos).addAll([item]).addAll(out.slice(pos, null));
        }
        if (mUnnamedSvcMs != 0 && (now - mUnnamedSvcMs) <= SEEN_EXPIRY_MS) {
            out = [{ :name => "(unnamed sensor)", :rssi => mUnnamedSvcRssi,
                     :hasService => true, :auto => true }].addAll(out);
        }
        return out;
    }

    //! Saves the nearby-device list to Application.Storage under NEARBY_KEY
    //! as an array of [name, rssi, advertisesService, epochSeconds]. An
    //! unnamed advert listing the service UUID is stored with name "".
    //! Only written while there is something to report.
    private function publishNearby() as Void {
        var nearby = getNearbyDevices();
        if (nearby.size() == 0) {
            return;
        }
        var stamp = Time.now().value();
        var rows = [];
        for (var i = 0; i < nearby.size(); i++) {
            var dev = nearby[i];
            var name = "";
            if (!dev.hasKey(:auto)) {
                name = dev[:name].toString();
            }
            var row = [name, dev[:rssi], dev[:hasService], stamp];
            rows.add(row);
        }
        try {
            Application.Storage.setValue(NEARBY_KEY, rows);
        } catch (e) {
            System.println("EnvSensor: cannot save nearby list: " + e.getErrorMessage());
        }
    }

    //! @return Array of all slot state objects (view must treat as read-only)
    function getSlots() as Array<EnvDeviceState> {
        return mSlots;
    }

    //! Looks up a device's state by its display name.
    //! @param name Display name from settings
    //! @return State object, or null if no enabled slot has that name
    function getStateByName(name as String) as EnvDeviceState? {
        return mStateByName.hasKey(name) ? mStateByName[name] : null;
    }

    // ---------------------------------------------------------------------
    // BleDelegate callbacks
    // ---------------------------------------------------------------------

    //! Profile registration result. Scanning starts only after the GATT
    //! profile is registered, otherwise service discovery would miss it.
    //! @param uuid   Service UUID that was registered
    //! @param status Ble.STATUS_SUCCESS on success
    function onProfileRegister(uuid as Ble.Uuid, status as Ble.Status) as Void {
        if (status == Ble.STATUS_SUCCESS) {
            System.println("EnvSensor: profile registered " + uuid.toString());
            var key = uuid.toString();
            if (mRegisteredProfiles.indexOf(key) < 0) {
                mRegisteredProfiles.add(key);
            }
            if (mServiceUuid != null && key.equals(mServiceUuid.toString())) {
                mProfileReady = true;
            }
        } else {
            System.println("EnvSensor: profile registration failed, status " + status);
            mProfileFailed = true;
        }
        updateScanState();
    }

    //! Scan state confirmation from the system.
    //! @param scanState New scan state
    //! @param status    Ble.STATUS_SUCCESS on success
    function onScanStateChange(scanState as Ble.ScanState, status as Ble.Status) as Void {
        mScanning = (status == Ble.STATUS_SUCCESS && scanState == Ble.SCAN_STATE_SCANNING);
        if (status == Ble.STATUS_SUCCESS) {
            mScanError = null;
        } else {
            System.println("EnvSensor: scan state change failed, status " + status);
            mScanError = "SCAN ERR " + status;
        }
    }

    //! Called with batches of advertising packets while scanning. Each result
    //! is compared (case-insensitively) against every enabled, unpaired slot.
    //! @param scanResults Iterator of Ble.ScanResult
    function onScanResults(scanResults as Ble.Iterator) as Void {
        for (var result = scanResults.next(); result != null; result = scanResults.next()) {
            if (!(result instanceof Ble.ScanResult)) {
                continue;
            }
            var name = result.getDeviceName();
            if (name != null && name.length() == 0) {
                name = null;
            }
            var now = System.getTimer();

            // ---- Ruuvi broadcast: decode in place, never connect ----
            var ruuvi = decodeRuuvi(result);
            if (ruuvi != null) {
                var mac = ruuvi[3] as String;
                mRuuviSeenMs = now;
                // The name usually sits in the scan response, which this
                // product does not receive; fall back to Ruuvi's own
                // "Ruuvi XXXX" naming (last 4 hex digits of the MAC).
                var label = (name != null) ? name : ("Ruuvi " + mac.substring(8, 12));
                recordSeen(label, result.getRssi(), true);
                var ruuviSlot = findSlotForRuuvi(mac, name);
                if (ruuviSlot >= 0) {
                    applyRuuvi(ruuviSlot, mac, ruuvi);
                }
                continue;
            }

            var hasService = advertisesService(result);
            if (hasService) {
                mServiceSeenMs = now;
            }
            if (name != null) {
                recordSeen(name, result.getRssi(), hasService);
            } else {
                mUnnamedMs = now;
                if (hasService) {
                    mUnnamedSvcMs = now;
                    var rssi = result.getRssi();
                    mUnnamedSvcRssi = (rssi != null) ? rssi : -127;
                }
            }

            var slotIdx = findSlotForResult(name, hasService, result);
            if (slotIdx < 0) {
                continue;
            }

            // A device to connect to: register the GATT profile now if that
            // has not happened yet; pairing follows on a later advert.
            if (!mProfileRequested && !mEnded) {
                registerProfile();
            }

            // No pairing while another pairing is in flight (one at a time
            // keeps the BLE stack happy), before the profile is registered,
            // or when no further connection is available.
            if (mPairingSlot >= 0 || !mProfileReady || !canPairMore()) {
                continue;
            }
            pairSlot(slotIdx, result);
        }
    }

    //! Connection state changes for paired devices.
    //! On connect: queue the CCCD write that enables notifications.
    //! On disconnect: show "---" and let the system auto-reconnect (tick()
    //! falls back to a fresh scan if that does not happen in time).
    //! @param device Device whose state changed
    //! @param state  Ble.CONNECTION_STATE_CONNECTED or _DISCONNECTED
    function onConnectedStateChanged(device as Ble.Device, state as Ble.ConnectionState) as Void {
        var idx = findSlotForDevice(device);
        if (idx < 0) {
            return;
        }
        var slot = mSlots[idx];

        if (state == Ble.CONNECTION_STATE_CONNECTED) {
            System.println("EnvSensor: connected " + slot.displayName);
            slot.setState(EnvDeviceState.STATE_CONNECTED);
            slot.pairStartMs = 0;
            slot.notifying = false;
            if (mPairingSlot == idx) {
                mPairingSlot = -1;
            }
            registerNotify(idx);
        } else {
            System.println("EnvSensor: disconnected " + slot.displayName);
            slot.notifying = false;
            // Only flip connected/scanning slots; pairing timeouts handle the rest.
            if (slot.state == EnvDeviceState.STATE_CONNECTED) {
                slot.setState(EnvDeviceState.STATE_UNAVAILABLE);
            }
            removeFromNotifyQueue(idx);
            if (mRequestSlot == idx) {
                mRequestSlot = -1;
                processNotifyQueue();
            }
        }

        updateScanState();
        WatchUi.requestUpdate();
    }

    //! Result of the CCCD write that enables notifications.
    //! @param descriptor Descriptor that was written
    //! @param status     Ble.STATUS_SUCCESS on success
    function onDescriptorWrite(descriptor as Ble.Descriptor, status as Ble.Status) as Void {
        var idx = mRequestSlot;
        mRequestSlot = -1;

        if (idx >= 0 && idx < mSlots.size()) {
            if (status == Ble.STATUS_SUCCESS) {
                mSlots[idx].notifying = true;
                System.println("EnvSensor: notifications enabled for " + mSlots[idx].displayName);
            } else {
                System.println("EnvSensor: CCCD write failed (" + status + ") for " + mSlots[idx].displayName);
                // Retry later while the link is still up.
                if (mSlots[idx].state == EnvDeviceState.STATE_CONNECTED) {
                    mNotifyQueue.add(idx);
                }
            }
        }
        processNotifyQueue();
    }

    //! Notification from a sensor's TX characteristic.
    //! @param characteristic Characteristic that changed
    //! @param value          Raw payload bytes
    function onCharacteristicChanged(characteristic as Ble.Characteristic, value as Lang.ByteArray) as Void {
        var device = null;
        try {
            device = characteristic.getService().getDevice();
        } catch (e) {
            System.println("EnvSensor: cannot resolve notification source");
            return;
        }

        var idx = findSlotForDevice(device);
        if (idx < 0) {
            return;
        }

        var slot = mSlots[idx];
        // Data proves the link is up even if we missed the connect callback.
        if (slot.state != EnvDeviceState.STATE_CONNECTED) {
            slot.setState(EnvDeviceState.STATE_CONNECTED);
        }
        slot.notifying = true;

        parsePayload(slot, value);
        WatchUi.requestUpdate();
    }

    // ---------------------------------------------------------------------
    // Parsing
    // ---------------------------------------------------------------------

    //! Parses "<temperature>,<humidity>,<pressure>" into the slot.
    //! All three fields must be valid and in range; otherwise the packet is
    //! rejected and the last known good values are kept.
    //! @param slot  Destination state object
    //! @param value Raw notification bytes
    private function parsePayload(slot as EnvDeviceState, value as Lang.ByteArray?) as Void {
        try {
            if (value == null || value.size() == 0) {
                System.println("EnvSensor: empty payload from " + slot.displayName);
                return;
            }

            // utf8ArrayToString() expects an Array<Number>; strip control
            // characters (CR, LF, NUL padding) while converting.
            var bytes = [] as Array<Number>;
            for (var i = 0; i < value.size(); i++) {
                var b = value[i];
                if (b >= 0x20 && b < 0x7F) {
                    bytes.add(b);
                }
            }
            if (bytes.size() == 0) {
                System.println("EnvSensor: payload had no printable data from " + slot.displayName);
                return;
            }

            var text = StringUtil.utf8ArrayToString(bytes);
            var fields = EnvSensorUtil.split(text, ",");
            if (fields.size() != 3) {
                System.println("EnvSensor: malformed payload '" + text + "' from " + slot.displayName);
                return;
            }

            var t = EnvSensorUtil.trim(fields[0]).toFloat();
            var h = EnvSensorUtil.trim(fields[1]).toFloat();
            var p = EnvSensorUtil.trim(fields[2]).toFloat();

            if (t == null || h == null || p == null) {
                System.println("EnvSensor: non-numeric field in '" + text + "' from " + slot.displayName);
                return;
            }
            if (t < TEMP_MIN || t > TEMP_MAX || h < HUM_MIN || h > HUM_MAX
                    || p < PRES_MIN || p > PRES_MAX) {
                System.println("EnvSensor: out-of-range values in '" + text + "' from " + slot.displayName);
                return;
            }

            // Commit atomically only after every field validated.
            slot.temperature = t;
            slot.humidity = h;
            slot.pressure = p;
            slot.lastDataMs = System.getTimer();
        } catch (e) {
            System.println("EnvSensor: parse error from " + slot.displayName + ": " + e.getErrorMessage());
        }
    }

    // ---------------------------------------------------------------------
    // BLE helpers
    // ---------------------------------------------------------------------

    //! Converts a UUID string with Ble.stringToUuid(), falling back to the
    //! given default when the input is blank or invalid.
    //! @param text     User supplied UUID string (may be "")
    //! @param fallback Default UUID string
    //! @return Parsed UUID
    private function parseUuid(text as String?, fallback as String) as Ble.Uuid {
        if (text != null && text.length() > 0) {
            try {
                return Ble.stringToUuid(text);
            } catch (e) {
                System.println("EnvSensor: invalid UUID '" + text + "', using default");
            }
        }
        return Ble.stringToUuid(fallback);
    }

    //! Registers the GATT profile (service + data characteristic + CCCD) for
    //! the active UUIDs. Connect IQ caps apps at three registered profiles, so
    //! a profile already registered earlier in this session is reused.
    private function registerProfile() as Void {
        var svc = mServiceUuid;
        var chr = mCharUuid;
        if (svc == null || chr == null) {
            return;
        }
        mProfileRequested = true;

        if (mRegisteredProfiles.indexOf(svc.toString()) >= 0) {
            mProfileReady = true;
            return;
        }

        mProfileReady = false;
        mProfileRequestMs = System.getTimer();
        mProfileAttempts++;
        var profile = {
            :uuid => svc,
            :characteristics => [{
                :uuid => chr,
                :descriptors => [Ble.cccdUuid()]
            }]
        };

        try {
            Ble.registerProfile(profile);
        } catch (e) {
            // ProfileRegistrationException: e.g. three profiles already used.
            System.println("EnvSensor: registerProfile failed: " + e.getErrorMessage());
            mProfileFailed = true;
        }
    }

    //! Pairs with the device behind a matching scan result. Scanning is paused
    //! during pairing; updateScanState() resumes it when appropriate.
    //! @param idx    Slot index
    //! @param result Matching scan result
    private function pairSlot(idx as Number, result as Ble.ScanResult) as Void {
        var slot = mSlots[idx];
        System.println("EnvSensor: pairing " + slot.bleId + " -> " + slot.displayName);

        setScanning(false);
        try {
            var device = Ble.pairDevice(result);
            if (device != null) {
                slot.device = device;
                slot.scanResult = result;
                slot.pairStartMs = System.getTimer();
                mPairingSlot = idx;
                // The system may report an already-up link immediately.
                if (device.isConnected()) {
                    onConnectedStateChanged(device, Ble.CONNECTION_STATE_CONNECTED);
                }
            }
        } catch (e) {
            System.println("EnvSensor: pairDevice failed: " + e.getErrorMessage());
            slot.device = null;
            slot.scanResult = null;
            slot.pairStartMs = 0;
            mPairingSlot = -1;
        }
        updateScanState();
    }

    //! Enables notifications on the slot's data characteristic.
    //! Connect IQ has no direct registerNotify() call: notifications are turned
    //! on by writing 0x0001 to the characteristic's CCCD. The write is queued
    //! because only one GATT request may be outstanding at a time.
    //! @param idx Slot index
    private function registerNotify(idx as Number) as Void {
        if (mNotifyQueue.indexOf(idx) < 0 && mRequestSlot != idx) {
            mNotifyQueue.add(idx);
        }
        processNotifyQueue();
    }

    //! Issues the next queued CCCD write if no request is in flight.
    private function processNotifyQueue() as Void {
        while (mRequestSlot < 0 && mNotifyQueue.size() > 0) {
            var idx = mNotifyQueue[0];
            mNotifyQueue = mNotifyQueue.slice(1, null);

            var slot = mSlots[idx];
            var device = slot.device;
            if (device == null || slot.state != EnvDeviceState.STATE_CONNECTED || slot.notifying) {
                continue;
            }

            var cccd = findCccd(device);
            if (cccd == null) {
                System.println("EnvSensor: service/characteristic not found on " + slot.displayName
                    + " - check the UUID settings");
                continue;
            }

            try {
                cccd.requestWrite(CCCD_ENABLE_NOTIFY);
                mRequestSlot = idx;
                mRequestStartMs = System.getTimer();
            } catch (e) {
                // DeviceRequestException etc.; tick() / reconnect will retry.
                System.println("EnvSensor: CCCD write rejected: " + e.getErrorMessage());
            }
        }
    }

    //! Locates the CCCD of the data characteristic on a connected device.
    //! @param device Connected device
    //! @return CCCD descriptor, or null if the profile is not present
    private function findCccd(device as Ble.Device) as Ble.Descriptor? {
        var svcUuid = mServiceUuid;
        var chrUuid = mCharUuid;
        if (svcUuid == null || chrUuid == null) {
            return null;
        }
        var service = device.getService(svcUuid);
        if (service == null) {
            return null;
        }
        var characteristic = service.getCharacteristic(chrUuid);
        if (characteristic == null) {
            return null;
        }
        return characteristic.getDescriptor(Ble.cccdUuid());
    }

    //! Unpairs a slot's device and clears its BLE plumbing. Readings are kept
    //! so the last known values survive transient reconnects. The slot drops
    //! back to SCANNING unless it is disabled.
    //! @param idx Slot index
    private function releaseSlot(idx as Number) as Void {
        var slot = mSlots[idx];
        var device = slot.device;
        if (device != null) {
            try {
                Ble.unpairDevice(device);
            } catch (e) {
                System.println("EnvSensor: unpair failed: " + e.getErrorMessage());
            }
        }
        slot.device = null;
        slot.scanResult = null;
        slot.pairStartMs = 0;
        slot.notifying = false;
        if (slot.isEnabled()) {
            slot.setState(EnvDeviceState.STATE_SCANNING);
        }

        removeFromNotifyQueue(idx);
        if (mRequestSlot == idx) {
            mRequestSlot = -1;
        }
        if (mPairingSlot == idx) {
            mPairingSlot = -1;
        }
    }

    //! Removes a slot index from the pending CCCD queue.
    //! @param idx Slot index
    private function removeFromNotifyQueue(idx as Number) as Void {
        var kept = [] as Array<Number>;
        for (var i = 0; i < mNotifyQueue.size(); i++) {
            if (mNotifyQueue[i] != idx) {
                kept.add(mNotifyQueue[i]);
            }
        }
        mNotifyQueue = kept;
    }

    //! Finds the slot a scan result should be paired to:
    //!   1. an enabled, unpaired slot whose BLE id equals the advertised name
    //!      (case-insensitive), otherwise
    //!   2. an unpaired wildcard ("*") slot, if the device advertises the
    //!      active service UUID.
    //! Devices already paired to a slot, and slots cooling down after being
    //! cycled out, are skipped.
    //! @param name       Advertised local name (may be null)
    //! @param hasService true if the advert lists the active service UUID
    //! @param result     Scan result (used to detect already-paired devices)
    //! @return Slot index, or -1 if none matches
    private function findSlotForResult(name as String?, hasService as Boolean,
            result as Ble.ScanResult) as Number {
        // Skip devices that already belong to a slot.
        for (var i = 0; i < mSlots.size(); i++) {
            var sr = mSlots[i].scanResult;
            if (sr != null && result.isSameDevice(sr)) {
                return -1;
            }
        }

        var now = System.getTimer();
        var upper = (name != null) ? name.toUpper() : null;
        var wildcard = -1;

        for (var i = 0; i < mSlots.size(); i++) {
            var slot = mSlots[i];
            if (!slot.isEnabled() || slot.device != null || slot.advertMode
                    || now < slot.cooldownUntilMs) {
                continue;
            }
            if (slot.bleId.equals(WILDCARD_ID)) {
                if (wildcard < 0 && hasService) {
                    wildcard = i;
                }
            } else if (upper != null && slot.bleId.toUpper().equals(upper)) {
                return i;
            }
        }
        return wildcard;
    }

    // ---------------------------------------------------------------------
    // Ruuvi broadcasts
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

    //! Picks the slot a Ruuvi broadcast belongs to:
    //!   1. the slot already bound to this MAC, else
    //!   2. an unbound slot whose BLE id names this tag (see ruuviIdMatches), else
    //!   3. an unbound wildcard ("*") slot.
    //! @param mac  12 hex digits from the broadcast
    //! @param name Advertised name, usually null
    //! @return Slot index, or -1
    private function findSlotForRuuvi(mac as String, name as String?) as Number {
        for (var i = 0; i < mSlots.size(); i++) {
            var bound = mSlots[i].boundMac;
            if (mSlots[i].isEnabled() && bound != null && bound.equals(mac)) {
                return i;
            }
        }
        var wildcard = -1;
        for (var i = 0; i < mSlots.size(); i++) {
            var slot = mSlots[i];
            if (!slot.isEnabled() || slot.boundMac != null || slot.device != null) {
                continue;
            }
            if (slot.bleId.equals(WILDCARD_ID)) {
                if (wildcard < 0) {
                    wildcard = i;
                }
            } else if (ruuviIdMatches(slot.bleId, mac, name)) {
                return i;
            }
        }
        return wildcard;
    }

    //! A BLE id names a Ruuvi tag if it equals the advertised name, the MAC
    //! (with or without separators), or ends in the MAC's last 4 hex digits
    //! the way Ruuvi names do ("Ruuvi BBF3", "HOTAIR BBF3").
    //! @param id   Stored BLE id
    //! @param mac  12 hex digits from the broadcast
    //! @param name Advertised name (may be null)
    //! @return true on a match
    private function ruuviIdMatches(id as String, mac as String, name as String?) as Boolean {
        if (name != null && id.toUpper().equals(name.toUpper())) {
            return true;
        }
        var chars = id.toUpper().toCharArray();
        var norm = "";
        for (var i = 0; i < chars.size(); i++) {
            var c = chars[i];
            if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z')) {
                norm += c.toString();
            }
        }
        if (norm.equals(mac)) {
            return true;
        }
        var n = norm.length();
        return n >= 4 && norm.substring(n - 4, n).equals(mac.substring(8, 12));
    }

    //! Stores decoded Ruuvi readings in a slot and binds it to the tag.
    //! @param idx  Slot index
    //! @param mac  12 hex digits from the broadcast
    //! @param vals [temperatureC, humidityPct, pressureHpa, macHex]
    private function applyRuuvi(idx as Number, mac as String, vals as Array) as Void {
        var slot = mSlots[idx];
        if (slot.boundMac == null) {
            System.println("EnvSensor: " + slot.displayName + " bound to Ruuvi " + mac);
        }
        slot.boundMac = mac;
        slot.advertMode = true;
        slot.temperature = vals[0] as Float;
        slot.humidity = vals[1] as Float;
        slot.pressure = vals[2] as Float;
        slot.lastDataMs = System.getTimer();
        if (slot.state != EnvDeviceState.STATE_CONNECTED) {
            slot.setState(EnvDeviceState.STATE_CONNECTED);
        }
    }

    //! @param result Scan result
    //! @return true if the advert lists the active service UUID
    private function advertisesService(result as Ble.ScanResult) as Boolean {
        var svc = mServiceUuid;
        if (svc == null) {
            return false;
        }
        try {
            var uuids = result.getServiceUuids();
            for (var u = uuids.next(); u != null; u = uuids.next()) {
                if (svc.equals(u)) {
                    return true;
                }
            }
        } catch (e) {
            // Malformed advert; treat as "not advertised".
        }
        return false;
    }

    //! Remembers a nearby advertiser for the settings device list.
    //! @param name       Advertised name
    //! @param rssi       Signal strength (dBm)
    //! @param hasService true if it advertises the active service UUID
    //! When the list is full, expired entries are dropped first, then the
    //! weakest entry if the new device is stronger, so a busy area cannot
    //! permanently crowd out a newly powered-on sensor.
    private function recordSeen(name as String, rssi as Number?, hasService as Boolean) as Void {
        var now = System.getTimer();
        var level = (rssi != null) ? rssi : -127;

        if (!mSeen.hasKey(name) && mSeen.size() >= SEEN_MAX) {
            var keys = mSeen.keys();
            var weakest = null;
            var weakestRssi = 0;
            for (var i = 0; i < keys.size(); i++) {
                var entry = mSeen[keys[i]];
                if (entry == null || (now - (entry[1] as Number)) > SEEN_EXPIRY_MS) {
                    mSeen.remove(keys[i]);
                } else if (weakest == null || (entry[0] as Number) < weakestRssi) {
                    weakest = keys[i];
                    weakestRssi = entry[0] as Number;
                }
            }
            if (mSeen.size() >= SEEN_MAX) {
                if (weakest == null || level <= weakestRssi) {
                    return;
                }
                mSeen.remove(weakest);
            }
        }
        mSeen[name] = [level, now, hasService];
    }

    //! Finds the slot that owns a paired device.
    //! @param device Device handle from a callback
    //! @return Slot index, or -1 if unknown
    private function findSlotForDevice(device as Ble.Device?) as Number {
        if (device == null) {
            return -1;
        }
        for (var i = 0; i < mSlots.size(); i++) {
            var d = mSlots[i].device;
            if (d != null && d.equals(device)) {
                return i;
            }
        }
        return -1;
    }

    //! @return Number of further connections the platform allows. Products
    //! without getAvailableConnectionCount() are assumed to have room.
    private function freeConnections() as Number {
        if (Ble has :getAvailableConnectionCount) {
            try {
                return Ble.getAvailableConnectionCount();
            } catch (e) {
                return 0;
            }
        }
        return EnvSensorApp.MAX_DEVICES;
    }

    //! @return true if another device may be paired: always when nothing is
    //! paired yet (some products report 0 free connections even then),
    //! otherwise when the platform reports a free connection
    private function canPairMore() as Boolean {
        for (var i = 0; i < mSlots.size(); i++) {
            if (mSlots[i].device != null) {
                return freeConnections() > 0;
            }
        }
        return true;
    }

    //! @return true if some enabled slot still needs a device
    private function hasUnpairedSlot() as Boolean {
        for (var i = 0; i < mSlots.size(); i++) {
            if (mSlots[i].isEnabled() && mSlots[i].device == null) {
                return true;
            }
        }
        return false;
    }

    //! @return true if an enabled slot waits for a GATT connection (slots fed
    //! by broadcasts never need one)
    private function hasSlotNeedingConnection() as Boolean {
        for (var i = 0; i < mSlots.size(); i++) {
            var slot = mSlots[i];
            if (slot.isEnabled() && slot.device == null && !slot.advertMode) {
                return true;
            }
        }
        return false;
    }

    //! @return true if at least one slot has a BLE id configured
    private function hasEnabledSlot() as Boolean {
        for (var i = 0; i < mSlots.size(); i++) {
            if (mSlots[i].isEnabled()) {
                return true;
            }
        }
        return false;
    }

    //! Sequential cycling: when every connection slot is used but some
    //! configured device is still waiting, release the device that has been
    //! connected the longest (after CYCLE_INTERVAL_MS) so the next one can
    //! connect. Its last readings are kept.
    //! @param now Current System.getTimer() value
    private function cycleConnectionsIfNeeded(now as Number) as Void {
        if (mPairingSlot >= 0 || !hasSlotNeedingConnection() || canPairMore()) {
            return;
        }

        var oldest = -1;
        var oldestSince = 0;
        for (var i = 0; i < mSlots.size(); i++) {
            var slot = mSlots[i];
            if (slot.state == EnvDeviceState.STATE_CONNECTED && slot.hasData()
                    && (now - slot.stateSinceMs) > CYCLE_INTERVAL_MS) {
                if (oldest < 0 || slot.stateSinceMs < oldestSince) {
                    oldest = i;
                    oldestSince = slot.stateSinceMs;
                }
            }
        }

        if (oldest >= 0) {
            System.println("EnvSensor: cycling out " + mSlots[oldest].displayName);
            releaseSlot(oldest);
            // Give the waiting devices a chance before this one re-pairs.
            mSlots[oldest].cooldownUntilMs = now + CYCLE_INTERVAL_MS;
        }
    }

    //! Scans whenever nothing is being paired and either a slot is waiting
    //! or no slot is configured at all (so the settings menu's nearby list
    //! can fill and the user can pick a first sensor); stops otherwise to
    //! save power. Scanning deliberately does not wait for the GATT profile
    //! or a free connection: only pairing needs those.
    private function updateScanState() as Void {
        var want = mPairingSlot < 0 && (hasUnpairedSlot() || !hasEnabledSlot());
        setScanning(want);
    }

    //! Requests a scan state change if it differs from the current one.
    //! @param on true to scan
    private function setScanning(on as Boolean) as Void {
        // Never start a scan once the app is closing.
        if (on == mScanning || (on && mEnded)) {
            return;
        }
        try {
            Ble.setScanState(on ? Ble.SCAN_STATE_SCANNING : Ble.SCAN_STATE_OFF);
            // Optimistic; onScanStateChange() confirms the real state.
            mScanning = on;
        } catch (e) {
            System.println("EnvSensor: setScanState failed: " + e.getErrorMessage());
            mScanError = "SCAN ERR";
        }
    }
}

//! Small string helpers (Monkey C has no built-in split / trim).
module EnvSensorUtil {

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

    //! Splits a string on a single-character delimiter.
    //! "a,,b" yields ["a", "", "b"].
    //! @param s     Input string
    //! @param delim Delimiter (one character)
    //! @return Array of fields (at least one element)
    function split(s as String, delim as String) as Array<String> {
        var out = [] as Array<String>;
        var rest = s;
        var pos = rest.find(delim);
        while (pos != null) {
            out.add(rest.substring(0, pos));
            rest = rest.substring(pos + delim.length(), rest.length());
            pos = rest.find(delim);
        }
        out.add(rest);
        return out;
    }
}
