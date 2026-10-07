import HostRuntime
// Which board an emulated device is.
//
// Each EmulatorController holds its own, from its device record's board.
// Screen geometry and art live in DeviceProfile+Display.swift; this file
// needs nothing else, so any source that only needs the name can use it.

import Foundation

nonisolated enum DeviceProfile: Equatable {
    case iPodTouch2G
    case iPad1
    /// The n45 (iPhone OS 1.x): qemu-ios `-M iPod-Touch-1G`, booted bootrom -> iBoot-204 from the base's iBoot.bin.
    case iPodTouch1G
    /// The n81 (iOS 4.2.1): qemu-ios `-M iPod-Touch-4G`, an A4 board on the iPad's machine, booted kboot.
    case iPodTouch4G
    /// The n90 (iOS 4.2.1): qemu-ios `-M iPhone-4`, the GSM iPhone 4 on the same A4 machine, booted kboot.
    case iPhone4
    /// The n88 (iOS 4.2.1): qemu-ios `-M n88`, the S5L8920 iPhone 3GS, prepared and booted (kboot) as the A4 boards are.
    case iPhone3GS
    /// The n18 (iOS 4.2.1): qemu-ios `-M n18`, the S5L8922 iPod touch 3G, the same way; the 2G's chassis, so the
    /// 2G's N72 model.
    case iPodTouch3G
    /// The m68 (the original iPhone, iPhone OS 1.0): qemu-ios `-M iPhone-2G`, the 1G's boot with iBoot-159.
    case iPhone2G

    /// The name passed to -M; also the key for the hello's device info.
    var machineName: String {
        switch self {
        case .iPad1: "ipad1"; case .iPodTouch2G: "iPod-Touch"; case .iPodTouch1G: "iPod-Touch-1G"; case .iPodTouch4G: "iPod-Touch-4G"
        case .iPhone4: "iPhone-4"; case .iPhone3GS: "n88"; case .iPodTouch3G: "n18"; case .iPhone2G: "iPhone-2G"
        }
    }
    var displayName: String { switch self { case .iPad1: "iPad"; case .iPhone4, .iPhone3GS, .iPhone2G: "iPhone"; default: "iPod touch" } }
    /// What the device is called in menus, titles and messages ("the iPod").
    var shortName: String { switch self { case .iPad1: "iPad"; case .iPhone4, .iPhone3GS, .iPhone2G: "iPhone"; default: "iPod" } }
    /// A requested stop's reason (the dead overlay, the session's phase); tests compare it.
    var stoppedReason: String { "The \(shortName) stopped." }

    var runtimeBoard: PreparedDeviceBoot.Board {
        switch self {
        case .iPad1: .k48; case .iPodTouch2G: .n72; case .iPodTouch1G: .n45; case .iPodTouch4G: .n81; case .iPhone4: .n90
        case .iPhone3GS: .n88; case .iPodTouch3G: .n18; case .iPhone2G: .m68
        }
    }
    var boardID: String { runtimeBoard.rawValue }
    /// The A4 boards (and the n18) share the iPad's machine options and boot (Wi-Fi netdev, no host audio, SpringBoard orientation).
    var isA4: Bool { runtimeBoard.isA4 }
    /// A prepared base's boot file and the other files its boots need besides nand/, by the lock's boot_strategy.
    /// The iPad's k48 iboot recipe (default) boots iBoot->kernel from iBoot.bin + nor.bin +
    /// gid-blobs.bin; the kboot recipe (and the two older prepared iPads) boots direct-kernel from kboot.bin.
    /// The iPod's n72 recipe boots the machine's direct-iBoot from iBoot.bin + nor.bin + gid-blobs.bin (3.x+, no
    /// boot_strategy or "iboot"), or with "bootrom" (2.x) the real SecureROM -> NOR LLB -> iBoot chain from nor.bin.
    /// The 1G's n45 recipe: iBoot.bin (the machine's `iboot=`) + nor.bin; no GID blobs (1.x's 8900 key is fixed).
    func preparedBoot(strategy: String?) throws -> (boot: String, files: [String]) {
        try runtimeBoard.requiredFiles(strategy: strategy)
    }
    var productType: String {
        switch self {
        case .iPad1: "iPad1,1"; case .iPodTouch2G: "iPod2,1"; case .iPodTouch1G: "iPod1,1"; case .iPodTouch4G: "iPod4,1"; case .iPhone4: "iPhone3,1"
        case .iPhone3GS: "iPhone2,1"; case .iPodTouch3G: "iPod3,1"; case .iPhone2G: "iPhone1,1"
        }
    }
    var marketingName: String {
        switch self {
        case .iPad1: "iPad"; case .iPodTouch2G: "iPod touch (2nd generation)"; case .iPodTouch1G: "iPod touch"
        case .iPodTouch4G: "iPod touch (4th generation)"; case .iPhone4: "iPhone 4"; case .iPhone3GS: "iPhone 3GS"
        case .iPodTouch3G: "iPod touch (3rd generation)"; case .iPhone2G: "iPhone"
        }
    }
    /// The SecureROM image the machine boots, looked up under Bundled.filesRoot (DeviceProfile.bootrom).
    var bootromName: String { self == .iPodTouch1G || self == .iPhone2G ? "bootrom_s5l8900" : "bootrom_240_4" }

    /// How long a boot may take until lockdown answers (the app's "iOS is up")
    /// before the app gives up on it. The lock screen is normally there in 25 s
    /// (iPod) / 40 s (iPad) and lockdown ~40 s later; a first boot after an
    /// erase replays journals, rebuilds caches and re-enumerates USB for minutes.
    // ponytail: fixed per board; make it per firmware in the catalog if 4.x first boots need more.
    var bootBudget: TimeInterval { (isA4 ? 300 : 240) * Self.hostSlowdown }

    /// Emulation on an Intel Mac (this app's x86_64 slice, native or under Rosetta) takes several times the
    /// CPU time of Apple silicon for the same boot. 2026-09-30, iPod 3.1.3 to its Home screen: 28–34 s of
    /// CPU on an M4 Max, 124 s for the x86_64 slice under Rosetta on it, 122–309 s to the first lit frame on
    /// a 2018 Intel MacBook Pro. The boot's wall-clock budgets scale by it, or an Intel Mac's boot is
    /// stopped while it's still starting.
    #if arch(x86_64)
    static let hostSlowdown: TimeInterval = 5
    #else
    static let hostSlowdown: TimeInterval = 1
    #endif

    /// The iPod image carries our guest shell and agent; the stock iPad has none, nor has 1.x (smoke.md #31).
    var hasGuestTools: Bool { self == .iPodTouch2G }
    var hasCompass: Bool { self == .iPad1 }
    /// Boards whose USB keyboard can be unplugged and plugged back while running (qemu_ios_ui_hardware_keyboard);
    /// the others keep the one they booted with (or have none: the n18 and n88).
    var canToggleHardwareKeyboard: Bool { self == .iPad1 || self == .iPodTouch4G || self == .iPhone4 }
    /// A cellular modem (the Carrier panel): the original iPhone, the 3GS and the iPhone 4.
    var hasCellular: Bool { self == .iPhone2G || self == .iPhone3GS || self == .iPhone4 }
    /// Whether the board's charging is its USB port's current (the iPad's usb-charger), not the PMU's charger.
    var canChooseUSBCharger: Bool { self == .iPad1 }

    enum OrientationSource {
        /// The guest agent's orientation op reports it; the host steps the
        /// accelerometer a quarter-turn at a time (ipod_touch_kbd_rotate).
        case guestHelper
        /// SpringBoard's getInterfaceOrientation over lockdown reports it; the
        /// host sets the accelerometer outright (LinkRequest.orientation).
        case springBoard
    }
    var orientationSource: OrientationSource { self == .iPodTouch2G ? .guestHelper : .springBoard }
}
