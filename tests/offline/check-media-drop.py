#!/usr/bin/env python3
"""Native file-drop acceptance on the device screen. The file kinds are UI/DroppedFiles.swift, compiled whole; the
drag handling is the device screen's (DisplayView). Revealing a dropped file's transfer in the Apps inspector is
AppsInspectorRowsTests' (AppsInspector.revealsTransfer)."""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[2]
display = (root / 'LightTouchMac/UI/DisplayView.swift').read_text()
drop = display[display.index('    override func draggingEntered('):display.index('\n}\n\n/// The shell\'s home button:')]
code = r'''import Cocoa
nonisolated let device = UUID()
struct DeviceInstance { let id = device }
@MainActor final class EmulatorController { var canQueueInstall = true; let instance = DeviceInstance() }
struct CatalogApp: Codable { let id: Int }
enum PreparedMedia { nonisolated static let extensions: Set<String> = ["png", "jpg", "mp3", "m4a", "mp4", "mov", "m4v"] }
extension NSPasteboard.PasteboardType { static let ltmCatalogApp = Self("test.catalog.app") }
@MainActor final class DropView: NSView {
 let emulator: EmulatorController? = EmulatorController()
 var onDropIPA: ((URL) -> Void)?, onDropMedia: ((URL) -> Void)?, onDropCatalogApp: ((CatalogApp) -> Void)?
 var onDropIPSW: ((URL) -> Void)?
''' + drop + r'''
}
@MainActor final class Drag: NSObject, NSDraggingInfo {
 let draggingPasteboard = NSPasteboard.withUniqueName()
 var draggingSource: Any?
 var draggingDestinationWindow: NSWindow? { nil }
 var draggingSourceOperationMask: NSDragOperation { .copy }
 var draggingLocation: NSPoint { .zero }
 var draggedImageLocation: NSPoint { .zero }
 nonisolated var draggedImage: NSImage? { nil }
 var draggingSequenceNumber: Int { 1 }
 var draggingFormation = NSDraggingFormation.default
 var animatesToDestination = false
 var numberOfValidItemsForDrop = 0
 var springLoadingHighlight = NSSpringLoadingHighlight.none
 func slideDraggedImage(to screenPoint: NSPoint) {}
 override nonisolated func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
 func resetSpringLoading() {}
 func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                             classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                             using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
 func files(_ names: [String]) {
  draggingPasteboard.clearContents()
  precondition(draggingPasteboard.writeObjects(names.map { URL(fileURLWithPath: "/tmp/" + $0) as NSURL }))
 }
}
@main struct Check {
 @MainActor static func main() throws {
  _ = NSApplication.shared
  let view = DropView(), drag = Drag()
  defer { drag.draggingPasteboard.releaseGlobally() }
  var apps: [String] = [], media: [String] = [], catalog: [Int] = [], ipsws: [String] = []
  view.onDropIPSW = { ipsws.append($0.lastPathComponent) }
  view.onDropIPA = { apps.append($0.lastPathComponent) }
  view.onDropMedia = { media.append($0.lastPathComponent) }
  view.onDropCatalogApp = { catalog.append($0.id) }
  // The drop-target ring (HIG p.294) shows only while an accepted drag is over the screen.
  func ring() -> NSView? { view.subviews.first { $0 is DropHighlight } }
  drag.files(["Notes.txt"])
  precondition(view.draggingEntered(drag).isEmpty && ring().map { $0.isHidden } != false, "a refused drag lights nothing")
  // A mixed drop: the badge counts what's taken, the rest is left out without an alert (G3).
  drag.files(["App.IPA", "Photo.PNG", "Song.mp3", "Movie.MOV", "Notes.txt"])
  precondition(view.draggingEntered(drag) == .copy && drag.numberOfValidItemsForDrop == 4)
  precondition(ring()?.isHidden == false && view.subviews.last === ring(), "an accepted drag highlights the screen")
  view.draggingExited(drag)
  precondition(ring()?.isHidden == true, "leaving clears the highlight")
  precondition(view.draggingUpdated(drag) == .copy && ring()?.isHidden == false)
  precondition(view.performDragOperation(drag))
  view.draggingEnded(drag)
  precondition(ring()?.isHidden == true, "a finished drop clears the highlight")
  precondition(apps == ["App.IPA"] && media == ["Photo.PNG", "Song.mp3", "Movie.MOV"])
  // The install queue remains an acceptable destination while another job
  // owns the device; readiness is rechecked if it goes away during a drag.
  precondition(view.draggingEntered(drag) == .copy)
  view.emulator!.canQueueInstall = false
  precondition(view.draggingUpdated(drag).isEmpty && !view.performDragOperation(drag))
  precondition(apps.count == 1 && media.count == 3)
  view.emulator!.canQueueInstall = true
  view.onDropMedia = nil
  drag.files(["Photo.png"])
  precondition(view.draggingEntered(drag).isEmpty && !view.performDragOperation(drag))
  // An IPSW goes to the library (matched by its SHA1), whatever the device is doing.
  view.emulator!.canQueueInstall = false
  drag.files(["iPad1,1_3.2.2_7B500_Restore.IPSW", "Notes.txt"])
  precondition(view.draggingEntered(drag) == .copy && drag.numberOfValidItemsForDrop == 1)
  precondition(view.performDragOperation(drag) && ipsws == ["iPad1,1_3.2.2_7B500_Restore.IPSW"])
  view.emulator!.canQueueInstall = true
  drag.files(["App.ipa"])
  drag.draggingSource = NSTableView()
  precondition(view.draggingEntered(drag).isEmpty && !view.performDragOperation(drag))
  // Explicit Store payloads remain accepted from inside the app.
  drag.draggingPasteboard.clearContents()
  let item = NSPasteboardItem()
  item.setData(try JSONEncoder().encode(CatalogApp(id: 42)), forType: .ltmCatalogApp)
  drag.draggingPasteboard.writeObjects([item])
  precondition(view.draggingEntered(drag) == .copy && drag.numberOfValidItemsForDrop == 1)
  precondition(view.performDragOperation(drag) && catalog == [42])

  print("PASS: accepted drags ring the screen until they leave or end, mixed Finder drops queue supported files, recheck readiness, reject missing handlers/internal IPA drags, route IPSWs to the library, and preserve Store drags")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-media-drop-') as directory:
    work = Path(directory)
    (work / 'check.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work / 'modules'), str(root / 'LightTouchMac/UI/DroppedFiles.swift'), str(root / 'LightTouchMac/UI/DropHighlight.swift'),
                    str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=25)
