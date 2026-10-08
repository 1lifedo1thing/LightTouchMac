import Cocoa
import FirmwareSchema
import HostRuntime
import HostServiceWire
import LightTouchCore
import SwiftUI
import UniformTypeIdentifiers

extension MainWindowController {
    /// Runtime conditions on top of what the row allows.
    func canPerform(_ action: DeviceAction, for entry: FirmwareCatalog.Entry) -> Bool {
        guard host.row(for: entry).allows(action, canDownload: FirmwareJobs.shared.canDownload) else { return false }
        let emulator = host.session(for: entry)?.emulator
        if let instance = host.instance(for: entry) {
            switch action {
            case .start:
                if DeviceFilesystemEdits.shared.blocksStart(instance) { return false }
            case .erase, .delete:
                if DeviceFilesystemEdits.shared.blocked(instance) { return false }
            case .openFilesystem, .commitFilesystem, .discardFilesystem, .recoverFilesystem:
                return DeviceFilesystemEdits.shared.canPerform(action, instance: instance)
            default: break
            }
        }
        switch action {
        case .start: return emulator.map { $0.isDead || ($0.isPoweredOff && !$0.shuttingDown) } ?? true
        case .stop: return emulator?.canShutDown == true
        case .forceStop: return emulator?.canForceStop == true
        case .erase: return emulator?.isErasing != true && !hasFileTransfer && !recording.isActive
        default: return true
        }
    }

    func perform(_ action: DeviceAction, for entry: FirmwareCatalog.Entry) {
        guard canPerform(action, for: entry) else { return }
        switch action {
        case .openFilesystem, .commitFilesystem, .discardFilesystem, .recoverFilesystem:
            DeviceFilesystemEdits.shared.perform(action, entry: entry, host: host)
        case .start: start(entry)
        // The same questions as Device ▸ Shut Down… and Force Stop…, from the sidebar and File menu too.
        case .stop: if let emulator = host.session(for: entry)?.emulator { confirmShutDown(emulator) }
        case .forceStop: if let emulator = host.session(for: entry)?.emulator { confirmForceStop(emulator) }
        case .downloadAndPrepare: FirmwareJobs.shared.downloadAndPrepare(entry)
        case .importIPSW: chooseIPSW(for: entry)
        case .cancel: FirmwareJobs.shared.cancel(entry)
        case .erase: erase(entry)
        case .showInFinder:
            // Every device has its Devices/<uuid> (an adopted one keeps its record, work and IPAs there).
            if let instance = host.instance(for: entry) {
                NSWorkspace.shared.activateFileViewerSelecting([instance.paths.directory])
            }
        case .delete: confirmDelete(entry)
        case .prepareAgain: confirmDelete(entry, thenPrepare: true)
        }
    }

    func name(_ entry: FirmwareCatalog.Entry) -> String { library.displayName(for: entry) }

