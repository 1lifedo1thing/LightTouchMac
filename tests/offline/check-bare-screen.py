#!/usr/bin/env python3
"""View ▸ Hide Device Bezel: the production DisplayView with the bezel off shows the screen alone, and input,
rotation and zoom still work on it. Windows are built but never ordered in; nothing appears on screen.

Bezel off (DisplayView.showsBezel, persisted): no 3D model is loaded or shown, the flat shell draws nothing and
casts no shadow, there is no Home button, and the LCD alone fills the pane (inset) at its centre, in portrait and
landscape. A click at a point of the LCD sends that point as a touch in both orientations; a click just off the
LCD sends nothing and doesn't grab a chassis to tilt. Zoom ▸ 2x shows two display pixels per guest pixel. Turning
the bezel back on restores the shell art, its shadow and the model; turning it off again drops the model.
--out DIR writes bare-portrait.png, bare-landscape.png and bezel.png there (the flat shell; the stub model draws nothing),
composed from the layer tree's geometry."""
import argparse, ast, subprocess, sys, tempfile
from pathlib import Path
root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "scripts"))
import device_runtime
ap = argparse.ArgumentParser()
ap.add_argument('--out')
args = ap.parse_args()

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
  let out = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil
  // A crashed run can leave the key behind (this binary's own defaults domain): start clean.
  UserDefaults.standard.removeObject(forKey: DisplayView.showsBezelKey)
  defer { UserDefaults.standard.removeObject(forKey: DisplayView.showsBezelKey) }
  precondition(DisplayView.showsBezel, "the bezel shows by default")
  DisplayView.showsBezel = false
  precondition(UserDefaults.standard.object(forKey: DisplayView.showsBezelKey) as? Bool == false, "not persisted")
  DeviceModelView.loadingDelay = .zero; DeviceModelView.preparationDelay = .milliseconds(50)

  let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: .iPodTouch2G)
  let e = EmulatorController(); display.emulator = e
  let window = NSWindow(contentRect: display.frame, styleMask: [.titled], backing: .buffered, defer: false)
  window.contentView = display
  func settle() async throws { display.needsLayout = true; display.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(1300)) }
  try await settle()
  func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
  let lcd = all(display.layer!).first { $0.backgroundColor == NSColor.black.cgColor && $0.contentsGravity == .resize }!
  let shell = lcd.superlayer!
  func models() -> [NSView] { display.subviews.filter { $0 is DeviceModelView } }
  let home = display.subviews.first { NSStringFromClass(type(of: $0)).contains("HomeButton") }!
  func check(_ ok: Bool, _ what: String, line: Int = #line) { precondition(ok, "line \(line): \(what)") }

  check(models().isEmpty && DeviceModelView.framesPrepared == 0, "bare loads no model")
  check(shell.contents == nil && shell.shadowOpacity == 0 && !shell.isHidden, "bare shell draws nothing, casts no shadow")
  check(home.isHidden, "no Home button bare")
  // The LCD's on-screen box, centred, filling the pane less the inset in its long dimension.
  func box() -> CGRect { lcd.convert(lcd.bounds, to: display.layer!) }
  func fills(_ landscape: Bool) {
   let b = box(), side = 800 - 2 * DisplayView.zoomInset
   check(abs(b.midX - 400) < 1 && abs(b.midY - 400) < 1, "LCD off centre: \(b)")
   check(landscape ? b.width > b.height : b.height > b.width, "LCD orientation: \(b)")
   check(abs(max(b.width, b.height) - side) < 1 && min(b.width, b.height) < side, "LCD doesn't fill the pane: \(b)")
  }
  fills(false)
  func click(_ p: CGPoint) {
   let b = box()
   let at = display.convert(CGPoint(x: b.minX + p.x * b.width, y: b.minY + p.y * b.height), to: nil)
   let down = NSEvent.mouseEvent(with: .leftMouseDown, location: at, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
   let up = NSEvent.mouseEvent(with: .leftMouseUp, location: at, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
   touches.removeAll(); display.mouseDown(with: down); display.mouseUp(with: up)
  }
  func touchLands(_ p: CGPoint) {
   click(p)
   check(!touches.isEmpty && abs(touches[0].0 - p.x) < 0.01 && abs(touches[0].1 - p.y) < 0.01, "touch at \(p) sent \(touches)")
  }
  // CALayer.render(in:) drops 3D transforms and IOSurface contents, so the PNG is composed from the live layer
  // tree's geometry: the shell art in the shell's on-screen box (when it draws), the guest frame in the LCD's.
  func render(_ name: String) throws {
   guard let out else { return }
   let size = display.bounds.size, scale: CGFloat = 2
   let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
   let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
   ctx.scaleBy(x: scale, y: scale)
   ctx.setFillColor(NSColor(calibratedWhite: 0.2, alpha: 1).cgColor); ctx.fill(CGRect(origin: .zero, size: size))
   func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }
   if let art = shell.contents, CFGetTypeID(art as CFTypeRef) == CGImage.typeID {
    ctx.draw(art as! CGImage, in: flip(shell.convert(shell.bounds, to: display.layer!)))
   }
   if let frame = display.captureFrame(includeTouches: false) { ctx.draw(frame, in: flip(box())) }
   try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name).png"))
  }
  try render("bare-portrait")
  for p in [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.8, y: 0.7)] { touchLands(p) }
  click(CGPoint(x: 0.5, y: -0.05))
  check(touches.isEmpty && e.attitude.angle == 0, "a click off the LCD touched or tilted: \(touches) \(e.attitude)")

  // Landscape: the surface arrives turned; the LCD stays centred and fills the pane's width.
  e.rotationDegrees = 90; frameWidth = 480; frameHeight = 320
  try await settle()
  fills(true)
  try render("bare-landscape")
  for p in [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.8, y: 0.7)] { touchLands(p) }
  e.rotationDegrees = 0; frameWidth = 320; frameHeight = 480

  // Zoom: 2x is two display pixels per guest pixel, the LCD alone sized by it.
  display.zoom = .pixels(2)
  try await settle()
  check(abs(display.pixelMultiple - 2) < 0.001, "2x zoom gives \(display.pixelMultiple)")
  let backing = window.backingScaleFactor
  check(abs(box().height - 480 * 2 / backing) < 1, "2x LCD is \(box()) at backing \(backing)")
  display.zoom = .fit

  // Back on: the shell art, its shadow and (with the stub renderer) the model; off again drops it.
  DisplayView.showsBezel = true
  try await settle()
  check(shell.contents != nil && shell.shadowOpacity > 0, "bezel on: no shell art or shadow")
  check(models().count == 1 && DeviceModelView.framesPrepared == 1, "bezel on: the model didn't load")
  models().forEach { $0.isHidden = true }; shell.isHidden = false; home.isHidden = false
  try render("bezel")
  DisplayView.showsBezel = false
  try await settle()
  check(models().isEmpty && shell.contents == nil && shell.shadowOpacity == 0 && home.isHidden, "bezel off again: model or shell left")
  fills(false)
  touchLands(CGPoint(x: 0.5, y: 0.5))
  window.contentView = nil

  // The iPad: its panel is mounted sideways in the shell; bare, the screen still stands upright, centred and fitted.
  frameWidth = Int32(DeviceProfile.iPad1.screenPixels.width); frameHeight = Int32(DeviceProfile.iPad1.screenPixels.height)
  let pad = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: .iPad1)
  let padEmulator = EmulatorController(); pad.emulator = padEmulator
  let padWindow = NSWindow(contentRect: pad.frame, styleMask: [.titled], backing: .buffered, defer: false)
  padWindow.contentView = pad
  pad.needsLayout = true; pad.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(300))
  let padLCD = all(pad.layer!).first { $0.backgroundColor == NSColor.black.cgColor && $0.contentsGravity == .resize }!
  let padBox = padLCD.convert(padLCD.bounds, to: pad.layer!), side = 800 - 2 * DisplayView.zoomInset
  check(!pad.subviews.contains { $0 is DeviceModelView } && padLCD.superlayer!.contents == nil, "iPad bare shows a device")
  check(abs(padBox.midX - 400) < 1 && abs(padBox.midY - 400) < 1 && padBox.height > padBox.width
        && abs(padBox.height - side) < 1, "iPad LCD \(padBox)")
  padWindow.contentView = nil
  print("PASS: bezel off shows the LCD alone (no model, shell or Home button), centred and filling the pane in both orientations; touches land; 2x zoom; toggles back and persists")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-bare-screen-') as tmp:
    work = Path(tmp)
    app = work / 'Check.app/Contents'
    (app / 'MacOS').mkdir(parents=True)
    (app / 'Resources').mkdir()
    (app / 'Resources/N72.usdz').symlink_to(root / 'LightTouchMac/N72.usdz')
    (app / 'Resources/shell.png').symlink_to(root / 'LightTouchMac/Assets.xcassets/shell.imageset/shell_opaque.png')
    (work / 'check.swift').write_text(source)
    exe = app / 'MacOS/check'
    sources = ['UI/DisplayView', 'UI/MouseTouchPair', 'Device/DeviceProfile', 'Device/DeviceProfile+Display', 'UI/DisplayMeasurements', 'UI/AttitudeIndicatorButton',
               'UI/InlineLiveTextView', 'UI/DroppedFiles', 'UI/DropHighlight']
    subprocess.run(['swiftc', *device_runtime.swift_flags(root), '-module-cache-path', str(work / 'modules'), '-default-isolation', 'MainActor',
                    *[str(root / 'LightTouchMac' / f'{s}.swift') for s in sources], str(work / 'check.swift'), '-o', str(exe)], check=True)
    if args.out:
        Path(args.out).mkdir(parents=True, exist_ok=True)
    subprocess.run([str(exe), *([str(Path(args.out).resolve())] if args.out else [])], check=True, timeout=60)
