from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GAP_C = ROOT / "main" / "src" / "gap.c"
SDKCONFIG_DEFAULTS = ROOT / "sdkconfig.defaults"


def test_ble_tx_power_uses_next_step_above_n6():
    gap = GAP_C.read_text()
    sdkconfig = SDKCONFIG_DEFAULTS.read_text()

    assert "esp_ble_tx_power_set(ESP_BLE_PWR_TYPE_ADV, ESP_PWR_LVL_N3)" in gap
    assert (
        "esp_ble_tx_power_set_enhanced(ESP_BLE_ENHANCED_PWR_TYPE_CONN,\n"
        "                                               event->connect.conn_handle,\n"
        "                                               ESP_PWR_LVL_N3)"
        in gap
    )
    assert "# CONFIG_BT_CTRL_DFT_TX_POWER_LEVEL_N6 is not set" in sdkconfig
    assert "CONFIG_BT_CTRL_DFT_TX_POWER_LEVEL_N3=y" in sdkconfig
