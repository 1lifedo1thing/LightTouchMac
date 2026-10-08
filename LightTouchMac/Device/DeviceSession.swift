// One device the window can show: its record, the controller that runs it,
// and the view controllers cached for it.
//
// DeviceSessionHost owns the sessions. Each running device is its own
// LightTouchDevice helper (DeviceProcess), so any number can run at once, a
// dead one restarts without the app, and the others never notice.

import Cocoa
import FirmwareSchema
import HostRuntime
import LightTouchCore

// MARK: - Sessions

/// The views one device keeps while it runs, so switching back to it is
/// instant. A hidden DisplayView stops its own display link.
@MainActor final class DeviceWorkspace {
    let deviceVC: DeviceViewController
    let inspectorVC: AppsInspectorViewController
    private(set) lazy var canvasCapture = CanvasCapture(view: deviceVC.screen, profile: deviceVC.emulator.profile)

    init(emulator: EmulatorController) {
        deviceVC = DeviceViewController(emulator: emulator)
        inspectorVC = AppsInspectorViewController(emulator: emulator)
    }
}

/// A started device: its record and the controller that runs its helper.
/// A restart replaces the whole session (DeviceSessionHost.restart).
/// Its state is the controller's, observable: observers track what they show (ObservationLoop).
@MainActor final class DeviceSession {
    var instance: DeviceInstance { emulator.instance }
    let emulator: EmulatorController
    var profile: Board { emulator.profile }
    private(set) lazy var workspace = DeviceWorkspace(emulator: emulator)

    init(emulator: EmulatorController) { self.emulator = emulator }

    var phase: SessionPhase {
        if emulator.isDead {
            return .dead(
                emulator.baseImageMismatch
                    ? "This \(profile.shortName)’s data was made with an older system image."
                    : emulator.deathReason ?? profile.stoppedReason
            )
        }
        if emulator.isErasing || (emulator.shuttingDown && !emulator.isPoweredOff) { return .stopping }
        return emulator.isPoweredOff ? .stopped : .running
    }
}

extension DeviceSession: LibrarySession {
    var ladder: ShutdownLadder { emulator.ladder }
    func release() async -> Bool { await emulator.release() }
}

/// Every session this process has started, the library rows, and the one
/// launch-selection default.
@MainActor final class DeviceSessionHost {
    /// Posted on the main actor when the session collection changes.
    static let didChangeNotification = Notification.Name("DeviceSessionHostDidChange")
    private static let lastDeviceKey = "lastDevice"

    let library: DeviceLibrary
    let catalog: FirmwareCatalog
    private(set) var sessions: [DeviceSession] = []

    /// The one host this process runs (AppDelegate's), for the places that
    /// need every running device rather than their own: "Install on ▸".
    private(set) static weak var shared: DeviceSessionHost?

