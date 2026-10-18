//
// RuuviSettings.mc
//
// On-device settings menu. Garmin Connect only shows app settings for apps
// installed from the Connect IQ store, and its settings page cannot hold a
// variable-length list, so the sensor list is edited here. Menu tree:
//
//   RuuviSensor
//   +-- Display           -> <sensor> on/off: the sensors the field shows
//   +-- Sensors           (own sub-menu so the list is clearly separate)
//   |   +-- + Add sensor  -> Ruuvi tags recently heard by the data field
//   |   +-- <sensor> ...  (one entry per listed sensor)
//   |       +-- Show      -> All / Temperature / Humidity / Pressure
//   |       +-- Rename    -> on-screen keyboard (if the product has one)
//   |       +-- Remove
//   +-- Temperature unit  -> Device setting / °C / °F
//   +-- Pressure unit     -> hPa / inHg / mmHg
//
// Sensors are locked to the MAC address of the tag they were added from;
// the Sensors menu item id of a sensor is that MAC.
//
// This menu makes no BLE calls (BLE activity here caused a System Error on
// the Montana when the menu closed). The "Add sensor" list is read from
// Application.Storage, where the running data field saves the tags it hears.
//
import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

//! @return Sensor count text, e.g. "2 of 8 used"
function sensorCountText() as String {
    return RuuviConfig.loadDevices().size() + " of " + RuuviConfig.MAX_DEVICES + " used";
}

//! @return Shown sensor count text, e.g. "2 of 3 shown", or "No sensors"
function displayText() as String {
    var devices = RuuviConfig.loadDevices();
    if (devices.size() == 0) {
        return "No sensors";
    }
    return RuuviConfig.visibleIndices(devices).size() + " of " + devices.size() + " shown";
}

//! Sub-label of a sensor's menu item, e.g. "Temperature, BBF3".
//! @param show RuuviConfig.SHOW_* value
//! @param mac  12 hex digits
//! @return Sub-label text
function describeSensor(show as Number, mac as String) as String {
    var tail = (mac.length() == 12) ? mac.substring(8, 12) : mac;
    return Lang.format("$1$, $2$", [RuuviConfig.choiceLabel(RuuviConfig.SHOW_LABELS, show), tail]);
}

// -------------------------------------------------------------------------
// Main menu: Sensors, units
// -------------------------------------------------------------------------

class RuuviMainMenu extends WatchUi.Menu2 {

    //! Builds the menu: Display, the Sensors sub-menu, then the units.
    function initialize() {
        Menu2.initialize({ :title => "RuuviSensor" });
        addItem(new WatchUi.MenuItem("Display", displayText(), :display, null));
        addItem(new WatchUi.MenuItem("Sensors", sensorCountText(), :sensors, null));
        addItem(new WatchUi.MenuItem("Temperature unit",
            RuuviConfig.choiceLabel(RuuviConfig.TEMP_UNIT_LABELS,
                RuuviConfig.getNumber(RuuviConfig.TEMP_UNIT_KEY, RuuviConfig.TEMP_DEVICE)),
            :tempUnit, null));
        addItem(new WatchUi.MenuItem("Pressure unit",
            RuuviConfig.choiceLabel(RuuviConfig.PRESSURE_UNIT_LABELS,
                RuuviConfig.getNumber(RuuviConfig.PRESSURE_UNIT_KEY, RuuviConfig.PRESSURE_HPA)),
            :pressureUnit, null));
    }

    //! Refreshes the Display count when a sub-menu closes (adding or
    //! removing a sensor changes it).
    function onShow() as Void {
        Menu2.onShow();
        var idx = findItemById(:display);
        var item = (idx >= 0) ? getItem(idx) : null;
        if (item != null) {
            item.setSubLabel(displayText());
        }
    }
}

class RuuviMainMenuDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    //! Opens the sub-menu for the selected item.
    //! @param item Selected item (id = :display, :sensors, :tempUnit or :pressureUnit)
    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :display) {
            WatchUi.pushView(new RuuviDisplayMenu(), new RuuviDisplayMenuDelegate(item), WatchUi.SLIDE_LEFT);
        } else if (id == :sensors) {
            var menu = new RuuviSensorsMenu();
            WatchUi.pushView(menu, new RuuviSensorsMenuDelegate(menu, item), WatchUi.SLIDE_LEFT);
        } else if (id == :tempUnit) {
            var current = RuuviConfig.getNumber(RuuviConfig.TEMP_UNIT_KEY, RuuviConfig.TEMP_DEVICE);
            WatchUi.pushView(new RuuviChoiceMenu("Temperature unit", RuuviConfig.TEMP_UNIT_LABELS, current),
                new RuuviChoiceMenuDelegate(:tempUnit, null, item, null), WatchUi.SLIDE_LEFT);
        } else if (id == :pressureUnit) {
            var current = RuuviConfig.getNumber(RuuviConfig.PRESSURE_UNIT_KEY, RuuviConfig.PRESSURE_HPA);
            WatchUi.pushView(new RuuviChoiceMenu("Pressure unit", RuuviConfig.PRESSURE_UNIT_LABELS, current),
                new RuuviChoiceMenuDelegate(:pressureUnit, null, item, null), WatchUi.SLIDE_LEFT);
        }
    }

    //! Back from the main menu closes the settings (default Menu2
    //! behaviour). Logged so the device log shows how many back presses
    //! actually reach the app.
    function onBack() as Void {
        trace("settings main menu onBack");
        Menu2InputDelegate.onBack();
    }
}

// -------------------------------------------------------------------------
// Display menu: which sensors the field shows (side by side)
// -------------------------------------------------------------------------

class RuuviDisplayMenu extends WatchUi.Menu2 {

    //! One on/off toggle per listed sensor (item id = MAC).
    function initialize() {
        Menu2.initialize({ :title => "Display" });
        var devices = RuuviConfig.loadDevices();

        if (devices.size() == 0) {
            addItem(new WatchUi.MenuItem("No sensors", "Add one under Sensors", :none, null));
            return;
        }
        for (var i = 0; i < devices.size(); i++) {
            var mac = devices[i][RuuviConfig.F_MAC] as String;
            addItem(new WatchUi.ToggleMenuItem(devices[i][RuuviConfig.F_NAME] as String,
                RuuviConfig.formatMac(mac), mac, devices[i][RuuviConfig.F_VISIBLE] == true, null));
        }
    }
}

class RuuviDisplayMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var mItem as WatchUi.MenuItem;   // "Display" item in the main menu

    //! @param item "Display" item in the main menu
    function initialize(item as WatchUi.MenuItem) {
        Menu2InputDelegate.initialize();
        mItem = item;
    }

    //! Stores a sensor's new on/off state; the menu stays open so several
    //! sensors can be switched. Back returns to the main menu.
    //! @param item Selected item (id = MAC, or :none when the list is empty)
    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id instanceof String && item instanceof WatchUi.ToggleMenuItem) {
            RuuviConfig.updateDevice(id, RuuviConfig.F_VISIBLE, item.isEnabled());
            mItem.setSubLabel(displayText());
            getApp().applySettings();
        } else {
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
        }
    }
}

// -------------------------------------------------------------------------
// Sensors menu: "+ Add sensor", then one item per listed sensor
// -------------------------------------------------------------------------

class RuuviSensorsMenu extends WatchUi.Menu2 {

    //! Builds the sensor list (item id of a sensor = its MAC).
    function initialize() {
        Menu2.initialize({ :title => "Sensors" });
        addItem(new WatchUi.MenuItem("+ Add sensor", sensorCountText(), :add, null));

        var devices = RuuviConfig.loadDevices();
        for (var i = 0; i < devices.size(); i++) {
            var dev = devices[i];
            var mac = dev[RuuviConfig.F_MAC] as String;
            addItem(new WatchUi.MenuItem(dev[RuuviConfig.F_NAME] as String,
                describeSensor(dev[RuuviConfig.F_SHOW] as Number, mac), mac, null));
        }
    }
}

class RuuviSensorsMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var mMenu as RuuviSensorsMenu;        // to add / remove sensor items
    private var mMainItem as WatchUi.MenuItem;    // "Sensors" item in the main menu

    //! @param menu     The sensors menu
    //! @param mainItem "Sensors" item in the main menu (shows the count)
    function initialize(menu as RuuviSensorsMenu, mainItem as WatchUi.MenuItem) {
        Menu2InputDelegate.initialize();
        mMenu = menu;
        mMainItem = mainItem;
    }

    //! Opens "Add sensor" or the selected sensor's menu.
    //! @param item Selected item (id = :add or a MAC)
    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :add) {
            WatchUi.pushView(new RuuviAddMenu(), new RuuviAddMenuDelegate(mMenu, item, mMainItem),
                WatchUi.SLIDE_LEFT);
        } else if (id instanceof String) {
            WatchUi.pushView(new RuuviSensorMenu(id), new RuuviSensorMenuDelegate(id, mMenu, item, mMainItem),
                WatchUi.SLIDE_LEFT);
        }
    }
}

// -------------------------------------------------------------------------
// Add sensor: Ruuvi tags recently heard by the data field
// -------------------------------------------------------------------------

class RuuviAddMenu extends WatchUi.Menu2 {

    //! Lists tags from Storage (rows [mac, label, rssi, epochSeconds]) that
    //! are not in the sensor list yet.
    function initialize() {
        Menu2.initialize({ :title => "Add sensor" });

        var devices = RuuviConfig.loadDevices();
        if (devices.size() >= RuuviConfig.MAX_DEVICES) {
            addItem(new WatchUi.MenuItem("List is full", "Remove a sensor first", :full, null));
            return;
        }

        var raw = null;
        try {
            raw = Application.Storage.getValue(RuuviConfig.NEARBY_KEY);
        } catch (e) {
            System.println("RuuviSensor: cannot read nearby list: " + e.getErrorMessage());
        }

        var now = Time.now().value();
        var added = 0;
        if (raw instanceof Array) {
            var rows = raw as Array;
            for (var i = 0; i < rows.size(); i++) {
                if (addRow(rows[i], devices, now)) {
                    added++;
                }
            }
        }

        if (added == 0) {
            addItem(new WatchUi.MenuItem("No new sensors", "Run the data field nearby", :refresh, null));
        } else {
            addItem(new WatchUi.MenuItem("Refresh list", "List updates every 10 s", :refresh, null));
        }
    }

    //! Adds one saved row as a menu item (id = MAC, label = tag name),
    //! skipping malformed rows and tags already in the list.
    //! @param row     Saved row [mac, label, rssi, epochSeconds]
    //! @param devices Current sensor list
    //! @param now     Current time in epoch seconds
    //! @return true if an item was added
    private function addRow(row, devices as Array<Array>, now as Number) as Boolean {
        if (!(row instanceof Array)) {
            return false;
        }
        var fields = row as Array;
        if (fields.size() < 4 || fields[0] == null || fields[1] == null
                || fields[2] == null || fields[3] == null) {
            return false;
        }
        var mac = fields[0].toString();
        if (RuuviConfig.findDevice(devices, mac) >= 0) {
            return false;
        }
        var age = now - (fields[3] as Number);
        var sub = fields[2].toString() + " dBm, " + formatAge(age);
        addItem(new WatchUi.MenuItem(fields[1].toString(), sub, mac, null));
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

class RuuviAddMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var mSensorsMenu as RuuviSensorsMenu;
    private var mAddItem as WatchUi.MenuItem;    // "+ Add sensor" (shows count)
    private var mMainItem as WatchUi.MenuItem;   // "Sensors" in the main menu

    //! @param sensorsMenu Sensors menu to add the new sensor to
    //! @param addItem     "+ Add sensor" item
    //! @param mainItem    "Sensors" item in the main menu
    function initialize(sensorsMenu as RuuviSensorsMenu, addItem as WatchUi.MenuItem,
            mainItem as WatchUi.MenuItem) {
        Menu2InputDelegate.initialize();
        mSensorsMenu = sensorsMenu;
        mAddItem = addItem;
        mMainItem = mainItem;
    }

    //! A tag adds a sensor locked to its MAC; "Refresh" rebuilds the list.
    //! @param item Selected item (id = MAC, :refresh or :full)
    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id instanceof String) {
            var name = item.getLabel();
            if (RuuviConfig.addDevice(id, name)) {
                mSensorsMenu.addItem(new WatchUi.MenuItem(name,
                    describeSensor(RuuviConfig.SHOW_TEMPERATURE, id), id, null));
                mAddItem.setSubLabel(sensorCountText());
                mMainItem.setSubLabel(sensorCountText());
                getApp().applySettings();
            }
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
        } else if (id == :refresh) {
            WatchUi.switchToView(new RuuviAddMenu(), new RuuviAddMenuDelegate(mSensorsMenu, mAddItem, mMainItem),
                WatchUi.SLIDE_IMMEDIATE);
        } else {
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
        }
    }
}

