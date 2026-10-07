import Foundation

/// Shared helpers for the Library and Storage tests: the checkout's files, child processes and fake tools.
enum LibraryFixtures {
    /// The repository checkout this test file is in.
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var shippedCatalog: URL { repo.appendingPathComponent("LightTouchMac/Resources/firmware-catalog.json") }
    static var fakeFirmwarekit: URL { repo.appendingPathComponent("tests/fixtures/fake-firmwarekit.py") }

    /// Runs `executable` to its exit; its stdout. Throws on a non-zero status.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> String {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments) exited \(process.terminationStatus)"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// An executable shell script at `url`.
    static func script(_ url: URL, _ body: String) throws -> URL {
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The fake preparer (tests/fixtures/fake-firmwarekit.py) in `mode`, writing its argv to `argv`, as its own
    /// executable: the mode and argv path travel in the script, not this process's shared environment.
    static func fakePreparer(in directory: URL, mode: String = "ok", argv: URL? = nil, unwrap: URL? = nil) throws -> URL {
        let name = "preparer-\(mode)-\(UUID().uuidString.prefix(8))"
        var body = ""
        if let unwrap { body += "[ \"$1\" = unwrap ] && exec '\(unwrap.path)' \"$@\"\n" }
        body += "FAKE_MODE=\(mode) FAKE_ARGV='\(argv?.path ?? "")' exec /usr/bin/python3 '\(fakeFirmwarekit.path)' \"$@\"\n"
        return try script(directory.appendingPathComponent(name), body)
    }

    /// Removes a tree a preparer made read-only or immutable.
    static func forceRemove(_ url: URL) {
        _ = try? run("/usr/bin/chflags", ["-R", "nouchg", url.path])
        _ = try? run("/bin/chmod", ["-R", "u+w", url.path])
        try? FileManager.default.removeItem(at: url)
    }

    /// Like withTemporaryDirectory, for trees with read-only or locked parts.
    static func withScratch<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { forceRemove(directory) }
        return try await body(directory.resolvingSymlinksInPath())
    }
}
