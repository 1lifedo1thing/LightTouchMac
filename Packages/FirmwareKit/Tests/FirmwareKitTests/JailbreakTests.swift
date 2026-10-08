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
