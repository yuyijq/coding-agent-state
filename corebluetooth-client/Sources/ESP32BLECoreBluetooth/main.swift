import CoreBluetooth
import CoreBluetoothSupport
import Foundation

private struct ClientConfig {
    var deviceName = BLEDefaults.deviceName
    var payload = Data()
    var serviceUUID = BLEDefaults.serviceUUID
    var characteristicUUID: String? = BLEDefaults.ledCharacteristicUUID
    var scanTimeout = BLEDefaults.scanTimeout
    var scanRounds = BLEDefaults.scanRounds
    var cachePath = BLEDefaults.cachePath
    var useCache = true
    var connectRetries = BLEDefaults.connectRetries
    var clientTimeout = BLEDefaults.clientTimeout
    var retryDelay = BLEDefaults.retryDelay
}

private enum CommandMode {
    case writeData(String)
    case syncTime
}

private enum CLIError: Error, CustomStringConvertible {
    case help
    case missingValue(String)
    case unknownOption(String)
    case invalidNumber(String, String)
    case invalidPayload(String)

    var description: String {
        switch self {
        case .help:
            return usageText
        case .missingValue(let option):
            return "\(option) 缺少参数值"
        case .unknownOption(let option):
            return "未知参数: \(option)"
        case .invalidNumber(let option, let value):
            return "\(option) 需要数字参数，当前是: \(value)"
        case .invalidPayload(let message):
            return message
        }
    }
}

private let usageText = """
用法:
  esp32-ble-corebluetooth [选项]
  esp32-ble-corebluetooth [选项] sync-time

选项:
  --name <name>              设备名包含匹配，默认 \(BLEDefaults.deviceName)
  --data <value>             发送内容，默认 \(BLEDefaults.data)。支持 0-255、0x00 或普通字符串
  --service-uuid <uuid>      目标服务 UUID，默认 \(BLEDefaults.serviceUUID)
  --uuid <uuid>              目标特征 UUID；传空字符串则只列出可写特征
  --scan-timeout <seconds>   扫描总秒数，默认 \(BLEDefaults.scanTimeout)
  --scan-rounds <count>      扫描分轮次数，默认 \(BLEDefaults.scanRounds)
  --cache-path <path>        设备缓存文件路径，默认 \(BLEDefaults.cachePath)
  --no-cache                 不使用缓存 identifier，直接扫描
  --connect-retries <count>  缓存连接和扫描连接重试次数，默认 \(BLEDefaults.connectRetries)
  --client-timeout <seconds> 单次连接/发现服务/写入阶段超时，默认 \(BLEDefaults.clientTimeout)
  --retry-delay <seconds>    失败后重试等待秒数，默认 \(BLEDefaults.retryDelay)
  --help                     显示帮助
"""

private func parseArguments(_ arguments: [String]) throws -> ClientConfig {
    var config = ClientConfig()
    var mode: CommandMode = .writeData(BLEDefaults.data)
    var explicitUUID: String?
    var index = 0

    func nextValue(for option: String) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw CLIError.missingValue(option)
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--help", "-h":
            throw CLIError.help
        case "--name":
            config.deviceName = try nextValue(for: argument)
        case "--data":
            mode = .writeData(try nextValue(for: argument))
        case "--service-uuid":
            config.serviceUUID = try nextValue(for: argument)
        case "--uuid":
            explicitUUID = try nextValue(for: argument)
        case "--scan-timeout":
            let value = try nextValue(for: argument)
            guard let number = Double(value) else {
                throw CLIError.invalidNumber(argument, value)
            }
            config.scanTimeout = number
        case "--scan-rounds":
            let value = try nextValue(for: argument)
            guard let number = Int(value) else {
                throw CLIError.invalidNumber(argument, value)
            }
            config.scanRounds = number
        case "--cache-path":
            config.cachePath = try nextValue(for: argument)
        case "--no-cache":
            config.useCache = false
        case "--connect-retries":
            let value = try nextValue(for: argument)
            guard let number = Int(value) else {
                throw CLIError.invalidNumber(argument, value)
            }
            config.connectRetries = number
        case "--client-timeout":
            let value = try nextValue(for: argument)
            guard let number = Double(value) else {
                throw CLIError.invalidNumber(argument, value)
            }
            config.clientTimeout = number
        case "--retry-delay":
            let value = try nextValue(for: argument)
            guard let number = Double(value) else {
                throw CLIError.invalidNumber(argument, value)
            }
            config.retryDelay = number
        case "sync-time":
            mode = .syncTime
        default:
            throw CLIError.unknownOption(argument)
        }
        index += 1
    }

    switch mode {
    case .writeData(let value):
        do {
            config.payload = try parsePayload(value)
        } catch {
            throw CLIError.invalidPayload(String(describing: error))
        }
        config.characteristicUUID = resolveCharacteristicUUID(explicitUUID, defaultUUID: BLEDefaults.ledCharacteristicUUID)
    case .syncTime:
        let timestamp = currentUnixTimestamp()
        guard timestamp >= 0 else {
            throw CLIError.invalidPayload(String(describing: PayloadError.negativeTimestamp(timestamp)))
        }
        config.payload = buildTimestampPayload(unixTimeSeconds: timestamp)
        config.characteristicUUID = resolveCharacteristicUUID(explicitUUID, defaultUUID: BLEDefaults.timeCharacteristicUUID)
        log("同步电脑时间戳: \(timestamp)")
    }

    config.scanTimeout = max(1.0, config.scanTimeout)
    config.scanRounds = max(1, config.scanRounds)
    config.connectRetries = max(1, config.connectRetries)
    config.clientTimeout = max(0.5, config.clientTimeout)
    config.retryDelay = max(0.0, config.retryDelay)
    return config
}