// -------------------------------------------------------------------------
// Sensor menu: show / rename / remove
// -------------------------------------------------------------------------

class RuuviSensorMenu extends WatchUi.Menu2 {

    //! @param mac MAC of the sensor (12 hex digits)
    function initialize(mac as String) {
        var dev = RuuviConfig.getDevice(mac);
        var name = (dev != null) ? (dev[RuuviConfig.F_NAME] as String) : mac;
        var show = (dev != null) ? (dev[RuuviConfig.F_SHOW] as Number) : RuuviConfig.SHOW_TEMPERATURE;

        Menu2.initialize({ :title => name });
        addItem(new WatchUi.MenuItem("Show", RuuviConfig.choiceLabel(RuuviConfig.SHOW_LABELS, show),
            :show, null));
        if (WatchUi has :TextPicker) {
            addItem(new WatchUi.MenuItem("Rename", name, :rename, null));
        }
        addItem(new WatchUi.MenuItem("Remove", RuuviConfig.formatMac(mac), :remove, null));
    }
}

class RuuviSensorMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var mMac as String;
    private var mSensorsMenu as RuuviSensorsMenu;
    private var mMainItem as WatchUi.MenuItem;      // this sensor's item in the Sensors menu
    private var mCountItem as WatchUi.MenuItem;     // "Sensors" in the main menu

    //! @param mac         MAC of the sensor
    //! @param sensorsMenu Sensors menu (to remove the item)
    //! @param mainItem    This sensor's item in the Sensors menu
    //! @param countItem   "Sensors" item in the main menu
    function initialize(mac as String, sensorsMenu as RuuviSensorsMenu, mainItem as WatchUi.MenuItem,
            countItem as WatchUi.MenuItem) {
        Menu2InputDelegate.initialize();
        mMac = mac;
        mSensorsMenu = sensorsMenu;
        mMainItem = mainItem;
        mCountItem = countItem;
    }

    //! Handles Show / Rename / Remove.
    //! @param item Selected item
    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :show) {
            var dev = RuuviConfig.getDevice(mMac);
            var current = (dev != null) ? (dev[RuuviConfig.F_SHOW] as Number) : RuuviConfig.SHOW_TEMPERATURE;
            WatchUi.pushView(new RuuviChoiceMenu("Show", RuuviConfig.SHOW_LABELS, current),
                new RuuviChoiceMenuDelegate(:show, mMac, item, mMainItem), WatchUi.SLIDE_LEFT);
        } else if (id == :rename) {
            WatchUi.pushView(new WatchUi.TextPicker(mMainItem.getLabel()),
                new RuuviRenameDelegate(mMac, item, mMainItem), WatchUi.SLIDE_LEFT);
        } else if (id == :remove) {
            RuuviConfig.removeDevice(mMac);
            var idx = mSensorsMenu.findItemById(mMac);
            if (idx >= 0) {
                mSensorsMenu.deleteItem(idx);
            }
            var addIdx = mSensorsMenu.findItemById(:add);
            if (addIdx >= 0) {
                var addItem = mSensorsMenu.getItem(addIdx);
                if (addItem != null) {
                    addItem.setSubLabel(sensorCountText());
                }
            }
            mCountItem.setSubLabel(sensorCountText());
            getApp().applySettings();
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
        }
    }
}

