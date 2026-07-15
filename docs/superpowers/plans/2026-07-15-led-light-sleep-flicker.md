# LED Light-Sleep Flicker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let automatic Light Sleep disable GPIO 7, GPIO 8, and GPIO 9 so the selected LED may flicker with existing system wake activity, without adding periodic wakeups.

**Architecture:** Keep the existing logical LED command path unchanged and remove only the three per-pin Light Sleep exclusions in `led_init()`. Keep the GPIO sleep policy explicit in tracked `sdkconfig.defaults`, and add a source-backed behavior regression that protects both halves of the power strategy: GPIO sleep handling remains enabled, and `led.c` gains no active blinking machinery.

**Tech Stack:** ESP-IDF C firmware, ESP32-S3 GPIO and automatic Light Sleep, Python source-backed regression tests, CMake/Ninja firmware build.

## Global Constraints

- Do not add an LED timer, FreeRTOS task, delay loop, PWM peripheral, or new dependency.
- Do not disable automatic Light Sleep, Tickless Idle, or `CONFIG_PM_SLP_DISABLE_GPIO`.
- Keep `CONFIG_PM_SLP_DISABLE_GPIO=y` explicit in tracked `sdkconfig.defaults`.
- Preserve persistent logical red, yellow, green, and off command behavior.
- Accept irregular wake-driven flicker; flash rate does not encode urgency.
- Do not modify or stage the pre-existing `main/include/common.h` device-name change.

---

### Task 1: Allow LED GPIOs to follow automatic Light Sleep

**Files:**
- Create: `tests/test_led_light_sleep_flicker.py`
- Modify: `main/src/led.c:46-62`
- Modify: `sdkconfig.defaults:41-46`
- Modify: `README.md:64-79`

**Interfaces:**
- Consumes: `led_init(void)`, `led_apply_command(uint8_t)`, `get_led_state(void)`, the current `esp_pm_configure()` setup, and the current `sdkconfig` power-management flags.
- Produces: unchanged LED command APIs whose physical GPIO output is allowed to disappear during Light Sleep without any new periodic CPU wake source.

- [ ] **Step 1: Write the failing behavior regression**

Create `tests/test_led_light_sleep_flicker.py` with:

```python
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LED_C = ROOT / "main" / "src" / "led.c"
MAIN_C = ROOT / "main" / "main.c"
SDKCONFIG_DEFAULTS = ROOT / "sdkconfig.defaults"


def test_led_gpios_follow_the_configured_light_sleep_policy():
    led_source = LED_C.read_text()
    main_source = MAIN_C.read_text()
    sdkconfig_defaults = SDKCONFIG_DEFAULTS.read_text()

    assert "gpio_sleep_sel_dis" not in led_source
    assert ".light_sleep_enable = true" in main_source
    assert "CONFIG_PM_ENABLE=y" in sdkconfig_defaults
    assert "CONFIG_PM_SLP_DISABLE_GPIO=y" in sdkconfig_defaults
    assert "CONFIG_FREERTOS_USE_TICKLESS_IDLE=y" in sdkconfig_defaults


def test_led_flicker_adds_no_periodic_wakeup_mechanism():
    led_source = LED_C.read_text()

    forbidden_wakeup_code = (
        "esp_timer_",
        "xTimerCreate",
        "vTaskDelay(",
        "vTaskDelayUntil(",
        "xTaskCreate(",
        "xTaskCreateStatic(",
        "ledc_",
        "gptimer_",
        "rmt_",
    )
    for forbidden in forbidden_wakeup_code:
        assert forbidden not in led_source


if __name__ == "__main__":
    test_led_gpios_follow_the_configured_light_sleep_policy()
    test_led_flicker_adds_no_periodic_wakeup_mechanism()
    print("2 LED Light Sleep behavior tests passed")
```

- [ ] **Step 2: Run the focused test and verify the expected failure**

Run:

```bash
python3 tests/test_led_light_sleep_flicker.py
```

