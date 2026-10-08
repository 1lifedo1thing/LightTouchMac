import Cocoa
import FirmwareSchema
import HostRuntime
import HostServiceWire
import LightTouchCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Menu validation (enablement + checkmarks)

extension MainWindowController: NSMenuItemValidation {
    /// The selected device as the Device menu's items see it (DeviceMenuState).
    private var deviceMenu: DeviceMenuState {
        var state = DeviceMenuState()
        guard let emulator else { return state }
        state.isRunning = emulator.isRunning
        state.isPaused = emulator.isPaused
        state.isSleeping = emulator.isSleeping
        state.isPoweredOff = emulator.isPoweredOff
        state.shuttingDown = emulator.shuttingDown
        state.isInstalling = emulator.isInstalling
        state.hasPendingInstalls = AppInstaller.hasPendingWork(for: emulator.instance.id)
        state.acceptsInput = emulator.acceptsInput
        state.hasCompass = emulator.hasCompass
        state.hasCellular = emulator.hasCellular
        state.batteryLevel = emulator.batteryLevel
        state.batteryCharging = emulator.batteryCharging
        state.compassHeading = emulator.compassHeading
        state.editingText = window?.firstResponder is NSTextView
        return state
    }

    func apply(_ validation: DeviceMenuState.Validation, to item: NSMenuItem) -> Bool {
        if let title = validation.title { item.title = title }
        if let on = validation.isOn { item.state = on ? .on : .off }
        return validation.isEnabled
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleFiles(_:)) {
            return true
        }
        // The selected row's commands, and the window's own, work without a device.
        switch menuItem.action {
        case #selector(addDevice(_:)): return window?.attachedSheet == nil
        case #selector(selectDeviceBezel(_:)):
            // A device without a 3D model (the iPhone 4, the original iPhone) shows 2D for 3D: its 3D is dimmed and
            // the check is on what it shows.
            let hasModel = currentProfile.deviceModelName != nil
            let shown = DisplayView.bezel == .model && !hasModel ? DisplayView.Bezel.flat : DisplayView.bezel
            menuItem.state = menuItem.tag == shown.rawValue ? .on : .off
            // Free-form shows this device's screen alone; the setting still applies to the others and comes back here.
            let freeForm = deviceVC?.screen.isFreeForm == true
            menuItem.toolTip =
                freeForm
                ? "Free-Form Screen shows this device’s screen without its bezel."
                : menuItem.tag == DisplayView.Bezel.model.rawValue && !hasModel ? "This device has no 3D model." : nil
            return !freeForm && (menuItem.tag != DisplayView.Bezel.model.rawValue || hasModel)
        case #selector(toggleFreeFormScreen(_:)):
            menuItem.state = deviceVC?.screen.isFreeForm == true ? .on : .off
            let profile = deviceVC?.emulator.profile
            menuItem.toolTip = profile?.supportsFreeForm == false ? profile?.freeFormUnavailableReason : nil
            return deviceVC?.screen.canToggleFreeForm ?? false
        case #selector(toggleDeviceRunning(_:)):
            let running = selectedEntry.map { [.running, .stopping].contains(host.row(for: $0).state) } ?? false
            menuItem.title = running ? "Shut Down…" : "Start"
            return selectedEntry.map { canPerform(running ? .stop : .start, for: $0) } ?? false
        case #selector(downloadAndPrepare(_:)):
            menuItem.title = selectedEntry.map { host.row(for: $0).prepareTitle } ?? "Download and Prepare"
            return selectedEntry.map { canPerform(.downloadAndPrepare, for: $0) } ?? false
        case #selector(importIPSW(_:)): return selectedEntry.map { canPerform(.importIPSW, for: $0) } ?? false
        case #selector(cancelFirmwareJob(_:)):
            menuItem.title = selectedEntry.map { host.row(for: $0).cancelTitle } ?? "Cancel Download"
            return selectedEntry.map { canPerform(.cancel, for: $0) } ?? false
        case #selector(showDeviceInFinder(_:)): return selectedEntry.map { canPerform(.showInFinder, for: $0) } ?? false
        case #selector(deleteDevice(_:)):
            let selected = library.selectedEntries
            if selected.count > 1 {
                menuItem.title = DeviceLibraryViewController.batchTitle(library.batch(selected))
                return library.canRemoveTargets
            }
            let row = selectedEntry.map(library.row(for:))
            menuItem.title = row?.removeTitle ?? "Delete Device…"
            return row.map { $0.instanceID != nil ? canPerform(.delete, for: $0.entry) : $0.canRemoveFromSidebar }
                ?? false
        case #selector(eraseDevice(_:)): return selectedEntry.map { canPerform(.erase, for: $0) } ?? false
        case #selector(toggleCaptureScreenOnly(_:)):
            menuItem.state = captureMode == 1 ? .on : .off
            return !recording.isActive && !capture.screenshotBusy
        case #selector(toggleVerboseBoot(_:)):
            menuItem.state = EmulatorController.verboseBoot ? .on : .off
            return true
        case #selector(toggleKernelConsole(_:)):
            menuItem.state = EmulatorController.kernelConsole ? .on : .off
            return true
        case #selector(discardRecording(_:)):
            return recording.canStop
        case #selector(toggleRecording(_:)):
            menuItem.title =
                recording.needsRecovery
                ? "Save Recording As…" : recording.canStop ? "Stop Recording" : "Start Recording"
            return canToggleRecording
        case #selector(toggleAppInspector(_:)):
            menuItem.title = inspectorItem.isCollapsed ? "Show Inspector" : "Hide Inspector"
            return true
        case #selector(toggleConsole(_:)):
            menuItem.title = console.split.layout.isCollapsed ? "Show Console" : "Hide Console"
            return true
        case #selector(showDeviceLogs(_:)), #selector(exportDiagnostics(_:)), #selector(showRecordingRecovery(_:)),
            #selector(showSettings(_:)), #selector(focusDeviceScreen(_:)):
            return true
        default: break
        }
        guard let emulator, let deviceVC else { return false }
        switch menuItem.action {
        case #selector(selectMotionPose(_:)):
            menuItem.state = menuItem.tag == emulator.motionPose.rawValue ? .on : .off
            return true
        case #selector(specialTrick(_:)):
            return deviceVC.screen.canPerformSpecialTrick
        case #selector(resetMotion(_:)):
            return emulator.acceptsInput && !emulator.isSleeping

        // App management: needs USB, a live guest, and no install already running
        // (the guest serves ~one lockdown session).
        case #selector(installApp(_:)):
            return emulator.canQueueInstall
        case #selector(syncMedia(_:)):
            return emulator.canQueueInstall && MediaSupport.supportsAny(emulator.mediaFirmware)
        case #selector(restartSpringBoard(_:)):
            return emulator.canReachDevice && !emulator.isInstalling
        // Device input only reaches a running guest.
        case #selector(deviceLock(_:)): return apply(deviceMenu.validate(.lock), to: menuItem)
        case #selector(deviceRotate(_:)), #selector(deviceRotateLeft(_:)), #selector(deviceRotateRight(_:)):
            return apply(deviceMenu.validate(.rotate), to: menuItem)
        case #selector(setBatteryLevel(_:)):
            return apply(deviceMenu.validate(.batteryLevel(menuItem.tag)), to: menuItem)
        case #selector(toggleBatteryCharging(_:)): return apply(deviceMenu.validate(.charging), to: menuItem)
        case #selector(setCompassHeading(_:)):
            return apply(deviceMenu.validate(.compassHeading(menuItem.tag)), to: menuItem)
        case #selector(showCarrier(_:)): return apply(deviceMenu.validate(.carrier), to: menuItem)
        case #selector(deviceHome(_:)), #selector(deviceShake(_:)),
            #selector(deviceVolumeUp(_:)), #selector(deviceVolumeDown(_:)):
            return apply(deviceMenu.validate(.input), to: menuItem)
        case #selector(toggleDevicePause(_:)): return apply(deviceMenu.validate(.pause), to: menuItem)
        case #selector(configureWebProxy(_:)):
            return emulator.webProxyAvailable
        case #selector(toggleKeyboardInput(_:)):
            menuItem.state = emulator.keyboardInputEnabled ? .on : .off
            return true
        case #selector(toggleHardwareKeyboard(_:)):
            menuItem.state = emulator.hardwareKeyboardConnected ? .on : .off
            return emulator.profile.canToggleHardwareKeyboard
        case #selector(deviceShutDown(_:)): return emulator.canShutDown
        case #selector(deviceForceStop(_:)): return emulator.canForceStop
        case #selector(deviceReset(_:)): return !emulator.isDead
        case #selector(toggleTouchOverlay(_:)):
            menuItem.title = deviceVC.screen.showsTouches ? "Hide Finger Dots" : "Show Finger Dots"
            return true
        case #selector(showLiveText(_:)):
            menuItem.title = deviceVC.screen.isShowingLiveText ? "Done Selecting Text" : "Select Text on Screen"
            return !recording.isActive && (deviceVC.screen.isShowingLiveText || canTakeScreenshot)
        case #selector(openScreenshot(_:)):
            menuItem.title = "Open Screenshot in \(capturePreferences.openInApplicationName)"
            return canTakeScreenshot
        case #selector(copy(_:)):
            return window?.firstResponder === deviceVC.screen && !deviceVC.screen.isShowingLiveText && canTakeScreenshot
        case #selector(saveScreenshot(_:)), #selector(saveScreenshotAs(_:)), #selector(copyScreen(_:)):
            return canTakeScreenshot
        case #selector(pasteToGuest(_:)):
            return emulator.acceptsInput && NSPasteboard.general.string(forType: .string) != nil
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(zoomPhysicalSize(_:)), #selector(zoomToFit(_:)),
            #selector(zoomPixelAccurate(_:)):
            return validateZoomItem(menuItem, screen: deviceVC.screen)
        default:
            return true
        }
    }
}
