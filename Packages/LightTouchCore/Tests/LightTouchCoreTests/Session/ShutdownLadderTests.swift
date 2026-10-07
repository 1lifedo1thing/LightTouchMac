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
    func halt(_ s: FakeSession) async -> Bool {
        await withCheckedContinuation { done in s.ladder.halt { done.resume(returning: $0) } }
    }

    @Test func stopMidBootHaltsAtOnceAndJoinsRequests() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.bootScope[.readiness] = Task { try? await Task.sleep(for: .seconds(60)) }
            let readiness = c.bootScope[.readiness]
            #expect(c.ladder.canStop)
            var results: [Bool] = []
            let started = Date()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                c.ladder.halt {
                    results.append($0)
                    if results.count == 2 { done.resume() }
                }
                c.ladder.halt {
                    results.append($0)
                    if results.count == 2 { done.resume() }
                }
                #expect(c.shuttingDown && c.halting && !c.ladder.canStop && readiness?.isCancelled == true)
                #expect(c.steps == ["retire"])
            }
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
            var result: Bool?
            gone.ladder.halt { result = $0 }
            #expect(result == true && gone.fakeHelper!.terms == 0 && !gone.shuttingDown)
            let off = session(directory, state: .poweredOff)
            off.ladder.halt { result = $0 }
            #expect(off.fakeHelper!.terms == 0)
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
            var result: Bool?
            #expect(
                observes({ _ = clean.ladder.shuttingDown }) { clean.ladder.shutDown { result = $0 } },
                "the window's Shutting down… follows"
            )
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
            let gaveUp = await withCheckedContinuation { done in stubborn.ladder.shutDown { done.resume(returning: $0) }
            }
            #expect(!gaveUp && !stubborn.shuttingDown && stubborn.state == .running && stubborn.ladder.canShutDown)
            // Not running, storage failed, or the helper gone: no Shut Down.
            for change: (FakeSession) -> Void in [
                { $0.state = .booting }, { $0.storageFailed = true }, { $0.fakeHelper!.isDead = true },
                { $0.isErasing = true },
            ] {
                let s = session(directory, state: .running)
                change(s)
                var result: Bool?
                s.ladder.shutDown { result = $0 }
                #expect(result == false && s.link.commands.isEmpty)
            }
        }
    }

    @Test func forceStopTakesOverAShutDown() async throws {
        try await withScratchDirectory { directory in
            let forced = session(directory, state: .running)
            var shutDown: Bool?
            forced.ladder.shutDown { shutDown = $0 }
            #expect(!forced.ladder.canStop && forced.ladder.canForceStop)
            let halted = await withCheckedContinuation { done in forced.ladder.forceStop { done.resume(returning: $0) }
            }
            await eventually("shut down ended") { shutDown != nil }
            #expect(halted && forced.fakeHelper!.terms == 1 && shutDown == true && !forced.shuttingDown)
            #expect(forced.steps.filter { $0 == "willStop" }.count == 2)

            let idle = session(directory, state: .notStarted)
            var refused: Bool?
            idle.ladder.forceStop { refused = $0 }
            #expect(refused == false && idle.fakeHelper!.terms == 0, "nothing started, nothing to stop")
        }
    }

    @Test func budgetsAddUpToTheQuitBackstop() {
        let budgets = ShutdownLadder.Budgets()
        #expect(budgets.halt == 10 && budgets.kill == 5 && budgets.serviceTeardown == 2)
        #expect(budgets.stop == 17)
    }
}
