# TODO

Improvements found by comparing this data field with
[zmullett/connectiq-ruuvitag](https://github.com/zmullett/connectiq-ruuvitag),
highest priority first. Check items off as they land.

- [x] **1. Unit tests for the Ruuvi decoder.** Decoding lives in plain
  functions (`source/RuuviDecode.mc`) with `(:test)` cases built from Ruuvi's
  official data format 5 test vectors (`source/RuuviDecodeTests.mc`).
- [x] **2. Fake sensors in the simulator.** A `sim.jungle` build replaces
  BLE with made-up tags fed through the same decoding path
  (`source/RuuviFakeSource.mc`), so every display state can be checked
  without hardware.
- [x] **4. Battery voltage and low-battery warning.** Format 5 battery
  voltage is decoded; a sensor can show **Battery**, and `!` is added to
  the unit when the battery is low.
- [ ] **3. Set up sensors from Garmin Connect.** Optional MAC + name
  settings merged into the list, avoiding the Montana firmware bug where the
  field does not restart after the on-device settings menu closes. Garmin
  Connect only shows settings for store installs, so this helps only once
  the field is published.
- [ ] **5. Use the measurement sequence number for freshness.** Tags repeat
  each packet several times, so the reading age is "last heard", not "last
  new measurement". Track bytes 16–17 so `?` / `---` reflect a sensor that
  stopped measuring.
- [ ] **6. Try `ScanResult.getManufacturerSpecificData(0x0499)`.** Could
  replace `RuuviDecode.manufacturerData()`; only worth it if it behaves the
  same on the Montana.
- [ ] **7. More products.** The view already sizes itself to the field, so
  GPSMAP 66/67, Oregon 7xx etc. are mostly a manifest change, but untested
  without the hardware.

Not planned: data format 3 (no MAC in the payload, so it cannot be locked
to a list entry) and timer-driven refresh (data fields cannot rely on
`Timer.Timer`).
