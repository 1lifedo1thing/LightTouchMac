#!/usr/bin/env python3
"""Real connection probes preserve errors and abandon queued reads safely: Services/DeviceServices.swift
(checkAttachment), Transport/IMobileDevice.swift and Transport/DeviceExecution.swift compiled whole against a fake
libimobiledevice (idevice_new), plus the inspector's read-suppression predicate (one declaration, looked up by name)."""
from pathlib import Path
import subprocess, tempfile
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import swift_subprocess
sys.path.insert(0, str(Path(__file__).resolve().parent))
from host_service_fixtures import engine

root = Path(__file__).resolve().parents[2]
app = root / 'LightTouchMac'
inspector = (app / 'UI/AppsInspectorViewController.swift').read_text()
suppression = next(line for line in inspector.splitlines() if 'private var readsSuppressed:' in line).replace('private ', '')

source = r'''
import Foundation
nonisolated func logEvent(_ message: String) {}
/// The attachment check's one call: idevice_new over the gate-selected endpoint, attached unless told otherwise.
nonisolated enum Attachment {
 static let lock = NSLock()
 nonisolated(unsafe) static var attached = true
 static func set(attached value: Bool) { lock.withLock { attached = value } }
 static func install() {
  IMDFake.ideviceNew = { device, _ in
   precondition(String(cString: getenv("USBMUXD_SOCKET_ADDRESS")) == "fixture", "gate did not select the endpoint before the attachment call")
   guard lock.withLock({ attached }) else { return IDEVICE_E_NO_DEVICE }
   device?.pointee = OpaquePointer(bitPattern: 1); return IDEVICE_E_SUCCESS
  }
 }
}
/// Resumes one waiter once, whichever side comes first.
nonisolated final class Signal: @unchecked Sendable {
 private let lock = NSLock()
 private var fired = false, waiter: CheckedContinuation<Void, Never>?
 func fire() {
  let w: CheckedContinuation<Void, Never>? = lock.withLock { fired = true; defer { waiter = nil }; return waiter }
  w?.resume()
 }
 func wait() async {
  await withCheckedContinuation { c in
   if lock.withLock({ if fired { return true }; waiter = c; return false }) { c.resume() }
  }
 }
}
@MainActor final class Inspector {
 final class Emulator { var hasFileTransfer = false, isReconnecting = false, preparingDevice = false }
 let emulator = Emulator()
 var installing = false
 var uninstalling: Set<String> = []
''' + suppression + r'''
}
@main struct Check {
 @MainActor static func main() async throws {
  Timeouts.serviceProbe = 0.015
  Attachment.install()
  let device = DeviceServices(clientSocket: "fixture", local: true)
  try await device.checkAttachment()
  Attachment.set(attached: false)
  do { try await device.checkAttachment(); preconditionFailure() }
  catch DeviceError.notAttached {} catch { throw error }
  Attachment.set(attached: true)

  // A probe waiting behind a long write must time out, leave the gate queue,
  // and retain a USB-specific cause instead of resetting app services.
  let held = Signal(), entered = Signal()
  let owner = Task {
   try await DeviceGate.shared.serialized {
    entered.fire()
    await held.wait()
   }
  }
  await entered.wait()
  do { try await device.checkAttachment(); preconditionFailure() }
  catch DeviceError.timedOut(let operation) { precondition(operation == "USB connection") }
  catch { throw error }
  precondition(AbandonedWork.count == 0, "waiting is not a blocked C request")
  held.fire(); try await owner.value
  try await device.checkAttachment()

  let cancelled = Task { try await device.checkAttachment() }
  cancelled.cancel()
  do { try await cancelled.value; preconditionFailure() }
  catch is CancellationError {} catch { throw error }

  let inspector = Inspector()
  inspector.uninstalling = ["queued-behind-paused-install"]
  precondition(!inspector.readsSuppressed, "queued removal must not deadlock recovery")
  inspector.installing = true; precondition(inspector.readsSuppressed)
  inspector.installing = false; inspector.emulator.hasFileTransfer = true
  precondition(inspector.readsSuppressed)
  inspector.emulator.hasFileTransfer = false; inspector.emulator.isReconnecting = true
  precondition(inspector.readsSuppressed)
  inspector.emulator.isReconnecting = false; inspector.emulator.preparingDevice = true
  precondition(inspector.readsSuppressed, "boot preparation owns device services too")
  print("PASS: typed health failures, bounded queued probes, cancellation, and health reads during paused removals")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-health-') as d:
    p = Path(d)/'check.swift'; p.write_text(source)
    subprocess.run(['swiftc', *engine(root), *swift_subprocess.swift_flags(root), *[str(app/'Services'/name) for name in ['HostServiceTypes.swift','HostServiceProtocol.swift','HostServiceResources.swift','HostServiceWorkers.swift']], '-swift-version', '6', '-parse-as-library', '-module-cache-path', d+'/modules',
                    str(app / 'Services/DeviceServices.swift'), str(app / 'Transport/DeviceExecution.swift'), str(p),
                    '-o', d+'/check'], check=True)
    subprocess.run([d+'/check'], check=True, timeout=10)
