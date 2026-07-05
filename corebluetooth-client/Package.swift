// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreBluetoothClient",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "esp32-ble-corebluetooth", targets: ["ESP32BLECoreBluetooth"])
    ],
    targets: [
        .target(name: "CoreBluetoothSupport"),
        .executableTarget(
            name: "ESP32BLECoreBluetooth",
            dependencies: ["CoreBluetoothSupport"]
        ),
        .testTarget(
            name: "CoreBluetoothSupportTests",
            dependencies: ["CoreBluetoothSupport"]
        )
    ]
)
