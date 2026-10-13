# RuuviSensor — Garmin Connect IQ data field

A Connect IQ data field for the Garmin Montana 700 series (`montana7xx`,
Connect IQ API 3.2.0+) that shows temperature, humidity or pressure from
RuuviTags and Ruuvi-firmware sensors (such as the HOTAIR pyrometer).

Ruuvi sensors broadcast their readings in every advertisement, so nothing is
paired or connected: the field listens for broadcasts and decodes them. You
keep a list of up to 8 sensors, each locked to its tag's MAC address, with
its own name and choice of what to show.

| Show | Header | Value |
| --- | --- | --- |
| Temperature (default) | `Balloon 1` | `23.5 °C` |
| Humidity | `Balloon 1` | `61 %RH` |
| Pressure | `Balloon 1` | `1013 hPa` |
| All | `Balloon 1` | `T:23.5 H:61 P:1013` |

The field shows the sensors switched on under **Display** in the settings
menu side by side, each with its own header and value:

```
+------------+------------+------------+
| Balloon 1  | Burner     | Envelope   |
|  23.5 °C   |  412.0 °C  |   43 %RH   |
+------------+------------+------------+
```

The cells are arranged in the grid that gives the largest readable value in
the data field slot. A grid with no empty cells (e.g. 3 across) is preferred
when its font is at least 80% as large as the best grid's, so put the field in
a wide slot for a single row. Readings use the device's number fonts, like the
native fields.