    init() {
        library = .shared
        catalog = .bundled
        Self.shared = self
        libraryObserver = NotificationCenter.default.addObserver(
            forName: DeviceLibrary.didChangeNotification,
            object: library,
            queue: nil
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stopVanished() } }
    }

    // MARK: Vanished folders

    private var libraryObserver: NSObjectProtocol?
    private let vanished = VanishedDevices()

    /// A device folder left Devices/ behind the app's back: its session stops and goes (VanishedDevices).
    private func stopVanished() {
        vanished.stop(sessions, library: library) { [weak self] session in
            guard let self else { return }
            sessions.removeAll { $0 === session }
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    func session(for entry: FirmwareCatalog.Entry) -> DeviceSession? {
        sessions.first { $0.instance.firmware == entry.id }
    }

    /// The device a row runs: its session's, else the newest record. One per entry for now.
    func instance(for entry: FirmwareCatalog.Entry) -> DeviceInstance? {
        session(for: entry)?.instance ?? library.instances(firmware: entry.id).last
    }

    func row(for entry: FirmwareCatalog.Entry) -> DeviceRow {
        let instance = instance(for: entry)
        return DeviceRow(
            entry: entry,
            instanceID: instance?.id,
            session: session(for: entry)?.phase,
            job: FirmwareJobs.shared.jobs[entry.id],
            downloaded: entry.source.sha1.map { IPSWStore.shared.existing($0) != nil } ?? false,
            preparedWithoutActivation: instance.map(lacksActivation) ?? false,
            baseRecipe: instance.flatMap(baseRecipe),
            deleting: deletions.contains(entry.id)
        )
    }

    /// Read once per device, like lacksActivation.
    private var baseRecipes: [UUID: Int?] = [:]
    private func baseRecipe(_ instance: DeviceInstance) -> Int? {
        if let known = baseRecipes[instance.id] { return known }
        let version = DeviceRow.baseRecipeVersion(
            instance.paths.base.appendingPathComponent(DeviceLock.fileName),
            device: instance.paths.directory
        )
        baseRecipes[instance.id] = version
        return version
    }

    /// Read once per device: the lock doesn't change while the app runs.
    private var activationless: [UUID: Bool] = [:]
    private func lacksActivation(_ instance: DeviceInstance) -> Bool {
        if let known = activationless[instance.id] { return known }
        let lacks = DeviceInstance.lockLacksActivation(instance.paths.base.appendingPathComponent(DeviceLock.fileName))
        activationless[instance.id] = lacks
        return lacks
    }

    // MARK: Launch

    /// The last selected entry, persisted on every selection change.
    var lastSelection: FirmwareCatalog.Entry? {
        get { UserDefaults.standard.string(forKey: Self.lastDeviceKey).flatMap(catalog.entry(id:)) }
        set { UserDefaults.standard.set(newValue?.id, forKey: Self.lastDeviceKey) }
    }

    /// The last selection, else the catalog's first-run device.
    var launchSelection: FirmwareCatalog.Entry? { lastSelection ?? catalog.firstRunEntry }

    // MARK: Starting

    /// Starts the entry's device in its own helper. The session reports any
    /// boot failure through its controller. Any number of devices can run at once.
    @discardableResult
    func start(_ entry: FirmwareCatalog.Entry) -> DeviceSession? {
        if let session = session(for: entry) { return session }
        guard !deletions.contains(entry.id) else { return nil }
        library.reload()  // offline publication may have selected another generation
        guard let instance = instance(for: entry), let profile = entry.profile else { return nil }
        let network = NetworkAccessPreference.resolve(profile: profile)
        let session = DeviceSession(
            emulator: EmulatorController(instance: instance, profile: profile, network: network)
        )
        sessions.append(session)
        session.emulator.onStorageGenerationChanged = { [weak self] in
            self?.baseRecipes.removeAll()
            self?.library.reload()
        }
        session.emulator.onRestartRequested = { [weak self, weak session] in
            if let self, let session { restart(session) }
        }
        // Before any workspace exists: the inspector checks the usbmux
        // session when its view loads.
        session.emulator.start()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return session
    }

    /// Replaces a session with a fresh helper: the dead overlay's Restart, a
    /// restore that never came alive, and the boot after an erase. The old
    /// helper is gone before the new one opens the same overlay; nothing else
    /// (the app, the other devices) stops.
    func restart(_ session: DeviceSession) {
        let id = session.instance.id
        guard sessions.contains(where: { $0 === session }), !restarting.contains(id),
            let entry = catalog.entry(id: session.instance.firmware)
        else { return }
        restarting.insert(id)
        logEvent("device: restarting \(session.instance.name)")
        Task {
            let released = await session.emulator.release()
            restarting.remove(id)
            guard released else {
                logEvent(
                    "device: \(session.instance.name)'s helper did not exit; not starting a second one on its storage"
                )
                return
            }
            sessions.removeAll { $0 === session }
            start(entry)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    /// Drop a shut-down or dead session before its storage changes (offline editing, Delete, Prepare Again); the next
    /// launch loads the newly published record rather than its cached generation. False while it runs.
    func releaseStopped(for entry: FirmwareCatalog.Entry) async -> Bool {
        guard let session = session(for: entry) else { return true }
        guard await session.releaseIfStopped() else { return false }
        sessions.removeAll { $0 === session }
        library.reload()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return true
    }

    private var restarting: Set<UUID> = []

    /// A controller for a device that isn't running, which never starts: the
    /// erase it runs is the one a running device gets.
    func stoppedController(for entry: FirmwareCatalog.Entry) -> EmulatorController? {
        guard session(for: entry) == nil, let instance = instance(for: entry), let profile = entry.profile else {
            return nil
        }
        return EmulatorController(instance: instance, profile: profile)
    }

    // MARK: Deleting

    /// Deletions in flight; their rows show Deleting and can't start.
    private(set) lazy var deletions: DeviceDeletions = {
        let deletions = DeviceDeletions()
        deletions.onChange = { [weak self] in
            guard let self else { return }
            library.reload()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
        return deletions
    }()

    /// Removes a device off the main actor: its directory (record, base, overlay, pairing), its logs and its
    /// settings. A shut-down or dead session is released first; a running one throws DeviceInUse. Its row says
    /// Deleting from now until the task ends.
    @discardableResult
    func delete(_ instance: DeviceInstance) -> Task<Void, Error> {
        let state = library.state
        let logs = instance.paths.logs
        let entry = catalog.entry(id: instance.firmware)
        return deletions.run(
            instance.firmware,
            release: { [weak self] in
                guard let self, let entry else { return true }
                return await releaseStopped(for: entry)
            }
        ) {
            try DeviceStateStorage.removeDevice(instance.id, state: state)
            try? DeviceStateStorage.removeTree(logs)
        }
    }
}
