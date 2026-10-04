#!/usr/bin/env python3
"""The production Battery controls: every boot starts from the menu's level and Charging choice (a new QEMU
otherwise sits at its own 80% while the menu shows 100%, the iPad's "82%"); Charging is the iPad's USB port
current (usb-charger, then a replug so the guest re-reads it) and the iPod's charger mode."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
s = (root / 'LightTouchMac/Device/EmulatorController.swift').read_text()
a = s.index('    // MARK: Battery, charger and compass'); b = s.index('    private(set) var compassHeading', a)
battery = s[a:b]
a = s.index('    private func noteFrameAdvanced() {'); b = s.index('    /// Frames within the last', a)
frame = s[a:b]
source = r"""import Foundation
struct Profile { let canChooseUSBCharger: Bool }
enum State { case booting, running }
enum ScopeKey { case usbReconnect }
struct Scope { subscript(_ k: ScopeKey) -> Task<Void, Never>? { get { nil } set { } } }
@MainActor final class Check {
 let profile: Profile
 init(iPad: Bool) { profile = Profile(canChooseUSBCharger: iPad) }
 var state = State.booting, poweringOn = false, lastFrameAdvance = Date.distantPast, bootScope = Scope()
 var sent: [LinkRequest] = []
 func control(_ r: LinkRequest, _ done: @escaping (Bool) -> Void = { _ in }) { sent.append(r); done(true) }
 func boot() -> [LinkRequest] { state = .booting; sent = []; noteFrameAdvanced(); noteFrameAdvanced(); return sent }
""" + battery + frame + r"""
}
@main struct Main { @MainActor static func main() {
 let pad = Check(iPad: true)
 precondition(pad.boot() == [.battery(level: 100, charging: 0), .usbCharger(true)], "first frame: \(pad.sent)")
 pad.sent = []; pad.setBattery(level: 50)
 precondition(pad.sent == [.battery(level: 50, charging: 0)])
 precondition(pad.boot() == [.battery(level: 50, charging: 0), .usbCharger(true)], "a restart keeps the chosen level")
 pad.sent = []; pad.setCharging(false)
 precondition(!pad.batteryCharging && pad.sent == [.usbCharger(false), .usbConnection(false)], "iPad: the port, then a replug: \(pad.sent)")
 precondition(pad.boot() == [.battery(level: 50, charging: 2), .usbCharger(false)], "a restart keeps Charging off")
 let pod = Check(iPad: false)
 precondition(pod.boot() == [.battery(level: 100, charging: 0)])
 pod.sent = []; pod.setCharging(false)
 precondition(pod.sent == [.battery(level: 100, charging: 2)], "iPod: the charger, no replug: \(pod.sent)")
 precondition(pod.boot() == [.battery(level: 100, charging: 2)])
 print("PASS: Battery level and Charging re-applied at each boot's first frame; iPad port current + replug, iPod charger mode")
} }
"""
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp); (tmp / 'check.swift').write_text(source)
    subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(root), '-parse-as-library',
                    str(root / 'Shared/DeviceLinkProtocol.swift'), str(tmp / 'check.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check')], check=True)
