import argparse
import asyncio
import json
import sys
import time
from datetime import datetime
from pathlib import Path

try:
    from bleak import BleakClient, BleakScanner
except ModuleNotFoundError:
    BleakClient = None
    BleakScanner = None


DEFAULT_NAME = "Mina-15"
DEFAULT_DATA = "0"
DEFAULT_CHAR_UUID = "00001525-1212-efde-1523-785feabcd123"
DEFAULT_TIME_CHAR_UUID = "01001525-1212-efde-1523-785feabcd123"
DEFAULT_CACHE_PATH = Path(__file__).with_name(".ble_device_cache.json")
DEFAULT_CONNECT_RETRIES = 3
DEFAULT_CLIENT_TIMEOUT = 3.0
DEFAULT_RETRY_DELAY = 1.2
DEFAULT_SLEEP_START_HOUR = 23
DEFAULT_SLEEP_END_HOUR = 9


def current_log_timestamp():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def format_log_message(message, timestamp=None):
    if timestamp is None:
        timestamp = current_log_timestamp()
    return f"[{timestamp}] {message}"


def log(message):
    print(format_log_message(message))


def device_display_name(device, advertisement_data=None):
    if device.name:
        return device.name
    if advertisement_data and getattr(advertisement_data, "local_name", None):
        return advertisement_data.local_name
    return None


def iter_seen_devices(devices):
    for item in devices:
        if isinstance(item, tuple):
            yield item
        else:
            yield item, None


def remember_seen_device(seen_devices, device, advertisement_data=None):
    key = device.address or id(device)
    previous = seen_devices.get(key)
    if previous is None:
        seen_devices[key] = (device, advertisement_data)
        return

    new_name = device_display_name(device, advertisement_data)
    previous_name = device_display_name(previous[0], previous[1])
    if new_name or not previous_name:
        seen_devices[key] = (device, advertisement_data)


def find_device_by_name(devices, device_name):
    for device, advertisement_data in iter_seen_devices(devices):
        name = device_display_name(device, advertisement_data)
        if name and device_name in name:
            return device
    return None


