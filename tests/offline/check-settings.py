#!/usr/bin/env python3
"""The Debug Port sheet (UI/DebugPortView.swift whole, SwiftUI) at a real size, offscreen. The menu items' state
and the sheet's text are DeviceSettingsMenuTests'. LTM_CHECK_OUT=DIR keeps a render (debug-port.png)."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[2]
fixture=r'''import Cocoa
import SwiftUI
@main struct Check {
 @MainActor static func main() {
  _=NSApplication.shared
  let lldb="lldb -o 'gdb-remote 127.0.0.1:4321' KERNELCACHE"
  let sheet=NSHostingView(rootView:DebugPortView(shortName:"iPod",port:4321,lldbWithSymbols:lldb,enabled:true,onToggle:{},onDone:{}))
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:400),styleMask:[.titled],backing:.buffered,defer:true)
  window.contentView=sheet; sheet.setFrameSize(sheet.fittingSize); sheet.layoutSubtreeIfNeeded()
  precondition(sheet.fittingSize.width >= 500 && sheet.fittingSize.height > 250, "debug port sheet \(sheet.fittingSize)")
  if let out=ProcessInfo.processInfo.environment["LTM_CHECK_OUT"] {
   let rep=sheet.bitmapImageRepForCachingDisplay(in:sheet.bounds)!; sheet.cacheDisplay(in:sheet.bounds,to:rep)
   try? rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:out).appendingPathComponent("debug-port.png"))
  }
  print("PASS: the Debug Port sheet lays out at a real size with its commands")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-preferences-') as directory:
 work=Path(directory);(work/'check.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-default-isolation','MainActor',str(root/'LightTouchMac/UI/DebugPortView.swift'),
                 str(root/'LightTouchMac/App/DeviceSettingsMenu.swift'),str(work/'check.swift'),'-o',str(work/'check')],check=True)
 subprocess.run([str(work/'check')],check=True)
