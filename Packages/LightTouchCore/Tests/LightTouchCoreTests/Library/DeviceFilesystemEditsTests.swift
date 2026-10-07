import Foundation
import Testing
@testable import LightTouchCore

/// Show File System and Start (DeviceFilesystemEdits) against a firmwarekit stand-in that answers like the real one:
/// `edit --action begin` writes work/edit.json, commit and discard remove it; mount and unmount for the read-only
/// view; a device marked unclean fails as a 1.x FTL not shut down cleanly. It logs every call, and holds one call
/// until the test lets it go.
@MainActor struct DeviceFilesystemEditsTests {
    let session = "6F8B1C8E-2D8E-4F0E-9C1A-3A3B0E7F5D11"

    func firmwarekit(_ dir: URL) throws -> URL {
        try LibraryFixtures.script(dir.appendingPathComponent("firmwarekit"), """
            D='\(dir.path)'
            echo "$*" >> "$D/calls"
            if [ -e "$D/hold" ]; then rm "$D/hold"; while [ ! -e "$D/gate" ]; do sleep 0.02; done; rm "$D/gate"; fi
            cmd=$1; shift; device=; action=; out=
            while [ $# -gt 0 ]; do case "$1" in --device) device=$2; shift;; --action) action=$2; shift;; --out) out=$2; shift;; esac; shift; done
            if [ -n "$device" ] && [ -e "$device/unclean" ]; then
                echo "unsupported: the 1.x FTL was not shut down cleanly (virtual block 3 does not end in its context); power the device off from the guest first" >&2
                exit 1
            fi
            case "$cmd:$action" in
                edit:begin) mkdir -p "$device/work"; printf '{"id":"\(session)","phase":"editing"}' > "$device/work/edit.json"; printf '{"id":"\(session)"}' ;;
                edit:mount) printf '{"id":"\(session)"}' ;;
                edit:commit|edit:discard) rm "$device/work/edit.json"; echo '{}' ;;
                mount:*) mkdir -p "$out"; echo '{"volume":"system"}' ;;
                unmount:*) rm -rf "$out"; echo '{}' ;;
                *) echo '{}' ;;
            esac

            """)
    }

    func device(_ board: String, state: URL) throws -> DeviceInstance {
        let id = UUID(), prefix = "Devices/\(id.uuidString)"
        let instance = DeviceInstance(id: id, name: board, board: board, firmware: "\(board)-fixture", created: DeviceInstance.now,
            base: .init(kind: .prepared, path: prefix + "/base"),
            storage: .init(key: "k", overlay: prefix + "/overlay", snapshot: prefix + "/snapshot", usbmuxConf: prefix + "/usbmuxd-conf"))
        try FileManager.default.createDirectory(at: DeviceInstance.directory(id, state: state).appendingPathComponent("work"),
                                                withIntermediateDirectories: true)
        return instance
    }

