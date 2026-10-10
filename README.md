# EnvSensor BLE — Garmin Connect IQ data field

A `SimpleDataField` for the Garmin Montana 700 series (`montana7xx`, Connect IQ
API 3.2.0+) that connects to up to three BLE environmental sensors and shows
temperature, relative humidity and barometric pressure, for example:

```
Balloon 1 | T:23.5 H:61 P:1013
```

## Layout

| File | Purpose |
| --- | --- |
| `manifest.xml` | App id, `datafield` type, `montana7xx`, `BluetoothLowEnergy` permission |
| `monkey.jungle` | Build file |
| `source/EnvSensorApp.mc` | Entry point; reads settings, applies them live in `onSettingsChanged()` |
| `source/EnvSensorView.mc` | `SimpleDataField` view; rotates through devices every 3 s |
| `source/EnvSensorBleDelegate.mc` | Scanning, pairing, notification setup, parsing, per-device state |
| `resources/properties/properties.xml` | Default setting values |
| `resources/settings/settings.xml` | Settings panel in Garmin Connect / Express |
| `resources/strings/strings.xml` | App name and settings labels |

## Settings

| Property | Meaning |
| --- | --- |
| `Device1BleId` … `Device3BleId` | Advertised BLE name to match (case-insensitive). Blank disables the slot. |
| `Device1DisplayName` … `Device3DisplayName` | Label shown on screen. |
| `CustomServiceUuid` | Optional service UUID; blank = Nordic UART `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`. |
| `CustomCharUuid` | Optional data characteristic UUID; blank = Nordic UART TX `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`. |

Invalid UUIDs fall back to the Nordic defaults. Changes take effect immediately.

## Sensor protocol

The sensor sends notifications on the data characteristic containing an ASCII
string `"<temperature>,<humidity>,<pressure>"` (°C, %RH, hPa), e.g.
`"23.5,61,1013"`. Trailing CR/LF/NUL bytes are ignored. Keep each message within
one notification (20 bytes at the default MTU). Packets that are malformed,
non-numeric or out of range are dropped and the last good values are kept.

## Display states

| Text | Meaning |
| --- | --- |
| `SCAN` | Searching for / pairing with the device |
| `---` | Device was connected and the link dropped; reconnecting |
| `WAIT` | Connected, no data yet |
| `T:… H:… P:…?` | Latest readings; `?` means no new data for 30 s |
| `NO SENSORS` | No device BLE name configured |
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
monkeyc -d montana7xx -f monkey.jungle -o bin/EnvSensor.prg -y <developer_key>
```
