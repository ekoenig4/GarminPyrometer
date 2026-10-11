//
// EnvSensorView.mc
//
// Data field that shows temperature, humidity and/or pressure from the
// configured BLE sensors. The header is the device's display name and the
// value is the quantity chosen in that device's "Show" setting:
//
//     header      value
//     Balloon 1   23.5 °C                (Show = Temperature, the default)
//     Balloon 1   T:23.5 H:61 P:1013     (Show = All)
//     Balloon 2   SCAN 5 dev RUUVI
//     Balloon 3   ---
//
// The field is drawn by hand (DataField + onUpdate) rather than as a
// SimpleDataField: a SimpleDataField value containing a unit such as "°C" is
// rendered in a text font, noticeably smaller than the number font the
// device's own data fields use. Here single readings are drawn in the largest
// number font that fits, with the unit in a small font beside it, like the
// native fields.
//
// When several devices are configured the view rotates through them every
// ROTATE_INTERVAL_MS.
//
import Toybox.Activity;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

class EnvSensorView extends WatchUi.DataField {

    // How long each device stays on screen when several are configured.
    private const ROTATE_INTERVAL_MS = 3000;

    // Readings older than this are flagged with "?" (sensor went quiet).
    private const STALE_DATA_MS = 30000;

    // Header when no device is configured.
    private const APP_LABEL = "RuuviSensor";

    // Value fonts, largest first. Number fonts only contain digits and a few
    // symbols, so they are used for plain numbers only.
    // FONT_NUMBER_THAI_HOT is left out: on the Montana it dwarfs the
    // native fields.
    private const NUMBER_FONTS = [
        Graphics.FONT_NUMBER_HOT,
        Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD,
        Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL,
        Graphics.FONT_TINY, Graphics.FONT_XTINY
    ];
    // Share of a font's line height taken by digits / capitals (the rest is
    // padding and descent); used to fit and align values.
    private const GLYPH_RATIO = 0.8;

    private const TEXT_FONTS = [
        Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL,
        Graphics.FONT_TINY, Graphics.FONT_XTINY
    ];

    // BLE delegate, obtained from the app once BLE has started.
    private var mBle as EnvSensorBleDelegate?;

    // Index into the delegate's slot array of the device currently shown.
    private var mActiveSlot as Number = 0;

    // System.getTimer() value when mActiveSlot was last advanced.
    private var mLastRotateMs as Number = 0;

    // What onUpdate() draws, prepared by compute().
    private var mLabel as String = APP_LABEL;  // header
    private var mValue as String = "";         // main value
    private var mUnit as String = "";          // unit drawn after a numeric value
    private var mNumeric as Boolean = false;   // mValue is a plain number

    //! Constructor.
    function initialize() {
        DataField.initialize();
        mLabel = initialLabel();
        mLastRotateMs = System.getTimer();
    }

    //! Header before BLE starts: the first configured device's display name.
    //! @return Label text
    private function initialLabel() as String {
        for (var i = 0; i < EnvSensorApp.MAX_DEVICES; i++) {
            if (EnvSettings.getBleId(i).length() > 0) {
                return EnvSettings.getDisplayName(i);
            }
        }
        return APP_LABEL;
    }

    //! Called once per second by the activity. Drives BLE housekeeping and
    //! prepares the header / value for the active device.
    //! @param info Activity info (unused; data comes from BLE)
    function compute(info as Activity.Info) as Void {
        // BLE starts a few seconds after the field does (see EnvSensorApp).
        var app = getApp();
        var ble = app.ensureBle();
        mBle = ble;
        if (ble == null) {
            setText(app.hasBle() ? "STARTING" : "NO BLE");
            return;
        }

        try {
            // Timeouts, reconnects and cycling run on the compute() cadence.
            ble.tick();

            var slots = ble.getSlots();
            var active = selectActiveSlot(slots);
            if (active == null) {
                // Still scanning, so the settings menu can list nearby devices.
                mLabel = APP_LABEL;
                setText("NO SENSORS " + ble.getScanStatus());
                return;
            }
            mLabel = active.displayName;
            formatSlot(active);
        } catch (e) {
            // Never let a display problem crash the data field.
            System.println("RuuviSensor: compute error: " + e.getErrorMessage());
            setText("---");
        }
    }

