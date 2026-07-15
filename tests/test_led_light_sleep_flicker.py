from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LED_C = ROOT / "main" / "src" / "led.c"
MAIN_C = ROOT / "main" / "main.c"
SDKCONFIG = ROOT / "sdkconfig"


def test_led_gpios_follow_the_configured_light_sleep_policy():
    led_source = LED_C.read_text()
    main_source = MAIN_C.read_text()
    sdkconfig = SDKCONFIG.read_text()

    assert "gpio_sleep_sel_dis" not in led_source
    assert ".light_sleep_enable = true" in main_source
    assert "CONFIG_PM_ENABLE=y" in sdkconfig
    assert "CONFIG_PM_SLP_DISABLE_GPIO=y" in sdkconfig
    assert "CONFIG_FREERTOS_USE_TICKLESS_IDLE=y" in sdkconfig


def test_led_flicker_adds_no_periodic_wakeup_mechanism():
    led_source = LED_C.read_text()

    forbidden_wakeup_code = (
        "esp_timer_",
        "vTaskDelay(",
        "xTaskCreate(",
        "ledc_",
    )
    for forbidden in forbidden_wakeup_code:
        assert forbidden not in led_source


if __name__ == "__main__":
    test_led_gpios_follow_the_configured_light_sleep_policy()
    test_led_flicker_adds_no_periodic_wakeup_mechanism()
    print("2 LED Light Sleep behavior tests passed")
