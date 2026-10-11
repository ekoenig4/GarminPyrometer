//
// RuuviSensorView.mc
//
// Data field showing the sensors in the RuuviSensor list. The header is the
// sensor's name and the value is the quantity chosen in its "Show" setting:
//
//     header      value
//     Balloon 1   23.5 °C                (Show = Temperature, the default)
//     Balloon 1   T:23.5 H:61 P:1013     (Show = All)
//     Balloon 2   SCAN 3 found           (not heard yet)
//     Balloon 3   ---                    (no broadcast for 60 s)
//
// The field is drawn by hand (DataField + onUpdate) so single readings use
// the device's number fonts with the unit in a smaller font beside them, like
// the native fields. The field shows the one sensor chosen under Display in
// the settings menu, or with "Nearest at startup" (the default) the listed
// sensor with the strongest signal during the first NEAREST_WINDOW_MS of
// scanning; that choice is kept until the field restarts.
//
import Toybox.Activity;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

class RuuviSensorView extends WatchUi.DataField {

    // Readings older than this are flagged with "?" (tag went quiet)...
    private const STALE_DATA_MS = 30000;
    // ...and older than this are replaced by "---".
    private const LOST_DATA_MS = 60000;

    // Header when the list is empty.
    private const APP_LABEL = "RuuviSensor";

    // "Nearest at startup": listen this long before choosing, then lock.
    private const NEAREST_WINDOW_MS = 10000;
    private const NEAREST_LABEL = "Nearest";

    // Value fonts, largest first. Number fonts only contain digits and a few
    // symbols, so they are used for plain numbers only. FONT_NUMBER_THAI_HOT
    // is left out: on the Montana it dwarfs the native fields.
    private const NUMBER_FONTS = [
        Graphics.FONT_NUMBER_HOT,
        Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD,
        Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL,
        Graphics.FONT_TINY, Graphics.FONT_XTINY
    ];
    private const TEXT_FONTS = [
        Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL,
        Graphics.FONT_TINY, Graphics.FONT_XTINY
    ];

    // What onUpdate() draws, prepared by compute().
    private var mLabel as String = APP_LABEL;  // header
    private var mValue as String = "";         // main value
    private var mUnit as String = "";          // unit drawn after a numeric value
    private var mNumeric as Boolean = false;   // mValue is a plain number

    // MAC locked in by "Nearest at startup" (null until chosen).
    private var mNearestMac as String? = null;

    //! Constructor.
    function initialize() {
        DataField.initialize();
        var devices = RuuviConfig.loadDevices();
        var idx = RuuviConfig.findDevice(devices, RuuviConfig.getActive());
        if (idx >= 0) {
            mLabel = devices[idx][RuuviConfig.F_NAME] as String;
        } else if (devices.size() > 0) {
            mLabel = NEAREST_LABEL;
        }
    }

    //! Called once per second by the activity. Drives the scanner and
    //! prepares the header / value for the sensor on screen.
    //! @param info Activity info (unused; data comes from BLE)
    function compute(info as Activity.Info) as Void {
        // BLE starts a few seconds after the field does (see RuuviSensorApp).
        var app = getApp();
        var scanner = app.ensureScanner();
        if (scanner == null) {
            setText(app.hasBle() ? "STARTING" : "NO BLE");
            return;
        }

        try {
            scanner.tick();

            var devices = scanner.getDevices();
            if (devices.size() == 0) {
                // Still scanning, so the settings menu can offer nearby tags.
                mLabel = APP_LABEL;
                setText("NO SENSORS " + scanner.getStatus());
                return;
            }

            // The sensor chosen under Display, else the nearest at startup.
            var idx = RuuviConfig.findDevice(devices, scanner.getActive());
            if (idx < 0) {
                idx = nearestIndex(devices, scanner);
                if (idx < 0) {
                    mLabel = NEAREST_LABEL;
                    setText("SCAN " + scanner.getStatus());
                    return;
                }
            }

            var now = System.getTimer();
            var dev = devices[idx];
            var mac = dev[RuuviConfig.F_MAC] as String;
            mLabel = dev[RuuviConfig.F_NAME] as String;
            formatReading(scanner.getReading(mac), dev[RuuviConfig.F_SHOW] as Number, scanner, now);
        } catch (e) {
            // Never let a display problem crash the data field.
            System.println("RuuviSensor: compute error: " + e.getErrorMessage());
            setText("---");
        }
    }

