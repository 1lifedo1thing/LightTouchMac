import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// Stop is a hard halt, never a guest shutdown; Shut Down asks the guest and waits for it to power off, gives up
/// after its budget, and Force Stop can take over while it waits.
struct ShutdownLadderTests {
    func session(_ directory: URL, state: VMState = .booting) -> FakeSession {
        let s = FakeSession(directory: directory)
        s.state = state
        s.ladder.budgets.halt = 0.3
        s.ladder.budgets.serviceTeardown = 0.3
        s.ladder.budgets.shutdown = 0.5
        return s
    }
    func halt(_ s: FakeSession) async -> Bool { await s.ladder.halt().value }

    @Test func stopMidBootHaltsAtOnceAndJoinsRequests() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.bootScope[.readiness] = Task { try? await Task.sleep(for: .seconds(60)) }
            let readiness = c.bootScope[.readiness]
            #expect(c.ladder.canStop)
            let started = Date()
            let first = c.ladder.halt()
            let second = c.ladder.halt()
            #expect(c.shuttingDown && c.halting && !c.ladder.canStop && readiness?.isCancelled == true)
            #expect(c.steps == ["retire"])
            let results = [await first.value, await second.value]
            #expect(results == [true, true] && c.fakeHelper!.terms == 1 && c.fakeHelper!.kills == 0 && !c.shuttingDown)
            #expect(Date().timeIntervalSince(started) < 1, "a halt never waits on the guest")
            #expect(c.link.commands.isEmpty, "no guest shutdown asked")
        }
    }

    @Test func aHungHelperIsKilledAndAGoneOneIsAlreadyStopped() async throws {
        try await withScratchDirectory { directory in
            let hung = session(directory)
            hung.fakeHelper!.hung = true
            #expect(await halt(hung) && hung.fakeHelper!.kills == 1)

            let gone = session(directory)
            gone.fakeHelper!.isDead = true
            let goneHalt = gone.ladder.halt()
            #expect(gone.fakeHelper!.terms == 0 && !gone.shuttingDown)
            #expect(await goneHalt.value)
            let off = session(directory, state: .poweredOff)
            #expect(await off.ladder.halt().value && off.fakeHelper!.terms == 0)
        }
    }

    @Test func meddledFilesQuitWithoutAFlush() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.filesMeddled = true
            c.link.onCommand = { if case .machine(.quit) = $0 { c.fakeHelper!.exit() } }
            #expect(await halt(c))
            #expect(c.link.commands == [.machine(.quit)] && c.fakeHelper!.terms == 0 && c.fakeHelper!.kills == 0)
        }
    }

    @Test func aStuckServicesWorkerCantHoldStop() async throws {
        try await withScratchDirectory { directory in
            let stuck = session(directory)
            stuck.hangWorker = true
            let started = Date()
            #expect(await halt(stuck))
            #expect(stuck.fakeHelper!.terms == 1 && !stuck.shuttingDown && Date().timeIntervalSince(started) < 2)
            let stuckHung = session(directory)
            stuckHung.hangWorker = true
            stuckHung.fakeHelper!.hung = true
            #expect(await halt(stuckHung) && stuckHung.fakeHelper!.kills == 1, "the kill doesn't wait on the worker")
        }
    }

    @Test func shutDownAsksTheGuestAndWaitsForItToPowerOff() async throws {
        try await withScratchDirectory { directory in
            let clean = session(directory, state: .running)
            #expect(clean.ladder.canShutDown)
            var shutdown: Task<Bool, Never>?
            #expect(
                observes({ _ = clean.ladder.shuttingDown }) { shutdown = clean.ladder.shutDown() },
                "the window's Shutting down… follows"
            )
            var result: Bool?
            Task { result = await shutdown?.value }
            #expect(clean.link.commands == [.machine(.shutdown)] && clean.steps == ["willStop"])
            #expect(
                clean.shuttingDown && clean.ladder.isShuttingDownCleanly && !clean.ladder.canShutDown
                    && clean.ladder.canForceStop
            )
            try await Task.sleep(for: .milliseconds(100))
            #expect(result == nil, "finished before the guest powered off")
            clean.state = .poweredOff
            await eventually("shut down finished") { result != nil }
            #expect(result == true && !clean.shuttingDown && clean.fakeHelper!.terms == 0, "the helper stays")
        }
    }

    @Test func aGuestThatNeverPowersOffIsLeftRunning() async throws {
        try await withScratchDirectory { directory in
            let stubborn = session(directory, state: .running)
            let gaveUp = await stubborn.ladder.shutDown().value
            #expect(!gaveUp && !stubborn.shuttingDown && stubborn.state == .running && stubborn.ladder.canShutDown)
            // Not running, storage failed, or the helper gone: no Shut Down.
            for change: (FakeSession) -> Void in [
                { $0.state = .booting }, { $0.storageFailed = true }, { $0.fakeHelper!.isDead = true },
                { $0.isErasing = true },
            ] {
                let s = session(directory, state: .running)
                change(s)
                let refused = s.ladder.shutDown()
                #expect(s.link.commands.isEmpty)
                #expect(await !refused.value)
            }
        }
    }

    @Test func forceStopTakesOverAShutDown() async throws {
        try await withScratchDirectory { directory in
            let forced = session(directory, state: .running)
            let shutDown = forced.ladder.shutDown()
            #expect(!forced.ladder.canStop && forced.ladder.canForceStop)
            let halted = await forced.ladder.forceStop().value
            #expect(await shutDown.value, "the shut down ends, stopped")
            #expect(halted && forced.fakeHelper!.terms == 1 && !forced.shuttingDown)
            #expect(forced.steps.filter { $0 == "willStop" }.count == 2)

            let idle = session(directory, state: .notStarted)
            let refused = idle.ladder.forceStop()
            #expect(idle.fakeHelper!.terms == 0, "nothing started, nothing to stop")
            #expect(await !refused.value)
        }
    }

    @Test func budgetsAddUpToTheQuitBackstop() {
        let budgets = ShutdownLadder.Budgets()
        #expect(budgets.halt == 10 && budgets.kill == 5 && budgets.serviceTeardown == 2)
        #expect(budgets.stop == 17)
    }
}
