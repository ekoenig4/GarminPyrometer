//
// EnvSensorSettings.mc
//
// On-device settings menu. Garmin Connect only shows app settings for
// apps installed from the Connect IQ store, so a side-loaded (USB) install is
// configured here instead. Menu tree:
//
//   RuuviSensor
//   +-- Device 1 / 2 / 3
//   |   +-- Choose sensor    -> nearby BLE devices last heard by the data field
//   |   +-- Auto connect     -> "*": any sensor advertising the service UUID
//   |   +-- Show             -> All / Temperature / Humidity / Pressure
//   |   +-- Rename           -> on-screen keyboard (if the product has one)
//   |   +-- Turn off         -> clears the slot
//   +-- Temperature unit     -> Device setting / °C / °F
//   +-- Pressure unit        -> hPa / inHg / mmHg
//
// Every change is written with Application.Properties.setValue().
//
// This menu deliberately makes no BLE calls (BLE activity here caused a
// System Error on the Montana when the menu closed). The "Choose sensor" list
// is read from Application.Storage, where the running data field saves the
// devices it hears every 10 seconds.
//
import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

//! Property helpers shared by the settings menus.
module EnvSettings {

    // Global display units (properties TempUnit / PressureUnit).
    const TEMP_UNIT_KEY = "TempUnit";
    const TEMP_DEVICE = 0;        // follow the device's own unit setting
    const TEMP_C = 1;
    const TEMP_F = 2;
    const TEMP_UNIT_LABELS = ["Device setting", "°C", "°F"];

    const PRESSURE_UNIT_KEY = "PressureUnit";
    const PRESSURE_HPA = 0;
    const PRESSURE_INHG = 1;
    const PRESSURE_MMHG = 2;
    const PRESSURE_UNIT_LABELS = ["hPa", "inHg", "mmHg"];

    //! Reads a number property.
    //! @param key      Property id
    //! @param fallback Value when missing or not a number
    //! @return Stored value or fallback
    function getNumber(key as String, fallback as Number) as Number {
        try {
            var value = Application.Properties.getValue(key);
            if (value instanceof Number) {
                return value as Number;
            }
        } catch (e) {
            System.println("RuuviSensor: missing property " + key);
        }
        return fallback;
    }

    //! Writes a number property and re-applies the configuration.
    //! @param key   Property id
    //! @param value New value
    function setNumber(key as String, value as Number) as Void {
        try {
            Application.Properties.setValue(key, value);
        } catch (e) {
            System.println("RuuviSensor: cannot save " + key + ": " + e.getErrorMessage());
        }
        getApp().applySettings();
    }

    //! @return true if temperatures should be shown in °F, taking "Device
    //! setting" from the device's own temperature unit setting
    function useFahrenheit() as Boolean {
        var unit = getNumber(TEMP_UNIT_KEY, TEMP_DEVICE);
        if (unit == TEMP_F) {
            return true;
        }
        if (unit == TEMP_C) {
            return false;
        }
        var ds = System.getDeviceSettings();
        return (ds has :temperatureUnits) && ds.temperatureUnits == System.UNIT_STATUTE;
    }

    //! @param labels Choice labels
    //! @param index  Stored choice
    //! @return Label for the choice (first label if out of range)
    function choiceLabel(labels as Array<String>, index as Number) as String {
        return (index >= 0 && index < labels.size()) ? labels[index] : labels[0];
    }

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

    //! @param slot Slot index (0-based)
    //! @return Stored quantity to show (EnvDeviceState.SHOW_*), default All
    function getShow(slot as Number) as Number {
        try {
            var value = Application.Properties.getValue("Device" + (slot + 1) + "Show");
            if (value instanceof Number) {
                return value as Number;
            }
        } catch (e) {
            System.println("RuuviSensor: missing property Device" + (slot + 1) + "Show");
        }
        return EnvDeviceState.SHOW_ALL;
    }

    //! Stores the quantity to show and applies the configuration.
    //! @param slot Slot index (0-based)
    //! @param show EnvDeviceState.SHOW_* value
    function setShow(slot as Number, show as Number) as Void {
        try {
            Application.Properties.setValue("Device" + (slot + 1) + "Show", show);
        } catch (e) {
            System.println("RuuviSensor: cannot save Show: " + e.getErrorMessage());
        }
        getApp().applySettings();
    }

    //! @param show EnvDeviceState.SHOW_* value
    //! @return Menu label for it
    function describeShow(show as Number) as String {
        if (show == EnvDeviceState.SHOW_TEMPERATURE) {
            return "Temperature";
        }
        if (show == EnvDeviceState.SHOW_HUMIDITY) {
            return "Humidity";
        }
        if (show == EnvDeviceState.SHOW_PRESSURE) {
            return "Pressure";
        }
        return "All";
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
            System.println("RuuviSensor: missing property " + key);
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
            System.println("RuuviSensor: cannot save " + key + ": " + e.getErrorMessage());
        }
        getApp().applySettings();
    }
}

