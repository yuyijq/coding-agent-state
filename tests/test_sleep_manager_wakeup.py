from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SLEEP_MANAGER_C = ROOT / "main" / "src" / "sleep_manager.c"
SLEEP_MANAGER_H = ROOT / "main" / "include" / "sleep_manager.h"
MAIN_C = ROOT / "main" / "main.c"


def test_deep_sleep_wakeup_restores_time_from_rtc_state():
    source = SLEEP_MANAGER_C.read_text()
    header = SLEEP_MANAGER_H.read_text()
    main = MAIN_C.read_text()

    assert "#define DEFAULT_SLEEP_START_HOUR 23" in source
    assert "#define DEFAULT_SLEEP_END_HOUR 9" in source
    assert "void sleep_manager_handle_wakeup(void);" in header
    assert (
        "void sleep_manager_update_time(uint32_t unix_time_seconds,"
        in header
    )
    assert "sleep_manager_handle_wakeup();" in main
    assert "RTC_DATA_ATTR" in source
    assert "planned_wakeup_unix_time" in source
    assert "planned_sleep_start_hour" in source
    assert "planned_sleep_end_hour" in source
    assert "esp_sleep_get_wakeup_causes() & BIT(ESP_SLEEP_WAKEUP_TIMER)" in source
    assert "planned_wakeup_unix_time = (uint64_t)now + sleep_seconds;" in source
    assert "planned_sleep_start_hour = active_sleep_start_hour;" in source
    assert "planned_sleep_end_hour = active_sleep_end_hour;" in source
    assert ".tv_sec = (time_t)planned_wakeup_unix_time" in source
    assert "active_sleep_start_hour = planned_sleep_start_hour;" in source
    assert "active_sleep_end_hour = planned_sleep_end_hour;" in source
    assert "active_sleep_start_hour" in source
    assert "active_sleep_end_hour" in source
    assert "sleep_window_crosses_midnight" in source
    assert "sleep_manager_update_time(unix_time_seconds, 0, 8)" not in source


def test_time_characteristic_requires_six_byte_payload():
    source = (ROOT / "main" / "src" / "gatt_svc.c").read_text()

    assert "#define TIME_SYNC_PAYLOAD_LEN 6" in source
    assert "ctxt->om->om_len != TIME_SYNC_PAYLOAD_LEN" in source
    assert "sleep_manager_update_time(unix_time_seconds, timestamp_bytes[4], timestamp_bytes[5])" in source


if __name__ == "__main__":
    test_deep_sleep_wakeup_restores_time_from_rtc_state()
