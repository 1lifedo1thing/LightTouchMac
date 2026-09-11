#!/usr/bin/env python3
"""Test production DisplayView's bounded model startup and late-render fallback."""
import ast
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
node=ast.parse((root/'tests/check-model.py').read_text())
fixture=next(ast.literal_eval(n.value) for n in node.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='display_source' for t in n.targets))
source=fixture[:fixture.index('@main struct Check')]+r'''
@MainActor final class DeviceModelView:NSView {
 static var preparationDelay:Duration = .milliseconds(50)
 let delay:Duration
 init(url:URL) async throws {delay=Self.preparationDelay;super.init(frame:.zero)}
 required init?(coder:NSCoder){fatalError()}
 func prepareFirstFrame() async -> Bool {
  // Deliberately ignore cancellation to reproduce a late renderer callback.
  await withCheckedContinuation { continuation in
   Task { try? await Task.sleep(for:delay);continuation.resume() }
  }
  return true
 }
 func pose(scale:CGFloat,rotation:Int,roll:CGFloat,pitch:CGFloat,yaw:CGFloat=0,animated:Bool,spring:Bool=false){}
 func updateFrame(_ image:CGImage){}
 func setScreenOff(_ off:Bool){}
 var homeButtonRect:CGRect? {nil}
 func projectedPoint(_ p:CGPoint)->CGPoint{.zero}
 func panelPoint(_ p:CGPoint,clamped:Bool=false)->CGPoint?{nil}
 func isChassis(_ p:CGPoint)->Bool{false}
 func advanceAnimations(){}
 func shake(){}
}
@main struct Check {
 @MainActor static func main() async throws {
  _=NSApplication.shared
  for slow in [false,true] {
   DeviceModelView.preparationDelay = slow ? .milliseconds(1400):.milliseconds(50)
   let display=DisplayView(frame:NSRect(x:0,y:0,width:500,height:800))
   let e=EmulatorController();display.emulator=e
   let window=NSWindow(contentRect:display.frame,styleMask:[.titled],backing:.buffered,defer:false)
   window.contentView=display;window.orderFront(nil)
   display.needsLayout=true;display.layoutSubtreeIfNeeded()
   let shell=display.layer!.sublayers!.first { $0.bounds.size==CGSize(width:737,height:1318) }!
   precondition(shell.isHidden,"Do not flash the photo before the model gets its first chance to render")
   try await Task.sleep(for:.milliseconds(1100))
   let models=display.subviews.compactMap{$0 as? DeviceModelView}
   if slow {
    precondition(models.isEmpty && !shell.isHidden,"Slow renderer must fall back within one second")
    try await Task.sleep(for:.milliseconds(600))
    precondition(display.subviews.compactMap{$0 as? DeviceModelView}.isEmpty && !shell.isHidden,
      "A late frame must not replace the already-visible photo")
   } else {
    precondition(models.count==1 && models[0].alphaValue>0 && shell.isHidden,
      "A ready first frame must present only the model")
   }
   window.orderOut(nil);window.contentView=nil
  }
  DeviceModelView.preparationDelay = .seconds(5)
  var closingDisplay:DisplayView? = DisplayView(frame:NSRect(x:0,y:0,width:500,height:800))
  weak let releasedDisplay = closingDisplay
  let closingWindow=NSWindow(contentRect:closingDisplay!.frame,styleMask:[.titled],backing:.buffered,defer:false)
  closingWindow.contentView=closingDisplay;closingWindow.orderFront(nil)
  try await Task.sleep(for:.milliseconds(100))
  closingWindow.orderOut(nil);closingWindow.contentView=nil;closingDisplay=nil
  try await Task.sleep(for:.milliseconds(100))
  precondition(releasedDisplay==nil,"A stalled renderer callback must not retain the closed display")
  print("PASS: first rendered model or bounded static fallback; no photo flash, late swap, or closed-window retention")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-model-startup-') as tmp:
    work=Path(tmp);app=work/'Check.app/Contents';(app/'MacOS').mkdir(parents=True);(app/'Resources').mkdir()
    (app/'Resources/N72.usdz').symlink_to(root/'LightTouchMac/N72.usdz')
    swift=work/'check.swift';swift.write_text(source);exe=app/'MacOS/check'
    subprocess.run(['swiftc','-module-cache-path',str(work/'modules'),'-default-isolation','MainActor',
                    *[str(root/'LightTouchMac'/f'{name}.swift') for name in ['DisplayView','GameControllerInput','AttitudeIndicatorButton','InlineLiveTextView']],
                    str(swift),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True,timeout=15)
