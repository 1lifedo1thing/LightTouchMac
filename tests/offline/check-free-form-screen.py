#!/usr/bin/env python3
"""View ▸ Free-Form Screen (issue #21): the production DisplayView resized by dragging, and a non-native panel's
display and touch mapping. Windows are built but never ordered in; nothing appears on screen.

- Sizes: DeviceProfile.snappedPanel clamps and snaps an upright size to what the board's panel= accepts (iPod even
  width 64…1024 by 64…511 rows; iPad landscape width a multiple of 16, 64…2047, within iBoot's 9 MB display
  region); panelOption/uprightPanel turn it into device.json's "WxH" as the panel scans (the iPad's landscape).
- Display: an iPod at 320x504 shows its LCD alone at one point per guest pixel, centred; 2x zoom doubles it; a
  click at a point of the LCD is a touch at that fraction. An iPad at 1280x768 (portrait 768x1280) likewise.
- Drag: a press just outside the LCD's edge grabs it; dragging stretches the LCD (the frame squishes live) and the
  readout shows the snapped W × H; past the board's limit it clamps (iPod 511 rows); the iPad's height snaps to 16s.
  In landscape the sides swap (dragging the iPod's on-screen width changes its rows). On release, after
  panelCommitDelay, the owner is asked to restart at the new upright panel, and the screen reads "Restarting at…"
  and keeps the stretched frame; with no restart (a stopped device) the size is just taken.
- Off returns to the shipped panel (a restart when the guest runs at another), and a device that was never
  free-form is untouched: no grab band, no readout.
"""
import ast, subprocess, sys, tempfile
from pathlib import Path
root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "scripts"))
import device_runtime

# check-model's DisplayView fixture (fake link and emulator) and check-model-startup's stub model.
node = ast.parse((root / 'tests/offline/check-model.py').read_text())
fixture = next(ast.literal_eval(n.value) for n in node.body if isinstance(n, ast.Assign)
               and any(isinstance(t, ast.Name) and t.id == 'display_source' for t in n.targets))
prefix = fixture[:fixture.index('@main struct Check')]
startup = (root / 'tests/offline/check-model-startup.py').read_text()
start = startup.index('@MainActor final class DeviceModelView')
stub = startup[start:startup.index('@main struct Check', start)]

