import AppKit
import HostRuntime
import Testing

@testable import Display
@testable import LightTouchCore

extension SharedState {
    /// The production DisplayView over a fake link and device (Sources/Display): windows built and never ordered in.
    @Suite struct DisplayTests {
        init() {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            _ = fixtureMachines
        }

        static let n72Model = [
            "Models/N72.usdz": "Models/N72.usdz",
            "shell.png": "LightTouchMac/Assets.xcassets/shell.imageset/shell_opaque.png",
        ]

        /// The flat LCD layer is black-backed, stretched to the cutout, and upscales nearest-neighbor (minification filters).
        @Test(arguments: [Board.n72, .k48, .n45, .n81, .n88]) func lcdLayerMagnifiesNearest(_ profile: Board) {
            let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: profile)
            func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
            let lcds = all(display.layer!).filter {
                $0.backgroundColor == NSColor.black.cgColor && $0.contentsGravity == .resize
            }
            #expect(lcds.count == 1, "expected one LCD layer, found \(lcds.count)")
            #expect(
                lcds.first?.magnificationFilter == .nearest,
                "DisplayView's LCD upscales with \(String(describing: lcds.first?.magnificationFilter.rawValue))"
            )
            #expect(lcds.first?.minificationFilter != .nearest, "DisplayView's LCD minification should filter")
        }

        /// The 3D model's startup: a fast first frame, a slow asset and a slow first frame all reach live 3D; the photo
        /// placeholder never flashes before the model's first second and shows after it while unprepared models stay
        /// invisible; a stalled renderer callback doesn't keep a closed display alive.
        @Test func modelStartupPlaceholderAndLifetime() async throws {
            try await MainBundle.with(Self.n72Model) {
                for scenario in ["fast", "slow asset", "slow frame"] {
                    DeviceModelView.loadingDelay = scenario == "slow asset" ? .milliseconds(1400) : .zero
                    DeviceModelView.preparationDelay =
                        scenario == "slow frame" ? .milliseconds(1400) : .milliseconds(50)
                    DeviceModelView.framesPrepared = 0
                    let started = ContinuousClock.now
                    let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 500, height: 800), profile: .n72)
                    let e = EmulatorController()
                    display.emulator = e
                    let window = NSWindow(
                        contentRect: display.frame,
                        styleMask: [.titled],
                        backing: .buffered,
                        defer: false
                    )
                    window.contentView = display
                    display.needsLayout = true
                    display.layoutSubtreeIfNeeded()
                    let shell = try #require(
                        display.layer!.sublayers!.first { $0.bounds.size == CGSize(width: 737, height: 1318) }
                    )
                    // Sampled every 10 ms: a late wake-up must not skip the placeholder's 1.0-1.4 s window or read the model mid-fade.
                    var placeholderShown = false
                    @MainActor func live() -> Bool {
                        let m = display.subviews.compactMap { $0 as? DeviceModelView }
                        return DeviceModelView.framesPrepared > 0 && m.count == 1 && m[0].alphaValue > 0.99
                            && shell.isHidden
                    }
                    while !live() && ContinuousClock.now - started < .seconds(5) {
                        if !shell.isHidden {
                            #expect(
                                ContinuousClock.now - started >= .seconds(1),
                                "\(scenario): the photo flashed before the model's first chance to render"
                            )
                            if DeviceModelView.framesPrepared == 0 {
                                #expect(
                                    display.subviews.compactMap { $0 as? DeviceModelView }.allSatisfy {
                                        $0.alphaValue == 0
                                    },
                                    "Unprepared models must stay invisible"
                                )
                            }
                            placeholderShown = true
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    if scenario != "fast" { #expect(placeholderShown, "\(scenario): no placeholder within one second") }
                    #expect(
                        live(),
                        "\(scenario): a ready first frame must eventually present live 3D, including after the placeholder"
                    )
                    window.contentView = nil
                }
                DeviceModelView.loadingDelay = .zero
                DeviceModelView.preparationDelay = .seconds(5)
                defer { DeviceModelView.preparationDelay = .milliseconds(50) }
                var closing: DisplayView? = DisplayView(
                    frame: NSRect(x: 0, y: 0, width: 500, height: 800),
                    profile: .n72
                )
                weak let released = closing
                let closingWindow = NSWindow(
                    contentRect: closing!.frame,
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                closingWindow.contentView = closing
                try await Task.sleep(for: .milliseconds(100))
                closingWindow.contentView = nil
                closing = nil
                try await Task.sleep(for: .milliseconds(100))
                #expect(released == nil, "A stalled renderer callback must not retain the closed display")
            }
        }
    }
}
