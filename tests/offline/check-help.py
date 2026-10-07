#!/usr/bin/env python3
"""The Help window (UI/HelpWindowController.swift whole) over the bundled text: its topics in a sidebar, the chosen
topic's text, [Device] renamed keeping the topic, scrolling and Find. The topics and Help.txt's audit are HelpTopicTests'.
--out DIR keeps a render of one topic (help-topic.png); the window is never ordered front."""
from pathlib import Path
import argparse,plistlib,shutil,subprocess,tempfile
ap=argparse.ArgumentParser();ap.add_argument('--out');args=ap.parse_args()
root=Path(__file__).resolve().parents[2]/'LightTouchMac'
source=r'''import Cocoa
@main struct Run {
 @MainActor static func main() {
  _=NSApplication.shared
  let whole=try! String(contentsOf:Bundle.main.url(forResource:"Help",withExtension:"txt")!,encoding:.utf8)
  let help=HelpWindowController(text:whole), window=help.window!
  help.show(deviceName:"iPad")
  let topics=HelpTopic.topics(whole)
  let titles=topics.map(\.title)
  func descendants(_ v:NSView)->[NSView] { [v]+v.subviews.flatMap(descendants) }
  let list=descendants(window.contentView!).compactMap{$0 as? NSTableView}.first!, text=help.text
  precondition(list.numberOfRows==topics.count && list.selectedRow==0)
  precondition(!text.isEditable && text.isSelectable && text.usesFindBar)
  func show(_ title:String)->String {
   list.selectRowIndexes([titles.firstIndex(of:title)!],byExtendingSelection:false)
   return text.string
  }
  // Choosing a topic shows that topic, not the whole file.
  let capture=show("Screenshots and recordings")
  precondition(capture.hasPrefix("Screenshots and recordings\n") && capture.contains("Recordings include device audio") && !capture.contains("Physical Size"))
  // [Device] is the device's name (here the iPad the check's emulator is).
  let files=show("Device files")
  precondition(files.contains("Show iPad Files") && files.contains("Copy to iPad") && !files.contains("[Device]"),files)
  help.show(deviceName:"iPod");precondition(text.string.contains("Show iPod Files") && list.selectedRow==titles.firstIndex(of:"Device files"),"a new name keeps the topic")
  // A long topic scrolls in a small window; the text wraps to the column.
  window.setContentSize(NSSize(width:560,height:300));window.contentView!.layoutSubtreeIfNeeded()
  _=show("Screenshots and recordings");text.layoutManager!.ensureLayout(for:text.textContainer!);text.sizeToFit()
  let scroll=text.enclosingScrollView!
  precondition(scroll.hasVerticalScroller && text.frame.height>scroll.contentSize.height && text.textContainer!.widthTracksTextView)
  if CommandLine.arguments.count>1 {
   window.setContentSize(NSSize(width:780,height:560));window.contentView!.layoutSubtreeIfNeeded()
   _=show("Keyboard access")
   let content=window.contentView!
   let rep=content.bitmapImageRepForCachingDisplay(in:content.bounds)!
   content.cacheDisplay(in:content.bounds,to:rep)
   try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("help-topic.png"))
  }
  precondition(!window.isVisible)
  window.close()
  print("PASS: bundled Help's \(topics.count) topics in the sidebar, topic selection, [Device] naming that keeps the topic, scrolling and Find")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-help-') as tmp:
    tmp=Path(tmp);app=tmp/'Help Check.app/Contents'
    (app/'MacOS').mkdir(parents=True);(app/'Resources').mkdir()
    (app/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='app.lighttouch.helpcheck',CFBundleExecutable='check',CFBundlePackageType='APPL')))
    shutil.copyfile(root/'Help.txt',app/'Resources/Help.txt')
    (tmp/'check.swift').write_text(source)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',str(root/'App/WindowRestorationPolicy.swift'),str(root/'UI/HelpWindowController.swift'),str(root/'UI/HelpTopic.swift'),str(tmp/'check.swift'),'-parse-as-library','-o',str(app/'MacOS/check')],check=True)
    subprocess.run([str(app/'MacOS/check'),*([args.out] if args.out else [])],check=True)