// -------------------------------------------------------------------------
// Main menu: one entry per device slot
// -------------------------------------------------------------------------

class EnvSettingsMenu extends WatchUi.Menu2 {

    //! Builds the main menu: one item per device slot, then the units.
    function initialize() {
        Menu2.initialize({ :title => "RuuviSensor" });
        for (var i = 0; i < EnvSensorApp.MAX_DEVICES; i++) {
            addItem(new WatchUi.MenuItem("Device " + (i + 1), EnvSettings.describeSlot(i), i, null));
        }
        addItem(new WatchUi.MenuItem("Temperature unit",
            EnvSettings.choiceLabel(EnvSettings.TEMP_UNIT_LABELS,
                EnvSettings.getNumber(EnvSettings.TEMP_UNIT_KEY, EnvSettings.TEMP_DEVICE)),
            :tempUnit, null));
        addItem(new WatchUi.MenuItem("Pressure unit",
            EnvSettings.choiceLabel(EnvSettings.PRESSURE_UNIT_LABELS,
                EnvSettings.getNumber(EnvSettings.PRESSURE_UNIT_KEY, EnvSettings.PRESSURE_HPA)),
            :pressureUnit, null));
    }
}

class EnvSettingsMenuDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    //! Opens the sub-menu for the selected device slot or unit.
    //! @param item Selected menu item (id = slot index, :tempUnit or :pressureUnit)
    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :tempUnit) {
            pushChoice("Temperature unit", EnvSettings.TEMP_UNIT_KEY, EnvSettings.TEMP_UNIT_LABELS,
                EnvSettings.TEMP_DEVICE, item);
            return;
        }
        if (id == :pressureUnit) {
            pushChoice("Pressure unit", EnvSettings.PRESSURE_UNIT_KEY, EnvSettings.PRESSURE_UNIT_LABELS,
                EnvSettings.PRESSURE_HPA, item);
            return;
        }
        var slot = id as Number;
        WatchUi.pushView(new EnvDeviceMenu(slot), new EnvDeviceMenuDelegate(slot, item), WatchUi.SLIDE_LEFT);
    }

    //! Opens a single-choice menu for a number property.
    private function pushChoice(title as String, key as String, labels as Array<String>,
            fallback as Number, item as WatchUi.MenuItem) as Void {
        var current = EnvSettings.getNumber(key, fallback);
        WatchUi.pushView(new EnvChoiceMenu(title, labels, current),
            new EnvChoiceMenuDelegate(key, labels, item), WatchUi.SLIDE_LEFT);
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
        addItem(new WatchUi.MenuItem("Show", EnvSettings.describeShow(EnvSettings.getShow(slot)), :show, null));
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
        } else if (id == :show) {
            WatchUi.pushView(new EnvShowMenu(mSlot), new EnvShowMenuDelegate(mSlot, item), WatchUi.SLIDE_LEFT);
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
// Choice menu: pick one of several labels for a number property (units)
// -------------------------------------------------------------------------

class EnvChoiceMenu extends WatchUi.Menu2 {

    //! @param title   Menu title
    //! @param labels  Choice labels; the item id is the label's index
    //! @param current Stored choice (marked "Selected")
    function initialize(title as String, labels as Array<String>, current as Number) {
        Menu2.initialize({ :title => title });
        for (var i = 0; i < labels.size(); i++) {
            addItem(new WatchUi.MenuItem(labels[i], (i == current) ? "Selected" : null, i, null));
        }
    }
}

class EnvChoiceMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var mKey as String;
    private var mLabels as Array<String>;
    private var mParentItem as WatchUi.MenuItem;   // main-menu item to refresh

    //! @param key        Property id to write
    //! @param labels     Choice labels
    //! @param parentItem Main-menu item showing the current choice
    function initialize(key as String, labels as Array<String>, parentItem as WatchUi.MenuItem) {
        Menu2InputDelegate.initialize();
        mKey = key;
        mLabels = labels;
        mParentItem = parentItem;
    }

    //! Stores the chosen index and returns to the main menu.
    //! @param item Selected item (id = choice index)
    function onSelect(item as WatchUi.MenuItem) as Void {
        var index = item.getId() as Number;
        EnvSettings.setNumber(mKey, index);
        mParentItem.setSubLabel(EnvSettings.choiceLabel(mLabels, index));
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

// -------------------------------------------------------------------------
// Show menu: which quantity the data field displays for a device
// -------------------------------------------------------------------------

class EnvShowMenu extends WatchUi.Menu2 {

    //! @param slot Slot index (0-based)
    function initialize(slot as Number) {
        Menu2.initialize({ :title => "Show" });
        var current = EnvSettings.getShow(slot);
        var choices = [EnvDeviceState.SHOW_ALL, EnvDeviceState.SHOW_TEMPERATURE,
                       EnvDeviceState.SHOW_HUMIDITY, EnvDeviceState.SHOW_PRESSURE];
        for (var i = 0; i < choices.size(); i++) {
            var sub = (choices[i] == current) ? "Selected" : null;
            addItem(new WatchUi.MenuItem(EnvSettings.describeShow(choices[i]), sub, choices[i], null));
        }
    }
}

class EnvShowMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var mSlot as Number;
    private var mDeviceItem as WatchUi.MenuItem;   // "Show" item to refresh

    //! @param slot       Slot index (0-based)
    //! @param deviceItem "Show" item in the device menu
    function initialize(slot as Number, deviceItem as WatchUi.MenuItem) {
        Menu2InputDelegate.initialize();
        mSlot = slot;
        mDeviceItem = deviceItem;
    }

    //! Stores the chosen quantity and returns to the device menu.
    //! @param item Selected item (id = EnvDeviceState.SHOW_* value)
    function onSelect(item as WatchUi.MenuItem) as Void {
        var show = item.getId() as Number;
        EnvSettings.setShow(mSlot, show);
        mDeviceItem.setSubLabel(EnvSettings.describeShow(show));
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

// -------------------------------------------------------------------------
// Sensor picker: nearby BLE devices saved by the data field
// -------------------------------------------------------------------------

class EnvPickerMenu extends WatchUi.Menu2 {

    //! Builds the list from the rows the data field saved to
    //! Application.Storage ([name, rssi, advertisesService, epochSeconds]).
    //! Devices that advertise the active service UUID are marked "sensor";
    //! an unnamed sensor (name "") selects auto connect.
    function initialize() {
        Menu2.initialize({ :title => "Nearby" });

        var raw = null;
        try {
            raw = Application.Storage.getValue(EnvSensorBleDelegate.NEARBY_KEY);
        } catch (e) {
            System.println("RuuviSensor: cannot read nearby list: " + e.getErrorMessage());
        }

        var now = Time.now().value();
        var added = 0;
        if (raw instanceof Array) {
            var rows = raw as Array;
            for (var i = 0; i < rows.size(); i++) {
                if (addRow(rows[i], now)) {
                    added++;
                }
            }
        }

        if (added == 0) {
            addItem(new WatchUi.MenuItem("No devices yet", "Run the data field first", :refresh, null));
        } else {
            addItem(new WatchUi.MenuItem("Refresh list", "List updates every 10 s", :refresh, null));
        }
    }

    //! Adds one saved row as a menu item, skipping malformed rows.
    //! @param row Saved row [name, rssi, advertisesService, epochSeconds]
    //! @param now Current time in epoch seconds
    //! @return true if an item was added
    private function addRow(row, now as Number) as Boolean {
        if (!(row instanceof Array)) {
            return false;
        }
        var fields = row as Array;
        if (fields.size() < 4 || fields[0] == null || fields[1] == null || fields[3] == null) {
            return false;
        }

        var name = fields[0].toString();
        var rssi = fields[1].toString();
        var hasService = (fields[2] == true);
        var age = now - (fields[3] as Number);

        // Note: avoid punctuation-only literals such as ", " here. monkeyc
        // 9.2 labels strings by their alphanumerics plus Java hashCode(), and
        // ", " collides with "+?" (both hash to 1396), which aborts the build.
        var sub = rssi + (hasService ? " dBm sensor, " : " dBm, ") + formatAge(age);
        if (name.length() == 0) {
            addItem(new WatchUi.MenuItem("(unnamed sensor)", sub, :auto, null));
        } else {
            addItem(new WatchUi.MenuItem(name, sub, name, null));
        }
        return true;
    }

    //! @param seconds Age in seconds
    //! @return e.g. "12s ago", "5min ago", "3h ago"
    private function formatAge(seconds as Number) as String {
        var secs = (seconds < 0) ? 0 : seconds;
        if (secs < 120) {
            return secs.toString() + "s ago";
        }
        if (secs < 7200) {
            return (secs / 60).toString() + "min ago";
        }
        return (secs / 3600).toString() + "h ago";
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

    //! Refresh rebuilds the list; "(unnamed sensor)" selects auto connect;
    //! any other item stores that device name.
    //! @param item Selected menu item (id = device name, :auto or :refresh)
    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :auto) {
            id = EnvSensorBleDelegate.WILDCARD_ID;
        }
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