    /// Start: the file system view let go first (an edit open in Finder is saved or discarded, after asking).
    func start(_ entry: FirmwareCatalog.Entry) {
        library.select(entry)
        guard let instance = host.instance(for: entry) else { return launch(entry) }
        let edits = DeviceFilesystemEdits.shared
        func release(commit: Bool?) {
            Task {
                do { try await edits.release(instance, entry: entry, host: host, commit: commit) } catch {
                    if let window { await NSAlert(error: error).beginSheetModal(for: window) }
                    return
                }
                if canPerform(.start, for: entry) { launch(entry) }
            }
        }
        guard edits.hasOpenEdit(instance), let window else { return release(commit: nil) }
        let alert = NSAlert()
        let shortName = entry.profile?.shortName ?? "device"
        alert.messageText = "\(name(entry))’s file system is open in Finder"
        alert.informativeText =
            edits.isEditMounted(instance)
            ? "Starting the \(shortName) unmounts its file system so the \(shortName) can use it. Copies in progress finish first, then your changes are saved."
            : "Starting the \(shortName) saves your changes first."
        alert.addButton(withTitle: "Save and Start")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: release(commit: true)
            case .alertThirdButtonReturn: release(commit: false)
            default: break
            }
        }
    }

    /// Show File System on a 1.x device stopped without shutting down (its FTL is mid-write): start it, shut it down
    /// from iOS, then open it, after asking.
    func offerShutDownFirst(_ entry: FirmwareCatalog.Entry) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "\(name(entry)) wasn’t shut down"
        alert.informativeText =
            "Its file system can be shown once it has been shut down. Light Touch can start it, shut it down, and then show it."
        alert.addButton(withTitle: "Shut Down First")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            start(entry)
            Task { [weak self] in
                // Up to the boot's own budget for iOS to come up, then Shut Down, then the file system.
                let deadline = Date().addingTimeInterval(entry.profile?.bootBudget ?? 240)
                while Date() < deadline {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, let emulator = self.host.session(for: entry)?.emulator else { continue }
                    if emulator.isDead || emulator.isPoweredOff { return }
                    guard emulator.isRunning, emulator.canShutDown else { continue }
                    self.shutDown(emulator) { [weak self] in self?.perform(.openFilesystem, for: entry) }
                    return
                }
            }
        }
    }

    private func launch(_ entry: FirmwareCatalog.Entry) {
        if let session = host.session(for: entry) {
            if session.emulator.isDead { host.restart(session) } else { session.emulator.powerOn() }
            return
        }
        host.start(entry)
    }

    @objc func toggleDeviceRunning(_ sender: Any?) {
        guard let entry = selectedEntry else { return }
        perform([.running, .stopping].contains(host.row(for: entry).state) ? .stop : .start, for: entry)
    }
    @objc func downloadAndPrepare(_ sender: Any?) { selectedEntry.map { perform(.downloadAndPrepare, for: $0) } }
    @objc func importIPSW(_ sender: Any?) { selectedEntry.map { perform(.importIPSW, for: $0) } }
    @objc func cancelFirmwareJob(_ sender: Any?) { selectedEntry.map { perform(.cancel, for: $0) } }
    @objc func showDeviceInFinder(_ sender: Any?) { selectedEntry.map { perform(.showInFinder, for: $0) } }
    /// Delete Device… for a prepared device (asks, then leaves the sidebar), Remove Device for the rest; with several
    /// rows selected, one question for the lot (DeviceLibraryViewController.removeTargets).
    @objc func deleteDevice(_ sender: Any?) { library.removeTargets() }

    /// The toolbar's +, the Device menu and the empty sidebar: the catalog in a sheet.
    @objc func addDevice(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let split = contentSplitViewController else { return }
        let catalog = host.catalog
        let downloaded = Set(
            catalog.entries.filter { $0.source.sha1.map { IPSWStore.shared.existing($0) != nil } ?? false }.map(\.id)
        )
        var sheet: NSViewController?
        let view = AddDeviceView(
            catalog: catalog,
            added: Set(library.entries.map(\.id)),
            downloaded: downloaded,
            onAdd: { [weak self] ids in
                sheet.map { split.dismiss($0) }
                self?.library.add(ids)
            },
            onCancel: { sheet.map { split.dismiss($0) } }
        )
        let hosting = NSHostingController(rootView: view)
        sheet = hosting
        split.presentAsSheet(hosting)
    }

    private func chooseIPSW(for entry: FirmwareCatalog.Entry) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw")].compactMap { $0 }
        panel.message = "Choose the IPSW for \(name(entry))."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.handOffIPSW(url, for: entry)
        }
    }

    /// Files opened from Finder, the Dock or `open` (AppDelegate.application(_:open:)), sorted as a drop is:
    /// an IPSW to the library (the catalog names its entry), an .ipa to the device on screen.
    func open(_ urls: [URL]) {
        showWindow(nil)
        DroppedFiles.files(urls, .ipsw).forEach { handOffIPSW($0, for: nil) }
        let ipas = DroppedFiles.files(urls, .ipa)
        guard !ipas.isEmpty else { return }
        guard let deviceVC else {
            let alert = NSAlert()
            alert.messageText = "No device is running"
            alert.informativeText = "Start a device, then open the app again."
            if let window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
            return
        }
        ipas.forEach(deviceVC.installDropped)
    }

    func handOffIPSW(_ url: URL, for entry: FirmwareCatalog.Entry?) {
        FirmwareJobs.shared.importIPSW(url, for: entry)
    }

    /// Delete, or with `thenPrepare` delete and prepare the entry again (a base from an older recipe): the same question.
    private func confirmDelete(_ entry: FirmwareCatalog.Entry, thenPrepare: Bool = false) {
        guard host.instance(for: entry) != nil else { return }
        askToDelete(name(entry), thenPrepare: thenPrepare) { [weak self] in
            // Asked again on the answer: the device may have started (from the menu bar) while the question was up.
            guard let self, canPerform(thenPrepare ? .prepareAgain : .delete, for: entry) else { return nil }
            return host.instance(for: entry)
        } deleted: { [weak self] in
            if thenPrepare {
                FirmwareJobs.shared.downloadAndPrepare(entry)
            } else {
                self?.library.removeFromList(entry)
            }
        }
    }

    /// Settings ▸ Storage lists every record, also one no row shows: its entry left the catalog, or a newer record
    /// for the same entry is the row's (host.instance(for:)). The row's own device goes the row's way; such a record
    /// has no session, so it goes whenever nothing else works on its storage.
    func canDeleteFromStorage(_ instance: DeviceInstance) -> Bool {
        if let entry = host.catalog.entry(id: instance.firmware), host.instance(for: entry)?.id == instance.id {
            return canPerform(.delete, for: entry)
        }
        return !host.storageWork.contains(instance.firmware) && !DeviceFilesystemEdits.shared.blocked(instance)
    }

    func deleteFromStorage(_ instance: DeviceInstance) {
        if let entry = host.catalog.entry(id: instance.firmware), host.instance(for: entry)?.id == instance.id {
            return perform(.delete, for: entry)
        }
        guard canDeleteFromStorage(instance) else { return }
        askToDelete("“\(instance.name)”") { [weak self] in
            self?.canDeleteFromStorage(instance) == true ? instance : nil
        } deleted: {
        }
    }

    /// The delete question; on Delete, `target` says what to delete now (nil: nothing, it changed meanwhile), which
    /// the host removes off the main actor while the row says Deleting.
    private func askToDelete(
        _ name: String,
        thenPrepare: Bool = false,
        target: @escaping () -> DeviceInstance?,
        deleted: @escaping () -> Void
    ) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = thenPrepare ? "Prepare \(name) again?" : "Delete \(name)?"
        alert.informativeText = "This permanently removes its apps, settings, and saved state."
        alert.addButton(withTitle: thenPrepare ? "Prepare Again" : "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let instance = target() else { return }
            let deletion = host.delete(instance)
            Task {
                do {
                    try await deletion.value
                    deleted()
                } catch { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
            }
        }
    }
}
