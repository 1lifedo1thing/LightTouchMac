// Restart and Power On in place: a new boot on the same helper (QEMU's system_reset), with every per-boot watch
// started again in the order the first boot started them. A device without a guest to sync through, or whose
// helper is gone, gets a fresh helper instead (DeviceSessionHost.restart).

import Foundation
import HostRuntime
import DeviceRuntime
import HostServiceWire

/// What a reset and a power-on read and do on the session, each step as the session names it.
public protocol BootCycleHost: AnyObject {
    var bootScope: BootSessionScope { get }
    var state: VMState { get set }
    var storageFailed: Bool { get }
    var shuttingDown: Bool { get }
    /// stop() or release() ran: this controller's boots are over.
    var isReleased: Bool { get }
    var hasGuestTools: Bool { get }
    var helper: DeviceHelper? { get }
    var helperLink: HelperLink? { get }
    var workers: WorkerRetirement { get }
    var readiness: ReadinessWatch { get }
    var notices: DeviceNotices { get }
    /// The helper's status block, read now.
    var status: SharedStatus? { get }
    /// The guest agent's sync: the guest's filesystems flushed.
    func syncGuest() async throws
    func halt(completion: @escaping (Bool) -> Void)
    func restart()
    func retireBoot()
    // The per-boot steps, in the order a boot takes them.
    func publishDeveloperConnection()
    func reconnectUSB()
    /// The staging sweep runs again, and no recovery is under way.
    func forgetConnectionWork()
    /// No app in front, the display awake (a power-on's guest starts from nothing).
    func forgetGuestFacts()
    /// Reachability unknown again, and since when.
    func forgetReachability()
    func forgetEthlink()
    /// The guest cold-boots portrait, so the tracked orientation (and the iPad's accelerometer) follows it back.
    /// Leaving it at 90/270 left DisplayView posing the shell sideways while the guest published a portrait buffer.
    func resetRotation()
    func startTimeZoneSync()
    func startForegroundWatch()
    func startOrientationWatch()
    func startGuestPackageWatch()
    func startBootWatch()
}

public final class BootCycle {
    private unowned let host: BootCycleHost
    public init(host: BootCycleHost) { self.host = host }

    /// A power-on waits for the machine before resuming it: no frame ends its boot until then.
    public private(set) var poweringOn = false
    /// The guest agent's sync before a restart, at most.
    var syncBudget: Double = 20
    /// How long a power-on waits for the PMU reset to clear the shutdown latch.
    var latchWait: Duration = .seconds(5)

    private var isPoweredOff: Bool { host.state == .poweredOff }

    /// Restart the guest. Flush first: a bare system_reset is the same hard cut as a SIGKILL as far as the guest's
    /// filesystem is concerned — it loses the HFS+ catalog updates still in memory, which is how a device ends up on
    /// the Connect-to-iTunes screen.
    public func reset() {
        if isPoweredOff { powerOn(); return }
        guard !host.shuttingDown else { return }
        guard !host.storageFailed else { return }
        let preparation = host.readiness.current
        preparation?.cancel()
        let generation = host.bootScope.generation
        let syncBudget = syncBudget
        host.bootScope[.reset] = Task { [weak self] in
            guard let self else { return }
            let host = host
            await preparation?.value
            guard !Task.isCancelled, generation == host.bootScope.generation else { return }
            if !host.hasGuestTools {
                // No guest to sync through: a hard halt (storage flushed, the
                // journal replays), then a fresh helper, as Stop then Start.
                host.halt { [weak host] _ in host?.restart() }
                return
            }
            let synced = await withSoftDeadline(syncBudget) { @MainActor in
                do { try await host.syncGuest(); return true }
                catch { return false }
            }
            guard !Task.isCancelled, generation == host.bootScope.generation, !host.storageFailed, !host.shuttingDown, !host.state.isDead else { return }
            guard synced == true else {
                host.notices.report("Couldn’t restart because the device didn’t finish saving its files.", for: .powerOff)
                if host.state == .booting { host.readiness.start() }
                return
            }
            host.notices.resolve(.powerOff)
            host.retireBoot()
            let retiredGeneration = host.bootScope.generation
            // Retirement intentionally cancels this boot's reset task. Finish
            // only this transition after old workers are reaped; a concurrent
            // halt/death prevents renewing the scope.
            await host.workers.task?.value
            guard retiredGeneration == host.bootScope.generation, !host.isReleased, !host.storageFailed, !host.shuttingDown,
                  !host.state.isDead, host.state != .poweredOff else { return }
            host.bootScope.renew()
            host.publishDeveloperConnection()
            host.reconnectUSB()
            host.forgetConnectionWork()
            host.forgetReachability()
            host.startTimeZoneSync()
            host.helperLink?.send(.machine(.reset))
            host.resetRotation()
            host.state = .booting
            host.startForegroundWatch()
            if host.hasGuestTools { host.startOrientationWatch() }
            host.readiness.start()
            host.startGuestPackageWatch()
            host.startBootWatch()
        }
    }

    /// The machine was kept at guest power-off (-no-shutdown): reset and resume it, without reinitializing QEMU or
    /// opening a second NAND writer. Stopped by a halt, the helper is gone: a fresh one starts.
    public func powerOn() {
        guard isPoweredOff, !host.storageFailed, !host.shuttingDown else { return }
        if host.helper?.isDead != false { host.restart(); return }
        host.bootScope.renew()
        host.publishDeveloperConnection()
        host.reconnectUSB()
        poweringOn = true
        host.forgetConnectionWork()
        host.forgetGuestFacts()
        host.forgetReachability()
        host.forgetEthlink()
        host.resetRotation()
        host.state = .booting
        host.startTimeZoneSync()
        host.helperLink?.send(.machine(.reset))
        let generation = host.bootScope.generation
        let latchWait = latchWait
        host.bootScope[.powerOn] = Task { [weak self] in
            guard let self else { return }
            let host = host
            await host.workers.task?.value
            guard !Task.isCancelled, generation == host.bootScope.generation else { return }
            let deadline = ContinuousClock.now + latchWait
            // system_reset is queued. Wait until the PMU reset clears its
            // shutdown latch (the helper republishes it at 20 Hz) before
            // resuming the stopped VM.
            while host.status?.shutdownConfirmed == true, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, generation == host.bootScope.generation else { return }
            guard host.status?.shutdownConfirmed == false, !host.state.isDead else {
                host.retireBoot()
                poweringOn = false
                host.state = .poweredOff
                return
            }
            host.helperLink?.send(.machine(.resume))
            poweringOn = false
            host.readiness.start()
            host.startForegroundWatch()
            host.startGuestPackageWatch()
            host.startBootWatch()
        }
    }
}
