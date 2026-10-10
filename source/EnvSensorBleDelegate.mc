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
//
import Toybox.Lang;
import Toybox.System;
import Toybox.StringUtil;
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

    // Timing (milliseconds).
    private const PAIR_TIMEOUT_MS      = 20000;   // pairDevice() -> connected
    private const RECONNECT_TIMEOUT_MS = 30000;   // system auto-reconnect window
    private const REQUEST_TIMEOUT_MS   = 5000;    // outstanding GATT request
    private const CYCLE_INTERVAL_MS    = 60000;   // min connected time before rotation

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
            registerProfile();
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
        for (var i = 0; i < mSlots.size(); i++) {
            releaseSlot(i);
        }
        setScanning(false);
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
        }
        updateScanState();
    }

    //! Scan state confirmation from the system.
    //! @param scanState New scan state
    //! @param status    Ble.STATUS_SUCCESS on success
    function onScanStateChange(scanState as Ble.ScanState, status as Ble.Status) as Void {
        mScanning = (status == Ble.STATUS_SUCCESS && scanState == Ble.SCAN_STATE_SCANNING);
    }

    //! Called with batches of advertising packets while scanning. Each result
    //! is compared (case-insensitively) against every enabled, unpaired slot.
    //! @param scanResults Iterator of Ble.ScanResult
    function onScanResults(scanResults as Ble.Iterator) as Void {
        // Only one pairing at a time keeps the BLE stack happy.
        if (mPairingSlot >= 0 || !mProfileReady) {
            return;
        }

        for (var result = scanResults.next(); result != null; result = scanResults.next()) {
            if (!(result instanceof Ble.ScanResult)) {
                continue;
            }
            var name = result.getDeviceName();
            if (name == null || name.length() == 0) {
                continue;
            }

            var slotIdx = findSlotForName(name, result);
            if (slotIdx >= 0) {
                pairSlot(slotIdx, result);
                return;
            }
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

        if (mRegisteredProfiles.indexOf(svc.toString()) >= 0) {
            mProfileReady = true;
            return;
        }

        mProfileReady = false;
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

    //! Finds the first enabled, unpaired slot whose BLE id matches the
    //! advertised name. Devices already paired to a slot are ignored.
    //! @param name   Advertised local name
    //! @param result Scan result (used to detect already-paired devices)
    //! @return Slot index, or -1 if none matches
    private function findSlotForName(name as String, result as Ble.ScanResult) as Number {
        var upper = name.toUpper();

        // Skip devices that already belong to a slot.
        for (var i = 0; i < mSlots.size(); i++) {
            var sr = mSlots[i].scanResult;
            if (sr != null && result.isSameDevice(sr)) {
                return -1;
            }
        }

        for (var i = 0; i < mSlots.size(); i++) {
            var slot = mSlots[i];
            if (slot.isEnabled() && slot.device == null && slot.bleId.toUpper().equals(upper)
                    && System.getTimer() >= slot.cooldownUntilMs) {
                return i;
            }
        }
        return -1;
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

    //! @return true if some enabled slot still needs a device
    private function hasUnpairedSlot() as Boolean {
        for (var i = 0; i < mSlots.size(); i++) {
            if (mSlots[i].isEnabled() && mSlots[i].device == null) {
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
        if (mPairingSlot >= 0 || !hasUnpairedSlot() || freeConnections() > 0) {
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

    //! Starts scanning when a profile is ready, a slot is waiting, nothing is
    //! being paired and a connection is free; stops it otherwise (saves power).
    private function updateScanState() as Void {
        var want = mProfileReady && mPairingSlot < 0 && hasUnpairedSlot() && freeConnections() > 0;
        setScanning(want);
    }

    //! Requests a scan state change if it differs from the current one.
    //! @param on true to scan
    private function setScanning(on as Boolean) as Void {
        if (on == mScanning) {
            return;
        }
        try {
            Ble.setScanState(on ? Ble.SCAN_STATE_SCANNING : Ble.SCAN_STATE_OFF);
            // Optimistic; onScanStateChange() confirms the real state.
            mScanning = on;
        } catch (e) {
            System.println("EnvSensor: setScanState failed: " + e.getErrorMessage());
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
