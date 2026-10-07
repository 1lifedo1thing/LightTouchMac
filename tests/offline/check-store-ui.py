#!/usr/bin/env python3
"""The Store's filter pull-down and the version sheet as AppKit draws them. Offline, nothing on screen.

The filter's rules (CatalogFilter) and the sheet's model (CatalogDetailsModel) are Swift Testing's StoreFilterTests
and CatalogDetailsModelTests; this is the AppKit side over them, against the recorded Legacy Store responses in
tests/fixtures/store-filter. Filter (real CatalogFilterButton, driven through its menu items, in a throwaway defaults
suite): the iPod's family choice is dimmed and its Show Unavailable Apps toggle live and checked; a toggle reports
and checks off; the iPad offers both families, checks iPad Apps Only when chosen, and a new button reads the saved
choices back. Sheet (real CatalogDetailsView over CatalogDetailsModel and a local server): fits its content for a
compatible and an incompatible copy.
Renders filter-*.png and sheet-*.png into --out (offscreen windows, never ordered front).
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs
import argparse, os, subprocess, tempfile, threading

root = Path(__file__).resolve().parents[2]
import sys
sys.path.insert(0, str(root / "scripts"))
import host_runtime
fixtures = root / 'tests/fixtures/store-filter'
ap = argparse.ArgumentParser()
ap.add_argument('--out')
args = ap.parse_args()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        name = {'/api/v1/apps/com.playfirst.hoteldash/versions': 'versions-hoteldash.json',
                '/api/v1/apps/com.secondarm.taptapdash/versions': 'versions-taptapdash.json'}.get(url.path)
        if url.path.startswith('/api/v1/copies/'):
            name = 'copy-' + url.path.rsplit('/', 1)[1] + '.json'
        if url.path == '/api/emulator/apps' and query.get('ipa_id') == ['207203']:
            name = 'emulator-207203.json'
        if not name or not (fixtures / name).exists():
            return self.send_error(404)
        body = (fixtures / name).read_bytes()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


code = r'''import Cocoa
import SwiftUI
@main struct Check {
 @MainActor static func main() async throws {
  func check(_ ok: Bool, _ what: String, line: Int = #line) { precondition(ok, "line \(line): \(what)") }
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.prohibited)
  CatalogClient.baseURL = URL(string: "http://127.0.0.1:\(CommandLine.arguments[1])")!
  let fixtures = URL(fileURLWithPath: CommandLine.arguments[2]), out = URL(fileURLWithPath: CommandLine.arguments[3])
  struct Envelope: Decodable { let apps: [CatalogApp] }
  func apps(_ name: String) throws -> [CatalogApp] {
   try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fixtures.appendingPathComponent(name))).apps
  }
  func render(_ view: NSView, _ name: String) throws {
   let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.titled], backing: .buffered, defer: true)
   window.appearance = NSAppearance(named: .aqua)
   window.contentView = view
   view.layoutSubtreeIfNeeded()
   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
   view.cacheDisplay(in: view.bounds, to: rep)
   try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
  }
  let ipod = try apps("ipod2-3.1.3-dash.json"), ipad = try apps("ipad1-3.2-dash.json")
  let suite = "ltm-store-ui-check-\(ProcessInfo.processInfo.processIdentifier)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }

  // iPod: the family choice dimmed (never hidden); the default shows unavailable apps greyed, the toggle hides them.
  let podButton = CatalogFilterButton(isIPad: false, defaults: defaults)
  let items = podButton.menu!.items
  check(items[1...4].allSatisfy { !$0.isHidden } && !items[1].isEnabled && !items[2].isEnabled && items[4].isEnabled
        && items[4].title == "Show Unavailable Apps", "iPod: family choice dimmed, the toggle live")
  check(items[4].state == .on && podButton.apply(ipod).count == 4, "default: every app, unavailable ones greyed")
  var changes = 0
  podButton.onChange = { changes += 1 }
  podButton.menu!.performActionForItem(at: 4)
  check(changes == 1 && items[4].state == .off && podButton.apply(ipod).count == 2, "toggle reports, checks off and filters")

  // iPad: the family choice, read back with the toggle the iPod saved.
  let padButton = CatalogFilterButton(isIPad: true, defaults: defaults)
  let padItems = padButton.menu!.items
  check(!padButton.filter.showUnavailable, "Show Unavailable persisted")
  check(padItems[1].isEnabled && padItems[2].isEnabled && padItems[1].state == .on, "iPad offers both families, all apps by default")
  try render(strip(padButton), "filter-ipad-all.png")
  padButton.menu!.performActionForItem(at: 2)
  check(padItems[2].state == .on && padItems[1].state == .off && padButton.filter.iPadOnly, "iPad Apps Only checked")
  padButton.menu!.performActionForItem(at: 4)
  check(padButton.apply(ipad).count == 3, "iPad Apps Only with unavailable apps shown")
  try render(strip(padButton), "filter-ipad-ipad-only.png")
  let reread = CatalogFilterButton(isIPad: true, defaults: defaults)
  check(reread.filter.iPadOnly && reread.filter.showUnavailable && reread.menu!.items[2].state == .on, "a new button reads both choices back")
  try render(strip(CatalogFilterButton(isIPad: false, defaults: defaults)), "filter-ipod.png")

  // The version sheet fits its content, for a compatible copy and an incompatible one.
  let hotel = ipod.first { $0.name == "Hotel Dash" }!
  let good = CatalogDetailsModel(app: hotel, device: "iPod2,1", deviceOS: "3.1.3", arch: "armv6", installedVersion: "1.10.3",
                                 canInstall: { true }, install: { _ in })
  await good.load(); await good.check()
  check(good.canInstallSelection && good.downgradeNote != nil, "the compatible sheet has its copy and note")
  let goodView = NSHostingView(rootView: CatalogDetailsView(model: good))
  check(goodView.fittingSize.height < 360, "sheet fits its content: \(goodView.fittingSize)")
  try render(goodView, "sheet-compatible.png")
  let dash = try apps("search-86286-ipad1-4.2.1.json")[0]
  let bad = CatalogDetailsModel(app: dash, device: "iPad1,1", deviceOS: "4.2.1", arch: "armv7", installedVersion: nil,
                                canInstall: { true }, install: { _ in })
  await bad.load(); await bad.check()
  check(bad.problem != nil, "the incompatible sheet shows its reason")
  let badView = NSHostingView(rootView: CatalogDetailsView(model: bad))
  check(badView.fittingSize.height < 360, "sheet fits its content: \(badView.fittingSize)")
  try render(badView, "sheet-incompatible.png")
  print("PASS: Store filter pull-down (iPod toggle only, iPad family choice, read back) and the version sheet's fit")
 }

 /// The pane's top row as the inspector lays it out: Installed/Store, then the filter.
 @MainActor static func strip(_ button: NSPopUpButton) -> NSView {
  let pane = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
  let mode = NSSegmentedControl(labels: ["Installed", "Store"], trackingMode: .selectOne, target: nil, action: nil)
  mode.selectedSegment = 1
  mode.segmentDistribution = .fillEqually
  mode.controlSize = .large
  for view in [mode, button] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; pane.addSubview(view) }
  NSLayoutConstraint.activate([
   mode.topAnchor.constraint(equalTo: pane.topAnchor, constant: 6),
   mode.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
   button.leadingAnchor.constraint(equalTo: mode.trailingAnchor, constant: 4),
   button.centerYAnchor.constraint(equalTo: mode.centerYAnchor),
   button.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -6),
   pane.widthAnchor.constraint(equalToConstant: 300), pane.heightAnchor.constraint(equalToConstant: 40),
  ])
  return pane
 }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-store-ui-') as directory:
    work = Path(directory)
    out = Path(args.out) if args.out else work / 'out'
    out.mkdir(parents=True, exist_ok=True)
    (work / 'home').mkdir()
    (work / 'check.swift').write_text(code)
    (work / 'paths.swift').write_text('extension DeviceInstance { var paths: Paths { paths(state: Bundled.stateDirectory, logs: Bundled.logsDirectory) } }\n')
    sources = ['Features/CatalogClient', 'Features/CatalogCopy', 'Features/CatalogFilter', 'Catalog/CatalogDetailsModel', 'UI/CatalogFilterButton',
               'UI/CatalogDetailsViewController', 'Library/Bundled', 'Transport/AppEventLog', 'Library/StorageLocations',
               'Transport/NativeLogging', 'Library/IPALibrary', 'Library/DeviceInstance', 'Device/Board+App', 'Library/FirmwareCatalog']
    subprocess.run(['xcrun', 'swiftc', *__import__('host_runtime').schema_flags(__import__('pathlib').Path(__file__).resolve().parents[2]), *host_runtime.swift_flags(root), '-parse-as-library', '-module-cache-path', str(work / 'modules'), *[str(root / f'LightTouchMac/{s}.swift') for s in sources], str(work / 'paths.swift'), str(work / 'check.swift'),
                    '-o', str(work / 'check')], check=True)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, CFFIXED_USER_HOME=str(work / 'home'), LTM_STATE_DIR=str(work / 'state'))
    try:
        subprocess.run([str(work / 'check'), str(server.server_port), str(fixtures), str(out)], check=True, timeout=60, env=env)
    finally:
        server.shutdown()
