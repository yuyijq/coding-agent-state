# Cache-Backed Sleep Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add cache-backed, client-provided deep sleep windows to time sync using a fixed 6-byte BLE payload.

**Architecture:** Extend the existing time characteristic instead of adding a new GATT characteristic. The client owns persisted sleep-window configuration and sends it with every time sync; the firmware treats the payload as the current schedule authority.

**Tech Stack:** ESP-IDF C firmware, Swift CoreBluetooth CLI and XCTest, Python Bleak compatibility client and unittest.

## Global Constraints

- Time sync payload is exactly 6 bytes: 4-byte unsigned little-endian Unix timestamp, 1-byte start hour, 1-byte end hour.
- Valid hours are `0..23`; `startHour == endHour` is invalid.
- Default sleep window is `23-9` when client cache has no valid window.
- Do not overwrite the existing local `main/include/common.h` device-name change.

---

### Task 1: Swift Payload and Cache Support

**Files:**
- Modify: `corebluetooth-client/Sources/CoreBluetoothSupport/CoreBluetoothSupport.swift`
- Modify: `corebluetooth-client/Tests/CoreBluetoothSupportTests/CoreBluetoothSupportTests.swift`

**Interfaces:**
- Produces: `SleepWindow`, `defaultSleepWindow(for:)`, `buildTimeSyncPayload(unixTimeSeconds:sleepWindow:)`, `DeviceCache.sleepWindow(for:)`, `DeviceCache.setSleepWindow(_:for:)`.

- [ ] **Step 1: Write failing Swift tests** for 6-byte payloads, default/cached sleep windows, and cache round-trip.
- [ ] **Step 2: Run** `cd corebluetooth-client && swift test` and confirm the new tests fail because the API does not exist.
- [ ] **Step 3: Implement minimal support code** in `CoreBluetoothSupport.swift`.
- [ ] **Step 4: Run** `cd corebluetooth-client && swift test` and confirm the support tests pass.

### Task 2: Swift CLI Command and Write Path

**Files:**
- Modify: `corebluetooth-client/Sources/ESP32BLECoreBluetooth/main.swift`
- Modify: `corebluetooth-client/README.md`

**Interfaces:**
- Consumes: `SleepWindow`, `buildTimeSyncPayload`, cache sleep-window helpers.
- Produces: `update-sleep-time <startHour> <endHour>` CLI behavior.

- [ ] **Step 1: Add tests indirectly through support helpers** where possible; the CLI file is executable-only, so parser behavior is verified by building and manual command help output.
- [ ] **Step 2: Implement `update-sleep-time` parsing** with two integer hour arguments.
- [ ] **Step 3: Make `sync-time` and automatic time sync use `buildTimeSyncPayload` with cached/default sleep windows.**
- [ ] **Step 4: Build with** `cd corebluetooth-client && swift build -c release`.

### Task 3: Firmware Time Payload and Scheduling

**Files:**
- Modify: `main/include/sleep_manager.h`
- Modify: `main/src/sleep_manager.c`
- Modify: `main/src/gatt_svc.c`
- Modify: `tests/test_sleep_manager_wakeup.py`

**Interfaces:**
- Produces: `sleep_manager_update_time(uint32_t unix_time_seconds, uint8_t sleep_start_hour, uint8_t sleep_end_hour)`.

- [ ] **Step 1: Add failing firmware regression assertions** for the 6-byte payload length, the new function signature, and cross-midnight scheduling.
- [ ] **Step 2: Run** `python3 tests/test_sleep_manager_wakeup.py` and confirm it fails before firmware changes.
- [ ] **Step 3: Update GATT parsing** to require exactly 6 bytes and call the new sleep manager signature.
- [ ] **Step 4: Update sleep scheduling** to use runtime start/end hours and handle cross-midnight windows.
- [ ] **Step 5: Run** `python3 tests/test_sleep_manager_wakeup.py`.

### Task 4: Python Client Alignment

**Files:**
- Modify: `ble_py_client/esp32_ble_client.py`
- Modify: `ble_py_client/tests/test_esp32_ble_scan_helpers.py`

**Interfaces:**
- Produces: Python `build_time_sync_payload(unix_time_seconds=None, sleep_start_hour=0, sleep_end_hour=8)`.

- [ ] **Step 1: Update Python tests** to expect the 6-byte payload.
- [ ] **Step 2: Run** `python3 -m unittest discover -s ble_py_client/tests` and confirm the payload test fails.
- [ ] **Step 3: Implement Python payload helper and use it for `sync-time`.**
- [ ] **Step 4: Run** `python3 -m unittest discover -s ble_py_client/tests`.

### Task 5: Full Verification

**Files:**
- Verify all changed source and docs.

- [ ] **Step 1: Run** `cd corebluetooth-client && swift test`.
- [ ] **Step 2: Run** `cd corebluetooth-client && swift build -c release`.
- [ ] **Step 3: Run** `python3 -m unittest discover -s ble_py_client/tests`.
- [ ] **Step 4: Run** `python3 tests/test_sleep_manager_wakeup.py`.
- [ ] **Step 5: Run** `git diff --check`.
