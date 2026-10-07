import Foundation
import Testing
import zlib
@testable import ReleaseChecks

/// Fixture bundles, each broken one way (was tests/release/test-bundle-hygiene.py's self-test).
struct BundleHygieneTests {
    let guest = BundleHygiene.guest

    struct Fixture {
        let root: URL, stripped: Data, debug: Data
        init(root: URL) throws {
            self.root = root
            let main = root.appendingPathComponent("main.c")
            try "int main(void) { return 0; }\n".write(to: main, atomically: true, encoding: .utf8)
            for args in [["-g", "-c", main.path, "-o", root.appendingPathComponent("main.o").path],
                         [root.appendingPathComponent("main.o").path, "-o", root.appendingPathComponent("debug").path]] {
                try #require(try Shell.run(["cc"] + args).succeeded)
            }
            try FileManager.default.copyItem(at: root.appendingPathComponent("debug"), to: root.appendingPathComponent("stripped"))
            try #require(try Shell.run(["strip", "-S", "-x", root.appendingPathComponent("stripped").path]).succeeded)
            stripped = try Data(contentsOf: root.appendingPathComponent("stripped"))
            debug = try Data(contentsOf: root.appendingPathComponent("debug"))
        }

        func write(_ data: Data, _ path: String, in app: URL) throws {
            let url = app.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        func guest(_ members: [String: Data], into app: URL) throws {
            let staged = root.appendingPathComponent(app.lastPathComponent + "-guest")
            try? FileManager.default.removeItem(at: staged)
            for (name, data) in members { try write(data, name, in: staged) }
            let archive = app.appendingPathComponent(BundleHygiene.guest)
            try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: archive)
            try #require(try Shell.run(["aa", "archive", "-d", staged.path, "-o", archive.path]).succeeded)
        }

        func bundle(_ label: String) throws -> URL {
            let app = root.appendingPathComponent("\(label).app")
            for (name, salt) in [("Contents/MacOS/usbmuxd", "u"), ("Contents/Frameworks/libplist-2.0.4.dylib", "p"),
                                 ("Contents/MacOS/inetcat", "i"), ("Contents/MacOS/LightTouchServices", "w")] {
                try write(stripped + Data(salt.utf8), name, in: app)   // distinct contents, still a Mach-O
            }
            try guest(["guest-tools/it_agent": stripped + Data("a".utf8)], into: app)
            for directory in ["usbmuxd", "glib", "proxy-libintl", "pcre2", "libslirp", "libimobiledevice-glue", "libplist", "qemu", "inetcat", "libusbmuxd"] {
                try write(Data("license text".utf8), "Contents/Resources/licenses/\(directory)/COPYING", in: app)
                try write(Data("\(directory): https://example.invalid/\(directory).tar.gz".utf8), "Contents/Resources/licenses/\(directory)/SOURCE.txt", in: app)
            }
            try write(Data("MIT".utf8), "Contents/Resources/licenses/swift/Example/LICENSE.txt", in: app)
            try write(Data("Licenses: usbmuxd, GLib, proxy-libintl, PCRE2, libslirp, libimobiledevice-glue, libplist, QEMU, inetcat, libusbmuxd".utf8),
                      "Contents/Resources/Help.txt", in: app)
            return app
        }

        func packed(_ app: URL, seed: String, extra: Data = Data()) throws {
            let files: [(String, Data)] = [
                ("device.lock.json", try JSONSerialization.data(withJSONObject: ["identity": ["seed": seed]])),
                ("identity.json", try JSONSerialization.data(withJSONObject: ["seed": seed])),
                ("nand/cs0/1.page", Data(repeating: UInt8(ascii: "p"), count: 5000) + extra),
            ]
            let index = try JSONSerialization.data(withJSONObject: ["entries": files.map { ["name": $0.0, "size": $0.1.count, "mode": 0o444] }])
            let body = files.reduce(Data()) { $0 + $1.1 }
            var length = UInt32(index.count).littleEndian
            try write(Data("ITPACK01".utf8) + Data(bytes: &length, count: 4) + index + deflate(body), "Contents/Resources/Device/n72ap-7E18.itbase", in: app)
        }

