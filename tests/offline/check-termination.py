#!/usr/bin/env python3
"""Quit through a real NSApplication: App/QuitRequest.swift and QuitCoordinator (LightTouchCore) compiled whole,
wired the way AppDelegate wires them, against a stand-in device whose halt completes later, at once, or never.

No user app or guest is opened. Desktop access is needed for AppKit's real modal run loop. The failing old
main-queue entry is demonstrated in a child process with a timeout; all fixed paths must terminate normally.
The ladder itself (holds, questions, one reply, the budget) is QuitCoordinatorTests'.
"""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
source=r'''import AppKit
@MainActor let mode=CommandLine.arguments[1]
func logEvent(_ s:String){print(s);fflush(stdout)}
@MainActor final class EmulatorController {
 var requests=0
 func halt(completion:@escaping(Bool)->Void){
  requests+=1;logEvent("shutdown-started")
  if mode=="backstop"{return}
  if mode=="synchronous"{completion(true);return}
  Task {
   logEvent("shutdown-task-began")
   try? await Task.sleep(for:.milliseconds(100))
   logEvent("shutdown-task-finished");completion(true)
  }
 }
}
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
 private var emulators=[EmulatorController()]
 private let quitting=QuitCoordinator(budget:0.25){ NSApp.reply(toApplicationShouldTerminate:true) }
 static func requestTermination(){ QuitRequest.post { (NSApp.delegate as? AppDelegate)?.quitting.awaitingTermination == true } }
 func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
  switch quitting.shouldTerminate(erasing:false,finishRecording:{false},preparing:0,confirmPreparation:{_ in true},hasDevices:true,
                                  changesInProgress:false,confirmChanges:{true},cancelChanges:{},
                                  running:emulators.map { emulator in { done in emulator.halt { _ in done() } } }) {
  case .now: return .terminateNow
  case .cancel: return .terminateCancel
  case .later: return .terminateLater
  }
 }
 func applicationDidFinishLaunching(_ notification:Notification){
  logEvent("launched")
  if mode=="system-entry" {
   let timer=Timer(timeInterval:0.01,repeats:false){_ in
    MainActor.assumeIsolated{NSApp.terminate(nil)}
   };RunLoop.main.add(timer,forMode:.common)
  } else {
   DispatchQueue.main.async {
    if mode=="old-entry" {NSApp.terminate(nil)} else {
     Self.requestTermination()
     if mode=="repeated" {
      Self.requestTermination()
      DispatchQueue.main.asyncAfter(deadline:.now()+0.02){Self.requestTermination()}
     }
    }
   }
  }
 }
 func applicationWillTerminate(_ notification:Notification){
  quitting.willTerminate()
  precondition(emulators[0].requests==1)
  logEvent("terminated-once")
 }
}
@main struct Main {
 @MainActor static func main(){
  let app=NSApplication.shared, delegate=AppDelegate()
  app.delegate=delegate;app.setActivationPolicy(.prohibited);app.run()
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-quit-') as d:
 p=Path(d)/'check.swift';p.write_text(source)
 binary=d+'/check'
 subprocess.run(['swiftc','-parse-as-library','-swift-version','5','-default-isolation','MainActor','-module-cache-path',d+'/modules',
                 str(root/'LightTouchMac/App/QuitRequest.swift'),str(root/'LightTouchMac/App/QuitCoordinator.swift'),str(p),'-o',binary],check=True)
 for mode in ['normal','repeated','synchronous','backstop','system-entry']:
  result=subprocess.run([binary,mode],capture_output=True,text=True,timeout=4)
  assert result.returncode==0 and 'terminated-once' in result.stdout,(mode,result.returncode,result.stdout,result.stderr)
  if mode in ['normal','system-entry']:assert 'shutdown-task-finished' in result.stdout
  if mode=='backstop':assert 'did not finish in time' in result.stdout
 # This confirms the cause, rather than merely asserting source patterns.
 try:
  result=subprocess.run([binary,'old-entry'],capture_output=True,text=True,timeout=1)
 except subprocess.TimeoutExpired as failure:
  output=failure.stdout or b''
  assert b'shutdown-started' in output and b'shutdown-task-began' not in output,output
 else:
  # Newer AppKit may fix this queue-reentrancy behavior; accepting a clean
  # completion keeps the test useful without encoding an OS bug forever.
  assert result.returncode==0 and 'terminated-once' in result.stdout,result
 print('PASS: real AppKit Quit from main queue, repeated Quit, synchronous completion, bounded fallback and native system-style entry')
