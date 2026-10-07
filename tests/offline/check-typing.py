#!/usr/bin/env python3
"""Typing into the device screen: US-layout keys go through as key codes, anything else (another layout, an input
method) through the text input system as text, and every key the guest has down goes up when focus leaves.
DisplayView's key handlers and its NSTextInputClient run against a recording emulator; GuestKeyboard is compiled whole."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
s = (root / 'LightTouchMac/UI/DisplayView.swift').read_text()
keys = s[s.index('    private var consumedWakeSpace = false'):s.index('    // MARK: - Drag & drop')]
client = s[s.index('extension DisplayView: NSTextInputClient {'):]
code = r"""import Cocoa
@MainActor final class Emulator {
 var log:[String]=[]
 var isSleeping=false,acceptsInput=true,keyboardInputEnabled=true
 func pressLock() {}
 func sendKey(macKeyCode:UInt16,down:Bool) { log.append("\(macKeyCode)\(down ? "v" : "^")") }
 func typeText(_ text:String,shiftHeld:Bool) { log.append("type:\(text)\(shiftHeld ? "+shift" : "")") }
}
@MainActor final class DisplayView: NSView {
 let emulator:Emulator?=Emulator()
 var isShowingLiveText=false
 func endLiveText() {}
 func moveFocusOut(_ e:NSEvent)->Bool { false }
 func keyboardPointerKey(_ e:NSEvent,down:Bool)->Bool { false }
 var keyboardTouchKeys=Set<UInt16>()
 func endKeyboardTouch() {}
 func updatePairRings(_ f:NSEvent.ModifierFlags) {}
 func resetMotion() {}
 lazy var context=NSTextInputContext(client:self)
 override var inputContext:NSTextInputContext? { context }
""" + keys + "}\n" + client + r"""
func key(_ code:UInt16,_ chars:String,_ down:Bool=true,_ flags:NSEvent.ModifierFlags=[])->NSEvent {
 NSEvent.keyEvent(with:down ? .keyDown : .keyUp,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:chars,charactersIgnoringModifiers:chars,isARepeat:false,keyCode:code)!
}
func flags(_ code:UInt16,_ f:NSEvent.ModifierFlags)->NSEvent {
 NSEvent.keyEvent(with:.flagsChanged,location:.zero,modifierFlags:f,timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
}
@main struct Main { @MainActor static func main() {
 // The table and the rule on their own.
 precondition(GuestKeyboard.passesThrough(keyCode:0,characters:"a",shift:false))
 precondition(GuestKeyboard.passesThrough(keyCode:0,characters:"A",shift:true))
 precondition(!GuestKeyboard.passesThrough(keyCode:0,characters:"q",shift:false),"AZERTY's q on the US a key is text")
 precondition(!GuestKeyboard.passesThrough(keyCode:14,characters:"",shift:false),"a dead key is text")
 precondition(!GuestKeyboard.passesThrough(keyCode:0,characters:"a",shift:false,inputSource:"com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"),"an input method composes")
 precondition(GuestKeyboard.passesThrough(keyCode:36,characters:"\r",shift:false,inputSource:"com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"),"Return is a key")
 precondition(GuestKeyboard.key(for:"Q")! == (12,true) && GuestKeyboard.key(for:"/")! == (44,false) && GuestKeyboard.key(for:"é")==nil)
 var held=HeldKeys();held.press(56);held.press(0);precondition(held.release(0) && !held.release(0) && held.releaseAll()==[56] && held.down.isEmpty)

 let v=DisplayView(frame:NSRect(x:0,y:0,width:100,height:100));let e=v.emulator!
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
}}
"""
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp); (tmp / 'check.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-default-isolation', 'MainActor', str(root / 'LightTouchMac/UI/GuestKeyboard.swift'),
                    str(tmp / 'check.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check')], check=True, timeout=60)
