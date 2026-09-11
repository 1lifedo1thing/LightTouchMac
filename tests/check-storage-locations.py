#!/usr/bin/env python3
"""Exercise production state migration, log ownership and bounded native pipes.
All state and simulated Library directories are temporary fixtures.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='ltm-storage-locations-') as temporary:
    work = Path(temporary)
    daemon = work / 'Fixture.app/Contents/MacOS/usbmuxd'
    daemon.parent.mkdir(parents=True)
    import plistlib
    (daemon.parent.parent / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'gold.samhenri.LightTouchMac',
        'CFBundleExecutable': 'usbmuxd', 'CFBundlePackageType': 'APPL'}))
    helper = work / 'daemon.c'
    helper.write_text(r'''#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc > 1) {
        pid_t child = fork();
        if (child < 0) return 1;
        if (child) { printf("%d\n",child); fflush(stdout); return 0; }
        close(0); close(1); close(2);
    } else { printf("%d\n",getpid()); fflush(stdout); }
    for (;;) pause();
}
''')
    subprocess.run(['xcrun','clang',str(helper),'-o',str(daemon)],check=True)
    source = work / 'check.swift'
    source.write_text(r'''
import Foundation

@main struct Check {
    static func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    static func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    static func denied(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected a storage failure") } catch {}
    }
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let support = root.appendingPathComponent("Library/Application Support", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let legacy = support.appendingPathComponent("LightTouchMac", isDirectory: true)
        let destination = support.appendingPathComponent(StorageLocations.bundleIdentifier, isDirectory: true)
        let owned = ["device/base/page", "nandrw-base/cs0/page", "nandrw-base/nor.bin",
                     "snapshot-base", "snapshot-base.meta", "IPAs/com.example.app.ipa",
                     "work/usbmuxd-conf/SystemConfiguration.plist", "work/usbmuxd-conf/device.plist",
                     "web-proxy.conf.ca.pem", "web-proxy.json"]
        for name in owned { try write(name, legacy.appendingPathComponent(name)) }
        let pointer = legacy.appendingPathComponent("device/active-base.json")
        try JSONSerialization.data(withJSONObject: ["key":"base", "directory":legacy.appendingPathComponent("device/base").path]).write(to: pointer)
        try write("previous app", legacy.appendingPathComponent("app.log.1"))
        try write("current app", legacy.appendingPathComponent("app.log"))
        try write("serial boot", legacy.appendingPathComponent("serial.log"))
        try write("mux boot", legacy.appendingPathComponent("work/usbmuxd.log"))
        let inode = try fm.attributesOfItem(atPath:legacy.appendingPathComponent(owned[0]).path)[.systemFileNumber] as! NSNumber
        let layout = try StorageLocations.prepare(applicationSupport:support, library:library)
        precondition(layout.state == destination && !exists(legacy))
        precondition(layout.logs.path == library.appendingPathComponent("Logs/"+StorageLocations.bundleIdentifier).path)
        for name in owned { precondition(try text(destination.appendingPathComponent(name)) == name) }
        precondition(try fm.attributesOfItem(atPath:destination.appendingPathComponent(owned[0]).path)[.systemFileNumber] as! NSNumber == inode)
        let json = try JSONSerialization.jsonObject(with:Data(contentsOf:destination.appendingPathComponent("device/active-base.json"))) as! [String:String]
        precondition(json["directory"] == "device/base")
        precondition(!exists(destination.appendingPathComponent("app.log")))
        precondition(!exists(destination.appendingPathComponent("work/usbmuxd.log")))
        precondition(try text(layout.logs.appendingPathComponent("serial.log")) == "serial boot")
        precondition(try text(layout.logs.appendingPathComponent("usbmuxd.log")) == "mux boot")
        _ = try StorageLocations.prepare(applicationSupport:support, library:library)

        // An isolated run never examines or moves the normal user's state.
        try write("unrelated", legacy.appendingPathComponent("do-not-touch"))
        let isolated = root.appendingPathComponent("isolated")
        let isolatedLayout = try StorageLocations.prepare(applicationSupport:support, library:library, override:isolated)
        precondition(isolatedLayout.state == isolated && isolatedLayout.logs == isolated.appendingPathComponent("Logs",isDirectory:true))
        precondition(try text(legacy.appendingPathComponent("do-not-touch")) == "unrelated")
        denied { _ = try StorageLocations.prepare(applicationSupport:support, library:library) }
        precondition(try text(legacy.appendingPathComponent("do-not-touch")) == "unrelated")
        for name in owned { precondition(try text(destination.appendingPathComponent(name)) == name) }

        // Rename failure retains the complete source. Relative pointer repair
        // remains valid in the original root if publication never happens.
        let failing = root.appendingPathComponent("failing")
        try write("base", failing.appendingPathComponent("device/base/page"))
        try JSONSerialization.data(withJSONObject:["key":"base","directory":failing.appendingPathComponent("device/base").path]).write(to:failing.appendingPathComponent("device/active-base.json"))
        let blocked = root.appendingPathComponent("blocked")
        try write("keep", blocked)
        denied { try StorageLocations.migrateState(from:failing,to:blocked.appendingPathComponent("state")) }
        precondition(try text(failing.appendingPathComponent("device/base/page")) == "base")
        precondition(try text(blocked) == "keep")
        let retry = root.appendingPathComponent("retry")
        try StorageLocations.migrateState(from:failing,to:retry)
        precondition(exists(retry.appendingPathComponent("device/base/page")))

        // A malformed/external pointer fails before moving or publishing any
        // replacement state, rather than pairing an overlay with another base.
        let corrupt = root.appendingPathComponent("corrupt")
        try write("{\"key\":\"base\",\"directory\":\"/some/other/device/base\"}",corrupt.appendingPathComponent("device/active-base.json"))
        let unexpected = root.appendingPathComponent("unexpected")
        denied { try StorageLocations.migrateState(from:corrupt,to:unexpected) }
        precondition(exists(corrupt) && !exists(unexpected))

        // A live owner blocks migration; a daemon orphaned by a crash is
        // identified by uid, bundle path, parent and start time before reaping.
        let daemonURL=URL(fileURLWithPath:CommandLine.arguments[2])
        let live=Process();live.executableURL=daemonURL
        live.standardOutput=FileHandle.nullDevice
        try live.run()
        defer { if live.isRunning { live.terminate();live.waitUntilExit() } }
        let liveState=root.appendingPathComponent("live-state")
        try write("\(live.processIdentifier)\n",liveState.appendingPathComponent("work/usbmuxd.pid"))
        let liveDestination=root.appendingPathComponent("live-destination")
        denied { try StorageLocations.migrateState(from:liveState,to:liveDestination) }
        precondition(live.isRunning && exists(liveState) && !exists(liveDestination))
        live.terminate();live.waitUntilExit()
        let orphan=Process();orphan.executableURL=daemonURL;orphan.arguments=["--orphan"]
        let orphanPipe=Pipe();orphan.standardOutput=orphanPipe
        try orphan.run();orphan.waitUntilExit()
        let orphanPID=pid_t(String(decoding:orphanPipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines))!
        var orphanNeedsCleanup=true
        defer { if orphanNeedsCleanup { _=kill(orphanPID,SIGTERM) } }
        let orphanState=root.appendingPathComponent("orphan-state")
        try write("\(orphanPID)\n",orphanState.appendingPathComponent("work/usbmuxd.pid"))
        try write("paired",orphanState.appendingPathComponent("work/usbmuxd-conf/device.plist"))
        let orphanDestination=root.appendingPathComponent("orphan-destination")
        try StorageLocations.migrateState(from:orphanState,to:orphanDestination)
        orphanNeedsCleanup=false
        precondition(!exists(orphanState))
        precondition(try text(orphanDestination.appendingPathComponent("work/usbmuxd-conf/device.plist"))=="paired")
        let unrelatedState=root.appendingPathComponent("unrelated-state")
        try write("\(getpid())\n",unrelatedState.appendingPathComponent("work/usbmuxd.pid"))
        try StorageLocations.migrateState(from:unrelatedState,to:root.appendingPathComponent("unrelated-destination"))

        // Existing Logs collisions keep the newest two distinct bounded tails;
        // owned legacy sources disappear, pairing files do not.
        let logState = root.appendingPathComponent("log-state")
        let logs = root.appendingPathComponent("log-tests")
        try StorageLocations.privateDirectory(logs)
        let candidates = [(logState.appendingPathComponent("app.log"),"0123456789NEW",30.0),
                          (logState.appendingPathComponent("app.log.1"),"old",10.0),
                          (logs.appendingPathComponent("app.log"),"middle",20.0),
                          (logs.appendingPathComponent("app.log.1"),"oldest",1.0)]
        for (url,value,age) in candidates {
            try write(value,url)
            try fm.setAttributes([.modificationDate:Date(timeIntervalSince1970:age)],ofItemAtPath:url.path)
        }
        try StorageLocations.migrateLogs(state:logState,logs:logs,limit:8)
        precondition(try text(logs.appendingPathComponent("app.log")) == "456789NEW".suffix(8))
        precondition(try text(logs.appendingPathComponent("app.log.1")) == "middle")
        precondition(!exists(logState.appendingPathComponent("app.log")) && !exists(logState.appendingPathComponent("app.log.1")))
        let protected = root.appendingPathComponent("protected")
        try write("secret",protected)
        try write("legacy",logState.appendingPathComponent("serial.log"))
        try fm.createSymbolicLink(at:logs.appendingPathComponent("serial.log"),withDestinationURL:protected)
        denied { try StorageLocations.migrateLogs(state:logState,logs:logs) }
        precondition(try text(protected) == "secret")
        precondition(try text(logState.appendingPathComponent("serial.log")) == "legacy")

        let streamURL = logs.appendingPathComponent("stream.log")
        let capture = try ProcessLogCapture(url:streamURL)
        let writer = FileHandle(fileDescriptor:capture.writeDescriptor,closeOnDealloc:false)
        try writer.write(contentsOf:Data(repeating:65,count:2_300_000))
        capture.flush()
        for path in [streamURL,streamURL.appendingPathExtension("1")] {
            let data=try Data(contentsOf:path)
            precondition(!data.isEmpty && data.count <= StorageLocations.logLimit && data.allSatisfy{$0==65})
            precondition(try fm.attributesOfItem(atPath:path.path)[.posixPermissions] as! NSNumber == 0o600)
        }
        // The general reader must cancel after EOF instead of spinning on a
        // permanently readable closed pipe; subsequent flush/finish are safe.
        var descriptors:[Int32]=[-1,-1]
        precondition(pipe(&descriptors)==0)
        let eofLog=logs.appendingPathComponent("eof.log")
        let reader=try LogPipeReader(descriptor:descriptors[0],log:RotatingLog(url:eofLog))
        let input=FileHandle(fileDescriptor:descriptors[1],closeOnDealloc:false)
        try input.write(contentsOf:Data("EOF marker".utf8));Darwin.close(descriptors[1])
        try await Task.sleep(for:.milliseconds(30))
        reader.flush();reader.finish()
        precondition(try text(eofLog)=="EOF marker")

        let fifoRoot=root.appendingPathComponent("fifo")
        try StorageLocations.privateDirectory(fifoRoot)
        let serial=try SerialLogCapture(url:logs.appendingPathComponent("fifo.log"),temporaryRoot:fifoRoot)
        let fifo=String(serial.argument.dropFirst("pipe:".count))+".out"
        let fd=open(fifo,O_WRONLY);precondition(fd>=0)
        let fifoWriter=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        try fifoWriter.write(contentsOf:Data("guest serial".utf8));Darwin.close(fd)
        // Unlink during app stop while keeping the writer alive: subsequent
        // native writes remain safe, and normal quit leaves no FIFO names.
        let activeFD=open(fifo,O_WRONLY);precondition(activeFD>=0)
        serial.removeEndpoints()
        precondition(try fm.contentsOfDirectory(atPath:fifoRoot.path).isEmpty)
        let activeWriter=FileHandle(fileDescriptor:activeFD,closeOnDealloc:false)
        try activeWriter.write(contentsOf:Data(" after unlink".utf8));Darwin.close(activeFD)
        serial.finish()
        precondition(try fm.contentsOfDirectory(atPath:fifoRoot.path).isEmpty)
        precondition(try text(logs.appendingPathComponent("fifo.log"))=="guest serial after unlink")

        // App events enter unified logging separately, so stderr capture does
        // not duplicate them in the native file. Restore test runner stdout.
        let savedOut=dup(STDOUT_FILENO), savedErr=dup(STDERR_FILENO)
        try Bundled.requireStorage()
        try NativeLogging.start()
        fputs("native error marker\n",stderr);fputs("native output marker\n",stdout);fflush(stdout)
        logEvent("app event only marker")
        await AppEventLog.shared.flush();NativeLogging.flush()
        precondition(try text(Bundled.logsDirectory.appendingPathComponent("native.log")).contains("native error marker"))
        precondition(try text(Bundled.logsDirectory.appendingPathComponent("native.log")).contains("native output marker"))
        precondition(!(try! text(Bundled.logsDirectory.appendingPathComponent("native.log"))).contains("app event only marker"))
        precondition(try text(Bundled.logsDirectory.appendingPathComponent("app.log")).contains("app event only marker"))
        _=dup2(savedOut,STDOUT_FILENO);_=dup2(savedErr,STDERR_FILENO)
        Darwin.close(savedOut);Darwin.close(savedErr)
        print("PASS: atomic state/pointer migration, conflicts/failures/isolation, verified crash-orphan cleanup, bounded log migration/streams, EOF and FIFO cleanup, unified/native separation")
    }
}
'''.replace('precondition(try ', 'precondition(try! '))
    subprocess.run(['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor',
                    '-module-cache-path',str(work/'modules'),
                    *[str(root/'LightTouchMac'/name) for name in ['StorageLocations.swift','NativeLogging.swift','Bundled.swift','AppEventLog.swift']],
                    str(source),'-o',str(work/'check')],check=True)
    subprocess.run([str(work/'check'),str(work/'fixtures'),str(daemon)],
                   env=dict(os.environ,LTM_STATE_DIR=str(work/'isolated-app')),check=True)
