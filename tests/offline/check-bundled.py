#!/usr/bin/env python3
"""Bundled tool lookup: bundle first, then the checkout; guest tools from the unpacked Resources/Guest/guest.aar
(FirmwareKit GuestArchive); the files root from LTM_FILES."""
from pathlib import Path
import os, shutil, subprocess, tempfile
root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='ltm-bundled-') as tmp:
    work = Path(tmp)
    source = work / 'main.swift'
    source.write_text(r'''import Foundation
let directory = CommandLine.arguments[1]
let file = directory + "/com.qemu.it-agent.plist"
try Data("fixture".utf8).write(to: URL(fileURLWithPath: file))
try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
precondition(Bundled.resolve("missing", fallbacks: [file]) == nil)
let host = Bundled.hostToolsDirectory! + "/itmedia"
try Data("host tool".utf8).write(to: URL(fileURLWithPath: host))
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host)
precondition(Bundled.tool("itmedia") == host)
try FileManager.default.removeItem(atPath: host)
// the archive's tools/, unpacked once into the user's caches, executable as packed
let guest = Bundled.toolsDirectory! + "/itmedia"
precondition(Bundled.tool("itmedia") == guest, "\(String(describing: Bundled.tool("itmedia"))) is not \(guest)")
let unpacked = try Data(contentsOf: URL(fileURLWithPath: guest))
precondition(String(decoding: unpacked, as: UTF8.self) == "guest tool")
precondition(Bundled.guestRoot!.path.contains("/Caches/gold.samhenri.LightTouchMac/Guest/"))
precondition(Bundled.binarySearchPaths.first == Bundled.hostToolsDirectory)
precondition(Bundled.filesRoot == CommandLine.arguments[2], "LTM_FILES names the device assets")
print(Bundled.guestRoot!.path)
''')
    contents = work / 'Check.app/Contents'
    executable = contents / 'MacOS/check'
    executable.parent.mkdir(parents=True)
    packed = work / 'packed/tools'
    packed.mkdir(parents=True)
    (packed / 'itmedia').write_text('guest tool')
    (packed / 'itmedia').chmod(0o755)
    (contents / 'Resources/Guest').mkdir(parents=True)
    subprocess.run(['aa', 'archive', '-d', packed.parent, '-o', contents / 'Resources/Guest/guest.aar'], check=True)
    subprocess.run(['swiftc', '-module-cache-path', str(work/'modules'), str(root/'LightTouchMac/Library/Bundled.swift'),
                    str(root/'Packages/FirmwareKit/Sources/FirmwareKit/GuestPackage/GuestArchive.swift'),
                    str(root/'LightTouchMac/Library/StorageLocations.swift'), str(root/'LightTouchMac/Transport/NativeLogging.swift'),
                    str(source), '-o', str(executable)], check=True)
    result = subprocess.run([str(executable), str(work), str(work / 'files')], check=True, capture_output=True, text=True,
                            env=dict(os.environ, LTM_FILES=str(work / 'files'), LTM_STATE_DIR=str(work / 'state')))
    shutil.rmtree(result.stdout.strip().splitlines()[-1])   # this check's unpacked copy
print('PASS: native helper precedence and checkout fallback; a non-executable file is no tool; the packed guest '
      'tools unpack into the caches and resolve, executable; LTM_FILES is the files root')
