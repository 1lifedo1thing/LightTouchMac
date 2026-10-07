#!/usr/bin/env python3
"""Native file-drop acceptance on the device screen, through the production DisplayView compiled whole (check-model's
fixture, check-model-startup's stub model, the 2D bezel; no window): a synthetic NSDraggingInfo into its dragging
handlers. The file kinds are UI/DroppedFiles.swift's. Revealing a dropped file's transfer in the Apps inspector is
AppsInspectorRowsTests' (AppsInspector.revealsTransfer)."""
import ast, subprocess, sys, tempfile
from pathlib import Path
root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "scripts"))
import device_runtime

node = ast.parse((root / 'tests/offline/check-model.py').read_text())
fixture = next(ast.literal_eval(n.value) for n in node.body if isinstance(n, ast.Assign)
               and any(isinstance(t, ast.Name) and t.id == 'display_source' for t in n.targets))
prefix = fixture[:fixture.index('@main struct Check')]
# Store rows carry a catalog id; media kinds are the app's (PreparedMedia's own list is ported with it).
for old, new in [('struct CatalogApp: Decodable {}', 'struct CatalogApp: Codable { let id: Int }'),
                 ('enum PreparedMedia { nonisolated static let extensions: Set<String> = [] }',
                  'enum PreparedMedia { nonisolated static let extensions: Set<String> = ["png", "jpg", "mp3", "m4a", "mp4", "mov", "m4v"] }')]:
    assert old in prefix, 'check-model fixture changed: update this check'
    prefix = prefix.replace(old, new)
startup = (root / 'tests/offline/check-model-startup.py').read_text()
start = startup.index('@MainActor final class DeviceModelView')
stub = startup[start:startup.index('@main struct Check', start)]

source = prefix + stub + r'''
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
  _ = fixtureMachines
  for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] { UserDefaults.standard.removeObject(forKey: key) }
  defer { for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] { UserDefaults.standard.removeObject(forKey: key) } }
  DisplayView.bezel = .flat
  let view = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: .n72), drag = Drag()
  let emulator = EmulatorController(); view.emulator = emulator   // weak: held here
  defer { withExtendedLifetime(emulator) {} }
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
  emulator.canQueueInstall = false
  precondition(view.draggingUpdated(drag).isEmpty && !view.performDragOperation(drag))
  precondition(apps.count == 1 && media.count == 3)
  emulator.canQueueInstall = true
  view.onDropMedia = nil
  drag.files(["Photo.png"])
  precondition(view.draggingEntered(drag).isEmpty && !view.performDragOperation(drag))
  // An IPSW goes to the library (matched by its SHA1), whatever the device is doing.
  emulator.canQueueInstall = false
  drag.files(["iPad1,1_3.2.2_7B500_Restore.IPSW", "Notes.txt"])
  precondition(view.draggingEntered(drag) == .copy && drag.numberOfValidItemsForDrop == 1)
  precondition(view.performDragOperation(drag) && ipsws == ["iPad1,1_3.2.2_7B500_Restore.IPSW"])
  emulator.canQueueInstall = true
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
with tempfile.TemporaryDirectory(prefix='ltm-media-drop-') as tmp:
    work = Path(tmp)
    (work / 'check.swift').write_text(source)
    sources = ['UI/DisplayView', 'Input/MouseTouchPair', 'Device/Board+App', '../tests/fixtures/machines', 'UI/DisplayMeasurements', 'UI/ZoomMode', 'Capture/PanelCapture', 'Input/KeyboardPointer', 'Session/ChassisTilt', 'UI/KeyModifiers+AppKit', 'UI/AttitudeIndicatorButton',
               'UI/InlineLiveTextView', 'UI/DroppedFiles', 'UI/DropHighlight', 'UI/GuestKeyboard']
    subprocess.run(['swiftc', *device_runtime.swift_flags(root), '-module-cache-path', str(work / 'modules'), '-default-isolation', 'MainActor',
                    *[str(root / 'LightTouchMac' / f'{s}.swift') for s in sources], str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=60)
