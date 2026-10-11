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

The field shows the sensor chosen under **Display** in the settings menu, or
cycles through all of them every 3 seconds with **Rotate all** (the default).

## Layout

| File | Purpose |
| --- | --- |
| `manifest.xml` | App id, `datafield` type, `montana7xx`, `BluetoothLowEnergy` permission |
| `monkey.jungle` | Build file |
| `source/RuuviSensorApp.mc` | Entry point; starts BLE (data field mode only), caches units |
| `source/RuuviSensorView.mc` | Data field view, drawn like the native fields |
| `source/RuuviScanner.mc` | BLE scanning and Ruuvi data format 5 decoding |
| `source/RuuviSettings.mc` | On-device settings menu (sensor list, units) |
| `source/RuuviConfig.mc` | Sensor list storage, units, helpers |
| `resources/properties/properties.xml` | Unit settings |
| `resources/settings/settings.xml` | Unit settings panel in Garmin Connect / Express |
| `resources/strings/strings.xml` | App name and settings labels |

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
   - **Rename** — the name shown as the field's header.
   - **Remove** — delete it from the list.
5. Back in the main menu, **Display** picks the sensor the field shows
   (or **Rotate all**). The choice is saved, so the field keeps showing that
   sensor every time it starts. Removing the displayed sensor falls back to
   Rotate all.
6. **Temperature unit** (Device setting / °C / °F) and
   **Pressure unit** (hPa / inHg / mmHg) apply to every sensor. *Device
   setting* follows the Montana's own unit setting.

On the Montana touchscreen the title-bar back arrow needs two taps (the first
only highlights it).

**Known Montana issue:** after the on-device settings menu closes, the
firmware does not restart the data field: it shows the app icon, and the
settings menu will not open again. Re-add the data field (pick RuuviSensor
for that field again) or restart the Montana. The app never gets control at
that point, so this cannot be fixed in app code.

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
| `---` | No broadcast from that sensor for 60 s |
| `SCAN 2 found` | Sensor not heard yet; 2 Ruuvi tags heard in the last 30 s |
| `SCAN OFF` / `SCAN ERR n` | Not scanning (retrying) / the system refused to scan |
| `NO SENSORS …` | The sensor list is empty (status as above) |
| `STARTING` | First 3 s after the field starts; Bluetooth is not touched yet |
| `NO BLE` | Product has no Connect IQ BLE support |

## Building

```
monkeyc -d montana7xx -f monkey.jungle -o bin/RuuviSensor.prg -y <developer_key>
```

monkeyc 9.2 names string constants from their letters/digits plus Java
`hashCode()`, so two punctuation-only literals with the same hash (e.g. `", "`
and `"+?"`) abort the build with "Redefinition of label". Avoid
punctuation-only string literals.
