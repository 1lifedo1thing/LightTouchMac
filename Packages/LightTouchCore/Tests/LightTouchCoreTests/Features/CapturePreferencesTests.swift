import Foundation
import HostRuntime
import Testing
import UserNotifications
@testable import LightTouchCore

/// Capture preferences: defaults written nowhere until chosen, the save location and its three recent folders, the
/// "Open in" app with its fallback, refused out-of-range values; the notifications' identity payloads.
struct CapturePreferencesTests {
    func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let domain = "ltm-capture-preferences-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults)
    }

    @Test func defaultsAreImplicit() throws {
        try withDefaults { defaults in
            let preferences = CapturePreferences(defaults: defaults)
            #expect(preferences.saveLocation == CapturePreferences.desktopDirectory)
            #expect(preferences.openFinderAfterCapture && preferences.soundEffectsEnabled)
            #expect(!preferences.copyOnCapture && !preferences.notifyOnRecordingRecovery)
            #expect(preferences.reminderAfterDuration == 0)
            _ = preferences.saveLocations; _ = preferences.openInApplicationURL
            #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("capture") || ["copyOnCapture",
                    "openFinderAfterCapture", "soundEffectsEnabled", "reminderAfterDuration", "openInApplicationPath"].contains($0) }.isEmpty,
                    "reading writes nothing")
        }
    }

    @Test func saveLocationAndRecentFolders() throws {
        try withDefaults { defaults in
            let preferences = CapturePreferences(defaults: defaults)
            let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Capture options " + UUID().uuidString)
            let oldFolder = base.appendingPathComponent("Existing save location")
            defaults.set(oldFolder.path, forKey: "captureFolder")   // an earlier build's key: upgrading never moves saves
            #expect(preferences.saveLocation.path == oldFolder.standardizedFileURL.path)
            #expect(preferences.saveLocations.contains { $0.path == oldFolder.standardizedFileURL.path })
            for name in ["One", "Two", "Three", "Four", "Two"] { preferences.saveLocation = base.appendingPathComponent(name) }
            #expect(defaults.stringArray(forKey: "captureRecentFolders")?.count == 3)
            #expect(preferences.saveLocations.dropFirst().map(\.lastPathComponent) == ["Two", "Four", "Three"])
            preferences.saveLocation = CapturePreferences.desktopDirectory
            #expect(preferences.saveLocations.count == 4, "the Desktop is always first, never a recent")
            preferences.saveLocation = URL(string: "https://example.com/folder")!
            #expect(preferences.saveLocation == CapturePreferences.desktopDirectory, "only file URLs")
        }
    }

    @Test func openInApplicationFallsBackToPreview() throws {
        try withDefaults { defaults in
            try withTemporaryDirectory { base in
                let preferences = CapturePreferences(defaults: defaults)
                defaults.set("/no-longer-installed/Image.app", forKey: "openInApplicationPath")
                #expect(preferences.openInApplicationURL == CapturePreferences.previewApplicationURL)
                #expect(CapturePreferences.previewApplicationURL?.lastPathComponent == "Preview.app")
                let app = base.appendingPathComponent("Image Editor.app")
                try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
                let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "test.capture.editor.\(UUID().uuidString)", "CFBundleName": "Image Editor"]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
                preferences.openInApplicationURL = app
                #expect(preferences.openInApplicationURL?.path == app.path)
                #expect(preferences.openInApplicationName == "Image Editor")
                preferences.openInApplicationURL = base
                #expect(preferences.openInApplicationURL?.path == app.path, "an invalid app must not replace an explicit choice")
                try FileManager.default.removeItem(at: app)
                #expect(preferences.openInApplicationURL == CapturePreferences.previewApplicationURL,
                        "a deleted app must not remain selected through Bundle's metadata cache")
            }
        }
    }

    @Test func outOfRangeValuesReadAsDefaults() throws {
        try withDefaults { defaults in
            let preferences = CapturePreferences(defaults: defaults)
            defaults.set(-60, forKey: "reminderAfterDuration")
            #expect(preferences.reminderAfterDuration == 0)
            preferences.reminderAfterDuration = 301
            #expect(preferences.reminderAfterDuration == 0, "only the listed durations")
            preferences.reminderAfterDuration = 300
            preferences.copyOnCapture = true; preferences.openFinderAfterCapture = false; preferences.soundEffectsEnabled = false
            let restored = CapturePreferences(defaults: defaults)
            #expect(restored.copyOnCapture && !restored.openFinderAfterCapture && !restored.soundEffectsEnabled)
            #expect(restored.reminderAfterDuration == 300)
        }
    }

    @Test func notificationPayloadsCarryTheirIdentity() {
        let id = UUID()
        let reminder = CaptureNotificationContent.reminder(recordingID: id, profile: .n72)
        #expect(reminder.userInfo["recordingID"] as? String == id.uuidString && reminder.title == "iPod is still recording")
        let ready = CaptureNotificationContent.ready("iPod touch (2nd generation) iOS 3.1.3", entryID: "n72ap-7E18")
        #expect(ready.title == "iPod touch (2nd generation) iOS 3.1.3 is ready to use" && ready.userInfo["entry"] as? String == "n72ap-7E18")
        let recovery = CaptureNotificationContent.recovery(filename: "Recovered.mov", bookmark: Data([1, 2, 3]))
        #expect(recovery.body == "Recovered.mov" && recovery.userInfo["recordingBookmark"] as? Data == Data([1, 2, 3]))
        #expect(Set([reminder, ready, recovery].map(\.categoryIdentifier)).count == 3)
    }
}
