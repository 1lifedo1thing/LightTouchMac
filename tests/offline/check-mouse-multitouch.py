#!/usr/bin/env python3
"""Simulator-style two fingers from a mouse (issue #18), through the production DisplayView compiled whole (check-model's
fixture with a link that records each finger's phase, check-model-startup's stub model, the bezel off so the LCD alone
takes the clicks): synthetic NSEvents through its mouse handlers, hover rings included. Option drags a second finger
mirrored through the panel centre; Option-Shift locks the spacing and drags both in parallel. A plain drag stays one
finger. No window is shown. The pair's own rules are MouseTouchPairTests'."""
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
prefix = prefix.replace(link, r''' func send(_ command: LinkCommand) {
  func r(_ v: Double) -> Int { Int((v * 100).rounded()) }
  switch command {
  case let .touch(_, phase, x, y): sent.append("1:\(phase)@\(r(x)),\(r(y))")
  case let .touch2(phase, x, y): sent.append("2:\(phase)@\(r(x)),\(r(y))")
  default: break
  }
 }''').replace('@MainActor var touches', '@MainActor var sent: [String] = []\n@MainActor var touches')
startup = (root / 'tests/offline/check-model-startup.py').read_text()
start = startup.index('@MainActor final class DeviceModelView')
stub = startup[start:startup.index('@main struct Check', start)]

source = prefix + stub + r'''
final class Cursor: NSWindow { var at = NSPoint.zero; override var mouseLocationOutsideOfEventStream: NSPoint { at } }
@main struct Check {
 @MainActor static func main() async throws {
  _ = fixtureMachines
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.prohibited)
  for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] { UserDefaults.standard.removeObject(forKey: key) }
  defer { for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] { UserDefaults.standard.removeObject(forKey: key) } }
  DisplayView.bezel = .off
  let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: .n72)
  let emulator = EmulatorController(); display.emulator = emulator   // weak: held here
  defer { withExtendedLifetime(emulator) {} }
  let window = Cursor(contentRect: display.frame, styleMask: [.titled], backing: .buffered, defer: false)
  window.contentView = display
  display.needsLayout = true; display.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(1300))
  display.needsLayout = true; display.layoutSubtreeIfNeeded()
  func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
  let lcd = all(display.layer!).first { $0.backgroundColor == NSColor.black.cgColor && $0.contentsGravity == .resize }!
  let box = lcd.convert(lcd.bounds, to: display.layer!)
  let pairRings = all(display.layer!).compactMap { $0 as? CAShapeLayer }.filter { $0.bounds.size == CGSize(width: 30, height: 30) }
  precondition(pairRings.count == 2, "pair rings: \(pairRings.count)")
  // Points are percent of the panel.
  func ev(_ t: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, _ f: NSEvent.ModifierFlags) -> NSEvent {
   let at = display.convert(CGPoint(x: box.minX + x / 100 * box.width, y: box.minY + y / 100 * box.height), to: nil)
   window.at = at
   return NSEvent.mouseEvent(with: t, location: at, modifierFlags: f, timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }
  func drag(_ f: NSEvent.ModifierFlags, _ path: [(CGFloat, CGFloat)]) -> [String] {
   sent = []
   display.mouseDown(with: ev(.leftMouseDown, path[0].0, path[0].1, f))
   for p in path.dropFirst() { display.mouseDragged(with: ev(.leftMouseDragged, p.0, p.1, f)) }
   display.mouseUp(with: ev(.leftMouseUp, path.last!.0, path.last!.1, f))
   return sent
  }
  func hover(_ x: CGFloat, _ y: CGFloat, _ f: NSEvent.ModifierFlags) { display.mouseMoved(with: ev(.mouseMoved, x, y, f)) }
  var rings: [String] {
   pairRings.map { $0.isHidden ? "-" : "\(Int(((($0.position.x - box.minX) / box.width) * 100).rounded())),\(Int(((($0.position.y - box.minY) / box.height) * 100).rounded()))" }
  }
  func expect(_ got: [String], _ want: [String], _ what: String) {
   if got != want { print("FAIL \(what):\n  got  \(got)\n  want \(want)"); exit(1) }
  }
  expect(drag([], [(30, 40), (20, 30)]), ["1:0@30,40", "1:1@20,30", "1:2@20,30"], "plain drag is one finger")
  expect(drag(.option, [(30, 40), (20, 30)]),
         ["1:0@30,40", "2:0@70,60", "1:1@20,30", "2:1@80,70", "1:2@20,30", "2:2@80,70"], "Option mirrors through the centre")
  hover(30, 50, .option); expect(rings, ["30,50", "70,50"], "Option hover shows the mirrored pair")
  hover(30, 50, [.option, .shift]); hover(20, 50, [.option, .shift])
  expect(rings, ["20,50", "60,50"], "Option-Shift hover keeps the spacing locked when Shift went down")
  expect(drag([.option, .shift], [(20, 50), (20, 30), (25, 10)]),
         ["1:0@20,50", "2:0@60,50", "1:1@20,30", "2:1@60,30", "1:1@25,10", "2:1@65,10", "1:2@25,10", "2:2@65,10"],
         "Option-Shift drags both fingers in parallel")
  expect(rings, ["25,10", "65,10"], "rings return to the hover pair after the drag")
  sent = []; display.mouseDown(with: ev(.leftMouseDown, 20, 50, [.option, .shift])); display.mouseDragged(with: ev(.leftMouseDragged, 20, 40, []))
  expect(rings, ["20,40", "60,40"], "rings track the contacts mid-drag")
  display.mouseUp(with: ev(.leftMouseUp, 20, 40, []))
  expect(sent, ["1:0@20,50", "2:0@60,50", "1:1@20,40", "2:1@60,40", "1:2@20,40", "2:2@60,40"], "releasing keys mid-drag keeps the pan")
  expect(rings, ["-", "-"], "no rings without Option")
  hover(80, 50, .option); hover(80, 50, [.option, .shift])
  expect(drag([.option, .shift], [(80, 50), (70, 50)]), ["1:0@80,50", "2:0@20,50", "1:1@70,50", "2:1@10,50", "1:2@70,50", "2:2@10,50"],
         "releasing Option drops the old lock; the next Option-Shift locks afresh")
  print("PASS: plain drag one finger; Option mirrored pinch; Option-Shift locked parallel pan; hover and drag rings")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-multitouch-') as tmp:
    work = Path(tmp)
    (work / 'check.swift').write_text(source)
    sources = ['UI/DisplayView', 'Input/MouseTouchPair', 'Device/Board+App', '../tests/fixtures/machines', 'UI/DisplayMeasurements', 'UI/ZoomMode', 'Capture/PanelCapture', 'Input/KeyboardPointer', 'UI/KeyModifiers+AppKit', 'UI/AttitudeIndicatorButton',
               'UI/InlineLiveTextView', 'UI/DroppedFiles', 'UI/DropHighlight', 'UI/GuestKeyboard']
    subprocess.run(['swiftc', *device_runtime.swift_flags(root), '-module-cache-path', str(work / 'modules'), '-default-isolation', 'MainActor',
                    *[str(root / 'LightTouchMac' / f'{s}.swift') for s in sources], str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=60)
