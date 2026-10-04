#!/usr/bin/env python3
"""Native row identity survives unchanged polls and another app's progress; a device status change re-evaluates
the rows (a Store row's Install button enables when its device becomes ready, without a manual refresh)."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
source = (root / 'LightTouchMac/UI/AppsInspectorViewController.swift').read_text()
a = source.index('    private struct RowAppearance:')
b = source.index('    /// Capture only values', a)
appearance = source[a:b]
a = source.index('    private func reloadTablePreservingSelection()')
b = source.index('\n    @objc private func appsChanged(', a)
reload = source[a:b]
a = source.index('    override func viewDidLoad() {')
b = source.index('\n    // MARK: - Loading / refresh', a)
did_load = source[a:b]
a = source.index('    @objc private func deviceStatusChanged(')
b = source.index('\n    @objc private func installStarted(', a)
status_changed = source[a:b]
code = r'''import Cocoa
@MainActor final class Fixture: NSObject, NSTableViewDataSource, NSTableViewDelegate {
 let tableView = NSTableView()
 var rowIdentities = ["one", "two", "three"]
 var displayedRows: [String] = []
''' + appearance + r'''
 private var rowAppearances = [
  RowAppearance(title: "One", subtitle: "Ready"),
  RowAppearance(title: "Two", subtitle: "Ready"),
  RowAppearance(title: "Three", subtitle: "Ready")
 ]
''' + reload + r'''
 func numberOfRows(in tableView: NSTableView) -> Int { rowIdentities.count }
 func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
  NSButton(title: rowAppearances[row].title, target: nil, action: nil)
 }
 static func run() {
  let fixture = Fixture()
  let table = fixture.tableView
  table.dataSource = fixture; table.delegate = fixture; table.rowHeight = 30
  table.addTableColumn(NSTableColumn(identifier: .init("app")))
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                        styleMask: [.titled], backing: .buffered, defer: false)
  let scroll = NSScrollView(); scroll.documentView = table
  window.contentView = scroll
  fixture.reloadTablePreservingSelection()
  scroll.layoutSubtreeIfNeeded()
  let first = table.view(atColumn: 0, row: 0, makeIfNecessary: true)!
  let second = table.view(atColumn: 0, row: 1, makeIfNecessary: true)!
  table.selectRowIndexes([1], byExtendingSelection: false)
  // Several polls with identical data must preserve live control objects.
  for _ in 0..<5 { fixture.reloadTablePreservingSelection() }
  precondition(table.view(atColumn: 0, row: 0, makeIfNecessary: true) === first)
  precondition(table.view(atColumn: 0, row: 1, makeIfNecessary: true) === second)
  fixture.rowAppearances[0].subtitle = "Downloading… 50%"
  fixture.reloadTablePreservingSelection()
  precondition(table.view(atColumn: 0, row: 0, makeIfNecessary: true) !== first)
  precondition(table.view(atColumn: 0, row: 1, makeIfNecessary: true) === second,
               "Another app's progress must preserve this row's button/AX element")
  precondition(table.selectedRowIndexes == [1])
  let last = fixture.rowAppearances.removeLast()
  fixture.rowAppearances.insert(last, at: 0)
  fixture.rowIdentities = ["three", "one", "two"]
  fixture.reloadTablePreservingSelection()
  precondition(table.selectedRowIndexes == [2], "Selection follows the app across a reorder")
  print("PASS: native row controls persist through unchanged polls and unrelated progress; reordered selection stays with app")
 }
}
extension Notification.Name { static let ltmAppsChanged = Self("a"), ltmInstallStarted = Self("b"), ltmInstallProgress = Self("c") }
@MainActor final class EmulatorController { var canQueueInstall = false }
@MainActor final class DeviceSession {
 static let didChangeNotification = Notification.Name("DeviceSessionDidChange")
 let emulator: EmulatorController
 init(_ emulator: EmulatorController) { self.emulator = emulator }
}
/// The inspector's observer wiring (viewDidLoad) and handler, over one Store row whose Install
/// button is enabled by the device's canQueueInstall, as production rowAppearances does.
@MainActor final class Inspector: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
 let emulator = EmulatorController()
 let tableView = NSTableView()
 var rowIdentities = ["hotel-dash"]
 var displayedRows: [String] = []
''' + appearance + r'''
 private var rowAppearances: [RowAppearance] {
  [RowAppearance(title: "Hotel Dash", subtitle: "PlayFirst", kind: .install, enabled: emulator.canQueueInstall)]
 }
''' + reload + did_load + status_changed + r'''
 var buttonsUpdated = 0
 func updateButtons() { buttonsUpdated += 1 }
 @objc func appsChanged(_ note: Notification) {}
 @objc func installStarted(_ note: Notification) {}
 @objc func installProgressed(_ note: Notification) {}
 @objc func refreshIconDimming() {}
 func startInitialLoad() {}
 func scheduleSearch() {}
 override func loadView() { view = NSView() }
 func numberOfRows(in tableView: NSTableView) -> Int { rowIdentities.count }
 func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
  let button = NSButton(title: "Install", target: nil, action: nil)
  button.isEnabled = rowAppearances[row].enabled
  return button
 }
 static func run() {
  let inspector = Inspector()
  inspector.loadViewIfNeeded()
  let table = inspector.tableView
  table.dataSource = inspector; table.delegate = inspector; table.rowHeight = 30
  table.addTableColumn(NSTableColumn(identifier: .init("app")))
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
  let scroll = NSScrollView(); scroll.documentView = table
  window.contentView = scroll
  // The Store's results land while the device is still booting: Install disabled.
  inspector.reloadTablePreservingSelection()
  scroll.layoutSubtreeIfNeeded()
  func install() -> NSButton { table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSButton }
  precondition(!install().isEnabled)
  // Another device becoming ready changes nothing here.
  let other = EmulatorController(); other.canQueueInstall = true
  NotificationCenter.default.post(name: DeviceSession.didChangeNotification, object: DeviceSession(other))
  precondition(!install().isEnabled && inspector.buttonsUpdated == 0)
  // This device becomes ready (the readiness watch, not the inspector's own poll): the status change alone enables Install.
  inspector.emulator.canQueueInstall = true
  NotificationCenter.default.post(name: DeviceSession.didChangeNotification, object: DeviceSession(inspector.emulator))
  precondition(install().isEnabled, "Install stays disabled after the device became ready")
  precondition(inspector.buttonsUpdated == 1)
  let ready = install()
  // A status change that changes nothing a row shows keeps the row's view.
  NotificationCenter.default.post(name: DeviceSession.didChangeNotification, object: DeviceSession(inspector.emulator))
  precondition(install() === ready)
  // And back: the device stops answering, Install disables again.
  inspector.emulator.canQueueInstall = false
  NotificationCenter.default.post(name: DeviceSession.didChangeNotification, object: DeviceSession(inspector.emulator))
  precondition(!install().isEnabled)
  print("PASS: a device status change re-evaluates Store rows: Install enables when the device becomes ready, only for its own device")
 }
}
@main struct Check { @MainActor static func main() { _ = NSApplication.shared; Fixture.run(); Inspector.run() } }
'''
with tempfile.TemporaryDirectory(prefix='ltm-row-refresh-') as directory:
    work = Path(directory)
    (work / 'check.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work / 'modules'), str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=20)
