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
- Only the screen's edges resize it: a window resize or a sidebar collapse/expand changes neither the panel nor
  (at Nx) the LCD's size, and asks for no restart; at Fit the panel is scaled into the pane as the shipped screen is.
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
  check(pod.snappedPanel(upright: size(1100, 600)) == size(510, 511), "iPod: never wider than tall upright")
  check(pad.snappedPanel(upright: size(1100, 1024)) == size(1024, 1024), "iPad: never wider than tall upright")
  check(pad.snappedPanel(upright: size(1024, 1024)) == size(1024, 1024), "iPad square")
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
  let one = 1
  var statuses: [String?] = []   // what the owner's notice stack is given
  var restarts = true

  func make(_ profile: DeviceProfile, panel: CGSize?, scan: CGSize? = nil, key: UUID = UUID(),
            rotation: Int = 0) async throws -> (DisplayView, EmulatorController, NSWindow) {
   let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 1400, height: 1400), profile: profile)
   let e = EmulatorController(); display.emulator = e
   e.rotationDegrees = rotation
   display.configureFreeForm(scan: scan ?? panel.map { profile.scan(upright: $0) }, key: key)
   display.onPanelStatus = { statuses.append($0) }
   display.onPanelChange = { upright, restart in requests.append((upright, restart)); return restart && restarts }
   let window = NSWindow(contentRect: display.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
   // The pane sits in a container, as the window's split view holds it beside the sidebar.
   let container = NSView(frame: display.frame)
   display.autoresizingMask = [.width, .height]
   container.addSubview(display)
   window.contentView = container
   display.zoom = .pixels(one)   // free-form Nx is N points per guest pixel
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
  d.zoom = .pixels(2 * one); try await settle(d)
  check(near(box(d), 640, 1008), "2x: \(box(d))")
  // ⌘+/⌘− step from the multiple shown, in free-form's unit (points per guest pixel).
  check(abs(d.pixelMultiple - 2) < 0.001, "2x reads as \(d.pixelMultiple) for zoom stepping")
  d.zoom = .pixels(one); try await settle(d)

  // Only the screen's own edges resize it. A window resize (AppKit's live resize around it) and a sidebar
  // collapse or expand leave the panel, the restart and, at Nx, the LCD's size alone (a pane too small clips it).
  func pane(_ frame: CGRect, live: Bool) async throws {
   if live { d.viewWillStartLiveResize() }
   d.frame = frame
   try await settle(d)
   if live { d.viewDidEndLiveResize() }
   try await Task.sleep(for: .milliseconds(200))
   try await settle(d)
  }
  func untouched(_ what: String, line: Int = #line) {
   check(requests.isEmpty && !d.restartingAtPanel && d.panelReadoutText == nil && d.freeFormPanel == size(320, 504),
         "\(what) changed the panel: \(requests) \(d.panelReadoutText ?? "none") \(String(describing: d.freeFormPanel))", line: line)
  }
  try await pane(CGRect(x: 0, y: 0, width: 900, height: 700), live: true)
  check(near(box(d), 320, 504), "window resize moved the LCD: \(box(d))"); untouched("a window resize")
  try await pane(CGRect(x: 300, y: 0, width: 300, height: 1400), live: false)        // the sidebar shown
  check(near(box(d), 320, 504), "sidebar shown: \(box(d))"); untouched("a sidebar expand")
  try await pane(CGRect(x: 0, y: 0, width: 1400, height: 1400), live: false)         // and collapsed
  check(near(box(d), 320, 504), "sidebar collapsed: \(box(d))"); untouched("a sidebar collapse")
  // Fit scales the panel into the pane as it does the shipped screen; still no new panel.
  d.zoom = .fit; try await pane(CGRect(x: 0, y: 0, width: 600, height: 600), live: true)
  check(abs(box(d).height - (600 - 2 * DisplayView.zoomInset)) < 1 && abs(box(d).width / box(d).height - 320.0 / 504) < 0.01,
        "fit: \(box(d))"); untouched("a window resize at Fit")
  d.zoom = .pixels(one); try await pane(CGRect(x: 0, y: 0, width: 1400, height: 1400), live: true)
  untouched("a window resize back")

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
  check(statuses.last == "Restarting at 420 × 511…" && statuses.contains("400 × 504"), "notices \(statuses)")
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

  // Zoom only draws the screen bigger or smaller. At 1x, 2x and Fit, portrait and landscape, a 320x448 iPod's
  // LCD is the panel at a guest pixel per N points (Fit: the largest that fits the pane, aspect kept), zooming
  // changes neither the panel nor asks for a restart, and an edge drag converts the pointer through the zoom.
  requests.removeAll(); restarts = false
  for rotation in [0, 90] {
   let sideways = rotation == 90, upright = size(320, 448), seen = sideways ? size(448, 320) : upright
   for zoom in [ZoomMode.pixels(1), .pixels(2), .fit] {
    frameWidth = Int32(sideways ? 448 : 320); frameHeight = Int32(sideways ? 320 : 448)
    (d, e, w) = try await make(pod, panel: upright, rotation: rotation)
    for z in [ZoomMode.pixels(2), .fit, .pixels(1), zoom] { d.zoom = z; try await settle(d) }
    let k: CGFloat = zoom == .fit ? min((1400 - 2 * DisplayView.zoomInset) / seen.width, (1400 - 2 * DisplayView.zoomInset) / seen.height)
                                  : CGFloat(zoom.percent!) / 100
    let what = "\(zoom) at \(rotation)°"
    check(near(box(d), seen.width * k, seen.height * k) && abs(box(d).midX - 700) < 1 && abs(box(d).midY - 700) < 1,
          "\(what): LCD \(box(d)), want \(seen) x \(k)")
    check(requests.isEmpty && d.freeFormPanel == upright && d.panelReadoutText == nil, "\(what): zooming changed the panel \(requests)")
    // The right edge 12 points out: the seen width grows by 24 points, 24 / k guest pixels.
    let b = box(d)
    drag(d, from: CGPoint(x: b.maxX + 4, y: b.midY), by: CGVector(dx: 12, dy: 0), release: false)
    let grown = CGSize(width: seen.width + 24 / k, height: seen.height)
    let want = pod.snappedPanel(upright: sideways ? size(grown.height, grown.width) : grown)
    let wantSeen = sideways ? size(want.height, want.width) : want
    check(d.panelReadoutText == "\(Int(wantSeen.width)) × \(Int(wantSeen.height))" && near(box(d), wantSeen.width * k, wantSeen.height * k),
          "\(what): drag gave \(d.panelReadoutText ?? "none") \(box(d)), want \(wantSeen)")
    w.contentView = nil
   }
  }

  // Orientation comes from the guest's rule, not the board: UIKit turns its portrait UI a quarter only into a
  // panel that scans wider than tall. Square, wider and taller scans on both boards, in all four rotations: the
  // LCD and a capture are the upright screen turned with the device, and a click at a point of it touches the
  // point of the scan the guest drew there.
  func rotCCW(_ p: CGPoint, _ quarters: Int) -> CGPoint {
   var q = p; for _ in 0..<((quarters % 4 + 4) % 4) { q = CGPoint(x: q.y, y: 1 - q.x) }; return q
  }
  func rotCW(_ p: CGPoint, _ quarters: Int) -> CGPoint { rotCCW(p, 4 - (quarters % 4 + 4) % 4) }
  for (profile, scans) in [(pod, [size(400, 400), size(320, 504), size(504, 320)]),
                           (pad, [size(1024, 1024), size(1104, 1024), size(1024, 1104)])] {
   for scan in scans {
    let turned = scan.width > scan.height
    let upright = turned ? size(scan.height, scan.width) : scan
    for rotation in [0, 90, 180, 270] {
     let quarters = rotation / 90, sideways = quarters % 2 == 1
     // What the guest publishes: the scan; the iPod's LCD model turns it with the device.
     let published = profile.surfaceFollowsRotation && sideways ? size(scan.height, scan.width) : scan
     frameWidth = Int32(published.width); frameHeight = Int32(published.height)
     (d, e, w) = try await make(profile, panel: nil, scan: scan, rotation: rotation)
     let seen = sideways ? size(upright.height, upright.width) : upright
     let what = "\(profile) scan \(Int(scan.width))x\(Int(scan.height)) at \(rotation)°"
     check(near(box(d), seen.width, seen.height), "\(what): LCD \(box(d)), want \(seen)")
     let shot = d.captureFrame(includeTouches: false)!
     check(shot.width == Int(seen.width) && shot.height == Int(seen.height), "\(what): capture \(shot.width)x\(shot.height)")
     for f in [CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.85, y: 0.6)] {
      let b = box(d), at = CGPoint(x: b.minX + f.x * b.width, y: b.minY + f.y * b.height)
      let u = rotCCW(f, quarters), g = turned ? rotCCW(u, 1) : u
      let want = profile.surfaceFollowsRotation ? rotCW(g, quarters) : g
      touches.removeAll(); d.mouseDown(with: event(.leftMouseDown, d, at)); d.mouseUp(with: event(.leftMouseUp, d, at))
      check(!touches.isEmpty && abs(touches[0].0 - want.x) < 0.01 && abs(touches[0].1 - want.y) < 0.01,
            "\(what): click at \(f) sent \(touches), want \(want)")
     }
     w.contentView = nil
    }
   }
  }

  // Back at the shipped panel the bezel follows View ▸ Show Device Bezel again, live: Free-Form on, a resize,
  // Free-Form off (a restart), then the next session's view (shown, swapped out and back as the window does)
  // takes the toggle both ways. A free-form screen ignores it.
  UserDefaults.standard.removeObject(forKey: DisplayView.showsBezelKey)
  defer { UserDefaults.standard.removeObject(forKey: DisplayView.showsBezelKey) }
  DisplayView.showsBezel = false
  requests.removeAll(); restarts = true
  frameWidth = 1104; frameHeight = 768
  let key = UUID()
  (d, e, w) = try await make(pad, panel: size(768, 1104), key: key)   // booted at the size a drag gave it
  d.setFreeForm(false)
  check(requests.last.map { $0.0 == nil && $0.1 } == true, "off at 768x1104 asked \(requests)")
  func shellShown(_ v: DisplayView) -> Bool {
   let lcd = all(v.layer!).first { $0.backgroundColor == NSColor.black.cgColor && $0.contentsGravity == .resize }!
   return lcd.superlayer!.contents != nil && lcd.superlayer!.shadowOpacity > 0
  }
  DisplayView.showsBezel = true; try await settle(d)
  check(!shellShown(d), "a free-form screen took the bezel")
  w.contentView = nil
  frameWidth = 1024; frameHeight = 768
  let (next, _, nw) = try await make(pad, panel: nil, key: key)
  let holder = nw.contentView!
  nw.contentView = nil; try await Task.sleep(for: .milliseconds(50)); nw.contentView = holder   // the session swap
  try await settle(next)
  DisplayView.showsBezel = false; try await settle(next)
  check(!next.isFreeForm && !shellShown(next), "bezel off: the shipped iPad still shows it")
  DisplayView.showsBezel = true; try await settle(next)
  check(shellShown(next), "bezel on: the shipped iPad stayed bare")
  DisplayView.showsBezel = false; try await settle(next)
  check(!shellShown(next), "bezel off again: the shipped iPad kept it")
  nw.contentView = nil
  print("PASS: panel sizes clamp and snap per board (never wider than tall upright); a non-native panel draws at N points per guest pixel, Fit and Nx in both orientations, edge drags converting through the zoom; window and sidebar changes never touch the panel; square, wider and taller scans give the upright picture and touch mapping in all four rotations; the drag status and restart go to the notice stack; back at the shipped panel the bezel follows the toggle live")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-free-form-') as tmp:
    work = Path(tmp)
    app = work / 'Check.app/Contents'
    (app / 'MacOS').mkdir(parents=True)
    (app / 'Resources').mkdir()
    (app / 'Resources/ipad-frame.png').symlink_to(root / 'LightTouchMac/Assets.xcassets/ipad-frame.imageset' /
        next(f for f in (root / 'LightTouchMac/Assets.xcassets/ipad-frame.imageset').iterdir() if f.suffix == '.png').name)
    (work / 'check.swift').write_text(source)
    exe = app / 'MacOS/check'
    sources = ['UI/DisplayView', 'UI/MouseTouchPair', 'Device/DeviceProfile', 'Device/DeviceProfile+Display', 'UI/DisplayMeasurements', 'UI/AttitudeIndicatorButton',
               'UI/InlineLiveTextView', 'UI/DroppedFiles', 'UI/DropHighlight']
    subprocess.run(['swiftc', *device_runtime.swift_flags(root), '-module-cache-path', str(work / 'modules'), '-default-isolation', 'MainActor',
                    *[str(root / 'LightTouchMac' / f'{s}.swift') for s in sources], str(work / 'check.swift'), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True, timeout=60)
