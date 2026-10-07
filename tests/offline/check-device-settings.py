#!/usr/bin/env python3
"""Per-device settings: what earlier builds kept in user defaults ("<name>.<uuid>", and the app-wide keyboard and
auto-rotate keys before those) moves once into each device's settings.plist, and every such key goes."""
from pathlib import Path
import subprocess, sys, tempfile
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import host_runtime
code = r'''import Foundation
@main struct Check {
 static func main() throws {
  _ = fixtureMachines
  let state = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
  let suite = "ltm-device-settings-\(getpid())", defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let a = UUID(), b = UUID(), gone = UUID()
  for id in [a, b] { try FileManager.default.createDirectory(at: DeviceInstance.directory(id, state: state), withIntermediateDirectories: true) }
  var carrier = CarrierSettings(); carrier.carrier = "Test Net"; carrier.bars = 2
  defaults.set(["message": "Couldn't erase", "operation": "erase"], forKey: "deviceNotice.\(a.uuidString)")
  defaults.set(1, forKey: "motionPose.\(a.uuidString)")
  defaults.set(false, forKey: "keyboardInputEnabled.\(a.uuidString)")
  defaults.set(true, forKey: "debugPort.\(a.uuidString)")
  defaults.set(try JSONEncoder().encode(carrier), forKey: "carrier.\(a.uuidString)")
  defaults.set(1, forKey: "motionPose.\(gone.uuidString)")
  defaults.set(true, forKey: "keyboardInputEnabled")
  defaults.set(false, forKey: "autoRotateWithGuest")
  defaults.set("kept", forKey: "captureFolder")

  DeviceSettings.migrateDefaults(defaults, state: state, devices: [a, b])

  let first = DeviceSettings.load(DeviceInstance.directory(a, state: state))
  precondition(first == DeviceSettings(deviceNotice: .init(message: "Couldn't erase", operation: "erase"), motionPose: 1,
                                       keyboardInputEnabled: false, autoRotateWithGuest: false, debugPort: true, carrier: carrier),
               "A's keys, the app-wide auto-rotate under them: \(first)")
  let second = DeviceSettings.load(DeviceInstance.directory(b, state: state))
  precondition(second == DeviceSettings(keyboardInputEnabled: true, autoRotateWithGuest: false), "B takes the app-wide keys: \(second)")
  let bytes = try Data(contentsOf: DeviceSettings.url(DeviceInstance.directory(a, state: state)))
  precondition(String(decoding: bytes.prefix(5), as: UTF8.self) == "<?xml", "an XML property list")
  let left = defaults.persistentDomain(forName: suite) ?? [:]
  precondition(left.keys.sorted() == ["captureFolder"], "every per-device and app-wide key went, a deleted device's too: \(left.keys.sorted())")
  // Connect Hardware Keyboard: off is saved per device and read back; unset is connected.
  var keyboard = DeviceSettings.load(DeviceInstance.directory(b, state: state))
  precondition(keyboard.hardwareKeyboard == nil)
  keyboard.hardwareKeyboard = false
  try keyboard.save(DeviceInstance.directory(b, state: state))
  precondition(DeviceSettings.load(DeviceInstance.directory(b, state: state)).hardwareKeyboard == false, "the keyboard choice wasn't kept")
  precondition(Board.n90.canToggleHardwareKeyboard && !Board.n88.canToggleHardwareKeyboard
               && !Board.n72.canToggleHardwareKeyboard, "keyboard toggle boards")
  print("PASS: per-device defaults (notice, pose, keyboard, debug port, carrier) and the app-wide fallbacks move into settings.plist; the keys go")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-device-settings-') as directory:
    work = Path(directory)
    (work / 'check.swift').write_text(code)
    sources = ['Library/DeviceSettings', 'Library/DeviceInstance', 'Device/Board+App', '../tests/fixtures/machines', 'Library/StorageLocations', 'Library/FirmwareCatalog']
    subprocess.run(['xcrun', 'swiftc', *__import__('host_runtime').schema_flags(__import__('pathlib').Path(__file__).resolve().parents[2]), *host_runtime.swift_flags(ROOT), '-swift-version', '5', '-parse-as-library',
                    '-module-cache-path', str(work / 'modules'), *[str(ROOT / f'LightTouchMac/{s}.swift') for s in sources],
                    str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check'), str(work / 'state')], check=True, timeout=60)
