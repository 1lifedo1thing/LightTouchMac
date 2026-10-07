// Created by Sam on 2026-08-05.
//
// Hosts the device screen in the window's main column. The DisplayView is the
// main content; it centres its content and becomes first responder so
// keyboard passthrough works whenever the device area has focus.

import Cocoa

final class DeviceViewController: NSViewController {
    
    let emulator: EmulatorController
    private let displayView: DisplayView
    private let panelStatus = CaptureStatusView()
    
    init(emulator: EmulatorController) {
        self.emulator = emulator
        self.displayView = DisplayView(frame: NSRect(origin: .zero, size: emulator.profile.screenPixels), profile: emulator.profile)
        super.init(nibName: nil, bundle: nil)
        displayView.emulator = emulator
        let profile = emulator.profile
        displayView.configureFreeForm(scan: DeviceProfile.panelScan(emulator.instance.panel), key: emulator.instance.id)
        displayView.onPanelChange = { [weak emulator] upright, restart in
            emulator?.setPanel(upright.map(profile.panelOption(upright:)), restart: restart) ?? false
        }
        // The free-form resize's status is a notice like the others: same stack, same glass, never under one.
        panelStatus.isHidden = true
        displayView.onPanelStatus = { [weak self] text in
            guard let self else { return }
            if let text { panelStatus.update(title: text, busy: text.hasSuffix("…")) } else { panelStatus.isHidden = true }
            updateStatusVisibility()
        }
        displayView.onDropIPA = { [weak self] url in self?.installDropped(url) }
        displayView.onDropIPSW = { FirmwareJobs.shared.importIPSW($0, for: nil) }   // matched by its SHA1
        // Media the firmware can't take is refused on its row, with why (MediaSupport), before anything runs.
        displayView.onDropMedia = { [weak self] url in
            guard let self, self.emulator.canQueueInstall else { return }
            AppInstaller.startMedia(url, with: self.emulator, presenting: self.view.window)
        }
        displayView.onDropCatalogApp = { [weak self] app in
            guard let self, self.emulator.canQueueInstall else { return }
            AppInstaller.startCatalog(app, with: self.emulator, presenting: self.view.window)
        }
    }
    
    required init?(coder: NSCoder) { fatalError("not used") }
    
    override func loadView() {
        let content = DeviceContentView(screen: displayView)
        view = content
        content.addStatus(panelStatus)
    }

    func addStatus(_ status: NSView) { (view as? DeviceContentView)?.addStatus(status) }
    func updateStatusVisibility() { (view as? DeviceContentView)?.updateStatusVisibility() }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(displayView)
    }

    var screen: DisplayView { displayView }
    
    func setZoom(_ zoom: ZoomMode) { displayView.zoom = zoom }
    
    /// The same preconditions the menu and toolbar enforce for Install App…
    /// A drop used to bypass all of them, so an .ipa dropped during the ~40s
    /// boot (or with app sync off) was accepted, put a spinner in a sidebar
    /// that wasn't even polling, and failed a moment later with a modal —
    /// while the button for the identical operation sat greyed out.
    func installDropped(_ url: URL) {
        // Deliberately NOT gated on isInstalling: AppInstaller queues each job
        // when their bytes are ready, so dropping another IPA is supported.
        // Refusing it was a regression — dropping three at once is the whole
        // point of accepting multiple files.
        guard emulator.canQueueInstall else {
            let alert = NSAlert()
            alert.messageText = "The \(emulator.profile.shortName) isn’t ready yet"
            alert.informativeText = "Try again when it has finished starting up."
            if let window = view.window { alert.beginSheetModal(for: window) { _ in } }
            else { alert.runModal() }
            return
        }
        AppInstaller.start(url, with: emulator, presenting: view.window)
    }
}
