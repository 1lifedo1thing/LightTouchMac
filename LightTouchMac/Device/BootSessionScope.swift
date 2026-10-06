import Foundation

/// Owns work which must never outlive one boot. The halt transaction itself
/// belongs to the controller, so retiring a boot cannot cancel its cleanup.
@MainActor
final class BootSessionScope {
    enum Work: CaseIterable {
        case foreground, readiness, recovery, watchdog, timeZone, orientation
        case guestPackage, activation, staging, powerOn, reset, usbReconnect
    }
    private(set) var id = UUID()
    private(set) var generation = 0
    private(set) var retired = false
    private var tasks: [Work: Task<Void, Never>] = [:]
    private var observers: [String: NSObjectProtocol] = [:]

    subscript(work: Work) -> Task<Void, Never>? {
        get { tasks[work] }
        set {
            tasks[work]?.cancel()
            guard !retired else { newValue?.cancel(); return }
            tasks[work] = newValue
        }
    }
    var timeZoneObserver: NSObjectProtocol? {
        get { observers["timeZone"] }
        set { setObserver("timeZone", newValue) }
    }
    /// The Mac's region and 24-hour setting (NSLocale.currentLocaleDidChangeNotification).
    var localeObserver: NSObjectProtocol? {
        get { observers["locale"] }
        set { setObserver("locale", newValue) }
    }
    private func setObserver(_ key: String, _ newValue: NSObjectProtocol?) {
        if let old = observers[key] { NotificationCenter.default.removeObserver(old) }
        guard !retired else {
            if let newValue { NotificationCenter.default.removeObserver(newValue) }
            observers[key] = nil
            return
        }
        observers[key] = newValue
    }
    func retire() {
        guard !retired else { return }
        retired = true
        generation += 1 // invalidate suspended completions before another boot
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        timeZoneObserver = nil
        localeObserver = nil
    }
    func renew() {
        retire()
        id = UUID()
        retired = false
    }
}
