// Never "Booting…" forever: the boot deadline, recovery mode on serial, a boot that can't be built, and the
// helper's death all end a boot as `.dead` with a named reason (the row and the overlay show it).

import DeviceRuntime
import Foundation
import HostRuntime
import Observation

/// What the boot watch reads and changes on the session.
public protocol BootWatchHost: AnyObject {
    var bootScope: BootSessionScope { get }
    var profile: Board { get }
    var state: VMState { get set }
    var shuttingDown: Bool { get }
    /// Stop asked the helper to halt: its exit is Stopped, not a crash.
    var halting: Bool { get }
    var helper: DeviceHelper? { get }
    /// iOS is up: lockdown answered (or, without a USB bridge, the display paints).
    var bootFinished: Bool { get }
    var readiness: ReadinessWatch { get }
    var notices: DeviceNotices { get }
    func retireBoot()
    /// The helper is gone: the file watch, status poll, recording audio, usbmuxd and serial capture end with it.
    func releaseBootResources()
}

@Observable public final class BootWatch {
    private unowned let host: BootWatchHost
    public init(host: BootWatchHost) { self.host = host }

    /// iBoot's last words before it waits for a restore.
    public static let recoveryMarker = "Entering recovery mode"
    /// it_ethlink (the iPad's guest package) bringing the USB Ethernet link up.
    public static let ethlinkMarker = "it_ethlink: LinkStatus 0 -> 1"
    public static func recoveryReason(_ profile: Board) -> String {
        "The \(profile.shortName) started in recovery mode. Delete it and prepare it again."
    }
    public static func deadlineReason(_ profile: Board) -> String {
        "The \(profile.shortName) didn’t start within \(Int(profile.bootBudget)) seconds."
    }
    /// A boot file the base lacks (BootRecipe.preparedFiles), else the storage error as it is.
    public static func bootFilesReason(_ error: Error, profile: Board) -> String {
        if let cocoa = error as? CocoaError, cocoa.code == .fileNoSuchFile,
            let path = cocoa.userInfo[NSFilePathErrorKey] as? String
        {
            return
                "This \(profile.shortName)’s system files are incomplete: \(URL(fileURLWithPath: path).lastPathComponent) is missing. Delete it and prepare it again."
        }
        return "Couldn’t prepare the \(profile.shortName)’s storage: \(error.localizedDescription)"
    }

    /// Why the helper died, for the row and the dead overlay.
    public private(set) var deathReason: String?
    /// The board's boot budget (shorter in tests).
    @ObservationIgnored lazy var budget: TimeInterval = host.profile.bootBudget
    /// How long an aborted boot's helper gets to exit before it is killed.
    var haltBudget = ShutdownLadder.Budgets().halt

    private var task: Task<Void, Never>? {
        get { host.bootScope[.watchdog] }
        set { host.bootScope[.watchdog] = newValue }
    }
    public var current: Task<Void, Never>? { task }

    /// The boot can't be built: dead with a named reason.
    public func failBoot(_ error: Error) {
        let reason = Self.bootFilesReason(error, profile: host.profile)
        deathReason = reason
        host.notices.report(reason, for: .storage)
        host.state = .dead(exitCode: 1)
    }

    /// No answer within the board's budget ends the boot as a named error, with the helper halted, unless iOS is
    /// up and showing a picture (the readiness watch then says USB isn't there yet). Per boot (also after Power On
    /// and Restart).
    public func start() {
        task?.cancel()
        let generation = host.bootScope.generation
        let budget = budget
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(budget * 1000)))
            guard let self, !Task.isCancelled, generation == host.bootScope.generation, !host.bootFinished else {
                return
            }
            guard host.readiness.deadlineVerdict == .stop else {
                logEvent(
                    "boot: iOS is up (\(host.readiness.bootStage.text)) but USB didn’t answer in \(Int(host.profile.bootBudget)) s; keeping it running"
                )
                return
            }
            abort(Self.deadlineReason(host.profile))
        }
    }

    /// The guest will not come up (recovery mode, or out of time): halt the helper and become `.dead` with
    /// `reason`; the row offers Start again.
    public func abort(_ reason: String) {
        guard !host.state.isDead, host.state != .poweredOff, !host.shuttingDown, !host.halting,
            let process = host.helper, !process.isDead
        else { return }
        logEvent("boot: \(reason)")
        deathReason = reason
        task?.cancel()
        process.terminate()
        let haltBudget = haltBudget
        Task {
            if await !process.waitForExit(timeout: haltBudget) { process.kill() }
        }
    }

    /// The helper is gone (QEMU returned, it crashed or was killed): `.dead`, or powered off after a halt; the
    /// window shows a Restart overlay, and the other devices keep running.
    public func helperDied(_ reason: String) {
        guard !host.state.isDead else { return }
        host.retireBoot()
        if !host.halting, deathReason == nil { deathReason = reason }  // an aborted boot keeps its own reason
        host.releaseBootResources()
        host.state = host.halting ? .poweredOff : .dead(exitCode: nil)
    }
}
