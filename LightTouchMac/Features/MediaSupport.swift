// Which libraries a device's firmware can take media into, decided before
// anything is prepared, staged or spawned: itmedia adds to Music and Videos,
// itphoto to Saved Photos (qemu-ios contrib/it-media). A firmware outside
// what they have been qualified on gets a plain refusal on the job row.

import Foundation

nonisolated enum MediaSupport {
    /// A device's firmware as the gate reads it: board, marketing version, build, and the name the sidebar shows.
    struct Firmware: Sendable, Equatable {
        var board: String
        var version: String
        var build: String
        /// "iOS 5.0 Beta 1"
        var name: String
    }

    /// Whether this firmware's helpers can add to `destination` ("Music", "Videos", "Photos").
    static func supports(_ destination: String, on firmware: Firmware) -> Bool {
        firmware.board == "n72ap" && firmware.build == "7E18"
    }

    /// Whether any media can be added (the Import Media… command).
    static func supportsAny(_ firmware: Firmware) -> Bool {
        ["Music", "Videos", "Photos"].contains { supports($0, on: firmware) }
    }

    /// nil when `destination` can be added to on this firmware; else the row's words.
    static func refusal(_ destination: String, on firmware: Firmware) -> String? {
        guard !supports(destination, on: firmware) else { return nil }
        let what = ["Music": "music", "Videos": "videos", "Photos": "photos"][destination] ?? "media"
        return "Adding \(what) isn’t supported on \(firmware.name) yet."
    }
}
