// Stop, Force Stop and Shut Down.
//
// Stop is a hard halt (Sam, 2026-09-28), never a guest shutdown: a booting or wedged guest ignores those and left
// the window on "Powering off…". SIGTERM makes the helper pause the VM, which flushes storage, and quit QEMU
// (DeviceHost.halt); a helper still alive after the halt budget is killed. The guest's filesystems replay their
// journals on the next boot. The helper's exit is Stopped (BootWatch.helperDied).
//
// Shut Down: the guest powers itself off, as the slider does (qemu_ios_ui_shutdown: the guest agent's halt, or
// 1.x's power-off gesture), so its storage is left clean; the helper stays, powered off, as after the slider.

import DeviceRuntime
import Foundation
import HostRuntime
import Observation

/// What Stop and Shut Down read and do on the session.
public protocol ShutdownHost: AnyObject {
    var state: VMState { get }
    var isErasing: Bool { get }
    var storageFailed: Bool { get }
    /// Something changed the files the helper has open: a flush would write into dead inodes.
    var filesMeddled: Bool { get }
    var helper: DeviceHelper? { get }
    var helperLink: HelperLink? { get }
    var workers: WorkerRetirement { get }
    func retireBoot()
    /// Before the guest goes: queued installs are dropped and the clock sync ends.
    func willStop()
}

@Observable public final class ShutdownLadder {
    public struct Budgets {
        public init() {}
        /// SIGTERM to the kill.
        public var halt: TimeInterval = 10
        /// The kill to giving up on the exit.
        public var kill: TimeInterval = 5
        /// How long Stop waits for the services worker's teardown after the helper is gone. Retirement already
        /// cancelled the worker (its subprocess is torn down); a teardown that never finishes keeps reaping in
        /// the background, never holding Stop.
        public var serviceTeardown: TimeInterval = 2
        /// Shut Down's wait for the guest to power off.
        public var shutdown: TimeInterval = 90 * Board.hostSlowdown
        /// The quit backstop: the halt, then the kill, then the services worker.
        public var stop: TimeInterval { halt + kill + serviceTeardown }
    }

    private unowned let host: ShutdownHost
    public var budgets = Budgets()
    public init(host: ShutdownHost) { self.host = host }

    public private(set) var shuttingDown = false
    /// Stop asked the helper to halt: its exit is Stopped, not a crash.
    public private(set) var halting = false
    private var haltTask: Task<Bool, Never>?
    private var cleanShutdown: Task<Bool, Never>?

    private var isPoweredOff: Bool { host.state == .poweredOff }
    private var isDead: Bool { host.state.isDead }

    /// A live helper whose VM can be stopped, including mid-boot.
    public var canStop: Bool {
        !isDead && !isPoweredOff && !shuttingDown && !host.isErasing && host.state != .notStarted
    }
    /// Force Stop: Stop's hard halt, also while a Shut Down is under way (one the guest never finishes).
    public var canForceStop: Bool { canStop || (cleanShutdown != nil && haltTask == nil && !isPoweredOff && !isDead) }
    public var canShutDown: Bool {
        host.state == .running && !shuttingDown && !host.isErasing && !host.storageFailed
            && host.helper?.isDead == false
    }
    public var isShuttingDownCleanly: Bool { cleanShutdown != nil && haltTask == nil }

    /// Asks the guest to power off, now. The task's value: true once the guest is off (or a Force Stop took over),
    /// false when it didn't get there in the shutdown budget (the device keeps running).
    @discardableResult public func shutDown() -> Task<Bool, Never> {
        guard canShutDown else { return Task { false } }
        host.willStop()
        shuttingDown = true
        logEvent("shut down: asking the guest")
        host.helperLink?.send(.machine(.shutdown))
        let budget = budgets.shutdown
        let task = Task { [weak self] in
            let deadline = ContinuousClock.now + .seconds(budget)
            while let self, ContinuousClock.now < deadline, !self.isPoweredOff, !self.isDead, self.haltTask == nil {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let self else { return false }
            // A Force Stop that took over owns the flag until its halt ends, and counts as stopped.
            let forced = haltTask != nil
            let off = isPoweredOff || isDead
            cleanShutdown = nil
            if !forced { shuttingDown = false }
            logEvent(
                off
                    ? "shut down: the guest powered off"
                    : forced ? "shut down: force stopped" : "shut down: the guest didn't power off"
            )
            return off || forced
        }
        cleanShutdown = task
        return task
    }

    /// Force Stop (and the guest's power-off from the menu): the halt, once queued installs are dropped. The task's
    /// value is the halt's; false when there is nothing to stop.
    @discardableResult public func forceStop() -> Task<Bool, Never> {
        guard canForceStop else { return Task { false } }
        host.willStop()
        return halt()
    }

    /// Starts the halt now, or joins the one under way. The task's value: true iff the helper is gone.
    @discardableResult public func halt() -> Task<Bool, Never> {
        if isPoweredOff || host.helper?.isDead != false { return Task { true } }
        if let haltTask { return haltTask }
        shuttingDown = true
        halting = true
        host.retireBoot()
        let process = host.helper
        if host.filesMeddled {
            // The overlay or NOR the helper has open is gone from disk: a flush would
            // write into dead inodes, so quit QEMU outright (no pause first).
            logEvent("stop: files were changed under the device; quitting without a flush")
            host.helperLink?.send(.machine(.quit))
        } else {
            process?.terminate()
        }
        let budgets = budgets
        let task = Task { [weak self] in
            var exited = await process?.waitForExit(timeout: budgets.halt) ?? true
            if !exited {
                logEvent("stop: the device helper did not exit in \(Int(budgets.halt)) s; killing it")
                process?.kill()
                exited = await process?.waitForExit(timeout: budgets.kill) ?? true
            }
            guard let self else { return exited }
            let host = host
            await host.workers.awaitTeardown(budget: budgets.serviceTeardown)
            if exited { logEvent("stop: device halted") }
            haltTask = nil
            shuttingDown = false
            return exited
        }
        haltTask = task
        return task
    }
}
