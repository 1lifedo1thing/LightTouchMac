import Cocoa
import DeviceRuntime
import FirmwareSchema
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore
import Observation

// Created by Sam on 2026-08-05.
//
// Owns one device: builds its boot from the device record (a prepared base),
// starts its usbmuxd (for app management), then runs it in its own
// LightTouchDevice helper (DeviceProcess) and exposes input and app operations
// to the UI. Everything that used to be a direct call into the dylib crosses the
// helper's DeviceLink: status and frames are read from shared memory, input is a
// command, the rest are requests. One controller per boot: a restart is a new
// session (DeviceSessionHost.restart).
//
// The composition root: the boot, the helper and the status poll are its own; the rest are components in
// LightTouchCore/Session it owns and forwards to (input, rotation, keyboard, battery, carrier, options, web proxy,
// guest package, foreground watch, time zone, app management, and the state machines: readiness, recovery,
// activation, boot watch, shutdown ladder, boot cycle, erase), each running against the controller through its
// host protocol (the extension at the end).
//
// Observable (as are its components): the window, the inspector and the sidebar each track what they show
// (ObservationLoop). Bookkeeping no observer shows is @ObservationIgnored.

@MainActor @Observable
final class EmulatorController {

    let profile: Board
    /// Emulated Wi-Fi with the Mac's networking (slirp); off is a device with no internet.
    let network: Bool
    private let usbmux = USBMux()
    private(set) var started = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var serialCapture: SerialLogCapture?
    var isErasing = false { didSet { trackStartup(was: oldValue || state == .booting || preparingDevice) } }
    /// When the current startup (erase, boot, readiness) began: the toast's counter, per device, not per window.
    private(set) var startupBegan = Date()
    var isStartingUp: Bool { isErasing || state == .booting || preparingDevice }
    private func trackStartup(was: Bool) { if isStartingUp, !was { startupBegan = Date() } }

    private(set) var isSleeping = false
    /// The guest's front app, the web proxy reaching the guest, the end of Setup (ForegroundWatch).
    @ObservationIgnored private(set) lazy var foreground = ForegroundWatch(host: self)
    var foregroundAppName: String? { foreground.appName }
    /// This device's web proxy (DeviceWebProxy): its routing and certificate beside the device's own state.
    @ObservationIgnored private(set) lazy var proxy = DeviceWebProxy(
        directory: { [unowned self] in
            WebProxyConfiguration.directory(for: instance)
        },
        shortName: profile.shortName
    )
    private var proxyDirectory: URL { proxy.directory }
    /// iPhone OS 1.x devices take the web proxy's CA while stopped (FirmwareTool.trustAnchor): no agent, no MCInstall.
    private var trustsStopped: Bool { profile.trustsStopped }
    var webProxy: WebProxyConfiguration { proxy.configuration }
    var webProxyStatus: WebProxyStatus { proxy.status }
    var webProxyAvailable: Bool { proxy.available }
    func configureWebProxy(_ value: WebProxyConfiguration) throws { try proxy.configure(value) }
    /// This device's settings.plist (DeviceSettings), read once and written on every change.
    @ObservationIgnored private lazy var settingsFile = DeviceSettingsFile(directory: instance.paths.directory)
    typealias NoticeOperation = DeviceNotices.Operation
    @ObservationIgnored private(set) lazy var notices = DeviceNotices(
        settings: settingsFile,
        shortName: profile.shortName
    ) {
        [weak self] in self?.storageFailed ?? false
    }
    var deviceNotice: String? { notices.message }
    func reportDeviceNotice(_ message: String, for operation: NoticeOperation) {
        notices.report(message, for: operation)
    }
    /// The notice's remedy is Erase All Content and Settings (a refused
    /// overlay, an unfinished or failed erase, an unactivated guest).
    var deviceNoticeOffersErase: Bool { notices.offersErase }
    /// Boot refused: the overlay belongs to a different base image.
    private(set) var baseImageMismatch = false

    func dismissDeviceNotice() { notices.dismiss() }
    func resolveDeviceNotice(for operation: NoticeOperation) { notices.resolve(operation) }

    let bootScope = BootSessionScope()
    private var bootGeneration: Int { bootScope.generation }
    /// Retired boots' services workers (Stop waits for them only so long).
    let workers = WorkerRetirement()
    var isPoweredOff: Bool { state == .poweredOff }

    @ObservationIgnored private var reportedStorageFailure = false
    /// From the boot until SpringBoard answers over lockdown; the status line says where it is.
    @ObservationIgnored private(set) lazy var readiness: ReadinessWatch = {
        let readiness = ReadinessWatch(host: self, notices: notices)
        readiness.onPreparingChange = { [weak self] old in
            guard let self else { return }
            trackStartup(was: isErasing || state == .booting || old)
        }
        return readiness
    }()
    var preparingDevice: Bool { readiness.preparingDevice }
    var preparationStatus: String { readiness.preparationStatus }
    /// How far this boot has provably got (BootStage): the boot toast's subtitle.
    var bootStage: BootStage { readiness.bootStage }
    private func noteBoot(_ event: BootStage.Event) { readiness.noteBoot(event) }
    private var readinessFailure: String? { readiness.readinessFailure }

    /// The VM's lifecycle. Everything the UI enables or disables keys off this;
    /// `.dead` is the one that used to be invisible — QEMU would exit and the
    /// app kept a frozen frame with every control live.
    typealias VMState = LightTouchCore.VMState
    var state: VMState = .notStarted {
        didSet { trackStartup(was: isErasing || oldValue == .booting || preparingDevice) }
    }

