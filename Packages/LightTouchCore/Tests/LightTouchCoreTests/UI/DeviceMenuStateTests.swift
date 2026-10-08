import Testing

@testable import LightTouchCore

/// The Device menu's device items and the capture commands' availability, from a device snapshot; the rotation
/// control's alternating turns.
struct DeviceMenuStateTests {
    func running() -> DeviceMenuState {
        var state = DeviceMenuState()
        state.isRunning = true
        state.acceptsInput = true
        return state
    }

    @Test func pauseNamesWhatItDoesAndWaitsForInstalls() {
        var state = running()
        #expect(state.validate(.pause) == .init(isEnabled: true, title: "Pause"))
        state.isRunning = false
        state.isPaused = true
        state.acceptsInput = false
        #expect(state.validate(.pause) == .init(isEnabled: true, title: "Resume"))
        state = running()
        state.hasPendingInstalls = true
        #expect(!state.validate(.pause).isEnabled, "a queued install keeps the device running")
        state = running()
        state.isInstalling = true
        #expect(!state.validate(.pause).isEnabled)
        state = DeviceMenuState()
        #expect(!state.validate(.pause).isEnabled, "nothing to pause when stopped")
    }

    /// State audit A-14: Restart was enabled whenever the device wasn't dead. Paused, it is (the restart resumes the
    /// guest first); powered off it powers on; not while it stops, is dead, or its storage failed.
    @Test func restartIsOfferedWhereItCanRun() {
        var state = running()
        #expect(state.validate(.restart).isEnabled)
        state.isRunning = false
        state.isPaused = true
        #expect(state.validate(.restart).isEnabled)
        state = DeviceMenuState()
        state.isPoweredOff = true
        #expect(state.validate(.restart).isEnabled)
        for change: (inout DeviceMenuState) -> Void in [
            { $0.isDead = true }, { $0.shuttingDown = true }, { $0.storageFailed = true },
        ] {
            var stopped = running()
            change(&stopped)
            #expect(!stopped.validate(.restart).isEnabled)
        }
    }

    @Test func rotationLeavesArrowKeysToTextBeingEdited() {
        var state = running()
        #expect(state.validate(.rotate).isEnabled)
        state.editingText = true
        #expect(!state.validate(.rotate).isEnabled)
        state.editingText = false
        state.acceptsInput = false
        #expect(!state.validate(.rotate).isEnabled)
    }

    @Test func inputNeedsADeviceTakingInput() {
        var state = running()
        #expect(state.validate(.input).isEnabled && state.validate(.charging).isEnabled)
        state.acceptsInput = false
        #expect(
            !state.validate(.input).isEnabled && !state.validate(.batteryLevel(100)).isEnabled
                && !state.validate(.charging).isEnabled
        )
    }

    @Test func batteryAndCompassCheckTheirCurrentValue() {
        var state = running()
        state.batteryLevel = 50
        state.batteryCharging = true
        #expect(state.validate(.batteryLevel(50)) == .init(isEnabled: true, isOn: true))
        #expect(state.validate(.batteryLevel(100)).isOn == false)
        #expect(state.validate(.charging).isOn == true)
        #expect(!state.validate(.compassHeading(0)).isEnabled, "no compass, dimmed (never left out)")
        state.hasCompass = true
        state.compassHeading = 90
        #expect(state.validate(.compassHeading(90)) == .init(isEnabled: true, isOn: true))
        #expect(state.validate(.compassHeading(0)).isOn == false)
        state.compassHeading = nil
        #expect(state.validate(.compassHeading(0)).isOn == false)
    }

    @Test func carrierNeedsACellularDeviceRunningOrPaused() {
        var state = running()
        #expect(!state.validate(.carrier).isEnabled)
        state.hasCellular = true
        #expect(state.validate(.carrier).isEnabled)
        state.isRunning = false
        state.isPaused = true
        #expect(state.validate(.carrier).isEnabled)
        state.isPaused = false
        #expect(!state.validate(.carrier).isEnabled)
    }

    @Test func lockWakesAndPowersOn() {
        var state = running()
        #expect(state.validate(.lock) == .init(isEnabled: true, title: "Lock"))
        state.isSleeping = true
        #expect(state.validate(.lock).title == "Wake")
        state = DeviceMenuState()
        state.isPoweredOff = true
        #expect(state.validate(.lock) == .init(isEnabled: true, title: "Start"))
        state.shuttingDown = true
        #expect(!state.validate(.lock).isEnabled)
    }

    @Test func captureAvailabilityFollowsTheDevice() {
        var c = CaptureAvailability()
        c.isRunning = true
        #expect(c.canTakeScreenshot && c.canStartRecording && c.canToggleRecording)
        c.isRunning = false
        c.isPaused = true
        #expect(
            c.canTakeScreenshot && !c.canStartRecording && !c.canToggleRecording,
            "a paused screen can be shot, not recorded"
        )
        c.isSleeping = true
        #expect(!c.canTakeScreenshot && !c.canToggleRecording)
        c.recordingCanStop = true
        #expect(c.canToggleRecording, "stopping must remain available when the guest stops")
        c.recordingSaving = true
        #expect(!c.canToggleRecording)
        c.recordingSaving = false
        c.recordingCanStop = false
        c.recordingNeedsRecovery = true
        #expect(c.canToggleRecording, "recovery must remain available offline")
        c = CaptureAvailability()
        c.isRunning = true
        c.screenshotBusy = true
        #expect(!c.canTakeScreenshot && !c.canStartRecording && !c.canToggleRecording)
        #expect(!CaptureAvailability().canTakeScreenshot, "no device")
    }

    /// Default presses alternate between upright portrait and home-button-right landscape; Option reverses the same
    /// next turn, including after auto-rotation.
    @Test func rotationControlAlternates() {
        var degrees = 0
        for expected in [270, 0, 270, 0] {
            let action = RotationControlAction(rotationDegrees: degrees, optionPressed: false)
            degrees = (degrees + (action.clockwise ? 90 : 270)) % 360
            #expect(degrees == expected)
        }
        for degrees in [0, 90, 180, 270] {
            let normal = RotationControlAction(rotationDegrees: degrees, optionPressed: false)
            let alternate = RotationControlAction(rotationDegrees: degrees, optionPressed: true)
            #expect(normal.clockwise != alternate.clockwise && normal.symbol != alternate.symbol)
        }
    }
}
