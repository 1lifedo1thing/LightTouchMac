#!/usr/bin/env python3
"""Bound installation setup without abandoning a started guest mutation; a new version of an installed app on 2.x
(ApplicationAlreadyInstalled) is sent again and replaces it through a documents-only archive and restore; a failed
replacement keeps the archive, and the next 2.x install of that app restores it. Compiles Services/InstallationProxy.swift
and Transport/DeviceExecution.swift whole against a fake libimobiledevice, with two pause points patched in
(after openBeforeDeadline stores the connection for the deadline's loser, and after it is handed to the install) so the races
run deterministically; no production deadline, cancellation or cleanup is replaced."""
from pathlib import Path
from host_service_fixtures import engine, leaves, local_engine_stub
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / "LightTouchMac"


def patched(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new)


install = patched((app / "Services/InstallationProxy.swift").read_text(),
                  "let connection = try await installConnection()",
                  "let connection = try await installConnection()\n        await Fixture.shared.afterConnection()")
# openBeforeDeadline is the install connection's only user in this build.
execution = patched((app / "Transport/DeviceExecution.swift").read_text(),
                    "if let opened = try open() { late.store(opened) }",
                    "if let opened = try open() { late.store(opened); Fixture.shared.afterStore() }")
fixture = r'''
import Foundation
import Dispatch
nonisolated func logEvent(_ message: String) { }
nonisolated final class Fixture: @unchecked Sendable {
    static let shared = Fixture()
    let lock = NSLock()
    var blockDevice = false, blockService = false, blockStore = false, blockHandoff = false
    var deviceEntered = false, serviceEntered = false, storeEntered = false, handoffEntered = false
    var deviceFrees = 0, clientFrees = 0, installs = 0, progress = 0, opens = 0
    /// Each command's terminal status, answered right after it is sent (empty: the test emits by hand).
    var script: [Int] = []
    var commands: [String] = []
    var options: [String: String] = [:]
    var productVersion = "3.1.3", archives: [String: Any] = [:], lookups = 0
    var readStarted = false
    var installResult: Int32 = 0
    var callback: instproxy_status_cb_t?
    var context: UnsafeMutableRawPointer?
    var handoff: CheckedContinuation<Void, Never>?
    let deviceRelease = DispatchSemaphore(value: 0), serviceRelease = DispatchSemaphore(value: 0)
    let storeRelease = DispatchSemaphore(value: 0)

    func reset() {
        lock.withLock {
            precondition(handoff == nil)
            blockDevice = false; blockService = false; blockStore = false; blockHandoff = false
            deviceEntered = false; serviceEntered = false; storeEntered = false; handoffEntered = false
            deviceFrees = 0; clientFrees = 0; installs = 0; progress = 0; readStarted = false
            callback = nil; context = nil; installResult = 0; opens = 0; script = []; commands = []
            productVersion = "3.1.3"; archives = [:]; lookups = 0
        }
    }
    func afterStore() {
        if lock.withLock({ storeEntered = blockStore; return blockStore }) { storeRelease.wait() }
    }
    func afterConnection() async {
        guard lock.withLock({ blockHandoff }) else { return }
        await withCheckedContinuation { continuation in
            lock.withLock { handoff = continuation; handoffEntered = true }
        }
    }
    func resumeHandoff() {
        let continuation = lock.withLock { let saved = handoff; handoff = nil; return saved }
        continuation?.resume()
    }
    func command(_ name: String, _ target: UnsafePointer<CChar>?, _ plist: plist_t?, _ callback: instproxy_status_cb_t?,
                 _ context: UnsafeMutableRawPointer?) -> instproxy_error_t {
        let (status, result) = lock.withLock {
            installs += 1; self.callback = callback; self.context = context
            options = IMDFake.value(plist) as? [String: String] ?? [:]
            let line = ([name, String(cString: target!)] + options.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
            commands.append(line.joined(separator: " "))
            return (script.isEmpty ? nil : script.removeFirst(), installResult)
        }
        if let status { DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) { self.emit(status) } }
        return instproxy_error_t(rawValue: result)
    }
    func emit(_ status: Int) {
        let (callback, context) = lock.withLock { (callback, context) }
        callback?(nil, UnsafeMutableRawPointer(bitPattern: status), context)
    }
}
/// installation_proxy and the device as the install path calls them (IMDFake), over Fixture.
nonisolated func fakeLibrary() {
    IMDFake.ideviceNew = { output, _ in
        precondition(String(cString: getenv("USBMUXD_SOCKET_ADDRESS")) == "127.0.0.1:1", "gate did not select the install endpoint before startup")
        let state = Fixture.shared
        let blocked = state.lock.withLock { state.deviceEntered = true; return state.blockDevice }
        if blocked { state.deviceRelease.wait() }
        state.lock.withLock { state.opens += 1 }
        output?.pointee = OpaquePointer(bitPattern: 17)
        return IDEVICE_E_SUCCESS
    }
    IMDFake.ideviceFree = { pointer in
        precondition(pointer == OpaquePointer(bitPattern: 17))
        Fixture.shared.lock.withLock { Fixture.shared.deviceFrees += 1; precondition(Fixture.shared.deviceFrees <= Fixture.shared.opens) }
        return IDEVICE_E_SUCCESS
    }
    // IMobileDevice.startInstallationProxy: lockdown's answers are IMDFake's defaults; the client is the boundary.
    IMDFake.instproxyClientNew = { device, _, output in
        precondition(device == OpaquePointer(bitPattern: 17))
        let state = Fixture.shared
        let blocked = state.lock.withLock { state.serviceEntered = true; return state.blockService }
        if blocked { state.serviceRelease.wait() }
        output?.pointee = OpaquePointer(bitPattern: 18)
        return INSTPROXY_E_SUCCESS
    }
    IMDFake.instproxyClientFree = { pointer in
        precondition(pointer == OpaquePointer(bitPattern: 18))
        let state = Fixture.shared
        // Model a final reader callback during join. Its retained context must
        // survive until this C free has returned, including immediate failures.
        state.emit(1)
        state.lock.withLock { state.clientFrees += 1; precondition(state.clientFrees <= state.opens) }
        return INSTPROXY_E_SUCCESS
    }
    IMDFake.instproxyCommand = { name, client, target, options, callback, context in
        let state = Fixture.shared
        switch name {
        case "install":
            precondition(client == OpaquePointer(bitPattern: 18) && String(cString: target!) == "PublicStaging/test.ipa")
        case "archive":
            state.lock.withLock { state.archives[String(cString: target!)] = ["ArchiveType": "DocumentsOnly"] }
        case "restore":
            state.lock.withLock { _ = state.archives.removeValue(forKey: String(cString: target!)) }   // Restore consumes the archive
        default: preconditionFailure("unexpected \(name)")
        }
        return state.command(name, target, options, callback, context)
    }
    IMDFake.instproxyLookupArchives = { client, _, result in
        precondition(client == OpaquePointer(bitPattern: 18))
        let state = Fixture.shared
        let archives = state.lock.withLock { state.lookups += 1; state.callback = nil; state.context = nil; return state.archives }   // no install callback is live
        result?.pointee = IMDFake.node(archives)
        return INSTPROXY_E_SUCCESS
    }
    IMDFake.instproxyStatusError = { status, name, description, _ in
        if status == UnsafeMutableRawPointer(bitPattern: 4) {   // iPhone OS 2.x's answer to Install of an installed bundle id
            name?.pointee = strdup("ApplicationAlreadyInstalled")
            return instproxy_error_t(rawValue: -9)
        }
        guard status == UnsafeMutableRawPointer(bitPattern: 3) else { return INSTPROXY_E_SUCCESS }
        name?.pointee = strdup("ApplicationVerificationFailed")
        description?.pointee = strdup("rejected fixture")
        return instproxy_error_t(rawValue: -5)
    }
    IMDFake.instproxyStatusName = { status, output in
        output?.pointee = strdup(status == UnsafeMutableRawPointer(bitPattern: 2) ? "Complete" : "Installing")
    }
    IMDFake.instproxyStatusPercent = { _, output in output?.pointee = 50 }
}
struct DeviceServices: Sendable {
    let clientSocket: String
    // AFC.swift's staging, not compiled here: each upload lands at the same path.
    func stage(_ ipa: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        Fixture.shared.lock.withLock { Fixture.shared.commands.append("stage \(ipa.lastPathComponent)") }
        return "PublicStaging/test.ipa"
    }
    func removeStaged(_ path: String) async { }
    func lockdownValue(_ key: String) async throws -> String? {
        precondition(key == "ProductVersion")
        return Fixture.shared.lock.withLock { Fixture.shared.productVersion }
    }
    func run<T: Sendable>(_ seconds: Double, _ label: String,
                          _ body: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        // The archive lookup's short query, without the gate's endpoint plumbing.
        var device: OpaquePointer?
        _ = IMobileDevice.openDevice(&device)
        defer { _ = idevice_free(device) }
        return try body(device!)
    }
}
'''
main = r'''
@main struct Check {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        precondition(condition(), "condition did not complete")
    }
    @MainActor static func launch() -> Task<Void, Error> {
        Task {
            try await DeviceServices(clientSocket: "127.0.0.1:1").install(stagedPath: "PublicStaging/test.ipa") { _, _ in
                Fixture.shared.lock.withLock { Fixture.shared.progress += 1 }
            }
        }
    }
    @MainActor static func expectFailure(_ task: Task<Void, Error>, _ expected: DeviceError?) async throws {
        let result = await withSoftDeadline(0.5) {
            do { try await task.value; return false }
            catch is CancellationError { return expected == nil }
            catch let error as DeviceError { return expected.map { "\($0)" == "\(error)" } ?? false }   // DeviceError is not Equatable
            catch { return false }
        }
        precondition(result == true, "install did not fail promptly with expected error")
    }
    @MainActor static func gateAvailable() async {
        let answer = await withSoftDeadline(0.2) { try? await DeviceGate.shared.serialized { 7 } }
        precondition(answer == .some(.some(7)), "startup failure held DeviceGate")
    }
    @MainActor static func main() async throws {
        Timeouts.serviceProbe = 0.04; Timeouts.installIdle = 0.20; Timeouts.installAbsolute = 1.0
        fakeLibrary()
        let state = Fixture.shared
        // Block each startup boundary, then let it return AFTER timeout or
        // cancellation. Neither the early exit nor a late handle may install.
        for atDevice in [true, false] {
            for cancel in [false, true] {
                state.reset()
                state.lock.withLock { state.blockDevice = atDevice; state.blockService = !atDevice }
                let task = launch()
                try await wait { state.lock.withLock { atDevice ? state.deviceEntered : state.serviceEntered } }
                if cancel { task.cancel() }
                try await expectFailure(task, cancel ? nil : .timedOut(operation: "install connection"))
                precondition(AbandonedWork.count == 1, "startup was not counted exactly once")
                await gateAvailable()
                precondition(state.lock.withLock { state.installs == 0 && state.deviceFrees == 0 && state.clientFrees == 0 })
                if atDevice { state.deviceRelease.signal() } else { state.serviceRelease.signal() }
                try await wait { AbandonedWork.count == 0 }
                precondition(state.lock.withLock { state.installs == 0 && state.deviceFrees == 1 && state.clientFrees == (atDevice ? 0 : 1) })
            }
        }
        // Deadline wins after the connection is stored but before its result
        // is delivered: the consumer side owns and closes both late handles.
        state.reset(); state.lock.withLock { state.blockStore = true }
        let stored = launch()
        try await wait { state.lock.withLock { state.storeEntered } }
        try await expectFailure(stored, .timedOut(operation: "install connection"))
        await gateAvailable()
        precondition(state.lock.withLock { state.installs == 0 && state.deviceFrees == 1 && state.clientFrees == 1 })
        precondition(AbandonedWork.count == 1)
        state.storeRelease.signal()
        try await wait { AbandonedWork.count == 0 }

        // Cancellation in the handoff gap must close a successful connection
        // exactly once, without ever submitting the guest mutation.
        state.reset(); state.lock.withLock { state.blockHandoff = true }
        let handoff = launch()
        try await wait { state.lock.withLock { state.handoffEntered } }
        handoff.cancel(); state.resumeHandoff()
        try await expectFailure(handoff, nil)
        precondition(state.lock.withLock { state.installs == 0 && state.deviceFrees == 1 && state.clientFrees == 1 })
        precondition(AbandonedWork.count == 0)
        await gateAvailable()

        // A real submitted installation remains owned, even after cancellation,
        // until its terminal callback; queued reads cannot interrupt it.
        state.reset()
        let normal = launch()
        try await wait { state.lock.withLock { state.installs == 1 } }
        let read = Task { try await DeviceGate.shared.serialized { state.lock.withLock { state.readStarted = true }; return 9 } }
        normal.cancel(); state.emit(1)
        try await Task.sleep(for: .milliseconds(20))
        precondition(state.lock.withLock { state.clientFrees == 0 && state.deviceFrees == 0 && !state.readStarted })
        precondition(AbandonedWork.count == 0)
        state.emit(2)
        try await normal.value
        let value = try await read.value
        precondition(value == 9)
        precondition(state.lock.withLock { state.clientFrees == 1 && state.deviceFrees == 1 && state.progress >= 2 && state.readStarted })
        // One progress call came from the C free's simulated final callback.

        state.reset(); state.lock.withLock { state.installResult = -4 }
        try await expectFailure(launch(), .instproxy(.init(code: -4), phase: "start"))
        precondition(state.lock.withLock { state.clientFrees == 1 && state.deviceFrees == 1 && state.progress == 1 })
        state.reset()
        let rejected = launch()
        try await wait { state.lock.withLock { state.installs == 1 } }
        state.emit(3)
        try await expectFailure(rejected, .instproxy(.init(code: -5), phase: "rejected fixture"))
        precondition(state.lock.withLock { state.clientFrees == 1 && state.deviceFrees == 1 })

        // The existing mutation watchdog alone accounts for an idle install.
        // It must not be nested inside a second deadline or free live callbacks.
        state.reset()
        try await expectFailure(launch(), .timedOut(operation: "install"))
        precondition(AbandonedWork.count == 1)
        precondition(state.lock.withLock { state.installs == 1 && state.clientFrees == 0 && state.deviceFrees == 0 })
        await gateAvailable()
        try await wait { AbandonedWork.count == 0 }
        // A new version of an installed app. 3.x+ installd upgrades through Install: one command.
        state.reset(); state.lock.withLock { state.script = [2] }
        try await DeviceServices(clientSocket: "127.0.0.1:1").install(URL(fileURLWithPath: "/tmp/new.ipa"), staged: "PublicStaging/test.ipa",
                                                                       bundleID: "com.example.app") { _, _ in }
        precondition(state.lock.withLock { state.commands } == ["install PublicStaging/test.ipa"], "\(state.commands)")
        // 2.x refuses with ApplicationAlreadyInstalled and has consumed the upload: it goes up again and replaces
        // the old app, keeping its data (documents-only archive, install, restore into the new container).
        state.reset(); state.lock.withLock { state.script = [4, 2, 2, 2] }
        try await DeviceServices(clientSocket: "127.0.0.1:1").install(URL(fileURLWithPath: "/tmp/new.ipa"), staged: "PublicStaging/test.ipa",
                                                                       bundleID: "com.example.app") { _, _ in }
        let replaced = state.lock.withLock { state.commands }
        precondition(replaced == ["install PublicStaging/test.ipa", "stage new.ipa", "archive com.example.app ArchiveType=DocumentsOnly",
                                  "install PublicStaging/test.ipa", "restore com.example.app ArchiveType=DocumentsOnly"],
                     "2.x upgrade sequence: \(replaced)")
        precondition(state.lock.withLock { state.deviceFrees == state.opens && state.clientFrees == state.opens })
        await gateAvailable()

        // 2.x: the replacement's Install fails after the archive. The archive (the app's data) stays, the error says
        // so, and the next install of the app that succeeds restores it.
        state.reset(); state.lock.withLock { state.productVersion = "2.1.1"; state.script = [4, 2, 3] }
        do {
            try await DeviceServices(clientSocket: "127.0.0.1:1").install(URL(fileURLWithPath: "/tmp/new.ipa"), staged: "PublicStaging/test.ipa",
                                                                           bundleID: "com.example.app") { _, _ in }
            preconditionFailure("a failed replacement reported success")
        } catch DeviceError.failed(let message) {
            precondition(message.contains("data is kept"), message)
        }
        precondition(state.lock.withLock { state.commands.last == "install PublicStaging/test.ipa" && state.archives["com.example.app"] != nil },
                     "archive dropped or restored after a failed install: \(state.commands)")
        state.lock.withLock { state.commands = []; state.script = [2, 2] }
        try await DeviceServices(clientSocket: "127.0.0.1:1").install(URL(fileURLWithPath: "/tmp/new.ipa"), staged: "PublicStaging/test.ipa",
                                                                       bundleID: "com.example.app") { _, _ in }
        let next = state.lock.withLock { state.commands }
        precondition(next == ["install PublicStaging/test.ipa", "restore com.example.app ArchiveType=DocumentsOnly"],
                     "kept data not restored by the next install: \(next)")
        precondition(state.lock.withLock { state.archives.isEmpty })
        // 3.x+: an archive is never looked up or restored by a plain install.
        state.reset(); state.lock.withLock { state.archives = ["com.example.app": [:]]; state.script = [2] }
        try await DeviceServices(clientSocket: "127.0.0.1:1").install(URL(fileURLWithPath: "/tmp/new.ipa"), staged: "PublicStaging/test.ipa",
                                                                       bundleID: "com.example.app") { _, _ in }
        precondition(state.lock.withLock { state.commands == ["install PublicStaging/test.ipa"] && state.lookups == 0 })
        await gateAvailable()
        print("PASS: bounded device/service startup, cancellation/handoff races, late-handle cleanup, gate reuse, owned terminal callback and single watchdog accounting, 2.x upgrade by archive/install/restore, kept archive restored by the next install")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ltm-install-startup-") as directory:
    path = Path(directory)
    swift = path / "check.swift"
    swift.write_text(fixture + main)
    (path / "InstallationProxy.swift").write_text(install)
    (path / "DeviceExecution.swift").write_text(execution)
    binary = path / "check"
    subprocess.run(["xcrun", "swiftc", *engine(root), *leaves(root), *local_engine_stub(path), "-parse-as-library", "-swift-version", "6",
                    "-default-isolation", "MainActor", "-module-cache-path", str(path / "modules"),
                    str(path / "InstallationProxy.swift"), str(path / "DeviceExecution.swift"),
                    str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