    /// Set by the inspector's poll: nil = never checked, true/false = last read.
    var deviceReachable: Bool? {
        didSet {
            // A service answered: nothing blocks commands any more, not even a stale activation issue.
            if deviceReachable == true { recovery.servicesAnswered() }
            if deviceReachable == true, reachableSince == nil {
                reachableSince = Date()
                startFileWatch()  // iOS is up: every file the helper depends on exists now
            }
            recovery.consider()
            activation.checkIfNeeded()
            // Clean abandoned uploads when the guest first answers. The sweep
            // excludes this process’s session-tagged uploads even if it runs late.
            if deviceReachable == true, !didSweepStaging {
                didSweepStaging = true
                if let socket = usbmux.session?.clientSocket {
                    let endpoint = DeviceServices(clientSocket: socket, udid: guestUDID, session: bootScope.id)
                    bootScope[.staging] = Task { await endpoint.sweepStaging() }
                }
            }
        }
    }
    var hasFileTransfer = false
    var connectionIssue: DeviceConnectionIssue? { recovery.issue }

    /// The standing issue from failed service reads, and the recovery of an unresponsive management service.
    @ObservationIgnored private(set) lazy var recovery = ConnectionRecovery(host: self, notices: notices)
    var isReconnecting: Bool { recovery.isReconnecting }
    func reportConnectionFailure(_ error: Error, operation: String) {
        recovery.reportFailure(error, operation: operation)
    }
    var installerUsesDevice: Bool { AppInstaller.isUsingDevice(instance.id) }
    var guestAgentAlive: Bool { guestAgent.isAlive }
    func reconnectManagement() async throws { try await guest.reconnectManagement() }
    func appsMayHaveChanged() { NotificationCenter.default.post(name: .ltmAppsChanged, object: instance.id) }

    @ObservationIgnored private var didSweepStaging = false

    /// The device record whose state this controller runs.
    private(set) var instance: DeviceInstance

