import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// Show File System and Start (DeviceFilesystemEdits) against a firmwarekit stand-in that answers like the real one:
/// `edit --action begin` writes work/edit.json, commit and discard remove it; mount and unmount for the read-only
/// view; a device marked unclean fails as a 1.x FTL not shut down cleanly. It logs every call, and holds one call
/// until the test lets it go.
@MainActor struct DeviceFilesystemEditsTests {
    let session = "6F8B1C8E-2D8E-4F0E-9C1A-3A3B0E7F5D11"

    func firmwarekit(_ dir: URL) throws -> URL {
        try LibraryFixtures.script(
            dir.appendingPathComponent("firmwarekit"),
            """
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

            """
        )
    }

    func device(_ board: String, state: URL) throws -> DeviceInstance {
        let id = UUID()
        let prefix = "Devices/\(id.uuidString)"
        let instance = DeviceInstance(
            id: id,
            name: board,
            board: board,
            firmware: "\(board)-fixture",
            created: DeviceInstance.now,
            base: .init(kind: .prepared, path: prefix + "/base"),
            storage: .init(
                key: "k",
                overlay: prefix + "/overlay",
                snapshot: prefix + "/snapshot",
                usbmuxConf: prefix + "/usbmuxd-conf"
            )
        )
        try FileManager.default.createDirectory(
            at: DeviceInstance.directory(id, state: state).appendingPathComponent("work"),
            withIntermediateDirectories: true
        )
        return instance
    }

    func settle() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    /// Until `done` or 10 s.
    func wait(_ done: () -> Bool) async {
        for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func startIsHeldOnlyWhileBusyOrMidCommit() async throws {
        try await LibraryFixtures.withScratch { dir in
            let state = dir.appendingPathComponent("state")
            let fm = FileManager.default
            let fk = try firmwarekit(dir)
            var opened: [URL] = []
            var errors: [String] = []
            let edits = DeviceFilesystemEdits(
                preparer: fk,
                state: state,
                logs: dir.appendingPathComponent("logs"),
                open: { opened.append($0) },
                presentError: { errors.append("\($0)") }
            )
            let library = DeviceLibrary(state: state)
            let catalog = try FirmwareCatalog.load(from: LibraryFixtures.shippedCatalog)
            let entry = try #require(catalog.entry(id: "n72ap-7E18"))
            let oldEntry = try #require(catalog.entries.first { $0.board == "m68ap" })
            func calls() -> [String] {
                ((try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(
                    separator: "\n"
                ).map(String.init)
            }
            func work(_ i: DeviceInstance) -> URL {
                DeviceInstance.directory(i.id, state: state).appendingPathComponent("work")
            }

            // An editable board (the N72): reading holds Start; an edit open in Finder doesn't; Start saves or discards it.
            let ipod = try device("n72ap", state: state)
            #expect(!edits.blocksStart(ipod), "a fresh device is held")
            fm.createFile(atPath: dir.appendingPathComponent("hold").path, contents: nil)
            edits.perform(.openFilesystem, entry: entry, instance: ipod, library: library, releaseStopped: { true })
            await wait { calls().count == 1 }
            #expect(
                edits.activity[ipod.id] == "Preparing to mount the file system…" && edits.blocksStart(ipod),
                "no activity while reading: \(edits.activity)"
            )
            fm.createFile(atPath: dir.appendingPathComponent("gate").path, contents: nil)
            await wait { edits.activity[ipod.id] == nil }
            #expect(edits.activity[ipod.id] == nil, "activity left behind")
            #expect(edits.hasOpenEdit(ipod) && !edits.blocksStart(ipod), "an edit open in Finder holds Start")
            try await edits.release(ipod, library: library, commit: true)
            #expect(
                calls().last?.contains("--action commit") == true && !edits.hasOpenEdit(ipod)
                    && !edits.blocksStart(ipod),
                "Save and Start didn't commit: \(calls())"
            )
            edits.perform(.openFilesystem, entry: entry, instance: ipod, library: library, releaseStopped: { true })
            await wait { edits.activity[ipod.id] == nil && edits.hasOpenEdit(ipod) }
            try await edits.release(ipod, library: library, commit: false)
            #expect(
                calls().last?.contains("--action discard") == true && !edits.blocksStart(ipod),
                "Discard and Start: \(calls())"
            )
            // An edit stuck mid-commit holds Start (Finish Filesystem Recovery is the way out).
            try Data(#"{"id":"\#(session)","phase":"committing"}"#.utf8).write(
                to: work(ipod).appendingPathComponent("edit.json")
            )
            #expect(edits.blocksStart(ipod) && !edits.hasOpenEdit(ipod), "a half-committed edit lets Start through")
            try fm.removeItem(at: work(ipod).appendingPathComponent("edit.json"))

            // A read-only view (the iPhone 4): never holds Start, and Start detaches it.
            let phone = try device("n90ap", state: state)
            edits.perform(.openFilesystem, entry: entry, instance: phone, library: library, releaseStopped: { true })
            let view = fm.temporaryDirectory.appendingPathComponent("LightTouch-files-\(phone.id.uuidString)")
            await wait { edits.activity[phone.id] == nil && fm.fileExists(atPath: view.path) }
            #expect(
                fm.fileExists(atPath: view.path) && !edits.blocksStart(phone),
                "no read-only view, or it holds Start"
            )
            try await edits.release(phone, library: library, commit: nil)
            #expect(
                !fm.fileExists(atPath: view.path) && calls().last?.hasPrefix("unmount") == true,
                "Start left the view attached"
            )

