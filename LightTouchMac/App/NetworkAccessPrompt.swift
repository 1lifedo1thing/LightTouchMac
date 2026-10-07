import LightTouchCore
import HostRuntime
import Cocoa

extension NetworkAccessPreference {
    /// Whether the device about to start gets the Mac's network: the decided answer, else a prompt whose answer is saved.
    static func resolve(profile: Board) -> Bool {
        if let enabled = decided() { return enabled }
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: "network", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 48, weight: .regular))
        alert.messageText = "Connect your \(profile.shortName) to the internet?"
        alert.informativeText = "Your \(profile.shortName) can use your Mac’s internet connection. You can change this later in the Device menu."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Use Offline")
        let enabled = alert.runModal() == .alertFirstButtonReturn
        UserDefaults.standard.set(enabled, forKey: key)
        return enabled
    }
}
