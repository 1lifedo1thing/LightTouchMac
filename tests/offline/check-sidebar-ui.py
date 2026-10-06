#!/usr/bin/env python3
"""The sidebar (DeviceLibraryViewController) and the Add Device sheet (AddDeviceView), rendered offscreen.

Compiles the real view controller and sheet with the real catalog, SidebarList and DeviceRow, and stubs for the
app singletons they ask (DeviceSessionHost, FirmwareJobs, the sessions). Everything lays out in windows that are
never ordered front: nothing appears on screen. PNGs land in --out (default a temp dir):
sidebar-{one-kind,mixed,renamed,empty,multi-select}.png, batch-delete-alert.png and add-device.png.

Checks what the user sees, from the rendered cells: every row is two lines, the model identifier ("iPod2,1") over
the version with its Beta/GM badge ("iOS 4.1 Beta 1"), whatever else is listed; a custom name shows over
"iPad1,1, iOS 3.2.2" / "iPod2,1, iOS 4.2.1". A download's row shows its ring and no percentage. Renaming in place (the context
menu's Rename, typing, ending the edit) saves the name to defaults; Delete on a row with nothing on disk removes
it (saved), on a prepared one it asks the delegate to delete instead; an empty sidebar shows Add Device…. A
download starting for an entry not in the list adds it. The sheet lists every catalog entry once.

Device artwork: every catalog board's profile resolves to a type macOS declares (com.apple.device-model-code), the
iPod 1G's and 2G's differ, each mixed row and sheet header shows that artwork (not the SF Symbol fallback, and a
different picture per board), and an unknown model code gets the fallback symbol.

Several rows: ⌘A selects every row and no single entry; Delete over a mixed selection (two with nothing on disk, one
prepared, one running) asks ONE question naming the prepared device and the skipped one; Cancel changes nothing,
Delete removes the unprepared ones at once; the prepared one says Deleting (no Start, no second Delete) while its
storage goes, with a main-actor heartbeat ticking throughout a slow fake removal (the real DeviceDeletions), then
leaves; the running one stays. A failed deletion keeps its row and shows one alert. Nothing prepared: no question.
All running or busy: Edit ▸ Delete is dimmed. Renders sidebar-progress.png and sidebar-deleting.png too.
The Add Device sheet says nothing for a supported build (no "Supported"), and Experimental/Untested where they apply.
"""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
from firmwarekit_leaf import schema_sources
import argparse, subprocess, tempfile

app = Path(__file__).resolve().parents[2] / 'LightTouchMac'
ap = argparse.ArgumentParser()
ap.add_argument('--out')
args = ap.parse_args()

stubs = r'''
import Cocoa
final class FirmwareJobs {
    static let shared = FirmwareJobs()
    static let didChangeNotification = Notification.Name("FirmwareJobsDidChange")
    var jobs: [String: FirmwareJob] = [:] { didSet { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) } }
}
struct StubInstance { let firmware: String }
final class DeviceLibrary {
    static let didChangeNotification = Notification.Name("DeviceLibraryDidChange")
    var instances: [StubInstance] = []
}
extension FirmwareCatalog.Entry.Status { static let allCasesForCheck: [Self] = [.available, .experimental, .untested, .comingSoon, .userIPSW] }
final class EmulatorController { var canQueueInstall = false }
final class DeviceSession {
    static let didChangeNotification = Notification.Name("DeviceSessionDidChange")
    let emulator = EmulatorController()
}
nonisolated enum PreparedMedia { static let extensions: Set<String> = [] }
enum AppInstaller { static func start(_ url: URL, with emulator: EmulatorController, presenting: NSWindow?) {} }
final class DeviceSessionHost {
    static let didChangeNotification = Notification.Name("DeviceSessionHostDidChange")
    let catalog: FirmwareCatalog
    let library = DeviceLibrary()
    var prepared: [String: UUID] = [:]
    var downloaded: Set<String> = []
    var running: Set<String> = []
    var deleted: [String] = []
    let deletions = DeviceDeletions()
    /// The fake removal: this long on its thread, then a throw when `failing`.
    var deleteSeconds = 0.0
    var failing = false
    struct Failed: LocalizedError { var errorDescription: String? { "The device’s folder couldn’t be removed." } }
    func delete(_ instance: StubInstance) -> Task<Void, Error> {
        let seconds = deleteSeconds, failing = failing, id = instance.firmware
        let removal = deletions.run(id) { Thread.sleep(forTimeInterval: seconds); if failing { throw Failed() } }
        return Task { try await removal.value; deleted.append(id); prepared[id] = nil }
    }
    init(catalog: FirmwareCatalog) {
        self.catalog = catalog
        deletions.onChange = { NotificationCenter.default.post(name: Self.didChangeNotification, object: nil) }
    }
    func instance(for entry: FirmwareCatalog.Entry) -> StubInstance? { prepared[entry.id].map { _ in StubInstance(firmware: entry.id) } }
    func session(for entry: FirmwareCatalog.Entry) -> DeviceSession? { nil }
    func row(for entry: FirmwareCatalog.Entry) -> DeviceRow {
        DeviceRow(entry: entry, instanceID: prepared[entry.id], session: running.contains(entry.id) ? .running : nil, job: FirmwareJobs.shared.jobs[entry.id],
                  downloaded: downloaded.contains(entry.id), deleting: deletions.contains(entry.id))
    }
}
'''

