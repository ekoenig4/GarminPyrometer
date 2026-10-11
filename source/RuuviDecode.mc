//
// RuuviDecode.mc
//
// Ruuvi broadcast decoding, kept free of BLE objects so the unit tests
// (RuuviDecodeTests.mc) can feed it raw bytes:
//
//   * manufacturerData() finds the Ruuvi manufacturer data (company 0x0499)
//     in raw advertising data.
//   * decodeFormat5() decodes data format 5 (RAWv2):
//       [0] 0x05  [1-2] temp int16 x0.005 C  [3-4] humidity uint16 x0.0025 %
//       [5-6] pressure uint16 +50000 Pa  [7-12] acceleration
//       [13-14] power info: battery (11 bits, +1600 mV) and tx power (5 bits)
//       [15] movement counter  [16-17] sequence number  [18-23] MAC address
//     https://docs.ruuvi.com/communication/bluetooth-advertisements/data-format-5-rawv2
//
import Toybox.Lang;

module RuuviDecode {

    // Ruuvi manufacturer data: company id 0x0499 (little endian 0x99 0x04).
    const COMPANY_LO = 0x99;
    const COMPANY_HI = 0x04;
    const FORMAT_5   = 0x05;

    // Decoded format 5 fields (see decodeFormat5()).
    const V_TEMP = 0;      // °C (Float)
    const V_HUMIDITY = 1;  // %RH (Float, at most 100)
    const V_PRESSURE = 2;  // hPa (Float)
    const V_MAC = 3;       // 12 upper-case hex digits
    const V_BATTERY = 4;   // volts (Float), or null if not reported

    //! Finds the Ruuvi manufacturer data in raw advertising data, which is a
    //! sequence of [length][type][payload...] structures (type 0xFF =
    //! manufacturer specific, payload starts with the company id).
    //! @param raw Raw advertising bytes (may be null)
    //! @return Bytes after the company id, or null if not a Ruuvi advert
    function manufacturerData(raw as ByteArray?) as ByteArray? {
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
                    && raw[i + 2] == COMPANY_LO && raw[i + 3] == COMPANY_HI) {
                return raw.slice(i + 4, i + 1 + len);
            }
            i += len + 1;
        }
        return null;
    }

    //! Decodes a data format 5 payload (the bytes after the company id).
    //! @param data Manufacturer data (may be null)
    //! @return [tempC, humidityPct, pressureHpa, macHex, batteryVolts?]
    //!         (indexes V_*), or null if this is not a valid format 5
    //!         broadcast or temperature, humidity or pressure is unavailable
    function decodeFormat5(data as ByteArray?) as Array? {
        if (data == null || data.size() < 24 || data[0] != FORMAT_5) {
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

        // Upper 11 bits of the power info; all ones = not available.
        var b = ((data[13] << 8) | data[14]) >> 5;
        var volts = (b == 0x7FF) ? null : (b + 1600) / 1000.0;

        return [t * 0.005, hum, (p + 50000) / 100.0, mac, volts];
    }

    //! Ruuvi Station's low-battery rule: the threshold drops in the cold,
    //! where a healthy coin cell sags.
    //! @param volts Battery voltage
    //! @param tempC Temperature reported by the same tag
    //! @return true if the battery should be replaced
    function isLowBattery(volts as Float, tempC as Float) as Boolean {
        if (tempC <= -20.0) {
            return volts < 2.0;
        }
        if (tempC < 0.0) {
            return volts < 2.3;
        }
        return volts < 2.5;
    }
}
