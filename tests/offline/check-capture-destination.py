#!/usr/bin/env python3
"""Exercise the production capture destination without launching the emulator: Features/CaptureController.swift
compiled whole against tests/fixtures/capture-controller.swift."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
app = root / 'LightTouchMac'
code = r'''import Cocoa
@main struct Check {
 @MainActor static func main() throws {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: base); UserDefaults.standard.removeObject(forKey: "captureFolder") }
  UserDefaults.standard.set(base.appendingPathComponent("nested").path, forKey: "captureFolder")
  let capture = CaptureController()
  UserDefaults.standard.removeObject(forKey: "captureFolder")
  precondition(capture.captureFolder == FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!)
  UserDefaults.standard.set(base.appendingPathComponent("nested").path, forKey: "captureFolder")
  // Named in local time, no random suffix; " 2" only when the name is taken.
  let at = Date(timeIntervalSince1970: 1_791_330_134)   // 2026-10-06 23:42:14 UTC
  let local = DateFormatter(); local.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"; local.locale = Locale(identifier: "en_US_POSIX")
  precondition(capture.captureName("Screenshot", at: at) == "Light Touch Screenshot " + local.string(from: at), capture.captureName("Screenshot", at: at))
  NSTimeZone.default = TimeZone(identifier: "America/New_York")!
  precondition(capture.captureName("Screenshot", at: at) == "Light Touch Screenshot 2026-10-06 at 19.42.14", "local time: " + capture.captureName("Screenshot", at: at))
  NSTimeZone.default = .current
  let first = try capture.captureDestination("Screenshot", extension: "png")
  precondition(first.lastPathComponent.hasPrefix("Light Touch Screenshot ") && first.pathExtension == "png")
  precondition(first.deletingPathExtension().lastPathComponent.count == "Light Touch Screenshot 2026-10-07 at 17.22.14".count, "no suffix: " + first.lastPathComponent)
  precondition(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
  try Data([1,2,3]).write(to: first, options: .atomic)
  let second = try capture.captureDestination("Screenshot", extension: "png")
  if second.lastPathComponent != first.lastPathComponent {   // the clock moved on: a fresh name, or the same second's " 2"
   precondition(second.deletingPathExtension().lastPathComponent == first.deletingPathExtension().lastPathComponent + " 2"
                || !FileManager.default.fileExists(atPath: second.path), second.lastPathComponent)
  } else { fatalError("a taken name was reused: " + second.lastPathComponent) }
  let taken = first.deletingLastPathComponent().appendingPathComponent("Light Touch Screenshot X.png")
  try Data().write(to: taken)
  precondition(taken.unused.lastPathComponent == "Light Touch Screenshot X 2.png")
  try Data().write(to: taken.unused)
  precondition(taken.unused.lastPathComponent == "Light Touch Screenshot X 3.png")
  let data = try Data(contentsOf: first); precondition(data == Data([1,2,3]))
  let blocker = base.appendingPathComponent("file")
  try Data().write(to: blocker)
  UserDefaults.standard.set(blocker.appendingPathComponent("child").path, forKey: "captureFolder")
  do { _ = try capture.captureDestination("Recording", extension: "mov"); fatalError("accepted an unwritable directory") } catch {}
  print("PASS: capture destinations create folders, local-time names without random suffixes, \" 2\" on collision, and propagate failure")
 }
}
'''
with tempfile.TemporaryDirectory() as tmp:
    script = Path(tmp)/'main.swift'
    script.write_text(code)
    subprocess.run(['swiftc', *host_runtime.swift_flags(Path(__file__).resolve().parents[2]), '-parse-as-library', '-default-isolation', 'MainActor', '-module-cache-path', str(Path(tmp)/'modules'),
                    *[str(app/f) for f in ['Device/Board+App.swift', 'Features/CapturePreferences.swift', 'Features/CaptureSound.swift', 'Library/UnusedURL.swift', 'UI/DeviceMenuState.swift',
                                           'Features/CaptureController.swift']],
                    str(root/'tests/fixtures/capture-controller.swift'), str(script), '-o', str(Path(tmp)/'check')], check=True)
    subprocess.run([str(Path(tmp)/'check')], check=True)