check = r'''
import Cocoa
import SwiftUI

final class Delegate: DeviceLibraryDelegate {
    var deletes: [String] = []
    var selected: [FirmwareCatalog.Entry?] = []
    func library(_ library: DeviceLibraryViewController, didSelect entry: FirmwareCatalog.Entry?) { selected.append(entry) }
    func libraryRowsDidChange(_ library: DeviceLibraryViewController) {}
    func library(_ library: DeviceLibraryViewController, canPerform action: DeviceAction, for entry: FirmwareCatalog.Entry) -> Bool { true }
    func library(_ library: DeviceLibraryViewController, perform action: DeviceAction, for entry: FirmwareCatalog.Entry) {
        if action == .delete { deletes.append(entry.id) }
    }
    func library(_ library: DeviceLibraryViewController, importIPSW url: URL, for entry: FirmwareCatalog.Entry?) {}
}

@main struct Check {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        let catalog = try FirmwareCatalog.load(from: URL(fileURLWithPath: args[1]))
        let out = URL(fileURLWithPath: args[2])
        let suite = "ltm-check-sidebar-ui-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var failures: [String] = []
        func fail(_ s: String) { failures.append(s) }

        func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
        func visible(_ v: NSView) -> Bool { var p: NSView? = v; while let q = p { if q.isHidden { return false }; p = q.superview }; return true }
        func render(_ view: NSView, _ name: String) throws {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name + ".png"))
        }
        func window(_ size: NSSize) -> NSWindow {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .aqua)
            return w
        }
        /// Each visible row's texts, top to bottom then leading to trailing: [title, subtitle] and any accessory text.
        func rows(_ vc: DeviceLibraryViewController) -> [[String]] {
            let outline = all(vc.view).compactMap { $0 as? NSOutlineView }.first!
            return (0..<outline.numberOfRows).map { r in
                let cell = outline.view(atColumn: 0, row: r, makeIfNecessary: true)!
                func top(_ f: NSTextField) -> CGFloat {
                    let rect = f.convert(f.bounds, to: cell)
                    return cell.isFlipped ? rect.minY : -rect.maxY
                }
                func before(_ a: NSTextField, _ b: NSTextField) -> Bool {
                    abs(top(a) - top(b)) > 4 ? top(a) < top(b) : a.convert(a.bounds, to: cell).minX < b.convert(b.bounds, to: cell).minX
                }
                let fields: [NSTextField] = all(cell).compactMap { $0 as? NSTextField }.filter { visible($0) && !$0.stringValue.isEmpty }
                return fields.sorted(by: before).map(\.stringValue)
            }
        }
        func sidebar(_ ids: [String], names: [String: String] = [:], host: DeviceSessionHost) -> (DeviceLibraryViewController, NSWindow) {
            SidebarList(ids: ids, names: names).save(defaults)
            let vc = DeviceLibraryViewController(host: host, defaults: defaults)
            let w = window(NSSize(width: 240, height: 260))
            w.contentView = vc.view
            vc.view.layoutSubtreeIfNeeded()
            return (vc, w)
        }

        // One kind of device: still the identifier over the version, the beta's badge in the version line.
        let host = DeviceSessionHost(catalog: catalog)
        host.prepared["n72ap-8C148"] = UUID()
        host.downloaded = ["n72ap-8B117"]
        var (vc, w) = sidebar(["n72ap-8C148", "n72ap-8B5080c", "n72ap-8B117", "n72ap-7E18"], host: host)
        var seen = rows(vc)
        if seen.map({ Array($0.prefix(1)) + $0.filter { $0.hasPrefix("iOS") } }) != [["iPod2,1", "iOS 3.1.3"], ["iPod2,1", "iOS 4.1 Beta 1"], ["iPod2,1", "iOS 4.1"], ["iPod2,1", "iOS 4.2.1"]]
            || seen.contains(where: { $0.count != 2 }) { fail("one kind (3.1.3 built in: nothing beside it): \(seen)") }
        try render(vc.view, "sidebar-one-kind")

        // Mixed: the same two lines.
        (vc, w) = sidebar(["n72ap-8C148", "k48ap-7B500", "n72ap-8B5080c", "n45ap-4B1"], host: host)
        seen = rows(vc)
        if seen != [["iPad1,1", "iOS 3.2.2"], ["iPod1,1", "iOS 1.1.5"], ["iPod2,1", "iOS 4.1 Beta 1"], ["iPod2,1", "iOS 4.2.1"]] { fail("mixed: \(seen)") }

        // Artwork: macOS's declared type per board, the two iPods apart, the fallback for a model macOS doesn't know.
        var types: [String: String] = [:]
        for board in Set(catalog.entries.map(\.board)).sorted() {
            guard let profile = catalog.entries.first(where: { $0.board == board })?.profile else { fail("\(board): no profile"); continue }
            guard let type = profile.deviceType, type.contentType.isDeclared else { fail("\(board) (\(profile.productType)): no declared type"); continue }
            types[board] = type.identifier
            if profile.icon.isTemplate { fail("\(board)'s icon is the SF Symbol fallback") }
        }
        print("types: \(types)")
        if types["n45ap"] == nil || types["n45ap"] == types["n72ap"] { fail("the iPod 1G and 2G share a type: \(types)") }
        if Set(types.values).count != types.count { fail("boards share a type: \(types)") }
        if !DeviceProfile.icon(modelCode: "Bogus9,9", fallbackSymbol: "ipodtouch").isTemplate { fail("an unknown model code didn't fall back to the symbol") }
        /// The image as 24×24 pixels, to tell pictures apart.
        func pixels(_ image: NSImage?) -> Data? {
            guard let image, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24, bitsPerSample: 8,
                                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 24, height: 24))
            NSGraphicsContext.restoreGraphicsState()
            return rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerRow * 24) }
        }
        let mixedOutline = all(vc.view).compactMap { $0 as? NSOutlineView }.first!
        let rowIcons = (0..<mixedOutline.numberOfRows).map { (mixedOutline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.imageView }
        if rowIcons.contains(where: { $0?.image == nil || $0!.isHidden || $0!.image!.isTemplate }) { fail("a mixed row shows no device artwork") }
        let iconPixels = rowIcons.map { pixels($0?.image) }
        // iPad, 1G, 2G, 2G: three pictures, the 2G's twice.
        if Set(iconPixels.prefix(3)).count != 3 || iconPixels[2] != iconPixels[3] { fail("the rows' artwork doesn't follow the board") }
        if let icon = rowIcons[0], icon.frame.height < 24 || icon.frame.height > 34 { fail("a two-line row's icon is \(icon.frame.size)") }
        try render(vc.view, "sidebar-mixed")

        // Rename in place through the context menu's Rename: the title turns into a field; ending the edit saves.
        vc.select(catalog.entry(id: "k48ap-7B500")!)
        vc.perform(NSSelectorFromString("renameFromMenu:"), with: nil)
        guard let editor = w.firstResponder as? NSTextView, let field = editor.delegate as? NSTextField, field.isEditable else {
            fail("Rename didn't start an edit: \(String(describing: w.firstResponder))"); precondition(failures.isEmpty, failures.joined(separator: "\n")); return
        }
        if field.stringValue != "iPad1,1" { fail("the edit starts from \(field.stringValue)") }
        editor.string = "Lab iPad"
        w.makeFirstResponder(nil)
        if (defaults.dictionary(forKey: SidebarList.namesKey) as? [String: String]) != ["k48ap-7B500": "Lab iPad"] {
            fail("rename not saved: \(String(describing: defaults.dictionary(forKey: SidebarList.namesKey)))")
        }
        seen = rows(vc)
        if seen.first != ["Lab iPad", "iPad1,1, iOS 3.2.2"] { fail("renamed: \(seen)") }
        if field.isEditable { fail("the title stays editable after renaming") }
        // And an iPod: its subtitle names the model by its identifier.
        vc.select(catalog.entry(id: "n72ap-8C148")!)
        vc.perform(NSSelectorFromString("renameFromMenu:"), with: nil)
        if let editor = w.firstResponder as? NSTextView {
            editor.string = "Test iPod"
            w.makeFirstResponder(nil)
        } else { fail("Rename didn't start an edit on the iPod row") }
        seen = rows(vc)
        if seen.last != ["Test iPod", "iPod2,1, iOS 4.2.1"] { fail("renamed iPod: \(seen)") }
        // Offscreen, a selected source-list row draws its material black: render unselected.
        all(vc.view).compactMap { $0 as? NSOutlineView }.first!.deselectAll(nil)
        try render(vc.view, "sidebar-renamed")

        // Delete: a prepared row asks through the delegate's delete and stays until it's done; the others go at once.
        let delegate = Delegate()
        vc.delegate = delegate
        let outline = all(vc.view).compactMap { $0 as? NSOutlineView }.first!
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                      context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        vc.select(catalog.entry(id: "n72ap-8C148")!)
        outline.keyDown(with: delete)
        if delegate.deletes != ["n72ap-8C148"] || !vc.entries.contains(where: { $0.id == "n72ap-8C148" }) { fail("prepared delete: \(delegate.deletes)") }
        vc.select(catalog.entry(id: "n72ap-8B5080c")!)
        outline.keyDown(with: delete)
        if vc.entries.contains(where: { $0.id == "n72ap-8B5080c" }) || defaults.stringArray(forKey: SidebarList.entriesKey)?.contains("n72ap-8B5080c") != false {
            fail("Delete didn't remove an unprepared row")
        }
        // A download started elsewhere (an IPSW dropped on the empty area) brings its entry in; its row shows the
        // ring, no percentage.
        FirmwareJobs.shared.jobs["n72ap-8B117"] = .downloading(fraction: 0.25)
        if !vc.entries.contains(where: { $0.id == "n72ap-8B117" }) { fail("a job's entry didn't join the sidebar") }
        if let index = vc.entries.firstIndex(where: { $0.id == "n72ap-8B117" }) {
            let texts = rows(vc)[index]
            let cell = outline.view(atColumn: 0, row: index, makeIfNecessary: true)!
            let ring = all(cell).compactMap { $0 as? NSProgressIndicator }.first
            if texts != ["iPod2,1", "iOS 4.1"] { fail("a download's row reads \(texts)") }
            if ring.map({ !visible($0) || $0.isIndeterminate || $0.doubleValue != 0.25 }) ?? true { fail("a download's row has no 25% ring") }
            outline.deselectAll(nil)
            try render(vc.view, "sidebar-progress")
        }
        // A failed download leaves with Delete and stays gone.
        FirmwareJobs.shared.jobs["n72ap-8B117"] = .failed("x")
        vc.select(catalog.entry(id: "n72ap-8B117")!)
        outline.keyDown(with: delete)
        FirmwareJobs.shared.jobs["n72ap-8C148"] = nil   // the next state change
        if vc.entries.contains(where: { $0.id == "n72ap-8B117" }) { fail("a failed download's row came back") }
        FirmwareJobs.shared.jobs = [:]

        // Several rows: ⌘A, then one Delete for the lot.
        let multi = DeviceSessionHost(catalog: catalog)
        multi.deleteSeconds = 0.8
        multi.prepared = ["n72ap-8C148": UUID(), "k48ap-7B500": UUID()]
        multi.running = ["k48ap-7B500"]
        multi.downloaded = ["n72ap-8B117"]
        (vc, w) = sidebar(["n72ap-8C148", "k48ap-7B500", "n72ap-8B117", "n45ap-4B1"], host: multi)
        let multiDelegate = Delegate()
        vc.delegate = multiDelegate
        var alerts: [NSAlert] = []
        var answer = NSApplication.ModalResponse.alertSecondButtonReturn
        vc.presentAlert = { alert, _, done in alerts.append(alert); done(answer) }
        let multiOutline = all(vc.view).compactMap { $0 as? NSOutlineView }.first!
        w.makeFirstResponder(multiOutline)
        multiOutline.selectAll(nil)
        if vc.selectedEntries.count != 4 || vc.selectedEntry != nil { fail("⌘A: \(vc.selectedEntries.map(\.id)), single \(String(describing: vc.selectedEntry?.id))") }
        if multiDelegate.selected.last != .some(nil) { fail("several rows selected still name one entry to the window") }
        if !vc.canRemoveTargets { fail("Delete dimmed over a removable selection") }
        // Offscreen, the selection's material draws black (as in sidebar-renamed's note): the rows' artwork shows on it.
        try render(vc.view, "sidebar-multi-select")
        multiOutline.keyDown(with: delete)   // Cancel
        if alerts.count != 1 { fail("a mixed batch asked \(alerts.count) questions") }
        if let alert = alerts.first {
            if alert.messageText != "Delete 3 devices?" { fail("batch question: \(alert.messageText)") }
            if !alert.informativeText.contains("iPod touch iOS 4.2.1") || !alert.informativeText.contains("iPad iOS 3.2.2") {
                fail("the question doesn't name the prepared and the skipped device: \(alert.informativeText)")
            }
            alert.layout()
            try render(alert.window.contentView!, "batch-delete-alert")
        }
        if vc.entries.count != 4 || !multi.deleted.isEmpty || !multiDelegate.deletes.isEmpty { fail("Cancel changed the sidebar: \(vc.entries.map(\.id)) \(multi.deleted)") }
        answer = .alertFirstButtonReturn
        multiOutline.selectAll(nil)
        multiOutline.keyDown(with: delete)
        if alerts.count != 2 { fail("the second Delete asked \(alerts.count - 1) questions") }
        // The unprepared rows left at once; the prepared one is Deleting until its storage is gone.
        let doomed = catalog.entry(id: "n72ap-8C148")!
        if vc.entries.map(\.id) != ["k48ap-7B500", "n72ap-8C148"] { fail("while deleting: \(vc.entries.map(\.id))") }
        if vc.row(for: doomed).state != .deleting || vc.row(for: doomed).allows(.start, canDownload: true) || vc.row(for: doomed).canRemoveFromSidebar {
            fail("a deleting row: \(vc.row(for: doomed).state), startable \(vc.row(for: doomed).allows(.start, canDownload: true))")
        }
        let doomedCell = multiOutline.view(atColumn: 0, row: 1, makeIfNecessary: true)!
        if !(doomedCell.accessibilityLabel() ?? "").contains("Deleting") { fail("a deleting row doesn't say so: \(doomedCell.accessibilityLabel() ?? "nil")") }
        if !all(doomedCell).contains(where: { ($0 as? NSProgressIndicator).map { visible($0) && $0.isIndeterminate } ?? false }) { fail("a deleting row has no spinner") }
        multiOutline.deselectAll(nil)
        try render(vc.view, "sidebar-deleting")
        // The main actor stays free while the fake removal sleeps on its thread: a heartbeat every 20 ms.
        var beats = 0
        let heart = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in MainActor.assumeIsolated { beats += 1 } }
        let began = Date()
        while vc.entries.count > 1, Date().timeIntervalSince(began) < 10 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        heart.invalidate()
        let took = Date().timeIntervalSince(began)
        print("delete: \(String(format: "%.2f", took)) s, \(beats) heartbeats")
        if took < 0.5 { fail("the fake removal took \(took) s: the heartbeat proves nothing") }
        if Double(beats) < took / 0.02 * 0.5 { fail("the main actor stalled during deletion: \(beats) heartbeats in \(took) s") }
        if multi.deleted != ["n72ap-8C148"] || !multiDelegate.deletes.isEmpty { fail("batch deleted \(multi.deleted), per-row deletes \(multiDelegate.deletes)") }
        if vc.entries.map(\.id) != ["k48ap-7B500"] || defaults.stringArray(forKey: SidebarList.entriesKey) != ["k48ap-7B500"] {
            fail("after the batch: \(vc.entries.map(\.id))")
        }
        if multi.deletions.contains("n72ap-8C148") { fail("still marked deleting") }
        if alerts.count != 2 { fail("a successful deletion showed an alert") }

        // A deletion that fails: the row stays, back to ready, and one alert says why.
        let broken = DeviceSessionHost(catalog: catalog)
        broken.prepared = ["n72ap-8C148": UUID(), "n72ap-8B117": UUID()]
        broken.failing = true
        (vc, w) = sidebar(["n72ap-8C148", "n72ap-8B117"], host: broken)
        vc.delegate = multiDelegate
        var failureAlerts: [NSAlert] = []
        vc.presentAlert = { alert, _, done in failureAlerts.append(alert); done(.alertFirstButtonReturn) }
        let brokenOutline = all(vc.view).compactMap { $0 as? NSOutlineView }.first!
        brokenOutline.selectAll(nil)
        brokenOutline.keyDown(with: delete)
        let failStart = Date()
        while !broken.deletions.ids.isEmpty || failureAlerts.count < 2, Date().timeIntervalSince(failStart) < 5 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        if vc.entries.count != 2 || vc.entries.contains(where: { vc.row(for: $0).state != .ready }) { fail("failed deletion: \(vc.entries.map { "\($0.id) \(vc.row(for: $0).state)" })") }
        if failureAlerts.count != 2 || !failureAlerts[1].messageText.contains("couldn’t be removed") {
            fail("failed deletion alerts: \(failureAlerts.map(\.messageText))")
        }
        // Nothing prepared: no question. All running or busy: Delete dims.
        (vc, w) = sidebar(["k48ap-7B500", "n72ap-8B117", "n45ap-4B1"], host: multi)
        vc.delegate = multiDelegate
        vc.presentAlert = { alert, _, done in alerts.append(alert); done(answer) }
        let plainOutline = all(vc.view).compactMap { $0 as? NSOutlineView }.first!
        plainOutline.selectRowIndexes([1, 2], byExtendingSelection: false)
        plainOutline.keyDown(with: delete)
        if alerts.count != 2 || vc.entries.map(\.id) != ["k48ap-7B500"] { fail("unprepared batch: \(alerts.count) questions, left \(vc.entries.map(\.id))") }
        FirmwareJobs.shared.jobs["n72ap-8B117"] = .downloading(fraction: 0.5)
        plainOutline.selectAll(nil)
        let editDelete = NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        if vc.selectedEntries.count != 2 || vc.validateMenuItem(editDelete) { fail("Edit ▸ Delete enabled over running and downloading rows") }
        FirmwareJobs.shared.jobs = [:]

        // Empty: the sidebar's own Add Device….
        (vc, w) = sidebar([], host: DeviceSessionHost(catalog: catalog))
        let add = all(vc.view).compactMap { $0 as? NSButton }.filter { visible($0) && $0.title == "Add Device…" }
        if add.count != 1 { fail("empty sidebar: no Add Device…") }
        var added = false
        vc.onAdd = { added = true }
        add.first?.performClick(nil)
        if !added { fail("empty sidebar's Add Device… does nothing") }
        try render(vc.view, "sidebar-empty")

        // The sheet: every entry once, grouped by device.
        let sheet = AddDeviceView(catalog: catalog, added: ["k48ap-7B500", "n72ap-8C148"], downloaded: ["n72ap-8B117", "k48ap-7B500", "n72ap-8C148"],
                                  selection: ["n72ap-8B117"], onAdd: { _ in }, onCancel: {})
        if sheet.groups.flatMap(\.entries).map(\.id) != catalog.entries.map(\.id) { fail("the sheet's entries aren't the catalog's, in its order") }
        if sheet.groups.map(\.name) != ["iPad", "iPod touch", "iPod touch (2nd generation)", "iPod touch (3rd generation)", "iPod touch (4th generation)", "iPhone", "iPhone 3GS", "iPhone 4"] { fail("sheet groups: \(sheet.groups.map(\.name))") }
        // macOS draws the iPod touch 3G (iPod3,1) with the 2G's picture, the same chassis: those two may match.
        let art = Dictionary(uniqueKeysWithValues: sheet.groups.map { ($0.id, pixels($0.icon)) })
        if sheet.groups.contains(where: \.icon.isTemplate) || Set(art.filter { $0.key != "n18ap" }.values).count != sheet.groups.count - 1
            || art["n18ap"] != art["n72ap"] { fail("the sheet's headers don't show each device's artwork") }
        try renderSheet(sheet, "add-device")
        // A supported build says nothing; the others keep their tag.
        let tags = FirmwareCatalog.Entry.Status.allCasesForCheck.map { AddDeviceRow.statusText($0) }
        if tags != [nil, "Experimental", "Untested", "Coming Soon", "Requires an IPSW"] { fail("the sheet's tags: \(tags)") }
        func renderSheet(_ view: AddDeviceView, _ name: String) throws {
            let hosting = NSHostingView(rootView: view)
            let sw = window(NSSize(width: 440, height: 480))
            sw.contentView = hosting
            try render(hosting, name)
        }

        precondition(failures.isEmpty, failures.joined(separator: "\n"))
        print("PASS: two-line sidebar titles (identifier/version, renamed), ring without percentage, device artwork, rename saves, Delete removes or asks, batch Delete off the main actor (Deleting, heartbeat, failure), empty Add Device…, the Add Device sheet")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-sidebar-ui-') as tmp:
    tmp = Path(tmp)
    out = Path(args.out) if args.out else tmp / 'out'
    out.mkdir(parents=True, exist_ok=True)
    (tmp / 'stubs.swift').write_text(stubs)
    (tmp / 'main.swift').write_text(check)
    subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(Path(__file__).resolve().parents[2]), *schema_sources(), '-parse-as-library', '-swift-version', '5', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(tmp / 'modules'),
                    str(app / 'Library/FirmwareCatalog.swift'), str(app / 'Device/DeviceProfile.swift'),
                    str(app / 'Device/DeviceRow.swift'), str(app / 'Library/SidebarList.swift'),
                    str(app / 'UI/DroppedFiles.swift'), str(app / 'Device/DeviceDeletions.swift'), str(app / 'UI/DeviceLibraryViewController.swift'),
                    str(app / 'UI/AddDeviceView.swift'), str(app / 'UI/AppleDeviceType.swift'), str(app / 'UI/DeviceProfile+Icon.swift'), str(tmp / 'stubs.swift'), str(tmp / 'main.swift'),
                    '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), str(app / 'Resources/firmware-catalog.json'), str(out)], check=True, timeout=60)
