// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VirtualLocation",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.executable(name: "MacHost", targets: ["MacHost"])],
    targets: [
        .target(name: "ScenarioKit"),
        .target(name: "RemoteControl"),
        .target(name: "PlaceKit", dependencies: ["ScenarioKit"]),
        .target(name: "HostSession", dependencies: ["ScenarioKit"]),
        .target(name: "DeviceBackend", dependencies: ["ScenarioKit", "HostSession"]),
        .target(
            name: "ModernHelper",
            path: "Host/ModernBackend",
            exclude: ["README.md", "requirements.txt", "portable_location.py"],
            sources: ["ModernHelperResource.swift"],
            resources: [.copy("modern_backend.py")]
        ),
        .executableTarget(name: "QtBluetoothBridge", dependencies: ["DeviceBackend", "ScenarioKit"]),
        .executableTarget(
            name: "MacHost",
            dependencies: ["ScenarioKit", "HostSession", "DeviceBackend", "ModernHelper", "RemoteControl", "PlaceKit"]
        ),
        .target(name: "MobileConnectionModel", dependencies: ["RemoteControl", "ScenarioKit"],
                path: "Apps/Mobile/Mobile", exclude: ["Assets.xcassets", "Diagnostics", "Info.plist", "MobileApp.swift", "MobileBluetoothReceiver.swift"],
                sources: ["MobileModel.swift"]),
        .testTarget(name: "MobileConnectionTests", dependencies: ["MobileConnectionModel", "RemoteControl"]),
        .testTarget(name: "PlaceKitTests", dependencies: ["PlaceKit", "ScenarioKit"]),
        .testTarget(name: "ScenarioKitTests", dependencies: ["ScenarioKit"]),
        .testTarget(name: "HostSessionTests", dependencies: ["HostSession", "ScenarioKit"]),
        .testTarget(
            name: "DeviceBackendTests",
            dependencies: ["DeviceBackend", "HostSession", "ScenarioKit"]
        ),
        .testTarget(name: "MacHostTests", dependencies: ["MacHost", "HostSession", "ScenarioKit", "RemoteControl"])
    ]
)
