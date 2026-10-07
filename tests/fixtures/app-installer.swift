// Stand-ins for what Features/AppInstaller.swift reaches outside itself, for the offline queue checks that compile
// it whole (check-install-queue-scope, check-media-queue, check-uninstall-queue, check-ipa-library). Each check
// brings its own EmulatorController (the device side it drives) and DeviceInstance, and compiles the real
// Board, DeviceExecution (DeviceError) and InstallationQueue; tests/fixtures/app-installer-library.swift
// adds IPALibrary and the Legacy Store for the checks that don't compile the real ones.

import HostRuntime
import Cocoa

struct InstalledApp { let id: String }

@MainActor final class AppMetadataCache {
    static let shared = AppMetadataCache()
    var forgotten: [String] = []
    func forget(_ id: String) { forgotten.append(id) }
    func preview(of ipa: URL) async -> (name: String, bundleID: String)? { nil }
    func learn(from ipa: URL) async -> String? { nil }
    static func bundleID(of ipa: URL) async -> String? { nil }
    static func info(of ipa: URL) async -> [String: Any]? { nil }
}

@MainActor final class DeviceLibrary { static let shared = DeviceLibrary(); var instances: [DeviceInstance] = [] }

/// A prepared photo or song, named after its source file. `failed` names fail to prepare, `delayed` ones wait for
/// `preparation[name]` to be resumed.
@MainActor struct PreparedMedia {
    static var failed = Set<String>()
    static var delayed = Set<String>()
    static var preparation: [String: CheckedContinuation<Void, Error>] = [:]
    struct Failure: LocalizedError { var errorDescription: String? { "Unreadable photo" } }
    let directory: URL, title: String, destination: String
    static var prepared: [String] = []
    nonisolated static func destination(forExtension suffix: String) -> String {
        ["mp3": "Music", "mov": "Videos"][suffix.lowercased()] ?? "Photos"
    }
    static func prepare(_ source: URL, profile: Board) async throws -> PreparedMedia {
        let name = source.deletingPathExtension().lastPathComponent
        prepared.append(name)
        if delayed.contains(name) { try await withCheckedThrowingContinuation { preparation[name] = $0 } }
        try Task.checkCancellation()
        if failed.contains(name) { throw Failure() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-app-installer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return PreparedMedia(directory: directory, title: name, destination: source.pathExtension == "mp3" ? "Music" : "Photos")
    }
}

/// EmulatorController.mediaFirmware, set per check; MediaSupport itself is compiled for real.
@MainActor var fixtureMediaFirmware = MediaSupport.Firmware(version: "3.1.3", name: "iOS 3.1.3", media: ["Music", "Photos", "Videos"])
extension EmulatorController { var mediaFirmware: MediaSupport.Firmware { fixtureMediaFirmware } }

/// EmulatorController.installPipeline: the queue checks reach only its placeholder.
struct InstallPipeline {
    @discardableResult
    func installPlaceholder(_ action: String, bundleID: String, after previous: Task<Void, Never>? = nil) -> Task<Void, Never>? { nil }
}
