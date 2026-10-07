// Screen geometry and device art.

import CoreGraphics

nonisolated extension DeviceProfile {
    /// Framebuffer pixels as the panel scans them out. Constants, so geometry
    /// doesn't need the dylib; DeviceProcess logs if the device info in the
    /// helper's hello disagrees.
    var screenPixels: CGSize {
        switch self {
        case .iPodTouch2G, .iPodTouch1G, .iPhone3GS, .iPodTouch3G, .iPhone2G: CGSize(width: 320, height: 480)
        case .iPad1: CGSize(width: 1024, height: 768)
        case .iPodTouch4G, .iPhone4: CGSize(width: 640, height: 960)
        }
    }

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

    /// The iPod LCD model turns the picture it publishes with the device (ipod_touch_lcd.c); the iPad's pipe
    /// scans out as is and the guest turns its UI inside it.
    var surfaceFollowsRotation: Bool { self != .iPad1 }

    /// The screen as it sits in the upright shell.
    var uprightScreenPixels: CGSize {
        let p = screenPixels
        return panelRotation == 0 ? p : CGSize(width: p.height, height: p.width)
    }

    // MARK: - Free-form screen (machine panel=WxH, issue #21)

    /// Boards whose guest lays out for a panel of another size and whose panel= limits snappedPanel knows (qemu-ios
    /// w05's table). The 1G's and the iPhone's machines take panel= too, but iPhone OS 1's SpringBoard keeps its icons
    /// and dock at 320x480.
    var supportsFreeForm: Bool { self != .iPodTouch1G && self != .iPhone2G }
    var freeFormUnavailableReason: String? {
        supportsFreeForm ? nil : "iPhone OS 1 keeps its Home screen at 320 × 480, whatever size the screen is."
    }

    /// The A4 boards' display pipe (ipad1.c's machine: iPad, iPod touch 4G, iPhone 4); the others have the
    /// S5L8720-style CLCD (iPod touch 2G and 3G, iPhone 3GS).
    var hasA4Panel: Bool { self == .iPad1 || self == .iPodTouch4G || self == .iPhone4 }

    /// iBoot's display region, 0x4f700000 up to the iPad's DRAM end: 9 MB at 4 bytes a pixel. Every A4 board
    /// scans out from that base, so the iPad's bound holds for the iPhone 4 and iPod touch 4G too.
    static let a4PanelPixels: CGFloat = 0x900000 / 4

    /// The nearest size the board's panel= accepts to an upright screen size, in guest pixels. qemu-ios's
    /// limits, in the panel's scan orientation: the CLCD boards' even width 64…1024 by 64…511 rows (the window
    /// keeps 9 bits of height); the A4 boards' width a multiple of 16, both sides 64…2047, and no more pixels than
    /// iBoot's display region holds (shrunk keeping the aspect). Upright it is never wider than tall: the guest's
    /// portrait is the panel's longer side (guestTurn), so a wider one would come back turned.
    func snappedPanel(upright size: CGSize) -> CGSize {
        let turned = panelRotation != 0
        let s = turned ? CGSize(width: size.height, height: size.width) : size
        let a4 = hasA4Panel
        func fit(_ v: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v.isFinite ? v.rounded() : 64, 64), hi) }
        var w = fit(s.width, a4 ? 2047 : 1024), h = fit(s.height, a4 ? 2047 : 511)
        if a4, w * h > Self.a4PanelPixels {
            let k = (Self.a4PanelPixels / (w * h)).squareRoot()
            w = max(64, w * k); h = max(64, h * k)
        }
        let step: CGFloat = a4 ? 16 : 2
        w = max(64, (w / step).rounded(.down) * step)
        h = h.rounded(.down)
        if a4 { h = min(h, (Self.a4PanelPixels / w).rounded(.down)) }
        // Portrait no wider than tall: a landscape-mounted panel's upright width is its scan height, a portrait
        // one's its scan width (in the board's steps).
        if turned { h = min(h, w) } else { w = min(w, max(64, (h / step).rounded(.down) * step)) }
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

    // MARK: - Device art (shell-native pixels, top-left origin)

    /// Each iPod, the iPad and the 3GS has a 3D model (<name>.usdz, revision 7 for K48, N45 and N81).
    /// The flat art is the prepare screen's picture and the fallback while the
    /// model loads or where RealityKit can't: the 2G has shell.png (a product
    /// photo), the 1G shell-1g.png (its N45 model rendered face-on, screen off,
    /// by scripts/render-shell-art.py, which prints the numbers below; the 4G's shell-4g.png the same way
    /// from N81; the 3G shows the 2G's photo, the chassis they share), and the
    /// iPad borrows the iPad chrome from the iPhone Simulator in Xcode 3.2.4
    /// (iPad.deviceinfo: portrait.png, 852x1108, with the 768x1024 screen centred in it). The two iPhones without a
    /// model take theirs from the Simulator too: the iPhone 4 Xcode 4.6.3's "iPhone (Retina 3.5-inch)" chrome
    /// (chrome_halfsize@2x.png, 730x1426 cropped, the 640x960 screen at 48,236, its hole filled with the LCD's tone),
    /// the iPhone 2G iPhone SDK 3.1.3's frame.png (383x729 cropped, the 320x480 screen at 33,130), which the 3GS
    /// shows too (Sam, 10-06).
    var shellImageName: String {
        switch self {
        case .iPodTouch2G, .iPodTouch3G: "shell"; case .iPad1: "ipad-frame"; case .iPodTouch1G: "shell-1g"; case .iPodTouch4G: "shell-4g"
        case .iPhone4: "shell-iphone4"; case .iPhone2G, .iPhone3GS: "shell-iphone2g"
        }
    }
    /// The bundled LightTouchMac/<name>.usdz (multidevice 98eac7c). The iPhone 2G and iPhone 4 have none: they show
    /// their 2D shell (or no bezel).
    var deviceModelName: String? {
        switch self {
        case .iPodTouch2G, .iPodTouch3G: "N72"; case .iPad1: "K48"; case .iPodTouch1G: "N45"; case .iPodTouch4G: "N81"
        case .iPhone3GS: "N88"; case .iPhone2G, .iPhone4: nil
        }
    }

    var shellPixels: CGSize {
        switch self {
        case .iPodTouch2G, .iPodTouch3G: CGSize(width: 737, height: 1318)
        case .iPodTouch1G: CGSize(width: 734, height: 1311)
        case .iPhone2G, .iPhone3GS: CGSize(width: 383, height: 729)
        case .iPad1: CGSize(width: 852, height: 1108)
        case .iPodTouch4G: CGSize(width: 696, height: 1310)   // scripts/render-shell-art.py N81
        case .iPhone4: CGSize(width: 730, height: 1426)
        }
    }

    var screenCutout: CGRect {
        switch self {
        case .iPodTouch2G, .iPodTouch3G: CGRect(x: 74, y: 213, width: 594, height: 891)
        case .iPodTouch1G: CGRect(x: 70, y: 211, width: 594, height: 891)
        case .iPhone2G, .iPhone3GS: CGRect(x: 33, y: 130, width: 320, height: 480)
        // (852 - 768) / 2 and (1108 - 1024) / 2: the Simulator centres its screen.
        case .iPad1: CGRect(x: 42, y: 42, width: 768, height: 1024)
        case .iPodTouch4G: CGRect(x: 54, y: 213, width: 590, height: 886)
        case .iPhone4: CGRect(x: 48, y: 236, width: 640, height: 960)
        }
    }

    /// The Home button's hit circle: diameter, and its gap to the shell's
    /// bottom edge. The iPad's comes from iPad.deviceinfo's homeOriginX/Y
    /// (412, 9, bottom-left origin) and its 29x31 home.png.
    var homeButtonDiameter: CGFloat {
        switch self {
        case .iPodTouch2G, .iPodTouch3G: 122; case .iPad1: 31; case .iPodTouch1G: 112; case .iPhone2G, .iPhone3GS: 70; case .iPodTouch4G: 119
        case .iPhone4: 140
        }
    }
    var homeButtonBottomInset: CGFloat {
        switch self {
        case .iPodTouch2G, .iPodTouch3G: 54; case .iPad1: 9; case .iPodTouch1G: 59; case .iPhone2G, .iPhone3GS: 34; case .iPodTouch4G: 49
        case .iPhone4: 52
        }
    }

    /// Height of the real device, for Actual Size zoom.
    var physicalHeightMillimeters: CGFloat {
        switch self { case .iPad1: 242.8; case .iPodTouch4G: 111; case .iPhone4: 115.2; case .iPhone3GS: 115.5; case .iPhone2G: 115
        case .iPodTouch2G, .iPodTouch1G, .iPodTouch3G: 110 }
    }
}
