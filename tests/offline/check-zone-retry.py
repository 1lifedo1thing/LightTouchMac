#!/usr/bin/env python3
"""DeviceServices.setTimeZone (LockdownTools.swift) against a fake lockdown-tz that drops the first writes.

A zone write the guest drops (exit 4: 4.x's locationd kept its first external zone, or the write landed while
it_prefs restarted locationd) is written again: with no agent, after 5 s; with an agent holding locationd's
first-zone record, at once after clearing it. Three more writes at most, then zoneKept.
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime, swift_subprocess
import subprocess, tempfile, time

ROOT = Path(__file__).resolve().parents[2]
stubs = r'''import Foundation
func logEvent(_ s: String) {}
enum DeviceToolsError: Error { case zoneKept(String), failed(String), toolMissing(String) }
enum Timeouts { nonisolated(unsafe) static var query = 15.0 }
enum Bundled { static func tool(_ name: String) -> String? { nil } }
struct DeviceServices { let clientSocket: String }
final class Agent { let alive: Bool; init(_ alive: Bool) { self.alive = alive }; func waitAlive(seconds: Double) async -> Bool { alive } }
final class GuestServices {
    let agent: Agent; var record: Bool; var forgets = 0
    init(alive: Bool, record: Bool) { agent = Agent(alive); self.record = record }
    func forgetExternalTimeZone() async throws -> Bool { forgets += 1; defer { record = false }; return record }
}

@main struct Check {
    static func run(_ dir: String, drops: Int, guest: GuestServices?) async -> (Result<String, Error>, writes: Int, seconds: Double) {
        let state = "\(dir)/state-\(UUID().uuidString)"
        try! "\(drops)".write(toFile: state + ".drops", atomically: true, encoding: .utf8)
        let start = Date()
        let result: Result<String, Error>
        do { result = .success(try await DeviceServices.setTimeZone("America/New_York", tool: "\(dir)/lockdown-tz", socket: state, guest: guest)) }
        catch { result = .failure(error) }
        let writes = Int((try? String(contentsOfFile: state, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
        return (result, writes, Date().timeIntervalSince(start))
    }

    static func main() async {
        let dir = CommandLine.arguments[1]
        var r = await run(dir, drops: 1, guest: nil)
        precondition((try? r.0.get()) == "America/New_York" && r.writes == 2 && r.seconds >= 4.5,
                     "a dropped write with no agent is written again 5 s later: \(r)")
        let agent = GuestServices(alive: true, record: true)
        r = await run(dir, drops: 1, guest: agent)
        precondition((try? r.0.get()) == "America/New_York" && r.writes == 2 && agent.forgets == 1 && r.seconds < 4,
                     "the agent clears locationd's first zone and the write goes again at once: \(r)")
        r = await run(dir, drops: 99, guest: nil)
        guard case .failure(DeviceToolsError.zoneKept("US/Pacific")) = r.0, r.writes == 4 else {
            preconditionFailure("a zone the device keeps is given up after 4 writes: \(r)")
        }
        print("PASS: dropped zone writes are retried (5 s without an agent, at once after clearing the record), kept after 4")
    }
}
'''
tool = '''#!/bin/sh
# lockdown-tz ZONE ...: state in $USBMUXD_SOCKET_ADDRESS (writes so far) and .drops (how many to drop)
f="$USBMUXD_SOCKET_ADDRESS"; n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo $n > "$f"
if [ $n -le $(cat "$f.drops") ]; then echo US/Pacific; exit 4; fi
echo "$2"
'''
with tempfile.TemporaryDirectory(prefix="ltm-zone-retry-") as d:
    work = Path(d)
    (work / "lockdown-tz").write_text(tool)
    (work / "lockdown-tz").chmod(0o755)
    (work / "check.swift").write_text(stubs)
    subprocess.run(["xcrun", "swiftc", *host_runtime.swift_flags(ROOT), *swift_subprocess.swift_flags(ROOT), "-swift-version", "5",
                    "-parse-as-library", "-module-cache-path", str(work / "modules"),
                    str(ROOT / "LightTouchMac/Services/LockdownTools.swift"), str(ROOT / "LightTouchMac/Services/ClockRegion.swift"),
                    str(work / "check.swift"), "-o", str(work / "check")], check=True)
    subprocess.run([str(work / "check"), d], check=True, timeout=120)
