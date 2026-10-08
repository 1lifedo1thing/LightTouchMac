import Cocoa
import FirmwareSchema
import HostRuntime
import HostServiceWire
import LightTouchCore
import SwiftUI
import UniformTypeIdentifiers

extension MainWindowController {
    /// The selected device's serial and usbmuxd logs and session file, with
    /// the app-wide ones.
    private var diagnosticInstance: DeviceInstance? { session?.instance ?? selectedEntry.flatMap(host.instance(for:)) }
    var diagnosticLogs: [URL] {
        let app = ["app.log", "native.log"].map { Bundled.logsDirectory.appendingPathComponent($0) }
        let device = ["serial.log", "usbmuxd.log"].compactMap {
            diagnosticInstance?.paths.logs.appendingPathComponent($0)
        }
        return (app + device).flatMap { [$0, $0.appendingPathExtension("1")] }
    }

    @objc func showDeviceLogs(_ sender: Any?) {
        // A window per device: switching the selection opens that device's logs.
        if logWindow == nil || logInstance != diagnosticInstance?.id {
            logWindow?.close()
            logWindow = LogWindowController(logs: diagnosticLogs)
            logInstance = diagnosticInstance?.id
        }
        logWindow?.showWindow(sender)
    }

    @objc func exportDiagnostics(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Light Touch Diagnostics.zip"
        if let zip = UTType(filenameExtension: "zip") { panel.allowedContentTypes = [zip] }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let dest = panel.url else { return }
            Task { await self.writeDiagnostics(to: dest) }
        }
    }

    private func writeDiagnostics(to dest: URL) async {
        await AppEventLog.shared.flush()
        NativeLogging.flush()
        let logs = diagnosticLogs
        let device =
            emulator.map { emulator in
                """
                \(emulator.dylibProvenance)
                state: \(emulator.statusLine)
                guest tools: \(emulator.guestToolsStatus) (offer \(emulator.guestOffer.map { "\($0)" } ?? "none"))
                base: \(emulator.instance.base.path)
                network: \(emulator.network)   usbmuxd: \(emulator.usbmuxSession ?? "none")
                canManageApps: \(emulator.canManageApps)
                """
            } ?? "state: not running"
        let executables =
            Bundle.main.executableURL.flatMap {
                try? FileManager.default.contentsOfDirectory(atPath: $0.deletingLastPathComponent().path)
            } ?? []
        let reports = DiagnosticsExport.crashReports(executables: executables)
        let info = """
            LightTouchMac diagnostics
            \(DiagnosticsExport.systemSummary())
            crash reports: \(reports.isEmpty ? "none in the last 30 days" : reports.map(\.lastPathComponent).joined(separator: ", "))
            device: \(diagnosticInstance.map { "\($0.name) \($0.firmware) \($0.id)" } ?? "none")
            \(device)
            """
        do {
            try await DiagnosticsExport.write(to: dest, logs: logs, info: info, crashReports: reports)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch is CancellationError {
            // The exporter waits for its child to stop before removing scratch.
        } catch {
            if let window { await NSAlert(error: error).beginSheetModal(for: window) }
        }
    }
}
