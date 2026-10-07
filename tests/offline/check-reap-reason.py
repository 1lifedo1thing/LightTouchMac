#!/usr/bin/env python3
"""The shared session owner classifies a helper's death by what was asked of it, not by which message won the exit race.

Packages/DeviceRuntime/Sources/DeviceRuntime/DeviceSessionProcess.swift, compiled whole, runs against a fake link
whose exit report arrives one reap retry (10 ms) after the helper dies (the race through the real owner: boot, then
Stop or a crash). The classification itself, the app's three labels and the link draining its last frame before it
closes are LightTouchCoreTests' DeviceProcessTests; this stays here because it swaps DeviceLink for a fake. A requested stop whose qemuExited
event was lost (the helper exited before sending it: DeviceHost.halt racing QEMU's own SIGTERM handler) is still
"The iPod stopped."; a crash or kill nobody asked for is "stopped unexpectedly" (the code and signal go to the log)."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
# The race through the real session owner (DeviceSessionProcess.swift, compiled whole) against a fake DeviceLink:
# the helper boots, then dies; its exit report lands 10 ms after any qemuExited event (or with none).
link = (root / 'Packages/DeviceRuntime/Sources/DeviceRuntime/DeviceLink.swift').read_text()
types = ''.join(link[link.index(f'nonisolated public enum {name}'):link.index('\n}\n', link.index(f'nonisolated public enum {name}')) + 3]
                for name in ('DeviceLinkError', 'DeviceTermination'))
race = 'import Foundation\nimport HostRuntime\n' + types + r'''
public struct SharedStatus {}
/// DeviceLink's surface: start + boot succeed; terminate/kill/die report the exit one reap retry later.
@MainActor public final class DeviceLink {
 public struct Configuration { var instance: UUID }
 init(configuration: Configuration) {}
 public var onEvent: ((LinkEvent) -> Void)?
 public var onTerminated: ((DeviceTermination) -> Void)?
 public var info: HelperInfo? { nil }
 public var status: SharedStatus? { nil }
 public var pid: pid_t = 0
 var sendsExitEvent = true
 func start(_ done: @escaping (Result<HelperInfo, DeviceLinkError>) -> Void) {
  pid = 4242; done(.success(HelperInfo(protocolVersion: 1, pid: 4242, dylibPath: "", dylibModified: 0)))
 }
 func request(_ request: LinkRequest, timeout: TimeInterval, _ done: @escaping (Result<LinkReply, DeviceLinkError>) -> Void) { done(.success(.ok(true))) }
 func terminate() { die(.exited(0)) }
 func kill() { die(.signaled(9)) }
 func die(_ how: DeviceTermination) {
  if sendsExitEvent, case .exited(let code) = how { onEvent?(.qemuExited(code)) }
  DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { self.onTerminated?(how) }
 }
}
@main struct Main {
 @MainActor static func main() async {
  func death(_ act: (DeviceSessionProcess) -> Void) async -> DeviceProcessDeath? {
   let p = DeviceSessionProcess(configuration: .init(instance: UUID()))
   var booted = false
   p.start({ _ in BootConfig(argv: [], machine: "iPod-Touch") }) { if case .success = $0 { booted = true } }
   precondition(booted, "the fake boot failed")
   act(p)
   let start = Date()
   while !p.isDead, Date().timeIntervalSince(start) < 1 { try? await Task.sleep(for: .milliseconds(5)) }
   return p.death
  }
  let cases: [(DeviceProcessDeath, (DeviceSessionProcess) -> Void)] = [
   (.stopped, { $0.terminate() }),                                         // Stop; QEMU's exit reported first
   (.stopped, { $0.link.sendsExitEvent = false; $0.terminate() }),         // the race: exited 0 before qemuExited
   (.stopped, { $0.link.die(.exited(0)) }),                                // the guest powered off: QEMU exited 0
   (.unexpected, { $0.link.sendsExitEvent = false; $0.link.die(.exited(0)) }),   // nobody asked
   (.unexpected, { $0.link.die(.signaled(11)) }),
   (.unexpected, { $0.link.sendsExitEvent = false; $0.link.die(.exited(70)) }),
   (.unexpected, { $0.link.die(.exited(1)) }),
   (.unexpected, { $0.kill() }),
  ]
  for (i, (expected, act)) in cases.enumerated() {
   let got = await death(act)
   precondition(got == expected, "case \(i): expected \(expected), got \(String(describing: got))")
  }
  print("PASS: through the real session owner, a booted helper's Stop is .stopped with or without the qemuExited event; crashes, kills and unasked exits are .unexpected")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-reap-') as d:
    p = Path(d) / 'race.swift'; p.write_text(race)
    subprocess.run(['swiftc', *host_runtime.swift_flags(root), '-parse-as-library', '-module-cache-path', d + '/modules',
                    str(root / 'Packages/DeviceRuntime/Sources/DeviceRuntime/DeviceLinkProtocol.swift'), str(root / 'Packages/DeviceRuntime/Sources/DeviceRuntime/DeviceSessionProcess.swift'), str(p), '-o', d + '/race'], check=True)
    subprocess.run([d + '/race'], check=True, timeout=8)
