// What the app derives from a board: HostRuntime's Board (the app's facts) and its DeviceInfo (the emulator's).
// Screen geometry, art, budgets and controls; nothing here lists boards.

import CoreGraphics
import Foundation
import HostRuntime

nonisolated extension Board {
    /// A requested stop's reason (the dead overlay, the session's phase); tests compare it.
    var stoppedReason: String { "The \(shortName) stopped." }

    /// How long a boot may take until lockdown answers (the app's "iOS is up")
    /// before the app gives up on it. The lock screen is normally there in 25 s
    /// (iPod) / 40 s (iPad) and lockdown ~40 s later; a first boot after an
    /// erase replays journals, rebuilds caches and re-enumerates USB for minutes.
    // ponytail: fixed per board family; make it per firmware in the catalog if 4.x first boots need more.
    var bootBudget: TimeInterval { (isKBoot ? 300 : 240) * Self.hostSlowdown }

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

    /// The image carries our guest shell and agent from preparation (Board.Facts.guestTools).
    var hasGuestTools: Bool { facts.guestTools }

    // MARK: - The emulator's controls (DeviceInfo)

    var hasCompass: Bool { hardware?.hasCompass ?? false }
    /// The USB keyboard can be unplugged and plugged back while running (qemu_ios_ui_hardware_keyboard).
    var canToggleHardwareKeyboard: Bool { hardware?.hasUSBHost ?? false }
    /// A cellular modem (the Carrier panel).
    var hasCellular: Bool { hardware?.hasCellular ?? false }
    /// Charging is the USB port's current (the machine's usb-charger), not the PMU's charger.
    var canChooseUSBCharger: Bool { hardware?.hasUSBCharger ?? false }

    enum OrientationSource {
        /// The guest agent's orientation op reports it; the host steps the
        /// accelerometer a quarter-turn at a time (ipod_touch_kbd_rotate).
        case guestHelper
        /// SpringBoard's getInterfaceOrientation over lockdown reports it; the
        /// host sets the accelerometer outright (LinkRequest.orientation).
        case springBoard
    }
    var orientationSource: OrientationSource { hasGuestTools ? .guestHelper : .springBoard }

    // MARK: - Screen

    /// Framebuffer pixels as the panel scans them out: the emulator's (DeviceInfo). 320x480 only until the
    /// emulator library has been listed (no library: nothing boots either).
    var screenPixels: CGSize { hardware?.screenPixels ?? CGSize(width: 320, height: 480) }

    /// Quarter-turn from the scanned-out panel to the upright (portrait, home
    /// button down) device, clockwise-positive in the view's y-down space. The
    /// iPod LCD pre-rotates its surface; the iPad's panel is landscape-native
    /// and portrait SpringBoard (interface orientation 1) arrives with its
    /// status bar along the panel's left edge, so it is turned a quarter
    /// clockwise to stand upright.
    var panelRotation: CGFloat { Self.guestTurn(scan: screenPixels) }

    /// The quarter-turn the guest gives its portrait UI on a panel of this scan size. UIKit decides it from the
    /// panel's shape, not the board: +[UIApplication _startWindowServerIfNecessary] (3.2 UIKit 0x3223f2fc) swaps
    /// the display's bounds and calls GSSetMainScreenInfo with orientation π/2 only when it is wider than tall,
    /// so a square or taller panel gets the UI as scanned (docs: qemu-ios-files ipad1/7B500 userland-gl-display
    /// §1.4). The host mirrors that one rule; it gives the shipped iPad π/2 and the iPods 0.
    static func guestTurn(scan: CGSize) -> CGFloat { scan.width > scan.height ? .pi / 2 : 0 }

    /// The CLCD boards' LCD model turns the picture it publishes with the device (ipod_touch_lcd.c); a
    /// landscape-mounted panel (the iPad's pipe) scans out as is and the guest turns its UI inside it.
    var surfaceFollowsRotation: Bool { (hardware?.defaultOrientation ?? 0) == 0 }

    /// The screen as it sits in the upright shell.
    var uprightScreenPixels: CGSize {
        let p = screenPixels
        return panelRotation == 0 ? p : CGSize(width: p.height, height: p.width)
    }

    // MARK: - Free-form screen (machine panel=WxH, issue #21)

    /// iPhone OS 1's SpringBoard keeps its icons and dock at 320x480 whatever the panel (its machines take panel=).
    var supportsFreeForm: Bool { soc != .s5l8900 }
    var freeFormUnavailableReason: String? {
        supportsFreeForm ? nil : "iPhone OS 1 keeps its Home screen at 320 × 480, whatever size the screen is."
    }

    /// The nearest size the board's panel= accepts (the emulator's limits, DeviceInfo, in the panel's scan
    /// orientation) to an upright screen size, in guest pixels: both sides at least panelMin, the width a multiple
    /// of panelWidthStep, and no more than panelMaxPixels (shrunk keeping the aspect). Upright it is never wider than
    /// tall: the guest's portrait is the panel's longer side (guestTurn), so a wider one would come back turned.
    func snappedPanel(upright size: CGSize) -> CGSize {
        let turned = panelRotation != 0
        let s = turned ? CGSize(width: size.height, height: size.width) : size
        let lo = CGFloat(hardware?.panelMin ?? 64), step = CGFloat(max(hardware?.panelWidthStep ?? 2, 1))
        let maxPixels = CGFloat(hardware?.panelMaxPixels ?? 0)
        func fit(_ v: CGFloat, _ hi: Int?) -> CGFloat { min(max(v.isFinite ? v.rounded() : lo, lo), CGFloat(hi ?? 1024)) }
        var w = fit(s.width, hardware?.panelMaxWidth), h = fit(s.height, hardware?.panelMaxHeight)
        if maxPixels > 0, w * h > maxPixels {
            let k = (maxPixels / (w * h)).squareRoot()
            w = max(lo, w * k); h = max(lo, h * k)
        }
        w = max(lo, (w / step).rounded(.down) * step)
        h = h.rounded(.down)
        if maxPixels > 0 { h = min(h, (maxPixels / w).rounded(.down)) }
        // Portrait no wider than tall: a landscape-mounted panel's upright width is its scan height, a portrait
        // one's its scan width (in the board's steps).
        if turned { h = min(h, w) } else { w = min(w, max(lo, (h / step).rounded(.down) * step)) }
        return turned ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// The scan of an upright size by the board's convention (the iPad's panel is mounted landscape), and the
    /// upright screen the guest makes of a scan (guestTurn: turned only when wider than tall).
    func scan(upright size: CGSize) -> CGSize { panelRotation != 0 ? CGSize(width: size.height, height: size.width) : size }
    static func upright(scan: CGSize) -> CGSize {
        guestTurn(scan: scan) != 0 ? CGSize(width: scan.height, height: scan.width) : scan
    }

    /// device.plist `panel` ("WxH" as the panel scans) for an upright guest size, and back.
    func panelOption(upright size: CGSize) -> String {
        let scan = scan(upright: size)
        return "\(Int(scan.width))x\(Int(scan.height))"
    }
    func uprightPanel(_ option: String?) -> CGSize? { Self.panelScan(option).map(Self.upright(scan:)) }
    static func panelScan(_ option: String?) -> CGSize? {
        guard let parts = option?.split(separator: "x"), parts.count == 2,
              let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return CGSize(width: w, height: h)
    }

    // MARK: - Device art (Board.Art: shell-native pixels, top-left origin)

    var shellImageName: String { facts.art.shell }
    var deviceModelName: String? { facts.art.model }
    var shellPixels: CGSize { facts.art.shellPixels }
    var screenCutout: CGRect { facts.art.screenCutout }
    var homeButtonDiameter: CGFloat { facts.art.homeDiameter }
    var homeButtonBottomInset: CGFloat { facts.art.homeBottomInset }
    var physicalHeightMillimeters: CGFloat { facts.art.heightMillimeters }
}
