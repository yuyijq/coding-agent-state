import XCTest
@testable import CoreBluetoothSupport

final class CoreBluetoothSupportTests: XCTestCase {
    func testParsePayloadMatchesPythonRules() throws {
        XCTAssertEqual(try parsePayload("0"), Data([0x00]))
        XCTAssertEqual(try parsePayload("3"), Data([0x03]))
        XCTAssertEqual(try parsePayload("0x0f"), Data([0x0f]))
        XCTAssertEqual(try parsePayload("hello"), Data("hello".utf8))
    }

    func testTimeSyncPayloadIsFourByteTimestampPlusSleepWindow() throws {
        XCTAssertEqual(
            try buildTimeSyncPayload(
                unixTimeSeconds: 0x12345678,
                sleepWindow: SleepWindow(startHour: 23, endHour: 9)
            ),
            Data([0x78, 0x56, 0x34, 0x12, 0x17, 0x09])
        )
    }

    func testSleepWindowRejectsInvalidHoursAndEqualEndpoints() {
        XCTAssertThrowsError(try SleepWindow(startHour: -1, endHour: 8))
        XCTAssertThrowsError(try SleepWindow(startHour: 0, endHour: 24))
        XCTAssertThrowsError(try SleepWindow(startHour: 8, endHour: 8))
    }

    func testDefaultSleepWindowIsTwentyThreeToNine() throws {
        XCTAssertEqual(defaultSleepWindow(), try SleepWindow(startHour: 23, endHour: 9))
    }

    func testDefaultServiceUUIDTargetsAutomationIOService() {
        XCTAssertEqual(BLEDefaults.serviceUUID, "1815")
    }

    func testWritableCharacteristicUUIDsAreFixedToLedAndTime() {
        XCTAssertEqual(BLEDefaults.writableCharacteristicUUIDs, [
            BLEDefaults.ledCharacteristicUUID,
            BLEDefaults.timeCharacteristicUUID,
        ])
    }

    func testCharacteristicUUIDsToDiscoverUsesFixedWritableSetWhenListing() {
        XCTAssertEqual(characteristicUUIDsToDiscover(
            targetCharacteristicUUID: nil,
            lastTimeSyncUnixSeconds: nil,
            nowUnixSeconds: 13_600
        ), [
            BLEDefaults.ledCharacteristicUUID,
            BLEDefaults.timeCharacteristicUUID,
        ])
    }

    func testCharacteristicUUIDsToDiscoverOnlyUsesLedWhenTimeSyncIsFresh() {
        XCTAssertEqual(
            characteristicUUIDsToDiscover(
                targetCharacteristicUUID: BLEDefaults.ledCharacteristicUUID,
                lastTimeSyncUnixSeconds: 10_001,
                nowUnixSeconds: 13_600
            ),
            [BLEDefaults.ledCharacteristicUUID]
        )
    }

    func testCharacteristicUUIDsToDiscoverUsesLedAndTimeWhenSyncIsExpired() {
        XCTAssertEqual(
            characteristicUUIDsToDiscover(
                targetCharacteristicUUID: BLEDefaults.ledCharacteristicUUID,
                lastTimeSyncUnixSeconds: 10_000,
                nowUnixSeconds: 13_600
            ),
            [
                BLEDefaults.ledCharacteristicUUID,
                BLEDefaults.timeCharacteristicUUID,
            ]
        )
    }

    func testCharacteristicUUIDsToDiscoverOnlyUsesTimeForSyncTime() {
        XCTAssertEqual(
            characteristicUUIDsToDiscover(
                targetCharacteristicUUID: BLEDefaults.timeCharacteristicUUID,
                lastTimeSyncUnixSeconds: nil,
                nowUnixSeconds: 13_600
            ),
            [BLEDefaults.timeCharacteristicUUID]
        )
    }

    func testDefaultCachePathLivesInHomeDirectory() {
        XCTAssertEqual(BLEDefaults.cachePath, "~/.ble_device_cache.json")
    }

