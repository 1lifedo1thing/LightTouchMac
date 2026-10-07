import AppKit
import SwiftUI
import Testing

@testable import AppViews
@testable import LightTouchCore

extension SharedState {
    /// The Store's filter pull-down and the version sheet as AppKit draws them, over the recorded Legacy Store responses
    /// in tests/fixtures/store-filter (LegacyStoreStub). The rules are CatalogFilterTests' and CatalogDetailsModelTests'.
    /// Filter (real CatalogFilterButton through its menu, a throwaway defaults suite): the iPod's family choice is dimmed
    /// and its Show Unavailable Apps toggle live and checked; a toggle reports and checks off; the iPad offers both
    /// families, checks iPad Apps Only when chosen, and a new button reads the saved choices back. Sheet (real
    /// CatalogDetailsView): fits its content for a compatible and an incompatible copy.
    @Suite struct StoreUITests {
        nonisolated static func server(_ request: URLComponents) -> LegacyStoreStub.Reply {
            var name = [
                "/api/v1/apps/com.playfirst.hoteldash/versions": "versions-hoteldash.json",
                "/api/v1/apps/com.secondarm.taptapdash/versions": "versions-taptapdash.json",
            ][request.path]
            if request.path.hasPrefix("/api/v1/copies/") { name = "copy-" + (request.path as NSString).lastPathComponent + ".json" }
            if request.path == "/api/emulator/apps", request.items["ipa_id"] == "207203" { name = "emulator-207203.json" }
            guard let name, FileManager.default.fileExists(atPath: fixture("store-filter/" + name).path) else { return .error(404) }
            return .file(fixture("store-filter/" + name))
        }

        @Test func filterAndVersionSheet() async throws {
            try await withTemporaryState { state in
                try await LegacyStoreStub.serving(state: state, { Self.server($0) }) { try await run() }
            }
        }

        func run() async throws {
            func check(_ ok: Bool, _ what: Comment, sourceLocation: SourceLocation = #_sourceLocation) { #expect(ok, what, sourceLocation: sourceLocation) }
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let fixtures = fixture("store-filter")
            struct Envelope: Decodable { let apps: [CatalogApp] }
            func apps(_ name: String) throws -> [CatalogApp] {
                try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fixtures.appendingPathComponent(name))).apps
            }
            let ipod = try apps("ipod2-3.1.3-dash.json")
            let ipad = try apps("ipad1-3.2-dash.json")
            let suite = "ltm-store-ui-check-\(ProcessInfo.processInfo.processIdentifier)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            // iPod: the family choice dimmed (never hidden); the default shows unavailable apps grayed, the toggle hides them.
            let podButton = CatalogFilterButton(isIPad: false, defaults: defaults)
            let items = podButton.menu!.items
            check(
                items[1...4].allSatisfy { !$0.isHidden } && !items[1].isEnabled && !items[2].isEnabled && items[4].isEnabled
                    && items[4].title == "Show Unavailable Apps", "iPod: family choice dimmed, the toggle live")
            check(items[4].state == .on && podButton.apply(ipod).count == 4, "default: every app, unavailable ones grayed")
            var changes = 0
            podButton.onChange = { changes += 1 }
            podButton.menu!.performActionForItem(at: 4)
            check(changes == 1 && items[4].state == .off && podButton.apply(ipod).count == 2, "toggle reports, checks off and filters")

            // iPad: the family choice, read back with the toggle the iPod saved.
            let padButton = CatalogFilterButton(isIPad: true, defaults: defaults)
            let padItems = padButton.menu!.items
            check(!padButton.filter.showUnavailable, "Show Unavailable persisted")
            check(padItems[1].isEnabled && padItems[2].isEnabled && padItems[1].state == .on, "iPad offers both families, all apps by default")
            padButton.menu!.performActionForItem(at: 2)
            check(padItems[2].state == .on && padItems[1].state == .off && padButton.filter.iPadOnly, "iPad Apps Only checked")
            padButton.menu!.performActionForItem(at: 4)
            check(padButton.apply(ipad).count == 3, "iPad Apps Only with unavailable apps shown")
            let reread = CatalogFilterButton(isIPad: true, defaults: defaults)
            check(reread.filter.iPadOnly && reread.filter.showUnavailable && reread.menu!.items[2].state == .on, "a new button reads both choices back")

            // The version sheet fits its content, for a compatible copy and an incompatible one.
            let hotel = ipod.first { $0.name == "Hotel Dash" }!
            let good = CatalogDetailsModel(
                app: hotel, device: "iPod2,1", deviceOS: "3.1.3", arch: "armv6", installedVersion: "1.10.3",
                canInstall: { true }, install: { _ in })
            await good.load()
            await good.check()
            check(good.canInstallSelection && good.downgradeNote != nil, "the compatible sheet has its copy and note")
            let goodView = NSHostingView(rootView: CatalogDetailsView(model: good))
            check(goodView.fittingSize.height < 360, "sheet fits its content: \(goodView.fittingSize)")
            let dash = try apps("search-86286-ipad1-4.2.1.json")[0]
            let bad = CatalogDetailsModel(
                app: dash, device: "iPad1,1", deviceOS: "4.2.1", arch: "armv7", installedVersion: nil,
                canInstall: { true }, install: { _ in })
            await bad.load()
            await bad.check()
            check(bad.problem != nil, "the incompatible sheet shows its reason")
            let badView = NSHostingView(rootView: CatalogDetailsView(model: bad))
            check(badView.fittingSize.height < 360, "sheet fits its content: \(badView.fittingSize)")
            _ = ("PASS: Store filter pull-down (iPod toggle only, iPad family choice, read back) and the version sheet's fit")
        }

        /// The pane's top row as the inspector lays it out: Installed/Store, then the filter.
        static func strip(_ button: NSPopUpButton) -> NSView {
            let pane = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
            let mode = NSSegmentedControl(labels: ["Installed", "Store"], trackingMode: .selectOne, target: nil, action: nil)
            mode.selectedSegment = 1
            mode.segmentDistribution = .fillEqually
            mode.controlSize = .large
            for view in [mode, button] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                pane.addSubview(view)
            }
            NSLayoutConstraint.activate([
                mode.topAnchor.constraint(equalTo: pane.topAnchor, constant: 6),
                mode.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
                button.leadingAnchor.constraint(equalTo: mode.trailingAnchor, constant: 4),
                button.centerYAnchor.constraint(equalTo: mode.centerYAnchor),
                button.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -6),
                pane.widthAnchor.constraint(equalToConstant: 300), pane.heightAnchor.constraint(equalToConstant: 40),
            ])
            return pane
        }

    }
}
