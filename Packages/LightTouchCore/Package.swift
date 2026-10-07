// swift-tools-version: 6.2
// LightTouchCore: the app's logic that needs no window: the device library and catalog, device records and boot
// pieces, the install and media pipelines, capture naming, the session's state machines and the input and zoom
// math. The app links it; LightTouchCoreTests (Swift Testing) is the Unit test plan's suite. Built like the app:
// MainActor by default with approachable concurrency.
import PackageDescription

let settings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(name: "LightTouchCore", platforms: [.macOS("14.4")],
    products: [.library(name: "LightTouchCore", type: .static, targets: ["LightTouchCore"])],
    dependencies: [
        .package(path: "../HostRuntime"),
        .package(path: "../FirmwareKit"),
        .package(path: "../DeviceServices"),
    ],
    targets: [
        .target(name: "LightTouchCore", dependencies: [
            .product(name: "HostRuntime", package: "HostRuntime"),
            .product(name: "FirmwareSchema", package: "FirmwareKit"),
            .product(name: "HostServiceWire", package: "DeviceServices"),
            .product(name: "HostServiceClient", package: "DeviceServices"),
        ], swiftSettings: settings),
        .testTarget(name: "LightTouchCoreTests", dependencies: ["LightTouchCore"], swiftSettings: settings),
    ],
    swiftLanguageModes: [.v5])
