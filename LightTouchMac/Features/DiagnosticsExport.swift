// Help > Export Diagnostics: the logs, device records and a summary zipped atomically into a scratch
// directory. Foundation only; tests/offline/check-storage-lifecycle.py compiles it whole.

import Foundation

// MARK: - Diagnostics storage

/// Each export owns its scratch and publishes one complete archive. Kept apart
/// from the window so the failure/cancellation paths can run without a device.
nonisolated enum DiagnosticsExport {
    /// What a report needs before anything else: which build, on which macOS, on which Mac.
    static func systemSummary(bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?", build = info["CFBundleVersion"] as? String ?? "?"
        func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var value = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        var translated: Int32 = 0, size = MemoryLayout<Int32>.size
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = rosetta ? "x86_64 (Rosetta)" : "x86_64"
        #endif
        return """
            Light Touch \(version) (\(build))
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
            \(arch) on \(sysctl("hw.model") ?? "?")\(sysctl("machdep.cpu.brand_string").map { ", \($0)" } ?? "")
            """
    }

    /// The newest crash reports (.ips) of the app's own executables (Contents/MacOS: the app, its helper,
    /// workers and tools), from the last 30 days, at most `limit`.
    static func crashReports(executables: [String], in folder: URL = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent("Library/Logs/DiagnosticReports"), limit: Int = 10, now: Date = Date()) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        return files.compactMap { url -> (URL, Date)? in
            let name = url.lastPathComponent
            guard url.pathExtension == "ips", executables.contains(where: { name.hasPrefix($0 + "-") }),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let date = values.contentModificationDate, now.timeIntervalSince(date) < 30 * 86_400 else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    @concurrent
    static func write(to destination: URL, logs: [URL], info: String, crashReports: [URL] = [],
                      temporaryRoot: URL = FileManager.default.temporaryDirectory,
                      archiver: URL = URL(fileURLWithPath: "/usr/bin/ditto")) async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        let scratch = temporaryRoot.appendingPathComponent("LightTouch-diagnostics-" + UUID().uuidString,
                                                          isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let staging = scratch.appendingPathComponent("LightTouchMac-diagnostics", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        for source in logs where fm.fileExists(atPath: source.path) {
            try Task.checkCancellation()
            try fm.copyItem(at: source, to: staging.appendingPathComponent(source.lastPathComponent))
        }
        try info.write(to: staging.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)
        if !crashReports.isEmpty {
            let reports = staging.appendingPathComponent("CrashReports", isDirectory: true)
            try fm.createDirectory(at: reports, withIntermediateDirectories: false)
            for report in crashReports { try? fm.copyItem(at: report, to: reports.appendingPathComponent(report.lastPathComponent)) }
        }

        // Keep the final rename on the destination volume. Failure or cancellation
        // leaves an existing user-selected archive untouched.
        let archive = destination.deletingLastPathComponent()
            .appendingPathComponent(".LightTouch-diagnostics-" + UUID().uuidString + ".zip")
        defer { try? fm.removeItem(at: archive) }
        try await runArchiver(archiver, staging: staging, archive: archive)
        let attributes = try fm.attributesOfItem(atPath: archive.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.uint64Value ?? 0 > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        guard rename(archive.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func runArchiver(_ executable: URL, staging: URL, archive: URL) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, archive.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { child in
                    continuation.resume(returning: child.terminationStatus)
                }
                do {
                    try process.run()
                    // Cancellation may have arrived before the process was live.
                    if Task.isCancelled, process.isRunning { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        guard status == 0 else {
            throw NSError(domain: "LightTouch.Diagnostics", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Couldn’t create the diagnostics file."
            ])
        }
    }
}
