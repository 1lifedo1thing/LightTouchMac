#!/usr/bin/env python3
"""About Light Touch's credits (App/AboutCredits.swift, compiled whole): the build record's components with qemu-ios,
usbmuxd and the guest tools first, then the rest by name; Help.txt's Licenses section; the link to the licence files;
nothing for a development build without a record."""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[2]
main = r'''
import Cocoa
let inputs = Data(#"{"components":{"libplist":"2.7.0","qemu-ios":"0e4bf5a90b","guest tools":"1.1.14 (serial 16)","usbmuxd":"e19fac2d4b","glib":"2.88.3"}}"#.utf8)
let help = try! String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), encoding: .utf8)
let text = AboutCredits.credits(buildInputs: inputs, help: help, licenses: FileManager.default.temporaryDirectory)
let s = text.string
precondition(s.hasPrefix("Components\nqemu-ios 0e4bf5a90b\nusbmuxd e19fac2d4b\nguest tools 1.1.14 (serial 16)\nglib 2.88.3\nlibplist 2.7.0\n\nLicenses\nLight Touch includes open-source software."), s)
precondition(!s.contains("# ") && s.hasSuffix("Show the license files"), s)
precondition(text.attribute(.link, at: text.length - 1, effectiveRange: nil) as? URL == FileManager.default.temporaryDirectory)
precondition(AboutCredits.credits(buildInputs: nil, help: nil, licenses: nil).length == 0)
print("PASS: About lists the bundled components and the licences")
'''
with tempfile.TemporaryDirectory(prefix='ltm-about-') as tmp:
    tmp = Path(tmp)
    (tmp / 'main.swift').write_text(main)
    subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-module-cache-path', str(tmp / 'modules'),
                    str(root / 'LightTouchMac/App/AboutCredits.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), str(root / 'LightTouchMac/Help.txt')], check=True)
