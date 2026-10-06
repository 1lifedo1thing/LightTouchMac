#!/usr/bin/env python3
"""On iOS 7 an app install holds its first AFC request until the guest tools report, bounded by a timeout with a
clear message; other versions never wait. 7.x's data volume can stall file creation for 1-3 minutes after lockdown
answers, and an upload in that window failed (afc_file_open). Compiles Features/AppInstallPipeline.swift whole
against fake services that record when each AFC call lands; only the exec-bit repair (a subprocess) is cut out."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "LightTouchMac/Features/AppInstallPipeline.swift").read_text()


def patched(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new)


src = patched(src, "import Subprocess\n", "")
src = patched(src, "import System\n", "")
src = patched(src, "let repaired = try await Self.execBitRepaired(ipa)", "let repaired: URL? = nil")
start, end = src.index("    private static func execBitRepaired"), src.index("    /// Whether a declared MinimumOSVersion")
src = src[:start] + src[end:]

fakes = r'''
import Foundation
enum DeviceError: Error { case preflight(String), failed(String), diskFull(free: Int64, needed: Int64)
    var isTransient: Bool { false } }
func logEvent(_ s: String) {}
actor AppMetadataCache {
    static let shared = AppMetadataCache()
    func minimumOS(from: URL) -> String? { nil }
    static func bundleID(of: URL) async -> String? { "com.example.app" }
}
struct GuestAgent: Sendable {
    var isAlive: Bool { false }
    func placeholder(_ action: String, id: String, bundleID: String?) async throws {}
}
final class Log: @unchecked Sendable {
    private let lock = NSLock(); private var calls: [(String, Bool)] = []; private var flag = false
    var ready: Bool { get { lock.withLock { flag } } set { lock.withLock { flag = newValue } } }
    func add(_ c: String) { lock.withLock { calls.append((c, flag)) } }
    var all: [(String, Bool)] { lock.withLock { calls } }
}
struct DeviceServices: Sendable {
    let log: Log
    func freeSpaceBytes() async throws -> Int64 { log.add("free"); return 1 << 40 }
    func stage(_ ipa: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String { log.add("stage"); return "s" }
    func removeStaged(_ s: String) async {}
    func install(_ ipa: URL, staged: String, bundleID: String, progress: @escaping @Sendable (Int, String) -> Void) async throws { log.add("install") }
}
final class Phrases: @unchecked Sendable {
    private let lock = NSLock(); private var all: [String] = []
    func add(_ s: String) { lock.withLock { all.append(s) } }
    var list: [String] { lock.withLock { all } }
}
@main struct Check {
    static func run(os: String, readyAfter: Double?, timeout: Duration) async -> (Log, Phrases, Error?) {
        let log = Log(), phrases = Phrases()
        let ipa = URL(fileURLWithPath: CommandLine.arguments[1])
        let start = Date()
        let p = AppInstallPipeline(services: DeviceServices(log: log), agent: GuestAgent(), deviceOS: os,
                                   guestReady: {
                                       if let readyAfter, Date().timeIntervalSince(start) >= readyAfter { log.ready = true }
                                       return log.ready
                                   }, guestReadyTimeout: timeout)
        do { try await p.install(ipa) { phrases.add($0) }; return (log, phrases, nil) }
        catch { return (log, phrases, error) }
    }
    static func main() async {
        // 7.x, tools report after 2 s: every AFC call lands after the report, and the user is told why it waits.
        var (log, phrases, error) = await run(os: "7.1.2", readyAfter: 2, timeout: .seconds(30))
        precondition(error == nil, "7.x install failed: \(String(describing: error))")
        precondition(log.all.map(\.0) == ["free", "stage", "install"], "calls \(log.all)")
        precondition(log.all.allSatisfy(\.1), "an AFC call ran before the guest tools reported: \(log.all)")
        precondition(phrases.list.first == "Waiting for iOS to finish starting…", "phrases \(phrases.list)")
        // 7.x, tools never report: a clear failure after the timeout, and nothing was sent.
        (log, phrases, error) = await run(os: "7.0.6", readyAfter: nil, timeout: .seconds(2))
        guard case .failed(let message)? = error as? DeviceError, message.contains("didn’t finish starting") else {
            fatalError("7.x without a report: \(String(describing: error))")
        }
        precondition(log.all.isEmpty, "sent despite no report: \(log.all)")
        // 6.x never waits, report or not.
        (log, phrases, error) = await run(os: "6.1.3", readyAfter: nil, timeout: .seconds(2))
        precondition(error == nil && log.all.map(\.0) == ["free", "stage", "install"], "6.x: \(log.all) \(String(describing: error))")
        precondition(!phrases.list.contains { $0.hasPrefix("Waiting") }, "6.x waited: \(phrases.list)")
        print("install guest wait: OK")
    }
}
'''

with tempfile.TemporaryDirectory() as d:
    d = Path(d)
    (d / "AppInstallPipeline.swift").write_text(src)
    (d / "Fakes.swift").write_text(fakes)
    # A minimal app archive: Payload/X.app/Info.plist is all the preflight reads (and the fake answers it anyway).
    ipa = d / "x.ipa"
    (d / "Payload/X.app").mkdir(parents=True)
    (d / "Payload/X.app/Info.plist").write_text("<plist/>")
    subprocess.run(["/usr/bin/zip", "-qr", str(ipa), "Payload"], cwd=d, check=True)
    exe = d / "check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-o", str(exe),
                    str(d / "AppInstallPipeline.swift"), str(d / "Fakes.swift")], check=True)
    subprocess.run([str(exe), str(ipa)], check=True)
