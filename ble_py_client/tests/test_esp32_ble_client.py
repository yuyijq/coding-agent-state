import importlib.util
import sys
import unittest
from pathlib import Path
from types import ModuleType, SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]


def load_client_module():
    fake_bleak = ModuleType("bleak")
    fake_bleak.BleakScanner = object
    fake_bleak.BleakClient = object
    sys.modules["bleak"] = fake_bleak
    spec = importlib.util.spec_from_file_location("esp32_ble_client", ROOT / "esp32_ble_client.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Esp32BleClientTests(unittest.TestCase):
    def test_default_cache_path_uses_ks_server_dev_mina_led(self):
        module = load_client_module()

        self.assertEqual(module.DEFAULT_CACHE_PATH, Path.home() / ".ks-server-dev" / ".mina_led")

    def test_find_device_by_name_uses_substring_match(self):
        module = load_client_module()
        devices = [
            SimpleNamespace(name=None),
            SimpleNamespace(name="Other"),
            SimpleNamespace(name="Mina-15"),
        ]

        self.assertIs(devices[2], module.find_device_by_name(devices, "Mina"))

    def test_find_device_by_name_returns_none_when_missing(self):
        module = load_client_module()

        self.assertIsNone(module.find_device_by_name([SimpleNamespace(name="Other")], "Mina"))


if __name__ == "__main__":
    unittest.main()
