#!/usr/bin/env python3
"""The app's side of host power, run from the production sources with a fake link:

  visible   EmulatorController.screenVisible: each change goes to the helper once (LinkCommand.screenVisible) and moves the
            status poll between 30 Hz (shown) and 4 Hz (hidden)
  sleep     NSWorkspace will-sleep pauses a running device and did-wake resumes it and re-syncs the guest's clock
            (the lockdown time sync); a device the user paused stays paused, one that was not running is left alone
  activity  InstallationQueue holds a user-initiated activity while busy: pmset lists this process as preventing idle
            sleep then, and not once it is released
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
import re, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
s = (root / "LightTouchMac/Device/EmulatorController.swift").read_text()


def block(start, end):
    a = s.index(start)
    return s[a:s.index(end, a)]


sliced = (block("    private func startStatusPoll()", "    /// For a restart:")
          + block("    private var pausedForHostSleep", "    /// Per-user machine state")
          + block("    func pause()  {", "    /// The guest cold-boots"))
source = r'''import AppKit
func logEvent(_ s: String) {}
@MainActor final class Controller {
    enum State { case running, paused, poweredOff }
    var state = State.running
    var shuttingDown = false, storageFailed = false
    var statusTimer: Timer?
    var sent: [LinkCommand] = []
    var synced: [Int] = []
    var bootGeneration = 7
    struct Link { let c: Controller; func send(_ x: LinkCommand) { c.sent.append(x) } }
    var link: Link? { Link(c: self) }
    func pollStorageFailure() {}
    func scheduleTimeZoneSync(generation: Int) { synced.append(generation) }
''' + sliced + r'''}

func holdsIdleSleep() -> Bool {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g", "assertions"]
    p.standardOutput = out
    try! p.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return text.split(separator: "\n").contains { $0.contains("pid \(getpid())(") && $0.contains("PreventUserIdleSystemSleep") }
}

@main struct Check {
    @MainActor static func main() async {
        let c = Controller()
        c.screenVisible = true
        c.statusTimer = Timer(timeInterval: 1, repeats: false) { _ in }
        c.screenVisible = true
        precondition(c.sent == [.screenVisible(true)], "\(c.sent)")
        c.screenVisible = false
        precondition(c.sent == [.screenVisible(true), .screenVisible(false)], "\(c.sent)")
        precondition(abs(c.statusTimer!.timeInterval - 0.25) < 1e-9, "hidden: 4 Hz, not \(c.statusTimer!.timeInterval)")
        c.screenVisible = true
        precondition(abs(c.statusTimer!.timeInterval - 1.0 / 30) < 1e-9, "shown: 30 Hz")

        c.sent = []
        c.hostWillSleep()
        precondition(c.state == .paused && c.sent == [.machine(.pause)], "sleep pauses: \(c.sent)")
        c.hostDidWake()
        precondition(c.state == .running && c.sent == [.machine(.pause), .machine(.resume)] && c.synced == [7],
                     "wake resumes and syncs the clock: \(c.sent) \(c.synced)")
        c.hostDidWake()
        precondition(c.synced == [7], "a second wake does nothing")
        let paused = Controller(); paused.state = .paused
        paused.hostWillSleep(); paused.hostDidWake()
        precondition(paused.state == .paused && paused.sent.isEmpty && paused.synced.isEmpty, "the user's pause stays")
        let off = Controller(); off.state = .poweredOff
        off.hostWillSleep(); off.hostDidWake()
        precondition(off.sent.isEmpty && off.synced.isEmpty, "a device not running is left alone")

        let queue = InstallationQueue()
        precondition(!holdsIdleSleep(), "no assertion before any work")
        try! await queue.acquire()
        precondition(holdsIdleSleep(), "an install holds off idle sleep")
        queue.release()
        precondition(!holdsIdleSleep(), "released once the queue is idle")
        print("PASS: visibility reaches the helper once per change and paces the status poll; Mac sleep pauses and wake resumes "
              + "with a clock sync; installs hold off idle sleep")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ltm-host-power-") as d:
    p = Path(d) / "check.swift"
    p.write_text(source)
    subprocess.run(["swiftc", *host_runtime.swift_flags(root), str(root / "Shared/DeviceLinkProtocol.swift"),
                    str(root / "LightTouchMac/Features/InstallationQueue.swift"), str(root / "LightTouchMac/App/UserActivity.swift"),
                    "-parse-as-library", "-default-isolation", "MainActor", "-module-cache-path", d + "/modules", str(p), "-o", d + "/check"],
                   check=True)
    subprocess.run([d + "/check"], check=True, timeout=30)
