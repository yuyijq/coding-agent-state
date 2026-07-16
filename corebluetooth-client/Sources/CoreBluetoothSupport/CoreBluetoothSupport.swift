import Foundation

public enum BLEDefaults {
    public static let deviceName = "Mina-15"
    public static let data = "0"
    public static let serviceUUID = "1815"
    public static let ledCharacteristicUUID = "00001525-1212-efde-1523-785feabcd123"
    public static let timeCharacteristicUUID = "01001525-1212-efde-1523-785feabcd123"
    public static let writableCharacteristicUUIDs = [
        ledCharacteristicUUID,
        timeCharacteristicUUID,
    ]
    public static let cachePath = "~/.ks-server-dev/.mina_led"
    public static let connectRetries = 3
    public static let clientTimeout = 3.0
    public static let retryDelay = 0.5
    public static let scanTimeout = 12.0
    public static let scanRounds = 3
    public static let timeSyncIntervalSeconds: Int64 = 3600
    public static let defaultSleepStartHour = 23
    public static let defaultSleepEndHour = 9
    public static let initializationDelaySeconds = 0.05
}

public func deviceNameMatches(_ candidateName: String, targetName: String) -> Bool {
    candidateName == targetName
}

public enum PayloadError: Error, CustomStringConvertible {
    case invalidHexByte(String)
    case byteOutOfRange(String)
    case negativeTimestamp(Int64)
    case timestampOutOfRange(Int64)
    case invalidSleepWindow(Int, Int)

    public var description: String {
        switch self {
        case .invalidHexByte(let value):
            return "无效的十六进制单字节: \(value)"
        case .byteOutOfRange(let value):
            return "数值必须在 0-255 之间: \(value)"
        case .negativeTimestamp(let value):
            return "时间戳不能为负数: \(value)"
        case .timestampOutOfRange(let value):
            return "时间戳超出 4 字节范围: \(value)"
        case .invalidSleepWindow(let startHour, let endHour):
            return "deep sleep 时间段无效: \(startHour)-\(endHour)，小时需为 0-23 且起止不能相同"
        }
    }
}

public struct SleepWindow: Codable, Equatable {
    public let startHour: Int
    public let endHour: Int

    public init(startHour: Int, endHour: Int) throws {
        guard (0...23).contains(startHour),
              (0...23).contains(endHour),
              startHour != endHour else {
            throw PayloadError.invalidSleepWindow(startHour, endHour)
        }

        self.startHour = startHour
        self.endHour = endHour
    }
}

public func defaultSleepWindow() -> SleepWindow {
    try! SleepWindow(
        startHour: BLEDefaults.defaultSleepStartHour,
        endHour: BLEDefaults.defaultSleepEndHour
    )
}

public func parsePayload(_ value: String) throws -> Data {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
        let hex = String(trimmed.dropFirst(2))
        guard let byte = UInt8(hex, radix: 16) else {
            throw PayloadError.invalidHexByte(value)
        }
        return Data([byte])
    }

    if trimmed.allSatisfy({ $0.isNumber }), !trimmed.isEmpty {
        guard let number = Int(trimmed), (0...255).contains(number) else {
            throw PayloadError.byteOutOfRange(value)
        }
        return Data([UInt8(number)])
    }

    return Data(trimmed.utf8)
}

public func buildTimeSyncPayload(unixTimeSeconds: Int64, sleepWindow: SleepWindow) throws -> Data {
    guard unixTimeSeconds >= 0 else {
        throw PayloadError.negativeTimestamp(unixTimeSeconds)
    }
    guard unixTimeSeconds <= Int64(UInt32.max) else {
        throw PayloadError.timestampOutOfRange(unixTimeSeconds)
    }

    var value = UInt32(unixTimeSeconds)
    var payload = Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    payload.append(UInt8(sleepWindow.startHour))
    payload.append(UInt8(sleepWindow.endHour))
    return payload
}

public struct LEDInitializationWrite: Equatable {
    public let payload: Data
    public let delayAfterSeconds: Double?

    public init(payload: Data, delayAfterSeconds: Double?) {
        self.payload = payload
        self.delayAfterSeconds = delayAfterSeconds
    }
}

public struct PlannedBLEWrite: Equatable {
    public let characteristicUUID: String
    public let payload: Data
    public let purpose: String
    public let timeSyncUnixSeconds: Int64?
    public let isRequired: Bool
    public let delayAfterSeconds: Double?

