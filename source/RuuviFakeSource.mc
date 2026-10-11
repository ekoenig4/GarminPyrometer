//
// RuuviFakeSource.mc
//
// Made-up Ruuvi tags for the simulator, which has no RuuviTags to hear.
// Only built with sim.jungle (see README "Simulator"); normal builds
// exclude the (:fakeBle) code and get the (:realBle) createFakeSource(),
// which returns null.
//
// The scanner calls tick() once per second; each call builds real data
// format 5 adverts and passes them to RuuviScanner.processAdvert(), so the
// decoding, nearby list and display all run as they do on the device:
//
//   HOTAIR F001  pyrometer, 80-110 °C, battery OK, named in the advert
//   Ruuvi F002   room tag, ~21 °C, low battery (shows "!")
//   Ruuvi F003   heard 20 s out of every 90 s, so it goes stale ("?") and
//                then lost ("---"); no battery reading
//
// Add them from the settings menu as with real tags.
//
import Toybox.Lang;
import Toybox.Math;

//! @return Fake tag source for simulator builds
(:fakeBle)
function createFakeSource() as RuuviFakeSource? {
    return new RuuviFakeSource();
}

//! @return null: device builds use BLE
(:realBle)
function createFakeSource() as Null {
    return null;
}

(:fakeBle)
class RuuviFakeSource {

    // Measurement sequence number, bumped every tick.
    private var mSeq as Number = 0;

    //! Constructor.
    function initialize() {
    }

    //! Sends one advert from each fake tag that is "in range" this second.
    //! @param scanner Receives the adverts
    //! @param now     System.getTimer()
    function tick(scanner as RuuviScanner, now as Number) as Void {
        mSeq = (mSeq + 1) & 0xFFFF;
        var s = now / 1000;

        scanner.processAdvert(advert(0xF001, 95.0 + 15.0 * Math.sin(s / 20.0), 12.0, 1013.0, 2950),
            "HOTAIR F001", -62, now);
        scanner.processAdvert(advert(0xF002, 21.0 + (s % 10) / 10.0, 45.0, 1009.5, 2350),
            null, -75, now);
        if (s % 90 < 20) {
            scanner.processAdvert(advert(0xF003, -5.5, 80.0, 990.0, -1), null, -88, now);
        }
    }

    //! Builds raw advertising data: flags, then Ruuvi manufacturer data in
    //! data format 5 (see RuuviDecode).
    //! @param id    Last two bytes of the MAC (EF:1E:4A:22:xx:xx)
    //! @param tempC Temperature
    //! @param hum   Humidity (%)
    //! @param hpa   Pressure
    //! @param mv    Battery millivolts, or -1 for "not available"
    //! @return 31 advertising bytes
    private function advert(id as Number, tempC as Numeric, hum as Numeric, hpa as Numeric,
            mv as Number) as ByteArray {
        var t = (tempC / 0.005).toNumber() & 0xFFFF;
        var h = (hum / 0.0025).toNumber();
        var p = (hpa * 100.0).toNumber() - 50000;
        // Battery in the upper 11 bits (0x7FF = not available), tx power
        // +4 dBm ((4 + 40) / 2 = 22) in the lower 5.
        var power = (((mv < 0) ? 0x7FF : (mv - 1600)) << 5) | 22;
        var bytes = [
            0x02, 0x01, 0x06,                      // flags
            0x1B, 0xFF, 0x99, 0x04,                // manufacturer data, Ruuvi
            0x05,                                  // data format 5
            (t >> 8) & 0xFF, t & 0xFF,
            (h >> 8) & 0xFF, h & 0xFF,
            (p >> 8) & 0xFF, p & 0xFF,
            0x00, 0x00, 0x00, 0x00, 0x03, 0xE8,    // acceleration 0, 0, 1000 mG
            (power >> 8) & 0xFF, power & 0xFF,
            0x00,                                  // movement counter
            (mSeq >> 8) & 0xFF, mSeq & 0xFF,
            0xEF, 0x1E, 0x4A, 0x22, (id >> 8) & 0xFF, id & 0xFF
        ];
        var raw = new [bytes.size()]b;
        for (var i = 0; i < bytes.size(); i++) {
            raw[i] = bytes[i];
        }
        return raw;
    }
}