    func settle() async { for _ in 0..<20 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) } }
    /// Until `done` or 10 s.
    func wait(_ done: () -> Bool) async { for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(20)) } }

    @Test func startIsHeldOnlyWhileBusyOrMidCommit() async throws {
        try await LibraryFixtures.withScratch { dir in
            let state = dir.appendingPathComponent("state"), fm = FileManager.default
            let fk = try firmwarekit(dir)
            var opened: [URL] = [], errors: [String] = []
            let edits = DeviceFilesystemEdits(preparer: fk, state: state, logs: dir.appendingPathComponent("logs"),
                                              open: { opened.append($0) }, presentError: { errors.append("\($0)") })
            let library = DeviceLibrary(state: state)
            let catalog = try FirmwareCatalog.load(from: LibraryFixtures.shippedCatalog)
            let entry = try #require(catalog.entry(id: "n72ap-7E18"))
            let oldEntry = try #require(catalog.entries.first { $0.board == "m68ap" })
            func calls() -> [String] { ((try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
            func work(_ i: DeviceInstance) -> URL { DeviceInstance.directory(i.id, state: state).appendingPathComponent("work") }

            // An editable board (the N72): reading holds Start; an edit open in Finder doesn't; Start saves or discards it.
            let ipod = try device("n72ap", state: state)
            #expect(!edits.blocksStart(ipod), "a fresh device is held")
            fm.createFile(atPath: dir.appendingPathComponent("hold").path, contents: nil)
            edits.perform(.openFilesystem, entry: entry, instance: ipod, library: library, releaseStopped: { true })
            await wait { calls().count == 1 }
            #expect(edits.activity[ipod.id] == "Reading the file system…" && edits.blocksStart(ipod), "no activity while reading: \(edits.activity)")
            fm.createFile(atPath: dir.appendingPathComponent("gate").path, contents: nil)
            await wait { edits.activity[ipod.id] == nil }
            #expect(edits.activity[ipod.id] == nil, "activity left behind")
            #expect(edits.hasOpenEdit(ipod) && !edits.blocksStart(ipod), "an edit open in Finder holds Start")
            try await edits.release(ipod, library: library, commit: true)
            #expect(calls().last?.contains("--action commit") == true && !edits.hasOpenEdit(ipod) && !edits.blocksStart(ipod),
                    "Save and Start didn't commit: \(calls())")
            edits.perform(.openFilesystem, entry: entry, instance: ipod, library: library, releaseStopped: { true })
            await wait { edits.activity[ipod.id] == nil && edits.hasOpenEdit(ipod) }
            try await edits.release(ipod, library: library, commit: false)
            #expect(calls().last?.contains("--action discard") == true && !edits.blocksStart(ipod), "Discard and Start: \(calls())")
            // An edit stuck mid-commit holds Start (Finish Filesystem Recovery is the way out).
            try Data(#"{"id":"\#(session)","phase":"committing"}"#.utf8).write(to: work(ipod).appendingPathComponent("edit.json"))
            #expect(edits.blocksStart(ipod) && !edits.hasOpenEdit(ipod), "a half-committed edit lets Start through")
            try fm.removeItem(at: work(ipod).appendingPathComponent("edit.json"))

            // A read-only view (the iPhone 4): never holds Start, and Start detaches it.
            let phone = try device("n90ap", state: state)
            edits.perform(.openFilesystem, entry: entry, instance: phone, library: library, releaseStopped: { true })
            let view = fm.temporaryDirectory.appendingPathComponent("LightTouch-files-\(phone.id.uuidString)")
            await wait { edits.activity[phone.id] == nil && fm.fileExists(atPath: view.path) }
            #expect(fm.fileExists(atPath: view.path) && !edits.blocksStart(phone), "no read-only view, or it holds Start")
            try await edits.release(phone, library: library, commit: nil)
            #expect(!fm.fileExists(atPath: view.path) && calls().last?.hasPrefix("unmount") == true, "Start left the view attached")

            // A running device isn't opened.
            let before = calls().count
            edits.perform(.openFilesystem, entry: entry, instance: ipod, library: library, releaseStopped: { false })
            await wait { edits.activity[ipod.id] == nil }
            #expect(calls().count == before && errors.count == 1, "opened while running: \(calls())")

            // A 1.x device stopped without shutting down: no raw error, the offer to shut it down first.
            let old = try device("m68ap", state: state)
            fm.createFile(atPath: DeviceInstance.directory(old.id, state: state).appendingPathComponent("unclean").path, contents: nil)
            var offered: [String] = []
            edits.onUncleanShutdown = { offered.append($0.id) }
            edits.perform(.openFilesystem, entry: oldEntry, instance: old, library: library, releaseStopped: { true })
            await wait { edits.activity.isEmpty && !offered.isEmpty }
            #expect(offered == [oldEntry.id] && edits.activity.isEmpty && errors.count == 1, "unclean 1.x: offered \(offered), errors \(errors)")
            #expect(opened.isEmpty, "no mount point was reported")
        }
    }
}
