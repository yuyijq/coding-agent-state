from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SLEEP_MANAGER_C = ROOT / "main" / "src" / "sleep_manager.c"
SLEEP_MANAGER_H = ROOT / "main" / "include" / "sleep_manager.h"
MAIN_C = ROOT / "main" / "main.c"


def test_deep_sleep_wakeup_restores_time_from_rtc_state():
    source = SLEEP_MANAGER_C.read_text()
    header = SLEEP_MANAGER_H.read_text()
    main = MAIN_C.read_text()

    assert "void sleep_manager_handle_wakeup(void);" in header
    assert "sleep_manager_handle_wakeup();" in main
    assert "RTC_DATA_ATTR" in source
    assert "planned_wakeup_unix_time" in source
    assert "esp_sleep_get_wakeup_causes() & BIT(ESP_SLEEP_WAKEUP_TIMER)" in source
    assert "planned_wakeup_unix_time = (uint64_t)now + sleep_seconds;" in source
    assert ".tv_sec = (time_t)planned_wakeup_unix_time" in source


if __name__ == "__main__":
    test_deep_sleep_wakeup_restores_time_from_rtc_state()
