import Foundation
import Testing
import HostServiceWire
import HostRuntime
import DeviceRuntime
@testable import LightTouchCore

/// Restart syncs the guest's filesystem before the reset and retires the boot; a failed or stale sync resets
/// nothing; a device without guest tools halts and restarts. Power On renews the boot in place and resumes the
/// machine once the shutdown latch clears.
struct BootCycleTests {
    init() { IsolatedState.use() }

    static let freshBoot = ["publish", "reconnectUSB", "forgetConnectionWork", "forgetReachability", "timeZone", "resetRotation",
                            "foreground", "orientation", "guestPackage", "bootWatch"]

    func session(_ directory: URL) -> FakeSession {
        let s = FakeSession(directory: directory)
        s.state = .running
        return s
    }

    @Test func restartSyncsThenResetsInANewBoot() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            let old = c.bootScope.id
            c.cycle.reset()
            await c.bootScope[.reset]?.value
            #expect(c.syncs == 1 && c.link.commands == [.machine(.reset)])
            #expect(c.bootScope.id != old && !c.bootScope.retired && c.state == .booting)
            #expect(c.steps == ["retire"] + Self.freshBoot, "\(c.steps)")
            #expect(c.readiness.current != nil && c.preparingDevice, "the new boot's readiness watch")
            c.readiness.cancel()
        }
    }

    @Test func aFailedSyncResetsNothing() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.state = .booting
            c.syncFails = true
            c.cycle.reset()
            await c.bootScope[.reset]?.value
            #expect(c.link.commands.isEmpty && !c.bootScope.retired && c.steps.isEmpty)
            #expect(c.notices.message == "Couldn’t restart because the device did not finish syncing its filesystem.")
            #expect(c.readiness.current != nil, "a booting device gets its readiness watch back")
            c.readiness.cancel()
            // The next good restart resolves the notice.
            c.syncFails = false
            c.state = .running
            c.cycle.reset()
            await c.bootScope[.reset]?.value
            #expect(c.notices.message == nil && c.link.commands == [.machine(.reset)])
            c.readiness.cancel()
        }
    }

    @Test func aStaleSyncResetsNothing() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.beforeSyncReturns = { c.bootScope.retire() }
            c.cycle.reset()
            await c.bootScope[.reset]?.value
            await Task.yield()
            #expect(c.link.commands.isEmpty && c.notices.message == nil && c.steps.isEmpty)
        }
    }

    @Test func noGuestToolsHaltsAndRestarts() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.hasGuestTools = false
            var restarted = false
            c.onRestart = { restarted = true }
            c.cycle.reset()
            await eventually("restart requested") { restarted }
            #expect(c.syncs == 0 && c.link.commands.isEmpty && c.fakeHelper!.terms == 1)
        }
    }

    @Test func restartWaitsForTheBootsPreparationAndSkipsStoppedDevices() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.readiness.start()
            let preparation = c.readiness.current
            c.cycle.reset()
            #expect(preparation?.isCancelled == true, "the readiness watch is cancelled before the sync")
            await c.bootScope[.reset]?.value
            #expect(c.syncs == 1)
            c.readiness.cancel()

            let failed = session(directory); failed.storageFailed = true
            failed.cycle.reset()
            #expect(failed.bootScope[.reset] == nil)
            let off = session(directory); off.state = .poweredOff; off.fakeHelper!.isDead = true
            off.cycle.reset()
            #expect(off.steps == ["restart"], "a halted device restarts with a fresh helper")
        }
    }

    @Test func powerOnRenewsTheBootAndResumesOnceTheLatchClears() async throws {
        try await withScratchDirectory { directory in
            let cold = session(directory)
            cold.state = .poweredOff
            cold.status = helperStatus(displaySleeping: true, shutdownConfirmed: true)
            cold.cycle.powerOn()
            #expect(cold.bootScope.generation == 1 && cold.cycle.poweringOn && cold.state == .booting)
            #expect(cold.steps == ["publish", "reconnectUSB", "forgetConnectionWork", "forgetGuestFacts", "forgetReachability",
                                   "forgetEthlink", "resetRotation", "timeZone"], "\(cold.steps)")
            #expect(cold.link.commands == [.machine(.reset)])
            try await Task.sleep(for: .milliseconds(100))
            #expect(cold.link.commands == [.machine(.reset)], "no resume while the latch is set")
            cold.status = helperStatus(displaySleeping: true, shutdownConfirmed: false)
            await cold.bootScope[.powerOn]?.value
            #expect(cold.link.commands == [.machine(.reset), .machine(.resume)] && !cold.cycle.poweringOn)
            #expect(Array(cold.steps.suffix(3)) == ["foreground", "guestPackage", "bootWatch"])
            // The new boot's readiness watch wakes the sleeping display once it's up.
            cold.state = .running
            await cold.readiness.current?.value
            #expect(cold.homes == 1)
        }
    }

    @Test func powerOnGivesUpWhenTheLatchStays() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.state = .poweredOff
            c.status = helperStatus(shutdownConfirmed: true)
            c.cycle.latchWait = .milliseconds(50)
            c.cycle.powerOn()
            await c.bootScope[.powerOn]?.value
            #expect(c.state == .poweredOff && !c.cycle.poweringOn && c.bootScope.retired && c.link.commands == [.machine(.reset)])

            let gone = session(directory)
            gone.state = .poweredOff
            gone.fakeHelper!.isDead = true
            gone.cycle.powerOn()
            #expect(gone.steps == ["restart"] && gone.bootScope.generation == 0)
        }
    }
}
