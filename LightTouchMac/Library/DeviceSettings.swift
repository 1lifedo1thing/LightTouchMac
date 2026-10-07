// A device's own settings: Devices/<uuid>/settings.plist (XML), beside its record rather than in it. The app
// changes these at any moment, and a storage transaction (erase, a stopped edit, boot admission) refuses to
// publish over a device.plist that changed under it. Deleting the device's directory deletes them.

import LightTouchCore
import Foundation
import HostRuntime

nonisolated struct DeviceSettings: Codable, Equatable {
    struct Notice: Codable, Equatable {
        var message: String
        /// An EmulatorController.NoticeOperation.
        var operation: String?
    }
    var deviceNotice: Notice?
    var motionPose: Int?
    var keyboardInputEnabled: Bool?
    var autoRotateWithGuest: Bool?
    var debugPort: Bool?
    var carrier: CarrierSettings?
    /// Connect Hardware Keyboard (⇧⌘K); nil is connected.
    var hardwareKeyboard: Bool?
    /// Attach to Local Network; nil is off.
    var localNetwork: Bool?

    static func url(_ device: URL) -> URL { device.appendingPathComponent("settings.plist") }

    /// `device`: its directory. Empty settings when there are none yet.
    static func load(_ device: URL) -> DeviceSettings {
        (try? Data(contentsOf: url(device))).flatMap { try? PropertyListDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    func save(_ device: URL) throws { try PropertyListFile.write(self, to: Self.url(device)) }

    /// Launch: earlier builds kept these in user defaults as "<name>.<uuid>" (the carrier as JSON data), with
    /// app-wide keyboardInputEnabled and autoRotateWithGuest from before that. Each device in `devices` gets
    /// its values written to its settings.plist, then every such key goes, a deleted device's too.
    static func migrateDefaults(_ defaults: UserDefaults, state: URL, devices: [UUID]) {
        let names: Set = ["deviceNotice", "motionPose", "keyboardInputEnabled", "autoRotateWithGuest", "debugPort", "carrier"]
        var kept: [UUID: [String: Any]] = [:], keys: [UUID: [String]] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard let dot = key.lastIndex(of: "."), names.contains(String(key[..<dot])),
                  let id = UUID(uuidString: String(key[key.index(after: dot)...])) else { continue }
            kept[id, default: [:]][String(key[..<dot])] = value
            keys[id, default: []].append(key)
        }
        let keyboard = defaults.object(forKey: "keyboardInputEnabled") as? Bool
        let autoRotate = defaults.object(forKey: "autoRotateWithGuest") as? Bool
        var failed = false
        for id in devices {
            let directory = DeviceInstance.directory(id, state: state), values = kept[id] ?? [:]
            let old = load(directory)
            var new = old
            if let notice = values["deviceNotice"] as? [String: String], let message = notice["message"] {
                new.deviceNotice = Notice(message: message, operation: notice["operation"])
            }
            if let pose = values["motionPose"] as? Int { new.motionPose = pose }
            new.keyboardInputEnabled = values["keyboardInputEnabled"] as? Bool ?? new.keyboardInputEnabled ?? keyboard
            new.autoRotateWithGuest = values["autoRotateWithGuest"] as? Bool ?? new.autoRotateWithGuest ?? autoRotate
            if let debugPort = values["debugPort"] as? Bool { new.debugPort = debugPort }
            if let data = values["carrier"] as? Data, let carrier = try? JSONDecoder().decode(CarrierSettings.self, from: data) {
                new.carrier = carrier
            }
            if new != old {
                do { try new.save(directory) } catch {
                    // Kept for the next launch to try again.
                    failed = true
                    keys[id] = nil
                }
            }
        }
        for key in keys.values.joined() { defaults.removeObject(forKey: key) }
        if !failed { for key in ["keyboardInputEnabled", "autoRotateWithGuest"] { defaults.removeObject(forKey: key) } }
    }
}
