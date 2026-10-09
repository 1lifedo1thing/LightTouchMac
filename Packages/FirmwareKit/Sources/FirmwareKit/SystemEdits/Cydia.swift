// Cydia on a jailbroken device (firmwarekit create --jailbreak): the bootstrap the jailbreaks of the time left on the
// system volume, extracted as they extracted it.
//
// The bootstrap is saurik's freeze.tar as Legacy iOS Kit ships it for the jailbroken restores it builds for iOS 3.1
// to 6.x (github.com/LukeZGD/Legacy-iOS-Kit, resources/jailbreak/freeze.tar.gz, pinned by commit): Cydia 1.1.30
// (armv6 + arm64, MinimumOSVersion 2.0), apt, dpkg, bash and the base packages, dpkg's status already listing them,
// and Cydia's com.saurik.Cydia.Startup job. Its executables are ldid-signed, which the boot-args every device boots
// with let run (FitCheck.amfiArgs). On the first boot the Startup job runs /usr/libexec/cydia/startup, which writes
// the firmware package and runs uicache, so SpringBoard lists Cydia.app; the bootstrap's own SpringBoard preference
// SBShowNonDefaultSystemApps shows it there.
//
//   let file = try SystemEdits.Cydia.bootstrap(in: caches.appendingPathComponent("Jailbreak"), log: log)
//   let (line, root, mobile) = try SystemEdits.installCydia(m, bootstrap: file)

import CryptoKit
import Foundation

extension SystemEdits {
    public enum Cydia {
        static let source =
            "https://raw.githubusercontent.com/LukeZGD/Legacy-iOS-Kit/4b0a582f4d53e105be373b495734c8ed639fd634/resources/jailbreak/freeze.tar.gz"
        static let sha1 = "c943e5ece72b7b71da589c22663a8f9b3b3d1190"
        static let name = "freeze.tar.gz", noStash = ".cydia_no_stash"
        static let springBoardPrefs = "private/var/mobile/Library/Preferences/com.apple.springboard.plist"

        /// The bootstrap in `dir`, downloaded there first when it is missing or other bytes.
        public static func bootstrap(
            in dir: URL,
            download: (URL, URL) throws -> Void = SourceFetch.download,
            log: (String) -> Void = { _ in }
        ) throws -> URL {
            let file = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path), try Preparer.digest(file, Insecure.SHA1()) == sha1 {
                return file
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let url = URL(string: source) else { throw FirmwareError(.internal, "Cydia bootstrap: \(source)") }
            let part = dir.appendingPathComponent("." + name + ".download")
            defer { try? FileManager.default.removeItem(at: part) }
            log("Cydia bootstrap from \(source)")
            try download(url, part)
            let got = try Preparer.digest(part, Insecure.SHA1())
            guard got == sha1 else { throw FirmwareError(.shaMismatch, "Cydia bootstrap: SHA-1 \(got), not \(sha1)") }
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: part, to: file)
            return file
        }
    }

    /// The bootstrap extracted into the mounted system volume `m`, keeping every file the firmware already has (tar
    /// -k). Returns the log line and the volume paths to make root's and mobile's: what it added, mobile's under
    /// /private/var/mobile, root's elsewhere (its symbolic links too, which tar replaces).
    static func installCydia(_ m: URL, bootstrap: URL) throws -> (line: String, root: [String], mobile: [String]) {
        let fm = FileManager.default
        let entries = try tar(["-tzf", bootstrap.path]).split(separator: "\n").map {
            String($0.hasPrefix("./") ? $0.dropFirst(2) : $0[...]).trimmingCharacters(in: ["/"])
        }
        .filter { !$0.isEmpty }
        func exists(_ rel: String) -> Bool {
            (try? fm.attributesOfItem(atPath: m.appendingPathComponent(rel).path)) != nil
        }
        func link(_ rel: String) -> Bool {
            (try? fm.destinationOfSymbolicLink(atPath: m.appendingPathComponent(rel).path)) != nil
        }
        let added = Set(entries.filter { !exists($0) })
        _ = try tar(["-xkzf", bootstrap.path, "-C", m.path])
        guard exists("Applications/Cydia.app/Cydia") else {
            throw FirmwareError(.internal, "Cydia bootstrap: no Applications/Cydia.app/Cydia after extracting")
        }
        // SpringBoard lists a system app outside its own set only with this key (the bootstrap's copy of the file
        // gives it, unless the firmware has the file already).
        let prefs = m.appendingPathComponent(Cydia.springBoardPrefs)
        let hadPrefs = exists(Cydia.springBoardPrefs)
        try seedPlist(prefs) { $0["SBShowNonDefaultSystemApps"] = true }
        // Cydia's first launch would otherwise stash /Applications, /usr/share and the rest onto the data volume
        // ("Preparing Filesystem", then exit) to free a stock-sized root; this root is grown, so no stash, as Legacy
        // iOS Kit's own restores mark it.
        try put(Data(), m.appendingPathComponent(Cydia.noStash), mode: 0o644)
        var root: [String] = [Cydia.noStash]
        var mobile: [String] = []
        for rel in entries where added.contains(rel) || link(rel) {
            if rel.hasPrefix("private/var/mobile/") { mobile.append(rel) } else { root.append(rel) }
        }
        if !hadPrefs, !mobile.contains(Cydia.springBoardPrefs) { mobile.append(Cydia.springBoardPrefs) }
        return ("Cydia: \(bootstrap.lastPathComponent), \(added.count) of \(entries.count) entries added", root, mobile)
    }

    /// /usr/bin/tar `args`; its stdout, or an error with its stderr.
    private static func tar(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw FirmwareError(.internal, "tar \(args.first ?? ""): \(String(decoding: errors, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
