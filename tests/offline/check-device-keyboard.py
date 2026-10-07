#!/usr/bin/env python3
"""Production keyboard preference and power-state gate."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'LightTouchMac/Device/EmulatorController.swift').read_text()
a=s.index('    var keyboardInputEnabled: Bool {');b=s.index('    // MARK: - Machine control',a)
source=r"""import Foundation
func logEvent(_ s: String) {}
@MainActor final class Check {
 struct Settings { var keyboardInputEnabled:Bool?; var hardwareKeyboard:Bool? }
 struct Profile { var canToggleHardwareKeyboard = true }
 var profile = Profile()
 var requests:[LinkRequest]=[]
 func control(_ r:LinkRequest,_ done:@escaping (Bool)->Void={_ in}){requests.append(r);done(true)}
 var settings=Settings()
 func changeSettings(_ change:(inout Settings)->Void){change(&settings)}
 var acceptsInput=true,isSleeping=false
 var onStatusChange:(()->Void)?
 final class FakeLink { var commands:[LinkCommand]=[]; func send(_ c:LinkCommand){commands.append(c)} }
 let fake=FakeLink()
 var link:FakeLink? {fake}
 var sent:[Bool] { fake.commands.compactMap { if case let .key(_,down)=$0 {down} else {nil} } }
"""+s[a:b]+r"""
 func run() {
  precondition(keyboardInputEnabled)
  var changes=0;onStatusChange={changes+=1}
  sendKey(macKeyCode:0,down:true);precondition(sent==[true])
  toggleKeyboardInput();precondition(!keyboardInputEnabled && changes==1)
  sendKey(macKeyCode:0,down:true);sendKey(macKeyCode:0,down:false)
  precondition(sent==[true,false],"release must remain possible after disabling")
  toggleKeyboardInput();precondition(keyboardInputEnabled && changes==2)
  isSleeping=true;sendKey(macKeyCode:0,down:true)
  isSleeping=false;acceptsInput=false;sendKey(macKeyCode:0,down:true)
  precondition(sent==[true,false],"sleeping/stopped devices must not receive key presses")
  // Connect Hardware Keyboard: the toggle unplugs and replugs it now; a boot (plugged in) unplugs it only when off.
  applyHardwareKeyboard();precondition(requests.isEmpty,"a boot with the keyboard on asked for something")
  toggleHardwareKeyboard();precondition(!hardwareKeyboardConnected && requests == [.hardwareKeyboard(false)] && changes==3)
  applyHardwareKeyboard();precondition(requests == [.hardwareKeyboard(false), .hardwareKeyboard(false)],"a boot didn't unplug it")
  toggleHardwareKeyboard();precondition(hardwareKeyboardConnected && requests.last == .hardwareKeyboard(true))
  profile.canToggleHardwareKeyboard=false;requests=[];settings.hardwareKeyboard=false
  applyHardwareKeyboard();precondition(requests.isEmpty,"a board without the toggle was asked")
  print("PASS: keyboard toggle, disabled/sleep/stopped gating and release delivery; Connect Hardware Keyboard now and at boot")
 }
}
@main struct Main {@MainActor static func main(){Check().run()}}
"""
with tempfile.TemporaryDirectory() as tmp:
 tmp=Path(tmp);(tmp/'check.swift').write_text(source)
 subprocess.run(['xcrun','swiftc', *host_runtime.swift_flags(Path(__file__).resolve().parents[2]),'-parse-as-library',str(root/'Shared/DeviceLinkProtocol.swift'),str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
 subprocess.run([str(tmp/'check')],check=True)
