// Created by Sam on 2026-08-05.

import LightTouchCore
import Cocoa
import DeviceRuntime
import HostRuntime
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    
    private var windowController: MainWindowController?
    private let dockProgress = DockProgress()
    private var host: DeviceSessionHost?
    /// Every device this launch started; quitting shuts each one down.
    private var emulators: [EmulatorController] { host?.sessions.map(\.emulator) ?? [] }
    /// The running device, for settings that apply to it on its next boot.
    private var emulator: EmulatorController? { windowController?.session?.emulator ?? emulators.first }
    private var helpController: HelpWindowController?
    private var awaitingTermination = false
    private var terminationBackstop: Task<Void, Never>?

    /// NSApplication's deferred quit runs a nested modal loop. Invoking it
    /// inside a main-queue callback occupies that serial queue until quit
    /// finishes, starving the Swift main-actor tasks needed to finish it.
    /// A run-loop timer invokes AppKit without holding the dispatch queue.
    /// System logout still uses applicationShouldTerminate's native reply.
    static func requestTermination() {
        guard (NSApp.delegate as? AppDelegate)?.awaitingTermination != true else { return }
        let timer = Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard (NSApp.delegate as? AppDelegate)?.awaitingTermination != true else { return }
                NSApp.terminate(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func quit(_ sender: Any?) { Self.requestTermination() }


    @objc func showDeviceWindow(_ sender: Any?) { windowController?.focusDeviceScreen(sender) }
    @objc func showFilesWindow(_ sender: Any?) { windowController?.toggleFiles(sender) }

    @objc func toggleAutomaticRotation(_ sender: Any?) { emulator?.toggleAutoRotate() }
    /// Device ▸ Debugging ▸ Debug Port…: a sheet with its switch, where it is, what it is, and how to attach (DebugPortView).
    @objc func showDebugPort(_ sender: Any?) {
        guard let emulator, let window = NSApp.mainWindow, window.attachedSheet == nil else { return }
        var sheet: NSWindow?
        let view = DebugPortView(shortName: emulator.profile.shortName, port: emulator.debugPort,
                                 lldbWithSymbols: emulator.lldbAttachCommand, enabled: emulator.debugPortEnabled,
                                 onToggle: { [weak emulator] in emulator?.toggleDebugPort() },
                                 onDone: { sheet.map { window.endSheet($0) } })
        let panel = NSWindow(contentViewController: NSHostingController(rootView: view))
        sheet = panel
        window.beginSheet(panel)
    }
    @objc func copyLLDBCommand(_ sender: Any?) {
        guard let command = emulator?.lldbAttachCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
    @objc func toggleInternetAccess(_ sender: Any?) { NetworkAccessPreference.toggle(running: emulator?.network) }
    @objc func toggleLocalNetwork(_ sender: Any?) { emulator?.toggleLocalNetwork() }

    /// The settings items for the running device (DeviceSettingsMenu).
    private var settingsMenu: DeviceSettingsMenu {
        DeviceSettingsMenu(device: emulator.map {
            var device = DeviceSettingsMenu.Device(marketingName: $0.profile.marketingName, shortName: $0.profile.shortName)
            device.localNetworkEnabled = $0.localNetworkEnabled
            device.autoRotateEnabled = $0.autoRotateEnabled
            device.debugPortEnabled = $0.debugPortEnabled
            device.debugPort = $0.debugPort
            device.lldbAttachCommand = $0.lldbAttachCommand
            device.network = $0.network
            return device
        }, desiredNetwork: NetworkAccessPreference.desired(running: emulator?.network))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let menuItem: DeviceSettingsMenu.Item
        switch item.action {
        case #selector(toggleLocalNetwork(_:)): menuItem = .localNetwork
        case #selector(toggleAutomaticRotation(_:)): menuItem = .autoRotate
        case #selector(showDebugPort(_:)): menuItem = .debugPort
        case #selector(copyLLDBCommand(_:)): menuItem = .copyLLDBCommand
        case #selector(toggleInternetAccess(_:)): menuItem = .internet
        default: return true
        }
        let validation = settingsMenu.validate(menuItem)
        if let title = validation.title { item.title = title }
        if let on = validation.isOn { item.state = on ? .on : .off }
        item.toolTip = validation.toolTip
        return validation.isEnabled
    }

    @objc func showHelp(_ sender: Any?) {
        if helpController == nil {
            helpController = HelpWindowController(text: Bundle.main.url(forResource: "Help", withExtension: "txt")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "# Help\nHelp is missing from this copy of Light Touch.")
        }
        helpController?.show(deviceName: emulator?.profile.shortName ?? "iPod")
        helpController?.showWindow(sender)
        helpController?.window?.makeKeyAndOrderFront(sender)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let windowController else { return nil }
        let menu = NSMenu()
        for (title, action) in [("Home Screen", #selector(MainWindowController.deviceHome(_:))),
                                ("Lock", #selector(MainWindowController.deviceLock(_:))),
                                ("Restart…", #selector(MainWindowController.deviceReset(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = windowController
            menu.addItem(item)
        }
        return menu
    }

    @objc func showAbout(_ sender: Any?) { AboutCredits.show() }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The boards' hardware facts are the emulator's: the bundled helper lists them once, here off the main thread.
        Machines.helper = DeviceLink.Configuration.bundledHelper
        Task.detached { _ = Board.n72.hardware }
        // Keep AppKit's native editing utilities for search fields and panels.
        // Device, Files, Help, and log windows have distinct jobs, not tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.disableRelaunchOnLogin()

        MainMenuBuilder.install(profile: .n72)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try Bundled.requireStorage() }
        catch {
            let alert = NSAlert()
            if (error as? CocoaError)?.code == .fileLocking {
                alert.messageText = Bundled.appLockMessage
                alert.informativeText = "Quit the other copy first."
            } else {
                alert.alertStyle = .critical
                alert.messageText = "Couldn’t open device storage"
                alert.informativeText = error.localizedDescription
            }
            // Either way this copy can't go on.
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            Self.requestTermination()
            return
        }
        do { try NativeLogging.start() }
        catch { logEvent("logging: native output capture unavailable: \(error.localizedDescription)") }
        // State from before devices were prepared from IPSWs: erased once, or the app quits. The erase
        // runs off the main actor behind a progress window; a launch after a quit midway resumes without asking.
        if let legacy = LegacyState.find(state: Bundled.stateDirectory, applicationSupport: ProcessInfo.processInfo.environment["LTM_STATE_DIR"] == nil
                                            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] : nil) {
            if !legacy.resuming {
                let alert = NSAlert()
                alert.messageText = LegacyState.message
                alert.informativeText = LegacyState.detail
                alert.addButton(withTitle: "Erase and Continue")
                alert.addButton(withTitle: "Quit")
                alert.buttons.first?.hasDestructiveAction = true
                guard alert.runModal() == .alertFirstButtonReturn else { Self.requestTermination(); return }
            }
            let progress = MigrationProgress()
            progress.window.makeKeyAndOrderFront(nil)
            Task {
                do { try await legacy.erase() } catch {
                    progress.window.orderOut(nil)
                    NSAlert(error: error).runModal()
                    Self.requestTermination()
                    return
                }
                progress.window.orderOut(nil)
                finishLaunching()
            }
            return
        }
        finishLaunching()
    }

    /// The rest of the launch, once no legacy state is left.
    private func finishLaunching() {
        // The network question belongs to the device being started (DeviceSessionHost.start), not to the app.
        let host = DeviceSessionHost()
        Self.sweepStorage()
        Self.adoptDevelopmentBase(catalog: host.catalog)
        // A fresh install starts unpacking the built-in iPod and selects it (it starts once published).
        if let bundled = FirmwareJobs.shared.prepareBundledIfFresh(sidebarSaved: UserDefaults.standard.object(forKey: SidebarList.entriesKey) != nil) {
            host.lastSelection = bundled
        }
        let profile = host.launchSelection?.profile ?? .n72
        MainMenuBuilder.install(profile: profile)
        let controller = MainWindowController(host: host, profile: profile)
        controller.showWindow(nil)
        self.host = host
        self.windowController = controller
        controller.selectLaunchDevice()
        dockProgress.start()
        if !pendingOpen.isEmpty { controller.open(pendingOpen); pendingOpen = [] }
    }

    /// Development runs: LTM_DEV_BASE names a `firmwarekit create` output directory to run as a
    /// device; a record naming it (kept in place, never locked) is written once, for the entry its
    /// lock names. The app has no other way to boot anything but a prepared base.
    private static func adoptDevelopmentBase(catalog: FirmwareCatalog) {
        guard let path = ProcessInfo.processInfo.environment["LTM_DEV_BASE"] else { return }
        let base = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let state = Bundled.stateDirectory
        guard !DeviceInstance.all(state: state).contains(where: { DeviceInstance.url($0.base.path, state: state).standardizedFileURL == base }) else { return }
        guard let id = (try? DeviceLock.read(base: base))??.entryID, let entry = catalog.entry(id: id) else {
            return logEvent("LTM_DEV_BASE: \(path) has no device.lock.json naming a catalog entry")
        }
        do {
            let instance = try PreparationJob.publish(staging: base, entry: entry, id: UUID(), state: state, keep: true)
            DeviceLibrary.shared.reload()
            logEvent("LTM_DEV_BASE: \(path) is device \(instance.id.uuidString) (\(entry.id))")
        } catch { logEvent("LTM_DEV_BASE: \(error.localizedDescription)") }
    }

    /// Launch, with the library's lock held: finish what a crash or an older
    /// build left. FirmwareJobs' own init sweeps Preparing/ and the IPSW stores.
    private static func sweepStorage() {
        let state = Bundled.stateDirectory, logs = Bundled.logsDirectory
        let records = DeviceInstance.all(state: state)
        _ = FirmwareJobs.shared
        DeviceStateStorage.sweepDeleting(state: state)
        DeviceSettings.migrateDefaults(.standard, state: state, devices: records.map(\.id))
        IPALibrary.sweep(devices: records)
        for record in records { USBMux.secure(DeviceInstance.url(record.storage.usbmuxConf, state: state)) }
        // Bases published by earlier builds become immutable too (a development base, outside State, is left alone).
        for record in records where !record.base.path.hasPrefix("/") {
            DeviceStateStorage.lockBase(DeviceInstance.url(record.base.path, state: state))
        }
        // Logs of devices that no longer exist, and the single-device logs
        // from before per-device ones (Logs/serial.log*, usbmuxd.log*).
        let fm = FileManager.default
        let deviceLogs = logs.appendingPathComponent("Devices", isDirectory: true)
        let ids = Set(records.map(\.id.uuidString))
        for name in (try? fm.contentsOfDirectory(atPath: deviceLogs.path)) ?? [] where UUID(uuidString: name) != nil && !ids.contains(name) {
            try? DeviceStateStorage.removeTree(deviceLogs.appendingPathComponent(name))
        }
        for name in (try? fm.contentsOfDirectory(atPath: logs.path)) ?? []
        where ["serial.log", "serial.log.1", "usbmuxd.log", "usbmuxd.log.1"].contains(name) {
            try? fm.removeItem(at: logs.appendingPathComponent(name))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationBackstop?.cancel()
        // A quit (or a crash, through firmwarekit's parent watch) cancels
        // every preparation; the next launch's sweep removes its staging.
        if host != nil { FirmwareJobs.shared.cancelAll() }
        emulators.forEach { $0.stop() }
        DeviceFilesystemEdits.shared.endAllBrowsing()
    }

    /// On quit: guard an in-flight install, then halt each device
    /// (EmulatorController.halt: storage flushed, no guest shutdown).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if emulators.contains(where: \.isErasing) { return .terminateCancel }
        if awaitingTermination { return .terminateLater }
        if windowController?.finishRecordingBeforeQuit() == true { return .terminateCancel }
        // A preparation doesn't survive a quit (a download does: it resumes).
        let preparing = FirmwareJobs.shared.jobs.values.filter { if case .preparing = $0 { true } else { false } }.count
        if preparing > 0 {
            let alert = NSAlert()
            alert.messageText = preparing == 1 ? "A device is being prepared" : "Devices are being prepared"
            alert.informativeText = "Quitting stops the preparation. It starts over the next time you prepare the device."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        guard !emulators.isEmpty else { return .terminateNow }

        // Queued installs count too. isInstalling is set only around the install
        // that is executing; jobs waiting their turn are parked on the previous
        // job's task, so quitting with three .ipas queued used to take no notice
        // and drop them without a word.
        if emulators.contains(where: \.isInstalling) || AppInstaller.hasPendingWork || windowController?.hasFileTransfer == true {
            let alert = NSAlert()
            alert.messageText = "Device changes are in progress"
            alert.informativeText = "Quitting cancels changes that haven’t finished."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            AppInstaller.cancelPendingWork()
            windowController?.cancelFileTransfer()
            // Falls through to the SAME shutdown as any other quit. It used to
            // return .terminateNow, on the reasoning that a half-finished
            // install is not a clean state to snapshot — true, and irrelevant
            // to the flush. Skipping the flush threw away every app installed
            // earlier in the session as well as the one in flight.
        }

        let running = emulators.filter { !$0.isDead && !$0.isPoweredOff }
        guard !running.isEmpty else { return .terminateNow }

        awaitingTermination = true
        let reply = { [weak self] in
            // A guard can complete synchronously. Reply only after this
            // delegate invocation has returned terminateLater to AppKit.
            DispatchQueue.main.async {
                guard let self, self.awaitingTermination else { return }
                self.awaitingTermination = false
                self.terminationBackstop?.cancel()
                self.terminationBackstop = nil
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        let backstop = EmulatorController.stopBudget
        terminationBackstop = Task {
            do { try await Task.sleep(for: .seconds(backstop)) } catch { return }
            logEvent("quit: shutdown did not finish in time — quitting anyway")
            reply()
        }

        // Every device shuts down at once; quit waits for the last of them.
        var remaining = running.count
        let finished = {
            remaining -= 1
            if remaining == 0 { reply() }
        }
        for emulator in running { emulator.halt { _ in finished() } }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Finder, the Dock and `open` hand over IPSWs and .ipa files here (Configuration/LightTouchMac-Info.plist).
    /// A launch by opening one arrives before the window exists: held until finishLaunching.
    private var pendingOpen: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        if let windowController { windowController.open(urls) } else { pendingOpen += urls }
    }

    /// Reopen the retained device window even when Files or Help is still visible.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if windowController?.window?.isVisible != true { windowController?.showWindow(nil) }
        return true
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        // This selects secure coding if AppKit consults the delegate; returning
        // false would select legacy coding, not disable window restoration.
        // LightTouchApplication and each window independently opt out.
        true
    }
}

/// A small window while the legacy erase runs off the main actor.
private final class MigrationProgress {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
    private let bar = NSProgressIndicator()

    init() {
        window.title = "Light Touch"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let label = NSTextField(labelWithString: LegacyState.progressMessage)
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            bar.widthAnchor.constraint(equalToConstant: 320),
        ])
        window.contentView = content
        window.center()
    }
}
