import Foundation
import Testing

@testable import FirmwareKit

/// The jailbreak option (firmwarekit create --jailbreak): afc2 beside the stock AFC service.
struct JailbreakTests {
    /// The stock com.apple.afc entries: 1.0's (no unactivated flag), 1.1.4 to 5.x's (afcd at the media folder) and 6.x
    /// to 7.x's (afcd as an XPC service). afc2 is the same old-style entry on every one: afcd still takes --lockdown.
    static var stockAFC: [[String: Any]] {
        [
            ["Label": "com.apple.afc", "ProgramArguments": ["/usr/libexec/afcd", "--lockdown"]],
            [
                "AllowUnactivatedService": true, "Label": "com.apple.afc",
                "ProgramArguments": ["/usr/libexec/afcd", "--lockdown", "-d", "/var/mobile/Media", "-u", "mobile"],
            ],
            [
                "AllowUnactivatedService": true, "Label": "com.apple.afc", "UserName": "mobile",
                "XPCServiceName": "com.apple.afcd",
            ],
        ]
    }

    @Test(arguments: 0..<3) func afc2ServesTheRootBesideTheStockService(era: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-afc2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let services = root.appendingPathComponent(SystemEdits.lockdownServices)
        try FileManager.default.createDirectory(
            at: services.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stock: [String: Any] = ["com.apple.afc": Self.stockAFC[era], "com.apple.syslog_relay": ["Label": "x"]]
        try PropertyListSerialization.data(fromPropertyList: stock, format: .binary, options: 0).write(to: services)
        _ = try SystemEdits.installAFC2(root)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let edited = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: services), format: &format)
                as? [String: Any]
        )
        #expect(format == .binary, "the stock format is kept")
        let afc2 = try #require(edited["com.apple.afc2"] as? [String: Any])
        #expect(afc2["Label"] as? String == "com.apple.afc2")
        #expect(afc2["ProgramArguments"] as? [String] == ["/usr/libexec/afcd", "--lockdown", "-d", "/"])
        #expect(afc2["AllowUnactivatedService"] as? Bool == true)
        #expect(afc2["UserName"] == nil, "afcd at / runs as root")
        #expect(
            NSDictionary(dictionary: edited["com.apple.afc"] as? [String: Any] ?? [:]).isEqual(to: Self.stockAFC[era])
        )
        #expect(edited.count == 3)
    }

    @Test func afc2NeedsTheStockService() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-afc2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let services = root.appendingPathComponent(SystemEdits.lockdownServices)
        try FileManager.default.createDirectory(
            at: services.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)
            .write(to: services)
        #expect(throws: FirmwareError.self) { try SystemEdits.installAFC2(root) }
    }

    @Test func theOptionIsOffUnlessAskedFor() throws {
        func options(_ o: String) throws -> SystemEdits.Options {
            SystemEdits.Options(
                recipe: try JSONDecoder().decode(
                    FirmwareEntry.Recipe.self,
                    from: Data(
                        #"{"name": "n90", "version": 1, "storage": "16g", "system_mib": 1664, "data_size": "partition", "options": {\#(o)}}"#
                            .utf8
                    )
                )
            )
        }
        #expect(try options(#""jailbreak": true"#).jailbreak)
        #expect(try !options("").jailbreak)
    }
}

/// Cydia's bootstrap extracted into a system volume (SystemEdits.installCydia), from a small stand-in built here.
struct CydiaInstallTests {
    let fm = FileManager.default

