// The session's settings that reach the machine: the keyboard (passthrough and Connect Hardware Keyboard) and
// the battery menu. The emulator can't be asked for these, so what the app last set is the menu's state, and
// every boot starts from it.

import Foundation
import HostRuntime
import DeviceRuntime

/// A control request for the running boot: `done(true)` when the machine applied it (BootSessionScope.control).
public typealias MachineControl = (LinkRequest, @escaping (Bool) -> Void) -> Void

/// Keyboard passthrough (per device, on by default) and Connect Hardware Keyboard (⇧⌘K, per device). Both are
/// settings, so observable through the settings file.
public final class KeyboardInput {
    private let settings: DeviceSettingsFile
    private let canToggleHardwareKeyboard: Bool
    private let control: MachineControl
    private let send: (LinkCommand) -> Void
    /// The guest takes key presses now: running, accepting input, display awake.
    private let canPress: () -> Bool

    public init(settings: DeviceSettingsFile, canToggleHardwareKeyboard: Bool, control: @escaping MachineControl,
                send: @escaping (LinkCommand) -> Void, canPress: @escaping () -> Bool) {
        self.settings = settings
        self.canToggleHardwareKeyboard = canToggleHardwareKeyboard
        self.control = control
        self.send = send
        self.canPress = canPress
    }

    /// Forward host keys by macOS virtual keycode; the shim maps them to QKeyCodes exactly as ui/cocoa.m does.
    public var enabled: Bool { settings.value.keyboardInputEnabled ?? true }
    public func toggleEnabled() {
        let enabled = !enabled
        settings.change { $0.keyboardInputEnabled = enabled }
    }

    /// Unplugged, iOS shows its on-screen keyboard in a text field.
    public var hardwareConnected: Bool { settings.value.hardwareKeyboard ?? true }
    public func toggleHardware() {
        let connected = !hardwareConnected
        settings.change { $0.hardwareKeyboard = connected }
        applyHardware(changed: true)
    }

    /// Each boot starts with the keyboard plugged in (BootRecipe's usb-kbd): unplug it when it's off.
    public func applyHardware(changed: Bool = false) {
        guard canToggleHardwareKeyboard, changed || !hardwareConnected else { return }
        let connected = hardwareConnected
        control(.hardwareKeyboard(connected)) { ok in
            if !ok { logEvent("keyboard: couldn’t \(connected ? "connect" : "disconnect") the hardware keyboard") }
        }
    }

    /// A press only while the guest takes input; a release always, so no key is left down.
    public func sendKey(macKeyCode: UInt16, down: Bool) {
        guard !down || (enabled && canPress()) else { return }
        send(.key(macKeyCode: Int(macKeyCode), down: down))
    }
}

/// The Battery menu: the level and whether the USB port charges the device (off, USB data stays connected).
/// The iPad's port then grants no charge current (a 500 mA port): "Not Charging", and the lock screen keeps its
/// wallpaper. The iPod reads not charging but, as on hardware, shows its battery while on USB.
public final class BatteryControls {
    public private(set) var level = 100
    public private(set) var charging = true
    private let canChooseUSBCharger: Bool
    private let scope: BootSessionScope
    private let control: MachineControl
    /// How long the port stays unplugged so the guest re-reads its current.
    var replugDelay: Duration = .seconds(1)

    public init(canChooseUSBCharger: Bool, scope: BootSessionScope, control: @escaping MachineControl) {
        self.canChooseUSBCharger = canChooseUSBCharger
        self.scope = scope
        self.control = control
    }

    public func setLevel(_ level: Int) {
        self.level = level
        control(.battery(level: level, charging: chargingMode)) { _ in }
    }

    /// The machine's battery-charging: auto (charge until full) or off.
    private var chargingMode: Int { charging ? 0 : 2 }

    /// At a boot's first frame, before configd reads the gauge and the guest enumerates USB, so neither needs a replug.
    public func apply() {
        control(.battery(level: level, charging: chargingMode)) { _ in }
        if canChooseUSBCharger { control(.usbCharger(charging)) { _ in } }
    }

    public func setCharging(_ on: Bool) {
        charging = on
        guard canChooseUSBCharger else { return control(.battery(level: level, charging: chargingMode)) { _ in } }
        control(.usbCharger(on)) { [weak self] applied in
            guard applied, let self else { return }
            // The port's current is read at enumeration: replug so the guest asks again.
            control(.usbConnection(false)) { [weak self] unplugged in
                guard unplugged, let self else { return }
                let delay = replugDelay
                scope[.usbReconnect] = Task { [weak self] in
                    do { try await Task.sleep(for: delay) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.control(.usbConnection(true)) { _ in }
                }
            }
        }
    }
}
