# Cache-Backed Sleep Window Design

## Goal

Make the ESP32 deep sleep window configurable from the client during time sync, while keeping the default window at `23:00-09:00` when no cached client setting exists.

## Protocol

The time characteristic accepts one fixed 6-byte payload:

- Bytes `0..3`: Unix timestamp seconds as an unsigned 32-bit little-endian integer.
- Byte `4`: `startHour`, valid range `0..23`.
- Byte `5`: `endHour`, valid range `0..23`.

`startHour == endHour` is invalid because it would represent an ambiguous all-day or never-sleep window. Windows may cross midnight, for example `23 7`.

## Firmware Behavior

The firmware stores the active sleep window in RAM with a default of `23-9`. Each valid time sync updates system time, updates the active sleep window from the payload, and recalculates the deep sleep schedule. The schedule logic supports both same-day windows such as `9-18` and cross-midnight windows such as `23-7`.

## Client Behavior

The CoreBluetooth cache stores `sleepStartHour` and `sleepEndHour` per device. If either value is missing or invalid, the client uses the default `23-9`.

`sync-time` sends the current timestamp plus the cached sleep window. Normal LED writes that append automatic time sync also include the cached sleep window. `update-sleep-time <startHour> <endHour>` validates the two hours, updates the cache, and immediately sends one time sync payload with that window.

## Tests

Swift support tests cover 6-byte payload creation, cached/default sleep window selection, and cache round-trip. Firmware regression tests assert that the C code exposes the 6-byte payload contract and cross-midnight scheduling branches. Python client tests are updated to match the 4-byte timestamp plus two-hour payload shape.
