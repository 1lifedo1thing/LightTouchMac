#!/usr/bin/env python3
"""Chassis tilt through the production DisplayView compiled whole (check-model's fixture, check-model-startup's stub
model, the 2D bezel so the flat shell is the chassis): synthetic NSEvents into its mouse, scroll and rotate handlers,
no window shown. Grab-and-drag rolls and pitches in every orientation and leaves guest touches alone; wheel lines and
precise points tilt alike, Natural Scrolling is not undone, momentum never starts a tilt, a wheel burst returns to
rest on its own; a twist tilts off the panel or with Option; layouts during repeated tilt leave the screen and shell
upright after release. The gesture math itself is ChassisTiltTests'."""
import ast, subprocess, sys, tempfile
from pathlib import Path
root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "scripts"))
import device_runtime

node = ast.parse((root / 'tests/offline/check-model.py').read_text())
fixture = next(ast.literal_eval(n.value) for n in node.body if isinstance(n, ast.Assign)
               and any(isinstance(t, ast.Name) and t.id == 'display_source' for t in n.targets))
prefix = fixture[:fixture.index('@main struct Check')]
link = ' func send(_ command: LinkCommand) { if case let .touch(_, _, x, y) = command { touches.append((x, y)) } }'
assert link in prefix, 'check-model fixture changed: update this check'
prefix = prefix.replace(link, ' func send(_ command: LinkCommand) { if case let .touch(_, phase, _, _) = command { sent.append(phase) } }') \
               .replace('@MainActor var touches', '@MainActor var sent: [Int] = []\n@MainActor var touches')
startup = (root / 'tests/offline/check-model-startup.py').read_text()
start = startup.index('@MainActor final class DeviceModelView')
stub = startup[start:startup.index('@main struct Check', start)]

