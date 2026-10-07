import LightTouchCore
import HostServiceWire
import HostRuntime
import Cocoa

/// A stopped generation is mounted by FirmwareKit; a durable intent keeps the
/// helper out even if this GUI quits. No filesystem writer lives in the GUI.
/// Boards without a stopped edit get a read-only view instead: `firmwarekit mount`,
/// the volumes rebuilt into images and attached read-only, detached at Start or quit.
@MainActor
final class DeviceFilesystemEdits {
    static let shared = DeviceFilesystemEdits()
    /// Posted when a device's `activity` changes.
    static let didChangeNotification = Notification.Name("DeviceFilesystemEditsDidChange")
    /// What each device's filesystem operation is doing now ("Reading the file system…"), for the device area; a
    /// device with an entry here can't start or open another.
    private(set) var activity: [UUID: String] = [:] {
        didSet { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
    }
    private var busy: Set<UUID> { Set(activity.keys) }
    /// A 1.x device whose storage wasn't shut down cleanly can't be opened; this offers to shut it down first.
    var onUncleanShutdown: ((FirmwareCatalog.Entry) -> Void)?
    struct Intent: Decodable { let id: UUID; let phase: String }
    struct Mounted: Decodable { let id: UUID; let mountPoint: String? }
    func pending(_ instance: DeviceInstance) -> Intent? {
        try? JSONDecoder().decode(Intent.self, from: Data(contentsOf: instance.paths.work.appendingPathComponent("edit.json")))
    }
    func blocked(_ instance: DeviceInstance) -> Bool {
        busy.contains(instance.id) || FileManager.default.fileExists(atPath: instance.paths.work.appendingPathComponent("edit.json").path)
    }
    /// Start may go ahead after saving or discarding an open edit (`editing`, startAfterEdit); anything else in
    /// flight, or an edit stuck mid-commit (Finish Filesystem Recovery), holds it.
    func blocksStart(_ instance: DeviceInstance) -> Bool {
        busy.contains(instance.id) || (blocked(instance) && pending(instance)?.phase != "editing")
    }
    /// An edit open in Finder: Start asks to save or discard it first.
    func hasOpenEdit(_ instance: DeviceInstance) -> Bool { !busy.contains(instance.id) && pending(instance)?.phase == "editing" }
    func canPerform(_ action: DeviceAction, instance: DeviceInstance) -> Bool {
        guard FirmwareJobs.preparer != nil, !busy.contains(instance.id) else { return false }
        guard instance.profile?.editableStopped == true else {
            return action == .openFilesystem && instance.profile?.browsableStopped == true
        }
        switch action {
        case .openFilesystem: return pending(instance)?.phase == nil || pending(instance)?.phase == "editing"
        case .commitFilesystem: return pending(instance)?.phase == "editing"
        case .recoverFilesystem: return pending(instance).map { $0.phase != "editing" } == true
        case .discardFilesystem: return pending(instance)?.phase == "editing"
        default: return false
        }
    }
    func perform(_ action: DeviceAction, entry: FirmwareCatalog.Entry, host: DeviceSessionHost) {
        guard let instance = host.instance(for: entry), let executable = FirmwareJobs.preparer,
              canPerform(action, instance: instance) else { return }
        activity[instance.id] = switch action {
        case .commitFilesystem: "Saving the file system…"
        case .discardFilesystem: "Discarding changes…"
        case .recoverFilesystem: "Recovering the file system…"
        default: "Reading the file system…"
        }
        Task {
            defer {
                activity[instance.id] = nil
                host.library.reload()
                NotificationCenter.default.post(name: DeviceLibrary.didChangeNotification, object: host.library)
            }
            do {
                guard await host.releaseStopped(for: entry) else {
                    throw DeviceToolsError.failed("Stop the device before opening its filesystem.")
                }
                guard instance.profile?.editableStopped == true else { return try await browse(instance, executable: executable) }
                var intent = pending(instance)
                let prefix = ["edit", "--device", instance.paths.directory.path, "--record-policy", "managed"]
                if action == .openFilesystem, intent == nil {
                    let result = try await FirmwareTool.run(prefix + ["--action", "begin"], executable: executable)
                    let created = try JSONDecoder().decode(Mounted.self, from: result)
                    intent = Intent(id: created.id, phase: "editing")
                }
                guard let intent else { throw DeviceToolsError.failed("The edit session is unavailable.") }
                let operation: String = switch action {
                case .openFilesystem: "mount"
                case .commitFilesystem: "commit"
                case .discardFilesystem: "discard"
                case .recoverFilesystem: "recover"
                default: throw DeviceToolsError.failed("Unsupported filesystem action.")
                }
                if action == .openFilesystem { activity[instance.id] = "Opening in Finder…" }
                let result = try await FirmwareTool.run(prefix + ["--action", operation, "--session", intent.id.uuidString], executable: executable)
                if action == .openFilesystem, let path = try JSONDecoder().decode(Mounted.self, from: result).mountPoint {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            } catch {
                if "\(error)".contains("was not shut down cleanly"), let onUncleanShutdown { onUncleanShutdown(entry) }
                else { NSApp.presentError(error) }
            }
        }
    }

    // MARK: - Read-only view

    private func browseDirectory(_ id: UUID) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LightTouch-files-\(id.uuidString)", isDirectory: true)
    }

    private func browse(_ instance: DeviceInstance, executable: URL) async throws {
        try await endBrowsing(instance.id, executable: executable)
        let out = browseDirectory(instance.id)
        let result = try await FirmwareTool.run(["mount", "--device", instance.paths.directory.path, "--record-policy", "managed",
                                                 "--out", out.path], executable: executable)
        struct Volume: Decodable { let mountPoint: String? }
        for line in result.split(separator: UInt8(ascii: "\n")) {
            if let path = (try? JSONDecoder().decode(Volume.self, from: Data(line)))?.mountPoint {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    /// Before Start: the read-only view detached, or an open edit saved (`commit`) or discarded. Throws when an edit
    /// couldn't be resolved; the view's detach is best effort (the device never reads the view's copies).
    func release(_ instance: DeviceInstance, entry: FirmwareCatalog.Entry, host: DeviceSessionHost, commit: Bool?) async throws {
        try? await endBrowsing(instance.id)
        guard let commit, hasOpenEdit(instance), let executable = FirmwareJobs.preparer, let intent = pending(instance) else { return }
        activity[instance.id] = commit ? "Saving the file system…" : "Discarding changes…"
        defer { activity[instance.id] = nil }
        _ = try await FirmwareTool.run(["edit", "--device", instance.paths.directory.path, "--record-policy", "managed",
                                        "--action", commit ? "commit" : "discard", "--session", intent.id.uuidString], executable: executable)
        host.library.reload()
    }

    /// Detaches a device's read-only view (one left by an earlier run included).
    func endBrowsing(_ id: UUID, executable: URL? = nil) async throws {
        let out = browseDirectory(id)
        guard let executable = executable ?? FirmwareJobs.preparer, FileManager.default.fileExists(atPath: out.path) else { return }
        _ = try await FirmwareTool.run(["unmount", "--out", out.path], executable: executable)
    }

    /// At quit: every read-only view detached before the app goes.
    func endAllBrowsing() {
        guard let executable = FirmwareJobs.preparer else { return }
        let temporary = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [] where name.hasPrefix("LightTouch-files-") {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["unmount", "--out", temporary.appendingPathComponent(name).path]
            try? process.run()
            process.waitUntilExit()
        }
    }
}
