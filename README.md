# RuuviSensor — Garmin Connect IQ data field

A `SimpleDataField` for the Garmin Montana 700 series (`montana7xx`, Connect IQ
API 3.2.0+) that connects to up to three BLE environmental sensors and shows
temperature, relative humidity and barometric pressure. The field's header is
the device's display name; the value is the quantity chosen in its **Show**
setting:

| Show | Header | Value |
| --- | --- | --- |
| All | `Balloon 1` | `T:23.5 H:61 P:1013` |
| Temperature | `Balloon 1` | `23.5°C` |
| Humidity | `Balloon 1` | `61%RH` |
| Pressure | `Balloon 1` | `1013 hPa` |

## Layout

| File | Purpose |
| --- | --- |
| `manifest.xml` | App id, `datafield` type, `montana7xx`, `BluetoothLowEnergy` permission |
| `monkey.jungle` | Build file |
| `source/EnvSensorApp.mc` | Entry point; reads settings, applies them live in `onSettingsChanged()` |
| `source/EnvSensorView.mc` | `SimpleDataField` view; rotates through devices every 3 s |
| `source/EnvSensorSettings.mc` | On-device settings menu (needed for USB installs) |
| `source/EnvSensorBleDelegate.mc` | Scanning, pairing, notification setup, parsing, per-device state |
| `resources/properties/properties.xml` | Default setting values |
| `resources/settings/settings.xml` | Settings panel in Garmin Connect / Express |
| `resources/strings/strings.xml` | App name and settings labels |

## Settings

### On the device (USB / side-loaded installs)

Garmin Connect only shows app settings for store installs. For a side-loaded
`.prg`, open the device's Connect IQ / data field menu, select **RuuviSensor →
Settings**, then for each device:

- **Choose sensor** — lists nearby BLE devices by name, signal strength and
  how long ago they were heard. The menu itself does not use Bluetooth: the
  running data field saves what it hears every 10 s, so show the data field
  near your sensors for a little while first. Devices advertising the
  configured service UUID are marked `sensor`; *(unnamed sensor)* selects
  auto connect.
- **Auto connect** — stores `*`: connect to any sensor advertising the service
  UUID (Nordic UART by default). This is the default for Device 1.
- **Show** — which quantity the field displays: All, Temperature, Humidity
  or Pressure.
- **Rename** — sets the display name shown as the field's header (needs an
  on-screen keyboard).
- **Turn off** — disables the slot.

Below the devices, **Temperature unit** (Device setting / °C / °F) and
**Pressure unit** (hPa / inHg / mmHg) apply to every device. *Device setting*
follows the Montana's own unit setting.

**Known Montana issue:** after the on-device settings menu closes, the
firmware does not restart the data field: it shows the app icon, and the
settings menu will not open again. Re-add the data field (pick
RuuviSensor for that field again) or restart the Montana. The app never
gets control at that point, so this cannot be fixed in app code; set
Device 1 to *Auto connect* once and the field finds the sensor by itself on
every start, or install from the Connect IQ store (beta is fine) and
configure from Garmin Connect, which updates the running field without
this problem.

### Garmin Connect (store installs)

| Property | Meaning |
| --- | --- |
| `Device1BleId` … `Device3BleId` | Advertised BLE name to match (case-insensitive). `*` = any sensor advertising the service UUID. Blank disables the slot. |
| `Device1DisplayName` … `Device3DisplayName` | Label shown as the field's header. |
| `Device1Show` … `Device3Show` | Quantity shown: 0 = all, 1 = temperature (default), 2 = humidity, 3 = pressure. |
| `TempUnit` | 0 = follow the device's unit setting, 1 = °C, 2 = °F. |
| `PressureUnit` | 0 = hPa, 1 = inHg, 2 = mmHg. |
| `CustomServiceUuid` | Optional service UUID; blank = Nordic UART `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`. |
| `CustomCharUuid` | Optional data characteristic UUID; blank = Nordic UART TX `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`. |

Invalid UUIDs fall back to the Nordic defaults. Changes take effect immediately.

## Sensor protocols

### RuuviTag / Ruuvi firmware (e.g. HOTAIR pyrometer) — no connection

Sensors running Ruuvi firmware broadcast their readings in the advertisement
(manufacturer data, company `0x0499`, data format 5 / RAWv2): temperature
(int16 × 0.005 °C), humidity (uint16 × 0.0025 %), pressure (uint16 + 50000 Pa)
and the tag's MAC address. The data field decodes these broadcasts directly;
nothing is paired or connected, so any number of tags can be read.

A slot is bound to a tag by MAC address. A BLE id matches a tag if it is the
tag's name, its MAC (`EF:1E:4A:22:BB:F3`), or ends in the MAC's last four hex
digits (`HOTAIR BBF3`, `Ruuvi BBF3`). Auto (`*`) binds to the first tag heard.
Ruuvi tags put their name in the scan response, which the Montana does not
receive, so the nearby list shows them as `Ruuvi XXXX`.

### Nordic UART text sensors


The sensor sends notifications on the data characteristic containing an ASCII
string `"<temperature>,<humidity>,<pressure>"` (°C, %RH, hPa), e.g.
`"23.5,61,1013"`. Trailing CR/LF/NUL bytes are ignored. Keep each message within
one notification (20 bytes at the default MTU). Packets that are malformed,
non-numeric or out of range are dropped and the last good values are kept.

## Display states

| Text | Meaning |
| --- | --- |
| `SCAN <status>` | Searching for the device. Status: `5 dev` = named devices heard, `+?` = unnamed adverts heard, `UART` = an advert lists the service UUID, `RUUVI` = a Ruuvi broadcast was heard, `setup` = waiting for the GATT profile (pairing waits for it), `NO PROFILE` = profile registration failed, `PAIR` = match found and pairing, `OFF` = not scanning, `SCAN ERR n` = the system refused to scan, `IDLE` = no scan needed |
| `---` | Device was connected and the link dropped; reconnecting |
| `WAIT` | Connected, no data yet |
| `T:… H:… P:…?` | Latest readings; `?` means no new data for 30 s |
| `NO SENSORS <status>` | No device configured; still scanning (status as for `SCAN`) so the settings menu can list nearby devices |
| `STARTING` | First 3 s after the field starts; Bluetooth is not touched yet |
| `NO BLE` | Product has no Connect IQ BLE support |

## Notes

- Connect IQ has no `registerNotify()` call; notifications are enabled by
  writing `0x0001` to the characteristic's CCCD (`registerNotify()` in the
  delegate wraps this).
- Devices connect concurrently up to `Ble.getAvailableConnectionCount()`. If the
  product allows fewer connections than configured devices, the longest-connected
  device is released every 60 s so the others get a turn.
- Data fields cannot use `Timer.Timer` reliably, so timeouts and reconnects are
  driven from `compute()` (1 Hz).

## Building

```
monkeyc -d montana7xx -f monkey.jungle -o bin/RuuviSensor.prg -y <developer_key>
```
