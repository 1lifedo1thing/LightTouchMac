#!/usr/bin/env python3
"""Execute the production Stop (EmulatorController.halt) against fake helpers: a hard halt, never a guest shutdown.
And Shut Down (shutDown): it asks the guest (.machine(.shutdown)) and waits for it to power off, gives up after its
budget, and Force Stop can take over while it waits."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
s = (root / 'LightTouchMac/Device/EmulatorController.swift').read_text()
a = s.index('    static let haltBudget:'); b = s.index('    /// Stop the guest and its helper, erase this device', a)
retire = s[s.index("    private func retireBoot()"):s.index("    func stop()", s.index("    private func retireBoot()"))]
halt = s[a:b].replace('haltBudget: TimeInterval = 10', 'haltBudget: TimeInterval = 0.3')
assert 'serviceTeardownBudget: TimeInterval = 2' in halt, 'Stop bounds the services worker teardown'
halt = halt.replace('serviceTeardownBudget: TimeInterval = 2', 'serviceTeardownBudget: TimeInterval = 0.3')
assert 'shutdownBudget: TimeInterval = 90 * Board.hostSlowdown' in halt
halt = halt.replace('shutdownBudget: TimeInterval = 90 * Board.hostSlowdown', 'shutdownBudget: TimeInterval = 0.5')
source = r'''import Foundation
nonisolated func logEvent(_ s: String) {}
/// DeviceProcess's surface: SIGTERM exits it (or not, when hung); SIGKILL always does.
@MainActor final class FakeProcess {
 var hung = false, terms = 0, kills = 0, quits = 0, isDead = false
 func terminate() { terms += 1; if !hung { Task { try? await Task.sleep(for: .milliseconds(30)); self.isDead = true } } }
 func kill() { kills += 1; isDead = true }
 func waitForExit(timeout: TimeInterval) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while !isDead, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
  return isDead
 }
}
@MainActor enum AppInstaller { static func discard(for id: UUID) {} }
@MainActor final class Controller {
 struct Instance { let id = UUID() }
 let instance = Instance()
 var storageFailed = false
 var sent: [LinkCommand] = []
 enum State { case notStarted, booting, running, paused, poweredOff }
 var state = State.booting, isDead = false, isErasing = false, shuttingDown = false, halting = false
 var isPoweredOff: Bool { state == .poweredOff }
 var connectionRecoveryTask: Task<Void, Never>?, orientationTask: Task<Void, Never>?, foregroundTask: Task<Void, Never>?, readinessTask: Task<Void, Never>?, haltTask: Task<Void, Never>?, bootWatchTask: Task<Void, Never>?
 let bootScope = BootSessionScope()
 var workerRetirement: Task<Void, Never>?
 func retireDeveloperConnection() {}
 /// The services worker's teardown; `hang`: one that never finishes.
 struct Service { let hang: Bool; func stopWorker() async { if hang { try? await Task.sleep(for: .seconds(3600)) } } }
 var hangWorker = false
 var services: Service { get throws { Service(hang: hangWorker) } }
 func stopTimeZoneSync() {}
 var haltCompletions: [(Bool) -> Void] = []
 var process: FakeProcess? = FakeProcess()
 var filesMeddled = false
 @MainActor struct FakeLink { let process: FakeProcess?; let record: (LinkCommand) -> Void
  func send(_ c: LinkCommand) { record(c); if case .machine(.quit) = c { process?.quits += 1; process?.terminate() } } }
 var link: FakeLink? { FakeLink(process: process, record: { self.sent.append($0) }) }
''' + retire + halt + r'''
 func powerOffForCheck(_ done: @escaping (Bool) -> Void) { guard canForceStop else { return done(false) }; halt(completion: done) }
}
@main struct Main {
 @MainActor static func main() async throws {
  // Mid-boot (never lit, no guest services): Stop still halts, and requests join.
  let c = Controller(); c.readinessTask = Task { try? await Task.sleep(for: .seconds(60)) }
  precondition(c.canStop)
  var results: [Bool] = []
  let started = Date()
  await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
   c.halt { results.append($0); if results.count == 2 { done.resume() } }
   c.halt { results.append($0); if results.count == 2 { done.resume() } }
   precondition(c.shuttingDown && !c.canStop && c.readinessTask!.isCancelled)
  }
  precondition(results == [true, true] && c.process!.terms == 1 && c.process!.kills == 0 && !c.shuttingDown)
  precondition(Date().timeIntervalSince(started) < 1, "a halt waited on the guest")
  // A helper that ignores SIGTERM is killed after the budget.
  let hung = Controller(); hung.process!.hung = true
  let killed = await withCheckedContinuation { done in hung.halt { done.resume(returning: $0) } }
  precondition(killed && hung.process!.kills == 1)
  // A gone helper or a powered-off guest is already stopped.
  let gone = Controller(); gone.process!.isDead = true
  var goneResult: Bool?; gone.halt { goneResult = $0 }
  precondition(goneResult == true && gone.process!.terms == 0)
  // Files changed under the device: quit QEMU outright, no SIGTERM (no pause, no flush into dead inodes).
  let meddled = Controller(); meddled.filesMeddled = true
  let quitResult = await withCheckedContinuation { done in meddled.halt { done.resume(returning: $0) } }
  precondition(quitResult && meddled.process!.quits == 1 && meddled.process!.terms == 1 && meddled.process!.kills == 0)
  // A services worker whose teardown never finishes: Stop still completes after its short bound,
  // and a hung helper is still killed (the escalation doesn't wait on the worker).
  let stuck = Controller(); stuck.hangWorker = true
  let stuckStart = Date()
  let stuckResult = await withCheckedContinuation { done in stuck.halt { done.resume(returning: $0) } }
  precondition(stuckResult && stuck.process!.terms == 1 && !stuck.shuttingDown && Date().timeIntervalSince(stuckStart) < 2)
  let stuckHung = Controller(); stuckHung.hangWorker = true; stuckHung.process!.hung = true
  let stuckKilled = await withCheckedContinuation { done in stuckHung.halt { done.resume(returning: $0) } }
  precondition(stuckKilled && stuckHung.process!.kills == 1)
  // Shut Down: the guest is asked, and it's done once the guest has powered itself off (the helper stays).
  let clean = Controller(); clean.state = .running
  precondition(clean.canShutDown)
  var cleanResult: Bool?
  clean.shutDown { cleanResult = $0 }
  precondition(clean.sent.contains(.machine(.shutdown)) && clean.shuttingDown && clean.isShuttingDownCleanly && !clean.canShutDown && clean.canForceStop)
  try await Task.sleep(for: .milliseconds(100))
  precondition(cleanResult == nil, "finished before the guest powered off")
  clean.state = .poweredOff
  try await Task.sleep(for: .milliseconds(400))
  precondition(cleanResult == true && !clean.shuttingDown && clean.process!.terms == 0, "shut down: \(String(describing: cleanResult))")
  // A guest that never powers off: false after the budget, the device left running.
  let stubborn = Controller(); stubborn.state = .running
  let gaveUp = await withCheckedContinuation { done in stubborn.shutDown { done.resume(returning: $0) } }
  precondition(!gaveUp && !stubborn.shuttingDown && stubborn.state == .running && stubborn.canShutDown)
  // Force Stop while a Shut Down waits: the halt takes over and the Shut Down ends without clearing its flag early.
  let forced = Controller(); forced.state = .running
  var forcedShutDown: Bool?
  forced.shutDown { forcedShutDown = $0 }
  let halted = await withCheckedContinuation { done in forced.powerOffForCheck { done.resume(returning: $0) } }
  try await Task.sleep(for: .milliseconds(300))
  precondition(halted && forced.process!.terms == 1 && forcedShutDown == true && !forced.shuttingDown, "force stop over a shut down: \(String(describing: forcedShutDown))")
  print("PASS: Shut Down asks the guest and waits for it to power off, gives up after its budget, Force Stop takes over")
  print("PASS: Stop mid-boot halts at once, joined requests, a hung helper is killed, meddled files skip the flush, a stuck services worker can't hold Stop")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-halt-') as d:
    p = Path(d) / 'check.swift'; p.write_text(source)
    subprocess.run(['swiftc', *host_runtime.swift_flags(Path(__file__).resolve().parents[2]), '-parse-as-library', '-module-cache-path', d + '/modules', str(root / 'Packages/DeviceRuntime/Sources/DeviceRuntime/DeviceLinkProtocol.swift'), str(root / 'LightTouchMac/Device/BootSessionScope.swift'), str(p), '-o', d + '/check'], check=True)
    subprocess.run([d + '/check'], check=True, timeout=8)
