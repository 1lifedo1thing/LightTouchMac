import FirmwareSchema
import Foundation
import Subprocess
import System

/// Narrow host boundary: the GUI requests operations; FirmwareKit owns formats.
nonisolated enum FirmwareTool {
    /// FirmwareKit validates/migrates stopped storage and releases ownership
    /// before DeviceRuntime spawns the helper. No live NOR writer is hosted here.
    static func admitBoot(device: URL, managed: Bool, executable: URL) async throws -> Bool {
        let flags = managed ? ["--record-policy", "managed"] : ["--record-policy", "standalone", "--allow-raw"]
        let data = try await run(["boot-admit", "--device", device.path] + flags, executable: executable)
        let report = try JSONDecoder().decode(FirmwareWire.BootAdmission.self, from: data)
        guard report.event == "admitted" else {
            throw DeviceToolsError.failed("The firmware worker did not admit this device.")
        }
        return report.changed
    }

    /// iPhone OS 1.x: `certificate` (DER) as a system anchor in the stopped device (`firmwarekit edit --action
    /// trust-anchor`, a stopped edit through the 1.x FTL). Nothing when the device already trusts it.
    static func trustAnchor(device: URL, certificate: URL, executable: URL) async throws -> Bool {
        let data = try await run(["edit", "--device", device.path, "--action", "trust-anchor", "--cert", certificate.path,
                                  "--record-policy", "managed"], executable: executable)
        struct Report: Decodable { let changed: Bool }
        return try JSONDecoder().decode(Report.self, from: data).changed
    }

    static func run(_ arguments: [String], executable: URL) async throws -> Data {
        let child = try await Subprocess.run(.path(FilePath(executable.path)), arguments: Arguments(arguments),
            input: .none, output: .string(limit: 65536), error: .string(limit: 65536))
        guard child.terminationStatus == .exited(0) else {
            throw DeviceToolsError.failed(child.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Data(child.standardOutput.utf8)
    }
}
