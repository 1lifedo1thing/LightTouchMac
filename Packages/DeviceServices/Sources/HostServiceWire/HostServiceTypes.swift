import Foundation

public nonisolated struct InstalledApp: Identifiable, Codable, Sendable {
    /// The `CFBundleIdentifier`
    public let id: String
    public let name: String
    public let version: String
    public init(id: String, name: String, version: String) {
        self.id = id
        self.name = name
        self.version = version
    }
}

public nonisolated struct DeviceFile: Codable, Sendable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let isRegular: Bool
    public let size: UInt64
    public init(name: String, path: String, isDirectory: Bool, isRegular: Bool, size: UInt64) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isRegular = isRegular
        self.size = size
    }
}

/// A host worker can never select another device after it starts. The session
/// distinguishes reused ports and prevents completions crossing a cold boot.
public nonisolated struct HostServiceEndpoint: Hashable, Codable, Sendable {
    public let socket: String
    public let udid: String?
    public let session: UUID
    public init(socket: String, udid: String?, session: UUID) {
        self.socket = socket
        self.udid = udid
        self.session = session
    }
}

public nonisolated enum HostServiceOperation: Codable, Sendable {
    case attachment, apps, archives, freeSpace, installReady, homeOrder, orientation
    case lockdownValue(String)
    case uninstall(String)
    case install(ipa: String, staged: String, bundleID: String)
    case upload(source: String, remote: String, reuse: Bool, allowEmpty: Bool)
    case sweep
    case remove(String)
    case files(String)
    case download(DeviceFile, destination: String)
    case move(bundle: String, before: String?, deviceName: String)
    case observe
}

public nonisolated enum HostServiceValue: Codable, Sendable {
    case none
    case boolean(Bool)
    case integer(Int64)
    case string(String?)
    case strings([String])
    case apps([InstalledApp])
    case files([DeviceFile])
}

public nonisolated enum HostServiceProgress: Codable, Sendable {
    case fraction(Double)
    case install(Int, String)
    case notification
}
