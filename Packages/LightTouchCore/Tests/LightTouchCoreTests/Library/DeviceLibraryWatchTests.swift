import CoreServices
import Foundation
import Testing

@testable import LightTouchCore

/// The library follows Devices/ as Finder and Terminal change it while the app runs, and a session whose folder
/// left stops and goes.
struct DeviceLibraryWatchTests {
    func record(_ name: String, state: URL) throws -> DeviceInstance {
        let id = UUID()
        let prefix = "Devices/\(id.uuidString)"
        let instance = DeviceInstance(
            id: id,
            name: name,
            board: "n72ap",
            firmware: "n72ap-7E18",
            created: DeviceInstance.now,
            base: .init(kind: .prepared, path: prefix + "/base"),
            storage: .init(
                key: "fixture",
                overlay: prefix + "/overlay",
                snapshot: prefix + "/snapshot",
                usbmuxConf: prefix + "/usbmuxd-conf"
            )
        )
        try instance.write(state: state)
        return instance
    }

    func ids(_ library: DeviceLibrary) -> Set<UUID> { Set(library.instances.map(\.id)) }

    @Test func aFolderMovedToTheTrashOrRemovedLeavesTheLibraryAndOnePutBackReturns() async throws {
        _ = LibraryFixtures.isolatedAppState
        try await LibraryFixtures.withScratch { scratch in
            let fm = FileManager.default
            let state = scratch.appendingPathComponent("State", isDirectory: true)
            let trash = scratch.appendingPathComponent("Trash", isDirectory: true)
            try fm.createDirectory(at: trash, withIntermediateDirectories: true)
            let a = try record("A", state: state)
            let b = try record("B", state: state)
            let library = DeviceLibrary(state: state)
            var posts = 0
            let observer = NotificationCenter.default.addObserver(
                forName: DeviceLibrary.didChangeNotification,
                object: library,
                queue: nil
            ) { _ in posts += 1 }
            defer { NotificationCenter.default.removeObserver(observer) }
            #expect(ids(library) == [a.id, b.id])

            let trashed = trash.appendingPathComponent(a.id.uuidString)
            try fm.moveItem(at: DeviceInstance.directory(a.id, state: state), to: trashed)
            await eventually("A leaves") { ids(library) == [b.id] }
            #expect(posts == 1)

            try fm.removeItem(at: DeviceInstance.directory(b.id, state: state))
            await eventually("B leaves") { ids(library).isEmpty }

            try fm.moveItem(at: trashed, to: DeviceInstance.directory(a.id, state: state))
            await eventually("A returns") { ids(library) == [a.id] }
            #expect(library.instance(id: a.id) == a)
        }
    }

    @Test func devicesRemovedWholeEmptiesTheLibraryAndOneMadeAgainIsSeen() async throws {
        _ = LibraryFixtures.isolatedAppState
        try await LibraryFixtures.withScratch { scratch in
            let state = scratch.appendingPathComponent("State", isDirectory: true)
            _ = try record("A", state: state)
            let library = DeviceLibrary(state: state)
            try FileManager.default.removeItem(at: state.appendingPathComponent("Devices"))
            await eventually("the library empties") { library.instances.isEmpty }
            let c = try record("C", state: state)
            await eventually("C appears") { ids(library) == [c.id] }
        }
    }

    /// The root, Devices/ and a device folder's own entries reload; a running device's pages and Preparing/ don't.
    @Test func onlyTheDeviceLevelsOfTheRootCount() {
        let watch = StateRootWatch(root: URL(fileURLWithPath: "/nonexistent/State")) {}
        let none = FSEventStreamEventFlags(kFSEventStreamEventFlagNone)
        for path in ["/nonexistent/State", "/nonexistent/State/Devices", "/nonexistent/State/Devices/X"] {
            #expect(watch.matters(path, none), "\(path)")
        }
        for path in [
            "/nonexistent/State/Devices/X/overlay", "/nonexistent/State/Preparing/Y", "/nonexistent/Statements",
        ] {
            #expect(!watch.matters(path, none), "\(path)")
        }
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        #expect(watch.matters("/nonexistent", dropped))
    }

