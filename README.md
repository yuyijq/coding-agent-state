| Supported Targets | ESP32 | ESP32-C2 | ESP32-C3 | ESP32-C5 | ESP32-C6 | ESP32-C61 | ESP32-H2 | ESP32-S3 |
| ----------------- | ----- | -------- | -------- | -------- | -------- | --------- | -------- | -------- |

# NimBLE LED GATT Server

## Overview

This ESP-IDF project runs a NimBLE GATT server that exposes BLE-controlled red, yellow, and green LEDs.

The device advertises as `NimBLE_GATT`. After a central device connects, it can write to a custom LED characteristic under the Automation IO service:

- Service UUID: `0x1815`
- LED characteristic UUID: `00001525-1212-efde-1523-785feabcd123`
- Access: write
- Payload: one byte
  - `0x00`: turn all LEDs off
  - `0x01`: turn the red LED on
  - `0x02`: turn the yellow LED on
  - `0x03`: turn the green LED on

You can test it with *nRF Connect for Mobile* or another BLE GATT client.

## Try It Yourself

### Set Target

Before project configuration and build, set the correct chip target:

```shell
idf.py set-target <chip_name>
```

For example:

```shell
idf.py set-target esp32s3
```

### Build and Flash

Run the following command to build, flash, and monitor the project:

```shell
idf.py -p <PORT> flash monitor
```

For example:

```shell
idf.py -p /dev/ttyACM0 flash monitor
```

To exit the serial monitor, type `Ctrl-]`.

## Code Structure

- `main/main.c`: initializes LED, NVS, NimBLE, GAP, GATT, then starts the NimBLE host task.
- `main/src/gap.c`: configures the BLE device name, advertising data, connection handling, and advertising restart after disconnect.
- `main/src/gatt_svc.c`: registers the Automation IO service and handles LED characteristic writes.
- `main/src/led.c`: controls the red, yellow, and green LEDs through hard-coded GPIO outputs.

## LED Pins

The LED pins are hard-coded in `main/include/led.h`:

```text
Red: GPIO 7
Yellow: GPIO 8
Green: GPIO 9
```
