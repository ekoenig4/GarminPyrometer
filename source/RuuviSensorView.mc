//
// RuuviSensorView.mc
//
// Data field showing the sensors in the RuuviSensor list side by side. Each
// visible sensor (chosen under Display in the settings menu) gets a cell
// with its name as the header and the quantity chosen in its "Show" setting
// as the value:
//
//     +------------+------------+------------+
//     | Balloon 1  | Balloon 2  | Burner     |
//     |  23.5 °C   |   61 %RH   |  SCAN 3 found
//     +------------+------------+------------+
//
//     23.5 °C               Show = Temperature (the default)
//     T:23.5 H:61 P:1013    Show = All
//     SCAN 3 found          not heard yet
//     ---                   no broadcast for 60 s
//
// The cells are laid out in the grid (columns x rows) that gives the
// largest value font in the space the field has. The field is drawn by hand
// (DataField + onUpdate) so single readings use the device's number fonts
// with the unit in a smaller font beside them, like the native fields.
//
// The temperature of every displayed sensor is also written to the
// activity's FIT file (see logTemperatures()).
//
import Toybox.Activity;
import Toybox.FitContributor;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

class RuuviSensorView extends WatchUi.DataField {

    // Readings older than this are flagged with "?" (tag went quiet)...
    private const STALE_DATA_MS = 30000;
    // ...and older than this are replaced by "---" (and not logged).
    private const LOST_DATA_MS = 60000;

    // Header when the list is empty.
    private const APP_LABEL = "RuuviSensor";

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

    // A cell is [label, value, unit, numeric]: header, main value, unit drawn
    // after a numeric value, and whether the value is a plain number.
    private const C_LABEL = 0;
    private const C_VALUE = 1;
    private const C_UNIT = 2;
    private const C_NUMERIC = 3;

    // What onUpdate() draws, prepared by compute(): one cell per visible
    // sensor, or a single status cell.
    private var mCells as Array<Array>;

    // FIT temperature fields created so far, with the MAC each logs and its
    // field id (the sensor's list position when it was created).
    private var mFitFields as Array<FitContributor.Field>;
    private var mFitMacs as Array<String>;
    private var mFitIds as Array<Number>;

    // Float with the bit pattern 0xFFFFFFFF, FIT's "invalid" float32 value:
    // logged while a sensor has no reading.
    private var mFitInvalid as Float;

    //! Constructor. Creates the FIT fields for the sensors displayed now.
    function initialize() {
        DataField.initialize();
        mCells = [statusCell(APP_LABEL, "")] as Array<Array>;
        mFitFields = [] as Array<FitContributor.Field>;
        mFitMacs = [] as Array<String>;
        mFitIds = [] as Array<Number>;
        mFitInvalid = [0xFF, 0xFF, 0xFF, 0xFF]b.decodeNumber(Lang.NUMBER_FORMAT_FLOAT, {}) as Float;
        var devices = RuuviConfig.loadDevices();
        var shown = RuuviConfig.visibleIndices(devices);
        for (var i = 0; i < shown.size(); i++) {
            fitFieldFor(devices, shown[i]);
        }
        trace("view created, logging " + mFitFields.size() + " sensors");
    }

    //! The field is shown (also when the settings menu above it closes).
    function onShow() as Void {
        trace("view onShow");
    }

    //! The field is hidden (also when the settings menu opens above it).
    function onHide() as Void {
        trace("view onHide");
    }

    //! Called once per second by the activity. Drives the scanner, logs the
    //! temperatures and prepares a cell for each visible sensor.
    //! @param info Activity info (unused; data comes from BLE)
    function compute(info as Activity.Info) as Void {
        // BLE starts a few seconds after the field does (see RuuviSensorApp).
        var app = getApp();
        var scanner = app.ensureScanner();
        if (scanner == null) {
            mCells = [statusCell(APP_LABEL, app.hasBle() ? "STARTING" : "NO BLE")] as Array<Array>;
            return;
        }

        try {
            scanner.tick();
            var now = System.getTimer();
            logTemperatures(scanner, now);

            var devices = scanner.getDevices();
            if (devices.size() == 0) {
                // Still scanning, so the settings menu can offer nearby tags.
                mCells = [statusCell(APP_LABEL, "NO SENSORS " + scanner.getStatus())] as Array<Array>;
                return;
            }
            var shown = RuuviConfig.visibleIndices(devices);
            if (shown.size() == 0) {
                mCells = [statusCell(APP_LABEL, "NONE SHOWN")] as Array<Array>;
                return;
            }

            var cells = [] as Array<Array>;
            for (var i = 0; i < shown.size(); i++) {
                var dev = devices[shown[i]];
                var mac = dev[RuuviConfig.F_MAC] as String;
                var cell = formatReading(scanner.getReading(mac), dev[RuuviConfig.F_SHOW] as Number,
                    scanner, now);
                cell[C_LABEL] = dev[RuuviConfig.F_NAME] as String;
                cells.add(cell);
            }
            mCells = cells;
        } catch (e) {
            // Never let a display problem crash the data field.
            System.println("RuuviSensor: compute error: " + e.getErrorMessage());
            mCells = [statusCell(APP_LABEL, "---")] as Array<Array>;
        }
    }

