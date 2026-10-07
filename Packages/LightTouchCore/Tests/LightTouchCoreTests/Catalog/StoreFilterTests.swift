import Foundation
import Testing
@testable import LightTouchCore

/// The Store's filter (CatalogFilter) and version sheet (CatalogDetailsModel) against recorded Legacy Store answers
/// (tests/fixtures/store-filter): Hotel Dash (family 1), Hotel Dash Deluxe (2, iPad only), Diner Dash (1, 2) and
/// Agent Dash (1, 2; needs iOS 4.1) judged for iPod2,1 3.1.3 and iPad1,1 3.2.
struct StoreFilterTests {
    struct Envelope: Decodable { let apps: [CatalogApp] }
    static func apps(_ name: String) throws -> [CatalogApp] {
        try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fixture("store-filter/" + name))).apps
    }
    func names(_ list: [CatalogApp]) -> Set<String> { Set(list.map(\.name)) }

    @Test func iPodShowsUnavailableAppsUntilToldNot() throws {
        let ipod = try Self.apps("ipod2-3.1.3-dash.json")
        var filter = CatalogFilter()
        #expect(filter.apply(ipod, iPad: false).count == 4 && !filter.isActive(iPad: false), "default: every app, unavailable ones greyed")
        filter.showUnavailable = false
        #expect(names(filter.apply(ipod, iPad: false)) == ["Hotel Dash", "Diner Dash"], "iPad-only and too-new apps hidden on the iPod")
        #expect(filter.isActive(iPad: false))
        // The iPad-only choice never narrows an iPod.
        let iPadOnly = CatalogFilter(iPadOnly: true, showUnavailable: true)
        #expect(names(iPadOnly.apply(ipod, iPad: false)) == names(ipod) && !iPadOnly.isActive(iPad: false))
    }

    @Test func iPadFamilyChoice() throws {
        let ipad = try Self.apps("ipad1-3.2-dash.json")
        var filter = CatalogFilter(showUnavailable: false)
        #expect(names(filter.apply(ipad, iPad: true)) == ["Hotel Dash", "Hotel Dash Deluxe", "Diner Dash"], "all families, runnable")
        filter.iPadOnly = true
        #expect(names(filter.apply(ipad, iPad: true)) == ["Hotel Dash Deluxe", "Diner Dash"], "iPad Apps Only drops iPhone-only Hotel Dash")
        filter.showUnavailable = true
        #expect(names(filter.apply(ipad, iPad: true)) == ["Hotel Dash Deluxe", "Diner Dash", "Agent Dash"], "unavailable iPad-capable app shown again")
        #expect(filter.isActive(iPad: true))
    }

    @Test func choicesPersist() throws {
        let suite = "ltm-store-filter-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CatalogFilter.load(defaults) == CatalogFilter(), "fresh defaults: all apps, unavailable shown")
        CatalogFilter(iPadOnly: true, showUnavailable: false).save(defaults)
        #expect(CatalogFilter.load(defaults) == CatalogFilter(iPadOnly: true, showUnavailable: false))
        CatalogFilter(iPadOnly: true, showUnavailable: true).save(defaults)
        #expect(CatalogFilter.load(defaults) == CatalogFilter(iPadOnly: true, showUnavailable: true))
    }
}

extension SharedState {
@Suite struct CatalogDetailsModelTests {
    /// The recorded version lists, copy records and the emulator endpoint's answer for 207203.
    static let server: @Sendable (URLComponents) -> LegacyStoreStub.Reply = { request in
        var name: String? = ["/api/v1/apps/com.playfirst.hoteldash/versions": "versions-hoteldash.json",
                             "/api/v1/apps/com.secondarm.taptapdash/versions": "versions-taptapdash.json"][request.path]
        if request.path.hasPrefix("/api/v1/copies/") { name = "copy-" + request.path.split(separator: "/").last! + ".json" }
        if request.path == "/api/emulator/apps", request.items["ipa_id"] == "207203" { name = "emulator-207203.json" }
        guard let name, FileManager.default.fileExists(atPath: fixture("store-filter/" + name).path) else { return .error(404) }
        return .file(fixture("store-filter/" + name))
    }

    @Test func compatibleCopyOnTheIPod() async throws {
        let hotel = try StoreFilterTests.apps("ipod2-3.1.3-dash.json").first { $0.name == "Hotel Dash" }!
        try await withTemporaryState { state in
            try await LegacyStoreStub.serving(state: state, Self.server) {
                var installed: Int?, closed = false
                let model = CatalogDetailsModel(app: hotel, device: "iPod2,1", deviceOS: "3.1.3", arch: "armv6", installedVersion: "1.10.3",
                                                canInstall: { true }, install: { installed = $0.ipaID })
                model.close = { closed = true }
                await model.load()
                let rows = model.rows ?? []
                #expect(rows.count == 7 && rows.allSatisfy { $0.copy.architectures?.contains("armv6") == true }, "\(rows.map(\.copy.ipa_id))")
                #expect(model.selection == "207203", "the row's own copy selected")
                let own = rows.first { $0.copy.ipa_id == "207203" }!, twin = rows.first { $0.copy.ipa_id == "5635" }!
                #expect(model.title(own) == "1.1.51 · 65.6 MB")
                #expect(model.title(twin).hasSuffix(" · Copy 5635"), "twin copies are numbered")
                await model.check()
                #expect(model.problem == nil && model.canInstallSelection, "\(model.problem ?? "")")
                #expect(model.downgradeNote == "Version 1.10.3 is installed. An older version may not read its data.")
                model.installSelection()
                #expect(installed == 207203 && closed, "Install fetches the revalidated copy and closes the sheet")
            }
        }
    }

    @Test func arm64OnlyAppOnTheIPad() async throws {
        let dash = try StoreFilterTests.apps("search-86286-ipad1-4.2.1.json")[0]
        try await withTemporaryState { state in
            try await LegacyStoreStub.serving(state: state, Self.server) {
                var installs = 0
                let model = CatalogDetailsModel(app: dash, device: "iPad1,1", deviceOS: "4.2.1", arch: "armv7", installedVersion: nil,
                                                canInstall: { true }, install: { _ in installs += 1 })
                await model.load()
                #expect(model.rows?.map(\.copy.ipa_id) == ["86286"], "only the row's own copy")
                await model.check()
                #expect(model.problem == "This copy needs a newer processor than this device has.")
                #expect(!model.canInstallSelection && model.downgradeNote == nil)
                model.installSelection()
                #expect(installs == 0, "an incompatible copy is never installed")
            }
        }
    }
}
}
