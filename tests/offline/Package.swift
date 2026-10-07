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
        // Small AppKit controls: the Apps pane's message, the horizon button, the record button, the Apps rows.
        .target(name: "Controls", dependencies: [.product(name: "LightTouchCore", package: "LightTouchCore")], swiftSettings: settings),
        .testTarget(name: "OfflineTests", dependencies: ["Controls"], swiftSettings: settings),
    ],
    swiftLanguageModes: [.v5])
