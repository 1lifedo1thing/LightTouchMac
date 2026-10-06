#!/usr/bin/env python3
"""The Carrier panel (CarrierPanel.swift) against a fake modem, rendered offscreen (--out DIR for carrier-*.png).

Checks: after Apply, the panel says Applying… with a spinner until the modem reports the new carrier and PLMN, and
not before or after; the SMS message field is multiline (three lines tall, growing with more).
"""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
import argparse, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
ap = argparse.ArgumentParser()
ap.add_argument('--out')
args = ap.parse_args()

check = r'''
import Cocoa
import SwiftUI
// The panel's window controller names the device; the panel itself only talks to CarrierBackend.
final class EmulatorController {
    struct Instance { let name = "iPhone" }
    let instance = Instance()
    var carrierSettings = CarrierSettings()
    func setCarrierSettings(_ settings: CarrierSettings) -> Bool { true }
    func modem(_ property: String, _ value: String, done: @escaping (Bool) -> Void) {}
    func modemStatus(_ done: @escaping (ModemStatus?) -> Void) {}
}
@MainActor final class Modem: CarrierBackend {
    var carrierSettings = CarrierSettings()
    var reported = CarrierSettings()
    func setCarrierSettings(_ settings: CarrierSettings) -> Bool { carrierSettings = settings; return true }
    func modem(_ property: String, _ value: String, done: @escaping (Bool) -> Void) { done(true) }
    func modemStatus(_ done: @escaping (ModemStatus?) -> Void) {
        done(ModemStatus(json: #"{"carrier": "\#(reported.carrier)", "mcc-mnc": "\#(reported.mccMNC)", "registered": true, "sim-present": true}"#))
    }
}
@main struct Check {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let out = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil
        let modem = Modem()
        let model = CarrierPanelModel(backend: modem)
        let hosting = NSHostingView(rootView: CarrierPanel(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 760), styleMask: [.titled], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        func settle() { for _ in 0..<5 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)); hosting.layoutSubtreeIfNeeded() } }
        func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
        func render(_ name: String) throws {
            guard let out else { return }
            settle()
            let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("carrier-\(name).png"))
        }
        model.poll()
        precondition(!model.applyingNetwork, "applying before any change")
        model.carrierName = "Fictional"
        model.applyNetwork()
        model.poll()
        precondition(model.applyingNetwork, "no progress while the modem still reports the old carrier")
        settle()
        precondition(all(hosting).contains { $0 is NSProgressIndicator }, "no spinner while applying")
        try render("applying")
        modem.reported = modem.carrierSettings
        model.poll()
        precondition(!model.applyingNetwork, "still applying once the modem reports it")
        func messageField() -> NSView? {
            all(hosting).first { ($0 as? NSTextField)?.stringValue == model.smsText || ($0 as? NSTextView)?.string == model.smsText }
        }
        // The message field is multiline: three lines tall when short, taller with more lines (a one-line field is ~22 pt).
        model.smsText = "x"
        settle()
        let one = messageField()?.frame.height
        model.smsText = (1...5).map { "line \($0)" }.joined(separator: "\n")
        settle()
        let five = messageField()?.frame.height
        precondition(one.map { $0 >= 40 } == true && five.map { $0 > one! + 10 } == true,
                     "the message field isn't multiline: \(String(describing: one)) -> \(String(describing: five))")
        try render("message")
        print("PASS: Applying… with a spinner until the modem reports the new carrier; a multiline SMS message")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-carrier-') as tmp:
    tmp = Path(tmp)
    (tmp / 'main.swift').write_text(check)
    subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(root), '-parse-as-library', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(tmp / 'modules'), '-D', 'CHECK',
                    str(root / 'LightTouchMac/UI/CarrierPanel.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'check')], check=True)
    if args.out:
        Path(args.out).mkdir(parents=True, exist_ok=True)
    subprocess.run([str(tmp / 'check'), *([str(Path(args.out).resolve())] if args.out else [])], check=True, timeout=60)
