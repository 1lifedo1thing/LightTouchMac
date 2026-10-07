#!/usr/bin/env python3
"""On iOS 7 an app install retries its first AFC request (the free-space query) while it times out, bounded, and sends
nothing until afcd answers; a different error, or any error on other versions, fails at once as before. 7.x starts afcd
in launchd's throttled band, and early in a boot a request can go unanswered for a minute or more (qemu-ios docs/n90
debt 6). Compiles Features/AppInstallPipeline.swift whole against fake services that answer the free-space query only
from a given try on; only the exec-bit repair (a subprocess) is cut out."""
from pathlib import Path
import subprocess
import sys as _sys, pathlib as _pl; _sys.path.insert(0, str(_pl.Path(__file__).resolve().parents[2] / "scripts"))
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
enum DeviceError: Error { case preflight(String), failed(String), diskFull(free: Int64, needed: Int64), unavailable,
    timedOut(operation: String)
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
    private let lock = NSLock(); private var calls: [String] = []
    func add(_ c: String) { lock.withLock { calls.append(c) } }
    var all: [String] { lock.withLock { calls } }
}
/// afcd answers the free-space query from try `answersFrom` on (nil: never); earlier tries time out, or fail
/// with `otherError` when set.
struct DeviceServices: Sendable {
    let log: Log; let answersFrom: Int?; let otherError: Bool
    func freeSpaceBytes() async throws -> Int64 {
        log.add("free")
        let n = log.all.filter { $0 == "free" }.count
        if let answersFrom, n >= answersFrom { return 1 << 40 }
        if otherError { throw DeviceError.unavailable }
        throw DeviceError.timedOut(operation: "free space")
    }
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
    static func run(os: String, answersFrom: Int?, otherError: Bool = false, timeout: Duration) async -> (Log, Phrases, Error?) {
        let log = Log(), phrases = Phrases()
        let ipa = URL(fileURLWithPath: CommandLine.arguments[1])
        var p = AppInstallPipeline(services: DeviceServices(log: log, answersFrom: answersFrom, otherError: otherError),
                                   agent: GuestAgent(), deviceOS: os)
        p.afcReadyTimeout = timeout
        do { try await p.install(ipa) { phrases.add($0) }; return (log, phrases, nil) }
        catch { return (log, phrases, error) }
    }
    static func main() async {
        // 7.x, afcd answers on the third try: the install waits it out, says why, then sends.
        var (log, phrases, error) = await run(os: "7.1.2", answersFrom: 3, timeout: .seconds(60))
        precondition(error == nil, "7.x install failed: \(String(describing: error))")
        precondition(log.all == ["free", "free", "free", "stage", "install"], "calls \(log.all)")
        precondition(phrases.list.first == "Waiting for iOS to finish starting…", "phrases \(phrases.list)")
        // 7.x, afcd never answers: a clear failure after the bound, and nothing was sent.
        (log, phrases, error) = await run(os: "7.0.6", answersFrom: nil, timeout: .seconds(2))
        guard case .failed(let message)? = error as? DeviceError, message.contains("didn’t answer") else {
            fatalError("7.x, no answer: \(String(describing: error))")
        }
        precondition(!log.all.contains("stage") && log.all.count >= 2, "7.x, no answer: \(log.all)")
        // 7.x, a different error is not retried.
        (log, phrases, error) = await run(os: "7.1.2", answersFrom: nil, otherError: true, timeout: .seconds(60))
        guard case .unavailable? = error as? DeviceError, log.all == ["free"] else { fatalError("7.x other error: \(log.all) \(String(describing: error))") }
        // 6.x: a timeout fails at once, as before.
        (log, phrases, error) = await run(os: "6.1.3", answersFrom: 3, timeout: .seconds(60))
        guard case .timedOut? = error as? DeviceError, log.all == ["free"] else { fatalError("6.x: \(log.all) \(String(describing: error))") }
        print("install AFC probe: OK")
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
    subprocess.run(["xcrun", "swiftc", *__import__('host_service').client_sources(__import__('pathlib').Path(__file__).resolve().parents[2]), "-parse-as-library", "-swift-version", "6", "-o", str(exe),
                    str(d / "AppInstallPipeline.swift"), str(d / "Fakes.swift")], check=True)
    subprocess.run([str(exe), str(ipa)], check=True)
