#!/usr/bin/env python3
"""The helper engine's ResumeOnce (LightTouchServices/Engine/DeviceExecution.swift, compiled whole): a timed-out
request's accounting finishes before the losing worker returns. The engine is the helper target's, so this stays
here; the archive-root and freshness halves are IPAMembersTests and AppsInspectorRowsTests."""
from pathlib import Path
import subprocess, tempfile
import sys as _sys, pathlib as _pl; _sys.path.insert(0, str(_pl.Path(__file__).resolve().parents[2] / "scripts"))
root = Path(__file__).resolve().parents[2]
once = (root/'LightTouchServices/Engine/DeviceExecution.swift').read_text()   # ResumeOnce is file-private, so the whole file goes in
source = '''import Foundation
nonisolated func logEvent(_ message: String) {}
import Dispatch
''' + once + '''
@main struct Check {
 static func main() async throws {
  let once = ResumeOnce<Int>()
  let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
  let counter = Counter()
  let winner = Task.detached {
   once.resume(.success(1), onWin: { entered.signal(); release.wait(); counter.add(1) })
  }
  await Task.detached { blockingWait(entered) }.value
  let loser = Task.detached { if !once.resume(.success(2)) { counter.add(-1) } }
  release.signal()
  _ = await winner.value; await loser.value
  precondition(counter.value == 0)
  let result = try await withCheckedThrowingContinuation { once.attach($0) }
  precondition(result == 1)
  print("PASS: timeout accounting serialized before losing worker returns")
 }
}
func blockingWait(_ semaphore: DispatchSemaphore) { semaphore.wait() }
final class Counter: @unchecked Sendable {
 private let lock = NSLock()
 private var n = 0
 func add(_ d: Int) { lock.withLock { n += d } }
 var value: Int { lock.withLock { n } }
}
'''
with tempfile.TemporaryDirectory() as work:
    swift=Path(work)/'check.swift';swift.write_text(source)
    executable=Path(work)/'check'
    subprocess.run(['swiftc', *__import__('host_service').wire_flags(__import__('pathlib').Path(__file__).resolve().parents[2]),'-parse-as-library','-module-cache-path','/tmp/ltm-module-cache',str(swift),'-o',str(executable)],check=True)
    subprocess.run([str(executable)],check=True)
