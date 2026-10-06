import Cocoa

/// A stopped generation is mounted by FirmwareKit; a durable intent keeps the
/// helper out even if this GUI quits. No filesystem writer lives in the GUI.
/// Boards without a stopped edit get a read-only view instead: `firmwarekit mount`,
/// the volumes rebuilt into images and attached read-only, detached at Start or quit.
@MainActor
final class DeviceFilesystemEdits {
    static let shared = DeviceFilesystemEdits()
    private var busy: Set<UUID> = []
    struct Intent: Decodable { let id: UUID; let phase: String }
    struct Mounted: Decodable { let id: UUID; let mountPoint: String? }
    func pending(_ instance: DeviceInstance) -> Intent? {
        try? JSONDecoder().decode(Intent.self, from: Data(contentsOf: instance.paths.work.appendingPathComponent("edit.json")))
    }
    func blocked(_ instance: DeviceInstance) -> Bool {
        busy.contains(instance.id) || FileManager.default.fileExists(atPath: instance.paths.work.appendingPathComponent("edit.json").path)
    }
    /// Boards whose stored volume FirmwareKit can edit while stopped: the N72's generated store, and 1.x devices
    /// through their legacy FTL (StoppedVolumeEdit edits those in place).
    static let editableBoards: Set<String> = ["n72ap", "n45ap", "m68ap"]
    /// The S5L8920 boards' stores aren't rebuilt into volumes (VolumeRebuild): no view at all.
    static let unbrowsableBoards: Set<String> = ["n18ap", "n88ap"]
    func canPerform(_ action: DeviceAction, instance: DeviceInstance) -> Bool {
        guard FirmwareJobs.preparer != nil, !busy.contains(instance.id) else { return false }
        guard Self.editableBoards.contains(instance.board) else {
            return action == .openFilesystem && !Self.unbrowsableBoards.contains(instance.board)
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
        busy.insert(instance.id)
        Task {
            defer {
                busy.remove(instance.id)
                host.library.reload()
                NotificationCenter.default.post(name: DeviceLibrary.didChangeNotification, object: host.library)
            }
            do {
                guard await host.releaseStopped(for: entry) else {
                    throw DeviceToolsError.failed("Stop the device before opening its filesystem.")
                }
                guard Self.editableBoards.contains(instance.board) else { return try await browse(instance, executable: executable) }
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
                let result = try await FirmwareTool.run(prefix + ["--action", operation, "--session", intent.id.uuidString], executable: executable)
                if action == .openFilesystem, let path = try JSONDecoder().decode(Mounted.self, from: result).mountPoint {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            } catch { NSApp.presentError(error) }
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
