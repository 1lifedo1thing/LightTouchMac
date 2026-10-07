// A device's settings file as the session holds it, and the notice the window shows for it (kept there, so a
// notice survives a relaunch until it is resolved or dismissed).

import Foundation
import HostRuntime
import DeviceRuntime

/// This device's settings.plist (DeviceSettings), read once and written on every change.
public final class DeviceSettingsFile {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public private(set) lazy var value = DeviceSettings.load(directory)

    public func change(_ change: (inout DeviceSettings) -> Void) {
        change(&value)
        do { try value.save(directory) } catch { logEvent("settings: could not save: \(error.localizedDescription)") }
    }
}

/// The device's one notice: what went wrong, and which operation's success resolves it.
public final class DeviceNotices {
    public enum Operation: String { case storage, preparation, erase, powerOff, lowSpace, activation, files }

    private let settings: DeviceSettingsFile
    private let shortName: String
    /// The helper reports its storage failing: every notice then says so, and none can be dismissed.
    private let storageFailed: () -> Bool
    public var onChange: (() -> Void)?

    public init(settings: DeviceSettingsFile, shortName: String, storageFailed: @escaping () -> Bool) {
        self.settings = settings
        self.shortName = shortName
        self.storageFailed = storageFailed
    }

    public private(set) lazy var message = settings.value.deviceNotice?.message
    private lazy var operation = settings.value.deviceNotice?.operation

    public func report(_ message: String, for operation: Operation) {
        let failed = storageFailed()
        let value = failed
            ? "Couldn’t save to disk, so the \(shortName) stopped and recent changes were lost. Free up space, then reopen Light Touch."
            : message
        logEvent(value)
        self.message = value
        let kind = (failed ? .storage : operation).rawValue
        self.operation = kind
        settings.change { $0.deviceNotice = .init(message: value, operation: kind) }
        onChange?()
    }

    /// The notice's remedy is Erase All Content and Settings (a refused overlay, an unfinished or failed erase,
    /// an unactivated guest).
    public var offersErase: Bool {
        [Operation.erase.rawValue, Operation.activation.rawValue].contains(operation) && !storageFailed()
    }

    public func dismiss() {
        guard !storageFailed() else { return }
        message = nil
        operation = nil
        settings.change { $0.deviceNotice = nil }
        onChange?()
    }

    public func resolve(_ operation: Operation) {
        if self.operation == operation.rawValue { dismiss() }
    }
}