source = prefix + stub + r'''
final class Cursor: NSWindow { var at = NSPoint.zero; override var mouseLocationOutsideOfEventStream: NSPoint { at } }
/// A trackpad/wheel event with the fields AppKit fills in.
final class Gesture: NSEvent {
 var eventPhase: NSEvent.Phase = .changed, momentum: NSEvent.Phase = []
 var dx = 0.0, dy = 0.0, degrees: Float = 0, at = NSPoint.zero
 var precise = true, inverted = false, option = false
 override var phase: NSEvent.Phase { eventPhase }
 override var momentumPhase: NSEvent.Phase { momentum }
 override var scrollingDeltaX: CGFloat { dx }
 override var scrollingDeltaY: CGFloat { dy }
 override var hasPreciseScrollingDeltas: Bool { precise }
 override var isDirectionInvertedFromDevice: Bool { inverted }
 override var modifierFlags: NSEvent.ModifierFlags { option ? .option : [] }
 override var rotation: Float { degrees }
 override var locationInWindow: NSPoint { at }
}
@main struct Check {
 @MainActor static func main() async throws {
  _ = fixtureMachines
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.prohibited)
  for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] { UserDefaults.standard.removeObject(forKey: key) }
  defer { for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] { UserDefaults.standard.removeObject(forKey: key) } }
  DisplayView.bezel = .flat
  let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: .n72)
  let emulator = EmulatorController(); display.emulator = emulator   // weak: held here
  defer { withExtendedLifetime(emulator) {} }
  let window = Cursor(contentRect: display.frame, styleMask: [.titled], backing: .buffered, defer: false)
  window.contentView = display
  func layout() { display.needsLayout = true; display.layoutSubtreeIfNeeded() }
  layout()
  func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
  let lcd = all(display.layer!).first { $0.backgroundColor == NSColor.black.cgColor && $0.contentsGravity == .resize }!
  let shell = lcd.superlayer!
  let home = display.subviews.first { String(describing: type(of: $0)) == "HomeButton" }!
  func close(_ a: CGFloat, _ b: CGFloat, _ what: String) { precondition(abs(a - b) < 1e-9, "\(what): \(a) vs \(b)") }
  func untouched() -> Bool { emulator.attitude == (7, 7) }
  /// The shell's roll from its transform: scale·Rx(pitch)·Rz(angle)·perspective leaves Rz in the first row.
  func shellAngle() -> CGFloat { atan2(shell.transform.m12, shell.transform.m11) }
  func shellTurned(_ angle: CGFloat, _ what: String) { close(remainder(shellAngle() - angle, 2 * .pi), 0, what) }
  func rest(_ rotation: Int) -> CGFloat { rotation == 270 ? -.pi / 2 : CGFloat(rotation) * .pi / 180 }
  func mouse(_ t: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
   let at = display.convert(p, to: nil); window.at = at
   return NSEvent.mouseEvent(with: t, location: at, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }
  /// Above the screen on the flat shell, in view points (wherever the shell is turned).
  func chassis() -> CGPoint { shell.convert(CGPoint(x: shell.bounds.midX, y: lcd.frame.minY / 2), to: display.layer!) }
  func panel() -> CGPoint { lcd.convert(CGPoint(x: lcd.bounds.midX, y: lcd.bounds.midY), to: display.layer!) }

  // Drag: linear roll right and pitch up from the grab point (the view is flipped), clamped, in every orientation.
  for rotation in [0, 90, 180, 270] {
   emulator.rotationDegrees = rotation; layout()
   shellTurned(rest(rotation), "rest \(rotation)")
   let grab = chassis()
   display.mouseDown(with: mouse(.leftMouseDown, grab))
   display.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: grab.x + 25, y: grab.y + 50)))
   close(emulator.attitude.angle, rest(rotation) + 0.1, "roll \(rotation)"); close(emulator.attitude.pitch, -0.2, "pitch \(rotation)")
   shellTurned(rest(rotation) + 0.1, "the shell turns with the roll at \(rotation)")
   display.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: grab.x - 25, y: grab.y - 50)))
   close(emulator.attitude.angle, rest(rotation) - 0.1, "back \(rotation)"); close(emulator.attitude.pitch, 0.2, "up \(rotation)")
   display.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: grab.x + 10000, y: grab.y - 10000)))
   close(emulator.attitude.angle, rest(rotation) + .pi / 4, "clamp \(rotation)"); close(emulator.attitude.pitch, .pi / 4, "clamp \(rotation)")
   display.mouseUp(with: mouse(.leftMouseUp, grab))
   close(emulator.attitude.angle, rest(rotation), "release \(rotation)"); close(emulator.attitude.pitch, 0, "release \(rotation)")
   shellTurned(rest(rotation), "the shell springs back at \(rotation)")
  }
  emulator.rotationDegrees = 0; layout()
  precondition(sent.isEmpty, "a chassis drag is no touch: \(sent)")
  // A press on the LCD is a touch: its drag updates the guest and leaves gravity alone.
  emulator.attitude = (7, 7)
  let p = panel()
  display.mouseDown(with: mouse(.leftMouseDown, p))
  display.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: p.x + 30, y: p.y + 30)))
  display.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: p.x + 30, y: p.y + 30)))
  precondition(sent == [0, 1, 2] && untouched(), "\(sent)")
  sent = []

  // Scroll off the panel: line wheels (x10) and precise points tilt the same; the phase's end returns to rest.
  let event = Gesture(); event.at = display.convert(CGPoint(x: 5, y: 5), to: nil)
  for precise in [false, true] {
   event.precise = precise; event.dx = precise ? 10 : 1; event.dy = precise ? -20 : -2
   event.eventPhase = .began; display.scrollWheel(with: event)
   close(emulator.attitude.angle, 0.015, "scroll roll precise=\(precise)"); close(emulator.attitude.pitch, -0.03, "scroll pitch precise=\(precise)")
   event.eventPhase = .ended; display.scrollWheel(with: event)
   close(emulator.attitude.angle, 0, "scroll end"); close(emulator.attitude.pitch, 0, "scroll end")
  }
  // The same swipe arrives with opposite deltas under the other Natural Scrolling setting: AppKit has already
  // applied it, so the deltas are taken as they come.
  for inverted in [false, true] {
   event.precise = true; event.inverted = inverted; event.dx = inverted ? -10 : 10; event.dy = 0
   event.eventPhase = .began; display.scrollWheel(with: event)
   close(emulator.attitude.angle, inverted ? -0.015 : 0.015, "inverted=\(inverted)")
   event.eventPhase = .ended; display.scrollWheel(with: event)
  }
  event.inverted = false
  // Momentum alone belongs to content scrolling: no tilt, no touch.
  emulator.attitude = (7, 7)
  event.momentum = .changed; event.eventPhase = []; display.scrollWheel(with: event)
  precondition(untouched() && sent.isEmpty, "momentum started a gesture")
  // Nor does momentum move a tilt the fingers are holding.
  event.momentum = []; event.dx = 10; event.eventPhase = .began; display.scrollWheel(with: event)
  event.momentum = .changed; event.eventPhase = []; display.scrollWheel(with: event)
  close(emulator.attitude.angle, 0.015, "momentum moved the tilt")
  event.momentum = []; event.eventPhase = .ended; display.scrollWheel(with: event)
  close(emulator.attitude.angle, 0, "momentum scroll end")
  // A conventional wheel has no phases: a burst tilts, then returns to rest by itself.
  event.momentum = []; event.eventPhase = []; event.precise = false; event.dx = 1; event.dy = 0; display.scrollWheel(with: event)
  close(emulator.attitude.angle, 0.015, "wheel burst")
  try await Task.sleep(for: .milliseconds(250))
  close(emulator.attitude.angle, 0, "a conventional wheel must return to rest after its burst")
  // Scroll over the panel is the guest's, unless Option is held.
  event.at = display.convert(panel(), to: nil); event.precise = true; event.dx = 10
  emulator.attitude = (7, 7); event.eventPhase = .began; display.scrollWheel(with: event)
  precondition(untouched(), "scroll over the panel tilted")
  event.eventPhase = .ended; display.scrollWheel(with: event); sent = []
  event.option = true; event.eventPhase = .began; display.scrollWheel(with: event)
  close(emulator.attitude.angle, 0.015, "Option-scroll over the panel tilts")
  event.eventPhase = .ended; display.scrollWheel(with: event); event.option = false
  precondition(sent.isEmpty, "\(sent)")

  // Twist: counterclockwise degrees roll clockwise; off the panel or with Option, else the guest's.
  event.at = display.convert(CGPoint(x: 5, y: 5), to: nil)
  event.eventPhase = .began; event.degrees = 30; display.rotate(with: event)
  close(emulator.attitude.angle, -.pi / 6, "twist")
  event.eventPhase = .cancelled; display.rotate(with: event); close(emulator.attitude.angle, 0, "twist cancelled")
  event.at = display.convert(panel(), to: nil)
  emulator.attitude = (7, 7); event.eventPhase = .began; display.rotate(with: event)
  precondition(untouched(), "a twist over the panel is the guest's")
  event.option = true; display.rotate(with: event); close(emulator.attitude.angle, -.pi / 6, "Option-twist over the panel")
  event.eventPhase = .ended; display.rotate(with: event); close(emulator.attitude.angle, 0, "twist ended")

  // Layouts during repeated tilt: the content counters only the guest's quarter turn, never the gesture, so after
  // release screen and shell are upright together, unpitched, and the flat shell's Home button is back.
  for rotation in [0, 90, 180, 270] {
   emulator.rotationDegrees = rotation; layout()
   for (right, down) in [(50.0, -25.0), (-75.0, 40.0), (0.0, 0.0), (100.0, 50.0)] {
    let grab = chassis()
    display.mouseDown(with: mouse(.leftMouseDown, grab))
    display.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: grab.x + right, y: grab.y + down)))
    precondition(home.isHidden == (right != 0 || down != 0), "Home over a tilting flat shell")
    layout()
    shellTurned(rest(rotation) + right * 0.004, "a layout mid-tilt keeps the tilt at \(rotation)")
    display.mouseUp(with: mouse(.leftMouseUp, grab))
    let combined = CATransform3DConcat(lcd.transform, shell.transform)
    let scale = hypot(combined.m11, combined.m12)
    precondition(abs(combined.m11 / scale - 1) < 1e-5 && abs(combined.m12 / scale) < 1e-5, "screen crooked at \(rotation): \(combined)")
    precondition(abs(combined.m13) < 1e-5 && abs(combined.m23) < 1e-5, "pitch left over at \(rotation)")
    close(emulator.attitude.angle, rest(rotation), "rest \(rotation)"); close(emulator.attitude.pitch, 0, "level \(rotation)")
    precondition(!home.isHidden, "Home hidden after release at \(rotation)")
   }
  }
  precondition(sent.isEmpty, "\(sent)")
  print("PASS: chassis drag roll/pitch in every orientation, wheel/precise scaling, Natural Scrolling, momentum, wheel timeout, twist routing, layouts during repeated tilt")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-chassis-') as tmp:
    work = Path(tmp)
    (work / 'check.swift').write_text(source)
    sources = ['UI/DisplayView', 'Input/MouseTouchPair', 'Device/Board+App', '../tests/fixtures/machines', 'UI/DisplayMeasurements', 'UI/ZoomMode', 'Capture/PanelCapture', 'Input/KeyboardPointer', 'Session/ChassisTilt', 'UI/KeyModifiers+AppKit', 'UI/AttitudeIndicatorButton',
               'UI/InlineLiveTextView', 'UI/DroppedFiles', 'UI/DropHighlight', 'UI/GuestKeyboard']
    subprocess.run(['swiftc', *device_runtime.swift_flags(root), '-module-cache-path', str(work / 'modules'), '-default-isolation', 'MainActor',
                    *[str(root / 'LightTouchMac' / f'{s}.swift') for s in sources], str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=60)
