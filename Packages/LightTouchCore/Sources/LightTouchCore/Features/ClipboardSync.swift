// Settings ▸ General ▸ Share clipboard with devices: what the Mac's clipboard and the devices' pasteboards trade, so
// a copy on either side is there to paste on the other. Text only, as the guest agent carries it (it_agent's
// QC_PB_* ops); iPhone OS 3.0 brought the pasteboard, so 1.x and 2.x have none to share.
//
// Echoes: the agent never reports text the app gave it, nor what the guest held when it started; this side never
// sends back a copy it took from a device (`shared`), nor takes its own write to the Mac's pasteboard for a copy.

import Foundation

public struct ClipboardSync: Sendable, Equatable {
    /// UTF-8 bytes either way: the guest agent's buffer, less its NUL. Longer text isn't shared at all (cut short,
    /// it would paste something nobody copied).
    public static let maxBytes = 65_535
    public static let key = "ShareClipboard"

    /// The text both sides last held: what every device should have, and what's no news from any of them.
    public private(set) var shared: String?
    /// The Mac pasteboard's changeCount as last seen (read or written here).
    private var macChangeCount: Int?

    public init() {}

    /// The device's iOS has a pasteboard (3.0 and later).
    public static func supported(iosVersion: String) -> Bool {
        iosVersion.compare("3.0", options: .numeric) != .orderedAscending
    }

    public static func fits(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= maxBytes }

    /// The Mac's pasteboard as polled. `text` is read only when the count moved: the new text for the devices, or nil
    /// (no change, this side's own write, no text, too long, or the same text again).
    public mutating func macChanged(changeCount: Int, text: () -> String?) -> String? {
        guard changeCount != macChangeCount else { return nil }
        macChangeCount = changeCount
        guard let text = text(), Self.fits(text), text != shared else { return nil }
        shared = text
        return text
    }

    /// A device's copy: the text to put on the Mac's pasteboard, or nil (an echo of `shared`, or too long).
    /// Every other device should get it too.
    public mutating func guestCopied(_ text: String) -> String? {
        guard Self.fits(text), text != shared else { return nil }
        shared = text
        return text
    }

    /// The Mac's pasteboard after this side wrote it: that change is no copy.
    public mutating func wroteMac(changeCount: Int) { macChangeCount = changeCount }

    /// What a device should be handed now: `shared` when it has something else (`delivered`: what it was last
    /// handed, or reported). nil when nothing's to go.
    public func pending(delivered: String?) -> String? {
        guard let shared, shared != delivered else { return nil }
        return shared
    }
}
