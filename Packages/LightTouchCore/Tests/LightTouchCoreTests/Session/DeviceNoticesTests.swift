import Foundation
import Testing
import HostServiceWire
import DeviceRuntime
import HostRuntime
@testable import LightTouchCore

/// The device notice: kept in the device's settings.plist across relaunches, resolved only by its own operation,
/// and while storage has failed, always the storage notice and not dismissable.
struct DeviceNoticesTests {
    @Test func noticesPersistResolveByOperationAndHoldWhileStorageFailed() throws {
        try withTemporaryDirectory { directory in
            var failed = false
            func open() -> DeviceNotices {
                DeviceNotices(settings: DeviceSettingsFile(directory: directory), shortName: "iPod") { failed }
            }
            let notices = open()
            var changes = 0
            notices.onChange = { changes += 1 }
            notices.report("Retry preparation", for: .preparation)
            #expect(changes == 1 && notices.message == "Retry preparation")
            #expect(open().message == "Retry preparation", "a relaunch reads the notice back")
            #expect(DeviceSettings.load(directory).deviceNotice == .init(message: "Retry preparation", operation: "preparation"))
            #expect(!notices.offersErase)

            notices.resolve(.powerOff)
            #expect(notices.message != nil && open().message != nil, "another operation's success leaves it")
            notices.resolve(.preparation)
            #expect(notices.message == nil && open().message == nil && changes == 2)

            notices.report("Couldn’t finish erasing", for: .erase)
            #expect(notices.offersErase)
            notices.report("Not activated", for: .activation)
            #expect(notices.offersErase)

            failed = true
            notices.report("Another failure", for: .powerOff)
            #expect(notices.message?.hasPrefix("Couldn’t save to disk, so the iPod stopped") == true)
            #expect(DeviceSettings.load(directory).deviceNotice?.operation == "storage")
            #expect(!notices.offersErase, "storage failure: Erase is not the remedy")
            notices.dismiss()
            #expect(notices.message != nil, "a storage failure can't be dismissed")
            notices.resolve(.storage)
            #expect(notices.message != nil)
            failed = false
            notices.dismiss()
            #expect(notices.message == nil && open().message == nil)
        }
    }

    @Test func settingsFileKeepsOtherFieldsAndSavesEachChange() throws {
        try withTemporaryDirectory { directory in
            var saved = DeviceSettings()
            saved.motionPose = 1
            try saved.save(directory)
            let file = DeviceSettingsFile(directory: directory)
            file.change { $0.keyboardInputEnabled = false }
            let read = DeviceSettings.load(directory)
            #expect(read.motionPose == 1 && read.keyboardInputEnabled == false)
        }
    }
}