def load_device_cache(cache_path=DEFAULT_CACHE_PATH):
    try:
        cache = json.loads(Path(cache_path).read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return {}

    if isinstance(cache, dict):
        return cache
    return {}


def save_device_cache(cache, cache_path=DEFAULT_CACHE_PATH):
    cache_path = Path(cache_path)
    cache_path.write_text(
        json.dumps(cache, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def cached_device_address(cache, device_name):
    entry = cache.get(device_name)
    if not isinstance(entry, dict):
        return None

    address = entry.get("address")
    if isinstance(address, str) and address:
        return address
    return None


def cache_device_address(cache, device_name, device):
    if not getattr(device, "address", None):
        return

    entry = cache.get(device_name)
    if not isinstance(entry, dict):
        entry = {}

    entry["address"] = device.address
    entry["name"] = device.name
    cache[device_name] = entry


def validate_sleep_window(sleep_start_hour, sleep_end_hour):
    if not 0 <= sleep_start_hour <= 23:
        raise ValueError("deep sleep 开始小时必须在 0-23 之间")
    if not 0 <= sleep_end_hour <= 23:
        raise ValueError("deep sleep 结束小时必须在 0-23 之间")
    if sleep_start_hour == sleep_end_hour:
        raise ValueError("deep sleep 起止小时不能相同")


def cached_sleep_window(cache, device_name):
    entry = cache.get(device_name)
    if isinstance(entry, dict):
        start_hour = entry.get("sleepStartHour")
        end_hour = entry.get("sleepEndHour")
        if isinstance(start_hour, int) and isinstance(end_hour, int):
            try:
                validate_sleep_window(start_hour, end_hour)
                return start_hour, end_hour
            except ValueError:
                pass

    return DEFAULT_SLEEP_START_HOUR, DEFAULT_SLEEP_END_HOUR


def cache_sleep_window(cache, device_name, sleep_start_hour, sleep_end_hour):
    validate_sleep_window(sleep_start_hour, sleep_end_hour)
    entry = cache.get(device_name)
    if not isinstance(entry, dict):
        entry = {}

    entry["sleepStartHour"] = sleep_start_hour
    entry["sleepEndHour"] = sleep_end_hour
    cache[device_name] = entry


def parse_payload(value):
    value = value.strip()
    if value.startswith(("0x", "0X")):
        return bytes([int(value, 16)])
    if value.isdigit() and 0 <= int(value) <= 255:
        return bytes([int(value)])
    return value.encode("utf-8")


def build_time_sync_payload(
    unix_time_seconds=None,
    sleep_start_hour=DEFAULT_SLEEP_START_HOUR,
    sleep_end_hour=DEFAULT_SLEEP_END_HOUR,
):
    if unix_time_seconds is None:
        unix_time_seconds = int(time.time())
    if unix_time_seconds < 0:
        raise ValueError("时间戳不能为负数")
    if unix_time_seconds > 0xFFFFFFFF:
        raise ValueError("时间戳超出 4 字节范围")

    validate_sleep_window(sleep_start_hour, sleep_end_hour)
    payload = int(unix_time_seconds).to_bytes(4, byteorder="little", signed=False)
    return payload + bytes([sleep_start_hour, sleep_end_hour])


def list_devices(devices):
    if not devices:
        log("  没有扫描到任何 BLE 设备")
        return

    for device, advertisement_data in iter_seen_devices(devices):
        name = device_display_name(device, advertisement_data) or "<无名称>"
        log(f"  - {name} ({device.address})")


async def get_services(client):
    services = getattr(client, "services", None)
    if services:
        return services
    if hasattr(client, "get_services"):
        return await client.get_services()
    raise RuntimeError("当前 bleak 版本无法读取服务列表")


def writable_characteristics(services):
    for service in services:
        for char in service.characteristics:
            if "write" in char.properties or "write-without-response" in char.properties:
                yield char


def print_writable_characteristics(services):
    writable = list(writable_characteristics(services))
    if not writable:
        log("  未发现可写特征")
        return

    for char in writable:
        log(f"  - {char.uuid}  ({', '.join(char.properties)})")


async def scan_for_device_by_name(device_name, scan_timeout=8.0, scan_rounds=3):
    seen_devices = {}
    found = None
    found_event = asyncio.Event()
    round_timeout = max(1.0, scan_timeout / max(1, scan_rounds))

    def detection_callback(device, advertisement_data):
        nonlocal found
        remember_seen_device(seen_devices, device, advertisement_data)
        if found is None and find_device_by_name([(device, advertisement_data)], device_name):
            found = device
            found_event.set()

    deadline = asyncio.get_running_loop().time() + scan_timeout
    for round_index in range(max(1, scan_rounds)):
        remaining = deadline - asyncio.get_running_loop().time()
        if remaining <= 0:
            break

        scanner = BleakScanner(detection_callback=detection_callback)
        await scanner.start()
        try:
            wait_time = min(round_timeout, remaining)
            try:
                await asyncio.wait_for(found_event.wait(), timeout=wait_time)
            except asyncio.TimeoutError:
                pass
        finally:
            await scanner.stop()

        if found is not None:
            return found, list(seen_devices.values())

        # Restarting the scan helps on macOS when CoreBluetooth misses a cycle.
        if round_index + 1 < scan_rounds:
            await asyncio.sleep(0.2)

    found = find_device_by_name(seen_devices.values(), device_name)
    return found, list(seen_devices.values())


async def write_ble_data(target_device, data, characteristic_uuid=None, display_name=None):
    target_name = display_name or getattr(target_device, "name", None) or str(target_device)

    async with BleakClient(target_device, timeout=DEFAULT_CLIENT_TIMEOUT) as client:
        if not client.is_connected:
            log("连接失败：BleakClient 未进入 connected 状态")
            return 1

        log(f"已连接到 {target_name}")
        services = await get_services(client)

        if characteristic_uuid is None:
            log("未指定特征 UUID，以下为所有可写特征：")
            print_writable_characteristics(services)
            return 0

        chars_by_uuid = {
            char.uuid.lower(): char
            for service in services
            for char in service.characteristics
        }
        char = chars_by_uuid.get(characteristic_uuid.lower())
        if char is None:
            log(f"未找到特征 UUID: {characteristic_uuid}")
            log("当前所有可写特征：")
            print_writable_characteristics(services)
            return 1

        response = "write" in char.properties
        await client.write_gatt_char(char.uuid, data, response=response)
        log(f"数据已写入 {char.uuid}: {data!r}")
        return 0


async def send_ble_data(
    device_name,
    data,
    characteristic_uuid=None,
    scan_timeout=8.0,
    scan_rounds=3,
    cache_path=DEFAULT_CACHE_PATH,
    use_cache=True,
    connect_retries=DEFAULT_CONNECT_RETRIES,
    retry_delay=DEFAULT_RETRY_DELAY,
):
    if BleakScanner is None or BleakClient is None:
        log("缺少 bleak 库，先安装后再运行：")
        log("  python3 -m pip install bleak")
        return 2

    attempts = max(1, connect_retries)
    cache = load_device_cache(cache_path)
    cached_address = cached_device_address(cache, device_name) if use_cache else None
    if cached_address:
        log(f"先尝试使用缓存地址连接 '{device_name}': {cached_address}")
        for attempt in range(1, attempts + 1):
            if attempts > 1:
                log(f"缓存地址连接尝试 {attempt}/{attempts}")
            try:
                return_code = await write_ble_data(
                    cached_address,
                    data,
                    characteristic_uuid,
                    display_name=device_name,
                )
                if return_code == 0:
                    return 0
            except Exception as exc:
                log(f"缓存地址连接失败: {type(exc).__name__}: {exc}")

            if attempt < attempts:
                log("缓存地址连接未完成，稍后重试。")
                await asyncio.sleep(retry_delay)

        log("缓存地址多次连接未完成，回退到扫描。")

    last_devices = []

    for attempt in range(1, attempts + 1):
        if attempts > 1:
            log(f"扫描/连接尝试 {attempt}/{attempts}")

        log(f"正在扫描 BLE 设备，寻找名称包含 '{device_name}' 的设备...")
        try:
            target_device, devices = await scan_for_device_by_name(
                device_name,
                scan_timeout=scan_timeout,
                scan_rounds=scan_rounds,
            )
        except Exception as exc:
            log(f"扫描失败: {type(exc).__name__}: {exc}")
            if attempt == attempts:
                log("请确认蓝牙已打开，并在 macOS 系统设置里允许运行该脚本的终端访问蓝牙。")
                return 1
            await asyncio.sleep(retry_delay)
            continue

        last_devices = devices
        if target_device is None:
            if attempt < attempts:
                log("本轮未找到目标设备，稍后重试。")
                await asyncio.sleep(retry_delay)
                continue

            log(f"未找到名称包含 '{device_name}' 的设备。当前扫描到：")
            list_devices(last_devices)
            return 1

        found_name = device_display_name(target_device) or device_name
        log(f"找到设备: {found_name} ({target_device.address})")
        cache_device_address(cache, device_name, target_device)
        if use_cache:
            try:
                save_device_cache(cache, cache_path)
            except OSError as exc:
                log(f"缓存设备地址失败，但会继续连接: {type(exc).__name__}: {exc}")

        try:
            return_code = await write_ble_data(target_device, data, characteristic_uuid)
            if return_code == 0:
                return 0
        except Exception as exc:
            log(f"连接或写入失败: {type(exc).__name__}: {exc}")

        if attempt < attempts:
            log("连接或写入未完成，稍后重新扫描并重试。")
            await asyncio.sleep(retry_delay)

    log("多次尝试后仍未完成连接或写入。")
    log("建议确认 ESP32 正在广播、设备名一致、手机没有占用连接、UUID 与固件一致。")
    return 1


def build_parser():
    parser = argparse.ArgumentParser(description="向 ESP32 BLE 可写特征发送数据")
    parser.add_argument("--name", default=DEFAULT_NAME, help=f"设备名包含匹配，默认 {DEFAULT_NAME}")
    parser.add_argument("--data", default=DEFAULT_DATA, help="发送内容。0/1/2 会按单字节发送；也支持 0x00 或普通字符串")
    parser.add_argument("--uuid", default=None, help="目标特征 UUID；传空字符串则只列出可写特征")
    parser.add_argument("--scan-timeout", type=float, default=12.0, help="扫描秒数，默认 12")
    parser.add_argument("--scan-rounds", type=int, default=3, help="扫描分轮次数，默认 3")
    parser.add_argument("--cache-path", default=str(DEFAULT_CACHE_PATH), help="设备地址缓存文件路径")
    parser.add_argument("--no-cache", action="store_true", help="不使用缓存地址，直接扫描")
    parser.add_argument("--connect-retries", type=int, default=DEFAULT_CONNECT_RETRIES, help="扫描到设备后的连接/写入重试次数，默认 3")
    parser.add_argument("--retry-delay", type=float, default=DEFAULT_RETRY_DELAY, help="连接/写入失败后的重试等待秒数，默认 1.2")
    subparsers = parser.add_subparsers(dest="command")
    subparsers.add_parser("sync-time", help="同步电脑当前 Unix 秒级时间戳")
    update_parser = subparsers.add_parser("update-sleep-time", help="更新缓存里的 deep sleep 小时段并同步到设备")
    update_parser.add_argument("sleep_start_hour", type=int)
    update_parser.add_argument("sleep_end_hour", type=int)
    return parser


def resolve_characteristic_uuid(args, default_uuid):
    if args.uuid is None:
        return default_uuid
    return args.uuid or None


async def main(argv=None):
    args = build_parser().parse_args(argv)
    cache = load_device_cache(args.cache_path)

    if args.command == "sync-time":
        sleep_start_hour, sleep_end_hour = cached_sleep_window(cache, args.name)
        data = build_time_sync_payload(
            sleep_start_hour=sleep_start_hour,
            sleep_end_hour=sleep_end_hour,
        )
        characteristic_uuid = resolve_characteristic_uuid(args, DEFAULT_TIME_CHAR_UUID)
        log(f"同步电脑时间戳: {int.from_bytes(data[:4], byteorder='little', signed=False)}")
    elif args.command == "update-sleep-time":
        cache_sleep_window(cache, args.name, args.sleep_start_hour, args.sleep_end_hour)
        save_device_cache(cache, args.cache_path)
        data = build_time_sync_payload(
            sleep_start_hour=args.sleep_start_hour,
            sleep_end_hour=args.sleep_end_hour,
        )
        characteristic_uuid = resolve_characteristic_uuid(args, DEFAULT_TIME_CHAR_UUID)
        log(f"更新 deep sleep 时间段: {args.sleep_start_hour}:00-{args.sleep_end_hour}:00")
    else:
        data = parse_payload(args.data)
        characteristic_uuid = resolve_characteristic_uuid(args, DEFAULT_CHAR_UUID)

    return await send_ble_data(
        args.name,
        data,
        characteristic_uuid,
        scan_timeout=args.scan_timeout,
        scan_rounds=args.scan_rounds,
        cache_path=args.cache_path,
        use_cache=not args.no_cache,
        connect_retries=args.connect_retries,
        retry_delay=args.retry_delay,
    )


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
