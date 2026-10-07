import Foundation
import Testing
@testable import LightTouchCore

/// About's credits: the build record's components (qemu-ios, usbmuxd, guest tools first, then by name), Help.txt's
/// Licenses section, the link to the licence files; nothing for a development build without a record.
struct AboutCreditsTests {
    static let help = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../../LightTouchMac/Help.txt").standardizedFileURL

    @Test func componentsThenLicensesThenTheLink() throws {
        let inputs = Data(#"{"components":{"libplist":"2.7.0","qemu-ios":"0e4bf5a90b","guest tools":"1.1.14 (serial 16)","usbmuxd":"e19fac2d4b","glib":"2.88.3"}}"#.utf8)
        let help = try String(contentsOf: Self.help, encoding: .utf8)
        let licenses = FileManager.default.temporaryDirectory
        let runs = AboutCredits.runs(buildInputs: inputs, help: help, licenses: licenses)
        let s = runs.map(\.text).joined()
        #expect(s.hasPrefix("Components\nqemu-ios 0e4bf5a90b\nusbmuxd e19fac2d4b\nguest tools 1.1.14 (serial 16)\nglib 2.88.3\nlibplist 2.7.0\n\nLicenses\nLight Touch includes open-source software."), "\(s)")
        #expect(!s.contains("# ") && s.hasSuffix("Show the license files"))
        #expect(runs.filter(\.isHeading).map(\.text) == ["Components\n", "Licenses\n"])
        #expect(runs.last?.link == licenses && runs.dropLast().allSatisfy { $0.link == nil })
    }

    @Test func developmentBuildHasNoCredits() {
        #expect(AboutCredits.runs(buildInputs: nil, help: nil, licenses: nil).isEmpty)
        #expect(AboutCredits.runs(buildInputs: nil, help: nil, licenses: URL(fileURLWithPath: "/nonexistent-licenses")).isEmpty)
    }
}
