import Foundation
import Testing
@testable import ReleaseChecks

/// Devices prepared by the bundled firmwarekit and booted through the bundled helper, dylib, services worker and
/// usbmuxd (tests/sessions/check-sessions.py --single: lit, lockdown, time zone, AFC, an IPA install, a clean
/// shutdown). The built-in iPod always; every release entry with LTM_RELEASE_FULL=1. One emulator at a time.
@Suite(.serialized, .enabled(if: appGiven, "no app: LTM_RELEASE_APP / LTM_RELEASE_ARCHIVE (the Release plan)"))
struct ReleaseBootTests {
    static let builtIn = "n72ap-7E18"
    /// entry: (check-sessions board, IPSW; nil: the app's IPSW cache by the catalog's sha1).
    static let releaseEntries: [(id: String, board: String, ipsw: String?)] = [
        ("k48ap-7B500", "ipad", "Downloads/ipad1-ios32-feasibility/iPad1,1_3.2.2_7B500_Restore.ipsw"),
        ("k48ap-8C148", "ipad", "Downloads/ipad1-ios32-feasibility/iPad1,1_4.2.1_8C148_Restore.ipsw"),
        ("k48ap-7B367", "ipad", "Downloads/ipad1-ios32-feasibility/iPad1,1_3.2_7B367_Restore.ipsw"),
        ("n72ap-7E18", "ipod", "Developer/ipod2g-re/OldSDK/iPod2,1_3.1.3_7E18_Restore.ipsw"),
        ("n72ap-8C148", "ipod", "Downloads/ios4/iPod2,1_4.2.1_8C148_Restore.ipsw"),
    ]

    @Test func theBuiltInIPodUnpacksWithItsOwnIdentityAndBoots() throws {
        try boot(entry: Self.builtIn, board: "ipod", ipsw: nil, builtIn: true)
    }

    @Test(.tags(.fullRelease), .enabled(if: ReleaseApp.full, "LTM_RELEASE_FULL=1 prepares and boots every release entry"),
          arguments: releaseEntries.map(\.id))
    func everyReleaseEntryPreparesAndBoots(_ id: String) throws {
        let entry = Self.releaseEntries.first { $0.id == id }!
        try boot(entry: id, board: entry.board, ipsw: entry.ipsw, builtIn: false)
    }

    func boot(entry id: String, board: String, ipsw relative: String?, builtIn: Bool) throws {
        let app = try ReleaseApp.app(), contents = app.appendingPathComponent("Contents")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: contents.appendingPathComponent("Resources/firmware-catalog.json"))) as! [String: Any]
        let entry = try #require((catalog["entries"] as! [[String: Any]]).first { $0["id"] as? String == id })
        try withScratch { work in
            let out = work.appendingPathComponent("out"), frames = work.appendingPathComponent("frames")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
            defer { _ = try? Shell.run(["chflags", "-R", "nouchg", work.path]); _ = try? Shell.run(["chmod", "-R", "u+w", work.path]) }
            let firmwarekit = contents.appendingPathComponent("MacOS/firmwarekit").path
            let seed = UUID().uuidString
            let command: [String]
            if builtIn {
                let blob = (catalog["bundled"] as! [String: String])[id]!
                command = [firmwarekit, "unpack-base", "--blob", contents.appendingPathComponent("Resources/\(blob)").path, "--out", out.path, "--seed", seed]
            } else {
                var ipsw = relative.map { home.appendingPathComponent($0) }
                if ipsw.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
                    let sha1 = (entry["source"] as? [String: Any])?["sha1"] as? String ?? ""
                    ipsw = home.appendingPathComponent("Library/Caches/gold.samhenri.LightTouchMac/IPSW/\(sha1).ipsw")
                }
                try #require(FileManager.default.fileExists(atPath: ipsw!.path), "\(id): no IPSW (\(ipsw!.path))")
                let entryFile = work.appendingPathComponent("entry.json")
                try JSONSerialization.data(withJSONObject: entry).write(to: entryFile)
                command = [firmwarekit, "create", "--entry", entryFile.path, "--ipsw", ipsw!.path, "--out", out.path,
                           "--cache", work.appendingPathComponent("cache").path, "--helper", contents.appendingPathComponent("MacOS/LightTouchDevice").path]
            }
            let prepared = try Shell.run(command, environment: ReleaseApp.cleanEnvironment, timeout: 480)
            let events = prepared.output.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            try #require(prepared.succeeded && events.last?["event"] as? String == "done",
                         "\(id): firmwarekit \(command[1]) failed (\(prepared.status)): \(events.last ?? [:])")
            let lock = try JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent(events.last!["lock"] as! String))) as! [String: Any]
            if builtIn {
                #expect((lock["identity"] as? [String: Any])?["seed"] as? String == seed, "the unpacked iPod did not take its own identity")
            }
            _ = try Shell.run(["find", out.path, "-type", "d", "-exec", "chflags", "uchg", "{}", "+"])   // as the app locks a base
            var arguments = ["python3", repository.appendingPathComponent("tests/sessions/check-sessions.py").path,
                             "--single", out.path, "--board", board,
                             "--helper", contents.appendingPathComponent("MacOS/LightTouchDevice").path,
                             "--dylib", contents.appendingPathComponent("Frameworks/libqemu-arm.dylib").path,
                             "--service-worker", contents.appendingPathComponent("MacOS/LightTouchServices").path,
                             "--usbmuxd", contents.appendingPathComponent("MacOS/usbmuxd").path,
                             "--frameworks", contents.appendingPathComponent("Frameworks").path,
                             "--files", contents.appendingPathComponent("Resources/Device").path, "--work", frames.path]
            if board == "ipad" {
                let guest = work.appendingPathComponent("guest")
                try #require(try Shell.run(["aa", "extract", "-i", contents.appendingPathComponent("Resources/Guest/guest.aar").path, "-d", guest.path]).succeeded)
                arguments += ["--ipad-itpack", guest.appendingPathComponent("guest-tools/armv7.itpack").path]
            }
            let booted = try Shell.run(arguments, environment: ReleaseApp.cleanEnvironment, timeout: 590)
            let summary = booted.output.split(separator: "\n").first { $0.contains(" passed; events ") }.map(String.init) ?? ""
            #expect(booted.succeeded, "\(id): boot \(summary.isEmpty ? "failed" : summary)\n\(booted.output.suffix(1500))")
        }
    }
}
