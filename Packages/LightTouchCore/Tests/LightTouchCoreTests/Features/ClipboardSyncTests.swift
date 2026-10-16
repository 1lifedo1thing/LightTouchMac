import Testing

@testable import LightTouchCore

/// Share clipboard with devices: a copy on either side reaches the other once, with no echo back and no Mac write
/// taken for a copy; which iOS versions have a pasteboard; the size cap.
struct ClipboardSyncTests {
    @Test func macCopyGoesToDevicesOnceAndIsReadOnlyWhenTheCountMoves() {
        var sync = ClipboardSync()
        let text = "Ünïcødé 🍎 https://example.com/?a=1"
        var reads = 0
        func read(_ value: String) -> String {
            reads += 1
            return value
        }
        #expect(sync.macChanged(changeCount: 1) { read(text) } == text)
        #expect(sync.macChanged(changeCount: 1) { read("unread") } == nil)
        #expect(reads == 1)
        // The same text copied again on the Mac is nothing new for the devices.
        #expect(sync.macChanged(changeCount: 2) { "Ünïcødé 🍎 https://example.com/?a=1" } == nil)
        // No text (an image, a file) leaves the devices with what they have.
        #expect(sync.macChanged(changeCount: 3) { nil } == nil)
        #expect(sync.shared == "Ünïcødé 🍎 https://example.com/?a=1")
    }

    @Test func guestCopyGoesToTheMacWithoutComingBack() {
        var sync = ClipboardSync()
        _ = sync.macChanged(changeCount: 5) { "from the Mac" }
        // The device reporting the Mac's own text back is an echo.
        #expect(sync.guestCopied("from the Mac") == nil)
        #expect(sync.guestCopied("from the device") == "from the device")
        // The app's write to the Mac's pasteboard moves the count; that is no Mac copy to send back.
        sync.wroteMac(changeCount: 6)
        #expect(sync.macChanged(changeCount: 6) { "from the device" } == nil)
        // Nor is the same text read back under a later count (another app touching the pasteboard).
        #expect(sync.macChanged(changeCount: 7) { "from the device" } == nil)
        // A real Mac copy after that still goes.
        #expect(sync.macChanged(changeCount: 8) { "next" } == "next")
    }

    @Test func eachDeviceIsHandedTheSharedTextUntilItHasIt() {
        var sync = ClipboardSync()
        #expect(sync.pending(delivered: nil) == nil)
        _ = sync.macChanged(changeCount: 1) { "a" }
        // A device that started later (nothing delivered) gets it; one that has it, or copied it, doesn't.
        #expect(sync.pending(delivered: nil) == "a")
        #expect(sync.pending(delivered: "a") == nil)
        _ = sync.guestCopied("b")
        #expect(sync.pending(delivered: "a") == "b")
        #expect(sync.pending(delivered: "b") == nil)
    }

    @Test func oversizedAndEmptyTextIsNotShared() {
        var sync = ClipboardSync()
        let limit = String(repeating: "é", count: ClipboardSync.maxBytes / 2)  // 2 UTF-8 bytes each
        let over = limit + "é"
        #expect(sync.macChanged(changeCount: 1) { over } == nil)
        #expect(sync.guestCopied(over) == nil)
        #expect(sync.guestCopied("") == nil)
        #expect(sync.macChanged(changeCount: 2) { limit } == limit)
    }

    @Test func onlyIOS3AndLaterHaveAPasteboard() {
        #expect(!ClipboardSync.supported(iosVersion: "1.1.5"))
        #expect(!ClipboardSync.supported(iosVersion: "2.2.1"))
        #expect(ClipboardSync.supported(iosVersion: "3.0"))
        #expect(ClipboardSync.supported(iosVersion: "3.1.3"))
        #expect(ClipboardSync.supported(iosVersion: "7.1.2"))
    }
}
