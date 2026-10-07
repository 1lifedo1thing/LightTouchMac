#!/usr/bin/env python3
"""Guest tools are judged "not responding" only for a package that has something to answer.

An itpack shaped like the shipped one (1.x's n45-ios1: an OpenGLES hook, no jobs; the iPad's k48-ios4:
it_agent, it_ethlink, it_prefs) goes through the production GuestPackage.compose and ethlinkSilent.
The 1G's offer must never read "not responding" (Sam's 3A101a, 10-04: "Running — Guest tools: Not
responding" a minute after boot); the iPad's still must when it_ethlink never comes up.
"""
from pathlib import Path
import hashlib, json, subprocess, sys, tempfile, zlib
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import device_runtime


def manifest(family, boards, builds, jobs, files):
    return {"serial": 14, "version": "1.1.12", "family": family, "arch": "armv6",
            "requires": {"boards": boards, "builds": builds, "host": {"guest-package": [1, 1]}},
            "files": [{"name": n, "mode": "0755", "size": len(d), "sha256": hashlib.sha256(d).hexdigest()} for n, d in files],
            "jobs": jobs, "hooks": []}


def itpack(path, packages):
    entries = []
    for m, files in packages:
        entries.append((m["family"] + "/manifest.json", json.dumps(m).encode()))
        entries += [(m["family"] + "/" + n, d) for n, d in files]
    index = json.dumps({"format": 1, "entries": [{"name": n, "size": len(d)} for n, d in entries]}).encode()
    path.write_bytes(b"ITPACK01" + len(index).to_bytes(4, "little") + index + zlib.compress(b"".join(d for _, d in entries)))


DRIVER = r'''
import Foundation
enum DeviceToolsError: Error { case failed(String) }
@main struct Probe {
 static func main() throws {
  let pack = URL(fileURLWithPath: CommandLine.arguments[1]), work = URL(fileURLWithPath: CommandLine.arguments[2])
  let n45 = try GuestPackage.compose(itpack: pack, board: "n45ap", build: "3A101a", lock: nil, guest: nil,
                                     into: work.appendingPathComponent("n45"))!
  let k48 = try GuestPackage.compose(itpack: pack, board: "k48ap", build: "8C148", lock: nil, guest: nil,
                                     into: work.appendingPathComponent("k48"))!
  precondition(!n45.ethlink && k48.ethlink, "offers: n45 ethlink \(n45.ethlink), k48 ethlink \(k48.ethlink)")
  // Installed (report serial 14), lockdown up for a minute, no it_ethlink line: the 1G has nothing to say.
  precondition(!GuestPackage.ethlinkSilent(offer: n45, reportedSerial: 14, ethlinkUp: false, reachableForAMinute: true),
               "the 1.x package carries no it_ethlink, yet its silence reads as not responding")
  precondition(GuestPackage.ethlinkSilent(offer: k48, reportedSerial: 14, ethlinkUp: false, reachableForAMinute: true),
               "the iPad's missing it_ethlink no longer reads as not responding")
  precondition(!GuestPackage.ethlinkSilent(offer: k48, reportedSerial: 14, ethlinkUp: true, reachableForAMinute: true))
  precondition(!GuestPackage.ethlinkSilent(offer: k48, reportedSerial: 14, ethlinkUp: false, reachableForAMinute: false))
  precondition(!GuestPackage.ethlinkSilent(offer: k48, reportedSerial: nil, ethlinkUp: false, reachableForAMinute: true))
  print("PASS: no 'not responding' for a package without it_ethlink (1.x); the iPad's silent it_ethlink still is")
 }
}
'''

with tempfile.TemporaryDirectory(prefix="ltm-guest-status-") as tmp:
    t = Path(tmp)
    hook, agent, ethlink = b"\x00hook", b"\x00agent", b"\x00ethlink"
    itpack(t / "pack.itpack", [
        (manifest("n45-ios1", ["n45ap"], ["3*", "4*"], [], [("hooks/OpenGLES", hook)]), [("hooks/OpenGLES", hook)]),
        (manifest("k48-ios4", ["k48ap"], ["8*"], ["jobs/com.qemu.it-agent.plist", "jobs/com.qemu.it-ethlink.plist"],
                  [("bin/it_agent", agent), ("bin/it_ethlink", ethlink)]),
         [("bin/it_agent", agent), ("bin/it_ethlink", ethlink)]),
    ])
    (t / "probe.swift").write_text(DRIVER)
    sources = ["Packages/FirmwareKit/Sources/FirmwareSchema/FirmwareWire.swift", "LightTouchMac/Guest/GuestPackage.swift",
               "LightTouchMac/Device/BootSessionScope.swift", "LightTouchMac/Library/DeviceInstance.swift",
               "LightTouchMac/Device/Board+App.swift", "LightTouchMac/Library/StorageLocations.swift",
               "LightTouchMac/Library/FirmwareCatalog.swift"]
    subprocess.run(["xcrun", "swiftc", *device_runtime.swift_flags(ROOT), "-swift-version", "5", "-default-isolation", "MainActor",
                    "-parse-as-library", "-module-cache-path", str(t / "modules"), *[str(ROOT / s) for s in sources],
                    str(t / "probe.swift"), "-o", str(t / "probe")], check=True)
    subprocess.run([str(t / "probe"), str(t / "pack.itpack"), str(t)], check=True, timeout=30)
