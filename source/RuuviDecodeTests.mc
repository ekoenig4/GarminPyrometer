//
// RuuviDecodeTests.mc
//
// Unit tests for RuuviDecode, using the test vectors from Ruuvi's data
// format 5 specification (valid, maximum, minimum and invalid values).
// Tests are only compiled into test builds (monkeyc -t; see README
// "Testing"). Helpers are (:debug), not (:test), so the test runner does not
// call them as tests; release builds (-r) leave them out.
//
import Toybox.Lang;
import Toybox.Test;

// Ruuvi's data format 5 test vectors (bytes after the company id). Functions
// rather than constants so each test gets its own copy to modify.
(:debug)
function validF5() as ByteArray {
    return [0x05, 0x12, 0xFC, 0x53, 0x94, 0xC3, 0x7C, 0x00, 0x04, 0xFF, 0xFC, 0x04,
        0x0C, 0xAC, 0x36, 0x42, 0x00, 0xCD, 0xCB, 0xB8, 0x33, 0x4C, 0x88, 0x4F]b;
}
(:debug)
function maxF5() as ByteArray {
    return [0x05, 0x7F, 0xFF, 0xFF, 0xFE, 0xFF, 0xFE, 0x7F, 0xFF, 0x7F, 0xFF, 0x7F,
        0xFF, 0xFF, 0xDE, 0xFE, 0xFF, 0xFE, 0xCB, 0xB8, 0x33, 0x4C, 0x88, 0x4F]b;
}
(:debug)
function minF5() as ByteArray {
    return [0x05, 0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x80, 0x01, 0x80, 0x01, 0x80,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xCB, 0xB8, 0x33, 0x4C, 0x88, 0x4F]b;
}
(:debug)
function invalidF5() as ByteArray {
    return [0x05, 0x80, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x80, 0x00, 0x80, 0x00, 0x80,
        0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]b;
}

//! @return true if a and b differ by less than eps
(:debug)
function near(a as Float, b as Float, eps as Float) as Boolean {
    var d = a - b;
    return d < eps && d > -eps;
}

//! @return true if a holds the same bytes as b
(:debug)
function sameBytes(a as ByteArray?, b as ByteArray) as Boolean {
    if (a == null || a.size() != b.size()) {
        return false;
    }
    for (var i = 0; i < b.size(); i++) {
        if (a[i] != b[i]) {
            return false;
        }
    }
    return true;
}

//! Checks a decoded reading against expected values.
(:debug)
function checkReading(vals as Array?, tempC as Float, hum as Float,
        hpa as Float, mac as String) as Boolean {
    if (vals == null) {
        return false;
    }
    return near(vals[RuuviDecode.V_TEMP] as Float, tempC, 0.001)
        && near(vals[RuuviDecode.V_HUMIDITY] as Float, hum, 0.001)
        && near(vals[RuuviDecode.V_PRESSURE] as Float, hpa, 0.001)
        && mac.equals(vals[RuuviDecode.V_MAC]);
}

(:test)
function decodesValidFormat5(logger as Logger) as Boolean {
    return checkReading(RuuviDecode.decodeFormat5(validF5()),
        24.3, 53.49, 1000.44, "CBB8334C884F");
}

(:test)
function decodesMaximumFormat5(logger as Logger) as Boolean {
    // Humidity 163.835 % is clamped to 100 %.
    return checkReading(RuuviDecode.decodeFormat5(maxF5()),
        163.835, 100.0, 1155.34, "CBB8334C884F");
}

(:test)
function decodesMinimumFormat5(logger as Logger) as Boolean {
    return checkReading(RuuviDecode.decodeFormat5(minF5()),
        -163.835, 0.0, 500.0, "CBB8334C884F");
}

(:test)
function rejectsInvalidFormat5(logger as Logger) as Boolean {
    return RuuviDecode.decodeFormat5(invalidF5()) == null;
}

(:test)
function rejectsOtherFormatsAndShortData(logger as Logger) as Boolean {
    var format3 = validF5();
    format3[0] = 0x03;
    return RuuviDecode.decodeFormat5(format3) == null
        && RuuviDecode.decodeFormat5(validF5().slice(0, 23)) == null
        && RuuviDecode.decodeFormat5(null) == null;
}

(:test)
function findsRuuviManufacturerData(logger as Logger) as Boolean {
    // Flags, then manufacturer data (length 27: type, company id, 24 bytes).
    var raw = [0x02, 0x01, 0x06, 0x1B, 0xFF, 0x99, 0x04]b.addAll(validF5());
    var data = RuuviDecode.manufacturerData(raw);
    return sameBytes(data, validF5());
}

(:test)
function ignoresNonRuuviAdverts(logger as Logger) as Boolean {
    // Same layout with another company id (0x004C).
    var other = [0x02, 0x01, 0x06, 0x1B, 0xFF, 0x4C, 0x00]b.addAll(validF5());
    // Manufacturer data claiming more bytes than were received.
    var truncated = [0x02, 0x01, 0x06, 0x1B, 0xFF, 0x99, 0x04]b.addAll(validF5().slice(0, 20));
    return RuuviDecode.manufacturerData(other) == null
        && RuuviDecode.manufacturerData(truncated) == null
        && RuuviDecode.manufacturerData(null) == null
        && RuuviDecode.manufacturerData(new [0]b) == null;
}