Expected: FAIL in `test_led_gpios_follow_the_configured_light_sleep_policy` because the current `led.c` still contains `gpio_sleep_sel_dis`.

- [ ] **Step 3: Remove only the three LED GPIO sleep exclusions**

Replace `led_init()` in `main/src/led.c` with:

```c
void led_init(void) {
    ESP_LOGD(TAG, "LEDs configured: red=%d yellow=%d green=%d", RED_LED_GPIO,
             YELLOW_LED_GPIO, GREEN_LED_GPIO);

    gpio_reset_pin(RED_LED_GPIO);
    gpio_reset_pin(YELLOW_LED_GPIO);
    gpio_reset_pin(GREEN_LED_GPIO);

    gpio_set_direction(RED_LED_GPIO, GPIO_MODE_OUTPUT);
    gpio_set_direction(YELLOW_LED_GPIO, GPIO_MODE_OUTPUT);
    gpio_set_direction(GREEN_LED_GPIO, GPIO_MODE_OUTPUT);

    led_apply_command(LED_CMD_OFF);
}
```

Do not change `led_apply_command()`, `get_led_state()`, the GPIO definitions, or
any runtime power-management value beyond making the already active GPIO sleep
policy explicit in tracked defaults.

Add the tracked default immediately after `CONFIG_PM_ENABLE=y` in
`sdkconfig.defaults`:

```text
CONFIG_PM_SLP_DISABLE_GPIO=y
```

- [ ] **Step 4: Run the focused test and verify it passes**

Run:

```bash
python3 tests/test_led_light_sleep_flicker.py
```

Expected: `2 LED Light Sleep behavior tests passed` with exit code 0.

- [ ] **Step 5: Document the intentionally irregular physical output**

Replace the `main/src/led.c` bullet in `README.md` with:

```markdown
- `main/src/led.c`: controls the red, yellow, and green LEDs through hard-coded GPIO outputs; automatic Light Sleep may temporarily disable those GPIOs, producing irregular wake-driven flicker without a periodic LED timer.
```

Add this paragraph immediately after the LED pin list:

```markdown
The selected color remains the logical LED state until another BLE command arrives. To minimize standby power, GPIO 7, GPIO 8, and GPIO 9 are allowed to follow the configured automatic Light Sleep policy, so the physical LED can flicker as BLE or other system activity wakes the chip. The flicker rate is intentionally not regular or color-specific.
```

- [ ] **Step 6: Run all source-backed regressions**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
import runpy

count = 0
for path in sorted(Path("tests").glob("test_*.py")):
    namespace = runpy.run_path(str(path), run_name=f"regression_{path.stem}")
    for name, candidate in sorted(namespace.items()):
        if name.startswith("test_") and callable(candidate):
            candidate()
            count += 1
print(f"{count} source-backed regression tests passed")
PY
```

Expected: every top-level `test_*` function completes and the command exits 0.

- [ ] **Step 7: Build the ESP-IDF firmware and inspect the complete diff**

Run:

```bash
cmake --build build
git diff --check
git diff -- main/src/led.c sdkconfig.defaults tests/test_led_light_sleep_flicker.py README.md
git status --short
```

Expected: the build exits 0; `git diff --check` emits no output; the intended diff contains only the three removed calls, the tracked GPIO sleep default, the new regression, and README wording; `main/include/common.h` remains a separate pre-existing modification.

- [ ] **Step 8: Commit only the LED Light Sleep change**

Run:

```bash
git add main/src/led.c sdkconfig.defaults tests/test_led_light_sleep_flicker.py README.md
git diff --cached --check
git diff --cached --name-only
git commit -m "fix: let LED GPIOs follow light sleep"
git status --short
```

Expected: the staged file list contains exactly `README.md`, `main/src/led.c`, `sdkconfig.defaults`, and `tests/test_led_light_sleep_flicker.py`; the commit succeeds; afterward `main/include/common.h` remains modified and unstaged.
