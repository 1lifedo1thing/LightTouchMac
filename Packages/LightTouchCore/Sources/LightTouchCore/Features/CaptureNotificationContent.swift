import Foundation
import HostRuntime
import UserNotifications

/// What capture and device notifications say, and the identity their actions find again (CaptureNotifications posts them).
public enum CaptureNotificationContent {
    public nonisolated static let recoveryCategory = "CAPTURE_RECORDING_RECOVERED"
    public nonisolated static let reminderCategory = "CAPTURE_STILL_RECORDING"
    public nonisolated static let readyCategory = "DEVICE_READY"

    public static func ready(_ name: String, entryID: String) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(name) is ready to use"
        content.categoryIdentifier = readyCategory
        content.userInfo = ["entry": entryID]
        return content
    }

    public static func recovery(filename: String, bookmark: Data) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Recording recovered"
        content.body = filename
        content.categoryIdentifier = recoveryCategory
        content.userInfo = ["recordingBookmark": bookmark]
        return content
    }

    public static func reminder(recordingID: UUID, profile: Board) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(profile.shortName) is still recording"
        content.categoryIdentifier = reminderCategory
        content.userInfo = ["recordingID": recordingID.uuidString]
        return content
    }
}