    public init(
        characteristicUUID: String,
        payload: Data,
        purpose: String,
        timeSyncUnixSeconds: Int64?,
        isRequired: Bool,
        delayAfterSeconds: Double? = nil
    ) {
        self.characteristicUUID = characteristicUUID
        self.payload = payload
        self.purpose = purpose
        self.timeSyncUnixSeconds = timeSyncUnixSeconds
        self.isRequired = isRequired
        self.delayAfterSeconds = delayAfterSeconds
    }
}

public func ledInitializationWrites(
    delaySeconds: Double = BLEDefaults.initializationDelaySeconds
) -> [LEDInitializationWrite] {
    let cyclePayloads = [
        Data([0x01]),
        Data([0x02]),
        Data([0x03]),
        Data([0x01]),
        Data([0x02]),
        Data([0x03]),
        Data([0x01]),
        Data([0x02]),
        Data([0x03]),
    ]

    return cyclePayloads.map {
        LEDInitializationWrite(payload: $0, delayAfterSeconds: delaySeconds)
    } + [
        LEDInitializationWrite(payload: Data([0x00]), delayAfterSeconds: nil),
    ]
}

public func initializationWritePlan(
    targetCharacteristicUUID: String,
    lastTimeSyncUnixSeconds: Int64?,
    nowUnixSeconds: Int64,
    sleepWindow: SleepWindow,
    autoTimeSync: Bool = true,
    delaySeconds: Double = BLEDefaults.initializationDelaySeconds
) throws -> [PlannedBLEWrite] {
    var writes = ledInitializationWrites(delaySeconds: delaySeconds).map {
        PlannedBLEWrite(
            characteristicUUID: targetCharacteristicUUID,
            payload: $0.payload,
            purpose: "初始化指令",
            timeSyncUnixSeconds: nil,
            isRequired: true,
            delayAfterSeconds: $0.delayAfterSeconds
        )
    }

    let normalizedTargetUUID = targetCharacteristicUUID.lowercased()
    let normalizedTimeUUID = BLEDefaults.timeCharacteristicUUID.lowercased()
    guard normalizedTargetUUID != normalizedTimeUUID,
          autoTimeSync,
          needsTimeSync(
              lastSyncUnixSeconds: lastTimeSyncUnixSeconds,
              nowUnixSeconds: nowUnixSeconds
          ) else {
        return writes
    }

    writes.append(PlannedBLEWrite(
        characteristicUUID: BLEDefaults.timeCharacteristicUUID,
        payload: try buildTimeSyncPayload(unixTimeSeconds: nowUnixSeconds, sleepWindow: sleepWindow),
        purpose: "同步时间",
        timeSyncUnixSeconds: nowUnixSeconds,
        isRequired: false
    ))
    return writes
}

public func shouldInitializeNamedDevice(
    cacheFileExists: Bool,
    hasNamedCacheEntry: Bool,
    useCache: Bool = true
) -> Bool {
    guard useCache else {
        return false
    }

    return !cacheFileExists || !hasNamedCacheEntry
}

public func shouldCacheIdentifierWhenDiscovered(requiresInitialization: Bool) -> Bool {
    !requiresInitialization
}

public func shouldCacheIdentifierAfterSuccessfulWrites(requiresInitialization: Bool) -> Bool {
    requiresInitialization
}

public func currentUnixTimestamp() -> Int64 {
    Int64(Date().timeIntervalSince1970)
}

public func needsTimeSync(
    lastSyncUnixSeconds: Int64?,
    nowUnixSeconds: Int64,
    intervalSeconds: Int64 = BLEDefaults.timeSyncIntervalSeconds
) -> Bool {
    guard let lastSyncUnixSeconds else {
        return true
    }
    return nowUnixSeconds - lastSyncUnixSeconds >= intervalSeconds
}

public func writeCharacteristicUUIDOrder(
    targetCharacteristicUUID: String,
    lastTimeSyncUnixSeconds: Int64?,
    nowUnixSeconds: Int64,
    autoTimeSync: Bool = true
) -> [String] {
    let normalizedTargetUUID = targetCharacteristicUUID.lowercased()
    let normalizedTimeUUID = BLEDefaults.timeCharacteristicUUID.lowercased()

    guard normalizedTargetUUID != normalizedTimeUUID else {
        return [targetCharacteristicUUID]
    }

    guard autoTimeSync else {
        return [targetCharacteristicUUID]
    }

    if needsTimeSync(
        lastSyncUnixSeconds: lastTimeSyncUnixSeconds,
        nowUnixSeconds: nowUnixSeconds
    ) {
        return [targetCharacteristicUUID, BLEDefaults.timeCharacteristicUUID]
    }

    return [targetCharacteristicUUID]
}

