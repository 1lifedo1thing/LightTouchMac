#!/usr/bin/env python3
"""A rotation shows without a new frame (Sam 10-06: the iPhone 4 only redrew its rotation when something else did).

The production DisplayView with the flat shell (the iPhone 4 has no 3D model), check-model's fake link and emulator,
in a window never ordered in. The emulator publishes the turned picture first; the app learns the new orientation
(SpringBoard's) a moment later, while the screen is static and no new frame comes. Checks: the display's own tick
lays the device out landscape then, without another frame."""
import ast, subprocess, sys, tempfile
from pathlib import Path
root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "scripts"))
import device_runtime

node = ast.parse((root / 'tests/offline/check-model.py').read_text())
fixture = next(ast.literal_eval(n.value) for n in node.body if isinstance(n, ast.Assign)
               and any(isinstance(t, ast.Name) and t.id == 'display_source' for t in n.targets))
prefix = fixture[:fixture.index('@main struct Check')]
assert '  serial += 1\n' in prefix
# A static screen: the link keeps answering with the frame it has.
prefix = prefix.replace('  serial += 1\n', '  if !frozen { serial += 1 }\n').replace(
    '@MainActor var frameColor', '@MainActor var frozen = false\n@MainActor var frameColor')
startup = (root / 'tests/offline/check-model-startup.py').read_text()
start = startup.index('@MainActor final class DeviceModelView')
stub = startup[start:startup.index('@main struct Check', start)]

source = prefix + stub + r'''
@main struct Check {
 @MainActor static func main() async throws {
  _ = fixtureMachines
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.prohibited)
  for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] { UserDefaults.standard.removeObject(forKey: key) }
  defer { for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] { UserDefaults.standard.removeObject(forKey: key) } }
  DisplayView.bezel = .flat
  let profile = Board.n90
  frameWidth = Int32(profile.screenPixels.width); frameHeight = Int32(profile.screenPixels.height)
  let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: profile)
  let e = EmulatorController(); display.emulator = e
  let window = NSWindow(contentRect: display.frame, styleMask: [.titled], backing: .buffered, defer: false)
  window.contentView = display
  func tick() async throws {
   display.perform(NSSelectorFromString("step"))
   display.layoutSubtreeIfNeeded()
   try await Task.sleep(for: .milliseconds(50))
  }
  for _ in 0..<5 { try await tick() }
  func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
  let lcd = all(display.layer!).first { $0.backgroundColor == NSColor.black.cgColor && $0.contentsGravity == .resize }!
  func box() -> CGRect { lcd.convert(lcd.bounds, to: display.layer!) }
  precondition(box().height > box().width, "not portrait at rest: \(box())")
  // The emulator turns its picture first; the app hears of the orientation later, with nothing new on screen.
  frameWidth = Int32(profile.screenPixels.height); frameHeight = Int32(profile.screenPixels.width)
  try await tick()
  frozen = true
  e.rotationDegrees = 90
  for _ in 0..<4 { try await tick() }
  // Animations off the screen: the model layer is where the layout put it.
  let b = box()
  precondition(b.width > b.height * 1.2, "the rotation didn't show without a new frame: LCD \(b)")
  window.contentView = nil
  print("PASS: an iPhone 4 rotation lays out landscape on the display's own tick, with no new frame")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-rotation-redraw-') as tmp:
    work = Path(tmp)
    app = work / 'Check.app/Contents'
    (app / 'MacOS').mkdir(parents=True)
    (app / 'Resources').mkdir()
    (app / 'Resources/shell-iphone4.png').symlink_to(root / 'LightTouchMac/Assets.xcassets/shell-iphone4.imageset/shell-iphone4.png')
    (work / 'check.swift').write_text(source)
    exe = app / 'MacOS/check'
    sources = ['UI/DisplayView', 'Input/MouseTouchPair', 'Device/Board+App', '../tests/fixtures/machines', 'UI/DisplayMeasurements', 'UI/ZoomMode', 'Capture/PanelCapture', 'Input/KeyboardPointer', 'UI/AttitudeIndicatorButton',
               'UI/InlineLiveTextView', 'UI/DroppedFiles', 'UI/DropHighlight','UI/GuestKeyboard']
    subprocess.run(['swiftc', *device_runtime.swift_flags(root), '-module-cache-path', str(work / 'modules'), '-default-isolation', 'MainActor',
                    *[str(root / 'LightTouchMac' / f'{s}.swift') for s in sources], str(work / 'check.swift'), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True, timeout=60)
