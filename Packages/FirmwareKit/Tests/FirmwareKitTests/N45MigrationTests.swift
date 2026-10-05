import Foundation
import HostRuntime
import Testing
@testable import FirmwareKit
import FirmwareSchema

/// Boot admission moves a recipe-1 M68 (and a recipe-2 N45) to the SystemConfiguration path 1.x reads.
struct N45MigrationTests {
    static func record(_ device: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: device.appendingPathComponent("device.json"))) as? [String: Any])
    }
    static func storage(_ device: URL) throws -> (base: URL, overlay: URL, key: String) {
        let r = try record(device), s = try #require(r["storage"] as? [String: Any])
        return (URL(fileURLWithPath: try #require((r["base"] as? [String: Any])?["path"] as? String)),
                URL(fileURLWithPath: try #require(s["overlay"] as? String)), try #require(s["key"] as? String))
    }

    /// A booted M68 prepared at recipe 1 before 8a54efd (root's Preferences, no SystemConfiguration in it).
    /// Admission writes the files through a stopped edit, stamps the overlay, and then leaves the device alone
    /// until Erase takes the overlay away.
    @Test func admissionWritesRootsSystemConfiguration() async throws {
        let fm = FileManager.default
        let root = try Fixtures.tempDir("n45-sc-step")
        defer { try? fm.removeItem(at: root) }
        let device = root.appendingPathComponent("device"), base = device.appendingPathComponent("base")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("volume.img")
        try await VolumeMount.makeHFS(image, size: 16 << 20, name: "SC step test")
        // What 1.x's configd writes there at first boot (measured on 1A543a): its own AirPort service on en0, and
        // no known networks.
        try await VolumeMount.withMounted(image, at: root.appendingPathComponent("initial")) { mount in
            let sc = mount.appendingPathComponent(N45Board.scPrefs)
            try fm.createDirectory(at: sc, withIntermediateDirectories: true)
            let service: [String: Any] = ["Interface": ["DeviceName": "en0", "Hardware": "AirPort", "Type": "Ethernet"], "UserDefinedName": "AirPort"]
            try PropertyListSerialization.data(fromPropertyList: ["NetworkServices": ["CONFIGD": service]], format: .xml, options: 0)
                .write(to: sc.appendingPathComponent("preferences.plist"))
            try PropertyListSerialization.data(fromPropertyList: ["JoinMode": "Automatic", "List of known networks": [Any]()], format: .xml, options: 0)
                .write(to: sc.appendingPathComponent("com.apple.wifi.plist"))
        }
        let dirs = ["private", "private/var", "private/var/root", N45Board.rootLibrary, N45Board.rootLibrary + "/Preferences", N45Board.scPrefs,
                    N45Board.scPrefs + "/preferences.plist", N45Board.wifiPrefs]
        try HFSPlusVolume(image, writable: true).setOwner(dirs, uid: 0, gid: 0, mode: 0o755)   // root's, as the recipe leaves them
        try N45NAND.write(volume: image, out: base.appendingPathComponent("nand"), filID: 0x4330_3030, banks: N45FTLTests.banks)
        let overlay = device.appendingPathComponent("overlay")
        try N45FTLTests.booted(overlay, base.appendingPathComponent("nand"), changeData: false)
        try Data("old".utf8).write(to: overlay.appendingPathComponent(".base-identity"))   // the app pinned it at first boot
        let lock: [String: Any] = ["board": "m68ap", "entry": ["id": "m68ap-1A543a", "content": ["recipe": ["name": "m68", "version": 1]]]]
        try JSONSerialization.data(withJSONObject: lock).write(to: base.appendingPathComponent("device.lock.json"))
        let record: [String: Any] = ["id": UUID().uuidString, "board": "m68ap", "firmware": "m68ap-1A543a",
            "base": ["kind": "prepared", "path": base.path],
            "storage": ["key": "old", "overlay": overlay.path, "snapshot": "old-snapshot"]]
        try JSONSerialization.data(withJSONObject: record).write(to: device.appendingPathComponent("device.json"))
        #expect(try N45Migration.pending(device: device, policy: .standalone) == 2)

        #expect(try await FirmwareBootAdmission.admit(device: device).changed)
        let first = try Self.storage(device)
        #expect(first.key != "old")
        #expect(fm.fileExists(atPath: first.overlay.appendingPathComponent(N45Migration.stamp).path))
        #expect(try PreparedDeviceBoot.pinOverlay(first.overlay, toBase: first.key))   // the app can boot the edited storage
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: device.appendingPathComponent(FirmwareWire.migratedRecipeFile))) as? [String: Any]
        #expect(marker?["recipe"] as? Int == 2)
        let volume = try HFSPlusVolume(try VolumeRebuild.rebuild(base: first.base.appendingPathComponent("nand"), overlay: first.overlay,
                                                                 into: root.appendingPathComponent("verify"))[0].image)
        let prefs = try PropertyListSerialization.propertyList(from: volume.contents(volume.record(at: N45Board.scPrefs + "/preferences.plist")),
                                                               format: nil) as? [String: Any]
        let services = try #require(prefs?["NetworkServices"] as? [String: [String: Any]])
        #expect(Array(services.keys) == ["CONFIGD"])                       // the PAC on configd's service, not a second en0 one
        #expect((services["CONFIGD"]?["Proxies"] as? [String: Any])?["ProxyAutoConfigURLString"] as? String == "file:///" + SystemEdits.pacPath)
        let wifi = try volume.record(at: N45Board.wifiPrefs)
        let known = try PropertyListSerialization.propertyList(from: volume.contents(wifi), format: nil) as? [String: Any]
        #expect(known?["JoinMode"] as? String == "Automatic" && known?["AllowEnable"] as? Bool == true)
        #expect((known?["List of known networks"] as? [[String: Any]])?.map { $0["SSID_STR"] as? String } == ["qemu-ios"])
        #expect(wifi.uid == 0)

        _ = try await FirmwareBootAdmission.admit(device: device)          // stamped: nothing to do
        #expect(try Self.storage(device).key == first.key)

        try fm.removeItem(at: first.overlay)                               // Erase
        _ = try await FirmwareBootAdmission.admit(device: device)
        let erased = try Self.storage(device)
        #expect(erased.key != first.key && fm.fileExists(atPath: erased.overlay.appendingPathComponent(N45Migration.stamp).path))
    }

    /// Only the declared steps: a device prepared at the current recipe, or not 1.x, takes none.
    @Test func declaredSteps() {
        #expect(FirmwareWire.admittedRecipe(2, board: "n45ap") == 3)
        #expect(FirmwareWire.admittedRecipe(1, board: "m68ap") == 2)
        #expect(FirmwareWire.admittedRecipe(1, board: "n45ap") == 1)
        #expect(FirmwareWire.admittedRecipe(2, board: "k48ap") == 2)
    }
}
