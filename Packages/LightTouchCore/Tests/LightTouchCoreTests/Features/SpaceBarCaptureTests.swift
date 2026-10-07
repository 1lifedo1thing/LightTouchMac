import Testing
@testable import LightTouchCore

/// The Space bar as a capture key: off by default, one capture per press with its repeats and release swallowed,
/// modifiers and other keys pass, ownership survives focus and modifier changes but never goes stale.
struct SpaceBarCaptureTests {
    struct Keys {
        var space = SpaceBarCapture()
        var action = CaptureSpaceBarAction.saveScreenshot
        var eligible = true
        mutating func down(_ modifiers: KeyModifiers = [], repeating: Bool = false, code: UInt16 = 49) -> SpaceBarCapture.Outcome {
            space.key(code, down: true, isRepeat: repeating, modifiers: modifiers, eligible: eligible, action: action)
        }
        mutating func up(_ modifiers: KeyModifiers = []) -> SpaceBarCapture.Outcome {
            space.key(49, down: false, isRepeat: false, modifiers: modifiers, eligible: eligible, action: action)
        }
    }

    @Test func defaultSpaceReachesTheDevice() {
        var keys = Keys(); keys.action = .none
        #expect(keys.down() == .pass && keys.up() == .pass)
    }

    @Test(arguments: [CaptureSpaceBarAction.copyScreenshot, .saveScreenshot, .saveScreenshotAs, .toggleRecording])
    func onePressOneCapture(_ action: CaptureSpaceBarAction) {
        var keys = Keys(); keys.action = action
        #expect(keys.down() == .capture(action))
        #expect(keys.down(repeating: true) == .swallow, "holding Space must not capture repeatedly")
        #expect(keys.up() == .swallow)
        #expect(keys.up() == .pass, "release is consumed only once")
    }

    @Test(arguments: [KeyModifiers.command, .control, .option, .shift, [.option, .shift]])
    func modifiedSpacePasses(_ modifiers: KeyModifiers) {
        var keys = Keys()
        #expect(keys.down(modifiers) == .pass && keys.up(modifiers) == .pass)
    }

    @Test func ownershipFollowsThePress() {
        var keys = Keys()
        #expect(keys.down(code: 0) == .pass)
        #expect(keys.down() == .capture(.saveScreenshot))
        #expect(keys.down(.option, repeating: true) == .swallow, "owned repeats stay consumed after modifier changes")
        keys.eligible = false
        #expect(keys.down(repeating: true) == .swallow, "owned repeats stay consumed after focus changes")
        #expect(keys.up() == .swallow)
        #expect(keys.down() == .pass, "typing spaces elsewhere must not capture")
        #expect(keys.up() == .pass)
        keys.eligible = true
        #expect(keys.down() == .capture(.saveScreenshot))
        // The key-up went to another app after Cmd-Tab: a later modified press must not inherit the ownership.
        #expect(keys.down(.shift) == .pass && keys.up(.shift) == .pass)
        #expect(keys.down(repeating: true) == .pass, "a repeat with no captured press is the device's")
    }
}
