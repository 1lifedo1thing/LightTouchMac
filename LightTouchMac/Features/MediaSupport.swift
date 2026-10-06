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
        /// "iOS 5.0 beta 1"
        var name: String
        /// A beta or GM: the helpers were qualified on releases only.
        var prerelease = false
    }

    /// Whether this firmware's helpers can add to `destination` ("Music", "Videos", "Photos").
    static func supports(_ destination: String, on firmware: Firmware) -> Bool {
        func from(_ low: String, below high: String) -> Bool {
            firmware.version.compare(low, options: .numeric) != .orderedAscending
                && firmware.version.compare(high, options: .numeric) == .orderedAscending
        }
        guard ["n72ap", "k48ap"].contains(firmware.board), !firmware.prerelease else { return false }
        switch destination {
        // MusicLibrary's purchase-folder insert over the iTunes Library.itlp library and PLCameraAlbum's save
        // with the saved path: 3.x. Music on 5.x through ML3's importer, round-tripped on the iPad's 5.1.1 alone.
        // 4.x's post-processing deletes a library it can't verify, and neither 4.x nor 5.x has a photo save that
        // names the saved file (qemu-ios contrib/it-media/README.md).
        case "Music": return from("3.1", below: "4") || (firmware.board == "k48ap" && firmware.build == "9B206")
        case "Photos": return from("3.1", below: "4")
        // Movies through the same insert, verified (decoding included) on 3.1.3 alone.
        case "Videos": return firmware.board == "n72ap" && firmware.build == "7E18"
        default: return false
        }
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
