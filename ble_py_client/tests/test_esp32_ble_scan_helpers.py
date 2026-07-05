import importlib.util
import asyncio
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace


MODULE_PATH = Path(__file__).resolve().parents[1] / "esp32_ble_client.py"
spec = importlib.util.spec_from_file_location("esp32_ble_client", MODULE_PATH)
esp32_ble_client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(esp32_ble_client)


def make_device(name=None, address="AA:BB"):
    return SimpleNamespace(name=name, address=address)


def make_adv(local_name=None):
    return SimpleNamespace(local_name=local_name)


class BleScanHelperTests(unittest.TestCase):
    def test_format_log_message_prefixes_timestamp(self):
        self.assertEqual(
            esp32_ble_client.format_log_message(
                "正在扫描 BLE 设备",
                timestamp="2026-07-05 12:34:56",
            ),
            "[2026-07-05 12:34:56] 正在扫描 BLE 设备",
        )

    def test_list_devices_prints_timestamped_lines(self):
        device = make_device(name="Mina-15", address="AA:BB")
        original_timestamp = getattr(esp32_ble_client, "current_log_timestamp", None)

        try:
            esp32_ble_client.current_log_timestamp = lambda: "2026-07-05 12:34:56"

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                esp32_ble_client.list_devices([(device, make_adv(local_name="Mina-15"))])

            self.assertEqual(
                output.getvalue(),
                "[2026-07-05 12:34:56]   - Mina-15 (AA:BB)\n",
            )
        finally:
            if original_timestamp is None:
                del esp32_ble_client.current_log_timestamp
            else:
                esp32_ble_client.current_log_timestamp = original_timestamp

    def test_find_device_matches_advertisement_local_name_when_device_name_missing(self):
        target = make_device(name=None, address="11:22")
        seen = [(target, make_adv(local_name="Mina-8"))]

        self.assertIs(esp32_ble_client.find_device_by_name(seen, "Mina"), target)

    def test_remember_seen_device_updates_advertisement_data_for_same_address(self):
        seen = {}
        device = make_device(name=None, address="11:22")

        esp32_ble_client.remember_seen_device(seen, device, make_adv(local_name=None))
        esp32_ble_client.remember_seen_device(seen, device, make_adv(local_name="Mina-8"))

        self.assertEqual(list(seen.values()), [(device, make_adv(local_name="Mina-8"))])

    def test_remember_seen_device_keeps_existing_name_when_new_report_has_no_name(self):
        seen = {}
        device = make_device(name=None, address="11:22")

        esp32_ble_client.remember_seen_device(seen, device, make_adv(local_name="Mina-8"))
        esp32_ble_client.remember_seen_device(seen, device, make_adv(local_name=None))

        self.assertEqual(list(seen.values()), [(device, make_adv(local_name="Mina-8"))])

    def test_cache_device_address_saves_address_by_requested_name(self):
        cache = {}
        device = make_device(name="Mina-8", address="11:22")

        esp32_ble_client.cache_device_address(cache, "Mina", device)

        self.assertEqual(cache, {"Mina": {"address": "11:22", "name": "Mina-8"}})

    def test_load_device_cache_returns_empty_dict_for_missing_or_invalid_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            missing_path = Path(temp_dir) / "missing.json"
            invalid_path = Path(temp_dir) / "invalid.json"
            invalid_path.write_text("{bad json", encoding="utf-8")

            self.assertEqual(esp32_ble_client.load_device_cache(missing_path), {})
            self.assertEqual(esp32_ble_client.load_device_cache(invalid_path), {})

    def test_save_device_cache_persists_json(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            cache_path = Path(temp_dir) / "cache.json"
            cache = {"Mina": {"address": "11:22", "name": "Mina-8"}}

            esp32_ble_client.save_device_cache(cache, cache_path)

            self.assertEqual(json.loads(cache_path.read_text(encoding="utf-8")), cache)


class BleSendRetryTests(unittest.IsolatedAsyncioTestCase):
    async def test_write_ble_data_uses_three_second_client_timeout(self):
        calls = {}

        class FakeBleakClient:
            def __init__(self, target_device, timeout):
                calls["target_device"] = target_device
                calls["timeout"] = timeout
                self.is_connected = True
                self.services = [
                    SimpleNamespace(
                        characteristics=[
                            SimpleNamespace(
                                uuid=esp32_ble_client.DEFAULT_CHAR_UUID,
                                properties=["write"],
                            )
                        ]
                    )
                ]

            async def __aenter__(self):
                return self

            async def __aexit__(self, exc_type, exc, tb):
                return None

            async def write_gatt_char(self, uuid, data, response):
                calls["write"] = (uuid, data, response)

        original_client = esp32_ble_client.BleakClient

        try:
            esp32_ble_client.BleakClient = FakeBleakClient

            with contextlib.redirect_stdout(io.StringIO()):
                result = await esp32_ble_client.write_ble_data(
                    "AA:BB",
                    b"\x00",
                    esp32_ble_client.DEFAULT_CHAR_UUID,
                )

            self.assertEqual(result, 0)
            self.assertEqual(calls["target_device"], "AA:BB")
            self.assertEqual(calls["timeout"], 3.0)
            self.assertEqual(
                calls["write"],
                (esp32_ble_client.DEFAULT_CHAR_UUID, b"\x00", True),
            )
        finally:
            esp32_ble_client.BleakClient = original_client

    async def test_send_ble_data_retries_scan_and_write_after_write_failure(self):
        calls = {"scan": 0, "write": 0}
        device = make_device(name="Mina-8", address="11:22")

        async def fake_scan_for_device_by_name(device_name, scan_timeout=8.0, scan_rounds=3):
            calls["scan"] += 1
            return device, [(device, make_adv(local_name="Mina-8"))]

        async def fake_write_ble_data(target_device, data, characteristic_uuid=None, display_name=None):
            calls["write"] += 1
            return 1 if calls["write"] == 1 else 0

        async def fake_sleep(delay):
            return None

        original_scanner = esp32_ble_client.BleakScanner
        original_client = esp32_ble_client.BleakClient
        original_scan = esp32_ble_client.scan_for_device_by_name
        original_write = esp32_ble_client.write_ble_data
        original_sleep = esp32_ble_client.asyncio.sleep

        try:
            esp32_ble_client.BleakScanner = object()
            esp32_ble_client.BleakClient = object()
            esp32_ble_client.scan_for_device_by_name = fake_scan_for_device_by_name
            esp32_ble_client.write_ble_data = fake_write_ble_data
            esp32_ble_client.asyncio.sleep = fake_sleep

            with tempfile.TemporaryDirectory() as temp_dir:
                with contextlib.redirect_stdout(io.StringIO()):
                    result = await esp32_ble_client.send_ble_data(
                        "Mina",
                        b"\x00",
                        cache_path=Path(temp_dir) / "cache.json",
                        use_cache=False,
                        connect_retries=2,
                        retry_delay=0,
                    )

            self.assertEqual(result, 0)
            self.assertEqual(calls, {"scan": 2, "write": 2})
        finally:
            esp32_ble_client.BleakScanner = original_scanner
            esp32_ble_client.BleakClient = original_client
            esp32_ble_client.scan_for_device_by_name = original_scan
            esp32_ble_client.write_ble_data = original_write
            esp32_ble_client.asyncio.sleep = original_sleep

    async def test_send_ble_data_retries_cached_address_before_scanning(self):
        calls = {"scan": 0, "write": 0}

        async def fake_scan_for_device_by_name(device_name, scan_timeout=8.0, scan_rounds=3):
            calls["scan"] += 1
            return None, []

        async def fake_write_ble_data(target_device, data, characteristic_uuid=None, display_name=None):
            calls["write"] += 1
            self.assertEqual(target_device, "AA:BB")
            self.assertEqual(display_name, "Mina")
            return 1 if calls["write"] < 3 else 0

        async def fake_sleep(delay):
            return None

        original_scanner = esp32_ble_client.BleakScanner
        original_client = esp32_ble_client.BleakClient
        original_scan = esp32_ble_client.scan_for_device_by_name
        original_write = esp32_ble_client.write_ble_data
        original_sleep = esp32_ble_client.asyncio.sleep

        try:
            esp32_ble_client.BleakScanner = object()
            esp32_ble_client.BleakClient = object()
            esp32_ble_client.scan_for_device_by_name = fake_scan_for_device_by_name
            esp32_ble_client.write_ble_data = fake_write_ble_data
            esp32_ble_client.asyncio.sleep = fake_sleep

            with tempfile.TemporaryDirectory() as temp_dir:
                cache_path = Path(temp_dir) / "cache.json"
                esp32_ble_client.save_device_cache(
                    {"Mina": {"address": "AA:BB", "name": "Mina-15"}},
                    cache_path,
                )

                with contextlib.redirect_stdout(io.StringIO()):
                    result = await esp32_ble_client.send_ble_data(
                        "Mina",
                        b"\x00",
                        cache_path=cache_path,
                        connect_retries=3,
                        retry_delay=0,
                    )

            self.assertEqual(result, 0)
            self.assertEqual(calls, {"scan": 0, "write": 3})
        finally:
            esp32_ble_client.BleakScanner = original_scanner
            esp32_ble_client.BleakClient = original_client
            esp32_ble_client.scan_for_device_by_name = original_scan
            esp32_ble_client.write_ble_data = original_write
            esp32_ble_client.asyncio.sleep = original_sleep


class BleSyncTimeCommandTests(unittest.IsolatedAsyncioTestCase):
    async def test_sync_time_command_writes_current_unix_time_to_time_characteristic(self):
        calls = []

        async def fake_send_ble_data(
            device_name,
            data,
            characteristic_uuid=None,
            scan_timeout=8.0,
            scan_rounds=3,
            cache_path=esp32_ble_client.DEFAULT_CACHE_PATH,
            use_cache=True,
            connect_retries=esp32_ble_client.DEFAULT_CONNECT_RETRIES,
            retry_delay=esp32_ble_client.DEFAULT_RETRY_DELAY,
        ):
            calls.append(
                {
                    "device_name": device_name,
                    "data": data,
                    "characteristic_uuid": characteristic_uuid,
                    "scan_timeout": scan_timeout,
                    "scan_rounds": scan_rounds,
                    "cache_path": cache_path,
                    "use_cache": use_cache,
                    "connect_retries": connect_retries,
                    "retry_delay": retry_delay,
                }
            )
            return 0

        original_send = esp32_ble_client.send_ble_data
        original_time = getattr(esp32_ble_client, "time", None)

        try:
            esp32_ble_client.send_ble_data = fake_send_ble_data
            esp32_ble_client.time = SimpleNamespace(time=lambda: 0x12345678)

            with tempfile.TemporaryDirectory() as temp_dir:
                with contextlib.redirect_stdout(io.StringIO()):
                    result = await esp32_ble_client.main(
                        [
                            "--name",
                            "Mina",
                            "--cache-path",
                            str(Path(temp_dir) / "cache.json"),
                            "sync-time",
                        ]
                    )

            self.assertEqual(result, 0)
            self.assertEqual(
                calls,
                [
                    {
                        "device_name": "Mina",
                        "data": b"\x78\x56\x34\x12\x00\x00\x00\x00",
                        "characteristic_uuid": esp32_ble_client.DEFAULT_TIME_CHAR_UUID,
                        "scan_timeout": 12.0,
                        "scan_rounds": 3,
                        "cache_path": str(Path(temp_dir) / "cache.json"),
                        "use_cache": True,
                        "connect_retries": esp32_ble_client.DEFAULT_CONNECT_RETRIES,
                        "retry_delay": esp32_ble_client.DEFAULT_RETRY_DELAY,
                    }
                ],
            )
        finally:
            esp32_ble_client.send_ble_data = original_send
            if original_time is None:
                del esp32_ble_client.time
            else:
                esp32_ble_client.time = original_time


if __name__ == "__main__":
    unittest.main()