public func characteristicUUIDsToDiscover(
    targetCharacteristicUUID: String?,
    lastTimeSyncUnixSeconds: Int64?,
    nowUnixSeconds: Int64,
    autoTimeSync: Bool = true
) -> [String] {
    guard let targetCharacteristicUUID else {
        return BLEDefaults.writableCharacteristicUUIDs
    }

    return writeCharacteristicUUIDOrder(
        targetCharacteristicUUID: targetCharacteristicUUID,
        lastTimeSyncUnixSeconds: lastTimeSyncUnixSeconds,
        nowUnixSeconds: nowUnixSeconds,
        autoTimeSync: autoTimeSync
    )
}

public func currentLogTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

public func formatLogMessage(_ message: String, timestamp: String? = nil) -> String {
    "[\(timestamp ?? currentLogTimestamp())] \(message)"
}

public func log(_ message: String) {
    print(formatLogMessage(message))
}

public func expandedPath(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else {
        return path
    }

    let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" {
        return homePath
    }
    return homePath + String(path.dropFirst())
}

public struct DeviceCacheEntry: Codable, Equatable {
    public var identifier: String?
    public var address: String?
    public var name: String?
    public var lastTimeSyncUnixSeconds: Int64?
    public var sleepStartHour: Int?
    public var sleepEndHour: Int?

    public init(
        identifier: String? = nil,
        address: String? = nil,
        name: String? = nil,
        lastTimeSyncUnixSeconds: Int64? = nil,
        sleepStartHour: Int? = nil,
        sleepEndHour: Int? = nil
    ) {
        self.identifier = identifier
        self.address = address
        self.name = name
        self.lastTimeSyncUnixSeconds = lastTimeSyncUnixSeconds
        self.sleepStartHour = sleepStartHour
        self.sleepEndHour = sleepEndHour
    }
}

public struct CachedDeviceTarget: Equatable {
    public let cacheKey: String
    public let identifier: String
    public let name: String?
    public let requiresInitialization: Bool

    public init(cacheKey: String, identifier: String, name: String?, requiresInitialization: Bool = false) {
        self.cacheKey = cacheKey
        self.identifier = identifier
        self.name = name
        self.requiresInitialization = requiresInitialization
    }
}

public struct DeviceCache: Codable, Equatable {
    public var entries: [String: DeviceCacheEntry]

    public init(entries: [String: DeviceCacheEntry] = [:]) {
        self.entries = entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        entries = try container.decode([String: DeviceCacheEntry].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }

    public func identifier(for deviceName: String) -> String? {
        entries[deviceName]?.identifier
    }

    public func lastTimeSync(for deviceName: String) -> Int64? {
        entries[deviceName]?.lastTimeSyncUnixSeconds
    }

    public func sleepWindow(for deviceName: String) -> SleepWindow {
        guard let entry = entries[deviceName],
              let startHour = entry.sleepStartHour,
              let endHour = entry.sleepEndHour,
              let sleepWindow = try? SleepWindow(startHour: startHour, endHour: endHour) else {
            return defaultSleepWindow()
        }

        return sleepWindow
    }

    public func cachedConnectionTargets() -> [CachedDeviceTarget] {
        entries.keys.sorted().compactMap { cacheKey in
            guard let identifier = entries[cacheKey]?.identifier,
                  !identifier.isEmpty else {
                return nil
            }

            return CachedDeviceTarget(
                cacheKey: cacheKey,
                identifier: identifier,
                name: entries[cacheKey]?.name
            )
        }
    }

    public mutating func set(identifier: String, name: String?, for deviceName: String) {
        var entry = entries[deviceName] ?? DeviceCacheEntry()
        entry.identifier = identifier
        entry.name = name
        entries[deviceName] = entry
    }

    public mutating func setLastTimeSync(unixTimeSeconds: Int64, for deviceName: String) {
        var entry = entries[deviceName] ?? DeviceCacheEntry()
        entry.lastTimeSyncUnixSeconds = unixTimeSeconds
        entries[deviceName] = entry
    }

    public mutating func setSleepWindow(_ sleepWindow: SleepWindow, for deviceName: String) {
        var entry = entries[deviceName] ?? DeviceCacheEntry()
        entry.sleepStartHour = sleepWindow.startHour
        entry.sleepEndHour = sleepWindow.endHour
        entries[deviceName] = entry
    }

    public static func load(from path: String) -> DeviceCache {
        let url = URL(fileURLWithPath: expandedPath(path))
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(DeviceCache.self, from: data) else {
            return DeviceCache()
        }
        return cache
    }

    public func save(to path: String) throws {
        let url = URL(fileURLWithPath: expandedPath(path))
        let data = try JSONEncoder.bleCacheEncoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

public extension JSONEncoder {
    static var bleCacheEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
