import Cocoa
import LightTouchCore

/// Help ▸ Copy Bug Report Info: the block (BugReportInfo) on the pasteboard, announced for VoiceOver; the menu's own
/// flash is the visual confirmation, as with any Copy.
enum BugReportCopy {
    static let title = "Copy Bug Report Info"

    @discardableResult
    static func copy(
        devices: [BugReportInfo.Device],
        bezel: String? = nil,
        secrets: [String] = [],
        to pasteboard: NSPasteboard = .general
    ) -> String {
        let text = BugReportInfo.text(
            system: DiagnosticsExport.systemSummary(),
            bezel: bezel,
            devices: devices,
            recentErrors: BugReportInfo.recentErrors(log: Bundled.logsDirectory.appendingPathComponent("app.log")),
            secrets: secrets
        )
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let app = NSApp {
            NSAccessibility.post(
                element: app,
                notification: .announcementRequested,
                userInfo: [.announcement: "Bug report info copied", .priority: NSAccessibilityPriorityLevel.medium.rawValue]
            )
        }
        return text
    }
}
