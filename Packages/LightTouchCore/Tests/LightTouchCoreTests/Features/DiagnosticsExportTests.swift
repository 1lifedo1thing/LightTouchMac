import Darwin
import Foundation
import Testing
@testable import LightTouchCore

/// Diagnostics export: the app's own crash reports, the system summary, and an atomic archive that a failing,
/// empty, missing or cancelled archiver never half-writes, with concurrent exports keeping their own scratch.
struct DiagnosticsExportTests {
    let fm = FileManager.default

    func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func children(_ url: URL) throws -> [URL] { try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }

    @Test func crashReportsAreTheAppsOwnNewestFirstWithinThirtyDays() throws {
        try withTemporaryDirectory { reports in
            for (name, age) in [("LightTouch-2026-10-07-101010.ips", 60.0), ("LightTouchDevice-2026-10-07-101011.ips", 30.0),
                                ("Safari-2026-10-07-101012.ips", 10.0), ("LightTouchServices-2026-08-01-101010.ips", 40 * 86_400.0),
                                ("LightTouchDevice-notes.txt", 5.0)] {
                let url = reports.appendingPathComponent(name)
                try Data("report".utf8).write(to: url)
                try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
            }
            let found = DiagnosticsExport.crashReports(executables: ["LightTouch", "LightTouchDevice", "LightTouchServices"], in: reports)
            #expect(found.map(\.lastPathComponent) == ["LightTouchDevice-2026-10-07-101011.ips", "LightTouch-2026-10-07-101010.ips"])
        }
    }

    @Test func systemSummaryNamesTheOSAndArchitecture() {
        let summary = DiagnosticsExport.systemSummary()
        #expect(summary.contains("macOS ") && summary.contains(ProcessInfo.processInfo.operatingSystemVersionString))
        #expect(summary.contains("arm64") || summary.contains("x86_64"))
    }

    /// An archiver stand-in: `fail` writes a partial archive and exits 9, `empty` an empty one, `cancel` records its
    /// pid in staging/ready and sleeps until killed. ($5 is the staging directory, $6 the archive.)
    func archiver(in directory: URL) throws -> URL {
        try LibraryFixtures.script(directory.appendingPathComponent("archive-helper"), """
            case "$(cat "$5/info.txt")" in
                fail) printf incomplete > "$6"; exit 9 ;;
                empty) : > "$6"; exit 0 ;;
                cancel) printf '%s\\n' "$$" > "$5/ready"; exec /bin/sleep 60 ;;
            esac
            exit 1

            """)
    }

    @Test func exportIsAtomicAndCancellable() async throws {
        try await LibraryFixtures.withScratch { root in
            let scratch = root.appendingPathComponent("diagnostic temp"), exports = root.appendingPathComponent("exports")
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            try fm.createDirectory(at: exports, withIntermediateDirectories: true)
            let log = root.appendingPathComponent("app.log")
            try Data("sample events".utf8).write(to: log)
            let report = root.appendingPathComponent("LightTouchDevice-2026-10-07-101011.ips")
            try Data("report".utf8).write(to: report)

            // A real ditto archive: valid, with the info and the crash report, and no scratch left.
            let success = exports.appendingPathComponent("success.zip")
            try await DiagnosticsExport.write(to: success, logs: [log], info: "real ditto archive", crashReports: [report], temporaryRoot: scratch)
            #expect(try children(scratch).isEmpty)
            try LibraryFixtures.run("/usr/bin/unzip", ["-tq", success.path])
            #expect(try LibraryFixtures.run("/usr/bin/unzip", ["-p", success.path, "LightTouchMac-diagnostics/info.txt"]) == "real ditto archive")
            let listing = try LibraryFixtures.run("/usr/bin/unzip", ["-Z1", success.path]).split(separator: "\n")
            #expect(listing.contains("LightTouchMac-diagnostics/CrashReports/LightTouchDevice-2026-10-07-101011.ips"))

            // A failing, empty or missing archiver: an error, the existing archive kept, nothing left behind.
            let helper = try archiver(in: root)
            let preserved = exports.appendingPathComponent("preserved.zip")
            try Data("existing user archive".utf8).write(to: preserved)
            func untouched() throws {
                #expect(try text(preserved) == "existing user archive")
                #expect(try children(scratch).isEmpty)
                #expect(try children(exports).allSatisfy { !$0.lastPathComponent.hasPrefix(".LightTouch-") })
            }
            for (info, executable) in [("fail", helper), ("empty", helper), ("missing", root.appendingPathComponent("no-archiver"))] {
                await #expect(throws: (any Error).self, "\(info)") {
                    try await DiagnosticsExport.write(to: preserved, logs: [log], info: info, temporaryRoot: scratch, archiver: executable)
                }
                try untouched()
            }

            // One export's archiver still running while another completes: neither deletes the other's scratch.
            let cancelled = Task {
                try await DiagnosticsExport.write(to: preserved, logs: [log], info: "cancel", temporaryRoot: scratch, archiver: helper)
            }
            var ready: URL?
            let deadline = Date().addingTimeInterval(10)
            while ready == nil, Date() < deadline {
                ready = try children(scratch).map { $0.appendingPathComponent("LightTouchMac-diagnostics/ready") }
                    .first { !((try? text($0))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
                if ready == nil { try await Task.sleep(for: .milliseconds(10)) }
            }
            guard let ready else { cancelled.cancel(); Issue.record("the archiver did not start"); return }
            let pid = try #require(Int32(text(ready).trimmingCharacters(in: .whitespacesAndNewlines)))
            let concurrent = exports.appendingPathComponent("concurrent.zip")
            try await DiagnosticsExport.write(to: concurrent, logs: [log], info: "concurrent real archive", temporaryRoot: scratch)
            #expect(try fm.fileExists(atPath: ready.path) && children(scratch).count == 1)
            #expect(try text(ready.deletingLastPathComponent().appendingPathComponent("info.txt")) == "cancel")
            #expect(try LibraryFixtures.run("/usr/bin/unzip", ["-p", concurrent.path, "LightTouchMac-diagnostics/info.txt"]) == "concurrent real archive")

            // Cancelled: CancellationError, the child gone, nothing written.
            let cancelledAt = Date()
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(Date().timeIntervalSince(cancelledAt) < 10, "the cancel waited for the archiver instead of stopping it")
            #expect(kill(pid, 0) != 0, "the cancelled archiver is still running")
            try untouched()
            #expect(try text(log) == "sample events")
        }
    }
}
