// swift-tools-version: 6.2
// OfflineChecks: Swift Testing over code that lives in the app's executable targets (the app, the helper, the services
// worker), which no package exports. Each fixture target under Sources/ holds symlinks to the production files it
// tests, compiled whole, beside the stand-ins for what those files reach into (the hub classes, the C library);
// OfflineTests drives them. No window is ordered in, no emulator runs. The Unit test plan runs it.
import PackageDescription

let settings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(name: "OfflineChecks", platforms: [.macOS("14.4")],
    dependencies: [
        .package(path: "../../Packages/LightTouchCore"),
        .package(path: "../../Packages/HostRuntime"),
        .package(path: "../../Packages/DeviceRuntime"),
        .package(path: "../../Packages/DeviceServices"),
        .package(path: "../../Packages/FirmwareKit"),
    ],
    targets: [
        // The app's views and windows that stand alone: production files whole, with the stand-ins in StandIns.swift.
        .target(name: "AppViews", dependencies: [.product(name: "LightTouchCore", package: "LightTouchCore"), .product(name: "HostRuntime", package: "HostRuntime"),
                                                 .product(name: "HostServiceClient", package: "DeviceServices"), .product(name: "HostServiceWire", package: "DeviceServices")],
                swiftSettings: settings),
        // The sidebar and the Add Device sheet over a stand-in session host, jobs and library.
        .target(name: "Sidebar", dependencies: [.product(name: "LightTouchCore", package: "LightTouchCore"), .product(name: "HostRuntime", package: "HostRuntime")],
                swiftSettings: settings),
        // The real main menu over no-op action targets.
        .target(name: "Menus", dependencies: [.product(name: "LightTouchCore", package: "LightTouchCore"), .product(name: "HostRuntime", package: "HostRuntime")],
                swiftSettings: settings),
        // A private home and app state for the test process (LightTouchCore's own, Tests/TestIsolation).
        .target(name: "TestIsolation"),
        .testTarget(name: "OfflineTests", dependencies: ["AppViews", "Menus", "Sidebar", "TestIsolation"], swiftSettings: settings),
    ],
    swiftLanguageModes: [.v5])
