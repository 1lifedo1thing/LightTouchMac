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
@MainActor enum NetworkAccessPreference { static let key="guestNetworkEnabled" }
@MainActor final class EmulatorController {
 var network = true
 struct Profile { let shortName = "iPod" }
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
  let debug=NSMenuItem(title:"Debug Port…",action:#selector(AppDelegate.showDebugPort(_:)),keyEquivalent:"")
  let copy=NSMenuItem(title:"Copy lldb Command",action:#selector(AppDelegate.copyLLDBCommand(_:)),keyEquivalent:"")
  precondition(delegate.validateMenuItem(debug) && debug.state == .off && debug.toolTip == nil && !delegate.validateMenuItem(copy))
  precondition(AppDelegate.debugPortText(shortName:"iPod",enabled:false,port:nil).hasPrefix("Off.\n"))
  delegate.emulator!.toggleDebugPort()
  precondition(delegate.validateMenuItem(debug) && debug.state == .on && debug.toolTip == "Takes effect the next time the iPod starts.")
  delegate.emulator!.debugPort=4321
  let text=AppDelegate.debugPortText(shortName:"iPod",enabled:true,port:4321)
  precondition(text.hasPrefix("On, at 127.0.0.1:4321.") && text.contains("gdb-remote 127.0.0.1:4321") && text.contains("target remote 127.0.0.1:4321"))
  precondition(AppDelegate.debugPortText(shortName:"iPod",enabled:false,port:4321).hasPrefix("Off from the next start."))
  precondition(delegate.validateMenuItem(debug) && debug.toolTip == nil && delegate.validateMenuItem(copy) && copy.toolTip!.contains("127.0.0.1:4321"))
  print("PASS: the debug port follows the next start and offers its lldb command only while a boot has one")
  print("PASS: menu preferences apply rotation immediately and show pending internet changes in the tooltip, never the title")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-preferences-') as directory:
 work=Path(directory);(work/'check.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-default-isolation','MainActor',str(work/'check.swift'),'-o',str(work/'check')],check=True)
 subprocess.run([str(work/'check')],check=True)
