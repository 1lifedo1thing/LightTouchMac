import Cocoa

/// Device ▸ Jailbreak…'s question: what the jailbreak adds to `name`'s device (Substrate on iOS 3 to 6, as FirmwareKit
/// installs it) and that it stays.
enum JailbreakAlert {
    static func make(name: String, version: String) -> NSAlert {
        let major = Int(version.split(separator: ".").first ?? "") ?? 0
        let alert = NSAlert()
        alert.messageText = "Jailbreak \(name)?"
        alert.informativeText =
            "Adds Cydia\((3...6).contains(major) ? ", Substrate," : "") and afc2, which shows the whole file system in Files. This can’t be undone."
        alert.addButton(withTitle: "Jailbreak")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}
