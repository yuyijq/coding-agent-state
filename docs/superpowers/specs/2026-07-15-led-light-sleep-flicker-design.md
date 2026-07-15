# LED Light-Sleep Flicker Design

## Goal

Reduce LED-related standby power without adding periodic CPU wakeups. Red,
yellow, and green remain persistent logical states, but their physical output
may flicker while automatic Light Sleep disables and restores the GPIOs.

## Chosen approach

Remove the three `gpio_sleep_sel_dis()` calls for GPIO 7, GPIO 8, and GPIO 9
from `led_init()`. Do not add an LED timer, FreeRTOS task, delay loop, PWM
peripheral, or new dependency.

The tracked `sdkconfig.defaults` power-management configuration remains
authoritative:

- `CONFIG_PM_ENABLE=y`
- `CONFIG_PM_SLP_DISABLE_GPIO=y`
- `CONFIG_FREERTOS_USE_TICKLESS_IDLE=y`
- `esp_pm_configure()` keeps automatic Light Sleep enabled

When the CPU is awake, `led_apply_command()` drives the selected GPIO exactly
as it does now. During Light Sleep, ESP-IDF may disable the LED GPIOs; when the
chip wakes for BLE or other work, the active GPIO output returns. The visible
flicker therefore follows real system wake activity and is intentionally not
regular or color-specific.

## Command behavior

- `LED_CMD_RED`, `LED_CMD_YELLOW`, and `LED_CMD_GREEN` continue to select one
  logical color until another BLE command arrives.
- `get_led_state()` continues to report that logical command even while the
  physical LED is unavailable during Light Sleep.
- `LED_CMD_OFF` continues to drive all three active GPIO levels low.
- Entering scheduled Deep Sleep continues to call `LED_CMD_OFF`; Deep Sleep
  scheduling and wake restoration are unchanged.

Urgency is communicated only by color: red is most urgent, yellow is next, and
green is least urgent. Flash rate does not encode urgency.

## Power and Light-Sleep constraints

No new code may periodically wake the CPU. The change must not disable
automatic Light Sleep or Tickless Idle. Allowing ESP-IDF to apply its configured
sleep handling to GPIO 7, GPIO 8, and GPIO 9 is expected to use less power than
holding the LEDs continuously active, but no numerical saving is claimed
without board-level current measurement.

## Verification

Add a narrow source-backed behavior test that fails while the three exclusions
remain and passes only when:

- `led.c` no longer calls `gpio_sleep_sel_dis()`;
- `led.c` contains no timer, task, or delay-based blinking implementation;
- tracked project defaults still enable automatic Light Sleep, Tickless Idle,
  and GPIO disabling during Light Sleep.

Run that regression test, the existing Python regression tests, the ESP-IDF
firmware build, and `git diff --check`. Update the README to state that visible
LED output can flicker according to system wake activity.

## Scope

Expected implementation files:

- `main/src/led.c`
- `sdkconfig.defaults`
- `tests/test_led_light_sleep_flicker.py`
- `README.md`

The pre-existing change in `main/include/common.h` is unrelated and must remain
untouched and uncommitted by this work.