        func deflate(_ data: Data) -> Data {
            var size = compressBound(uLong(data.count))
            var out = [UInt8](repeating: 0, count: Int(size))
            data.withUnsafeBytes { _ = compress(&out, &size, $0.bindMemory(to: Bytef.self).baseAddress, uLong(data.count)) }
            return Data(out.prefix(Int(size)))
        }
    }

    func problems(_ app: URL) throws -> [String] {
        try BundleHygiene.problems(app: app, packages: ["example"], localMarkers: ["/Users/someone"])
    }

    func expect(_ app: URL, _ text: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let found = try problems(app)
        #expect(found.contains { $0.contains(text) }, "\(app.lastPathComponent): expected “\(text)”, got \(found)", sourceLocation: sourceLocation)
    }

    @Test func aCompleteBundlePassesAndEachBreakageIsNamed() throws {
        try withScratch { root in
            let f = try Fixture(root: root)
            let good = try f.bundle("good")
            #expect(try problems(good) == [])
            try f.packed(good, seed: BundleHygiene.placeholderSeed)
            #expect(try problems(good) == [])

            var broken = try f.bundle("no-license")
            try FileManager.default.removeItem(at: broken.appendingPathComponent("Contents/Resources/licenses/libslirp/COPYING"))
            try expect(broken, "no license text for libslirp")
            broken = try f.bundle("no-source")
            try FileManager.default.removeItem(at: broken.appendingPathComponent("Contents/Resources/licenses/glib/SOURCE.txt"))
            try expect(broken, "no SOURCE.txt naming the source of glib")
            broken = try f.bundle("local-path")
            try f.write(Data(#"{"path": "/Users/someone/Developer/qemu-ios"}"#.utf8), "Contents/Resources/build-inputs.json", in: broken)
            try expect(broken, "names a local path: Contents/Resources/build-inputs.json")
            broken = try f.bundle("packed-local-path")
            try f.packed(broken, seed: BundleHygiene.placeholderSeed, extra: Data("/Users/someone/Library/Caches/x.ipsw".utf8))
            try expect(broken, "names a local path: Contents/Resources/Device/n72ap-7E18.itbase (packed)")
            broken = try f.bundle("packed-identity")
            try f.packed(broken, seed: "6A1F0E2B-0000-4000-8000-000000000000")
            try expect(broken, "carries a unit identity")
            broken = try f.bundle("unattributed")
            try f.write(f.stripped + Data("n".utf8), "Contents/MacOS/newtool", in: broken)
            try expect(broken, "unattributed Mach-O (add it to binaries with its licenses): Contents/MacOS/newtool")
            broken = try f.bundle("unstripped")
            try f.write(f.debug, "Contents/MacOS/usbmuxd", in: broken)
            try expect(broken, "not stripped (has a debug map): Contents/MacOS/usbmuxd")
            broken = try f.bundle("dsym")
            try FileManager.default.createDirectory(at: broken.appendingPathComponent("Contents/Resources/usbmuxd.dSYM/Contents"), withIntermediateDirectories: true)
            try expect(broken, "a dSYM ships")
            broken = try f.bundle("twice")
            try f.guest(["guest-tools/it_agent": f.stripped + Data("a".utf8), "tools/it_agent": f.stripped + Data("a".utf8)], into: broken)
            try expect(broken, "ships twice: \(guest)/guest-tools/it_agent and \(guest)/tools/it_agent")
            broken = try f.bundle("loose")
            try f.write(f.stripped + Data("g".utf8), "Contents/Resources/guest-tools/it_pbd", in: broken)
            try expect(broken, "nested code under Resources (pack it into")
            broken = try f.bundle("packed-local")
            try f.guest(["guest-tools/it_agent": f.stripped + Data("a".utf8), "guest-tools/it.plist": Data("/Users/someone/x".utf8)], into: broken)
            try expect(broken, "names a local path: \(guest)/guest-tools/it.plist")
            broken = try f.bundle("swift")
            try FileManager.default.removeItem(at: broken.appendingPathComponent("Contents/Resources/licenses/swift/Example"))
            try expect(broken, "no license text for the Swift package example")
            broken = try f.bundle("help")
            try f.write(Data("Licenses: usbmuxd".utf8), "Contents/Resources/Help.txt", in: broken)
            try expect(broken, "Help.txt does not name GLib")
        }
    }
}
