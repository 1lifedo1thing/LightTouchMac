import Foundation

/// A live connection description, scoped to one boot. Private keys remain in
/// the developer account's protected state directory, never in this profile.
public nonisolated enum DeveloperConnectionProfile {
    public struct Connection: Codable {
        public let instance: UUID
        public let session: UUID
        public let usbmux: String
        public let inetcat: String
        public let udid: String?
    }
    private static func file(_ instance: UUID) -> URL {
        GuestDeveloperTools.state.appendingPathComponent(instance.uuidString.lowercased()).appendingPathComponent("connection.json")
    }
    public static func publish(instance: UUID, session: UUID, socket: String, udid: String?) throws {
        let destination = file(instance)
        guard FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().appendingPathComponent("enabled").path) else { return }
        let candidates = [Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("inetcat").path,
                          "/opt/homebrew/bin/inetcat", "/usr/local/bin/inetcat"].compactMap { $0 }
        guard let inetcat = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The developer USB forwarding tool is unavailable."])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.deletingLastPathComponent().path)
        let bytes = try JSONEncoder().encode(Connection(instance: instance, session: session, usbmux: socket, inetcat: inetcat, udid: udid))
        try bytes.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    public static func retire(instance: UUID, session: UUID) {
        let path = file(instance)
        guard let data = try? Data(contentsOf: path), let profile = try? JSONDecoder().decode(Connection.self, from: data),
              profile.instance == instance, profile.session == session else { return }
        try? FileManager.default.removeItem(at: path)
    }
}
