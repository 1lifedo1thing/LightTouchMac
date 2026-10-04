#!/usr/bin/env python3
"""Simulator-style two fingers from a mouse (issue #18): synthetic NSEvents through DisplayView's own mouse
handlers (sliced: mouseDown..mouseUp, hover rings, emit/send) and UI/MouseTouchPair.swift (whole). Option drags a
second finger mirrored through the panel centre; Option-Shift locks the spacing and drags both in parallel. A plain
drag stays one finger. No window is shown."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
s = (root / 'LightTouchMac/UI/DisplayView.swift').read_text()
def cut(a, b):
    i = s.index(a); return s[i:s.index(b, i)].replace('private func', 'func')
code = r"""import Cocoa
enum TouchPhase { static let begin: Int32 = 0, update: Int32 = 1, end: Int32 = 2 }
final class Cursor: NSWindow { var at = NSPoint.zero; override var mouseLocationOutsideOfEventStream: NSPoint { at } }
@MainActor final class Check: NSView {
 let cursor = Cursor(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
 override var window: NSWindow? { cursor }
 final class Emulator { var rotationDegrees = 0 }
 var emulator: Emulator? = nil
 var touchPair = MouseTouchPair()
 let pairRings = [CAShapeLayer(), CAShapeLayer()]
 var touchInteractionEnabled = true, touchDown = false, tilting = false
 var motionRestAngle: CGFloat?, grabPoint = CGPoint.zero, tiltAngle: CGFloat = 0, pitchAngle: CGFloat = 0
 let shellLayer = CALayer()
 static func layerAngle(_ d: Int) -> CGFloat { 0 }
 var restAngle: CGFloat { 0 }
 func endTilt() {}; func setShellAngle(_ a: CGFloat) {}; func sendAttitude() {}
 func pressModelControl(_ e: NSEvent) -> Bool { false }
 func panelResize(_ e: NSEvent) -> Bool { false }
 func isChassisEvent(_ e: NSEvent) -> Bool { false }
 // A 100x100 panel at the window origin.
 func normalized(windowPoint p: NSPoint) -> (Double, Double)? {
  (0...100).contains(p.x) && (0...100).contains(p.y) ? (Double(p.x) / 100, Double(p.y) / 100) : nil
 }
 func normalized(_ e: NSEvent) -> (Double, Double)? { normalized(windowPoint: e.locationInWindow) }
 func clampedPanelPoint(_ e: NSEvent) -> CGPoint? {
  CGPoint(x: min(max(e.locationInWindow.x / 100, 0), 1), y: min(max(e.locationInWindow.y / 100, 0), 1))
 }
 func projectedPanelPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x * 100).rounded(), y: (p.y * 100).rounded()) }
 var sent: [String] = []
 func r(_ v: Double) -> Int { Int((v * 100).rounded()) }
 func sendVisualTouch(_ slot: Int32, _ phase: Int32, _ x: Double, _ y: Double) { sent.append("1:\(phase)@\(r(x)),\(r(y))") }
 func sendVisualTouch2(_ phase: Int32, _ x: Double, _ y: Double) { sent.append("2:\(phase)@\(r(x)),\(r(y))") }
""" + cut('    override func mouseDown(with event: NSEvent) {', '    // MARK: - Tilt (drag the chassis') \
    + cut('    private func emit(_ event: NSEvent, _ phase: Int32) {', '    // MARK: - Keyboard pointer') + r"""
 func ev(_ t: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, _ f: NSEvent.ModifierFlags) -> NSEvent {
  cursor.at = NSPoint(x: x, y: y)
  return NSEvent.mouseEvent(with: t, location: NSPoint(x: x, y: y), modifierFlags: f, timestamp: 0, windowNumber: 0,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
 }
 func drag(_ f: NSEvent.ModifierFlags, _ path: [(CGFloat, CGFloat)]) -> [String] {
  sent = []
  mouseDown(with: ev(.leftMouseDown, path[0].0, path[0].1, f))
  for p in path.dropFirst() { mouseDragged(with: ev(.leftMouseDragged, p.0, p.1, f)) }
  mouseUp(with: ev(.leftMouseUp, path.last!.0, path.last!.1, f))
  return sent
 }
 func hover(_ x: CGFloat, _ y: CGFloat, _ f: NSEvent.ModifierFlags) { mouseMoved(with: ev(.mouseMoved, x, y, f)) }
 var rings: [String] { pairRings.map { $0.isHidden ? "-" : "\(Int($0.position.x)),\(Int($0.position.y))" } }
 func expect(_ got: [String], _ want: [String], _ what: String) {
  if got != want { print("FAIL \(what):\n  got  \(got)\n  want \(want)"); exit(1) }
 }
 func run() {
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
  sent = []; mouseDown(with: ev(.leftMouseDown, 20, 50, [.option, .shift])); mouseDragged(with: ev(.leftMouseDragged, 20, 40, []))
  expect(rings, ["20,40", "60,40"], "rings track the contacts mid-drag")
  mouseUp(with: ev(.leftMouseUp, 20, 40, []))
  expect(sent, ["1:0@20,50", "2:0@60,50", "1:1@20,40", "2:1@60,40", "1:2@20,40", "2:2@60,40"], "releasing keys mid-drag keeps the pan")
  expect(rings, ["-", "-"], "no rings without Option")
  hover(80, 50, .option); hover(80, 50, [.option, .shift])
  expect(drag([.option, .shift], [(80, 50), (70, 50)]), ["1:0@80,50", "2:0@20,50", "1:1@70,50", "2:1@10,50", "1:2@70,50", "2:2@10,50"],
         "releasing Option drops the old lock; the next Option-Shift locks afresh")
  touchInteractionEnabled = false; hover(50, 50, .option); expect(rings, ["-", "-"], "no rings while input is off")
  print("PASS: plain drag one finger; Option mirrored pinch; Option-Shift locked parallel pan; hover and drag rings")
 }
}
@main struct Main { @MainActor static func main() { Check(frame: .zero).run() } }
"""
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp); (tmp / 'check.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(tmp / 'check.swift'),
                    str(root / 'LightTouchMac/UI/MouseTouchPair.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check')], check=True)