    init(instance: DeviceInstance, profile: Board, network: Bool = true) {
        self.instance = instance
        self.profile = profile
        self.network = network
        let center = NSWorkspace.shared.notificationCenter
        hostSleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hostWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hostDidWake() }
            },
        ]
    }

    deinit { hostSleepObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }

    // MARK: - Mac sleep

    @ObservationIgnored nonisolated(unsafe) private var hostSleepObservers: [NSObjectProtocol] = []
    /// The Mac's sleep and the screen's visibility (HostPower).
    @ObservationIgnored private lazy var hostPower = HostPower(host: self) { [weak self] in
        guard let self, statusTimer != nil else { return }
        startStatusPoll()
    }
    func hostWillSleep() { hostPower.hostWillSleep() }
    func hostDidWake() { hostPower.hostDidWake() }
    func resyncTimeZone() { timeZone.resync() }

    /// Per-user machine state (the NAND copy-on-write overlay, logs).
    private var stateDir: URL { Bundled.stateDirectory }

    // MARK: - Helper

    /// This device's LightTouchDevice, from start() until the next restart.
    private(set) var process: DeviceProcess?
    /// Its link: status and frames (synchronous), commands and requests.
    var link: DeviceLink? { process?.link }
    /// The status block, read now; nil before the helper's first hello.
    var status: SharedStatus? { process?.status }
    /// The session replaces this controller with a fresh helper (DeviceSessionHost.restart).
    @ObservationIgnored var onRestartRequested: (() -> Void)?
    @ObservationIgnored var onStorageGenerationChanged: (() -> Void)?
    /// The active recording's audio (GuestAudioCapture).
    @ObservationIgnored var audioSink: ((LinkEvent) -> Void)?
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var lastFrameSerial: UInt64 = 0
    @ObservationIgnored private var releasing = false
    @ObservationIgnored private var admittedStorage: StorageBootProof?

    // MARK: - Boot

    func start() {
        guard !started else { return }
        let paths = instance.paths
        do {
            try Bundled.requireStorage()
            try DeviceStateStorage.checkBootPaths(
                base: paths.base,
                mutable: [
                    paths.overlay, paths.snapshot, paths.snapshotMeta, paths.snapshotTmp, paths.snapshotBad,
                    paths.usbmuxConf, paths.work, paths.lease,
                ] + [paths.writableNOR].compactMap { $0 },
                state: Bundled.stateDirectory,
                owner: instance.id
            )
        } catch {
            logEvent("storage: \(error.localizedDescription)")
            failBoot(error)
            return
        }
        started = true
        state = .booting
        resolveDeviceNotice(for: .files)  // a fresh helper opens the files as they are now
        let process = DeviceProcess(
            instance: instance.id,
            profile: profile,
            log: instance.paths.logs.appendingPathComponent("native.log"),
            lease: instance.paths.lease
        )
        self.process = process
        lastFrameSerial = 0
        process.onDeath = { [weak self, weak process] reason in
            guard let self, let process, self.process === process else { return }
            helperDied(reason)
        }
        process.onAudio = { [weak self] event in self?.audioSink?(event) }
        startStatusPoll()
        // Low space doesn't stop a boot; it's said before writes start failing.
        warnIfLowOnSpace()
        // The boot is built after the hello: usbmuxd must listen before the guest's USB.
        readiness.setStatus("Preparing device…")
        process.start(
            { [weak self] info in self?.bootConfiguration(hardware: info.deviceInfo) },
            preparation: { [weak self] in
                guard let self, !self.releasing, !self.stopped else { throw CancellationError() }
                guard let executable = FirmwareJobs.preparer else {
                    throw DeviceToolsError.failed("The firmware worker is unavailable.")
                }
                // The boot configuration (on main, after the helper's hello) reads the unpacked guest tools: their
                // first read hashes guest.aar, so it happens here, off the main thread.
                await Self.unpackGuestTools()
                // 1.x has no agent to trust the web proxy's CA: once it exists, the stopped device takes it as an anchor.
                let ca = URL(fileURLWithPath: WebProxyConfiguration.file(in: self.proxyDirectory).path + ".ca.der")
                if self.trustsStopped, FileManager.default.fileExists(atPath: ca.path) {
                    self.readiness.setStatus("Trusting the proxy certificate…")
                    if try await FirmwareTool.trustAnchor(
                        device: self.instance.paths.directory,
                        certificate: ca,
                        executable: executable
                    ) {
                        logEvent("proxy: certificate written into the stopped device's trust store")
                    }
                    try Task.checkCancellation()
                }
                _ = try await FirmwareTool.admitBoot(
                    device: self.instance.paths.directory,
                    managed: true,
                    executable: executable
                )
                try Task.checkCancellation()
                let recordBytes = try Data(contentsOf: DeviceRecord.url(self.instance.paths.directory))
                let refreshed = try DeviceInstance.decoder.decode(DeviceInstance.self, from: recordBytes)
                guard refreshed.id == self.instance.id, refreshed.board == self.instance.board else {
                    throw DeviceToolsError.failed("The device identity changed while preparing to start.")
                }
                self.instance = refreshed
                self.admittedStorage = try StorageBootProof.capture(recordBytes: recordBytes)
                self.onStorageGenerationChanged?()
            }
        ) { [weak self] result in
            if case .failure(let error) = result, let self { logEvent("boot: \(instance.name): \(error)") }
        }
        if hasGuestTools {
            rotation.startGuestWatch()  // idle until the guest is up and reachable
        } else {
            rotation.startInterfaceWatch()
        }
        startTimeZoneSync()  // guest zone follows the Mac's, incl. travel
        startForegroundWatch()
        // The guest-package watch starts in bootConfiguration(), once this boot's offer is composed.
    }

    /// nil when the device can't boot; the notice says why and the state is dead.
    /// `hardware`: the helper's hello's DeviceInfo, the emulator's facts about this board.
    private func bootConfiguration(hardware: DeviceInfo?) -> BootConfig? {
        guard !isDead, !releasing else { return nil }
        link?.send(.screenVisible(screenVisible))
        proxy.forgetEndpoint()
        var config = preparedBootConfiguration(hardware: hardware)
        config?.webProxy = proxy.endpoint
        config?.storageProof = admittedStorage
        if let port = options.chooseDebugPort(booting: config != nil) {
            config?.argv += DebugPort.arguments(port: port)
            logEvent("debug port: QEMU gdbstub on 127.0.0.1:\(port)")
        }
        if config != nil {
            // Stopped migration time is separate from the guest boot budget.
            readiness.start()
            publishDeveloperConnection()
            logEmulatorBuild()
            startGuestPackageWatch()  // after guestPackage.compose(): a watch with no offer judges nothing
            startBootWatch()
        }
        return config
    }

    /// Storage preparation and argv assembly are shared with headless callers.
    /// DeviceProcess already holds the storage lease when this hello callback runs.
    /// The UDID the guest reports: the record's, or for an iPhone base prepared before its identity carried an IMEI
    /// (n90/n88 recipe 1) the one its seed-derived IMEI makes; DeviceLock.machineOptions passes that IMEI to the modem.
    var guestUDID: String? {
        if profile.kbootPhone,
            let data = try? Data(contentsOf: instance.paths.base.appendingPathComponent("identity.json")),
            let identity = try? JSONSerialization.jsonObject(with: data) as? [String: Any], identity["imei"] == nil,
            let upgraded = IPhoneIdentity.upgraded(identity)
        {
            return upgraded.udid
        }
        return instance.identity?.udid
    }

    private func preparedBootConfiguration(hardware: DeviceInfo?) -> BootConfig? {
        let prepared: PreparedDeviceBoot
        let machine: DeviceInfo
        do {
            guard let hardware else {
                throw DeviceToolsError.failed("The emulator library has no machine for this \(profile.shortName).")
            }
            machine = hardware
            prepared = try PreparedDeviceBoot.prepare(
                board: profile,
                base: instance.paths.base,
                overlay: overlayURL,
                writableNOR: instance.paths.writableNOR,
                storageKey: instance.storage.key,
                bootrom: BootRecipe.bootrom(profile.bootrom, filesRoot: Bundled.filesRoot),
                dieID: instance.identity?.dieID,
                panel: instance.panel
            )
        } catch PreparedDeviceBoot.Failure.baseMismatch {
            baseImageMismatch = true
            reportDeviceNotice("This \(profile.shortName)’s data was made with an older system image.", for: .erase)
            state = .dead(exitCode: 1)
            return nil
        } catch {
            failBoot(error)
            return nil
        }
        // Keep the bridge listening before the guest USB starts.
        let usbSession = usbmux.start(paths: instance.paths)
        openSerialLog()
        let netdev: String?
        let setupDone = FileManager.default.fileExists(atPath: BootRecipe.setupDoneMark(overlay: overlayURL).path)
        expectsSetup = BootRecipe.setupPhonesHome(iosVersion: iosVersion) && !setupDone
        // Setup's end is watched on every boot that shows it (the mark, the readiness text), networked or not.
        foreground.setupGate = expectsSetup ? BootRecipe.SetupNetworkGate() : nil
        foreground.liftsRestrict = false
        if profile.isKBoot {
            let restrict = network && expectsSetup
            netdev =
                network
                ? proxy.forward().map {
                    BootRecipe.wifiNetdev(guestForward: $0, restricted: restrict, localNetwork: localNetworkEnabled)
                } : nil
            foreground.liftsRestrict = netdev != nil && restrict
        } else {
            netdev =
                network
                ? BootRecipe.wifiNetdev(
                    guestForward: proxy.forward() ?? "",
                    restricted: false,
                    localNetwork: localNetworkEnabled
                ) : nil
        }
        do {
            return try prepared.configuration(
                hardware: machine,
                bootArgs: DeviceOptions.bootArgs(),
                usbAddress: usbSession?.guestAddress,
                wifi: network,
                guestPackage: guestPackage.compose(),
                serial: serialCapture?.argument ?? "null",
                // Every board: 16 CoreAudio buffers (186 ms) ride out a busy emulator thread. The A4 boards
                // had QEMU's default 4 (46 ms), and the iPod touch 4's sounds crackled on a slower Mac.
                audio: ["-audio", "driver=coreaudio,out.buffer-count=16"],
                netdev: netdev,
                carrier: profile.hasCellular ? carrierSettings : nil
            )
        } catch {
            failBoot(error)
            return nil
        }
    }

    private func openSerialLog() {
        do {
            serialCapture = try SerialLogCapture(
                url: instance.paths.logs.appendingPathComponent("serial.log"),
                watch: [BootWatch.recoveryMarker, BootWatch.ethlinkMarker] + BootStage.serialMarkers.keys
            ) { [weak self] phrase in
                Task { @MainActor in
                    guard let self else { return }
                    switch phrase {
                    case BootWatch.ethlinkMarker:
                        self.ethlinkUp = true
                        self.noteBoot(.guestTools)
                    case BootWatch.recoveryMarker:
                        self.inRecovery = true
                        self.abortBoot(BootWatch.recoveryReason(self.profile))
                    default: self.noteBoot(.serial(phrase))
                    }
                }
            }
        } catch { logEvent("logging: serial capture unavailable: \(error.localizedDescription)") }
    }

    // MARK: - Files under a running device

    @ObservationIgnored private var fileWatch: DeviceFileWatch?
    /// Something deleted, renamed or replaced the device's files while its helper
    /// had them open: the guest runs on dead inodes until Stop, which then quits
    /// without flushing into them.
    private(set) var filesMeddled = false

    private func startFileWatch() {
        guard fileWatch == nil, !filesMeddled else { return }
        let paths = instance.paths
        // Guest-owned files only; the app's own writes under Devices/<uuid> must not fire this.
        let nor = [paths.writableNOR].compactMap { $0 }.filter { !$0.path.hasPrefix(paths.overlay.path + "/") }
        fileWatch = DeviceFileWatch(directories: [paths.overlay], files: nor, base: paths.base) { [weak self] path in
            Task { @MainActor in self?.filesChanged(path) }
        }
    }

    private func filesChanged(_ path: String) {
        guard !filesMeddled, !isDead, !isPoweredOff else { return }
        filesMeddled = true
        fileWatch = nil
        logEvent("files: \(path) changed under the running device; Stop will quit without a flush")
        reportDeviceNotice(DeviceFileWatch.notice(shortName: profile.shortName), for: .files)
    }

    // MARK: - Boot deadline

    /// The boot deadline, recovery mode, a boot that can't be built and the helper's death (BootWatch).
    @ObservationIgnored private(set) lazy var bootWatch = BootWatch(host: self)
    /// Why the helper died, for the row and the dead overlay.
    var deathReason: String? { bootWatch.deathReason }
    private func failBoot(_ error: Error) { bootWatch.failBoot(error) }
    func startBootWatch() { bootWatch.start() }
    private func abortBoot(_ reason: String) { bootWatch.abort(reason) }

    /// iOS is up: lockdown answered (the helper's uiReady is QEMU's display, lit
    /// by iBoot too). Without a USB bridge (--no-appsync) painting has to do.
    var bootFinished: Bool { deviceReachable == true || (usbmux.session == nil && state == .running) }

    /// Status is read from the helper's shared block: the old per-frame poll,
    /// now on its own timer so a hidden device (no display link) still flips
    /// booting -> running, notices storage failures and its power-off.
    /// 30 Hz while the screen is on show, 4 Hz otherwise.
    private func startStatusPoll() {
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

    /// The guest's zone and region follow the Mac's (TimeZoneSync).
    @ObservationIgnored private lazy var timeZone = TimeZoneSync(host: self)
    private func stopTimeZoneSync() { timeZone.stop() }
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
    @concurrent private nonisolated static func unpackGuestTools() async { _ = Bundled.guestRoot }
    @concurrent private nonisolated static func lowSpaceWarning(at url: URL) async -> String? {
        IPSWStore.lowSpaceWarning(at: url)
    }

    /// The helper is gone (QEMU returned, it crashed or was killed). Flip to
    /// `.dead`; the window shows a Restart overlay, and the other devices keep running.
    private func helperDied(_ reason: String) { bootWatch.helperDied(reason) }

    func releaseBootResources() {
        fileWatch = nil
        statusTimer?.invalidate()
        statusTimer = nil
        audioSink?(.audioEnded(generation: 0, failed: true))
        usbmux.stop()
        serialCapture?.finish()
        serialCapture = nil
    }

    // MARK: - Liveness

    /// When the guest last painted a new frame. Advanced by the status poll on
    /// every new ring serial; the signal behind `booting → running`.
    @ObservationIgnored private(set) var lastFrameAdvance = Date.distantPast

    private func noteFrameAdvanced() {
        lastFrameAdvance = Date()
        if state.runsAfterFrame(poweringOn: poweringOn) {
            state = .running
            battery.apply()
            keyboard.applyHardware()
        }
    }

    /// Frames within the last ~2s. Not sufficient alone for "healthy": a
    /// locked/idle device legitimately stops painting.
    var framesRecentlyAdvanced: Bool {
        Date().timeIntervalSince(lastFrameAdvance) < 2.0
    }

    /// The helper's shared status block, so the status poll announces the flip (withMutation) for observers.
    var storageFailed: Bool {
        access(keyPath: \.storageFailed)
        return status?.storageFailed ?? false
    }
    /// The guest agent, live: 0 absent or not running, 1 alive, 2 stale.
    var liveAgentStatus: Int { status?.agentStatus ?? 0 }

    /// The agent's ping (its ops), until it restarts.
    let agentCache = GuestAgentCache()
    @ObservationIgnored private var lastAgentStatusCheck = Date.distantPast
    private var agentStatus = 0
    var agentStatusText: String {
        guard state == .running || state == .paused else { return "Waiting for device" }
        return agentStatus == 1 ? "Connected" : agentStatus == 2 ? "Not responding" : "Unavailable"
    }

    func pollStorageFailure() {
        guard let status else { return }
        if status.frameSerial != lastFrameSerial {
            lastFrameSerial = status.frameSerial
            noteFrameAdvanced()
        }
        if bootStage < .system,
            status.agentStatus == 1
                || (status.guestPackage != nil && status.guestPackage != readiness.reportAtBootStart)
        {
            noteBoot(.guestTools)
        }
        let now = Date()
        if now.timeIntervalSince(lastAgentStatusCheck) >= 1 {
            lastAgentStatusCheck = now
            if status.agentStatus != agentStatus {
                // A restarted agent may be a different version: ping it again.
                agentCache.reset()
                agentStatus = status.agentStatus
            }
            if status.agentStatus == 2 { agentStaleSince = agentStaleSince ?? now } else { agentStaleSince = nil }
        }
        if !poweringOn, status.shutdownConfirmed, !isDead, !isPoweredOff {
            // Publish terminal state before observable fields: their callbacks
            // must never render a stale running/sleeping subtitle mid-shutdown.
            state = .poweredOff
            retireBoot()
            foreground.forget()
            isSleeping = false
            deviceReachable = false
        }
        if state == .running, !preparingDevice, !shuttingDown {
            isSleeping = status.displaySleeping
        } else if isSleeping {
            isSleeping = false
        }

        if storageFailed, !reportedStorageFailure {
            reportedStorageFailure = true
            withMutation(keyPath: \.storageFailed) {}
            reportDeviceNotice(statusLine, for: .storage)
        }
    }

    var isRunning: Bool {
        state == .running && !storageFailed && !preparingDevice && readinessFailure == nil && !restartingSpringBoard
            && !shuttingDown && !isErasing
    }
    var isPaused: Bool { state == .paused }
    var isDead: Bool { if case .dead = state { return true } else { return false } }
    /// The guest takes input whenever its screen is live (state == .running: the display paints). Readiness —
    /// SpringBoard answering, a startup that judged failure — never holds it back.
    var acceptsInput: Bool {
        state == .running && !storageFailed && !restartingSpringBoard && !shuttingDown && !isErasing
    }

    /// One line for the window's status area.
    var statusLine: String {
        if isErasing { return "Erasing \(profile.shortName)…" }
        if storageFailed { return "Couldn’t save to disk — \(profile.shortName) stopped; recent changes weren’t saved" }
        if shuttingDown, !isPoweredOff { return isShuttingDownCleanly ? "Shutting down…" : "Stopping…" }
        switch state {
        case .poweredOff: return "Powered off"
        case .notStarted: return "Starting…"
        case .booting: return "Starting iOS…"
        case .running:
            if let issue = connectionIssue, issue.persistent { return issue.summary }
            if preparingDevice { return preparationStatus }
            if isSleeping { return "Sleeping" }
            if restartingSpringBoard { return "Restarting the Home screen…" }
            if let readinessFailure { return "Startup failed — \(readinessFailure)" }
            guard canManageApps else { return "Running — USB unavailable" }
            // Quiet when all is well; the guest tools only when they need attention.
            return guestToolsState.needsAttention ? "Running — " + guestToolsLine : "Running"
        case .paused: return "Paused"
        case .dead: return "Stopped"
        }
    }

    /// The "Guest tools" line: the loader's report as the package watch judged it
    /// (GuestPackage.status), overridden by what the boot and the agent show now.
    var guestToolsLine: String { "Guest tools: " + guestToolsState.text }
    var guestToolsState: GuestPackage.Status {
        if inRecovery { return .recovery }
        if !bootFinished { return .notBooted }
        let stale = agentStaleSince.map { Date().timeIntervalSince($0) > 60 } ?? false
        let reachable = reachableSince.map { Date().timeIntervalSince($0) > 60 } ?? false
        // The iPad has no agent: it_ethlink's serial line is its sign of life once a package carrying it runs.
        let ethlinkMissing =
            !hasGuestTools
            && GuestPackage.ethlinkSilent(
                offer: guestOffer,
                reportedSerial: status?.guestPackage?.serial,
                ethlinkUp: ethlinkUp,
                reachableForAMinute: reachable
            )
        if hasGuestTools ? stale : ethlinkMissing { return .notResponding }
        return guestToolsStatus
    }
    /// Set by the status poll: when the agent last went stale (2), nil while it answers.
    @ObservationIgnored private var agentStaleSince: Date?
    /// When lockdown first answered this boot.
    @ObservationIgnored private var reachableSince: Date?
    /// it_ethlink reported LinkStatus 0 -> 1 on serial (the iPad's guest package).
    private(set) var ethlinkUp = false
    /// This boot ends in Setup, not the Home screen: iOS 5 or later on an overlay that hasn't finished it.
    private(set) var expectsSetup = false
    private var inRecovery = false

    /// Which libqemu-arm.dylib this device's helper loaded, and when it was
    /// built (its hello). The dylib lives in a build tree other sessions rebuild
    /// under our feet; when "did this run have that fix?" comes up, this answers it.
    var dylibProvenance: String {
        guard let info = process?.info else { return "dylib: helper not connected" }
        return
            "dylib: \(info.dylibPath) (built \(Date(timeIntervalSince1970: info.dylibModified)), build \(info.buildID ?? "unknown"))"
    }

    private func logEmulatorBuild() { logEvent("emulator \(dylibProvenance)") }

    // MARK: - Input

    /// The hardware buttons, shake, tilt, pasting and typing (DeviceInput); the keyboard is KeyboardInput.
    @ObservationIgnored private(set) lazy var input = DeviceInput(host: self, settings: settingsFile)
    typealias Button = DeviceInput.Button
    func pressHome() { input.tap(.home) }
    func pressLock() { input.tap(.power) }
    func pressVolumeUp() { input.tap(.volumeUp) }
    func pressVolumeDown() { input.tap(.volumeDown) }
    func rotateLeft() { rotation.rotateLeft() }
    func rotateRight() { rotation.rotateRight() }
    var shakeGeneration: UInt64 { input.shakeGeneration }
    func shake() { input.shake() }
    typealias MotionPose = DeviceInput.MotionPose
    var motionPose: MotionPose { input.motionPose }
    func setMotionPose(_ pose: MotionPose) { input.setMotionPose(pose) }
    func setTilt(angle: Double, pitch: Double = 0) { input.setTilt(angle: angle, pitch: pitch) }
    func pasteToGuest(_ text: String) { input.paste(text) }
    func typeText(_ text: String, shiftHeld: Bool) { input.typeText(text, shiftHeld: shiftHeld) }
    func typeThroughAgent(_ text: String) async -> Bool {
        let agent = guestAgent
        guard (try? await agent.capabilities().has("type")) == true else { return false }
        return (try? await agent.perform("type", body: Data(text.utf8))) != nil
    }

    /// A control request; `done(true)` when the machine applied it (false on a
    /// machine without the control, the iPod, or from a helper that's gone).
    private func control(_ request: LinkRequest, _ done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        bootScope.control(request, on: link, done)
    }

    // MARK: Battery, charger and compass

    /// The Battery menu (BatteryControls): every boot starts from it (at its first frame); a new QEMU otherwise
    /// starts at its own 80% while the menu still shows the choice.
    @ObservationIgnored private(set) lazy var battery = BatteryControls(
        canChooseUSBCharger: profile.canChooseUSBCharger,
        scope: bootScope
    ) {
        [weak self] request, done in self?.control(request, done)
    }
    var batteryLevel: Int { battery.level }
    var batteryCharging: Bool { battery.charging }
    func setBattery(level: Int) { battery.setLevel(level) }
    func setCharging(_ on: Bool) { battery.setCharging(on) }

    private(set) var compassHeading: Int?
    var hasCompass: Bool { profile.hasCompass }
    func setCompassHeading(_ degrees: Int) {
        control(.compass(degrees)) { [weak self] applied in if applied { self?.compassHeading = degrees } }
    }
    // Location comes later (a4-iboot's location responder); it will sit here
    // beside the compass as another control request.

    private(set) var usbConnected = true
    func reconnectUSB() {
        guard !usbConnected else { return }
        control(.usbConnection(true)) { [weak self] attached in
            guard attached, let self else { return }
            usbConnected = true
            deviceReachable = nil
        }
    }

    // MARK: - Rotation

    /// The quarter turns and auto-rotation with the guest (DeviceRotation).
    @ObservationIgnored private(set) lazy var rotation = DeviceRotation(
        host: self,
        settings: settingsFile,
        setsAccelerometer: profile.orientationSource == .springBoard
    )
    var rotationDegrees: Int { rotation.degrees }
    var isLandscape: Bool { rotation.isLandscape }
    func toggleRotation() { rotation.toggle() }
    func rotate(clockwise: Bool) { rotation.rotate(clockwise: clockwise) }
    var autoRotateEnabled: Bool { rotation.autoRotateEnabled }
    func toggleAutoRotate() { rotation.toggleAutoRotate() }
    func startOrientationWatch() { rotation.startGuestWatch() }
    func resetRotation() { rotation.reset() }

    // MARK: Carrier (radio boards)

    /// The fake network's settings and the running modem (CarrierModem).
    @ObservationIgnored private(set) lazy var carrier = CarrierModem(
        hasCellular: profile.hasCellular,
        settings: settingsFile,
        scope: bootScope
    ) { [weak self] in self?.link }
    var hasCellular: Bool { carrier.hasCellular }
    var carrierSettings: CarrierSettings { carrier.carrierSettings }
    @discardableResult
    func setCarrierSettings(_ settings: CarrierSettings) -> Bool { carrier.setCarrierSettings(settings) }
    func modem(_ property: String, _ value: String, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        carrier.modem(property, value, done: done)
    }
    func modemStatus(_ done: @escaping @MainActor (ModemStatus?) -> Void) { carrier.modemStatus(done) }

    // MARK: - Options

    /// Attach to Local Network, the debug port and the boot arguments (DeviceOptions).
    @ObservationIgnored private(set) lazy var options = DeviceOptions(settings: settingsFile, board: instance.board) {
        [weak self] in self?.link
    }
    var localNetworkEnabled: Bool { options.localNetworkEnabled }
    func toggleLocalNetwork() { options.toggleLocalNetwork() }
    var debugPortEnabled: Bool { options.debugPortEnabled }
    func toggleDebugPort() { options.toggleDebugPort() }
    var debugPort: Int? { options.debugPort }
    var lldbAttachCommand: String? { options.lldbAttachCommand }

    // MARK: - Guest package

    /// This boot's offer and its verdict (GuestPackageWatch).
    @ObservationIgnored private(set) lazy var guestPackage = GuestPackageWatch(host: self, stateDirectory: stateDir)
    var guestOffer: GuestPackage.Offer? { guestPackage.offer }
    var guestToolsStatus: GuestPackage.Status { guestPackage.status }
    func startGuestPackageWatch() { guestPackage.start() }
    private var recordURL: URL { guestPackage.recordURL }
    private var lock: DeviceLock? { guestPackage.lock }

    /// View ▸ Free-Form Screen (issue #21): the record's `panel`, read fresh and written back ("WxH" as the panel
    /// scans; nil, the shipped panel). With `restart`, a running device stops (Stop's hard halt) and a fresh helper
    /// boots on it, since the guest takes its screen size at boot. Returns whether that restart is under way.
    func setPanel(_ panel: String?, restart: Bool) -> Bool {
        guard var record = try? DeviceInstance.read(recordURL) else { return false }
        if record.panel != panel {
            record.panel = panel
            do {
                try record.write(state: stateDir)
                DeviceLibrary.shared.reload()
            } catch {
                logEvent("display: could not record panel \(panel ?? "native"): \(error.localizedDescription)")
                return false
            }
        }
        instance.panel = panel
        guard restart, canStop else { return false }
        logEvent("display: restarting \(instance.name) at panel \(panel ?? "native")")
        halt { [weak self] _ in self?.onRestartRequested?() }
        return true
    }

    // MARK: - Keyboard passthrough

    /// Keyboard passthrough and Connect Hardware Keyboard (KeyboardInput), per device.
    @ObservationIgnored private(set) lazy var keyboard = KeyboardInput(
        settings: settingsFile,
        canToggleHardwareKeyboard: profile.canToggleHardwareKeyboard,
        control: { [weak self] request, done in self?.control(request, done) },
        send: { [weak self] command in self?.link?.send(command) },
        canPress: { [weak self] in self.map { $0.acceptsInput && !$0.isSleeping } ?? false }
    )
    var keyboardInputEnabled: Bool { keyboard.enabled }
    func toggleKeyboardInput() { keyboard.toggleEnabled() }
    /// Connect Hardware Keyboard (⇧⌘K, per device): unplugged, iOS shows its on-screen keyboard in a text field.
    var hardwareKeyboardConnected: Bool { keyboard.hardwareConnected }
    func toggleHardwareKeyboard() { keyboard.toggleHardware() }
    func sendKey(macKeyCode: UInt16, down: Bool) { keyboard.sendKey(macKeyCode: macKeyCode, down: down) }

    // MARK: - Machine control
    //
    // pause() and resume() are MachineHost's; Restart and Power On are BootCycle's.

    /// Restart and Power On in place (BootCycle).
    @ObservationIgnored private(set) lazy var cycle = BootCycle(host: self)
    private var poweringOn: Bool { cycle.poweringOn }
    /// Restart the guest, its filesystem synced first.
    func reset() { cycle.reset() }
    /// Retain the QEMU main loop at guest power-off; a reset can cold boot it
    /// again without reinitializing QEMU or opening a second NAND writer.
    func powerOff(completion: @escaping (Bool) -> Void) { ladder.forceStop(completion: completion) }
    func powerOn() { cycle.powerOn() }

    var isReleased: Bool { stopped || releasing }
    func syncGuest() async throws { try await guestAgent.sync() }
    func forgetConnectionWork() {
        didSweepStaging = false
        recovery.isReconnecting = false
    }
    func forgetGuestFacts() {
        foreground.forget()
        isSleeping = false
    }
    func forgetReachability() {
        deviceReachable = nil
        reachableSince = nil
    }
    func forgetEthlink() { ethlinkUp = false }

    func startForegroundWatch() { foreground.start() }
    var hasPendingInstallWork: Bool { AppInstaller.hasPendingWork(for: instance.id) }
    var overlay: URL { overlayURL }
    func foregroundApp() async throws -> (bundleID: String, name: String?) { try await guest.foreground() }
    func applyWebProxy(since applied: Int?, generation: Int) async throws -> Int? {
        try await proxy.apply(since: applied, isCurrent: { generation == self.bootGeneration }) { enabled in
            try await WebProxySetup(
                services: self.services,
                guest: self.guest,
                proxyDirectory: self.proxyDirectory,
                stoppedTrust: self.trustsStopped ? (self.instance.paths.directory, self.instance.storage.key) : nil
            )
            .configure(enabled: enabled)
        }
    }
    func setupFinished(generation: Int) { timeZone.schedule(generation: generation) }

    /// Guest audio for a recording (ScreenMovieWriter). Its clock is the
    /// dylib's: monotonic seconds since the capture started.
    func startAudioCapture() async throws -> GuestAudioCapture {
        guard let link, !isDead else { throw CaptureError.failed("The device is not ready to record audio.") }
        let origin = ProcessInfo.processInfo.systemUptime
        let capture = GuestAudioCapture(
            clock: { ProcessInfo.processInfo.systemUptime - origin },
            stop: { generation in link.send(.audioStop(generation: generation)) }
        )
        audioSink = { [weak capture] event in capture?.receive(event) }
        guard case .audio(let generation) = try await link.request(.audioStart) else {
            throw CaptureError.failed("The device is not ready to record audio.")
        }
        capture.begin(generation: generation)
        return capture
    }

    // MARK: - Device storage paths

    /// Saved-state files older builds wrote beside the overlay; Erase removes them.
    private var snapshotURL: URL { instance.paths.snapshot }
    private var snapshotTmpURL: URL { snapshotURL.appendingPathExtension("tmp") }
    private var snapshotBadURL: URL { snapshotURL.appendingPathExtension("bad") }
    private var overlayURL: URL { instance.paths.overlay }
    /// The device's private NOR copy, which pairs with its overlay: Erase removes it too, and the
    /// next boot clones base/nor.bin again.
    private var preparedNORURL: URL? { instance.paths.writableNOR }
    /// Stop, Force Stop and Shut Down (ShutdownLadder): Stop is a hard halt, never a guest shutdown.
    @ObservationIgnored private(set) lazy var ladder = ShutdownLadder(host: self)
    static let haltBudget: TimeInterval = ShutdownLadder.Budgets().halt
    /// The quit backstop: the halt, then the kill, then the services worker.
    static let stopBudget: TimeInterval = ShutdownLadder.Budgets().stop
    var shuttingDown: Bool { ladder.shuttingDown }
    var halting: Bool { ladder.halting }
    /// A live helper whose VM can be stopped, including mid-boot.
    var canStop: Bool { ladder.canStop }
    /// Force Stop: Stop's hard halt, also while a Shut Down is under way (one the guest never finishes).
    var canForceStop: Bool { ladder.canForceStop }
    var canShutDown: Bool { ladder.canShutDown }
    var isShuttingDownCleanly: Bool { ladder.isShuttingDownCleanly }
    /// The guest powers itself off, as the slider does; the helper stays, powered off.
    func shutDown(completion: @escaping (Bool) -> Void) { ladder.shutDown(completion: completion) }
    /// `completion(true)` iff the helper is gone.
    func halt(completion: @escaping (Bool) -> Void) { ladder.halt(completion: completion) }
    func willStop() {
        AppInstaller.discard(for: instance.id)
        stopTimeZoneSync()
    }

    /// Erase All Content and Settings (DeviceErase).
    @ObservationIgnored private lazy var eraser = DeviceErase(host: self)
    func requestFactoryReset() { eraser.request() }
    var eraseTargets: DeviceErase.Targets {
        DeviceErase.Targets(
            overlay: overlayURL,
            snapshots: [snapshotURL, snapshotTmpURL, snapshotBadURL],
            preparedNOR: preparedNORURL,
            state: stateDir,
            owner: instance.id
        )
    }
    func discardInstalls() { AppInstaller.discard(for: instance.id) }
    func stopGuestWatches() {
        foreground.stop()
        rotation.stopWatching()
    }
    func restart() { onRestartRequested?() }

    // MARK: - App management

    /// Reaching the device's services, installs and media imports, restarting the Home screen (DeviceApps).
    @ObservationIgnored private(set) lazy var apps = DeviceApps(host: self)
    var canManageApps: Bool { apps.canManageApps }
    var canReachDevice: Bool { apps.canReachDevice }
    var canQueueInstall: Bool { apps.canQueueInstall }
    var isInstalling: Bool { apps.isInstalling }
    private var restartingSpringBoard: Bool { apps.restartingSpringBoard }
    /// The usbmuxd socket to talk to this device on, for the long-lived
    /// notification_proxy watcher (which owns its own session, not a gated one).
    var usbmuxSession: String? { usbmux.session?.clientSocket }

    /// The guest agent through this device's helper, and the app's operations on it.
    var guestAgent: GuestAgent { GuestAgent(link: link, cache: agentCache) }
    var guest: GuestServices { GuestServices(agent: guestAgent, packaged: status?.guestPackage != nil) }
    var services: DeviceServices { get throws { try apps.services } }
    var installPipeline: AppInstallPipeline { get throws { try apps.installPipeline } }
    func deviceReady() async -> Bool { await apps.deviceReady() }
    func checkDeviceConnection() async throws { try await apps.checkDeviceConnection() }
    func restartSpringBoard() async throws { try await apps.restartSpringBoard() }
    var hasSpringBoardServices: Bool { apps.hasSpringBoardServices }
    func waitForSpringBoard(agentCounts: Bool = false) async throws {
        try await apps.waitForSpringBoard(agentCounts: agentCounts)
    }
    func install(
        _ ipa: URL,
        placeholderRaised: Bool = false,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        try await apps.install(ipa, placeholderRaised: placeholderRaised, progress: progress)
    }
    func importMedia(
        _ media: PreparedMedia,
        progress: @escaping @Sendable (Double) -> Void,
        willCommit: () -> Void
    ) async throws {
        try await apps.importMedia(media, progress: progress, willCommit: willCommit)
    }

    /// The guest's orientation in degrees; nil when this image has no agent.
    /// Failures must not start a second transport.
    func guestOrientation() async throws -> Int? {
        _ = try services
        guard guestAgent.status != 0 else { return nil }
        return try await guestAgent.orientation()
    }
    func interfaceOrientation() async throws -> Int { try await services.interfaceOrientation() }

    /// This device's firmware, from its catalog entry: what an app's minimum
    /// iOS and architecture are checked against.
    private var catalogEntry: FirmwareCatalog.Entry? { FirmwareCatalog.bundled.entry(id: instance.firmware) }
    var iosVersion: String { catalogEntry?.version ?? "3.1.3" }
    /// "iPod2,1": the model Legacy Store judges apps for, with iosVersion.
    var productType: String? { catalogEntry?.productType }
    var guestArch: String { catalogEntry?.recipe?.guest?.arch ?? profile.arch }
    /// What the media gate reads (MediaSupport).
    var mediaFirmware: MediaSupport.Firmware {
        MediaSupport.Firmware(
            version: iosVersion,
            name: (["iOS \(iosVersion)"] + [catalogEntry?.prereleaseBadge].compactMap { $0 }).joined(separator: " "),
            media: catalogEntry?.media ?? [],
            prerelease: catalogEntry?.prerelease != nil
        )
    }

    // MARK: - Activation (prepared offline, completed and verified per boot)

    /// The once-per-boot activation verdict (ActivationCheck).
    @ObservationIgnored private lazy var activation = ActivationCheck(
        host: self,
        services: self,
        recovery: recovery,
        readiness: readiness,
        notices: notices
    )
    func activationState() async -> String? { await (try? services)?.activationState() }
    func finishActivation() async throws { try await services.finishActivation() }
    func installProxyReady() async -> Bool { await (try? services)?.installProxyReady() == true }

    // launchApp(_:) is AppLaunchHost's: a sleeping display is woken first.
    var displaySleeping: Bool? { status?.displaySleeping }
    func checkServices() throws { _ = try services }
    func launchInGuest(_ bundleID: String) async throws { try await guest.launch(bundleID) }

    // MARK: - Boot environment (DeviceOptions)

    static let verboseBootDefaultsKey = DeviceOptions.verboseBootDefaultsKey
    static var verboseBoot: Bool { UserDefaults.standard.bool(forKey: verboseBootDefaultsKey) }
    static let kernelConsoleDefaultsKey = DeviceOptions.kernelConsoleDefaultsKey
    static var kernelConsole: Bool { UserDefaults.standard.bool(forKey: kernelConsoleDefaultsKey) }

}

// The session's state machines (LightTouchCore/Session) run against the controller through these.
extension EmulatorController: MachineHost, ConnectionHost, ActivationServices, ReadinessHost, BootWatchHost,
    ShutdownHost, EraseHost, BootCycleHost, AppLaunchHost, RotationHost,
    InputHost, GuestPackageHost, TimeZoneHost, AppsHost,
    ForegroundHost
{
    var helper: DeviceHelper? { process }
    var helperLink: HelperLink? { link }
    var isPainting: Bool { state == .running }
    func readyForInput() { deviceReachable = true }
    var bootStageText: String { bootStage.text(expectingSetup: expectsSetup) }
}
