// The guest's front app, every few seconds while the device answers: the window's subtitle, the web proxy's
// changes reaching the guest, and the end of Setup on a boot whose networking waits for it.

import Foundation
import Observation
import HostRuntime
import DeviceRuntime

/// What the foreground watch reads of the session and asks of the guest.
public protocol ForegroundHost: AnyObject {
    var bootScope: BootSessionScope { get }
    var helperLink: HelperLink? { get }
    var canReachDevice: Bool { get }
    var isSleeping: Bool { get }
    var isInstalling: Bool { get }
    /// AppInstaller has queued work for this device.
    var hasPendingInstallWork: Bool { get }
    var guestAgentAlive: Bool { get }
    /// The device's overlay: where the Setup-done mark goes.
    var overlay: URL { get }
    /// The guest agent's frontmost app.
    func foregroundApp() async throws -> (bundleID: String, name: String?)
    /// Applies a changed web proxy to the guest (DeviceWebProxy.apply); throws CancellationError to end the watch.
    func applyWebProxy(since applied: Int?, generation: Int) async throws -> Int?
    /// Setup's country page set its own locale: the Mac's region again.
    func setupFinished(generation: Int)
}

@Observable public final class ForegroundWatch {
    @ObservationIgnored private unowned let host: ForegroundHost
    public init(host: ForegroundHost) { self.host = host }

    /// The guest's front app; the window's subtitle while it runs.
    public private(set) var appName: String?
    /// Set when this boot came up with slirp restrict=on (5.x, Setup not yet done on this overlay):
    /// the watch feeds it frontmost and lifts restrict in place once Setup is over.
    @ObservationIgnored public var setupGate: BootRecipe.SetupNetworkGate?
    /// Between polls (shorter in tests).
    @ObservationIgnored var interval: Duration = .seconds(3)

    private var task: Task<Void, Never>? {
        get { host.bootScope[.foreground] }
        set { host.bootScope[.foreground] = newValue }
    }

    public func forget() { appName = nil }
    public func stop() { task?.cancel() }

    public func start() {
        task?.cancel()
        let generation = host.bootScope.generation
        let interval = interval
        task = Task { [weak self] in
            var appliedProxyRevision: Int?
            while !Task.isCancelled {
                guard let self else { return }
                if host.canReachDevice, !host.isSleeping, !host.isInstalling, !host.hasPendingInstallWork {
                    do {
                        appliedProxyRevision = try await host.applyWebProxy(since: appliedProxyRevision, generation: generation)
                    } catch { return }
                    do {
                        let fg = host.guestAgentAlive ? try await host.foregroundApp() : nil
                        try Task.checkCancellation()
                        guard generation == host.bootScope.generation else { return }
                        appName = fg?.name
                        // Setup over (unlocked, purplebuddy gone): open networking once, in
                        // place -- the Wi-Fi association and DHCP lease stay (no reboot, no re-join).
                        if var gate = setupGate, let link = host.helperLink {
                            if gate.observe(bundleID: fg?.bundleID, name: fg?.name) {
                                setupGate = nil
                                link.send(.netRestrict(false))
                                try? Data().write(to: BootRecipe.setupDoneMark(overlay: host.overlay))
                                logEvent("networking: Setup finished, lifting slirp restrict on wifi0")
                                host.setupFinished(generation: generation)
                            } else {
                                setupGate = gate
                            }
                        }
                    } catch {
                        if Task.isCancelled { return }
                        appName = nil
                        _ = setupGate?.observe(bundleID: nil, name: nil)   // a failed poll breaks the streak
                    }
                }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }
}
