#!/usr/bin/env python3
"""Native column browser loading, navigation, layout and stale-reply handling."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='ltm-files-ui-') as tmp:
 tmp=Path(tmp)
 (tmp/'check.swift').write_text(r'''import Cocoa
// Supply the test window to AppKit's real action dispatcher without requiring
// desktop activation (the test must also run while the Mac is locked).
@MainActor final class FilesApplication:NSApplication {
 var commandWindow:NSWindow?
 override var keyWindow:NSWindow? { commandWindow }
 override var mainWindow:NSWindow? { commandWindow }
}
struct DeviceFile: Sendable { let name,path:String;let isDirectory,isRegular:Bool;let size:UInt64 }
// Listings the fake has handed back; the reply's consumer runs in the same main-actor job, so once the count moves the reply was taken or dropped.
var replies=0
nonisolated(unsafe) var uploads:[(String,String)]=[]
struct DeviceServices: Sendable {
 func files(in path:String) async throws ->[DeviceFile] {
  try? await Task.sleep(for:.milliseconds(30)) // Deliberately deliver after cancellation.
  defer { replies+=1 }
  return path.isEmpty ? [DeviceFile(name:"Folder",path:"Folder",isDirectory:true,isRegular:false,size:0)] : [DeviceFile(name:"file.bin",path:"Folder/file.bin",isDirectory:false,isRegular:true,size:10),DeviceFile(name:"note.txt",path:"Folder/note.txt",isDirectory:false,isRegular:true,size:5)]
 }
 func freeSpaceBytes() async throws ->Int64 { 2_500_000_000 }
 func uploadFile(_ source:URL,into path:String,progress:@escaping @Sendable(Double)->Void) async throws { uploads.append((source.lastPathComponent,path)) }
 func download(_ file:DeviceFile,to path:URL,progress:@escaping @Sendable(Double)->Void) async throws {
  try Data(("device:"+file.path).utf8).write(to:path)
 }
}
/// A drop of `urls` (only the pasteboard matters to the browser delegate).
final class Drop: NSObject, NSDraggingInfo {
 let pasteboard=NSPasteboard(name:.init("ltm-files-ui-drop-"+UUID().uuidString))
 init(_ urls:[URL]) { super.init(); pasteboard.clearContents(); pasteboard.writeObjects(urls as [NSURL]) }
 var draggingDestinationWindow:NSWindow? { nil }
 var draggingSourceOperationMask:NSDragOperation { .copy }
 var draggingLocation:NSPoint { .zero }
 var draggedImageLocation:NSPoint { .zero }
 var draggedImage:NSImage? { nil }
 var draggingPasteboard:NSPasteboard { pasteboard }
 var draggingSource:Any? { nil }
 var draggingSequenceNumber:Int { 1 }
 func slideDraggedImage(to screenPoint:NSPoint) {}
 var draggingFormation:NSDraggingFormation { get { .default } set {} }
 var animatesToDestination:Bool { get { false } set {} }
 var numberOfValidItemsForDrop:Int { get { 1 } set {} }
 func enumerateDraggingItems(options:NSDraggingItemEnumerationOptions=[],for view:NSView?,classes:[AnyClass],searchOptions:[NSPasteboard.ReadingOptionKey:Any]=[:],using block:(NSDraggingItem,Int,UnsafeMutablePointer<ObjCBool>)->Void) {}
 var springLoadingHighlight:NSSpringLoadingHighlight { .none }
 func resetSpringLoading() {}
}
final class Sink: NSResponder {
 var events = 0
 override func keyDown(with event:NSEvent) { events += 1 }
 override func scrollWheel(with event:NSEvent) { events += 1 }
}
@main struct Check {
 @MainActor static func main() {
  _ = FilesApplication.shared
  Task { @MainActor in
   do { try await runChecks(); exit(0) }
   catch { fatalError(String(describing:error)) }
  }
  NSApp.run()
 }
 @MainActor static func runChecks() async throws {
  let controller=DeviceFilesWindowController(profile:.n72)
  let vc=controller.browser;vc.services=DeviceServices()
  let window=controller.window!
  (NSApp as! FilesApplication).commandWindow=window
  controller.showWindow(nil)
  window.setContentSize(NSSize(width:360,height:500))
  // Wait on the listing itself; the deadline only guards a hang (host load must not decide the verdict).
  func until(_ what:String,_ ok:()->Bool) async throws {
   let guardline=Date().addingTimeInterval(15)
   while !ok() { precondition(Date()<guardline,"hung waiting: \(what)"); try await Task.sleep(for:.milliseconds(10)) }
  }
  vc.reload()
  func children(_ view:NSView)->[NSView] { view.subviews.flatMap{[$0]+children($0)} }
  let all=children(vc.view)
  let browser=all.compactMap{$0 as? NSBrowser}.first!
  func rows(_ column:Int)->Int { browser.matrix(inColumn:column)?.numberOfRows ?? -1 }
  try await until("the root listing") { rows(0)==1 }
  browser.selectRow(0,inColumn:0)
  browser.addColumn()
  try await until("the folder listing") { rows(1)==2 }
  browser.selectRow(0,inColumn:1)
  browser.sendAction(browser.action!,to:browser.target)
  let export=all.compactMap{$0 as? NSButton}.first{$0.title=="Save to Mac…"}!
  precondition(export.isEnabled)
  let save=NSMenuItem(title:"Save to Mac…",action:#selector(DeviceFilesViewController.exportFile),keyEquivalent:"")
  let copy=NSMenuItem(title:"Copy to iPod…",action:#selector(DeviceFilesViewController.importFile),keyEquivalent:"")
  let cancel=NSMenuItem(title:"Cancel Transfer",action:#selector(DeviceFilesViewController.cancelTransfer),keyEquivalent:"")
  let hidden=NSMenuItem(title:"Show Hidden Files",action:#selector(DeviceFilesViewController.toggleHidden(_:)),keyEquivalent:"")
  precondition(vc.validateMenuItem(save) && vc.validateMenuItem(copy) && !vc.validateMenuItem(cancel))
  vc.focusBrowser()
  precondition(NSApp.target(forAction:save.action!,to:nil,from:save) as? DeviceFilesViewController === vc,"File menu reaches focused browser")
  precondition(NSApp.sendAction(hidden.action!,to:nil,from:hidden))
  precondition(vc.validateMenuItem(hidden) && hidden.title=="Hide Hidden Files" && hidden.state == .off)
  precondition(NSApp.sendAction(hidden.action!,to:nil,from:hidden))
  try await until("the root listing again") { rows(0)==1 }
  browser.selectRow(0,inColumn:0);browser.addColumn()
  try await until("the folder listing again") { rows(1)==2 }
  precondition(!vc.validateMenuItem(save),"Directories cannot be exported as files")
  browser.selectRow(0,inColumn:1);browser.sendAction(browser.action!,to:browser.target)
  for width in [360.0,660.0,900.0] {
   window.setContentSize(NSSize(width:width,height:500));vc.view.layoutSubtreeIfNeeded()
   for button in all.compactMap({$0 as? NSButton}) where !button.isHidden {
    let frame=button.convert(button.bounds,to:vc.view)
    precondition(frame.minX>=0 && frame.maxX<=width,"clipped \(button.title): \(frame)")
   }
  }
  // Several at once: both files selected export, drag out as two file promises, and fulfil into the drop folder.
  browser.selectRowIndexes(IndexSet([0,1]),inColumn:1);browser.sendAction(browser.action!,to:browser.target)
  precondition(vc.validateMenuItem(save) && export.isEnabled,"two files selected can be saved")
  precondition(vc.browser(browser,canDragRowsWith:IndexSet([0,1]),inColumn:1,with:NSEvent()),"files drag out")
  precondition(!vc.browser(browser,canDragRowsWith:IndexSet([0]),inColumn:0,with:NSEvent()),"a folder doesn't drag out")
  let board=NSPasteboard(name:.init("ltm-files-ui-"+UUID().uuidString))
  precondition(vc.browser(browser,writeRowsWith:IndexSet([0,1]),inColumn:1,to:board) && board.pasteboardItems?.count==2,"two promises")
  let out=FileManager.default.temporaryDirectory.appendingPathComponent("ltm-files-ui-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:out) }
  let provider=vc.promise(DeviceFile(name:"note.txt",path:"Folder/note.txt",isDirectory:false,isRegular:true,size:5))
  precondition(vc.filePromiseProvider(provider,fileNameForType:provider.fileType)=="note.txt")
  var fulfilled:Error??=nil
  vc.filePromiseProvider(provider,writePromiseTo:out.appendingPathComponent("note.txt")) { fulfilled = .some($0) }
  try await until("the promise") { fulfilled != nil }
  precondition(fulfilled! == nil && (try? String(contentsOf:out.appendingPathComponent("note.txt"),encoding:.utf8))=="device:Folder/note.txt","promised file written")
  // Drag in: onto the folder row puts the files in it; a Finder file anywhere in column 1 goes to Folder.
  let local=out.appendingPathComponent("from-mac.txt");try Data("x".utf8).write(to:local)
  var row=0,column=0,op=NSBrowser.DropOperation.on
  precondition(vc.browser(browser,validateDrop:Drop([local]),proposedRow:&row,column:&column,dropOperation:&op) == .copy)
  precondition(vc.browser(browser,acceptDrop:Drop([local]),atRow:0,column:0,dropOperation:.on))
  try await until("the drop upload") { !vc.hasTransfer && uploads.count==1 }
  precondition(uploads.last! == ("from-mac.txt","Folder"),"dropped into the folder: \(uploads)")
  try await until("the folder listing after the drop") { rows(0)==1 }
  browser.selectRow(0,inColumn:0);browser.addColumn()
  try await until("the folder listing after the drop") { rows(1)==2 }
  row=1;column=1;op = .on
  precondition(vc.browser(browser,validateDrop:Drop([local]),proposedRow:&row,column:&column,dropOperation:&op) == .copy && op == .above && row == -1)
  precondition(vc.browser(browser,acceptDrop:Drop([local]),atRow:-1,column:1,dropOperation:.above))
  try await until("the second drop upload") { !vc.hasTransfer && uploads.count==2 }
  precondition(uploads.last! == ("from-mac.txt","Folder"),"dropped into the column's folder: \(uploads)")
  // Quick Look: the selected files copied to a private folder for the panel (kept off screen here).
  try await until("the root listing for Quick Look") { rows(0)==1 }
  browser.selectRow(0,inColumn:0);browser.addColumn()
  try await until("the folder listing for Quick Look") { rows(1)==2 }
  browser.selectRowIndexes(IndexSet([0,1]),inColumn:1);browser.sendAction(browser.action!,to:browser.target)
  var presented=false;vc.presentPreview={ presented=true }
  vc.quickLook(nil)
  try await until("the Quick Look copies") { presented }
  precondition(vc.previewURLs.map(\.lastPathComponent)==["file.bin","note.txt"] && vc.previewURLs.allSatisfy{FileManager.default.fileExists(atPath:$0.path)})
  precondition(vc.numberOfPreviewItems(in:nil)==2)
  window.setContentSize(NSSize(width:360,height:500));vc.view.layoutSubtreeIfNeeded()
  let image=vc.view.bitmapImageRepForCachingDisplay(in:vc.view.bounds)!
  vc.view.cacheDisplay(in:vc.view.bounds,to:image)
  try image.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/ltm-files-ui.png"))
  window.close()
  controller.showWindow(nil)
  precondition(controller.browser === vc && browser.selectedColumn == 1)
  precondition(!window.isExcludedFromWindowsMenu && window.styleMask.contains(.resizable))
  let asked=replies
  vc.reload();vc.services=nil;vc.reload()
  try await until("the stale listing's reply") { replies>asked }
  precondition(browser.matrix(inColumn:0)!.numberOfRows==0 && !export.isEnabled)
  precondition(!vc.validateMenuItem(save) && !vc.validateMenuItem(copy) && !vc.validateMenuItem(cancel))
  let idleStatus=vc.transferStatus;vc.cancelTransfer();precondition(vc.transferStatus==idleStatus)
  let sink=Sink();let next=vc.view.nextResponder;vc.view.nextResponder=sink
  let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"x",charactersIgnoringModifiers:"x",isARepeat:false,keyCode:7)!
  vc.view.keyDown(with:key);vc.view.scrollWheel(with:key)
  precondition(sink.events==0)
  vc.view.nextResponder=next
  vc.stop()
  print("PASS: native Files routing, multi-select, drag out (file promises) and in, Quick Look copies, selection/connection validation, columns, 360/660/900-point layout and stale reply rejection")
 }
}
''')
 subprocess.run(['xcrun','swiftc', *host_runtime.swift_flags(Path(__file__).resolve().parents[2]),'-default-isolation','MainActor',str(root/'LightTouchMac/App/WindowRestorationPolicy.swift'),str(root/'LightTouchMac/UI/DeviceFilesViewController.swift'),str(root/'LightTouchMac/App/UserActivity.swift'),str(root/'LightTouchMac/UI/DeviceFilesWindowController.swift'),str(root/'LightTouchMac/Library/UnusedURL.swift'),str(root/'LightTouchMac/Device/Board+App.swift'),str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
 subprocess.run([str(tmp/'check')],check=True,timeout=120)  # hang guard only