    //! "Nearest at startup": after NEAREST_WINDOW_MS of scanning, locks onto
    //! the listed sensor heard with the strongest signal (later, if none was
    //! heard yet). The lock is by MAC and lasts until the field restarts.
    //! @param devices Sensor list
    //! @param scanner Scanner
    //! @return Index of the locked sensor, or -1 while still choosing
    private function nearestIndex(devices as Array<Array>, scanner as RuuviScanner) as Number {
        var locked = mNearestMac;
        if (locked != null) {
            var idx = RuuviConfig.findDevice(devices, locked);
            if (idx >= 0) {
                return idx;
            }
            mNearestMac = null;   // removed from the list: choose again
        }
        if (scanner.scanAgeMs() < NEAREST_WINDOW_MS) {
            return -1;
        }
        var nearest = scanner.getNearestIndex();
        if (nearest >= 0) {
            mNearestMac = devices[nearest][RuuviConfig.F_MAC] as String;
            System.println("RuuviSensor: nearest sensor is " + devices[nearest][RuuviConfig.F_NAME]);
        }
        return nearest;
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
        // System fonts, as used by the device's own data field labels.
        var labelFont = (h >= 120) ? Graphics.FONT_SYSTEM_MEDIUM
            : ((h >= 70) ? Graphics.FONT_SYSTEM_SMALL : Graphics.FONT_SYSTEM_TINY);
        var labelH = dc.getFontHeight(labelFont);
        dc.drawText(w / 2, 1, labelFont, mLabel, Graphics.TEXT_JUSTIFY_CENTER);

        // ---- Value ----
        var top = labelH + 1;
        var avail = h - top;
        var maxW = w - 6;
        var unitFont = (h >= 120) ? Graphics.FONT_LARGE
            : ((h >= 70) ? Graphics.FONT_MEDIUM : Graphics.FONT_SMALL);
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
            // Unit vertically centred on the number, directly beside it.
            dc.drawText(x + valueW, cy, unitFont, " " + mUnit,
                Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
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

    //! Prepares the value for one sensor (its name is in the header).
    //! @param reading [tempC, humidity, hPa, timerMs] or null if not heard yet
    //! @param show    RuuviConfig.SHOW_* value
    //! @param scanner Scanner (for the status text)
    //! @param now     System.getTimer()
    private function formatReading(reading as Array?, show as Number, scanner as RuuviScanner,
            now as Number) as Void {
        if (reading == null) {
            setText("SCAN " + scanner.getStatus());
            return;
        }
        var age = now - (reading[3] as Number);
        if (age > LOST_DATA_MS) {
            setText("---");
            return;
        }

        var t = reading[0] as Float;
        var h = reading[1] as Float;
        var p = reading[2] as Float;
        var mark = (age > STALE_DATA_MS) ? "?" : "";

        // Convert to the configured units (Ruuvi data is °C and hPa).
        var app = getApp();
        var tempText = (app.useFahrenheit() ? (t * 9.0 / 5.0 + 32.0) : t).format("%.1f");
        var tempUnit = app.useFahrenheit() ? "°F" : "°C";
        var presUnit = app.getPressureUnit();
        var presText;
        var presSuffix;
        if (presUnit == RuuviConfig.PRESSURE_INHG) {
            presText = (p * 0.0295300).format("%.2f");
            presSuffix = "inHg";
        } else if (presUnit == RuuviConfig.PRESSURE_MMHG) {
            presText = (p * 0.750062).format("%.0f");
            presSuffix = "mmHg";
        } else {
            presText = p.format("%.0f");
            presSuffix = "hPa";
        }

        if (show == RuuviConfig.SHOW_HUMIDITY) {
            setNumber(h.format("%.0f"), "%RH" + mark);
        } else if (show == RuuviConfig.SHOW_PRESSURE) {
            setNumber(presText, presSuffix + mark);
        } else if (show == RuuviConfig.SHOW_ALL) {
            setText("T:" + tempText + " H:" + h.format("%.0f") + " P:" + presText + mark);
        } else {
            setNumber(tempText, tempUnit + mark);
        }
    }
}
