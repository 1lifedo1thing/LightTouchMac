#!/usr/bin/env python3
"""Show File System in Finder and Start (DeviceFilesystemEdits) against a fake firmwarekit.

Compiles the real DeviceFilesystemEdits.swift with stubs for the device record, the session host and FirmwareTool
(which answers like firmwarekit: edit begin writes work/edit.json, commit and discard remove it; mount and unmount
for the read-only view). Checks:
- while an operation runs, the device's activity says so ("Reading the file system…") and Start is held;
- an edit left open in Finder (phase editing) doesn't hold Start: Start saves or discards it first (release), and
  then nothing holds it; an edit stuck mid-commit still does;
- a read-only view (a board without stopped edits) is detached by release, and doesn't hold Start either.
"""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[2]

stubs = r'''
import Cocoa
enum DeviceAction { case start, openFilesystem, commitFilesystem, discardFilesystem, recoverFilesystem }
enum DeviceToolsError: Error { case failed(String) }
enum FirmwareCatalog { struct Entry { let id: String } }
struct DeviceInstance {
    struct Paths { let directory: URL; var work: URL { directory.appendingPathComponent("work") } }
    let id = UUID()
    let board: String
    let paths: Paths
}
final class DeviceLibrary {
    static let didChangeNotification = Notification.Name("lib")
    func reload() {}
}
@MainActor final class DeviceSessionHost {
    let library = DeviceLibrary()
    var device: DeviceInstance!
    func instance(for entry: FirmwareCatalog.Entry) -> DeviceInstance? { device }
    func releaseStopped(for entry: FirmwareCatalog.Entry) async -> Bool { true }
}
enum FirmwareJobs { static var preparer: URL? = URL(fileURLWithPath: "/usr/bin/true") }
/// firmwarekit's answers; `gate` holds an operation until the check lets it go.
@MainActor enum FirmwareTool {
    static var calls: [String] = []
    static var gate: CheckedContinuation<Void, Never>?
    static var holdNext = false
    static func run(_ arguments: [String], executable: URL) async throws -> Data {
        calls.append(arguments.joined(separator: " "))
        if holdNext { holdNext = false; await withCheckedContinuation { gate = $0 } }
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).map { arguments[$0 + 1] } }
        let work = value("--device").map { URL(fileURLWithPath: $0).appendingPathComponent("work") }
        let session = "6F8B1C8E-2D8E-4F0E-9C1A-3A3B0E7F5D11"
        switch (arguments[0], value("--action")) {
        case ("edit", "begin"?):
            try FileManager.default.createDirectory(at: work!, withIntermediateDirectories: true)
            try Data(#"{"id":"\#(session)","phase":"editing"}"#.utf8).write(to: work!.appendingPathComponent("edit.json"))
            return Data(#"{"id":"\#(session)"}"#.utf8)
        case ("edit", "mount"?): return Data(#"{"id":"\#(session)"}"#.utf8)
        case ("edit", "commit"?), ("edit", "discard"?):
            try FileManager.default.removeItem(at: work!.appendingPathComponent("edit.json"))
            return Data("{}".utf8)
        case ("mount", _):
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: value("--out")!), withIntermediateDirectories: true)
            return Data(#"{"volume":"system"}"#.utf8)
        case ("unmount", _):
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: value("--out")!))
            return Data("{}".utf8)
        default: return Data("{}".utf8)
        }
    }
}
'''

check = r'''
import Cocoa
@main struct Check {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let edits = DeviceFilesystemEdits.shared
        let host = DeviceSessionHost()
        let entry = FirmwareCatalog.Entry(id: "n72ap-7E18")
        func settle() async { for _ in 0..<20 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) } }

        // An editable board (the N72): open, held while it runs, then an open edit that Start resolves.
        let ipod = DeviceInstance(board: "n72ap", paths: .init(directory: dir.appendingPathComponent("ipod")))
        try FileManager.default.createDirectory(at: ipod.paths.work, withIntermediateDirectories: true)
        host.device = ipod
        precondition(!edits.blocksStart(ipod), "a fresh device is held")
        FirmwareTool.holdNext = true
        edits.perform(.openFilesystem, entry: entry, host: host)
        await settle()
        precondition(edits.activity[ipod.id] == "Reading the file system…" && edits.blocksStart(ipod), "no activity while reading: \(edits.activity)")
        FirmwareTool.gate?.resume(); FirmwareTool.gate = nil
        await settle()
        precondition(edits.activity[ipod.id] == nil, "activity left behind: \(edits.activity)")
        precondition(edits.hasOpenEdit(ipod) && !edits.blocksStart(ipod), "an edit open in Finder holds Start")
        try await edits.release(ipod, entry: entry, host: host, commit: true)
        precondition(FirmwareTool.calls.last!.contains("--action commit") && !edits.hasOpenEdit(ipod) && !edits.blocksStart(ipod),
                     "Save and Start didn't commit: \(FirmwareTool.calls)")
        // Discard and Start.
        edits.perform(.openFilesystem, entry: entry, host: host)
        await settle()
        try await edits.release(ipod, entry: entry, host: host, commit: false)
        precondition(FirmwareTool.calls.last!.contains("--action discard") && !edits.blocksStart(ipod), "Discard and Start: \(FirmwareTool.calls)")
        // An edit stuck mid-commit holds Start (Finish Filesystem Recovery is the way out).
        try Data(#"{"id":"6F8B1C8E-2D8E-4F0E-9C1A-3A3B0E7F5D11","phase":"committing"}"#.utf8).write(to: ipod.paths.work.appendingPathComponent("edit.json"))
        precondition(edits.blocksStart(ipod) && !edits.hasOpenEdit(ipod), "a half-committed edit lets Start through")
        try FileManager.default.removeItem(at: ipod.paths.work.appendingPathComponent("edit.json"))

        // A read-only view (the iPhone 4): it never holds Start, and Start detaches it.
        let phone = DeviceInstance(board: "n90ap", paths: .init(directory: dir.appendingPathComponent("phone")))
        try FileManager.default.createDirectory(at: phone.paths.work, withIntermediateDirectories: true)
        host.device = phone
        edits.perform(.openFilesystem, entry: entry, host: host)
        await settle()
        let view = FileManager.default.temporaryDirectory.appendingPathComponent("LightTouch-files-\(phone.id.uuidString)")
        precondition(FileManager.default.fileExists(atPath: view.path) && !edits.blocksStart(phone), "no read-only view, or it holds Start")
        try await edits.release(phone, entry: entry, host: host, commit: nil)
        precondition(!FileManager.default.fileExists(atPath: view.path) && FirmwareTool.calls.last!.hasPrefix("unmount"), "Start left the view attached")
        print("PASS: activity while reading, Start held only while busy or mid-commit, an open edit saved or discarded before Start, the read-only view detached")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-fs-edits-') as tmp:
    tmp = Path(tmp)
    (tmp / 'stubs.swift').write_text(stubs)
    (tmp / 'main.swift').write_text(check)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(tmp / 'modules'),
                    str(root / 'LightTouchMac/Library/DeviceFilesystemEdits.swift'), str(tmp / 'stubs.swift'), str(tmp / 'main.swift'),
                    '-o', str(tmp / 'check')], check=True)
    (tmp / 'devices').mkdir()
    subprocess.run([str(tmp / 'check'), str(tmp / 'devices')], check=True, timeout=60)
