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
    public static let cachePath = "~/.ble_device_cache.json"
    public static let connectRetries = 3
    public static let clientTimeout = 3.0
    public static let retryDelay = 0.5
    public static let scanTimeout = 12.0
    public static let scanRounds = 3
    public static let timeSyncIntervalSeconds: Int64 = 3600
}

public enum PayloadError: Error, CustomStringConvertible {
    case invalidHexByte(String)
    case byteOutOfRange(String)
    case negativeTimestamp(Int64)

    public var description: String {
        switch self {
        case .invalidHexByte(let value):
            return "无效的十六进制单字节: \(value)"
        case .byteOutOfRange(let value):
            return "数值必须在 0-255 之间: \(value)"
        case .negativeTimestamp(let value):
            return "时间戳不能为负数: \(value)"
        }
    }
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

public func buildTimestampPayload(unixTimeSeconds: Int64) -> Data {
    var value = UInt64(unixTimeSeconds)
    return Data(bytes: &value, count: MemoryLayout<UInt64>.size)
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
    nowUnixSeconds: Int64
) -> [String] {
    let normalizedTargetUUID = targetCharacteristicUUID.lowercased()
    let normalizedTimeUUID = BLEDefaults.timeCharacteristicUUID.lowercased()

    guard normalizedTargetUUID != normalizedTimeUUID else {
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
    nowUnixSeconds: Int64
) -> [String] {
    guard let targetCharacteristicUUID else {
        return BLEDefaults.writableCharacteristicUUIDs
    }

    return writeCharacteristicUUIDOrder(
        targetCharacteristicUUID: targetCharacteristicUUID,
        lastTimeSyncUnixSeconds: lastTimeSyncUnixSeconds,
        nowUnixSeconds: nowUnixSeconds
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

    public init(
        identifier: String? = nil,
        address: String? = nil,
        name: String? = nil,
        lastTimeSyncUnixSeconds: Int64? = nil
    ) {
        self.identifier = identifier
        self.address = address
        self.name = name
        self.lastTimeSyncUnixSeconds = lastTimeSyncUnixSeconds
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