    //! Draws the header at the top and the value in the largest font that
    //! fits the remaining space, in the device's data field colours.
    //! @param dc Device context
    function onUpdate(dc as Graphics.Dc) as Void {
        var bg = getBackgroundColor();
        var fg = (bg == Graphics.COLOR_BLACK) ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        dc.setColor(fg, bg);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();

        // ---- Header ----
        var labelFont = (h >= 120) ? Graphics.FONT_MEDIUM
            : ((h >= 70) ? Graphics.FONT_SMALL : Graphics.FONT_TINY);
        var labelH = dc.getFontHeight(labelFont);
        dc.drawText(w / 2, 1, labelFont, mLabel, Graphics.TEXT_JUSTIFY_CENTER);

        // ---- Value ----
        var top = labelH + 1;
        var avail = h - top;
        var maxW = w - 6;
        // Unit one size up from the header so it stays readable.
        var unitFont = (labelFont == Graphics.FONT_MEDIUM) ? Graphics.FONT_LARGE
            : ((labelFont == Graphics.FONT_SMALL) ? Graphics.FONT_MEDIUM : Graphics.FONT_SMALL);
        var unitW = (mUnit.length() > 0) ? dc.getTextWidthInPixels(" " + mUnit, unitFont) : 0;

        var fonts = mNumeric ? NUMBER_FONTS : TEXT_FONTS;
        var font = fonts[fonts.size() - 1];
        for (var i = 0; i < fonts.size(); i++) {
            var f = fonts[i];
            // Fit the full line height so the number is not oversized.
            if (dc.getFontHeight(f) <= avail && dc.getTextWidthInPixels(mValue, f) + unitW <= maxW) {
                font = f;
                break;
            }
        }

        var valueW = dc.getTextWidthInPixels(mValue, font);
        var x = (w - valueW - unitW) / 2;
        var cy = top + avail / 2;
        dc.drawText(x, cy, font, mValue, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        if (unitW > 0) {
            // Unit sits on the value's baseline, like the native fields.
            var valueBottom = cy + dc.getFontHeight(font) * GLYPH_RATIO / 2;
            var unitTop = valueBottom - dc.getFontHeight(unitFont) * GLYPH_RATIO;
            dc.drawText(x + valueW, unitTop.toNumber(), unitFont, " " + mUnit, Graphics.TEXT_JUSTIFY_LEFT);
        }
    }

    //! Sets a text (non-numeric) value with no unit.
    //! @param text Value text
    private function setText(text as String) as Void {
        mValue = text;
        mUnit = "";
        mNumeric = false;
    }

    //! Sets a numeric value drawn in a number font, with a unit beside it.
    //! @param value Number text (digits, '.', '-')
    //! @param unit  Unit text
    private function setNumber(value as String, unit as String) as Void {
        mValue = value;
        mUnit = unit;
        mNumeric = true;
    }

    //! Picks the device to display, advancing to the next enabled slot every
    //! ROTATE_INTERVAL_MS. Copes with slots being enabled / disabled by a
    //! mid-activity settings change.
    //! @param slots All device slots
    //! @return Active slot, or null if no slot is enabled
    private function selectActiveSlot(slots as Array<EnvDeviceState>) as EnvDeviceState? {
        var count = slots.size();
        if (count == 0) {
            return null;
        }
        if (mActiveSlot >= count) {
            mActiveSlot = 0;
        }

        var now = System.getTimer();
        var rotate = (now - mLastRotateMs) >= ROTATE_INTERVAL_MS;
        if (rotate) {
            mLastRotateMs = now;
        }

        // Start from the next slot when rotating, else from the current one,
        // and take the first enabled slot found.
        var start = rotate ? (mActiveSlot + 1) % count : mActiveSlot;
        for (var n = 0; n < count; n++) {
            var idx = (start + n) % count;
            if (slots[idx].isEnabled()) {
                mActiveSlot = idx;
                return slots[idx];
            }
        }
        return null;
    }

    //! Prepares the value for one device (its name is in the header).
    //!   SCAN <status>   : searching / pairing, never connected since config;
    //!                     <status> is EnvSensorBleDelegate.getScanStatus()
    //!   ---             : link lost / broadcasts stopped
    //!   WAIT            : connected, first packet not received yet
    //!   readings        : per the device's Show setting ("?" after the unit
    //!                     when stale)
    //! @param slot Device state
    private function formatSlot(slot as EnvDeviceState) as Void {
        if (slot.state == EnvDeviceState.STATE_SCANNING) {
            var ble = mBle;
            setText("SCAN" + ((ble != null) ? (" " + ble.getScanStatus()) : ""));
            return;
        }
        if (slot.state != EnvDeviceState.STATE_CONNECTED) {
            // Unavailable (or any unexpected state): configured but no data.
            setText("---");
            return;
        }

        var t = slot.temperature;
        var h = slot.humidity;
        var p = slot.pressure;
        if (t == null || h == null || p == null) {
            setText("WAIT");
            return;
        }

        // Convert to the configured units (sensor data is °C and hPa).
        var app = getApp();
        var tempText = (app.useFahrenheit() ? (t * 9.0 / 5.0 + 32.0) : t).format("%.1f");
        var tempUnit = app.useFahrenheit() ? "°F" : "°C";
        var presUnit = app.getPressureUnit();
        var presText;
        var presSuffix;
        if (presUnit == EnvSettings.PRESSURE_INHG) {
            presText = (p * 0.0295300).format("%.2f");
            presSuffix = "inHg";
        } else if (presUnit == EnvSettings.PRESSURE_MMHG) {
            presText = (p * 0.750062).format("%.0f");
            presSuffix = "mmHg";
        } else {
            presText = p.format("%.0f");
            presSuffix = "hPa";
        }

        var stale = (System.getTimer() - slot.lastDataMs) > STALE_DATA_MS;
        var mark = stale ? "?" : "";

        if (slot.show == EnvDeviceState.SHOW_TEMPERATURE) {
            setNumber(tempText, tempUnit + mark);
        } else if (slot.show == EnvDeviceState.SHOW_HUMIDITY) {
            setNumber(h.format("%.0f"), "%RH" + mark);
        } else if (slot.show == EnvDeviceState.SHOW_PRESSURE) {
            setNumber(presText, presSuffix + mark);
        } else {
            setText("T:" + tempText + " H:" + h.format("%.0f") + " P:" + presText + mark);
        }
    }
}
