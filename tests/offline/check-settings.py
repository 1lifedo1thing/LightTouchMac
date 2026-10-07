#!/usr/bin/env python3
"""Exercise the production preference actions and menu validation without a guest."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[2]
source=(root/'LightTouchMac/App/AppDelegate.swift').read_text()
a=source.index('    @objc func toggleAutomaticRotation(')
b=source.index('    @objc func showHelp(',a)
actions=source[a:b]
fixture=r'''import Cocoa
import SwiftUI
@MainActor enum NetworkAccessPreference { static let key="guestNetworkEnabled" }
@MainActor final class EmulatorController {
 var network = true
 struct Profile { let shortName = "iPod"; let marketingName = "iPod touch (2nd generation)" }
 var localNetworkEnabled = false
 func toggleLocalNetwork() { localNetworkEnabled.toggle() }
 let profile = Profile()
 static let autoRotateDefaultsKey="autoRotateWithGuest"
 static var autoRotateEnabled:Bool { UserDefaults.standard.object(forKey:autoRotateDefaultsKey) as? Bool ?? true }
 var autoRotateEnabled:Bool { Self.autoRotateEnabled }
 func toggleAutoRotate() { UserDefaults.standard.set(!autoRotateEnabled, forKey:Self.autoRotateDefaultsKey) }
 var debugPortEnabled = false
 func toggleDebugPort() { debugPortEnabled.toggle() }
 var debugPort:Int? = nil
 var lldbAttachCommand:String? { debugPort.map { "lldb -o 'gdb-remote 127.0.0.1:\($0)'" } }
}
@MainActor final class AppDelegate:NSObject, NSMenuItemValidation {
 var emulator:EmulatorController? = EmulatorController()
'''+actions+r'''
}
@main struct Check {
 @MainActor static func main() {
  _=NSApplication.shared
  let defaults=UserDefaults.standard
  defer { defaults.removeObject(forKey:NetworkAccessPreference.key);defaults.removeObject(forKey:EmulatorController.autoRotateDefaultsKey) }
  defaults.set(true,forKey:EmulatorController.autoRotateDefaultsKey)
  defaults.removeObject(forKey:NetworkAccessPreference.key)
  let delegate=AppDelegate()
  let rotation=NSMenuItem(title:"Rotate Automatically",action:#selector(AppDelegate.toggleAutomaticRotation(_:)),keyEquivalent:"")
  let network=NSMenuItem(title:"Connect to the Internet",action:#selector(AppDelegate.toggleInternetAccess(_:)),keyEquivalent:"")
  precondition(delegate.validateMenuItem(rotation) && rotation.state == .on)
  delegate.toggleAutomaticRotation(nil)
  precondition(delegate.validateMenuItem(rotation) && rotation.state == .off && !EmulatorController.autoRotateEnabled)
  precondition(delegate.validateMenuItem(network) && network.state == .on)
  delegate.toggleInternetAccess(nil)
  precondition(delegate.validateMenuItem(network) && network.state == .off && network.title == "Connect to the Internet" && network.toolTip == "Takes effect the next time Light Touch opens the iPod.")
  delegate.toggleInternetAccess(nil)
  precondition(delegate.validateMenuItem(network) && network.state == .on && network.title == "Connect to the Internet" && network.toolTip == nil)
  delegate.emulator!.network=false
  defaults.removeObject(forKey:NetworkAccessPreference.key)
  precondition(delegate.validateMenuItem(network) && network.state == .off && network.toolTip == nil)
  // Attach to Local Network: named for the device, off until turned on, and disabled with no device.
  let lan=NSMenuItem(title:"Attach to Local Network",action:#selector(AppDelegate.toggleLocalNetwork(_:)),keyEquivalent:"")
  precondition(delegate.validateMenuItem(lan) && lan.state == .off && lan.title == "Attach iPod touch (2nd generation) to Local Network", lan.title)
  delegate.toggleLocalNetwork(nil)
  precondition(delegate.validateMenuItem(lan) && lan.state == .on)
  let device=delegate.emulator;delegate.emulator=nil
  precondition(!delegate.validateMenuItem(lan) && lan.title == "Attach to Local Network");delegate.emulator=device
  let debug=NSMenuItem(title:"Debug Port…",action:#selector(AppDelegate.showDebugPort(_:)),keyEquivalent:"")
  let copy=NSMenuItem(title:"Copy lldb Command",action:#selector(AppDelegate.copyLLDBCommand(_:)),keyEquivalent:"")
  precondition(delegate.validateMenuItem(debug) && debug.state == .off && debug.toolTip == nil && !delegate.validateMenuItem(copy))
  precondition(DebugPortView.state(shortName:"iPod",enabled:false,port:nil) == "Off.")
  delegate.emulator!.toggleDebugPort()
  precondition(delegate.validateMenuItem(debug) && debug.state == .on && debug.toolTip == "Takes effect the next time the iPod starts.")
  delegate.emulator!.debugPort=4321
  precondition(DebugPortView.state(shortName:"iPod",enabled:true,port:4321) == "On, at 127.0.0.1:4321.")
  let commands=DebugPortView.commands(port:4321,lldbWithSymbols:delegate.emulator!.lldbAttachCommand).map(\.1)
  precondition(commands.count == 3 && commands[0].contains("gdb-remote 127.0.0.1:4321") && commands[2].contains("target remote 127.0.0.1:4321"))
  precondition(DebugPortView.state(shortName:"iPod",enabled:false,port:4321).hasPrefix("Off from the next start."))
  // The sheet: a real size, every command on it with a Copy button, offscreen.
  let sheet=NSHostingView(rootView:DebugPortView(shortName:"iPod",port:4321,lldbWithSymbols:delegate.emulator!.lldbAttachCommand,enabled:true,onToggle:{},onDone:{}))
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:400),styleMask:[.titled],backing:.buffered,defer:true)
  window.contentView=sheet; sheet.setFrameSize(sheet.fittingSize); sheet.layoutSubtreeIfNeeded()
  func all(_ v:NSView)->[NSView] { v.subviews.flatMap { [$0]+all($0) } }
  precondition(sheet.fittingSize.width >= 500 && sheet.fittingSize.height > 250, "debug port sheet \(sheet.fittingSize)")
  if let out=ProcessInfo.processInfo.environment["LTM_CHECK_OUT"] {
   let rep=sheet.bitmapImageRepForCachingDisplay(in:sheet.bounds)!; sheet.cacheDisplay(in:sheet.bounds,to:rep)
   try? rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:out).appendingPathComponent("debug-port.png"))
  }
  precondition(delegate.validateMenuItem(debug) && debug.toolTip == nil && delegate.validateMenuItem(copy) && copy.toolTip!.contains("127.0.0.1:4321"))
  print("PASS: the debug port follows the next start and offers its lldb command only while a boot has one")
  print("PASS: menu preferences apply rotation immediately and show pending internet changes in the tooltip, never the title")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-preferences-') as directory:
 work=Path(directory);(work/'check.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-default-isolation','MainActor',str(root/'LightTouchMac/UI/DebugPortView.swift'),str(work/'check.swift'),'-o',str(work/'check')],check=True)
 subprocess.run([str(work/'check')],check=True)
