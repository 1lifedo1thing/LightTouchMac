// The VM's lifecycle and the machine controls that move it: pause and resume (the user's, and the Mac's sleep),
// and the screen's visibility, which paces the status poll.

import Foundation
import HostRuntime
import DeviceRuntime

/// The VM's lifecycle. Everything the UI enables or disables keys off this; `.dead` is the one that used to be
/// invisible — QEMU would exit and the app kept a frozen frame with every control live.
public enum VMState: Equatable {
    case notStarted, booting, running, paused, poweredOff
    case dead(exitCode: Int32?)

    public var isDead: Bool { if case .dead = self { true } else { false } }

    /// A new frame ends the boot's `booting` (the signal behind booting → running), except while a power-on still
    /// waits to resume the machine.
    public func runsAfterFrame(poweringOn: Bool) -> Bool { self == .booting && !poweringOn }
}

/// What pause, resume and the Mac's sleep need of the session.
public protocol MachineHost: AnyObject {
    var state: VMState { get set }
    var storageFailed: Bool { get }
    var shuttingDown: Bool { get }
    var helperLink: HelperLink? { get }
    /// Set the guest's clock again through lockdown (lockdown-tz, as at boot), for this boot.
    func resyncTimeZone()
}

extension MachineHost {
    public func pause() {
        helperLink?.send(.machine(.pause))
        if state == .running { state = .paused }
    }

    public func resume() {
        guard !storageFailed else { return }
        helperLink?.send(.machine(.resume))
        if state == .paused { state = .running }
    }
}

/// The Mac's side of power: its sleep pauses the VM, and a hidden screen slows the helper and the status poll.
public final class HostPower {
    private unowned let host: MachineHost
    /// Restarts the status poll at the new pace (when it runs).
    private let repoll: () -> Void
    public init(host: MachineHost, repoll: @escaping () -> Void) {
        self.host = host
        self.repoll = repoll
    }

    /// 30 Hz while the screen is on show, 4 Hz otherwise.
    public static func pollInterval(screenVisible: Bool) -> TimeInterval { screenVisible ? 1.0 / 30 : 0.25 }

    /// The window shows this device's screen (DisplayView: on screen, not occluded, minimized or hidden).
    /// Hidden, the helper publishes a few frames a second and lets the Mac idle-sleep, and the status poll slows.
    public var screenVisible = false {
        didSet {
            guard screenVisible != oldValue else { return }
            host.helperLink?.send(.screenVisible(screenVisible))
            repoll()
        }
    }

    private(set) var pausedForHostSleep = false

    /// The Mac is going to sleep: pause the VM, so the guest's timers don't all come due at once on wake
    /// (QEMU's clock counts the sleep). A device the user paused stays paused through it.
    public func hostWillSleep() {
        guard host.state == .running, !host.shuttingDown else { return }
        host.pause()
        pausedForHostSleep = true
        logEvent("host sleep: paused")
    }

    /// Awake: resume, then set the guest's clock again.
    public func hostDidWake() {
        guard pausedForHostSleep else { return }
        pausedForHostSleep = false
        host.resume()
        logEvent("host wake: resumed")
        host.resyncTimeZone()
    }
}
