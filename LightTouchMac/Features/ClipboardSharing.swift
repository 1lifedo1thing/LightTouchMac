import Cocoa
import LightTouchCore

/// Settings ▸ General ▸ Share clipboard with devices (on unless turned off): ClipboardSync between the Mac's
/// pasteboard and every running device with one (iOS 3.0 and later). The Mac posts no change notification, so its
/// pasteboard is polled twice a second while Light Touch is active, and at once when it becomes active: a copy in
/// another app can only be pasted on a device after coming here. A device starting gets the Mac's text once it takes
/// input; its copies arrive as the helper reports them (LinkEvent.guestPasteboard).
@MainActor final class ClipboardSharing {
    static let shared = ClipboardSharing()
    /// The running devices (AppDelegate's sessions).
    var emulators: () -> [EmulatorController] = { [] }
    private var sync = ClipboardSync()
    /// What each boot (its DeviceProcess) was last handed or reported.
    private var delivered: [ObjectIdentifier: String] = [:]
    private var timer: Timer?

    static var enabled: Bool { UserDefaults.standard.object(forKey: ClipboardSync.key) as? Bool ?? true }

    func start() {
        guard timer == nil else { return }
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in MainActor.assumeIsolated { ClipboardSharing.shared.tick() } }
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardSharing.shared.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard Self.enabled else { return }
        let boots = emulators().compactMap { emulator in
            emulator.sharesClipboard ? emulator.process.map { (emulator, ObjectIdentifier($0)) } : nil
        }
        delivered = delivered.filter { entry in boots.contains { $0.1 == entry.key } }
        guard !boots.isEmpty else { return }
        if NSApp.isActive {
            let board = NSPasteboard.general
            _ = sync.macChanged(changeCount: board.changeCount) { board.string(forType: .string) }
        }
        for (emulator, boot) in boots where emulator.acceptsInput {
            guard let text = sync.pending(delivered: delivered[boot]) else { continue }
            emulator.pasteToGuest(text)
            delivered[boot] = text
        }
    }

    /// A copy on `emulator`'s device: onto the Mac's pasteboard, and the other devices' on the next tick.
    func guestCopied(_ text: String, on emulator: EmulatorController) {
        guard Self.enabled, emulator.sharesClipboard, let process = emulator.process else { return }
        delivered[ObjectIdentifier(process)] = text
        guard let text = sync.guestCopied(text) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        sync.wroteMac(changeCount: board.changeCount)
    }
}

extension EmulatorController {
    /// The device's iOS has a pasteboard to share (3.0 and later).
    var sharesClipboard: Bool { ClipboardSync.supported(iosVersion: iosVersion) }
}