    /// A started device, as the app's DeviceSession wraps its controller.
    final class Started: LibrarySession {
        let fake: FakeSession
        let instance: DeviceInstance
        var releases = 0
        var phase = SessionPhase.running
        /// A helper that won't exit, even when killed.
        var stuck = false
        init(_ instance: DeviceInstance, directory: URL) {
            self.instance = instance
            fake = FakeSession(directory: directory)
            fake.state = .running
            fake.ladder.budgets.halt = 0.3
            fake.ladder.budgets.serviceTeardown = 0.3
        }
        var ladder: ShutdownLadder { fake.ladder }
        func release() async -> Bool {
            releases += 1
            if !stuck { fake.fakeHelper?.exit() }
            return fake.fakeHelper?.isDead ?? true
        }
    }

    /// Delete and Prepare Again (state audit B-4, B-11): a shut-down or dead device's session lets go of its helper
    /// first, so its storage goes without quitting the app; one running (started again while the question was up)
    /// is refused with DeviceInUse and keeps its storage, where the host used to trap.
    @Test func deleteReleasesAShutDownOrDeadSessionAndRefusesARunningOne() async throws {
        _ = LibraryFixtures.isolatedAppState
        try await LibraryFixtures.withScratch { scratch in
            let state = scratch.appendingPathComponent("State", isDirectory: true)
            let deletions = DeviceDeletions()
            for phase in [SessionPhase.running, .stopping, .stopped, .dead("The iPod stopped.")] {
                let instance = try record("\(phase)", state: state)
                let directory = DeviceInstance.directory(instance.id, state: state)
                let session = Started(instance, directory: scratch)
                session.phase = phase
                let deletion = deletions.run(instance.firmware, release: { await session.releaseIfStopped() }) {
                    try DeviceStateStorage.removeDevice(instance.id, state: state)
                }
                let result = await deletion.result
                let exists = FileManager.default.fileExists(atPath: directory.path)
                if phase == .running || phase == .stopping {
                    #expect(throws: DeviceInUse.self, "\(phase)") { try result.get() }
                    #expect(exists && session.releases == 0, "\(phase): the storage stays, the helper runs on")
                } else {
                    #expect(throws: Never.self, "\(phase)") { try result.get() }
                    #expect(!exists && session.releases == 1, "\(phase): released, then removed")
                }
                #expect(!deletions.contains(instance.firmware))
            }
        }
    }

    @Test func aRunningDeviceWhoseFolderLeftHaltsOnceAndIsDropped() async throws {
        _ = LibraryFixtures.isolatedAppState
        try await LibraryFixtures.withScratch { scratch in
            let state = scratch.appendingPathComponent("State", isDirectory: true)
            let gone = try record("Gone", state: state)
            let kept = try record("Kept", state: state)
            let library = DeviceLibrary(state: state)
            var sessions = [Started(gone, directory: scratch), Started(kept, directory: scratch)]
            var dropped: [UUID] = []
            let vanished = VanishedDevices()
            let observer = NotificationCenter.default.addObserver(
                forName: DeviceLibrary.didChangeNotification,
                object: library,
                queue: nil
            ) { _ in
                MainActor.assumeIsolated {
                    vanished.stop(sessions, library: library) { session in
                        dropped.append(session.instance.id)
                        sessions.removeAll { $0 === session }
                    }
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            let stopping = sessions[0]

            try FileManager.default.removeItem(at: DeviceInstance.directory(gone.id, state: state))
            await eventually("the session is dropped") { dropped == [gone.id] }
            #expect(stopping.fake.fakeHelper?.terms == 1 && stopping.releases == 1)
            #expect(sessions.map(\.instance.id) == [kept.id])
            #expect(sessions[0].fake.fakeHelper?.terms == 0 && sessions[0].releases == 0)

            // Another change to the library stops nothing again.
            _ = try record("New", state: state)
            await eventually("the new device appears") { library.instances.count == 2 }
            #expect(dropped == [gone.id] && stopping.fake.fakeHelper?.terms == 1)
        }
    }
}