source = prefix + stub + r'''
@main struct Check {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.prohibited)
  func check(_ ok: Bool, _ what: String, line: Int = #line) { precondition(ok, "line \(line): \(what)") }
  func size(_ w: CGFloat, _ h: CGFloat) -> CGSize { CGSize(width: w, height: h) }

  // Sizes the boards accept.
  let pod = DeviceProfile.iPodTouch2G, pad = DeviceProfile.iPad1
  check(pod.snappedPanel(upright: size(321, 600)) == size(320, 511), "iPod: even width, 511 rows")
  check(pod.snappedPanel(upright: size(10, 10)) == size(64, 64), "iPod minimum")
  check(pod.snappedPanel(upright: size(1100, 300)) == size(1024, 300), "iPod maximum width")
  check(pod.snappedPanel(upright: size(320, 480)) == size(320, 480), "iPod native")
  check(pad.snappedPanel(upright: size(768, 1290)) == size(768, 1280), "iPad: landscape width (portrait height) in 16s")
  check(pad.snappedPanel(upright: size(768, 1024)) == size(768, 1024), "iPad native")
  let big = pad.snappedPanel(upright: size(2000, 2000))
  check(big.width * big.height <= DeviceProfile.iPadPanelPixels && Int(big.height) % 16 == 0 && big.width >= 1500,
        "iPad display region: \(big)")
  check(pad.panelOption(upright: size(768, 1280)) == "1280x768" && pad.uprightPanel("1280x768") == size(768, 1280), "iPad panel=")
  check(pod.panelOption(upright: size(320, 504)) == "320x504" && pod.uprightPanel("320x504") == size(320, 504), "iPod panel=")
  check(!DeviceProfile.iPodTouch1G.supportsFreeForm && pod.supportsFreeForm && pad.supportsFreeForm, "boards")

  DisplayView.panelCommitDelay = .milliseconds(50)
  var requests: [(CGSize?, Bool)] = []
  var restarts = true

  func make(_ profile: DeviceProfile, panel: CGSize?) async throws -> (DisplayView, EmulatorController, NSWindow) {
   let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 1400, height: 1400), profile: profile)
   let e = EmulatorController(); display.emulator = e
   display.configureFreeForm(panel: panel, key: UUID())
   display.onPanelChange = { upright, restart in requests.append((upright, restart)); return restart && restarts }
   let window = NSWindow(contentRect: display.frame, styleMask: [.titled], backing: .buffered, defer: false)
   window.contentView = display
   try await settle(display)
   return (display, e, window)
  }
  func settle(_ d: DisplayView) async throws { d.needsLayout = true; d.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(300)) }
  func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
  func box(_ d: DisplayView) -> CGRect {
   let lcd = all(d.layer!).first { $0.backgroundColor == NSColor.black.cgColor && $0.contentsGravity == .resize }!
   return lcd.convert(lcd.bounds, to: d.layer!)
  }
  func near(_ a: CGRect, _ w: CGFloat, _ h: CGFloat) -> Bool { abs(a.width - w) < 1 && abs(a.height - h) < 1 }
  func event(_ type: NSEvent.EventType, _ d: DisplayView, _ p: CGPoint) -> NSEvent {
   NSEvent.mouseEvent(with: type, location: d.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: d.window!.windowNumber,
                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  }
  /// A click at fraction `f` of the LCD as seen is a touch at that point of the panel as it scans: the iPod's
  /// surface is pre-rotated (as seen); the iPad's landscape panel stands a quarter turn clockwise, (f.y, 1 - f.x).
  func touchLands(_ d: DisplayView, _ f: CGPoint, ipad: Bool = false) {
   let b = box(d), p = CGPoint(x: b.minX + f.x * b.width, y: b.minY + f.y * b.height)
   let want = ipad ? CGPoint(x: f.y, y: 1 - f.x) : f
   touches.removeAll(); d.mouseDown(with: event(.leftMouseDown, d, p)); d.mouseUp(with: event(.leftMouseUp, d, p))
   check(!touches.isEmpty && abs(touches[0].0 - want.x) < 0.01 && abs(touches[0].1 - want.y) < 0.01, "touch at \(f) sent \(touches)")
  }
  /// Grab just outside the LCD at `from` (view points), drag by `by`, release.
  func drag(_ d: DisplayView, from: CGPoint, by: CGVector, release: Bool = true) {
   touches.removeAll()
   d.mouseDown(with: event(.leftMouseDown, d, from))
   let to = CGPoint(x: from.x + by.dx, y: from.y + by.dy)
   d.mouseDragged(with: event(.leftMouseDragged, d, to))
   d.layoutSubtreeIfNeeded()
   if release { d.mouseUp(with: event(.leftMouseUp, d, to)) }
   check(touches.isEmpty, "a resize drag touched the guest: \(touches)")
  }

  // iPod at 320x504: the LCD alone, a point per guest pixel, centred; touches land.
  frameWidth = 320; frameHeight = 504
  var (d, e, w) = try await make(pod, panel: size(320, 504))
  check(d.isFreeForm && near(box(d), 320, 504), "iPod 320x504 at 1x: \(box(d))")
  check(abs(box(d).midX - 700) < 1 && abs(box(d).midY - 700) < 1, "off centre: \(box(d))")
  check(!d.subviews.contains { $0 is DeviceModelView }, "free-form shows a device")
  for f in [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.8, y: 0.95)] { touchLands(d, f) }
  d.zoom = .pixels(2); try await settle(d)
  check(near(box(d), 640, 1008), "2x: \(box(d))")
  d.zoom = .fit; try await settle(d)

  // Drag the right edge 40 points: 40 more on each side of the centred screen.
  var b = box(d)
  drag(d, from: CGPoint(x: b.maxX + 4, y: b.midY), by: CGVector(dx: 40, dy: 0), release: false)
  check(d.panelReadoutText == "400 × 504", "readout \(d.panelReadoutText ?? "none")")
  check(near(box(d), 400, 504), "stretched LCD \(box(d))")
  // On down past 511 rows: clamped. The corner takes both.
  b = box(d)
  d.mouseUp(with: event(.leftMouseUp, d, CGPoint(x: b.maxX + 4, y: b.midY)))
  drag(d, from: CGPoint(x: b.maxX + 4, y: b.maxY + 4), by: CGVector(dx: 10.3, dy: 400))
  check(d.panelReadoutText == "420 × 511", "clamped readout \(d.panelReadoutText ?? "none")")
  check(near(box(d), 420, 511) && requests.isEmpty, "clamped LCD \(box(d)); asked early \(requests)")
  try await Task.sleep(for: .milliseconds(300))
  check(requests.count == 1 && requests[0].0 == size(420, 511) && requests[0].1, "release asked \(requests)")
  check(d.restartingAtPanel && d.panelReadoutText == "Restarting at 420 × 511…" && near(box(d), 420, 511),
        "restart: \(d.panelReadoutText ?? "none") \(box(d))")
  b = box(d)
  d.mouseDown(with: event(.leftMouseDown, d, CGPoint(x: b.maxX + 4, y: b.midY)))
  check(d.panelReadoutText == "Restarting at 420 × 511…", "a drag during the restart")
  w.contentView = nil

  // Landscape: the screen's sides swap, so its on-screen width is the panel's rows.
  requests.removeAll(); restarts = false
  (d, e, w) = try await make(pod, panel: size(320, 504))
  e.rotationDegrees = 90; frameWidth = 504; frameHeight = 320
  try await settle(d)
  check(near(box(d), 504, 320), "landscape \(box(d))")
  touchLands(d, CGPoint(x: 0.25, y: 0.75))
  b = box(d)
  drag(d, from: CGPoint(x: b.minX - 4, y: b.midY), by: CGVector(dx: -3, dy: 0))
  check(d.panelReadoutText == "510 × 320", "landscape readout \(d.panelReadoutText ?? "none")")
  try await Task.sleep(for: .milliseconds(300))
  // No restart (a stopped device): the size is simply taken.
  check(requests.count == 1 && requests[0].0 == size(320, 510), "landscape asked \(requests)")
  check(!d.restartingAtPanel && d.panelReadoutText == nil && d.isFreeForm, "taken without a restart")
  try await settle(d)
  check(near(box(d), 510, 320), "landscape after \(box(d))")
  e.rotationDegrees = 0; frameWidth = 320; frameHeight = 510
  // Off at a non-native size: back to the shipped panel by a restart.
  requests.removeAll(); restarts = true
  d.setFreeForm(false)
  check(requests.count == 1 && requests[0].0 == nil && requests[0].1 && d.panelReadoutText == "Restarting at 320 × 480…",
        "off asked \(requests) \(d.panelReadoutText ?? "none")")
  w.contentView = nil

  // iPad at 1280x768: portrait 768x1280, touches land; its height snaps to 16s.
  requests.removeAll()
  frameWidth = 1280; frameHeight = 768
  (d, e, w) = try await make(pad, panel: size(768, 1280))
  check(near(box(d), 768, 1280), "iPad 768x1280 \(box(d))")
  for f in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.6)] { touchLands(d, f, ipad: true) }
  b = box(d)
  drag(d, from: CGPoint(x: b.midX, y: b.minY - 4), by: CGVector(dx: 0, dy: 20), release: false)
  check(d.panelReadoutText == "768 × 1232", "iPad shrink \(d.panelReadoutText ?? "none")")
  d.mouseDragged(with: event(.leftMouseDragged, d, CGPoint(x: b.midX, y: b.minY - 4 + 4)))
  check(d.panelReadoutText == "768 × 1264", "iPad snap \(d.panelReadoutText ?? "none")")
  d.mouseUp(with: event(.leftMouseUp, d, CGPoint(x: b.midX, y: b.minY)))
  try await Task.sleep(for: .milliseconds(300))
  check(requests.count == 1 && requests[0].0 == size(768, 1264) && pad.panelOption(upright: requests[0].0!) == "1264x768",
        "iPad asked \(requests)")
  w.contentView = nil

  // Free-form on from the shipped device: no restart, the same size; never free-form: no grab band.
  requests.removeAll()
  frameWidth = 320; frameHeight = 480
  (d, e, w) = try await make(pod, panel: nil)
  b = box(d)
  d.mouseDown(with: event(.leftMouseDown, d, CGPoint(x: b.maxX + 4, y: b.midY)))
  d.mouseUp(with: event(.leftMouseUp, d, CGPoint(x: b.maxX + 4, y: b.midY)))
  check(!d.isFreeForm && d.panelReadoutText == nil && touches.isEmpty, "a shipped device grabbed")
  d.setFreeForm(true); try await settle(d)
  check(d.isFreeForm && requests.count == 1 && requests[0].0 == size(320, 480) && !requests[0].1 && near(box(d), 320, 480),
        "on: \(requests) \(box(d))")
  w.contentView = nil
  print("PASS: panel sizes clamp and snap per board; a non-native panel shows a point per guest pixel and takes touches; edge and corner drags stretch the screen live with a snapped readout, swap in landscape, and ask for a restart at the new panel on release")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-free-form-') as tmp:
    work = Path(tmp)
    app = work / 'Check.app/Contents'
    (app / 'MacOS').mkdir(parents=True)
    (app / 'Resources').mkdir()
    (work / 'check.swift').write_text(source)
    exe = app / 'MacOS/check'
    sources = ['UI/DisplayView', 'UI/MouseTouchPair', 'Device/DeviceProfile', 'Device/DeviceProfile+Display', 'UI/DisplayMeasurements', 'UI/AttitudeIndicatorButton',
               'UI/InlineLiveTextView', 'UI/DroppedFiles', 'UI/DropHighlight']
    subprocess.run(['swiftc', *device_runtime.swift_flags(root), '-module-cache-path', str(work / 'modules'), '-default-isolation', 'MainActor',
                    *[str(root / 'LightTouchMac' / f'{s}.swift') for s in sources], str(work / 'check.swift'), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True, timeout=60)
