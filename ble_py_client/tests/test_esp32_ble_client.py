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

    def test_find_device_by_name_requires_exact_match(self):
        module = load_client_module()
        exact_device = SimpleNamespace(name="Mina-1")
        similarly_named_device = SimpleNamespace(name="Mina-19")

        self.assertIs(
            exact_device,
            module.find_device_by_name([similarly_named_device, exact_device], "Mina-1"),
        )
        self.assertIsNone(module.find_device_by_name([similarly_named_device], "Mina-1"))

    def test_find_device_by_name_returns_none_when_missing(self):
        module = load_client_module()

        self.assertIsNone(module.find_device_by_name([SimpleNamespace(name="Other")], "Mina"))


if __name__ == "__main__":
    unittest.main()