The temperature of every listed sensor is also logged to the activity's FIT
file (see [Activity logging](#activity-logging-fit)).

## Layout

| File | Purpose |
| --- | --- |
| `manifest.xml` | App id, `datafield` type, `montana7xx`, `BluetoothLowEnergy` and `FitContributor` permissions |
| `monkey.jungle` | Build file |
| `source/RuuviSensorApp.mc` | Entry point; starts BLE (data field mode only), caches units |
| `source/RuuviSensorView.mc` | Data field view (sensors side by side) and FIT logging |
| `source/RuuviScanner.mc` | BLE scanning and Ruuvi data format 5 decoding |
| `source/RuuviSettings.mc` | On-device settings menu (sensor list, units) |
| `source/RuuviConfig.mc` | Sensor list storage, units, helpers |
| `source/test/RuuviConfigTest.mc` | Unit tests for the sensor list and helpers |
| `resources/properties/properties.xml` | Unit settings |
| `resources/settings/settings.xml` | Unit settings panel in Garmin Connect / Express |
| `resources/strings/strings.xml` | App name, settings and FIT labels |
| `resources/fit/fit.xml` | FIT field descriptions for Garmin Connect charts |

## Setting up sensors (on the device)

1. Add the RuuviSensor data field to an activity page and let it run near
   your sensors for ~20 seconds (it shows `NO SENSORS 2 found` while the list
   is empty). The field saves the tags it hears for the settings menu.
2. Open the device's Connect IQ data field menu → **RuuviSensor → Settings**.
3. Open **Sensors**. **+ Add sensor** (at the top) lists the tags heard
   recently (name, signal strength, how long ago), excluding ones already
   added. Tap one to add it. Tags whose name is not received are listed as
   `Ruuvi XXXX` (last 4 hex digits of the MAC).
4. Your sensors are listed below **+ Add sensor**. Tap one for:
   - **Show** — Temperature, Humidity, Pressure or All.
   - **Rename** — the name shown as the sensor's header (and its FIT field
     name).
   - **Remove** — delete it from the list.
5. Back in the main menu, **Display** has an on/off switch per sensor:
   the field shows the switched-on sensors side by side, in list order. New
   sensors are on. Hidden sensors are still logged.
6. **Temperature unit** (Device setting / °C / °F) and
   **Pressure unit** (hPa / inHg / mmHg) apply to every sensor. *Device
   setting* follows the Montana's own unit setting.

On the Montana touchscreen the title-bar back arrow needs two taps (the first
only highlights it).

**Known Montana issue:** after the on-device settings menu closes, the
data field may show the app icon instead of data, and the settings menu may
not open again. Re-add the data field (pick RuuviSensor for that field again)
or restart the Montana. The cause is not known yet; see below.

### Tracing the settings lifecycle on the Montana

Create an empty `GARMIN/APPS/LOGS/RUUVISENSOR.TXT` (same base name as the
`.prg`) on the Montana. The app then logs each lifecycle step, stamped with
`System.getTimer()` and the id of the app instance (its creation time):

```
RuuviSensor 292628921: new app instance 292628921
RuuviSensor 292628921: onStart, instance 292628921
RuuviSensor 292628921: getInitialView, instance 292628921
RuuviSensor 292628937: view created
RuuviSensor 292628937: view onShow
RuuviSensor 292635890: getSettingsView, instance 292628921
RuuviSensor 292635921: view onHide
RuuviSensor 292645312: settings main menu onBack
RuuviSensor 292645312: view onShow
```

That excerpt is the Connect IQ simulator (SDK 9.2, montana7xx): the settings
menu runs in the same app instance as the data field, one back press closes
it, and there is no `onStop`, `onSettingsChanged` or new `getInitialView`.
Draw and BLE errors are logged too, and `GARMIN/APPS/LOGS/CIQ_LOG.YML`
records crashes.

In the simulator, use **Settings → Trigger App Settings** to open the menu.
After the menu closes, the simulator ignores that command until
**Settings → Timeout App Settings** is used. Garmin's SimpleDataField sample
behaves the same way, so this is a simulator quirk, not this app.

## Ruuvi data format 5

Manufacturer data (company `0x0499`) after the company id:

| Bytes | Field |
| --- | --- |
| 0 | format (`0x05`) |
| 1–2 | temperature, int16 × 0.005 °C |
| 3–4 | humidity, uint16 × 0.0025 % |
| 5–6 | pressure, uint16 + 50000 Pa |
| 18–23 | MAC address |

`0x8000` / `0xFFFF` mark unavailable values; such broadcasts are ignored.

## Display states

| Value | Meaning |
| --- | --- |
| reading | Latest broadcast; `?` after the unit when older than 30 s |
| `---` | No broadcast from that sensor for 60 s (see [Update rate](#update-rate-and-scan-watchdog)) |
| `SCAN 2 found` | Sensor not heard yet; 2 Ruuvi tags heard in the last 30 s |
| `SCAN OFF` / `SCAN ERR n` | Not scanning (retrying) / the system refused to scan |
| `NO SENSORS …` | The sensor list is empty (status as above) |
| `NONE SHOWN` | Every sensor is switched off under **Display** |
| `STARTING` | First 3 s after the field starts; Bluetooth is not touched yet |
| `NO BLE` | Product has no Connect IQ BLE support |

## Update rate and scan watchdog

The field redraws once per second (the firmware's data field rate), and a
RuuviTag broadcasts about every 1.3 s, so a reading on screen is normally at
most 1–2 s old. Readings come only from BLE scan results, so the scanner
keeps the scan alive:

- If the system reports the scan off, it is requested again after 2 s.
- **Watchdog:** if no listed sensor has been heard for 6 s, the scan is
  switched off and back on a second later, in case the system stopped
  delivering results without saying so. While still nothing is heard, the
  next restarts wait 10 s, 20 s, then every 30 s, so tags that are simply out
  of range do not keep the scan restarting.

With the lifecycle log enabled (below), the scanner also logs what it sees,
which shows whether a `---` came from the scan or from the tag. An
illustrative example (made-up numbers):

```
RuuviSensor 294971796: scan state on status 0
RuuviSensor 294975102: Balloon 1 first heard
RuuviSensor 295001781: scan on adverts 412 ruuvi 46 listed 23 in 30 s, restarts 0, last listed 0 s ago
RuuviSensor 295030113: scan restart, no listed sensor heard for 6 s (restart 1 in a row)
RuuviSensor 295030140: scan state off status 0
RuuviSensor 295031120: scan state on status 0
RuuviSensor 295031544: Balloon 1 heard again after 7 s
```

- `adverts` / `ruuvi` / `listed`: BLE broadcasts of any device, Ruuvi format
  5 broadcasts, and broadcasts from listed sensors in the last 30 s. Adverts
  dropping to 0 means the scan itself stopped; adverts continuing while
  `listed` is 0 means the tags are not being heard (range, battery).
- `heard again after N s`: a sensor came back after a gap of 10 s or more.
  If this regularly follows a `scan restart`, the restart is what brings
  data back.

## Activity logging (FIT)

While an activity records, the field writes each listed sensor's temperature
to the FIT file every record, next to the Montana's own data (the
`FitContributor` developer fields). Details:

- One field per sensor in the list when the data field starts (up to 8),
  shown or not. Field ids 0–7 follow the list order, and each field is named
  after its sensor in the FIT file (first 16 characters). Garmin Connect
  labels them "Sensor 1 temperature" … "Sensor 8 temperature".
- Always °C, whatever the display unit, with one decimal.
- When a sensor has not been heard for 60 s (the field shows `---`), FIT's
  invalid value is written, so charts show a gap rather than a stale value.
- Sensors added during an activity are logged from the next time the data
  field starts (the next activity, or re-adding the field).
- Garmin Connect generally only charts Connect IQ developer fields for apps
  installed from the Connect IQ store. With a sideloaded `.prg`, the data is
  still in the FIT file (`GARMIN/Activities` on the Montana) and readable by
  FIT tools.

## Building

```
monkeyc -d montana7xx -f monkey.jungle -o bin/RuuviSensor.prg -y <developer_key>
```

monkeyc 9.2 names string constants from their letters/digits plus Java
`hashCode()`, so two punctuation-only literals with the same hash (e.g. `", "`
and `"+?"`) abort the build with "Redefinition of label". Avoid
punctuation-only string literals.

## Unit tests

`(:test)` code is left out of normal builds (the device `.prg` is identical
with or without it). To run the tests in the simulator (Windows: run
`monkeydo` from PowerShell or cmd; Git Bash rewrites `/t` into a path):

```
monkeyc -d montana7xx -f monkey.jungle -o bin/RuuviSensorTest.prg -y <developer_key> --unit-test
monkeydo bin/RuuviSensorTest.prg montana7xx /t
```

The tests use the app's Application.Storage and restore the sensor list and
displayed sensor after each test.
