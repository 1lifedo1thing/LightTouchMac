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
    var panelRotation: CGFloat { self == .iPad1 ? .pi / 2 : 0 }

    /// The screen as it sits in the upright shell.
    var uprightScreenPixels: CGSize {
        let p = screenPixels
        return panelRotation == 0 ? p : CGSize(width: p.height, height: p.width)
    }

    // MARK: - Free-form screen (machine panel=WxH, issue #21)

    /// Boards whose machine takes panel=WxH (the iPod touch 1G's doesn't).
    var supportsFreeForm: Bool { self != .iPodTouch1G }

    /// iBoot's iPad display region, 0x4f700000 up to DRAM's end: 9 MB at 4 bytes a pixel.
    static let iPadPanelPixels: CGFloat = 0x900000 / 4

    /// The nearest size the board's panel= accepts to an upright screen size, in guest pixels. qemu-ios's
    /// limits, in the panel's scan orientation: the iPod's even width 64…1024 by 64…511 rows (the S5L8720
    /// window keeps 9 bits of height); the iPad's landscape width a multiple of 16, both sides 64…2047, and no
    /// more pixels than iBoot's display region holds (shrunk keeping the aspect).
    func snappedPanel(upright size: CGSize) -> CGSize {
        let turned = panelRotation != 0
        let s = turned ? CGSize(width: size.height, height: size.width) : size
        let pad = self == .iPad1
        func fit(_ v: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v.isFinite ? v.rounded() : 64, 64), hi) }
        var w = fit(s.width, pad ? 2047 : 1024), h = fit(s.height, pad ? 2047 : 511)
        if pad, w * h > Self.iPadPanelPixels {
            let k = (Self.iPadPanelPixels / (w * h)).squareRoot()
            w = max(64, w * k); h = max(64, h * k)
        }
        let step: CGFloat = pad ? 16 : 2
        w = max(64, (w / step).rounded(.down) * step)
        h = h.rounded(.down)
        if pad { h = min(h, (Self.iPadPanelPixels / w).rounded(.down)) }
        return turned ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// device.json `panel` ("WxH" as the panel scans) for an upright guest size, and back.
    func panelOption(upright size: CGSize) -> String {
        let scan = panelRotation != 0 ? CGSize(width: size.height, height: size.width) : size
        return "\(Int(scan.width))x\(Int(scan.height))"
    }
    func uprightPanel(_ option: String?) -> CGSize? {
        guard let parts = option?.split(separator: "x"), parts.count == 2,
              let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return panelRotation != 0 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    // MARK: - Device art (shell-native pixels, top-left origin)

    /// Each board has a 3D model (<name>.usdz, revision 7 for K48, N45 and N81).
    /// The flat art is the prepare screen's picture and the fallback while the
    /// model loads or where RealityKit can't: the 2G has shell.png (a product
    /// photo), the 1G shell-1g.png (its N45 model rendered face-on, screen off,
    /// by scripts/render-shell-art.py, which prints the numbers below; the 4G's shell-4g.png the same way
    /// from N81, the 3G's shell-3g.png from N72, the chassis it shares with the 2G), and the
    /// iPad borrows the iPad chrome from the iPhone Simulator in Xcode 3.2.4
    /// (iPad.deviceinfo: portrait.png, 852x1108, with the 768x1024 screen centred in it).
    var shellImageName: String {
        // ponytail: the iPhone 2G's is the 1G's art with its earpiece slot added (same geometry); a real picture replaces it.
        switch self {
        case .iPodTouch2G: "shell"; case .iPad1: "ipad-frame"; case .iPodTouch1G: "shell-1g"; case .iPodTouch4G: "shell-4g"
        case .iPodTouch3G: "shell-3g"
        case .iPhone4: "shell-iphone4"; case .iPhone3GS: "shell-iphone3gs"; case .iPhone2G: "shell-iphone2g"
        }
    }
    /// The bundled LightTouchMac/<name>.usdz (multidevice 98eac7c). The iPhone has none yet: it shows its 2D shell
    /// until an M68.usdz is bundled and named here.
    var deviceModelName: String? {
        switch self {
        case .iPodTouch2G, .iPodTouch3G: "N72"; case .iPad1: "K48"; case .iPodTouch1G: "N45"; case .iPodTouch4G: "N81"; case .iPhone4: "N90"
        case .iPhone3GS: "N88"; case .iPhone2G: nil
        }
    }

    var shellPixels: CGSize {
        switch self {
        case .iPodTouch2G: CGSize(width: 737, height: 1318)
        case .iPodTouch3G: CGSize(width: 736, height: 1318)   // scripts/render-shell-art.py N72 (the 2G's chassis)
        case .iPodTouch1G, .iPhone2G: CGSize(width: 734, height: 1311)
        case .iPad1: CGSize(width: 852, height: 1108)
        case .iPodTouch4G: CGSize(width: 696, height: 1310)   // scripts/render-shell-art.py N81
        case .iPhone4: CGSize(width: 697, height: 1362)       // scripts/render-shell-art.py N90
        case .iPhone3GS: CGSize(width: 731, height: 1360)     // scripts/render-shell-art.py N88
        }
    }

    var screenCutout: CGRect {
        switch self {
        case .iPodTouch2G: CGRect(x: 74, y: 213, width: 594, height: 891)
        case .iPodTouch3G: CGRect(x: 72, y: 214, width: 594, height: 892)
        case .iPodTouch1G, .iPhone2G: CGRect(x: 70, y: 211, width: 594, height: 891)
        // (852 - 768) / 2 and (1108 - 1024) / 2: the Simulator centres its screen.
        case .iPad1: CGRect(x: 42, y: 42, width: 768, height: 1024)
        case .iPodTouch4G: CGRect(x: 54, y: 213, width: 590, height: 886)
        case .iPhone4: CGRect(x: 57, y: 240, width: 590, height: 885)
        case .iPhone3GS: CGRect(x: 71, y: 240, width: 590, height: 885)
        }
    }

    /// The Home button's hit circle: diameter, and its gap to the shell's
    /// bottom edge. The iPad's comes from iPad.deviceinfo's homeOriginX/Y
    /// (412, 9, bottom-left origin) and its 29x31 home.png.
    var homeButtonDiameter: CGFloat {
        switch self {
        case .iPodTouch2G: 122; case .iPodTouch3G: 117; case .iPad1: 31; case .iPodTouch1G, .iPhone2G: 112; case .iPodTouch4G: 119; case .iPhone4: 131
        case .iPhone3GS: 131
        }
    }
    var homeButtonBottomInset: CGFloat {
        switch self {
        case .iPodTouch2G: 54; case .iPodTouch3G: 55; case .iPad1: 9; case .iPodTouch1G, .iPhone2G: 59; case .iPodTouch4G: 49; case .iPhone4: 56
        case .iPhone3GS: 64
        }
    }

    /// Height of the real device, for Actual Size zoom. The iPhone 2G (115 mm) wears the 1G's art, so it takes the
    /// 1G's height: its screen, the same 3.5", stays true to size.
    var physicalHeightMillimeters: CGFloat {
        switch self { case .iPad1: 242.8; case .iPodTouch4G: 111; case .iPhone4: 115.2; case .iPhone3GS: 115.5; case .iPodTouch2G, .iPodTouch1G, .iPodTouch3G, .iPhone2G: 110 }
    }
}
