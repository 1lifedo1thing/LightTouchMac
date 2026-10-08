import Cocoa
import DeviceRuntime
import FirmwareSchema
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore
import Observation

extension EmulatorController {
    // MARK: - Boot deadline
    /// Why the helper died, for the row and the dead overlay.
    var deathReason: String? { bootWatch.deathReason }
    func failBoot(_ error: Error) { bootWatch.failBoot(error) }
    func startBootWatch() { bootWatch.start() }
    func abortBoot(_ reason: String) { bootWatch.abort(reason) }

    /// iOS is up: lockdown answered (the helper's uiReady is QEMU's display, lit
    /// by iBoot too). Without a USB bridge (--no-appsync) painting has to do.
    var bootFinished: Bool { deviceReachable == true || (usbmux.session == nil && state == .running) }

    /// Status is read from the helper's shared block: the old per-frame poll,
    /// now on its own timer so a hidden device (no display link) still flips
    /// booting -> running, notices storage failures and its power-off.
    /// 30 Hz while the screen is on show, 4 Hz otherwise.
    func startStatusPoll() {
        statusTimer?.invalidate()
        let interval = HostPower.pollInterval(screenVisible: screenVisible)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollStorageFailure() }
        }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    /// The window shows this device's screen (DisplayView: on screen, not occluded, minimized or hidden).
    /// Hidden, the helper publishes a few frames a second and lets the Mac idle-sleep, and the status poll slows.
    var screenVisible: Bool {
        get { hostPower.screenVisible }
        set { hostPower.screenVisible = newValue }
    }

    /// For a restart: stop this device's tasks and usbmuxd, kill its helper if
    /// it is still running, and wait until it is gone. False if it would not exit.
    func release() async -> Bool {
        releasing = true
        stop()
        guard let process, process.link.pid > 0 else {
            await workers.awaitTeardown(budget: ladder.budgets.serviceTeardown)
            return true
        }
        if !process.isDead { process.kill() }
        let exited = await process.waitForExit(timeout: 10)
        await workers.awaitTeardown(budget: ladder.budgets.serviceTeardown)
        return exited
    }

    /// The iPod machine has the guest agent's channel; a stock iPad has none,
    /// so its media import and agent extras are skipped.
    var hasGuestTools: Bool { profile.hasGuestTools }

    func stopTimeZoneSync() { timeZone.stop() }
    func startTimeZoneSync() { timeZone.start() }
    func setGuestTimeZone(_ identifier: String) async throws {
        let dated = lock?.pinsClock == true
        try await services.setTimeZone(identifier, keepClock: dated, guest: guest, region: .mac)
    }

    /// App quit (after the clean shutdowns) and restarts. The helper gets
    /// SIGTERM: a guest that already powered off quits at once; one that
    /// didn't gets the helper's own bounded clean shutdown after we are gone.
    func publishDeveloperConnection() {
        guard GuestDeveloperTools.supports(build: instance.firmware.split(separator: "-").last.map(String.init) ?? "")
        else { return }
        guard let socket = usbmux.session?.clientSocket else { return }
        do {
            try DeveloperConnectionProfile.publish(
                instance: instance.id,
                session: bootScope.id,
                socket: socket,
                udid: guestUDID
            )
        } catch { logEvent("developer access: \(error.localizedDescription)") }
    }

    private func retireDeveloperConnection() {
        DeveloperConnectionProfile.retire(instance: instance.id, session: bootScope.id)
    }

    func retireBoot() {
        guard !bootScope.retired else { return }
        let endpoint = try? services
        retireDeveloperConnection()
        stopTimeZoneSync()
        bootScope.retire()
        workers.chain { await endpoint?.stopWorker() }
    }

    func stop() {
        stopped = true
        retireBoot()  // cancels every task of this boot (BootSessionScope)
        statusTimer?.invalidate()
        statusTimer = nil
        process?.terminate()
        fileWatch = nil
        // Unlink the owned FIFO paths now, keeping readers alive until the
        // helper is finished writing.
        serialCapture?.removeEndpoints()
        usbmux.stop()
    }

    /// Booting and recording: a notice (non-blocking) below 2 GB free, gone once there's room.
    /// The volume query (CacheDelete, ~0.1 s) runs off the main thread.
    func warnIfLowOnSpace() {
        let stateDir = stateDir
        Task {
            let warning = await Self.lowSpaceWarning(at: stateDir)
            if let warning { reportDeviceNotice(warning, for: .lowSpace) } else { resolveDeviceNotice(for: .lowSpace) }
        }
    }
    @concurrent nonisolated static func unpackGuestTools() async { _ = Bundled.guestRoot }
    @concurrent private nonisolated static func lowSpaceWarning(at url: URL) async -> String? {
        IPSWStore.lowSpaceWarning(at: url)
    }

    /// The helper is gone (QEMU returned, it crashed or was killed). Flip to
    /// `.dead`; the window shows a Restart overlay, and the other devices keep running.
    func helperDied(_ reason: String) { bootWatch.helperDied(reason) }

    func releaseBootResources() {
        fileWatch = nil
        statusTimer?.invalidate()
        statusTimer = nil
        audioSink?(.audioEnded(generation: 0, failed: true))
        usbmux.stop()
        serialCapture?.finish()
        serialCapture = nil
    }
}