    /// A bootstrap laid out as freeze.tar is (the /etc link, mobile's SpringBoard preferences, a file the firmware
    /// also has), gzipped by /usr/bin/tar.
    func bootstrap(in dir: URL) throws -> URL {
        let src = dir.appendingPathComponent("src")
        for (rel, text) in [
            ("Applications/Cydia.app/Cydia", "cydia"), ("bin/bash", "bash"), ("private/var/lib/dpkg/status", "s"),
            ("usr/libexec/afcd", "not the firmware's"),
        ] {
            let u = src.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
        }
        let prefs = src.appendingPathComponent(SystemEdits.Cydia.springBoardPrefs)
        try fm.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["SBShowNonDefaultSystemApps": true],
            format: .xml,
            options: 0
        ).write(to: prefs)
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("etc").path, withDestinationPath: "private/etc/")
        let file = dir.appendingPathComponent("freeze.tar.gz")
        let p = try Process.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-czf", file.path, "-C", src.path, "."]
        )
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return file
    }

    /// A firmware root: /etc, afcd, /private/var/mobile and (with `prefs`) mobile's SpringBoard preferences.
    func firmware(in dir: URL, prefs: [String: Any]?) throws -> URL {
        let m = dir.appendingPathComponent("volume")
        for rel in ["private/etc", "usr/libexec", "private/var/mobile"] {
            try fm.createDirectory(at: m.appendingPathComponent(rel), withIntermediateDirectories: true)
        }
        try Data("stock afcd".utf8).write(to: m.appendingPathComponent("usr/libexec/afcd"))
        try fm.createSymbolicLink(atPath: m.appendingPathComponent("etc").path, withDestinationPath: "private/etc")
        if let prefs {
            let u = m.appendingPathComponent(SystemEdits.Cydia.springBoardPrefs)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0).write(to: u)
        }
        return m
    }

    func springBoard(_ m: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: m.appendingPathComponent(SystemEdits.Cydia.springBoardPrefs))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func cydiaLandsBesideTheFirmwaresOwnFiles() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-cydia-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let m = try firmware(in: dir, prefs: nil)
        let r = try SystemEdits.installCydia(m, bootstrap: try bootstrap(in: dir))
        let cydia = m.appendingPathComponent("Applications/Cydia.app/Cydia")
        #expect(try String(contentsOf: cydia, encoding: .utf8) == "cydia")
        #expect(
            try String(contentsOf: m.appendingPathComponent("usr/libexec/afcd"), encoding: .utf8) == "stock afcd",
            "a file the firmware has is kept"
        )
        #expect(try springBoard(m)["SBShowNonDefaultSystemApps"] as? Bool == true)
        #expect(fm.fileExists(atPath: m.appendingPathComponent(".cydia_no_stash").path), "no stash on first launch")
        for rel in [
            ".cydia_no_stash", "Applications", "Applications/Cydia.app/Cydia", "bin/bash",
            "private/var/lib/dpkg/status",
            "etc",
        ] {
            #expect(r.root.contains(rel), "\(rel) is root's")
        }
        for rel in ["usr/libexec", "usr/libexec/afcd", "private/var/mobile"] {
            #expect(!r.root.contains(rel) && !r.mobile.contains(rel), "the firmware's \(rel) keeps its owner")
        }
        #expect(
            Set(r.mobile) == [
                "private/var/mobile/Library", "private/var/mobile/Library/Preferences",
                SystemEdits.Cydia.springBoardPrefs,
            ]
        )
    }

    @Test func theFirmwaresSpringBoardPreferencesGainTheKey() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-cydia-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let m = try firmware(in: dir, prefs: ["SBAutoLockTime": 60])
        let r = try SystemEdits.installCydia(m, bootstrap: try bootstrap(in: dir))
        let prefs = try springBoard(m)
        #expect(prefs["SBShowNonDefaultSystemApps"] as? Bool == true)
        #expect(prefs["SBAutoLockTime"] as? Int == 60)
        #expect(r.mobile.isEmpty, "mobile's own preferences keep their owner")
    }

    @Test func aBootstrapOfOtherBytesIsRefused() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-cydia-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        #expect(throws: FirmwareError.self) {
            try SystemEdits.Cydia.bootstrap(in: dir) { _, file in try Data("not freeze.tar".utf8).write(to: file) }
        }
        #expect((try? fm.contentsOfDirectory(atPath: dir.path)) == [], "nothing is left in the cache")
    }
}