// -------------------------------------------------------------------------
// Choice menu: Show / Temperature unit / Pressure unit
// -------------------------------------------------------------------------

class RuuviChoiceMenu extends WatchUi.Menu2 {

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

class RuuviChoiceMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var mKind as Symbol;                // :show, :tempUnit or :pressureUnit
    private var mMac as String?;                // sensor, for :show
    private var mItem as WatchUi.MenuItem;      // item showing the choice
    private var mMainItem as WatchUi.MenuItem?; // sensor's main-menu item, for :show

    //! @param kind     What is being chosen
    //! @param mac      Sensor MAC (for :show), else null
    //! @param item     Menu item whose sub-label shows the choice
    //! @param mainItem Sensor's main-menu item (for :show), else null
    function initialize(kind as Symbol, mac as String?, item as WatchUi.MenuItem,
            mainItem as WatchUi.MenuItem?) {
        Menu2InputDelegate.initialize();
        mKind = kind;
        mMac = mac;
        mItem = item;
        mMainItem = mainItem;
    }

    //! Stores the chosen index and returns.
    //! @param item Selected item (id = choice index)
    function onSelect(item as WatchUi.MenuItem) as Void {
        var index = item.getId() as Number;
        if (mKind == :tempUnit) {
            RuuviConfig.setNumber(RuuviConfig.TEMP_UNIT_KEY, index);
            mItem.setSubLabel(RuuviConfig.choiceLabel(RuuviConfig.TEMP_UNIT_LABELS, index));
        } else if (mKind == :pressureUnit) {
            RuuviConfig.setNumber(RuuviConfig.PRESSURE_UNIT_KEY, index);
            mItem.setSubLabel(RuuviConfig.choiceLabel(RuuviConfig.PRESSURE_UNIT_LABELS, index));
        } else {
            var mac = mMac;
            if (mac != null) {
                RuuviConfig.updateDevice(mac, RuuviConfig.F_SHOW, index);
                mItem.setSubLabel(RuuviConfig.choiceLabel(RuuviConfig.SHOW_LABELS, index));
                var mainItem = mMainItem;
                if (mainItem != null) {
                    mainItem.setSubLabel(describeSensor(index, mac));
                }
            }
        }
        getApp().applySettings();
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

// -------------------------------------------------------------------------
// Rename: on-screen keyboard
// -------------------------------------------------------------------------

class RuuviRenameDelegate extends WatchUi.TextPickerDelegate {

    private var mMac as String;
    private var mItem as WatchUi.MenuItem;       // "Rename" item
    private var mMainItem as WatchUi.MenuItem;   // sensor's main-menu item

    //! @param mac      Sensor MAC
    //! @param item     "Rename" item to refresh
    //! @param mainItem Sensor's main-menu item to refresh
    function initialize(mac as String, item as WatchUi.MenuItem, mainItem as WatchUi.MenuItem) {
        TextPickerDelegate.initialize();
        mMac = mac;
        mItem = item;
        mMainItem = mainItem;
    }

    //! Stores the new name; blank input is ignored.
    //! @param text    Entered text
    //! @param changed true if the text was edited
    //! @return true (the picker closes itself)
    function onTextEntered(text as String, changed as Boolean) as Boolean {
        var name = RuuviConfig.trim(text);
        if (name.length() > 0) {
            RuuviConfig.updateDevice(mMac, RuuviConfig.F_NAME, name);
            mItem.setSubLabel(name);
            mMainItem.setLabel(name);
            getApp().applySettings();
        }
        return true;
    }

    //! Keyboard dismissed without input.
    //! @return true
    function onCancel() as Boolean {
        return true;
    }
}