    //! Draws the cells in the grid that fits them best, in the device's data
    //! field colours.
    //! @param dc Device context
    function onUpdate(dc as Graphics.Dc) as Void {
        try {
            draw(dc);
        } catch (e) {
            // An uncaught error here ends the data field (it then shows the
            // app icon); log it and leave this frame blank instead.
            System.println("RuuviSensor: draw error: " + e.getErrorMessage());
        }
    }

    // ---------------------------------------------------------------------
    // FIT logging
    // ---------------------------------------------------------------------

    //! Returns the FIT temperature field (°C, record level) of a sensor,
    //! creating it the first time. The field id is the sensor's list
    //! position, matching the fitField entries in resources/fit/fit.xml (the
    //! lowest free id if that one is taken), and the field name is the
    //! sensor's name.
    //! @param devices Sensor list
    //! @param idx     Index of the sensor in devices
    //! @return Index in mFitFields, or -1 if no field could be created
    private function fitFieldFor(devices as Array<Array>, idx as Number) as Number {
        var mac = devices[idx][RuuviConfig.F_MAC] as String;
        for (var i = 0; i < mFitMacs.size(); i++) {
            if (mac.equals(mFitMacs[i])) {
                return i;
            }
        }
        var id = (mFitIds.indexOf(idx) < 0) ? idx : -1;
        for (var free = 0; id < 0 && free < RuuviConfig.MAX_DEVICES; free++) {
            if (mFitIds.indexOf(free) < 0) {
                id = free;
            }
        }
        if (id < 0 || id >= RuuviConfig.MAX_DEVICES) {
            return -1;   // all fit.xml ids used (sensors replaced mid-activity)
        }
        try {
            var field = createField(fitFieldName(devices[idx][RuuviConfig.F_NAME] as String, id), id,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "°C" });
            field.setData(mFitInvalid);
            mFitFields.add(field);
            mFitMacs.add(mac);
            mFitIds.add(id);
            trace("FIT field " + id + " created for " + devices[idx][RuuviConfig.F_NAME]);
            return mFitFields.size() - 1;
        } catch (e) {
            System.println("RuuviSensor: cannot create FIT field " + id + ": " + e.getErrorMessage());
            return -1;
        }
    }

    //! @param name  Sensor name
    //! @param index List position
    //! @return FIT field name: the sensor's name, at most 16 characters
    //!         ("sensor 1" etc. if the name is empty)
    private function fitFieldName(name as String, index as Number) as String {
        if (name.length() == 0) {
            return "sensor " + (index + 1);
        }
        return (name.length() > 16) ? name.substring(0, 16) : name;
    }

    //! Logs the displayed sensors: each FIT field gets its sensor's latest
    //! temperature (°C), or FIT's invalid value (a gap) while the sensor is
    //! switched off under Display, removed, or not heard for LOST_DATA_MS.
    //! A sensor switched on during the activity gets its field then.
    //! @param scanner Scanner
    //! @param now     System.getTimer()
    private function logTemperatures(scanner as RuuviScanner, now as Number) as Void {
        var devices = scanner.getDevices();
        var shown = RuuviConfig.visibleIndices(devices);
        for (var i = 0; i < shown.size(); i++) {
            fitFieldFor(devices, shown[i]);
        }
        for (var i = 0; i < mFitFields.size(); i++) {
            var idx = RuuviConfig.findDevice(devices, mFitMacs[i]);
            var reading = (idx >= 0 && devices[idx][RuuviConfig.F_VISIBLE] == true)
                ? scanner.getReading(mFitMacs[i]) : null;
            if (reading != null && (now - (reading[3] as Number)) <= LOST_DATA_MS) {
                mFitFields[i].setData(reading[0] as Float);
            } else {
                mFitFields[i].setData(mFitInvalid);
            }
        }
    }

    // ---------------------------------------------------------------------
    // Drawing
    // ---------------------------------------------------------------------

    //! Does the drawing for onUpdate(): picks the grid, then draws each cell
    //! and the lines between them.
    //! @param dc Device context
    private function draw(dc as Graphics.Dc) as Void {
        var bg = getBackgroundColor();
        var fg = (bg == Graphics.COLOR_BLACK) ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        dc.setColor(fg, bg);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var cells = mCells;
        var n = cells.size();
        var cols = bestColumns(dc, cells, w, h);
        var rows = (n + cols - 1) / cols;

        for (var i = 0; i < n; i++) {
            var col = i % cols;
            var row = i / cols;
            // Integer edges so neighbouring cells share their border pixels.
            var x0 = col * w / cols;
            var x1 = (col + 1) * w / cols;
            var y0 = row * h / rows;
            var y1 = (row + 1) * h / rows;
            drawCell(dc, cells[i], x0, y0, x1 - x0, y1 - y0);
        }

        // Lines between the cells.
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        for (var c = 1; c < cols; c++) {
            var x = c * w / cols;
            dc.drawLine(x, 0, x, h);
        }
        for (var r = 1; r < rows; r++) {
            var y = r * h / rows;
            dc.drawLine(0, y, w, y);
        }
    }

    //! Picks the grid (number of columns) for the cells. Each grid is scored
    //! by the value font height in its worst cell; among grids scoring at
    //! least 80% of the best, the one with the fewest empty cells wins, then
    //! the one with more columns (side by side).
    //! @param dc    Device context
    //! @param cells Cells to lay out
    //! @param w     Field width
    //! @param h     Field height
    //! @return Number of columns (1..cells.size())
    private function bestColumns(dc as Graphics.Dc, cells as Array<Array>, w as Number,
            h as Number) as Number {
        var n = cells.size();
        var scores = new [n + 1] as Array<Number>;
        var top = -1000000;
        for (var cols = 1; cols <= n; cols++) {
            var rows = (n + cols - 1) / cols;
            var score = gridScore(dc, cells, w / cols, h / rows);
            scores[cols] = score;
            if (score > top) {
                top = score;
            }
        }
        var best = 1;
        var bestEmpty = n;
        if (top <= 0) {
            // Nothing fits anywhere: take the least bad grid.
            for (var cols = 1; cols <= n; cols++) {
                if (scores[cols] == top) {
                    return cols;
                }
            }
        }
        for (var cols = 1; cols <= n; cols++) {
            var empty = ((n + cols - 1) / cols) * cols - n;
            if ((scores[cols] as Number) * 5 >= top * 4 && empty <= bestEmpty) {
                best = cols;
                bestEmpty = empty;
            }
        }
        return best;
    }

    //! @param dc    Device context
    //! @param cells Cells to lay out
    //! @param cw    Cell width
    //! @param ch    Cell height
    //! @return Value font height in the worst cell; a value that does not
    //!         fit even in the smallest font scores below every grid where
    //!         it fits
    private function gridScore(dc as Graphics.Dc, cells as Array<Array>, cw as Number,
            ch as Number) as Number {
        var score = 1000000;
        for (var i = 0; i < cells.size(); i++) {
            var fit = fitValue(dc, cells[i], cw, ch);
            var fontH = dc.getFontHeight(fit[0] as Graphics.FontType);
            if (!(fit[1] as Boolean)) {
                fontH -= 1000;
            }
            if (fontH < score) {
                score = fontH;
            }
        }
        return score;
    }

    //! @param h Cell height
    //! @return Header font for a cell of this height (system fonts, as the
    //!         device's own data field labels use)
    private function labelFont(h as Number) as Graphics.FontType {
        return (h >= 120) ? Graphics.FONT_SYSTEM_MEDIUM
            : ((h >= 70) ? Graphics.FONT_SYSTEM_SMALL : Graphics.FONT_SYSTEM_TINY);
    }

    //! @param h Cell height
    //! @return Unit font for a cell of this height
    private function unitFont(h as Number) as Graphics.FontType {
        return (h >= 120) ? Graphics.FONT_LARGE
            : ((h >= 70) ? Graphics.FONT_MEDIUM : Graphics.FONT_SMALL);
    }

    //! Finds the largest value font that fits a cell below its header.
    //! @param dc   Device context
    //! @param cell Cell [label, value, unit, numeric]
    //! @param w    Cell width
    //! @param h    Cell height
    //! @return [font, fits]: fits is false if even the smallest font is too
    //!         big (the smallest font is returned then)
    private function fitValue(dc as Graphics.Dc, cell as Array, w as Number, h as Number) as Array {
        var avail = h - dc.getFontHeight(labelFont(h)) - 1;
        var maxW = w - 6;
        var value = cell[C_VALUE] as String;
        var unit = cell[C_UNIT] as String;
        var unitW = (unit.length() > 0) ? dc.getTextWidthInPixels(" " + unit, unitFont(h)) : 0;

        var fonts = (cell[C_NUMERIC] as Boolean) ? NUMBER_FONTS : TEXT_FONTS;
        for (var i = 0; i < fonts.size(); i++) {
            var f = fonts[i];
            // Fit the full line height so the number is not oversized.
            if (dc.getFontHeight(f) <= avail && dc.getTextWidthInPixels(value, f) + unitW <= maxW) {
                return [f, true];
            }
        }
        return [fonts[fonts.size() - 1], false];
    }

    //! Draws one cell: the header at the top and the value in the largest
    //! font that fits the space below it.
    //! @param dc   Device context
    //! @param cell Cell [label, value, unit, numeric]
    //! @param x0   Left edge
    //! @param y0   Top edge
    //! @param w    Width
    //! @param h    Height
    private function drawCell(dc as Graphics.Dc, cell as Array, x0 as Number, y0 as Number,
            w as Number, h as Number) as Void {
        dc.setClip(x0, y0, w, h);

        // ---- Header ----
        var lFont = labelFont(h);
        var labelH = dc.getFontHeight(lFont);
        dc.drawText(x0 + w / 2, y0 + 1, lFont, cell[C_LABEL] as String, Graphics.TEXT_JUSTIFY_CENTER);

        // ---- Value ----
        var value = cell[C_VALUE] as String;
        var unit = cell[C_UNIT] as String;
        var uFont = unitFont(h);
        var unitW = (unit.length() > 0) ? dc.getTextWidthInPixels(" " + unit, uFont) : 0;
        var font = fitValue(dc, cell, w, h)[0] as Graphics.FontType;
        var valueW = dc.getTextWidthInPixels(value, font);
        var x = x0 + (w - valueW - unitW) / 2;
        var top = y0 + labelH + 1;
        var cy = top + (y0 + h - top) / 2;
        dc.drawText(x, cy, font, value, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        if (unitW > 0) {
            // Unit vertically centred on the number, directly beside it.
            dc.drawText(x + valueW, cy, uFont, " " + unit,
                Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        dc.clearClip();
    }

    // ---------------------------------------------------------------------
    // Cell contents
    // ---------------------------------------------------------------------

    //! @param label Header
    //! @param text  Value text
    //! @return Text (non-numeric) cell with no unit
    private function statusCell(label as String, text as String) as Array {
        return [label, text, "", false];
    }

    //! Prepares the value for one sensor (the caller sets its name).
    //! @param reading [tempC, humidity, hPa, timerMs] or null if not heard yet
    //! @param show    RuuviConfig.SHOW_* value
    //! @param scanner Scanner (for the status text)
    //! @param now     System.getTimer()
    //! @return Cell [label, value, unit, numeric] with an empty label
    private function formatReading(reading as Array?, show as Number, scanner as RuuviScanner,
            now as Number) as Array {
        if (reading == null) {
            return statusCell("", "SCAN " + scanner.getStatus());
        }
        var age = now - (reading[3] as Number);
        if (age > LOST_DATA_MS) {
            return statusCell("", "---");
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
            return ["", h.format("%.0f"), "%RH" + mark, true];
        } else if (show == RuuviConfig.SHOW_PRESSURE) {
            return ["", presText, presSuffix + mark, true];
        } else if (show == RuuviConfig.SHOW_ALL) {
            return statusCell("", "T:" + tempText + " H:" + h.format("%.0f") + " P:" + presText + mark);
        }
        return ["", tempText, tempUnit + mark, true];
    }
}
