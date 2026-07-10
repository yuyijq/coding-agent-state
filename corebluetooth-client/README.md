# ESP32 CoreBluetooth Client

这是一个 macOS CoreBluetooth 命令行客户端，逻辑参考 `ble_py_client/esp32_ble_client.py`：

- 指定 `--name` 时只连接名称匹配的单个 BLE 设备；不指定 `--name` 时读取缓存文件并遍历所有缓存设备。
- 指定 `--name` 且缓存文件不存在或缓存里没有该设备时，首次普通 LED 连接会先发送初始化灯光序列：红、黄、绿各间隔 `50ms` 重复 3 次，最后熄灭并断开。
- 默认向 LED 特征 `00001525-1212-efde-1523-785feabcd123` 写入单字节 `0x00`。
- `sync-time` 会向时间特征 `01001525-1212-efde-1523-785feabcd123` 写入 6 字节 payload：4 字节小端 Unix 秒级时间戳、1 字节 deep sleep 开始小时、1 字节结束小时。
- 缓存文件会记录每个设备上次成功同步时间和 deep sleep 时间段；普通指令写入时如果超过 1 小时未同步，会在同一次连接里先写入指令，再尝试同步时间。自动时间同步失败不会触发指令重试；传 `--no-auto-time-sync` 可以关闭普通指令后的自动时间同步。
- 默认使用 `3s` 连接/发现服务/写入阶段超时，缓存连接失败会重试 `3` 次，再回退到按名称扫描。
- 连接成功后只发现目标服务 `1815`，并在该服务内发现固定的两个可写特征。
- 扫描时按广播服务 `1815` 过滤；需要 ESP32 广播包包含该服务 UUID。
- 写入完成或连接失败后会等待 CoreBluetooth 的断开/取消回调，减少连续命令之间的状态竞争。
- CoreBluetooth 不暴露 BLE MAC 地址，所以缓存的是 macOS 的 `CBPeripheral.identifier`。

## 运行

构建后可以直接执行当前目录里的 release CLI。默认使用用户目录下的 `~/.ble_device_cache.json`。不指定 `--name` 时，会遍历缓存里所有可连接设备：

```bash
./esp32-ble-corebluetooth
```

只连接一个指定设备：

```bash
./esp32-ble-corebluetooth --name Mina-15
```

同步时间：

```bash
./esp32-ble-corebluetooth sync-time
```

更新 deep sleep 时间段并立即同步到设备：

```bash
./esp32-ble-corebluetooth update-sleep-time 23 7
```

发送其他命令：

```bash
./esp32-ble-corebluetooth --name Mina-15 --data 3
./esp32-ble-corebluetooth --name Mina-15 --data 0x05
```

发送指令但不自动同步时间：

```bash
./esp32-ble-corebluetooth --name Mina-15 --data 3 --no-auto-time-sync
```

如果固件里的服务 UUID 改了，可以显式指定：

```bash
./esp32-ble-corebluetooth --service-uuid 1815 --data 1
```

只列出可写特征：

```bash
./esp32-ble-corebluetooth --uuid ""
```

## macOS 权限

第一次运行可能需要在系统设置里允许当前终端访问蓝牙：

`系统设置 -> 隐私与安全性 -> 蓝牙`

如果没有权限，程序会打印 `没有蓝牙权限` 并退出。
