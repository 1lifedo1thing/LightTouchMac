// The sidebar's world, as the app singletons it asks would answer: a host over a catalog with prepared, downloaded and
// running sets and a slow (or failing) fake removal through the real DeviceDeletions, the jobs, the library.
import Cocoa
import LightTouchCore

final class FirmwareJobs {
    static let shared = FirmwareJobs()
    static let didChangeNotification = Notification.Name("FirmwareJobsDidChange")
    var jobs: [String: FirmwareJob] = [:] {
        didSet { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
    }
    func dismissFailure(_ entry: FirmwareCatalog.Entry) {
        if case .failed? = jobs[entry.id] { jobs[entry.id] = nil }
    }
}
struct StubInstance { let firmware: String }
final class DeviceLibrary {
    static let didChangeNotification = Notification.Name("DeviceLibraryDidChange")
    var instances: [StubInstance] = []
}
extension FirmwareCatalog.Entry.Status {
    static let allCasesForCheck: [Self] = [.available, .experimental, .untested, .comingSoon, .userIPSW]
}
final class EmulatorController { var canQueueInstall = false }
final class DeviceSession {
    let emulator = EmulatorController()
    var phase: SessionPhase { .running }
}
nonisolated enum PreparedMedia { static let extensions: Set<String> = [] }
enum AppInstaller { static func start(_ url: URL, with emulator: EmulatorController, presenting: NSWindow?) {} }
final class DeviceSessionHost {
    static let didChangeNotification = Notification.Name("DeviceSessionHostDidChange")
    let catalog: FirmwareCatalog
    let library = DeviceLibrary()
    var prepared: [String: UUID] = [:]
    var downloaded: Set<String> = []
    var running: Set<String> = []
    var sessions: [DeviceSession] = []
    var deleted: [String] = []
    let deletions = DeviceDeletions()
    /// The fake removal: this long on its thread, then a throw when `failing`.
    var deleteSeconds = 0.0
    var failing = false
    struct Failed: LocalizedError { var errorDescription: String? { "The device’s folder couldn’t be removed." } }
    func delete(_ instance: StubInstance) -> Task<Void, Error> {
        let seconds = deleteSeconds
        let failing = failing
        let id = instance.firmware
        let removal = deletions.run(id) {
            Thread.sleep(forTimeInterval: seconds)
            if failing { throw Failed() }
        }
        return Task {
            try await removal.value
            deleted.append(id)
            prepared[id] = nil
        }
    }
    init(catalog: FirmwareCatalog) {
        self.catalog = catalog
        deletions.onChange = { NotificationCenter.default.post(name: Self.didChangeNotification, object: nil) }
    }
    func instance(for entry: FirmwareCatalog.Entry) -> StubInstance? {
        prepared[entry.id].map { _ in StubInstance(firmware: entry.id) }
    }
    func session(for entry: FirmwareCatalog.Entry) -> DeviceSession? { nil }
    func row(for entry: FirmwareCatalog.Entry) -> DeviceRow {
        DeviceRow(
            entry: entry,
            instanceID: prepared[entry.id],
            session: running.contains(entry.id) ? .running : nil,
            job: FirmwareJobs.shared.jobs[entry.id],
            downloaded: downloaded.contains(entry.id),
            deleting: deletions.contains(entry.id)
        )
    }
}