            // A running device isn't opened.
            let before = calls().count
            edits.perform(.openFilesystem, entry: entry, instance: ipod, library: library, releaseStopped: { false })
            await wait { edits.activity[ipod.id] == nil }
            #expect(calls().count == before && errors.count == 1, "opened while running: \(calls())")

            // A 1.x device stopped without shutting down: no raw error, the offer to shut it down first.
            let old = try device("m68ap", state: state)
            fm.createFile(
                atPath: DeviceInstance.directory(old.id, state: state).appendingPathComponent("unclean").path,
                contents: nil
            )
            var offered: [String] = []
            edits.onUncleanShutdown = { offered.append($0.id) }
            edits.perform(.openFilesystem, entry: oldEntry, instance: old, library: library, releaseStopped: { true })
            await wait { edits.activity.isEmpty && !offered.isEmpty }
            #expect(
                offered == [oldEntry.id] && edits.activity.isEmpty && errors.count == 1,
                "unclean 1.x: offered \(offered), errors \(errors)"
            )
            // Each view opens one folder: the edit's mount point, the read-only view's one tree (system with data on it).
            #expect(
                Set(opened) == [
                    edits.mountPoint(ipod),
                    view.appendingPathComponent(phone.profile!.marketingName, isDirectory: true),
                ],
                "opened \(opened)"
            )
            #expect(
                calls().contains {
                    $0.contains("--action mount") && $0.contains("--mount-point \(edits.mountPoint(ipod).path)")
                }
            )
            #expect(calls().contains { $0.hasPrefix("mount ") && $0.contains("--root ") })
        }
    }

    /// Quit detaches the read-only views this run attached and touches nothing else: no listing of the temporary
    /// directory (seconds on a $TMPDIR of 100,000 entries), no unmount of another run's folder, nothing at all with
    /// no view open.
    @Test func quitDetachesOnlyTheViewsThisRunAttached() async throws {
        try await LibraryFixtures.withScratch { dir in
            let state = dir.appendingPathComponent("state")
            let fm = FileManager.default
            let edits = DeviceFilesystemEdits(
                preparer: try firmwarekit(dir),
                state: state,
                logs: dir.appendingPathComponent("logs"),
                open: { _ in },
                presentError: { _ in }
            )
            let library = DeviceLibrary(state: state)
            let entry = try #require(
                try FirmwareCatalog.load(from: LibraryFixtures.shippedCatalog).entry(id: "n72ap-7E18")
            )
            func calls() -> [String] {
                ((try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(
                    separator: "\n"
                ).map(String.init)
            }
            let stray = fm.temporaryDirectory.appendingPathComponent("LightTouch-files-\(UUID().uuidString)")
            try fm.createDirectory(at: stray, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stray) }

            edits.endAllBrowsing()
            #expect(calls().isEmpty, "quit with no view open ran \(calls())")

            let phone = try device("n90ap", state: state)
            edits.perform(.openFilesystem, entry: entry, instance: phone, library: library, releaseStopped: { true })
            let view = fm.temporaryDirectory.appendingPathComponent("LightTouch-files-\(phone.id.uuidString)")
            await wait { edits.activity[phone.id] == nil && fm.fileExists(atPath: view.path) }
            edits.endAllBrowsing()
            #expect(
                calls().filter { $0.hasPrefix("unmount") } == ["unmount --out \(view.path)"],
                "quit's unmounts: \(calls())"
            )
            #expect(
                !fm.fileExists(atPath: view.path) && fm.fileExists(atPath: stray.path),
                "the view stayed, or another run's folder went"
            )
        }
    }

    /// The edit's volume mounted, then unmounted from outside (Eject in Finder): that saves it, as Save Changes does.
    /// An edit already unmounted when watching starts (after a restart of the Mac) is left for the user.
    @Test func ejectingTheMountedEditSavesIt() async throws {
        try await LibraryFixtures.withScratch { dir in
            let state = dir.appendingPathComponent("state")
            let fk = try firmwarekit(dir)
            var mounted = false
            var errors: [String] = []
            let edits = DeviceFilesystemEdits(
                preparer: fk,
                state: state,
                logs: dir.appendingPathComponent("logs"),
                open: { _ in },
                presentError: { errors.append("\($0)") },
                isMounted: { _ in mounted },
                isWriting: { _ in false },
                poll: .milliseconds(20)
            )
            let library = DeviceLibrary(state: state)
            let entry = try #require(
                try FirmwareCatalog.load(from: LibraryFixtures.shippedCatalog).entry(id: "n72ap-7E18")
            )
            func calls() -> [String] {
                ((try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(
                    separator: "\n"
                ).map(String.init)
            }

            let ipod = try device("n72ap", state: state)
            edits.perform(
                .openFilesystem,
                entry: entry,
                instance: ipod,
                library: library,
                releaseStopped: {
                    mounted = true
                    return true
                }
            )
            await wait { edits.activity[ipod.id] == nil && edits.hasOpenEdit(ipod) }
            try await Task.sleep(for: .milliseconds(100))
            #expect(
                edits.hasOpenEdit(ipod) && !calls().contains { $0.contains("--action commit") },
                "saved while still mounted: \(calls())"
            )
            mounted = false
            await wait { !edits.hasOpenEdit(ipod) && edits.activity[ipod.id] == nil }
            #expect(
                calls().last?.contains("--action commit") == true && errors.isEmpty,
                "Eject didn't save: \(calls()) \(errors)"
            )

            // Found unmounted: no save until the user chooses.
            let other = try device("n72ap", state: state)
            edits.perform(.openFilesystem, entry: entry, instance: other, library: library, releaseStopped: { true })
            await wait { edits.activity[other.id] == nil && edits.hasOpenEdit(other) }
            edits.watch(other, library: library)
            try await Task.sleep(for: .milliseconds(150))
            #expect(edits.hasOpenEdit(other), "an edit found unmounted was saved without asking")
            try await edits.release(other, library: library, commit: false)
        }
    }

    /// Start with the edit mounted (Save and Start): nothing is saved while a copy is still writing into the volume.
    @Test func savingWaitsForCopiesInProgress() async throws {
        try await LibraryFixtures.withScratch { dir in
            let state = dir.appendingPathComponent("state")
            let fk = try firmwarekit(dir)
            var writing = true
            let edits = DeviceFilesystemEdits(
                preparer: fk,
                state: state,
                logs: dir.appendingPathComponent("logs"),
                open: { _ in },
                presentError: { _ in },
                isMounted: { _ in true },
                isWriting: { _ in writing },
                poll: .milliseconds(20)
            )
            let library = DeviceLibrary(state: state)
            let entry = try #require(
                try FirmwareCatalog.load(from: LibraryFixtures.shippedCatalog).entry(id: "n72ap-7E18")
            )
            func calls() -> [String] {
                ((try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(
                    separator: "\n"
                ).map(String.init)
            }

            let ipod = try device("n72ap", state: state)
            edits.perform(.openFilesystem, entry: entry, instance: ipod, library: library, releaseStopped: { true })
            await wait { edits.activity[ipod.id] == nil && edits.hasOpenEdit(ipod) }
            let start = Task { try await edits.release(ipod, library: library, commit: true) }
            try await Task.sleep(for: .milliseconds(200))
            #expect(
                edits.activity[ipod.id] == "Waiting for copies to finish…"
                    && !calls().contains { $0.contains("--action commit") },
                "saved during a copy: \(calls()) \(edits.activity)"
            )
            writing = false
            try await start.value
            #expect(calls().last?.contains("--action commit") == true && !edits.hasOpenEdit(ipod), "\(calls())")
        }
    }

    /// The default probes on a real volume mounted the way an edit is (nobrowse, in the temporary directory, whose
    /// /private/var/folders the mount table names): it is a mount point, and a file held open for writing is a copy
    /// in progress until it is closed.
    @Test func theMountAndWriteProbesOnARealVolume() async throws {
        try await LibraryFixtures.withScratch { dir in
            func run(_ tool: String, _ args: [String]) throws -> String {
                let p = Process()
                let pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: tool)
                p.arguments = args
                p.standardOutput = pipe
                p.standardError = pipe
                try p.run()
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                guard p.terminationStatus == 0 else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: out])
                }
                return out
            }
            let image = dir.appendingPathComponent("v.img")
            #expect(
                FileManager.default.createFile(atPath: image.path, contents: nil) && truncate(image.path, 8 << 20) == 0
            )
            let dev =
                try run(
                    "/usr/bin/hdiutil",
                    ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", "-nobrowse", image.path]
                )
                .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            defer { _ = try? run("/usr/bin/hdiutil", ["detach", dev, "-force"]) }
            _ = try run("/sbin/newfs_hfs", ["-v", "probe", dev])
            let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent(
                "LightTouch-edit-test-\(UUID().uuidString)/probe"
            )
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            defer {
                rmdir(mountPoint.path)
                rmdir(mountPoint.deletingLastPathComponent().path)
            }
            #expect(!DeviceFilesystemEdits.isMountPoint(mountPoint))
            _ = try run(
                "/usr/sbin/diskutil",
                ["mount", "-mountOptions", "nobrowse,noowners", "-mountPoint", mountPoint.path, dev]
            )
            #expect(
                DeviceFilesystemEdits.isMountPoint(mountPoint),
                "a volume mounted in the temporary directory isn't seen"
            )
            #expect(await !DeviceFilesystemEdits.isBeingWritten(mountPoint))
            let file = mountPoint.appendingPathComponent("copy.bin")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: Data(count: 4096))
            #expect(
                await DeviceFilesystemEdits.isBeingWritten(mountPoint),
                "a file open for writing isn't a copy in progress"
            )
            try handle.close()
            #expect(await !DeviceFilesystemEdits.isBeingWritten(mountPoint))
            _ = try run("/usr/sbin/diskutil", ["unmount", dev])
            #expect(!DeviceFilesystemEdits.isMountPoint(mountPoint))
        }
    }
}
