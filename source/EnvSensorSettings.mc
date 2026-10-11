//
// EnvSensorSettings.mc
//
// On-device settings menu. Garmin Connect only shows app settings for
// apps installed from the Connect IQ store, so a side-loaded (USB) install is
// configured here instead. Menu tree:
//
//   EnvSensor
//   +-- Device 1 / 2 / 3
//       +-- Choose sensor    -> list of nearby BLE devices (scan results)
//       +-- Auto connect     -> "*": any sensor advertising the service UUID
//       +-- Rename           -> on-screen keyboard (if the product has one)
//       +-- Turn off         -> clears the slot
//
// Every change is written with Application.Properties.setValue() and applied
// immediately via EnvSensorApp.applySettings().
//
import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! Property helpers shared by the settings menus.
module EnvSettings {

    //! @param slot Slot index (0-based)
    //! @return Stored BLE id for the slot ("" if unset)
    function getBleId(slot as Number) as String {
        return readString("Device" + (slot + 1) + "BleId");
    }

    //! @param slot Slot index (0-based)
    //! @return Stored display name, or the default "Sensor N"
    function getDisplayName(slot as Number) as String {
        var name = readString("Device" + (slot + 1) + "DisplayName");
        return (name.length() > 0) ? name : ("Sensor " + (slot + 1));
    }

    //! Stores a BLE id and applies the configuration.
    //! @param slot Slot index (0-based)
    //! @param id   BLE name, "*" for auto, or "" to disable
    function setBleId(slot as Number, id as String) as Void {
        writeString("Device" + (slot + 1) + "BleId", id);
    }

    //! Stores a display name and applies the configuration.
    //! @param slot Slot index (0-based)
    //! @param name New display name
    function setDisplayName(slot as Number, name as String) as Void {
        writeString("Device" + (slot + 1) + "DisplayName", name);
    }

    //! Human readable form of a BLE id for menu sub-labels.
    //! @param id Stored BLE id
    //! @return "Off", "Auto (any sensor)" or the name itself
    function describeBleId(id as String) as String {
        if (id.length() == 0) {
            return "Off";
        }
        if (id.equals(EnvSensorBleDelegate.WILDCARD_ID)) {
            return "Auto (any sensor)";
        }
        return id;
    }

    //! Sub-label for a device entry in the main menu, e.g. "Balloon 1: Auto".
    //! @param slot Slot index (0-based)
    //! @return Summary string
    function describeSlot(slot as Number) as String {
        var id = getBleId(slot);
        if (id.length() == 0) {
            return "Off";
        }
        return getDisplayName(slot) + ": " + describeBleId(id);
    }

    //! Reads a string property, returning "" for missing / null values.
    //! @param key Property id
    //! @return Trimmed value
    function readString(key as String) as String {
        try {
            var value = Application.Properties.getValue(key);
            if (value != null) {
                return EnvSensorUtil.trim(value.toString());
            }
        } catch (e) {
            System.println("EnvSensor: missing property " + key);
        }
        return "";
    }

    //! Writes a string property and re-applies the configuration.
    //! @param key   Property id
    //! @param value New value
    function writeString(key as String, value as String) as Void {
        try {
            Application.Properties.setValue(key, value);
        } catch (e) {
            System.println("EnvSensor: cannot save " + key + ": " + e.getErrorMessage());
        }
        getApp().applySettings();
    }
}

// -------------------------------------------------------------------------
// Main menu: one entry per device slot
// -------------------------------------------------------------------------

class EnvSettingsMenu extends WatchUi.Menu2 {

    //! Builds the main menu with one item per device slot.
    function initialize() {
        Menu2.initialize({ :title => "EnvSensor" });
        for (var i = 0; i < EnvSensorApp.MAX_DEVICES; i++) {
            addItem(new WatchUi.MenuItem("Device " + (i + 1), EnvSettings.describeSlot(i), i, null));
        }
    }
}

class EnvSettingsMenuDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    //! Opens the sub-menu for the selected device slot.
    //! @param item Selected menu item (id = slot index)
    function onSelect(item as WatchUi.MenuItem) as Void {
        var slot = item.getId() as Number;
        WatchUi.pushView(new EnvDeviceMenu(slot), new EnvDeviceMenuDelegate(slot, item), WatchUi.SLIDE_LEFT);
    }

    //! Leaving settings: stop discovery scanning and resume normal operation.
    function onBack() as Void {
        var ble = getApp().getBleDelegate();
        if (ble != null) {
            ble.setDiscovery(false);
        }
        getApp().applySettings();
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

// -------------------------------------------------------------------------
// Device menu: choose / auto / rename / off
// -------------------------------------------------------------------------

class EnvDeviceMenu extends WatchUi.Menu2 {

    //! @param slot Slot index (0-based)
    function initialize(slot as Number) {
        Menu2.initialize({ :title => "Device " + (slot + 1) });
        addItem(new WatchUi.MenuItem("Choose sensor", EnvSettings.describeBleId(EnvSettings.getBleId(slot)), :choose, null));
        addItem(new WatchUi.MenuItem("Auto connect", "Any sensor with the service", :auto, null));
        if (WatchUi has :TextPicker) {
            addItem(new WatchUi.MenuItem("Rename", EnvSettings.getDisplayName(slot), :rename, null));
        }
        addItem(new WatchUi.MenuItem("Turn off", null, :off, null));
    }
}

class EnvDeviceMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var mSlot as Number;
    private var mParentItem as WatchUi.MenuItem;   // main-menu entry to refresh

    //! @param slot       Slot index (0-based)
    //! @param parentItem Main-menu item whose sub-label shows this slot
    function initialize(slot as Number, parentItem as WatchUi.MenuItem) {
        Menu2InputDelegate.initialize();
        mSlot = slot;
        mParentItem = parentItem;
    }

    //! Handles the device menu actions.
    //! @param item Selected menu item
    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();

        if (id == :choose) {
            WatchUi.pushView(new EnvPickerMenu(), new EnvPickerMenuDelegate(mSlot, item, mParentItem), WatchUi.SLIDE_LEFT);
        } else if (id == :auto) {
            EnvSettings.setBleId(mSlot, EnvSensorBleDelegate.WILDCARD_ID);
            finish();
        } else if (id == :rename) {
            WatchUi.pushView(new WatchUi.TextPicker(EnvSettings.getDisplayName(mSlot)),
                new EnvRenameDelegate(mSlot, item, mParentItem), WatchUi.SLIDE_LEFT);
        } else if (id == :off) {
            EnvSettings.setBleId(mSlot, "");
            finish();
        }
    }

    //! Refreshes the main menu entry and returns to it.
    private function finish() as Void {
        mParentItem.setSubLabel(EnvSettings.describeSlot(mSlot));
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

// -------------------------------------------------------------------------
// Sensor picker: nearby BLE devices from discovery scanning
// -------------------------------------------------------------------------

class EnvPickerMenu extends WatchUi.Menu2 {

    //! Builds the list from the delegate's discovery results. Devices that
    //! advertise the active service UUID are marked "sensor".
    function initialize() {
        Menu2.initialize({ :title => "Nearby" });

        var ble = getApp().getBleDelegate();
        var nearby = (ble != null) ? ble.getNearbyDevices() : [];

        if (nearby.size() == 0) {
            addItem(new WatchUi.MenuItem("Searching...", "Select to refresh", :refresh, null));
            return;
        }

        addItem(new WatchUi.MenuItem("Refresh list", nearby.size() + " found", :refresh, null));
        for (var i = 0; i < nearby.size(); i++) {
            var dev = nearby[i];
            var sub = dev[:rssi].toString() + " dBm" + ((dev[:hasService] as Boolean) ? "  sensor" : "");
            addItem(new WatchUi.MenuItem(dev[:name] as String, sub, dev[:name], null));
        }
    }
}

class EnvPickerMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var mSlot as Number;
    private var mDeviceItem as WatchUi.MenuItem;   // "Choose sensor" item
    private var mParentItem as WatchUi.MenuItem;   // main-menu entry

    //! @param slot       Slot index (0-based)
    //! @param deviceItem "Choose sensor" item to refresh
    //! @param parentItem Main-menu item to refresh
    function initialize(slot as Number, deviceItem as WatchUi.MenuItem, parentItem as WatchUi.MenuItem) {
        Menu2InputDelegate.initialize();
        mSlot = slot;
        mDeviceItem = deviceItem;
        mParentItem = parentItem;
    }

    //! Refresh rebuilds the list; any other item stores that device name.
    //! @param item Selected menu item (id = device name or :refresh)
    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id instanceof String) {
            EnvSettings.setBleId(mSlot, id);
            mDeviceItem.setSubLabel(EnvSettings.describeBleId(id));
            mParentItem.setSubLabel(EnvSettings.describeSlot(mSlot));
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
        } else {
            WatchUi.switchToView(new EnvPickerMenu(), new EnvPickerMenuDelegate(mSlot, mDeviceItem, mParentItem),
                WatchUi.SLIDE_IMMEDIATE);
        }
    }
}

// -------------------------------------------------------------------------
// Rename: on-screen keyboard
// -------------------------------------------------------------------------

class EnvRenameDelegate extends WatchUi.TextPickerDelegate {

    private var mSlot as Number;
    private var mDeviceItem as WatchUi.MenuItem;   // "Rename" item
    private var mParentItem as WatchUi.MenuItem;   // main-menu entry

    //! @param slot       Slot index (0-based)
    //! @param deviceItem "Rename" item to refresh
    //! @param parentItem Main-menu item to refresh
    function initialize(slot as Number, deviceItem as WatchUi.MenuItem, parentItem as WatchUi.MenuItem) {
        TextPickerDelegate.initialize();
        mSlot = slot;
        mDeviceItem = deviceItem;
        mParentItem = parentItem;
    }

    //! Stores the new name; blank input is ignored.
    //! @param text    Entered text
    //! @param changed true if the text was edited
    //! @return true (the picker closes itself)
    function onTextEntered(text as String, changed as Boolean) as Boolean {
        var name = EnvSensorUtil.trim(text);
        if (name.length() > 0) {
            EnvSettings.setDisplayName(mSlot, name);
            mDeviceItem.setSubLabel(name);
            mParentItem.setSubLabel(EnvSettings.describeSlot(mSlot));
        }
        return true;
    }

    //! Keyboard dismissed without input.
    //! @return true
    function onCancel() as Boolean {
        return true;
    }
}