private func resolveCharacteristicUUID(_ explicitUUID: String?, defaultUUID: String) -> String? {
    guard let explicitUUID else {
        return defaultUUID
    }
    return explicitUUID.isEmpty ? nil : explicitUUID
}

private struct SeenPeripheral {
    var peripheral: CBPeripheral
    var advertisementData: [String: Any]
}

private struct BLEWriteRequest {
    var characteristicUUID: String
    var payload: Data
    var purpose: String
    var timeSyncUnixSeconds: Int64?
    var isRequired: Bool
}

private struct RuntimeError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

private func currentUnixTimestampFromPayload(_ payload: Data) -> Int64? {
    guard payload.count == MemoryLayout<UInt64>.size else {
        return nil
    }

    var value: UInt64 = 0
    for (index, byte) in payload.enumerated() {
        value |= UInt64(byte) << UInt64(index * 8)
    }
    return Int64(value)
}

@MainActor
private final class BLEClientRunner: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private let config: ClientConfig
    private let completion: (Int32) -> Void
    private var central: CBCentralManager?
    private var cache: DeviceCache
    private var finished = false
    private var activePeripheral: CBPeripheral?
    private var activeAttemptFailure: (() -> Void)?
    private var activeDisplayName = ""
    private var phaseTimer: DispatchSourceTimer?
    private var disconnectTimer: DispatchSourceTimer?
    private var pendingDisconnectCompletion: (() -> Void)?
    private var scanTimer: DispatchSourceTimer?
    private var seenPeripherals: [UUID: SeenPeripheral] = [:]
    private var discoveredCharacteristics: [CBCharacteristic] = []
    private var discoveredCharacteristicsByUUID: [String: CBCharacteristic] = [:]
    private var pendingWrites: [BLEWriteRequest] = []
    private var activeWriteRequest: BLEWriteRequest?
    private var activeWritePlanUnixSeconds: Int64?
    private var pendingServiceDiscoveries = 0
    private var scanAttempt = 0
    private var scanRound = 0
    private var scanDeadline = Date()

    init(config: ClientConfig, completion: @escaping (Int32) -> Void) {
        self.config = config
        self.completion = completion
        self.cache = DeviceCache.load(from: config.cachePath)
        super.init()
    }

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startConnectionFlow()
        case .unsupported:
            log("这台 Mac 不支持 BLE。")
            finish(2)
        case .unauthorized:
            log("没有蓝牙权限。请在 macOS 系统设置里允许运行该程序的终端访问蓝牙。")
            finish(2)
        case .poweredOff:
            log("蓝牙未打开。")
            finish(1)
        case .resetting, .unknown:
            log("蓝牙状态暂不可用: \(central.state.rawValue)")
        @unknown default:
            log("未知蓝牙状态: \(central.state.rawValue)")
            finish(1)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        seenPeripherals[peripheral.identifier] = SeenPeripheral(
            peripheral: peripheral,
            advertisementData: advertisementData
        )

        guard peripheralMatchesTarget(peripheral, advertisementData: advertisementData) else {
            return
        }

        stopScanTimer()
        central.stopScan()

        let foundName = displayName(peripheral, advertisementData: advertisementData) ?? config.deviceName
        log("找到设备: \(foundName) (\(peripheral.identifier.uuidString))")
        remember(peripheral: peripheral, name: foundName)

        connectAndWrite(peripheral: peripheral, displayName: foundName) { [weak self] in
            self?.handleScannedConnectionFailure()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isActive(peripheral) else {
            return
        }

        log("已连接到 \(activeDisplayName)")
        startPhaseTimeout("发现服务超时") { [weak self] in
            self?.failActiveAttempt("发现服务超时")
        }
        discoveredCharacteristics.removeAll()
        discoveredCharacteristicsByUUID.removeAll()
        pendingWrites.removeAll()
        activeWriteRequest = nil
        activeWritePlanUnixSeconds = nil
        pendingServiceDiscoveries = 0
        log("正在发现目标服务: \(config.serviceUUID)")
        peripheral.discoverServices([CBUUID(string: config.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard isActive(peripheral) else {
            return
        }
        if pendingDisconnectCompletion != nil {
            completePendingDisconnect()
            return
        }
        failActiveAttempt("连接失败: \(describe(error))")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard isActive(peripheral) else {
            return
        }

        if pendingDisconnectCompletion != nil {
            completePendingDisconnect()
            return
        }

        if let error {
            failActiveAttempt("连接已断开: \(describe(error))")
            return
        }

        activePeripheral = nil
        activeAttemptFailure = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isActive(peripheral) else {
            return
        }
        if let error {
            failActiveAttempt("发现服务失败: \(describe(error))")
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            failActiveAttempt("未发现 GATT 服务")
            return
        }

        let serviceUUIDs = services.map { $0.uuid.uuidString }.joined(separator: ", ")
        log("目标服务发现完成: \(serviceUUIDs)")
        pendingServiceDiscoveries = services.count
        let writePlanUnixSeconds = currentUnixTimestamp()
        activeWritePlanUnixSeconds = writePlanUnixSeconds
        let characteristicUUIDs = characteristicUUIDsToDiscover(
            targetCharacteristicUUID: config.characteristicUUID,
            lastTimeSyncUnixSeconds: cache.lastTimeSync(for: config.deviceName),
            nowUnixSeconds: writePlanUnixSeconds
        ).map { CBUUID(string: $0) }
        startPhaseTimeout("发现特征超时") { [weak self] in
            self?.failActiveAttempt("发现特征超时")
        }
        for service in services {
            log("正在发现固定特征集合: \(characteristicUUIDs.count) 个")
            peripheral.discoverCharacteristics(characteristicUUIDs, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isActive(peripheral) else {
            return
        }
        if let error {
            failActiveAttempt("发现特征失败: \(describe(error))")
            return
        }

        discoveredCharacteristics.append(contentsOf: service.characteristics ?? [])
        pendingServiceDiscoveries -= 1
        if pendingServiceDiscoveries == 0 {
            log("固定特征发现完成: \(discoveredCharacteristics.count) 个")
            handleDiscoveredCharacteristics(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isActive(peripheral) else {
            return
        }
        if let error {
            if let request = activeWriteRequest, !request.isRequired {
                log("\(request.purpose)写入失败，忽略本次时间缓存更新: \(describe(error))")
                activeWriteRequest = nil
                pendingWrites.removeAll()
                completeActiveAttempt()
                return
            }
            failActiveAttempt("写入失败: \(describe(error))")
            return
        }
        log("收到写入响应: \(characteristic.uuid.uuidString)")
        completeCurrentWrite(characteristic)
        writeNextPendingValue(on: peripheral)
    }

    private func startConnectionFlow() {
        if config.useCache,
           let central,
           let peripheral = retrieveConnectedTargetPeripheral(from: central) {
            log("发现系统已连接设备 '\(config.deviceName)': \(peripheral.identifier.uuidString)")
            connectSystemConnected(peripheral: peripheral, attempt: 1)
            return
        }

        if config.useCache,
           let cachedIdentifier = cache.identifier(for: config.deviceName),
           let uuid = UUID(uuidString: cachedIdentifier),
           let central {
            let peripherals = central.retrievePeripherals(withIdentifiers: [uuid])
            if let peripheral = peripherals.first {
                log("先尝试使用缓存 identifier 连接 '\(config.deviceName)': \(cachedIdentifier)")
                connectCached(peripheral: peripheral, attempt: 1)
                return
            }
            log("缓存 identifier 未被 CoreBluetooth 找回，回退到扫描: \(cachedIdentifier)")
        }

        beginScanAttempts()
    }

    private func retrieveConnectedTargetPeripheral(from central: CBCentralManager) -> CBPeripheral? {
        let serviceUUID = CBUUID(string: config.serviceUUID)
        let connectedPeripherals = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
        let cachedIdentifier = cache.identifier(for: config.deviceName)

        return connectedPeripherals.first { peripheral in
            if peripheral.identifier.uuidString == cachedIdentifier {
                return true
            }
            if let name = peripheral.name, name.contains(config.deviceName) {
                return true
            }
            return false
        }
    }

    private func connectSystemConnected(peripheral: CBPeripheral, attempt: Int) {
        guard !finished else {
            return
        }
        if config.connectRetries > 1 {
            log("系统已连接设备本地连接尝试 \(attempt)/\(config.connectRetries)")
        }

        connectAndWrite(peripheral: peripheral, displayName: config.deviceName) { [weak self] in
            guard let self else {
                return
            }
            if attempt < self.config.connectRetries {
                log("系统已连接设备本地连接未完成，稍后重试。")
                self.afterRetryDelay {
                    self.connectSystemConnected(peripheral: peripheral, attempt: attempt + 1)
                }
            } else {
                log("系统已连接设备多次本地连接未完成，回退到缓存 identifier。")
                self.tryCachedIdentifierOrScan()
            }
        }
    }

    private func tryCachedIdentifierOrScan() {
        if config.useCache,
           let cachedIdentifier = cache.identifier(for: config.deviceName),
           let uuid = UUID(uuidString: cachedIdentifier),
           let central {
            let peripherals = central.retrievePeripherals(withIdentifiers: [uuid])
            if let peripheral = peripherals.first {
                log("先尝试使用缓存 identifier 连接 '\(config.deviceName)': \(cachedIdentifier)")
                connectCached(peripheral: peripheral, attempt: 1)
                return
            }
            log("缓存 identifier 未被 CoreBluetooth 找回，回退到扫描: \(cachedIdentifier)")
        }

        beginScanAttempts()
    }

    private func connectCached(peripheral: CBPeripheral, attempt: Int) {
        guard !finished else {
            return
        }
        if config.connectRetries > 1 {
            log("缓存 identifier 连接尝试 \(attempt)/\(config.connectRetries)")
        }

        connectAndWrite(peripheral: peripheral, displayName: config.deviceName) { [weak self] in
            guard let self else {
                return
            }
            if attempt < self.config.connectRetries {
                log("缓存 identifier 连接未完成，稍后重试。")
                self.afterRetryDelay {
                    self.connectCached(peripheral: peripheral, attempt: attempt + 1)
                }
            } else {
                log("缓存 identifier 多次连接未完成，回退到扫描。")
                self.beginScanAttempts()
            }
        }
    }

    private func beginScanAttempts() {
        scanAttempt = 1
        startScanAttempt()
    }

    private func startScanAttempt() {
        guard !finished else {
            return
        }
        if config.connectRetries > 1 {
            log("扫描/连接尝试 \(scanAttempt)/\(config.connectRetries)")
        }
        seenPeripherals.removeAll()
        scanRound = 0
        scanDeadline = Date().addingTimeInterval(config.scanTimeout)
        startNextScanRound()
    }

    private func startNextScanRound() {
        guard !finished, let central else {
            return
        }

        let remaining = scanDeadline.timeIntervalSinceNow
        if remaining <= 0 {
            completeScanAttemptWithoutTarget()
            return
        }

        scanRound += 1
        let roundTimeout = min(max(1.0, config.scanTimeout / Double(config.scanRounds)), remaining)
        log("正在扫描广播服务 \(config.serviceUUID) 且名称包含 '\(config.deviceName)' 的设备... 第 \(scanRound)/\(config.scanRounds) 轮")

        central.scanForPeripherals(
            withServices: [CBUUID(string: config.serviceUUID)],
            options: nil
        )

        scanTimer = DispatchSource.makeTimerSource(queue: .main)
        scanTimer?.schedule(deadline: .now() + roundTimeout)
        scanTimer?.setEventHandler { [weak self] in
            self?.finishScanRound()
        }
        scanTimer?.resume()
    }

    private func finishScanRound() {
        guard !finished, let central else {
            return
        }

        central.stopScan()
        stopScanTimer()

        if scanRound < config.scanRounds, scanDeadline.timeIntervalSinceNow > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.startNextScanRound()
            }
            return
        }

        if let seen = seenPeripherals.values.first(where: {
            peripheralMatchesTarget($0.peripheral, advertisementData: $0.advertisementData)
        }) {
            centralManager(
                central,
                didDiscover: seen.peripheral,
                advertisementData: seen.advertisementData,
                rssi: 0
            )
            return
        }

        completeScanAttemptWithoutTarget()
    }

    private func completeScanAttemptWithoutTarget() {
        if scanAttempt < config.connectRetries {
            log("本轮未找到目标设备，稍后重试。")
            scanAttempt += 1
            afterRetryDelay {
                self.startScanAttempt()
            }
            return
        }

        log("未找到名称包含 '\(config.deviceName)' 的设备。当前扫描到：")
        listSeenDevices()
        finish(1)
    }

    private func handleScannedConnectionFailure() {
        guard !finished else {
            return
        }
        if scanAttempt < config.connectRetries {
            log("连接或写入未完成，稍后重新扫描并重试。")
            scanAttempt += 1
            afterRetryDelay {
                self.startScanAttempt()
            }
            return
        }

        log("多次尝试后仍未完成连接或写入。")
        log("建议确认 ESP32 正在广播、设备名一致、手机没有占用连接、UUID 与固件一致。")
        finish(1)
    }

    private func connectAndWrite(peripheral: CBPeripheral, displayName: String, onFailure: @escaping () -> Void) {
        guard let central else {
            finish(1)
            return
        }

        stopPhaseTimer()
        activePeripheral = peripheral
        activeDisplayName = displayName
        activeAttemptFailure = onFailure
        peripheral.delegate = self

        startPhaseTimeout("连接超时") { [weak self] in
            self?.failActiveAttempt("连接超时")
        }
        central.connect(peripheral, options: nil)
    }

    private func handleDiscoveredCharacteristics(_ peripheral: CBPeripheral) {
        stopPhaseTimer()

        discoveredCharacteristicsByUUID = Dictionary(
            uniqueKeysWithValues: discoveredCharacteristics.map {
                ($0.uuid.uuidString.lowercased(), $0)
            }
        )

        guard let characteristicUUID = config.characteristicUUID else {
            log("未指定特征 UUID，以下为所有可写特征：")
            printWritableCharacteristics()
            completeActiveAttempt()
            return
        }

        do {
            pendingWrites = try buildWriteRequests(targetCharacteristicUUID: characteristicUUID)
        } catch {
            failActiveAttempt(String(describing: error))
            return
        }

        writeNextPendingValue(on: peripheral)
    }

    private func buildWriteRequests(targetCharacteristicUUID: String) throws -> [BLEWriteRequest] {
        var requests: [BLEWriteRequest] = []
        let normalizedTargetUUID = targetCharacteristicUUID.lowercased()
        let normalizedTimeUUID = BLEDefaults.timeCharacteristicUUID.lowercased()
        let now = activeWritePlanUnixSeconds ?? currentUnixTimestamp()
        let uuidOrder = writeCharacteristicUUIDOrder(
            targetCharacteristicUUID: targetCharacteristicUUID,
            lastTimeSyncUnixSeconds: cache.lastTimeSync(for: config.deviceName),
            nowUnixSeconds: now
        )

        guard discoveredCharacteristicsByUUID[normalizedTargetUUID] != nil else {
            log("未找到特征 UUID: \(targetCharacteristicUUID)")
            log("当前所有可写特征：")
            printWritableCharacteristics()
            throw RuntimeError("目标特征不存在")
        }

        for uuid in uuidOrder {
            let normalizedUUID = uuid.lowercased()
            guard discoveredCharacteristicsByUUID[normalizedUUID] != nil else {
                throw RuntimeError("需要写入特征，但未找到 UUID: \(uuid)")
            }

            if normalizedUUID == normalizedTargetUUID {
                requests.append(BLEWriteRequest(
                    characteristicUUID: targetCharacteristicUUID,
                    payload: config.payload,
                    purpose: normalizedTargetUUID == normalizedTimeUUID ? "同步时间" : "写入指令",
                    timeSyncUnixSeconds: normalizedTargetUUID == normalizedTimeUUID ? currentUnixTimestampFromPayload(config.payload) : nil,
                    isRequired: true
                ))
            } else if normalizedUUID == normalizedTimeUUID {
                log("上次同步时间超过 1 小时或无记录，指令写入后同步电脑时间戳: \(now)")
                requests.append(BLEWriteRequest(
                    characteristicUUID: BLEDefaults.timeCharacteristicUUID,
                    payload: buildTimestampPayload(unixTimeSeconds: now),
                    purpose: "同步时间",
                    timeSyncUnixSeconds: now,
                    isRequired: false
                ))
            }
        }

        return requests
    }

    private func writeNextPendingValue(on peripheral: CBPeripheral) {
        guard !pendingWrites.isEmpty else {
            completeActiveAttempt()
            return
        }

        let request = pendingWrites.removeFirst()
        let normalizedUUID = request.characteristicUUID.lowercased()
        guard let characteristic = discoveredCharacteristicsByUUID[normalizedUUID] else {
            failActiveAttempt("未找到特征 UUID: \(request.characteristicUUID)")
            return
        }

        if characteristic.properties.contains(.write) {
            activeWriteRequest = request
            startPhaseTimeout("写入超时") { [weak self] in
                self?.failActiveAttempt("写入超时")
            }
            log("开始\(request.purpose): \(characteristic.uuid.uuidString) \(formatPayload(request.payload))")
            peripheral.writeValue(request.payload, for: characteristic, type: .withResponse)
        } else if characteristic.properties.contains(.writeWithoutResponse) {
            if !request.isRequired {
                log("\(request.purpose)使用无响应写入，无法确认成功，忽略本次时间缓存更新")
                activeWriteRequest = nil
                pendingWrites.removeAll()
                completeActiveAttempt()
                return
            }
            activeWriteRequest = request
            log("开始\(request.purpose)(无响应): \(characteristic.uuid.uuidString) \(formatPayload(request.payload))")
            peripheral.writeValue(request.payload, for: characteristic, type: .withoutResponse)
            completeCurrentWrite(characteristic)
            writeNextPendingValue(on: peripheral)
        } else {
            log("目标特征不可写: \(characteristic.uuid.uuidString)")
            failActiveAttempt("目标特征不可写")
        }
    }

    private func completeCurrentWrite(_ characteristic: CBCharacteristic) {
        stopPhaseTimer()
        let request = activeWriteRequest
        activeWriteRequest = nil
        log("\(request?.purpose ?? "数据")已写入 \(characteristic.uuid.uuidString): \(formatPayload(request?.payload ?? Data()))")

        guard let timestamp = request?.timeSyncUnixSeconds else {
            return
        }
        cache.setLastTimeSync(unixTimeSeconds: timestamp, for: config.deviceName)
        do {
            try cache.save(to: config.cachePath)
        } catch {
            log("缓存同步时间戳失败，但会继续: \(describe(error))")
        }
    }

    private func completeActiveAttempt() {
        disconnectActivePeripheral {
            self.finish(0)
        }
    }

    private func failActiveAttempt(_ message: String) {
        stopPhaseTimer()
        log(message)
        let failure = activeAttemptFailure
        disconnectActivePeripheral {
            failure?()
        }
    }

    private func disconnectActivePeripheral(_ completion: @escaping () -> Void) {
        stopPhaseTimer()

        guard let peripheral = activePeripheral else {
            activeAttemptFailure = nil
            completion()
            return
        }

        pendingDisconnectCompletion = completion

        if peripheral.state == .disconnected {
            completePendingDisconnect()
            return
        }

        startDisconnectFallbackTimer()
        central?.cancelPeripheralConnection(peripheral)
    }

    private func completePendingDisconnect() {
        stopDisconnectTimer()
        let completion = pendingDisconnectCompletion
        pendingDisconnectCompletion = nil
        activePeripheral = nil
        activeAttemptFailure = nil
        completion?()
    }

    private func startDisconnectFallbackTimer() {
        stopDisconnectTimer()
        disconnectTimer = DispatchSource.makeTimerSource(queue: .main)
        disconnectTimer?.schedule(deadline: .now() + 0.5)
        disconnectTimer?.setEventHandler { [weak self] in
            self?.completePendingDisconnect()
        }
        disconnectTimer?.resume()
    }

    private func stopDisconnectTimer() {
        disconnectTimer?.cancel()
        disconnectTimer = nil
    }

    private func cancelActivePeripheral() {
        if let peripheral = activePeripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    private func startPhaseTimeout(_ message: String, handler: @escaping () -> Void) {
        stopPhaseTimer()
        phaseTimer = DispatchSource.makeTimerSource(queue: .main)
        phaseTimer?.schedule(deadline: .now() + config.clientTimeout)
        phaseTimer?.setEventHandler(handler: handler)
        phaseTimer?.resume()
    }

    private func stopPhaseTimer() {
        phaseTimer?.cancel()
        phaseTimer = nil
    }

    private func stopScanTimer() {
        scanTimer?.cancel()
        scanTimer = nil
    }

    private func afterRetryDelay(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + config.retryDelay, execute: work)
    }

    private func remember(peripheral: CBPeripheral, name: String?) {
        guard config.useCache else {
            return
        }

        cache.set(identifier: peripheral.identifier.uuidString, name: name, for: config.deviceName)
        do {
            try cache.save(to: config.cachePath)
        } catch {
            log("缓存设备 identifier 失败，但会继续连接: \(describe(error))")
        }
    }

    private func peripheralMatchesTarget(_ peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        guard let name = displayName(peripheral, advertisementData: advertisementData) else {
            return false
        }
        return name.contains(config.deviceName)
    }

    private func displayName(_ peripheral: CBPeripheral, advertisementData: [String: Any]) -> String? {
        if let name = peripheral.name, !name.isEmpty {
            return name
        }
        if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String, !localName.isEmpty {
            return localName
        }
        return nil
    }

    private func listSeenDevices() {
        if seenPeripherals.isEmpty {
            log("  没有扫描到任何 BLE 设备")
            return
        }

        for seen in seenPeripherals.values.sorted(by: {
            ($0.peripheral.name ?? $0.peripheral.identifier.uuidString) < ($1.peripheral.name ?? $1.peripheral.identifier.uuidString)
        }) {
            let name = displayName(seen.peripheral, advertisementData: seen.advertisementData) ?? "<无名称>"
            log("  - \(name) (\(seen.peripheral.identifier.uuidString))")
        }
    }

    private func printWritableCharacteristics() {
        let writable = discoveredCharacteristics.filter {
            $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
        }

        if writable.isEmpty {
            log("  未发现可写特征")
            return
        }

        for characteristic in writable {
            log("  - \(characteristic.uuid.uuidString)  (\(describe(characteristic.properties)))")
        }
    }

    private func isActive(_ peripheral: CBPeripheral) -> Bool {
        activePeripheral?.identifier == peripheral.identifier
    }

    private func finish(_ code: Int32) {
        guard !finished else {
            return
        }
        finished = true
        stopPhaseTimer()
        stopDisconnectTimer()
        stopScanTimer()
        central?.stopScan()
        cancelActivePeripheral()
        completion(code)
    }

    private func describe(_ error: Error?) -> String {
        guard let error else {
            return "<无详细错误>"
        }
        return "\(type(of: error)): \(error.localizedDescription)"
    }

    private func describe(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.writeWithoutResponse) { names.append("write-without-response") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        return names.isEmpty ? "unknown" : names.joined(separator: ", ")
    }

    private func formatPayload(_ data: Data) -> String {
        let bytes = data.map { String(format: "0x%02x", $0) }.joined(separator: " ")
        return "Data([\(bytes)])"
    }
}

do {
    let config = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    let runner = BLEClientRunner(config: config) { code in
        Foundation.exit(code)
    }
    runner.start()
    RunLoop.main.run()
} catch CLIError.help {
    print(usageText)
    Foundation.exit(0)
} catch {
    log(String(describing: error))
    log("使用 --help 查看参数。")
    Foundation.exit(2)
}
