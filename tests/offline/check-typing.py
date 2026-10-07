#!/usr/bin/env python3
"""Typing into the device screen: US-layout keys go through as key codes, anything else (another layout, an input
method) through the text input system as text, and every key the guest has down goes up when focus leaves.
The production DisplayView (compiled whole, check-model's fixture with a recording emulator, check-model-startup's
stub model) gets synthetic key events and its NSTextInputClient calls; nothing is put on screen. GuestKeyboard's
table and rule, and HeldKeys, are GuestKeyboardTests'."""
import ast, subprocess, sys, tempfile
from pathlib import Path
root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "scripts"))
import device_runtime

node = ast.parse((root / 'tests/offline/check-model.py').read_text())
fixture = next(ast.literal_eval(n.value) for n in node.body if isinstance(n, ast.Assign)
               and any(isinstance(t, ast.Name) and t.id == 'display_source' for t in n.targets))
prefix = fixture[:fixture.index('@main struct Check')]
recording = 'func sendKey(macKeyCode:UInt16,down:Bool) {};func typeText(_ text:String,shiftHeld:Bool) {}'
assert recording in prefix, 'check-model fixture changed: update this check'
prefix = prefix.replace(recording, 'var log:[String]=[]\n func sendKey(macKeyCode:UInt16,down:Bool) { log.append("\\(macKeyCode)\\(down ? "v" : "^")") }\n'
                        ' func typeText(_ text:String,shiftHeld:Bool) { log.append("type:\\(text)\\(shiftHeld ? "+shift" : "")") }')
startup = (root / 'tests/offline/check-model-startup.py').read_text()
start = startup.index('@MainActor final class DeviceModelView')
stub = startup[start:startup.index('@main struct Check', start)]

source = prefix + stub + r'''
func key(_ code:UInt16,_ chars:String,_ down:Bool=true,_ flags:NSEvent.ModifierFlags=[])->NSEvent {
 NSEvent.keyEvent(with:down ? .keyDown : .keyUp,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:chars,charactersIgnoringModifiers:chars,isARepeat:false,keyCode:code)!
}
func flags(_ code:UInt16,_ f:NSEvent.ModifierFlags)->NSEvent {
 NSEvent.keyEvent(with:.flagsChanged,location:.zero,modifierFlags:f,timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
}
@main struct Check {
 @MainActor static func main() {
  _ = fixtureMachines
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.prohibited)
  let v = DisplayView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), profile: .n72)
  let e = EmulatorController(); v.emulator = e
  let window = NSWindow(contentRect: v.frame, styleMask: [.titled], backing: .buffered, defer: false)
  window.contentView = v
  precondition(window.makeFirstResponder(v))
  // US layout: the key itself, down and up.
  v.keyDown(with:key(0,"a"));v.keyUp(with:key(0,"a",false))
  precondition(e.log==["0v","0^"],"\(e.log)");e.log=[]
  // Another layout: AZERTY's q (US a key) becomes text, and its key-up sends nothing.
  v.keyDown(with:key(0,"q"));v.keyUp(with:key(0,"q",false))
  precondition(e.log==["type:q"],"\(e.log)");e.log=[]
  // Shift held through a layout's capital: the text says Shift is down already.
  v.flagsChanged(with:flags(56,.shift));v.keyDown(with:key(0,"Q",true,.shift))
  precondition(e.log==["56v","type:Q+shift"],"\(e.log)");e.log=[]
  // Focus leaves with Shift and a key down: both go up, once.
  v.keyDown(with:key(1,"S",true,.shift))
  _=v.resignFirstResponder()
  precondition(Set(e.log)==["1v","56^","1^"] && e.log.count==3,"\(e.log)");e.log=[]
  v.releaseHeldKeys();v.keyUp(with:key(1,"s",false))
  precondition(e.log.isEmpty,"nothing left to release: \(e.log)")
  // Composition: marked text is held back until committed, and focus loss drops it.
  v.setMarkedText("´",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
  precondition(v.hasMarkedText());v.keyDown(with:key(0,"a"))
  precondition(!e.log.contains("0v"),"a key during composition goes to the input system: \(e.log)")
  v.insertText("á",replacementRange:NSRange(location:NSNotFound,length:0))
  precondition(e.log.last=="type:á" && !v.hasMarkedText(),"\(e.log)")
  print("PASS: US keys as key codes, other layouts and input methods as text, composition, held keys released on focus loss")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-typing-') as tmp:
    work = Path(tmp)
    (work / 'check.swift').write_text(source)
    sources = ['UI/DisplayView', 'Input/MouseTouchPair', 'Device/Board+App', '../tests/fixtures/machines', 'UI/DisplayMeasurements', 'UI/ZoomMode', 'Capture/PanelCapture', 'Input/KeyboardPointer', 'UI/KeyModifiers+AppKit', 'UI/AttitudeIndicatorButton',
               'UI/InlineLiveTextView', 'UI/DroppedFiles', 'UI/DropHighlight', 'UI/GuestKeyboard']
    subprocess.run(['swiftc', *device_runtime.swift_flags(root), '-module-cache-path', str(work / 'modules'), '-default-isolation', 'MainActor',
                    *[str(root / 'LightTouchMac' / f'{s}.swift') for s in sources], str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=60)
