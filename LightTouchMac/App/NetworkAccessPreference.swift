import Cocoa
import Network

/// Resolve consent before QEMU can send any guest traffic. Loopback USB and
/// Mac-side app downloads remain available when guest networking is off.
enum NetworkAccessPreference {
    static let key = "guestNetworkEnabled"

    /// Whether the device about to start gets the Mac's network: `--network`/`--no-network`
    /// on the command line (a choice that is not remembered), else the saved answer, else a prompt.
    static func resolve(profile: DeviceProfile) -> Bool {
        let arguments = CommandLine.arguments
        if arguments.contains("--no-network") { return false }
        if arguments.contains("--network") { return true }
        if let enabled = UserDefaults.standard.object(forKey: key) as? Bool { return enabled }
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: "network", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 48, weight: .regular))
        alert.messageText = "Connect your \(profile.shortName) to the internet?"
        alert.informativeText = "Your \(profile.shortName) can use your Mac’s internet connection. You can change this later in the Device menu."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Use Offline")
        let enabled = alert.runModal() == .alertFirstButtonReturn
        UserDefaults.standard.set(enabled, forKey: key)
        if enabled { requestLocalNetworkAccess() }
        return enabled
    }

    /// macOS asks for Local Network access the first time the app reaches the LAN. Asked now, right after
    /// Connect, the question has its context, not later in the middle of a session: one mDNS datagram does it.
    static func requestLocalNetworkAccess() {
        let connection = NWConnection(host: "224.0.0.251", port: 5353, using: .udp)
        connection.start(queue: .main)
        connection.send(content: Data([0]), completion: .contentProcessed { _ in })
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { connection.cancel() }
    }
}