    func testDefaultRetryDelayIsHalfASecond() {
        XCTAssertEqual(BLEDefaults.retryDelay, 0.5)
    }

    func testCachePathExpandsHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            expandedPath("~/.ble_device_cache.json"),
            "\(home)/.ble_device_cache.json"
        )
    }

    func testLogFormatPrefixesTimestampWithMilliseconds() {
        XCTAssertEqual(
            formatLogMessage("正在扫描 BLE 设备", timestamp: "2026-07-05 12:34:56.789"),
            "[2026-07-05 12:34:56.789] 正在扫描 BLE 设备"
        )
    }

    func testCurrentLogTimestampIncludesMilliseconds() {
        XCTAssertTrue(
            currentLogTimestamp().range(
                of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$"#,
                options: .regularExpression
            ) != nil
        )
    }

    func testCacheRoundTripStoresIdentifierAndName() throws {
        var cache = DeviceCache()
        cache.set(identifier: "550E8400-E29B-41D4-A716-446655440000", name: "Mina-15", for: "Mina")
        cache.setLastTimeSync(unixTimeSeconds: 1_788_000_000, for: "Mina")
        cache.setSleepWindow(try SleepWindow(startHour: 23, endHour: 7), for: "Mina")

        let data = try JSONEncoder.bleCacheEncoder.encode(cache)
        let decoded = try JSONDecoder().decode(DeviceCache.self, from: data)

        XCTAssertEqual(decoded.identifier(for: "Mina"), "550E8400-E29B-41D4-A716-446655440000")
        XCTAssertEqual(decoded.entries["Mina"]?.name, "Mina-15")
        XCTAssertEqual(decoded.lastTimeSync(for: "Mina"), 1_788_000_000)
        XCTAssertEqual(decoded.sleepWindow(for: "Mina"), try SleepWindow(startHour: 23, endHour: 7))
    }

    func testCacheSleepWindowFallsBackToDefaultWhenMissingOrInvalid() throws {
        var cache = DeviceCache(entries: [
            "Missing": DeviceCacheEntry(),
            "Invalid": DeviceCacheEntry(sleepStartHour: 9, sleepEndHour: 9),
        ])

        XCTAssertEqual(cache.sleepWindow(for: "Missing"), defaultSleepWindow())
        XCTAssertEqual(cache.sleepWindow(for: "Invalid"), defaultSleepWindow())

        cache.setSleepWindow(try SleepWindow(startHour: 22, endHour: 6), for: "Missing")
        XCTAssertEqual(cache.sleepWindow(for: "Missing"), try SleepWindow(startHour: 22, endHour: 6))
    }

    func testTimeSyncIsNeededWhenMissingOrOlderThanOneHour() {
        XCTAssertTrue(needsTimeSync(lastSyncUnixSeconds: nil, nowUnixSeconds: 10_000))
        XCTAssertTrue(needsTimeSync(lastSyncUnixSeconds: 10_000, nowUnixSeconds: 13_600))
        XCTAssertFalse(needsTimeSync(lastSyncUnixSeconds: 10_001, nowUnixSeconds: 13_600))
    }

    func testLedCommandWriteOrderAppendsTimeSyncAfterCommandWhenExpired() {
        XCTAssertEqual(
            writeCharacteristicUUIDOrder(
                targetCharacteristicUUID: BLEDefaults.ledCharacteristicUUID,
                lastTimeSyncUnixSeconds: 10_000,
                nowUnixSeconds: 13_600
            ),
            [
                BLEDefaults.ledCharacteristicUUID,
                BLEDefaults.timeCharacteristicUUID,
            ]
        )
    }

    func testLedCommandWriteOrderSkipsTimeSyncWhenFresh() {
        XCTAssertEqual(
            writeCharacteristicUUIDOrder(
                targetCharacteristicUUID: BLEDefaults.ledCharacteristicUUID,
                lastTimeSyncUnixSeconds: 10_001,
                nowUnixSeconds: 13_600
            ),
            [BLEDefaults.ledCharacteristicUUID]
        )
    }
}
