import Cocoa
import FirmwareSchema
import HostRuntime
import HostServiceWire
import LightTouchCore
import SwiftUI
import UniformTypeIdentifiers

extension MainWindowController {
    /// The Files window follows the selected device; its title says which.
    func titleFilesWindow() {
        guard let window = filesWindow?.window else { return }
        let label = selectedEntry.map { library.label(for: $0) }
        window.title = "\(label?.title ?? currentProfile.shortName) Files"
        window.subtitle = label?.subtitle ?? ""
    }

    func refreshForState() {
        proxySettingsEditor?.updateStatus(emulator?.webProxyStatus ?? .waiting)
        titleFilesWindow()
        if let filesVC {
            let socket = emulator.flatMap { $0.canReachDevice ? $0.usbmuxSession : nil }
            if filesVC.services?.clientSocket != socket {
                filesVC.services = socket.map { DeviceServices(clientSocket: $0) }
                filesVC.reload()
            }
        }
        updateDeviceNotice()
        updateStartupStatus()
        validateCaptureToolbar()  // validates the toolbar once, the lock item included
        updateDeadOverlay()
        guard let emulator, let deviceVC else {
            window?.subtitle = selectedEntry.map { library.label(for: $0).subtitle } ?? ""
            return
        }
        // The window subtitle is where AppKit puts secondary window state, and
        // it styles and truncates itself to match the title. A custom titlebar
        // accessory was carrying this before — more code, its own constraints,
        // and it competed with the toolbar for space.
        window?.subtitle =
            emulator.isRunning && !emulator.shuttingDown && !emulator.isSleeping
            ? (emulator.foregroundAppName ?? emulator.statusLine) : emulator.statusLine
        if emulator.isPoweredOff || emulator.isDead { deviceVC.screen.endLiveText() }
        deviceVC.screen.updatePowerPresentation()
        if emulator.isDead || emulator.isPoweredOff { recording.stop() }
    }

    private func updateStartupStatus() {
        defer { deviceVC?.updateStatusVisibility() }
        guard let emulator, emulator.isStartingUp else {
            startupTask?.cancel()
            startupTask = nil
            startupStatus.isHidden = true
            return
        }
        let elapsed = Int(Date().timeIntervalSince(emulator.startupBegan))
        // The subtitle is the boot's real stage (BootStage, from the device's own signals) and the session's counter.
        startupStatus.update(
            title: emulator.isErasing
                ? "Erasing \(emulator.profile.shortName)…"
                : deviceVC?.screen.restartTitle ?? "Starting iOS…",
            detail: (emulator.isErasing ? "" : emulator.bootStageText + " · ") + "\(elapsed) s",
            busy: true,
            primary: elapsed >= Int(emulator.profile.bootBudget) ? "Show Logs" : nil
        )
        if startupTask == nil {
            startupTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    updateStartupStatus()
                }
            }
        }
    }

    private func updateDeviceNotice() {
        guard let window else { return }
        guard let emulator, let message = emulator.deviceNotice else {
            if let accessory = noticeAccessory,
                let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory)
            {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            noticeAccessory = nil
            return
        }
        if noticeAccessory == nil {
            let accessory = DeviceNoticeViewController()
            accessory.onShowLogs = { [weak self] in self?.showDeviceLogs(nil) }
            accessory.onDismiss = { [weak self] in self?.emulator?.dismissDeviceNotice() }
            accessory.onAction = { [weak self] in self?.eraseDevice(nil) }
            window.addTitlebarAccessoryViewController(accessory)
            noticeAccessory = accessory
        }
        noticeAccessory?.update(
            message,
            canDismiss: !emulator.storageFailed,
            action: emulator.deviceNoticeOffersErase ? "Erase…" : nil
        )
    }

    /// When the emulator dies (QEMU can't re-init), cover the device with an
    /// unmistakable overlay — the frozen last frame otherwise looks live.
    private func updateDeadOverlay() {
        guard let emulator, let deviceVC, emulator.isDead, !emulator.isErasing else {
            deadOverlay?.removeFromSuperview()
            deadOverlay = nil
            return
        }
        // Over the device pane only, centered where the device is laid out
        // (its safe area), not on the whole window with the inspector.
        guard deadOverlay == nil else { return }
        let content = deviceVC.view
        let overlay = NSView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        overlay.translatesAutoresizingMaskIntoConstraints = false

        // A refused boot says why and offers the remedy; anything else restarts
        // the device in a fresh helper (the app and other devices keep running).
        let refused = emulator.baseImageMismatch
        let label = NSTextField(
            wrappingLabelWithString: refused
                ? "This \(emulator.profile.shortName)’s data was made with an older system image. Erase it to start fresh."
                : emulator.deathReason ?? emulator.profile.stoppedReason
        )
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.preferredMaxLayoutWidth = 280
        let button =
            refused
            ? NSButton(title: "Erase…", target: self, action: #selector(eraseDevice(_:)))
            : NSButton(title: "Restart", target: self, action: #selector(restartDevice(_:)))
        button.bezelStyle = .rounded
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: content.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: content.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.safeAreaLayoutGuide.centerYAnchor),
        ])
        deadOverlay = overlay
    }

    /// A fresh helper for the dead device (DeviceSessionHost.restart).
    @objc private func restartDevice(_ sender: Any?) {
        if let session { host.restart(session) }
    }

    /// Search Apps focuses the inspector search field in either mode.
    @objc func findCatalog(_ sender: Any?) {
        if let toolbar = window?.toolbar {
            toolbar.isVisible = true
            if !toolbar.items.contains(where: { $0.itemIdentifier == .searchCatalog }) {
                let index =
                    toolbar.items.firstIndex { $0.itemIdentifier == .inspectorTrackingSeparator } ?? toolbar.items.count
                toolbar.insertItem(withItemIdentifier: .searchCatalog, at: min(index + 1, toolbar.items.count))
            }
        }
        inspectorVC?.focusSearch()
    }

    /// NSTextView handles Find first in Help and logs. In the device window,
    /// the searchable content is the app inspector.
    @objc func performFindPanelAction(_ sender: Any?) { findCatalog(sender) }
}
