import Foundation
import Testing
import HostRuntime
import DeviceRuntime
@testable import LightTouchCore

/// The guest's front app while the device answers (and nothing while it sleeps, installs or has queued work),
/// the web proxy applied on each pass, and Setup's end lifting the boot's network restriction once.
struct ForegroundWatchTests {
    struct NoAgent: Error {}

    final class Host: ForegroundHost {
        let bootScope = BootSessionScope()
        let link = RecordingLink()
        var helperLink: HelperLink? { link }
        var canReachDevice = true, isSleeping = false, isInstalling = false, hasPendingInstallWork = false
        var guestAgentAlive = true
        let overlay: URL
        var fronts: [(bundleID: String, name: String?)?] = []
        var proxyPasses = 0
        var finished: [Int] = []
        /// Polls still to come when Setup finished.
        var remainingAtFinish: Int?
        init(overlay: URL) { self.overlay = overlay }
        func foregroundApp() async throws -> (bundleID: String, name: String?) {
            guard !fronts.isEmpty, let front = fronts.removeFirst() else { throw NoAgent() }
            return front
        }
        func applyWebProxy(since applied: Int?, generation: Int) async throws -> Int? { proxyPasses += 1; return applied }
        func setupFinished(generation: Int) { finished.append(generation); remainingAtFinish = fronts.count }
    }

    func watch(_ host: Host) -> ForegroundWatch {
        let watch = ForegroundWatch(host: host)
        watch.interval = .milliseconds(5)
        return watch
    }

    @Test func theFrontAppNamesTheWindow() async throws {
        try await withScratchDirectory { overlay in
            let host = Host(overlay: overlay)
            host.isSleeping = true
            let watch = watch(host)
            host.fronts = [("com.apple.mobilesafari", "Safari"), nil]
            watch.start()
            try await Task.sleep(for: .milliseconds(40))
            #expect(watch.appName == nil && host.proxyPasses == 0, "asleep: no polls")
            host.isSleeping = false
            await eventually("Safari") { watch.appName == "Safari" }
            await eventually("the failed poll") { watch.appName == nil && host.fronts.isEmpty }
            #expect(host.proxyPasses >= 2, "the proxy is applied on every pass")
            watch.stop()
        }
    }

    @Test func setupsEndLiftsTheRestrictionOnce() async throws {
        try await withScratchDirectory { overlay in
            let host = Host(overlay: overlay)
            let watch = watch(host)
            watch.setupGate = BootRecipe.SetupNetworkGate()
            host.fronts = [("com.apple.purplebuddy", "Setup"), ("com.apple.springboard", "Home"), nil,
                           ("com.apple.springboard", "Home"), ("com.apple.mobilesafari", "Safari"), ("com.apple.springboard", "Home")]
            watch.start()
            await eventually("lifted") { !host.finished.isEmpty }
            await eventually("every poll seen") { host.fronts.isEmpty }
            watch.stop()
            #expect(host.link.commands == [.netRestrict(false)] && host.finished == [host.bootScope.generation], "once, after two unlocked polls in a row")
            #expect(host.remainingAtFinish == 1, "the failed poll broke the streak: lifted at Safari, not the Home before it")
            #expect(watch.setupGate == nil)
            #expect(FileManager.default.fileExists(atPath: BootRecipe.setupDoneMark(overlay: overlay).path), "the overlay remembers Setup is done")
        }
    }
}
