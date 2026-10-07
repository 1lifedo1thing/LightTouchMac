// Erase All Content and Settings: stop the guest and its helper, erase this device, then start it fresh (a running
// device) or leave it ready (a stopped one). The app keeps running. No request is left behind for an unrelated
// future launch.

import DeviceRuntime
import Foundation
import HostRuntime

/// What the erase reads and does on the session.
public protocol EraseHost: AnyObject {
    var isErasing: Bool { get set }
    var state: VMState { get }
    /// start() ran: an erased device starts again.
    var started: Bool { get }
    var helper: DeviceHelper? { get }
    var helperLink: HelperLink? { get }
    var notices: DeviceNotices { get }
    var profile: Board { get }
    /// What the erase removes.
    var eraseTargets: DeviceErase.Targets { get }
    /// Nothing queued can land on an erased device: installs are dropped first.
    func discardInstalls()
    /// The foreground and orientation watches stop asking the guest.
    func stopGuestWatches()
    func halt(completion: @escaping (Bool) -> Void)
    /// A fresh helper boots the erased device (DeviceSessionHost.restart).
    func restart()
}

public final class DeviceErase {
    public struct Targets {
        public init(overlay: URL, snapshots: [URL], preparedNOR: URL?, state: URL, owner: UUID) {
            self.overlay = overlay
            self.snapshots = snapshots
            self.preparedNOR = preparedNOR
            self.state = state
            self.owner = owner
        }
        public var overlay: URL
        /// Saved-state files older builds wrote beside the overlay.
        public var snapshots: [URL]
        /// The device's private NOR copy, which pairs with its overlay; the next boot clones base/nor.bin again.
        public var preparedNOR: URL?
        public var state: URL
        public var owner: UUID
    }

    private unowned let host: EraseHost
    public init(host: EraseHost) { self.host = host }
    /// How long a helper gets to exit (release every NAND/NOR writer) after its halt, and how often it's checked.
    var exitWait: Duration = .seconds(15)
    var exitPoll: Duration = .milliseconds(100)

    public func request() {
        guard !host.isErasing else { return }
        host.discardInstalls()
        host.isErasing = true
        host.stopGuestWatches()
        let exitWait = exitWait
        let exitPoll = exitPoll
        let host = host  // the session stays until its erase ends
        Task {
            if !host.state.isDead, host.state != .notStarted {
                _ = await withCheckedContinuation { continuation in
                    host.halt { continuation.resume(returning: $0) }
                }
                // The helper must release every NAND/NOR writer (exit) before removal;
                // one whose guest powered itself off is still alive.
                host.helperLink?.send(.machine(.quit))
                let deadline = ContinuousClock.now + exitWait
                while host.helper?.isDead == false, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: exitPoll)
                }
                guard host.helper?.isDead != false else {
                    host.isErasing = false
                    host.notices.report(
                        "Couldn’t stop the \(host.profile.shortName) to erase it. Try again.",
                        for: .erase
                    )
                    return
                }
            }
            let targets = host.eraseTargets
            do {
                try await Task.detached {
                    try DeviceStateStorage.erase(
                        overlay: targets.overlay,
                        snapshots: targets.snapshots,
                        state: targets.state,
                        owner: targets.owner
                    )
                    if let preparedNOR = targets.preparedNOR, FileManager.default.fileExists(atPath: preparedNOR.path) {
                        try DeviceStateStorage.checkRemovable(preparedNOR, state: targets.state, owner: targets.owner)
                        try FileManager.default.removeItem(at: preparedNOR)
                    }
                }.value
                host.notices.resolve(.erase)
                host.notices.resolve(.activation)
                host.isErasing = false
                if host.started {
                    logEvent("reset: device erased; starting it fresh")
                    host.restart()
                } else {
                    logEvent("reset: device erased")
                }
            } catch {
                host.isErasing = false
                host.notices.report(
                    "Couldn’t finish erasing the \(host.profile.shortName): \(error.localizedDescription)",
                    for: .erase
                )
            }
        }
    }
}
