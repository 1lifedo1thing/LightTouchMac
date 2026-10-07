import LightTouchCore
import HostRuntime
import DeviceRuntime
// Device shell and LCD share a transform. Fit uses the pane bounds; manual
// zoom uses display pixels per guest pixel, independent of orientation.

import Cocoa

/// Fit the whole device in the window, or use an integer display-pixel scale.
final class DisplayView: NSView {

    /// The device this view shows, fixed at init.
    private let profile: Board
    /// The panel at rest — iPod touch 2G: 320×480 at 163 ppi (3.5" panel).
    /// The live frame buffer swaps its sides on rotation.
    private var nativeScreenPixels: CGSize

    /// The shell art: its full pixel size, the screen cutout rect within
    /// it (top-left origin, matching this view's isFlipped space), and the
    /// home button circle — all in the shell image's own native (portrait,
    /// unrotated) pixel space.
    private let shellPixels: CGSize
    private var screenCutout: CGRect
    private let homeButtonDiameter: CGFloat
    private let homeButtonBottomInset: CGFloat

    /// Whatever the guest is actually sending right now — swaps on rotation.
    private var framePixels: CGSize
    /// nil until the first layout, so the initial appearance never "rotates in".
    private var lastRotation: Int?

    /// Set by the owner so key/drop events can reach the guest.
    weak var emulator: EmulatorController?
    /// Called when an .ipa is dropped on the screen.
    var onDropIPA: ((URL) -> Void)?
    /// An IPSW from outside: the library's, whatever this device is doing.
    var onDropIPSW: ((URL) -> Void)?
    var onDropMedia: ((URL) -> Void)?
    /// Called when a Legacy Store row is dropped on the screen.
    var onDropCatalogApp: ((CatalogApp) -> Void)?

    /// Points of breathing room between the shell and the pane edge when
    /// zoomed. A flat inset, not a fraction of the pane: 0.85 of the pane threw
    /// away 15% of a 1400-point window — over 200 points of black — to leave the
    /// same visual margin an 8-point gap gives.
    ///
    /// Wide enough that the shell's shadow has somewhere to fall.
    static let zoomInset: CGFloat = 16
    /// How long the shell + screen take to swing between portrait and landscape.
    private static let rotationDuration = 0.4

    private var deviceLayoutRect: CGRect { safeAreaRect }
    var zoom: ZoomMode = .fit {
        didSet {
            guard oldValue != zoom else { return }
            // A finished edge drag waiting to be recorded keeps no scale of its own: the new zoom draws it.
            if panelDrag == nil, !restartingAtPanel { dragScale = nil }
            pendingAnimatedLayout = true
            needsLayout = true
        }
    }
    /// Set by the scaleMode toggle so the next layout animates even though
    /// orientation didn't change — mirrors how orientationChanged drives it.
    private var pendingAnimatedLayout = false

    private enum PowerPresentation: Equatable { case awake, sleeping, poweredOff, shuttingDown }
    private var powerPresentation: PowerPresentation = .awake
    private var powerBadge: NSStackView?
    var isCapturingCanvas = false { didSet { powerBadge?.isHidden = isCapturingCanvas } }

    func updatePowerPresentation() {
        guard let emulator else { return }
        let next: PowerPresentation = restartingAtPanel ? .awake : emulator.isPoweredOff ? .poweredOff
            : emulator.shuttingDown ? .shuttingDown : (emulator.isSleeping && !emulator.preparingDevice && !isShowingLiveText) ? .sleeping : .awake
        guard next != powerPresentation else { return }
        powerPresentation = next
        powerBadge?.removeFromSuperview()
        powerBadge = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.3)
        shellLayer.opacity = next == .awake ? 1 : next == .sleeping ? 0.45 : 0.25
        contentLayer.isHidden = next == .poweredOff
        modelView?.alphaValue = CGFloat(shellLayer.opacity)
        modelView?.setScreenOff(next != .awake)
        CATransaction.commit()
        guard next != .awake else {
            setAccessibilityValue("Device awake")
            return
        }
        let symbol: NSView
        if next == .sleeping {
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 160, height: 128))
            let sleeping = SleepingAnimationView()
            sleeping.frame = container.bounds
            sleeping.autoresizingMask = [.width, .height]
            container.addSubview(sleeping)
            container.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                container.widthAnchor.constraint(equalToConstant: 160),
                container.heightAnchor.constraint(equalToConstant: 128)
            ])
            symbol = container
        } else {
            let power = NSTextField(labelWithString: "⏻")
            power.font = .systemFont(ofSize: 30, weight: .light)
            power.textColor = .white
            symbol = power
        }
        let title = next == .sleeping ? "Sleeping" : next == .poweredOff ? "Powered off" : "Stopping…"
        let stack = NSStackView(views: [symbol])
        if next == .shuttingDown {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 15, weight: .medium)
            label.textColor = .white
            stack.addArrangedSubview(label)
        }
        stack.appearance = NSAppearance(named: .darkAqua)
        stack.orientation = .vertical
        stack.spacing = 10
        if next != .shuttingDown {
            let button = NSButton(title: next == .poweredOff ? "Start" : "Wake", target: self, action: #selector(wakeDevice(_:)))
            button.bezelStyle = .rounded
            stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor)
        ])
        powerBadge = stack
        stack.isHidden = isCapturingCanvas
        setAccessibilityValue(title)
    }

    @objc private func wakeDevice(_ sender: Any?) {
        guard let emulator else { return }
        if emulator.isPoweredOff { emulator.powerOn() } else { emulator.pressLock() }
    }

    /// View ▸ Device Bezels, app-wide: 3D (the model), 2D (the flat shell art, no RealityKit at all), or Off — the
    /// screen alone, where input, rotation and zoom work as they do inside the device.
    enum Bezel: Int { case model, flat, off }
    static let bezelKey = "deviceBezel"
    /// The earlier on/off preference; off carries over as `.off`.
    static let showsBezelKey = "showsDeviceBezel"
    static let bezelDidChange = Notification.Name("DisplayViewBezelDidChange")
    static var bezel: Bezel {
        get {
            let defaults = UserDefaults.standard
            if let raw = defaults.object(forKey: bezelKey) as? Int, let bezel = Bezel(rawValue: raw) { return bezel }
            return defaults.object(forKey: showsBezelKey) as? Bool == false ? .off : .model
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: bezelKey)
            NotificationCenter.default.post(name: bezelDidChange, object: nil)
        }
    }
    private var bare = false
    private var appliedBezel: Bezel?

    private var modelView: DeviceModelView?
    private var pendingModelView: DeviceModelView?
    private var modelLoadTask: Task<Void, Never>?
    private var modelFallbackTask: Task<Void, Never>?
    private var modelPresentationFinished = false
    private var lastShakeGeneration: UInt64 = 0
    private let contentLayer = CALayer()
    private let shellLayer = CALayer()
    private let homeButton = HomeButton()
    private let attitudeIndicator = AttitudeIndicatorButton(frame: .zero)
    private var displayLink: CADisplayLink?
    /// The ring serial on screen, and its surface (captures read it).
    private var shownSerial: UInt64 = 0
    private var shownSurface: IOSurface?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var touchPair = MouseTouchPair()
    /// Simulator-style rings where the two fingers of an Option drag land.
    private let pairRings = [CAShapeLayer(), CAShapeLayer()]

    init(frame: NSRect, profile: Board) {
        self.profile = profile
        nativeScreenPixels = profile.uprightScreenPixels
        framePixels = nativeScreenPixels
        shellPixels = profile.shellPixels
        screenCutout = profile.screenCutout
        homeButtonDiameter = profile.homeButtonDiameter
        homeButtonBottomInset = profile.homeButtonBottomInset
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        shellLayer.contentsGravity = .resize
        // The shell stays at its native pixel size forever; layout() scales and
        // rotates it with a single transform. The content layer lives INSIDE it
        // at the cutout, so scale and rotation can never drift apart — they are
        // one matrix.
        shellLayer.bounds = CGRect(origin: .zero, size: shellPixels)
        // Enough of a shadow to lift the device off the gradient, not enough to
        // notice as an effect. The radius is in the shell's own native pixels,
        // so the transform scales it with the device and the shadow stays
        // proportionate at every window size.
        //
        // Ambient — no offset — on purpose: the shadow belongs to the shell
        // layer, so it rides the same transform, and any offset that fell
        // downwards in portrait would fall sideways once the shell rotates.
        //
        // ponytail: no shadowPath, so Core Animation derives the shape from the
        // artwork's alpha — correct for a rounded, bevelled device by
        // construction. The layer's contents never change, so it renders once;
        // give it a rounded-rect path if it ever shows up in a profile.
        shellLayer.shadowColor = NSColor.black.cgColor
        shellLayer.shadowOpacity = 0.4
        shellLayer.shadowRadius = 40
        shellLayer.shadowOffset = .zero
        layer?.addSublayer(shellLayer)
        touchOverlayLayer.zPosition = 50
        touchOverlayLayer.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        layer?.addSublayer(touchOverlayLayer)
        keyboardPointerLayer.zPosition = 51
        keyboardPointerLayer.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        keyboardPointerLayer.path = CGPath(ellipseIn: CGRect(x: 2, y: 2, width: 14, height: 14), transform: nil)
        keyboardPointerLayer.fillColor = NSColor.black.withAlphaComponent(0.25).cgColor
        keyboardPointerLayer.strokeColor = NSColor.white.cgColor
        keyboardPointerLayer.lineWidth = 2
        keyboardPointerLayer.shadowColor = NSColor.black.cgColor
        keyboardPointerLayer.shadowOpacity = 1
        keyboardPointerLayer.shadowRadius = 1
        keyboardPointerLayer.shadowOffset = .zero
        keyboardPointerLayer.isHidden = true
        layer?.addSublayer(keyboardPointerLayer)
        for ring in pairRings {
            ring.zPosition = 52
            ring.actions = ["position": NSNull(), "hidden": NSNull()]
            ring.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
            ring.fillColor = NSColor(white: 0.5, alpha: 0.35).cgColor
            ring.strokeColor = NSColor(white: 0.25, alpha: 0.6).cgColor
            ring.isHidden = true
            layer?.addSublayer(ring)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))

        contentLayer.magnificationFilter = .nearest   // until a layout picks by scale (contentsFilter)
        // The shell is opaque, so the LCD draws on top of it. Black backing
        // shows a powered-on device screen during boot, before the first frame.
        contentLayer.contentsGravity = .resize
        contentLayer.backgroundColor = NSColor.black.cgColor
        contentLayer.position = CGPoint(x: screenCutout.midX, y: screenCutout.midY)
        shellLayer.addSublayer(contentLayer)

        homeButton.target = self
        homeButton.action = #selector(homeTapped)
        addSubview(homeButton)
        applyBezel(Self.bezel)
        NotificationCenter.default.addObserver(self, selector: #selector(bezelPreferenceChanged), name: Self.bezelDidChange, object: nil)
        attitudeIndicator.target = self
        attitudeIndicator.action = #selector(levelAttitude(_:))
        attitudeIndicator.isHidden = true
        attitudeIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(attitudeIndicator)
        NSLayoutConstraint.activate([
            attitudeIndicator.widthAnchor.constraint(equalToConstant: 40),
            attitudeIndicator.heightAnchor.constraint(equalToConstant: 40),
            attitudeIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            attitudeIndicator.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        ])

        registerForDraggedTypes([.fileURL, .ltmCatalogApp])
        setAccessibilityLabel("\(profile.displayName) screen")
        setAccessibilityRole(.group)
        setAccessibilityCustomActions(Self.screenActions.map { title, action in
            NSAccessibilityCustomAction(name: title) { [weak self] in NSApp.sendAction(action, to: nil, from: self) }
        })
        setAccessibilityHelp("Turn off Send Keyboard Input (Device > Input) to move a pointer with the arrow keys. Hold Space to touch; Shift-arrow drags.")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func bezelPreferenceChanged() { applyBezel(freeFormActive ? .off : Self.bezel) }

    /// The device around the screen, its flat art, or the screen alone. Flat and bare drop the model (and its
    /// load); bare also empties the shell layer, which stays as the screen's transform: rotation, zoom and touch
    /// mapping are unchanged.
    private func applyBezel(_ bezel: Bezel) {
        guard bezel != appliedBezel else { return }
        appliedBezel = bezel
        bare = bezel == .off
        modelLoadTask?.cancel()
        modelFallbackTask?.cancel()
        modelLoadTask = nil
        for model in [modelView, pendingModelView] { model?.removeFromSuperview() }
        modelView = nil
        pendingModelView = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shellLayer.removeAnimation(forKey: "modelPresentation")
        shellLayer.contents = bare ? nil : NSImage(named: profile.shellImageName)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        shellLayer.shadowOpacity = bare ? 0 : 0.4
        // Bare, the transform turns and scales about the screen's centre, which layout() puts at the pane's.
        shellLayer.anchorPoint = bare
            ? CGPoint(x: screenCutout.midX / shellPixels.width, y: screenCutout.midY / shellPixels.height)
            : CGPoint(x: 0.5, y: 0.5)
        shellLayer.isHidden = false
        CATransaction.commit()
        modelPresentationFinished = true
        // macOS 14 keeps the photo shell; RealityKit texture rotation requires 15.
        if bezel == .model, #available(macOS 15, *), let name = profile.deviceModelName,
           let url = Bundle.main.url(forResource: name, withExtension: "usdz", subdirectory: "Models") {
            modelPresentationFinished = false
            // Give RealityKit one second to present the device itself. Slower
            // startup shows a temporary photo while the live model keeps
            // loading; a busy GPU must never permanently disable 3D.
            shellLayer.isHidden = true
            homeButton.isHidden = true
            let profile = profile
            modelFallbackTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.showStaticDevice()
            }
            modelLoadTask = Task { [weak self] in
                do {
                    let model = try await DeviceModelView(url: url, profile: profile)
                    try Task.checkCancellation()
                    guard self?.stageModelForPresentation(model) == true else { return }
                    let frameReady = await model.prepareFirstFrame()
                    try Task.checkCancellation()
                    // Do not retain the display across a renderer callback. A
                    // stalled snapshot must not keep a closed window alive.
                    guard frameReady else { return }
                    self?.presentModel(model)
                } catch is CancellationError {} catch {
                    NSLog("%@ model could not load: %@", name, error.localizedDescription)
                    self?.showStaticDevice()
                }
            }
        }
        needsLayout = true
    }

    private func stageModelForPresentation(_ model: DeviceModelView) -> Bool {
        guard modelView == nil else { return false }
        addSubview(model, positioned: .below, relativeTo: homeButton)
        pendingModelView = model
        model.alphaValue = 0
        model.setScreenOff(powerPresentation != .awake)
        if let image = captureFrame(includeTouches: false) { model.updateFrame(image) }
        needsLayout = true
        layoutSubtreeIfNeeded()
        return true
    }

    private func showStaticDevice() {
        guard modelView == nil else { return }
        modelPresentationFinished = true
        modelFallbackTask?.cancel()
        shellLayer.isHidden = false
        needsLayout = true
    }

    private func presentModel(_ model: DeviceModelView) {
        guard modelView == nil else { return }
        modelPresentationFinished = true
        modelFallbackTask?.cancel()
        pendingModelView = nil
        modelView = model
        model.setScreenOff(powerPresentation != .awake)
        needsLayout = true
        layoutSubtreeIfNeeded()
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.0 : 0.2
        if !shellLayer.isHidden, duration > 0 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shellLayer.opacity
            fade.toValue = 0
            fade.duration = duration
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            shellLayer.add(fade, forKey: "modelPresentation")
        } else { shellLayer.isHidden = true }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            model.animator().alphaValue = CGFloat(shellLayer.opacity)
        } completionHandler: { [weak self] in
            self?.shellLayer.isHidden = true
            self?.shellLayer.removeAnimation(forKey: "modelPresentation")
        }
    }

    override var isFlipped: Bool { true }          // y-down, matching the guest
    override var acceptsFirstResponder: Bool { true }
    /// A click into a window in the background touches the device at once, as on a real screen.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The device's buttons and the capture actions, for the contextual menu and VoiceOver's actions;
    /// each goes up the responder chain to the window's own command (MainWindowController's, by name).
    static let screenActions: [(String, Selector)] = [
        ("Home Screen", NSSelectorFromString("deviceHome:")),
        ("Lock", NSSelectorFromString("deviceLock:")),
        ("Rotate Left", NSSelectorFromString("deviceRotateLeft:")),
        ("Rotate Right", NSSelectorFromString("deviceRotateRight:")),
        ("Shake", NSSelectorFromString("deviceShake:")),
        ("Copy Screenshot", NSSelectorFromString("copyScreen:")),
        ("Save Screenshot", NSSelectorFromString("saveScreenshot:")),
    ]

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (index, (title, action)) in Self.screenActions.enumerated() {
            if index == 5 { menu.addItem(.separator()) }
            menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        }
        return menu
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the window: stop the link. It retains self, and nothing ever
        // invalidated it — so the view (and the emulator through it) could never
        // deallocate and step() kept polling, deep-copying frames forever. Only
        // masked because closing the window usually quits the app.
        if window == nil {
            modelLoadTask?.cancel()
            modelFallbackTask?.cancel()
            wheelTiltResetTask?.cancel()
            displayLink?.invalidate()
            displayLink = nil
            NotificationCenter.default.removeObserver(self)
            return
        }
        guard displayLink == nil else { return }
        // Every window entry: leaving one dropped all of this view's observers (above), the bezel's included,
        // so a view that had left a window (a session swap, a restart at a new panel) ignored View ▸ Show Device
        // Bezel for good. The preference may have changed meanwhile too.
        NotificationCenter.default.addObserver(self, selector: #selector(bezelPreferenceChanged), name: Self.bezelDidChange, object: nil)
        bezelPreferenceChanged()
        let link = displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
        // Moving between displays can change the backing pixel scale.
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didMoveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: name, object: window)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(releaseHeldKeys),
            name: NSWindow.didResignKeyNotification, object: window)
    }

    var onPhysicalSizeUnavailable: (() -> Void)?
    var physicalScale: CGFloat? {
        guard let window else { return nil }
        let center = window.convertPoint(toScreen: convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? window.screen
        return screen.flatMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).flatMap {
                DisplayMeasurements.pointsPerMillimeter(display: CGDirectDisplayID($0.uint32Value), logical: screen.frame.size)
            }
        }.map {
            let height = profile.physicalHeightMillimeters * $0
            return modelView?.physicalScale(heightInPoints: height) ?? height / shellPixels.height
        }
    }
    @objc private func screenChanged() {
        if zoom == .physical, physicalScale == nil { zoom = .fit; onPhysicalSizeUnavailable?() }
        needsLayout = true
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); screenChanged() }


    @objc private func homeTapped() { endLiveText(); emulator?.pressHome() }

    // MARK: - Layout

    /// The shell layer stays at its native pixel size and carries scale and
    /// rotation in a single transform; the content layer is its child, parked
    /// at the screen cutout in shell-native pixels. Locked-together geometry
    /// falls out of the layer tree — layout only picks the scale, the angle,
    /// and the home button's (view-space) frame.
    override func layout() {
        super.layout()
        // The pose comes from the emulator's tracked orientation, not the frame
        // buffer's aspect — 480×320 alone can't tell landscape-left from
        // landscape-right, and 180° doesn't change the dimensions at all.
        // (Layout is still *triggered* by the dims flipping in step(), which
        // every quarter turn does.)
        let rotation = emulator?.rotationDegrees ?? 0
        if let lastRotation, lastRotation != rotation { endLiveText() }
        let orientationChanged = lastRotation.map { $0 != rotation } ?? false
        lastRotation = rotation
        let isLandscape = rotation == 90 || rotation == 270

        // The scan stands a quarter-turn from upright when the guest turned its
        // UI into it (guestTurn). A panel fixed to the shell (the iPad's) keeps
        // that; the iPod's pre-rotated surface also swaps with the device.
        let turned = guestTurn != 0
        let cutoutSize = (profile.surfaceFollowsRotation ? turned != isLandscape : turned)
            ? CGSize(width: screenCutout.height, height: screenCutout.width)
            : screenCutout.size
        // The shell's own on-screen bounding box once rotated — this, not just
        // the content, is what needs to fit inside the pane with margin. The
        // 3D model's outline, once it has one: the iPad's flat art is smaller.
        let shell = (modelView ?? pendingModelView)?.shellPixels ?? shellPixels
        // Bare, the screen's own box is what fits.
        let fitted = bare ? screenCutout.size : shell
        let shellOnScreenPixels = isLandscape
            ? CGSize(width: fitted.height, height: fitted.width)
            : fitted

        let scale: CGFloat
        switch zoom {
        case _ where dragScale != nil:
            scale = dragScale!   // an edge drag keeps its scale, so the edge stays under the pointer
        case .pixels(let points) where freeFormActive:
            scale = CGFloat(points)   // free-form Nx: a guest pixel is N points (Sam's "at 1x a point is a pixel")
        case .physical where freeFormActive:
            // Free-form's shell unit is a guest pixel: the shipped panel's pixel pitch, at its physical size.
            scale = physicalScale.map { $0 * profile.screenCutout.height / profile.uprightScreenPixels.height }
                ?? fitScale(shellOnScreenPixels)
        case .fit:
            scale = fitScale(shellOnScreenPixels)
        case .physical:
            scale = physicalScale ?? fitScale(shellOnScreenPixels)
        case .pixels(let multiple):
            scale = shellScale(guestPixelsPerDisplayPixel: multiple)
        }
        appliedScale = scale
        contentLayer.magnificationFilter = Self.contentsFilter(pixelMultiple)
        // Centre on the SAFE area, not the raw bounds: with .fullSizeContentView
        // the pane runs behind the toolbar, so centring on bounds would push the
        // device up under it. The gradient still fills the whole pane, which is
        // the point — only the device is inset.
        let usable = deviceLayoutRect
        let viewCenter = CGPoint(x: usable.midX, y: usable.midY)
        let shellCenter = CGPoint(x: shellPixels.width / 2, y: shellPixels.height / 2)
        let rest = Self.layerAngle(rotation)
        let angle = (motionRestAngle ?? rest) + tiltAngle

        // The home button is an NSView, so it can't ride the shell's transform;
        // project its shell-native centre through the same rotation by hand.
        // NOTE: in this flipped (y-down) view the standard rotation matrix
        // turns a point visually clockwise for a positive angle — the SAME
        // visual direction a positive angle gives the layer transform here
        // (AppKit's geometry flip inverts a layer transform's handedness too),
        // so `rest` feeds both unconverted. At rest+tilt the button is mid-drag
        // and invisible anyway, so only `rest` is projected.
        let buttonCenterNative = CGPoint(x: shellPixels.width / 2,
                                         y: shellPixels.height - homeButtonBottomInset
                                            - homeButtonDiameter / 2)
        let native = CGVector(dx: buttonCenterNative.x - shellCenter.x,
                              dy: buttonCenterNative.y - shellCenter.y)
        let buttonOffset = CGVector(dx: native.dx * cos(rest) - native.dy * sin(rest),
                                    dy: native.dx * sin(rest) + native.dy * cos(rest))
        let buttonDiameter = (homeButtonDiameter * scale).rounded()
        let buttonRect = CGRect(
            x: (viewCenter.x + buttonOffset.dx * scale - buttonDiameter / 2).rounded(),
            y: (viewCenter.y + buttonOffset.dy * scale - buttonDiameter / 2).rounded(),
            width: buttonDiameter, height: buttonDiameter)

        let animate = orientationChanged || pendingAnimatedLayout
        pendingAnimatedLayout = false

        // The guest surface arrives pre-rotated (ipod_touch_lcd.c turns the
        // picture the same way the user turned the device), so at rest the
        // content sits at -angle inside the shell: net rotation zero, surface
        // shown as published. These are applied WITHOUT animation — the new
        // buffer drawn at the new pose is pixel-identical to the old frame at
        // the old pose, so there's no jump, and during the shell's animated
        // swing the content keeps its fixed offset and rides rigidly, rotating
        // with the chrome instead of squishing in place. Bounds, never frame:
        // setting .frame on a transformed layer is undefined (it was the
        // squished-screen bug).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.bounds = CGRect(origin: .zero, size: cutoutSize)
        // Counter only the guest's quarter-turn, never the temporary tilt.
        // A layout during a gesture must not leave the panel crooked after release.
        if !profile.surfaceFollowsRotation {
            // The iPad's guest turns its own UI inside a panel that turns with
            // the shell: only the scan-to-upright quarter-turn applies.
            contentLayer.transform = CATransform3DMakeRotation(guestTurn, 0, 0, 1)
        } else {
            contentLayer.transform = CATransform3DMakeRotation(guestTurn - rest, 0, 0, 1)
        }
        CATransaction.commit()

        // Scale and rotation live in ONE transform, and the content is a child
        // of the shell — the whole device swings as a unit.
        CATransaction.begin()
        if animate {
            CATransaction.setAnimationDuration(Self.rotationDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)   // no implicit fade on plain resize
        }
        shellLayer.position = viewCenter
        shellLayer.transform = motionTransform(angle: angle, scale: scale)
        homeButton.isHidden = homeButtonHidden
        CATransaction.commit()

        modelView?.frame = bounds
        pendingModelView?.frame = bounds
        modelView?.viewportCenter = viewCenter
        pendingModelView?.viewportCenter = viewCenter
        updateModelPose(animated: animate)
        if let modelView, let rect = modelView.homeButtonRect {
            homeButton.frame = convert(rect, from: modelView)
        } else { homeButton.frame = buttonRect }
        if let liveTextView, let root = layer {
            if let modelView {
                let a = convert(modelView.projectedPoint(.zero), from: modelView)
                let b = convert(modelView.projectedPoint(CGPoint(x: 1, y: 1)), from: modelView)
                liveTextView.frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
            } else { liveTextView.frame = contentLayer.convert(contentLayer.bounds, to: root) }
        }
        if freeFormActive { window?.invalidateCursorRects(for: self) }
    }

    /// No Home button bare (⇧⌘H presses it), while the model loads, or over a tilting flat shell.
    private var homeButtonHidden: Bool { bare || !modelPresentationFinished || (modelView == nil && (tiltAngle != 0 || pitchAngle != 0)) }

    /// Scale is independent of a framebuffer arriving before or after rotation.
    var pixelMultiple: CGFloat {
        // Free-form steps in points per guest pixel, the unit its Nx is in.
        ZoomMode.pixelMultiple(appliedScale: appliedScale, cutoutWidth: screenCutout.width, nativeWidth: nativeScreenPixels.width,
                               backingScale: window?.backingScaleFactor ?? 2, freeForm: freeFormActive)
    }

    private var appliedScale: CGFloat = 1

    /// Whole display pixels per guest pixel stay crisp (nearest); between the steps (Fit, Physical Size)
    /// nearest would draw guest pixels one or two display pixels wide, so those are filtered (linear).
    static func contentsFilter(_ pixelMultiple: CGFloat) -> CALayerContentsFilter {
        ZoomMode.drawsNearest(pixelMultiple) ? .nearest : .linear
    }

    private func shellScale(guestPixelsPerDisplayPixel multiple: Int) -> CGFloat {
        ZoomMode.shellScale(guestPixelsPerDisplayPixel: multiple, cutoutWidth: screenCutout.width, nativeWidth: nativeScreenPixels.width,
                            backingScale: window?.backingScaleFactor ?? 2)
    }

    /// The largest uniform scale that fits `nativeSize` in the pane inset on
    /// every side. `nativeSize` is the shell's bounding box in its current
    /// orientation, so portrait and landscape both land with the same margin
    /// without either needing its own number.
    private func fitScale(_ nativeSize: CGSize) -> CGFloat {
        let usable = deviceLayoutRect
        let maxWidth = max(usable.width - 2 * Self.zoomInset, 1)
        let maxHeight = max(usable.height - 2 * Self.zoomInset, 1)
        return min(maxWidth / nativeSize.width, maxHeight / nativeSize.height)
    }

    // MARK: - Free-form screen (issue #21)
    //
    // View ▸ Free-Form Screen: no bezel, and the screen itself is resizable. Dragging the screen's own edge or
    // corner (nothing else: not the window, the sidebar or the inspector) stretches the current frame to the new
    // size live, with a W × H status snapped to what the board's panel= accepts. Zoom only draws it bigger or
    // smaller: Nx is N points per guest pixel, Fit scales the panel into the pane, Physical gives a guest pixel the
    // shipped panel's physical pitch. Like the shipped screen's, a screen bigger than the pane is clipped, centred. A second after the drag ends the size is recorded and, if it changed, the
    // device restarts at it (Stop's hard halt, then a fresh helper): UIKit takes the panel's size at boot only.
    // The squished frame stays up, through the next session's view (`handoffs`), until the new boot's first frame.

    /// The upright guest panel the running boot has, when free-form is on; nil: the device as shipped.
    private(set) var freeFormPanel: CGSize?
    /// The upright size on screen while a resize is in progress or waiting to restart (the frame stretched to it).
    private var freeFormTarget: CGSize?
    private var freeFormActive: Bool { freeFormPanel != nil || freeFormTarget != nil }
    /// The running scan's scan-to-upright turn (Board.guestTurn): the shipped panel's, or the free-form one's.
    private var guestTurn: CGFloat { runningScan.map(Board.guestTurn(scan:)) ?? profile.panelRotation }
    /// The free-form panel as it scans (the record's `panel`); nil, the shipped one.
    private var runningScan: CGSize?
    var isFreeForm: Bool { freeFormPanel != nil }
    var canToggleFreeForm: Bool { profile.supportsFreeForm && !restartingAtPanel }
    /// Records an upright panel (nil: the shipped one); with `restart` true the owner restarts the device on it.
    /// Returns whether a restart is under way.
    var onPanelChange: ((_ upright: CGSize?, _ restart: Bool) -> Bool)?
    static var panelCommitDelay: Duration = .seconds(1)
    /// The last frame of a device restarting at a new panel, for that device's next view.
    private static var handoffs: [UUID: CGImage] = [:]
    private var deviceKey: UUID?
    private(set) var restartingAtPanel = false
    private var panelCommitTask: Task<Void, Never>?
    /// Points per guest pixel, fixed for the length of a resize.
    private var dragScale: CGFloat?
    private var panelDrag: (origin: CGPoint, edges: CGVector, size: CGSize)?
    /// The resize's status for the window's notice stack (the owner shows it there, one surface with the others):
    /// "W × H" while dragging, "Restarting at W × H…" while this device restarts; nil, none.
    var onPanelStatus: ((String?) -> Void)?
    private(set) var panelReadoutText: String? { didSet { if oldValue != panelReadoutText { onPanelStatus?(panelReadoutText) } } }
    /// "Restarting at W × H…" for the startup notice of a boot this view's device restarted at a new panel.
    private(set) var restartTitle: String?

    /// The owner's device: its recorded panel as it scans (nil when not free-form) and its identity for the hand-off.
    func configureFreeForm(scan: CGSize?, key: UUID) {
        deviceKey = key
        if profile.supportsFreeForm, let scan {
            runningScan = scan
            freeFormPanel = Board.upright(scan: scan)
            applyFreeFormGeometry()
            applyBezel(.off)
            needsLayout = true
        }
        if let image = Self.handoffs.removeValue(forKey: key) {
            contentLayer.contents = image
            restartTitle = "Restarting at \(Self.text(onScreen(freeFormPanel ?? profile.uprightScreenPixels)))…"
        }
    }

    /// View ▸ Free-Form Screen. On keeps the running size (the shipped panel's; no restart); off returns to the
    /// shipped panel and the bezel, restarting if the guest runs at another size.
    func setFreeForm(_ on: Bool) {
        guard canToggleFreeForm, on != isFreeForm else { return }
        panelCommitTask?.cancel()
        let native = profile.uprightScreenPixels
        if on {
            runningScan = nil
            freeFormPanel = native
            _ = onPanelChange?(native, false)
            applyFreeFormGeometry()
            applyBezel(.off)
            needsLayout = true
            return
        }
        let running = freeFormPanel
        freeFormPanel = nil
        freeFormTarget = running == native ? nil : native
        dragScale = nil
        if freeFormTarget == nil || !requestPanel(nil) {
            if freeFormTarget == nil { _ = onPanelChange?(nil, false) }
            freeFormTarget = nil
            panelReadoutText = nil
            applyFreeFormGeometry()
            applyBezel(Self.bezel)
        }
        needsLayout = true
    }

    /// The screen's box in the shell follows the size shown; the caller lays out (or is layout).
    private func applyFreeFormGeometry() {
        guard let size = freeFormTarget ?? freeFormPanel else {
            nativeScreenPixels = profile.uprightScreenPixels
            screenCutout = profile.screenCutout
            return
        }
        // One shell unit per guest pixel, centred where the shipped screen sits.
        nativeScreenPixels = size
        let centre = CGPoint(x: profile.screenCutout.midX, y: profile.screenCutout.midY)
        screenCutout = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Upright ⇄ as seen: the device's quarter-turns swap the sides.
    private func onScreen(_ size: CGSize) -> CGSize {
        (emulator?.rotationDegrees ?? 0) % 180 != 0 ? CGSize(width: size.height, height: size.width) : size
    }

    private static func text(_ size: CGSize) -> String { "\(Int(size.width)) × \(Int(size.height))" }

    private func showReadout(_ text: String) { panelReadoutText = text }

    private func beginPanelResize() {
        panelCommitTask?.cancel()
        if dragScale == nil { dragScale = appliedScale }
        if freeFormTarget == nil { freeFormTarget = freeFormPanel }
        showReadout(Self.text(onScreen(freeFormTarget ?? profile.uprightScreenPixels)))
    }

    /// The edges a press just outside the screen grabs (-1 left/top, +1 right/bottom, 0 neither); nil off the band.
    private func panelEdges(at p: CGPoint) -> CGVector? {
        guard isFreeForm, !restartingAtPanel, let root = layer else { return nil }
        let r = contentLayer.convert(contentLayer.bounds, to: root), band: CGFloat = 10
        guard r.insetBy(dx: -band, dy: -band).contains(p), !r.contains(p) else { return nil }
        return CGVector(dx: p.x < r.minX ? -1 : p.x > r.maxX ? 1 : 0, dy: p.y < r.minY ? -1 : p.y > r.maxY ? 1 : 0)
    }

    /// The mouse on the free-form screen's edge: a press there grabs it, a drag resizes, the release ends it.
    /// True when the event was the resize's (not a touch).
    private func panelResize(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            guard let edges = panelEdges(at: p) else { return false }
            beginPanelResize()
            panelDrag = (p, edges, onScreen(freeFormTarget ?? profile.uprightScreenPixels))
        case .leftMouseDragged:
            guard let drag = panelDrag, let scale = dragScale else { return false }
            // The screen stays centred: an edge moves half the size change, so the size changes twice the pointer's.
            updatePanelTarget(onScreen: CGSize(width: drag.size.width + 2 * (p.x - drag.origin.x) * drag.edges.dx / scale,
                                               height: drag.size.height + 2 * (p.y - drag.origin.y) * drag.edges.dy / scale))
            needsLayout = true
        default:
            guard panelDrag != nil else { return false }
            panelDrag = nil
            endPanelResize()
        }
        return true
    }

    /// A resize's size as seen, in guest pixels: snapped to the board's panel, shown stretched, read out.
    private func updatePanelTarget(onScreen size: CGSize) {
        let snapped = profile.snappedPanel(upright: onScreen(size))
        freeFormTarget = snapped
        showReadout(Self.text(onScreen(snapped)))
        applyFreeFormGeometry()
    }

    private func endPanelResize() {
        panelCommitTask?.cancel()
        panelCommitTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.panelCommitDelay) } catch { return }
            self?.commitPanel()
        }
    }

    private func commitPanel() {
        guard let target = freeFormTarget, isFreeForm, !restartingAtPanel else { return }
        if target == freeFormPanel || !requestPanel(target) {
            if target != freeFormPanel { runningScan = profile.scan(upright: target) }   // recorded for the next start
            freeFormPanel = target
            freeFormTarget = nil
            dragScale = nil
            panelReadoutText = nil
            applyFreeFormGeometry()
            needsLayout = true
        }
    }

    /// Record the panel and have the owner restart on it. While it restarts the screen keeps the squished frame
    /// and reads "Restarting at…", and the frame waits for the next view. False: nothing restarts.
    private func requestPanel(_ upright: CGSize?) -> Bool {
        let image = currentFrame().flatMap { Self.image($0, colorSpace: colorSpace) }
        guard onPanelChange?(upright, true) == true else { return false }
        restartingAtPanel = true
        if let deviceKey, let image { Self.handoffs[deviceKey] = image }
        showReadout("Restarting at \(Self.text(onScreen(upright ?? profile.uprightScreenPixels)))…")
        updatePowerPresentation()
        window?.invalidateCursorRects(for: self)
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isFreeForm, !restartingAtPanel, let root = layer else { return }
        let r = contentLayer.convert(contentLayer.bounds, to: root), band: CGFloat = 10
        addCursorRect(CGRect(x: r.minX - band, y: r.minY, width: band, height: r.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: r.maxX, y: r.minY, width: band, height: r.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: r.minX, y: r.minY - band, width: r.width, height: band), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: r.minX, y: r.maxY, width: r.width, height: band), cursor: .resizeUpDown)
        for x in [r.minX - band, r.maxX] { for y in [r.minY - band, r.maxY] {
            addCursorRect(CGRect(x: x, y: y, width: band, height: band), cursor: .crosshair)
        } }
    }

    // MARK: - Frame polling

    /// Frames come from the helper's IOSurface ring: the layer shows the front
    /// surface itself (no copy), and only the 3D model, which needs a texture,
    /// gets a CGImage made from it. Liveness and status are EmulatorController's
    /// own poll, so a hidden device (no display link) keeps them.
    @objc private func step() {
        if let generation = emulator?.shakeGeneration, generation != lastShakeGeneration {
            lastShakeGeneration = generation
            modelView?.shake()
        }
        if let modelView, modelView.advanceAnimations(), let rect = modelView.homeButtonRect {
            homeButton.frame = convert(rect, from: modelView)
        }
        updateTouchOverlay()
        updateKeyboardPointer()
        _ = currentFrame()
        // The guest's orientation can change after its turned picture arrived (the A4 boards' SpringBoard query
        // answers later): with a static screen no new frame would lay it out.
        if emulator?.rotationDegrees != lastRotation { needsLayout = true }
    }

    /// The newest ring surface, shown if it is new. The ring reader belongs to
    /// one thread; the display link and captures are both on main.
    private func currentFrame() -> IOSurface? {
        guard let frame = emulator?.link?.frontSurface() else { return shownSurface }
        guard frame.serial != shownSerial || frame.surface !== shownSurface else { return frame.surface }
        shownSerial = frame.serial
        shownSurface = frame.surface
        let newFramePixels = CGSize(width: frame.surface.width, height: frame.surface.height)
        if newFramePixels != framePixels {
            framePixels = newFramePixels
            needsLayout = true
        }
        // The dims flipping catches every quarter turn but not a half one:
        // 180° leaves 320×480 at 320×480, so an upside-down app (or two
        // auto-rotations run back to back) would leave the shell posed at the
        // old angle until something else happened to lay out. Ask the emulator
        // directly — it is the source of truth for the pose, and layout()
        // already compares against the same value to decide whether to animate.
        if emulator?.rotationDegrees != lastRotation { needsLayout = true }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The helper forces the alpha byte opaque (FrameRingWriter.copy): iBoot
        // and the iPod's framebuffer leave it 0, which a layer would honour.
        contentLayer.contents = frame.surface
        if let model = modelView ?? pendingModelView, let image = Self.image(frame.surface, colorSpace: colorSpace) {
            model.updateFrame(image)
        }
        CATransaction.commit()
        return frame.surface
    }

    /// A copy of a ring surface, held in use while it is read so the helper
    /// never writes into it. noneSkipFirst, NOT premultipliedFirst: the panel
    /// is opaque (ui/cocoa.m ignores alpha for the same reason).
    private static func image(_ surface: IOSurface, colorSpace: CGColorSpace) -> CGImage? {
        surface.incrementUseCount()
        surface.lock(options: .readOnly, seed: nil)
        let data = Data(bytes: surface.baseAddress, count: surface.bytesPerRow * surface.height)
        surface.unlock(options: .readOnly, seed: nil)
        surface.decrementUseCount()
        let info: CGBitmapInfo = [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: surface.width, height: surface.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: surface.bytesPerRow, space: colorSpace, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private var liveTextView: InlineLiveTextView?
    var isShowingLiveText: Bool { liveTextView != nil }
    func toggleLiveText() {
        if liveTextView != nil { endLiveText(); return }
        guard let image = captureFrame(includeTouches: false) else { return }
        resetMotion()
        let view = InlineLiveTextView(image: image)
        view.onClose = { [weak self] in self?.endLiveText() }
        liveTextView = view
        updatePowerPresentation()
        addSubview(view)
        needsLayout = true
        window?.toolbar?.validateVisibleItems()
    }
    func endLiveText() {
        guard let liveTextView else { return }
        liveTextView.stop()
        self.liveTextView = nil
        updatePowerPresentation()
        window?.makeFirstResponder(self)
        window?.toolbar?.validateVisibleItems()
    }

    var showsTouches = UserDefaults.standard.bool(forKey: "showsTouches") {
        didSet {
            UserDefaults.standard.set(showsTouches, forKey: "showsTouches")
            updateTouchOverlay()
        }
    }
    // A sibling of the device shell, never a child of the framebuffer layer.
    // Fading/shadow compositing must not involve the guest screen's contents.
    private let touchOverlayLayer = CALayer()
    private var touchLayers: [Int: CALayer] = [:]
    private static let touchFadeDuration = 0.16
    private var visibleTouches: [Int: (point: CGPoint, expires: CFTimeInterval)] = [:]

    private func sendVisualTouch(_ slot: Int32, _ phase: Int32, _ x: Double, _ y: Double, keyboard: Bool = false) {
        if !keyboard { endKeyboardTouch() }
        guard touchInteractionEnabled else {
            if phase == TouchPhase.end { emulator?.link?.send(.touch(slot: Int(slot), phase: Int(phase), x: x, y: y)) }
            clearTouchOverlay()
            return
        }
        noteTouch(slot: Int(slot), phase: phase, x: x, y: y)
        emulator?.link?.send(.touch(slot: Int(slot), phase: Int(phase), x: x, y: y))
    }
    private func sendVisualTouch2(_ phase: Int32, _ x: Double, _ y: Double) {
        guard touchInteractionEnabled else {
            if phase == TouchPhase.end { emulator?.link?.send(.touch2(phase: Int(phase), x: x, y: y)) }
            clearTouchOverlay()
            return
        }
        noteTouch(slot: 1, phase: phase, x: x, y: y)
        emulator?.link?.send(.touch2(phase: Int(phase), x: x, y: y))
    }
    private func noteTouch(slot: Int, phase: Int32, x: Double, y: Double) {
        visibleTouches[slot] = (CGPoint(x: x, y: y), phase == TouchPhase.end ? CACurrentMediaTime() + Self.touchFadeDuration : .infinity)
        updateTouchOverlay()
    }
    private var touchInteractionEnabled: Bool {
        emulator?.acceptsInput == true && emulator?.isSleeping != true && !isShowingLiveText
    }
    private func clearTouchOverlay() {
        visibleTouches.removeAll()
        for layer in touchLayers.values { layer.removeFromSuperlayer() }
        touchLayers.removeAll()
    }
    private var activeTouches: [(slot: Int, point: CGPoint, opacity: CGFloat)] {
        guard touchInteractionEnabled else { clearTouchOverlay(); return [] }
        let now = CACurrentMediaTime()
        visibleTouches = visibleTouches.filter { $0.value.expires > now }
        guard showsTouches else { return [] }
        return visibleTouches.map { slot, value in
            (slot, value.point, CGFloat(min(1, (value.expires - now) / Self.touchFadeDuration)))
        }
    }
    private func updateTouchOverlay() {
        let touches = activeTouches
        let liveSlots = Set(touches.map(\.slot))
        for slot in Array(touchLayers.keys) where !liveSlots.contains(slot) {
            touchLayers.removeValue(forKey: slot)?.removeFromSuperlayer()
        }
        // This overlay uses view coordinates, independent of the scaled shell.
        let diameter: CGFloat = 44
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        touchOverlayLayer.frame = layer?.bounds ?? bounds
        for touch in touches {
            let dot: CALayer
            if let existing = touchLayers[touch.slot] { dot = existing }
            else {
                dot = CALayer()
                dot.actions = ["opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "shadowPath": NSNull()]
                let gradient = CAGradientLayer()
                gradient.colors = [NSColor.white.withAlphaComponent(0.95).cgColor,
                                   NSColor(white: 0.94, alpha: 0.9).cgColor]
                gradient.startPoint = CGPoint(x: 0.5, y: 0)
                gradient.endPoint = CGPoint(x: 0.5, y: 1)
                gradient.masksToBounds = true
                dot.addSublayer(gradient)
                dot.shadowColor = NSColor.black.cgColor
                dot.shadowOpacity = 0.22
                touchOverlayLayer.addSublayer(dot)
                touchLayers[touch.slot] = dot
            }
            dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            dot.position = projectedPanelPoint(touch.point)
            dot.opacity = Float(touch.opacity)
            dot.shadowRadius = 5
            dot.shadowOffset = CGSize(width: 0, height: 2)
            dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
            dot.sublayers?.first?.frame = dot.bounds
            dot.sublayers?.first?.cornerRadius = diameter / 2
        }
        CATransaction.commit()
    }

    /// Reads the newest ring surface under a use count, so capture is current
    /// even when paused, hidden or minimized and never reads a recycled slot.
    func captureFrame(includeTouches: Bool = true) -> CGImage? {
        if let liveTextView { return liveTextView.capturedImage }
        guard let image = capturePanelFrame(includeTouches: includeTouches) else { return nil }
        // Match the window: scan-to-upright plus, where the surface doesn't follow it, the device's own quarter-turn.
        let turns = PanelCapture.quarterTurns(guestTurn: guestTurn, deviceDegrees: emulator?.rotationDegrees ?? 0,
                                              surfaceFollowsRotation: profile.surfaceFollowsRotation)
        guard turns != 0 else { return image }
        return PanelCapture.rotated(image, clockwiseQuarterTurns: turns) ?? image
    }

    private func capturePanelFrame(includeTouches: Bool) -> CGImage? {
        guard let surface = currentFrame(), let image = Self.image(surface, colorSpace: colorSpace) else { return nil }
        let width = image.width, height = image.height
        let info: CGBitmapInfo = [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
        let touches = includeTouches ? activeTouches : []
        guard !touches.isEmpty,
              let context = CGContext(data: nil, width: Int(width), height: Int(height),
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: info.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: Int(width), height: Int(height)))
        let pixelScale = CGFloat(width) / max(contentLayer.bounds.width * appliedScale, 1)
        let diameter = 44 * pixelScale
        let colors = [NSColor.white.withAlphaComponent(0.95).cgColor,
                      NSColor(white: 0.94, alpha: 0.9).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return image }
        for touch in touches {
            let rect = CGRect(x: touch.point.x * CGFloat(width) - diameter / 2,
                              y: (1 - touch.point.y) * CGFloat(height) - diameter / 2,
                              width: diameter, height: diameter)
            context.saveGState()
            context.setAlpha(touch.opacity)
            context.setShadow(offset: CGSize(width: 0, height: -2 * pixelScale), blur: 5 * pixelScale,
                              color: NSColor.black.withAlphaComponent(0.22).cgColor)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: rect)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.addEllipse(in: rect)
            context.clip()
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY),
                                       end: CGPoint(x: rect.midX, y: rect.minY), options: [])
            context.restoreGState()
        }
        return context.makeImage()
    }
    /// The guest screen's long side in pixels: the screen-only recording's square canvas.
    var screenSide: CGFloat { max(nativeScreenPixels.width, nativeScreenPixels.height) }
    var screenImage: NSImage? {
        get async {
            guard let cg = captureFrame() else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }

    // MARK: - Touch input

    /// Normalise a point to 0…1 over the panel content. The content layer sits
    /// inside the shell's scale+rotation transform, so convert through the
    /// layer tree rather than reading a frame. Returns nil for clicks outside
    /// it. (The emulator un-rotates touches itself — ipod_touch_lcd_map_touch —
    /// so coordinates over the surface as published are exactly what it wants.)
    private func normalized(_ event: NSEvent) -> (Double, Double)? { normalized(windowPoint: event.locationInWindow) }

    private func normalized(windowPoint: NSPoint) -> (Double, Double)? {
        if let modelView {
            guard let p = modelView.panelPoint(modelView.convert(windowPoint, from: nil)) else { return nil }
            return (Double(p.x), Double(p.y))
        }
        guard let rootLayer = layer else { return nil }
        let p = convert(windowPoint, from: nil)
        let cp = contentLayer.convert(p, from: rootLayer)
        let b = contentLayer.bounds
        guard b.width > 0, b.height > 0, b.contains(cp) else { return nil }
        return (Double(cp.x / b.width), Double(cp.y / b.height))   // isFlipped → y-down
    }

    // MARK: - Trackpad gestures
    //
    // Where the cursor is decides who the gesture belongs to. Over the panel it
    // is the guest's — a pinch is a real two-finger pinch, a scroll is a finger
    // dragging the content, a two-finger double tap is a double tap. Off the
    // panel there is no touch to send, so the same gestures drive the host: the
    // window's zoom, and tilting the device for the accelerometer.
    //
    // All of it tracks continuously. A gesture is a stream of small deltas from
    // .began to .ended, and each one is forwarded as it arrives, so the guest
    // follows the fingers instead of receiving a canned event at the end.

    /// Where the guest touch(es) are right now, in 0…1 panel space.
    private var gestureAnchor = CGPoint.zero
    /// Half the current pinch separation, panel-relative.
    private var pinchSpread = 0.0
    private var pinchingGuest = false
    /// Live scroll-drag: the finger's current position, carried between events.
    private var scrollPoint: CGPoint?
    /// Tilt driven by a two-finger scroll off the panel.
    /// Tilt's gesture state and math (ChassisTilt): drag, scroll and twist off the panel.
    private var tilt = ChassisTilt()
    private var pitchAngle: CGFloat { tilt.pitchAngle }
    private var rotatingChassis: Bool { tilt.rotatingChassis }
    private var wheelTiltResetTask: Task<Void, Never>?
    private var motionRestAngle: CGFloat? { tilt.motionRestAngle }
    private var scrollTilting: Bool { tilt.scrollTilting }

    /// How far outside the screen, in points, a press still lands on its edge: edge swipes (Notification Center,
    /// back swipes) start at the glass's border, where a pointer easily misses by a few points.
    static let screenEdgeMargin: CGFloat = 14

    /// A press within `screenEdgeMargin` of the screen, clamped onto its edge; nil on the screen itself or farther
    /// out. Probes the margin around the point through the same mapping as `normalized`, so it holds for the 3D
    /// model, the flat shell and any rotation or zoom.
    private func nearScreenEdge(_ event: NSEvent) -> (Double, Double)? {
        let point = event.locationInWindow, m = Self.screenEdgeMargin
        let probes = [(-m, 0), (m, 0), (0, -m), (0, m), (-m, -m), (m, -m), (-m, m), (m, m)]
        guard normalized(windowPoint: point) == nil,
              probes.contains(where: { normalized(windowPoint: NSPoint(x: point.x + $0.0, y: point.y + $0.1)) != nil }),
              let p = clampedPanelPoint(event) else { return nil }
        return (Double(p.x), Double(p.y))
    }

    /// The panel-space point under the cursor, clamped into the panel. Unlike
    /// `normalized` this does not fail when the cursor is just outside — a pinch
    /// that drifts off the edge mid-gesture should keep tracking, not stop dead.
    private func clampedPanelPoint(_ event: NSEvent) -> CGPoint? {
        if let modelView { return modelView.panelPoint(modelView.convert(event.locationInWindow, from: nil), clamped: true) }
        guard let rootLayer = layer else { return nil }
        let cp = contentLayer.convert(convert(event.locationInWindow, from: nil), from: rootLayer)
        let b = contentLayer.bounds
        guard b.width > 0, b.height > 0 else { return nil }
        return CGPoint(x: min(max(cp.x / b.width, 0), 1), y: min(max(cp.y / b.height, 0), 1))
    }

    /// Is the cursor over the device's screen right now?
    private func cursorOverPanel(_ event: NSEvent) -> Bool { normalized(event) != nil }

    // MARK: Pinch

    /// A pinch is the guest's, always — a genuine two-finger pinch with both
    /// contacts tracking the magnification continuously around the point the
    /// fingers started on.
    ///
    /// It deliberately does NOT resize the device itself: pinching is what you
    /// do to the content on a phone, so having it also scale the phone made the
    /// same gesture mean two things depending on a few pixels of cursor
    /// position. The window's zoom lives on the toolbar, the View menu and ⌘+/−.
    override func magnify(with event: NSEvent) {
        guard pinchingGuest || (event.phase == .began && cursorOverPanel(event)) else { return }
        guestPinch(event)
    }

    private func guestPinch(_ event: NSEvent) {
        switch event.phase {
        case .began:
            guard let p = clampedPanelPoint(event) else { return }
            gestureAnchor = p
            pinchSpread = 0.12          // a comfortable starting separation
            pinchingGuest = true
            sendPinch(TouchPhase.begin)
        case .changed:
            guard pinchingGuest else { return }
            // Track the fingers: the separation scales exactly as they do.
            pinchSpread = min(max(pinchSpread * (1 + event.magnification), 0.01), 0.6)
            sendPinch(TouchPhase.update)
        case .ended, .cancelled:
            guard pinchingGuest else { return }
            sendPinch(TouchPhase.end)
            pinchingGuest = false
        default:
            break
        }
    }

    /// Two contacts mirrored through the anchor, along the panel's x axis.
    private func sendPinch(_ phase: Int32) {
        let a = gestureAnchor
        let x1 = min(max(a.x - pinchSpread, 0), 1), x2 = min(max(a.x + pinchSpread, 0), 1)
        sendVisualTouch(0, phase, Double(x1), Double(a.y))
        sendVisualTouch2(phase, Double(x2), Double(a.y))
    }

    // MARK: Two-finger double tap

    /// macOS calls this for a two-finger double tap — the "smart zoom" gesture.
    /// Over the panel it becomes what it means on the device: a double tap,
    /// which is exactly how iOS zooms to fit.
    override func smartMagnify(with event: NSEvent) {
        guard let (nx, ny) = normalized(event) else {
            super.smartMagnify(with: event)
            return
        }
        Task { @MainActor in
            for _ in 0..<2 {
                sendVisualTouch(0, TouchPhase.begin, nx, ny)
                try? await Task.sleep(for: .milliseconds(40))
                sendVisualTouch(0, TouchPhase.end, nx, ny)
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    // MARK: Scroll / swipe

    /// Over the panel, a two-finger scroll IS a finger dragging the content:
    /// begin a touch where the cursor is and move it with the fingers, through
    /// momentum too, so a flick keeps travelling and iOS's own inertia takes
    /// over naturally. A two-finger swipe is the same stream at speed, so it
    /// needs no separate case.
    ///
    /// Off the panel, scrolls tilt the device's accelerometer. A two-finger
    /// twist also controls roll; letting go springs either gesture to rest.
    override func scrollWheel(with event: NSEvent) {
        guard !rotatingChassis && !tilting else { return }
        // Host tilt ends with the fingers. Momentum belongs to content
        // scrolling, and must not start a second model gesture at the cursor.
        if !scrollTilting && scrollPoint == nil && !event.momentumPhase.isEmpty { return }
        if scrollPoint == nil && !scrollTilting && (event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty))
            && (!cursorOverPanel(event) || event.modifierFlags.contains(.option)) {
            beginScrollTilt()
        }
        if scrollTilting {
            scrollTiltChanged(event)
            return
        }
        guestScrollDrag(event)
    }

    private func guestScrollDrag(_ event: NSEvent) {
        // A conventional wheel mouse reports NO phase at all: phase and
        // momentumPhase are both empty. Every branch below tests for a specific
        // phase, so those events fell through to `default`, found no
        // scrollPoint, and returned — scrolling the guest with anything other
        // than an Apple trackpad or Magic Mouse did nothing whatsoever, and
        // super.scrollWheel was never called either, so the event just vanished.
        // Treat one as a whole flick: press, move, lift, in this single call.
        if event.phase.isEmpty, event.momentumPhase.isEmpty {
            wheelFlick(event)
            return
        }
        // Use the deltas as AppKit reports them. It has ALREADY applied the
        // user's natural-scrolling preference, so consulting
        // isDirectionInvertedFromDevice and flipping the sign ourselves just
        // corrects a correction — which is what kept sending these gestures the
        // wrong way. That flag is for telling the user which way the hardware
        // went, not for undoing the system setting.
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let b = contentLayer.bounds
        guard b.width > 0, b.height > 0 else { return }

        switch event.phase {
        case .began:
            guard let p = clampedPanelPoint(event) else { return }
            scrollPoint = p
            sendVisualTouch(0, TouchPhase.begin, Double(p.x), Double(p.y))
        case .changed:
            guard var p = scrollPoint else { return }
            let d = rotatedPanelDelta(dx, dy)
            p.x = min(max(p.x + d.dx / b.width, 0), 1)
            p.y = min(max(p.y + d.dy / b.height, 0), 1)
            scrollPoint = p
            sendVisualTouch(0, TouchPhase.update, Double(p.x), Double(p.y))
        case .ended, .cancelled:
            // Lift only if no momentum follows; otherwise ride it out below.
            if event.momentumPhase == [] { endScrollDrag() }
        default:
            // Momentum: keep the contact down and moving so the flick reads as
            // one continuous drag rather than a drag that stops and restarts.
            guard var p = scrollPoint else { return }
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                endScrollDrag()
                return
            }
            let d = rotatedPanelDelta(dx, dy)
            p.x = min(max(p.x + d.dx / b.width, 0), 1)
            p.y = min(max(p.y + d.dy / b.height, 0), 1)
            scrollPoint = p
            sendVisualTouch(0, TouchPhase.update, Double(p.x), Double(p.y))
        }
    }

    /// One phase-less wheel event as a complete short drag.
    private func wheelFlick(_ event: NSEvent) {
        let b = contentLayer.bounds
        guard b.width > 0, b.height > 0, var p = clampedPanelPoint(event) else { return }
        let delta = Self.scrollMovement(event)
        let dx = delta.dx, dy = delta.dy
        let d = rotatedPanelDelta(dx, dy)
        sendVisualTouch(0, TouchPhase.begin, Double(p.x), Double(p.y))
        p.x = min(max(p.x + d.dx / b.width, 0), 1)
        p.y = min(max(p.y + d.dy / b.height, 0), 1)
        sendVisualTouch(0, TouchPhase.update, Double(p.x), Double(p.y))
        sendVisualTouch(0, TouchPhase.end, Double(p.x), Double(p.y))
    }

    private func endScrollDrag() {
        guard let p = scrollPoint else { return }
        sendVisualTouch(0, TouchPhase.end, Double(p.x), Double(p.y))
        scrollPoint = nil
    }

    /// A movement in view points expressed in content-layer points, un-rotated
    /// so directions match what the user sees in any orientation.
    private func rotatedPanelDelta(_ dx: CGFloat, _ dy: CGFloat) -> CGVector {
        let a = -(Self.layerAngle(emulator?.rotationDegrees ?? 0) + tiltAngle + guestTurn)  // the scan stands a quarter turn from upright when the guest turned its UI
        let s = max(appliedScale * (contentLayer.bounds.width / max(framePixels.width, 1)), 0.01)
        let ux = dx / s, uy = dy / s
        return CGVector(dx: ux * cos(a) - uy * sin(a), dy: ux * sin(a) + uy * cos(a))
    }

    // MARK: Tilt by scroll (cursor off the panel)

    private func beginScrollTilt() {
        guard touchInteractionEnabled else { return }
        wheelTiltResetTask?.cancel()
        tilt.beginScroll(rotation: emulator?.rotationDegrees ?? 0)
        shellLayer.removeAnimation(forKey: "tiltSnap")
    }

    private func scrollTiltChanged(_ event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        switch event.phase {
        case .began, .changed, []:
            // AppKit already applied Natural Scrolling. Use the same content
            // movement convention as the LCD, without inverting it again.
            tilt.scroll(by: Self.scrollMovement(event))
            setShellAngle(restAngle + tiltAngle)
            sendAttitude()
            // Wheel mice have no ended event. End a burst after a short idle
            // interval so they cannot leave the device tilted indefinitely.
            if event.phase.isEmpty {
                wheelTiltResetTask?.cancel()
                wheelTiltResetTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                    self?.endTilt()
                }
            }
        case .ended, .cancelled:
            endTilt()          // springs the shell back and restores gravity
        default:
            break
        }
    }

    /// Precise deltas are points; conventional wheels report lines. Preserve
    /// both signs because NSEvent has already honored the system preference.
    private static func scrollMovement(_ event: NSEvent) -> CGVector {
        ChassisTilt.scrollMovement(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
    }

    override func rotate(with event: NSEvent) {
        guard touchInteractionEnabled && !tilting && scrollPoint == nil && !pinchingGuest else { return }
        if event.phase == .began && (!cursorOverPanel(event) || event.modifierFlags.contains(.option)) {
            endTilt()
            tilt.beginTwist(rotation: emulator?.rotationDegrees ?? 0)
        }
        guard rotatingChassis else { return }
        if event.phase == .ended || event.phase == .cancelled { endTilt(); return }
        // NSEvent rotation is incremental counterclockwise degrees; this
        // flipped view's roll is clockwise radians. Scrolling preferences do
        // not affect a physical two-finger twist.
        tilt.twist(byDegrees: event.rotation)
        setShellAngle(restAngle + tiltAngle)
        sendAttitude()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if pressModelControl(event) { return }
        if panelResize(event) { return }
        guard touchInteractionEnabled else { return }
        // Just off the screen's edge is the screen's (an edge swipe starts there), not the chassis's.
        if normalized(event) == nil, nearScreenEdge(event) == nil, isChassisEvent(event) {
            endTilt()
            tilt.beginDrag(at: convert(event.locationInWindow, from: nil), rotation: emulator?.rotationDegrees ?? 0)
            shellLayer.removeAnimation(forKey: "tiltSnap")
            return
        }
        if let (nx, ny) = normalized(event) ?? nearScreenEdge(event) { touchPair.down(at: CGPoint(x: nx, y: ny), event.modifierFlags) }
        emit(event, TouchPhase.begin)
    }

    override func mouseDragged(with event: NSEvent) {
        if panelResize(event) { return }
        if tilting {
            // Horizontal movement steers with accelerometer roll, not yaw
            // around gravity. Use fixed deltas from the grab point so a
            // diagonal has the same response anywhere on the frame. This
            // view is flipped: dragging up matches an upward gesture.
            tilt.drag(to: convert(event.locationInWindow, from: nil))
            setShellAngle(restAngle + tiltAngle)
            sendAttitude()
            return
        }
        emit(event, TouchPhase.update)
    }

    override func mouseUp(with event: NSEvent) {
        if panelResize(event) { return }
        if tilting { endTilt(); return }
        emit(event, TouchPhase.end)
        touchPair.up()
        updatePairRings(event.modifierFlags)
    }

    override func mouseMoved(with event: NSEvent) { updatePairRings(event.modifierFlags) }
    override func mouseExited(with event: NSEvent) { updatePairRings([]) }

    /// Hover preview: the rings follow the cursor while Option is held, and
    /// Option-Shift locks their spacing (Simulator's convention).
    private func updatePairRings(_ flags: NSEvent.ModifierFlags) {
        guard !touchDown else { return }
        let point = window.flatMap { normalized(windowPoint: $0.mouseLocationOutsideOfEventStream) }.map { CGPoint(x: $0.0, y: $0.1) }
        touchPair.track(KeyModifiers(flags), at: point)
        guard touchInteractionEnabled, let point, let second = touchPair.secondFinger(for: point, KeyModifiers(flags)) else {
            showPairRings(nil); return
        }
        showPairRings((point, second))
    }

    private func showPairRings(_ pair: (CGPoint, CGPoint)?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (ring, point) in zip(pairRings, [pair?.0, pair?.1]) {
            ring.isHidden = point == nil
            if let point { ring.position = projectedPanelPoint(point) }
        }
        CATransaction.commit()
    }

    // MARK: - Tilt (drag the chassis to rotate; the accelerometer follows)
    //
    // Grabbing the shell anywhere outside the screen — bezel or corners — and
    // dragging side to side steers tilt games; dragging up/down adds pitch.
    // Both axes change the gravity vector measured by the accelerometer.
    // Release springs the shell back to rest and restores resting gravity.

    /// Radians of device tilt per point of two-finger swipe, when the cursor is
    /// off the panel. Much gentler than a drag: a swipe has no anchor to hold
    /// on to, so the same rate that feels direct under a finger feels wild here.
    /// A full trackpad sweep is a few degrees, which is the range tilt games use.
    private var tilting: Bool { tilt.tilting }
    private var tiltAngle: CGFloat { tilt.tiltAngle }   // current drag delta from rest

    /// The shell layer's rest rotation for a guest orientation, signed so 270°
    /// comes in as a single quarter turn (-π/2), not three of them — the
    /// implicit animation interpolates the transform, and the sign is what
    /// makes the swing take the short way round.
    private static func layerAngle(_ degrees: Int) -> CGFloat { ChassisTilt.layerAngle(degrees) }

    /// The shell's resting rotation for the guest's current orientation —
    /// the same angle layout() starts from.
    private var restAngle: CGFloat { tilt.restAngle(rotation: emulator?.rotationDegrees ?? 0) }

    /// The model's side buttons are hardware, like Home: they work asleep too.
    private func pressModelControl(_ event: NSEvent) -> Bool {
        guard let modelView, let control = modelView.control(at: modelView.convert(event.locationInWindow, from: nil)) else { return false }
        switch control {
        case .sleepWake: emulator?.pressLock()
        case .volumeUp: emulator?.pressVolumeUp()
        case .volumeDown: emulator?.pressVolumeDown()
        }
        return true
    }

    /// Keep direct manipulation on the chassis and guest touches on the LCD.
    private func isChassisEvent(_ event: NSEvent) -> Bool {
        if let modelView {
            return modelView.isChassis(modelView.convert(event.locationInWindow, from: nil))
        }
        // Bare, there is no chassis to grab: the empty shell around the screen is the backdrop.
        guard modelPresentationFinished, !bare, let rootLayer = layer else { return false }
        let p = convert(event.locationInWindow, from: nil)
        let sp = shellLayer.convert(p, from: rootLayer)
        return shellLayer.bounds.contains(sp) && !screenCutout.contains(sp)
    }

    /// The same transform layout() computes, at an arbitrary angle, applied
    /// without animation — this is the per-mouse-move path.
    private func motionTransform(angle: CGFloat, scale: CGFloat) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / 1400
        let flat = emulator?.motionPose == .flat
        transform = CATransform3DRotate(transform, flat ? angle - tiltAngle : angle, 0, 0, 1)
        transform = CATransform3DRotate(transform, pitchAngle, 1, 0, 0)
        transform = CATransform3DRotate(transform, flat ? tiltAngle : 0, 0, 1, 0)
        return CATransform3DScale(transform, scale, scale, 1)
    }

    private func updateModelPose(animated: Bool = false, spring: Bool = false) {
        (modelView ?? pendingModelView)?.pose(scale: appliedScale, rotation: emulator?.rotationDegrees ?? 0,
                        roll: tiltAngle, pitch: pitchAngle,
                        flat: emulator?.motionPose == .flat, animated: animated, spring: spring)
    }

    private func projectedPanelPoint(_ point: CGPoint) -> CGPoint {
        if let modelView { return convert(modelView.projectedPoint(point), from: modelView) }
        return contentLayer.convert(CGPoint(x: point.x * contentLayer.bounds.width,
                                           y: point.y * contentLayer.bounds.height), to: layer)
    }

    @objc private func levelAttitude(_ sender: Any?) { resetMotion() }
    private func sendAttitude() {
        attitudeIndicator.update(pitch: pitchAngle, roll: tiltAngle)
        attitudeIndicator.isHidden = !touchInteractionEnabled || (abs(pitchAngle) < 0.001 && abs(tiltAngle) < 0.001)
        // Flat, gravity points into the display: its screen-relative X/Y go into the sensor axes (ChassisTilt).
        let attitude = tilt.attitude(rotation: emulator?.rotationDegrees ?? 0, flat: emulator?.motionPose == .flat)
        emulator?.setTilt(angle: attitude.angle, pitch: attitude.pitch)
    }

    /// The trick is the 3D model's: 2D, Off, or a model still loading has nothing to flip.
    var canPerformSpecialTrick: Bool { modelView != nil }
    func specialTrick() { modelView?.specialTrick() }

    func resetMotion() {
        endTilt()
    }

    private func setShellAngle(_ angle: CGFloat, animated: Bool = false) {
        updateModelPose(animated: animated, spring: animated)
        shellLayer.removeAnimation(forKey: "tiltSnap")
        shellLayer.removeAnimation(forKey: "transform")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shellLayer.transform = motionTransform(angle: angle, scale: appliedScale)
        homeButton.isHidden = homeButtonHidden
        CATransaction.commit()
    }

    private func endTilt() {
        wheelTiltResetTask?.cancel()
        let from = shellLayer.presentation()?.transform ?? shellLayer.transform
        tilt.reset()
        setShellAngle(restAngle, animated: true)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: shellLayer.transform)
        spring.stiffness = 200
        spring.damping = 14
        spring.duration = spring.settlingDuration
        shellLayer.add(spring, forKey: "tiltSnap")
        // Gravity snaps straight to rest; the spring is only visual.
        // ponytail: sample the presentation layer from the display link if a
        // game ever needs to see the settle.
        sendAttitude()
    }

    /// Is a mouse-driven touch currently down in the guest? The host and the
    /// guest each keep their own idea of that, and this is what keeps the two
    /// from drifting apart.
    private var touchDown = false

    /// Send a mouse event to the guest as a touch.
    ///
    /// This used to bail whenever the cursor was outside the screen — which
    /// silently dropped the TOUCH_END of any drag that ended off the panel, and
    /// a drag that runs past the edge is the most ordinary gesture there is.
    /// The guest then believed a finger was still down forever: scrolling
    /// stopped working, and `mtt_bh`'s tracked flag (which only clears on an
    /// END) desynced so no later pinch ever began. So:
    ///
    /// - a BEGIN outside the screen is not a touch, and is dropped — but then
    ///   nothing is in flight, so the matching END is dropped too;
    /// - once down, UPDATEs clamp to the panel edge rather than vanishing,
    ///   which is also what a real finger sliding onto the bezel does;
    /// - an END is delivered whenever a touch is down, wherever the cursor is.
    private func emit(_ event: NSEvent, _ phase: Int32) {
        if phase == TouchPhase.begin {
            guard let (nx, ny) = normalized(event) ?? nearScreenEdge(event) else { return }
            touchDown = true
            send(phase, nx, ny)
            return
        }
        guard touchDown, let p = clampedPanelPoint(event) else { return }
        if phase == TouchPhase.end { touchDown = false }
        send(phase, Double(p.x), Double(p.y))
    }

    private func send(_ phase: Int32, _ nx: Double, _ ny: Double) {
        sendVisualTouch(0, phase, nx, ny)
        // Option: second finger mirrored through the panel centre (pinch).
        // Option-Shift: second finger at a locked offset (two-finger pan).
        let p = CGPoint(x: nx, y: ny)
        guard let q = touchPair.secondFinger(for: p, []) else { return }
        sendVisualTouch2(phase, Double(q.x), Double(q.y))
        showPairRings(phase == TouchPhase.end ? nil : (p, q))
    }

    // MARK: - Keyboard pointer (typing disabled)

    private let keyboardPointerLayer = CAShapeLayer()
    private var keyboardPointer = KeyboardPointer()

    private func send(_ touch: KeyboardPointer.Touch?) {
        guard let touch else { return }
        let phase = switch touch.phase { case .begin: TouchPhase.begin; case .update: TouchPhase.update; case .end: TouchPhase.end }
        sendVisualTouch(0, phase, touch.point.x, touch.point.y, keyboard: true)
    }

    private func endKeyboardTouch() { send(keyboardPointer.end()) }

    /// Tab out of the screen (KeyboardPointer.focusMove).
    private func moveFocusOut(_ event: NSEvent) -> Bool {
        switch KeyboardPointer.focusMove(keyCode: event.keyCode, modifiers: KeyModifiers(event.modifierFlags),
                                         typingOff: emulator?.keyboardInputEnabled == false) {
        case .next?: window?.selectNextKeyView(self)
        case .previous?: window?.selectPreviousKeyView(self)
        case nil: return false
        }
        return true
    }

    private func keyboardPointerKey(_ event: NSEvent, down: Bool) -> Bool {
        let (handled, touches) = keyboardPointer.key(event.keyCode, down: down, modifiers: KeyModifiers(event.modifierFlags),
                                                     typingOff: emulator?.keyboardInputEnabled == false,
                                                     canTouch: touchInteractionEnabled && !touchDown && !pinchingGuest && scrollPoint == nil)
        touches.forEach(send)
        return handled
    }

    private func updateKeyboardPointer() {
        let active = touchInteractionEnabled && emulator?.keyboardInputEnabled == false && window?.isKeyWindow == true && window?.firstResponder === self
        if !active { endKeyboardTouch() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        keyboardPointerLayer.isHidden = !active || !keyboardPointer.isShown
        if active { keyboardPointerLayer.position = projectedPanelPoint(keyboardPointer.point) }
        CATransaction.commit()
    }

    // MARK: - Keyboard passthrough

    private var consumedWakeSpace = false
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           consumedWakeSpace || (emulator?.isSleeping == true && emulator?.acceptsInput == true) {
            if !consumedWakeSpace && !event.isARepeat { emulator?.pressLock() }
            consumedWakeSpace = true
            return
        }
        if isShowingLiveText {
            if event.keyCode == 53 { endLiveText() }
            else { super.keyDown(with: event) }
            return
        }
        if moveFocusOut(event) { return }
        // Command combinations belong to the menu bar; let them pass.
        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            super.keyDown(with: event)
            return
        }
        if keyboardPointerKey(event, down: true) { return }
        if !hasMarkedText(), GuestKeyboard.passesThrough(keyCode: event.keyCode, characters: event.characters,
                                                          shift: event.modifierFlags.contains(.shift),
                                                          inputSource: inputContext?.selectedKeyboardInputSource) {
            pressKey(event.keyCode)
        } else {
            // Another layout, a dead key or an input method: the text input system composes, insertText sends.
            keyInText = event
            inputContext?.handleEvent(event)
            keyInText = nil
        }
    }

    // MARK: - Held keys and composed text

    private var heldKeys = HeldKeys()
    private var keyInText: NSEvent?
    private var markedText = NSMutableAttributedString()

    private func pressKey(_ code: UInt16) {
        heldKeys.press(code)
        emulator?.sendKey(macKeyCode: code, down: true)
    }

    /// Focus left the screen (another view, window or app): every key the guest has down goes up.
    @objc func releaseHeldKeys() {
        for code in heldKeys.releaseAll() { emulator?.sendKey(macKeyCode: code, down: false) }
        if hasMarkedText() { inputContext?.discardMarkedText(); unmarkText() }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 && consumedWakeSpace { consumedWakeSpace = false; return }
        if !keyboardPointer.touchKeys.isEmpty, keyboardPointerKey(event, down: false) { return }
        if isShowingLiveText { return }
        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            super.keyUp(with: event)
            return
        }
        if keyboardPointerKey(event, down: false) { return }
        if heldKeys.release(event.keyCode) { emulator?.sendKey(macKeyCode: event.keyCode, down: false) }
    }

    override func flagsChanged(with event: NSEvent) {
        // Shift and Option only ever arrive here, never as keyDown, so the
        // guest keyboard missed them (no capitals, no "!"). Command and
        // Control stay with the menu bar. sendKey lets key-ups through while
        // input is off, so a modifier can't stick down.
        let down: Bool?
        switch event.keyCode {
        case 56, 60: down = event.modifierFlags.contains(.shift)
        case 58, 61: down = event.modifierFlags.contains(.option)
        default: down = nil
        }
        if let down {
            if down { heldKeys.press(event.keyCode) } else { _ = heldKeys.release(event.keyCode) }
            emulator?.sendKey(macKeyCode: event.keyCode, down: down)
        }
        updatePairRings(event.modifierFlags)
        send(keyboardPointer.modifiersChanged(KeyModifiers(event.modifierFlags)))
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        releaseHeldKeys()
        endKeyboardTouch()
        resetMotion()
        return super.resignFirstResponder()
    }

    // MARK: - Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropHighlight.show(for: dropOperation(sender)) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropHighlight.show(for: dropOperation(sender)) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight.show(for: []) }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlight.show(for: []) }
    private lazy var dropHighlight = DropHighlight.install(in: self)

    private func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Refuse at the drag system, not with an alert per file. During the boot
        // the menu and toolbar items for this same operation are correctly
        // greyed out, but the drop still showed the green copy badge, accepted,
        // and then queued one "The device isn't ready yet" sheet per .ipa to be
        // dismissed one at a time.
        // An IPSW is for the library, not this device: any time, from outside.
        if sender.draggingSource == nil, onDropIPSW != nil, !dropped(sender, .ipsw).isEmpty {
            sender.numberOfValidItemsForDrop = dropped(sender, .ipsw).count
            return .copy
        }
        guard emulator?.canQueueInstall == true else { return [] }
        let catalog = droppedCatalogApps(sender)
        if !catalog.isEmpty, onDropCatalogApp != nil {
            sender.numberOfValidItemsForDrop = catalog.count
            return .copy
        }
        // Local drags carry .fileURL too (an installed row is draggable to
        // the Finder as its .ipa), but dropping one back on the device would
        // just reinstall what's already there — only OUTSIDE files install.
        guard sender.draggingSource == nil else { return [] }
        let count = (onDropIPA == nil ? 0 : dropped(sender, .ipa).count)
            + (onDropMedia == nil ? 0 : dropped(sender, .media).count)
        guard count > 0 else { return [] }
        sender.numberOfValidItemsForDrop = count
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Readiness can change after the drag entered. Never animate a
        // successful drop when its owner will reject the import.
        guard dropOperation(sender) == .copy else { return false }
        let ipsws = dropped(sender, .ipsw)
        if sender.draggingSource == nil, let onDropIPSW, !ipsws.isEmpty {
            ipsws.forEach(onDropIPSW)
            return true
        }
        let catalog = droppedCatalogApps(sender)
        if !catalog.isEmpty, let onDropCatalogApp {
            catalog.forEach(onDropCatalogApp)
            return true
        }
        guard sender.draggingSource == nil else { return false }
        let ipas = dropped(sender, .ipa)
        let media = dropped(sender, .media)
        guard !ipas.isEmpty || !media.isEmpty else { return false }
        ipas.forEach { onDropIPA?($0) }   // AppInstaller queues them
        media.forEach { onDropMedia?($0) }
        return true
    }

    private func dropped(_ sender: NSDraggingInfo, _ kind: DroppedFiles) -> [URL] {
        DroppedFiles.files(sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [], kind)
    }

    /// Store rows dragged from the inspector: decode the private payload.
    private func droppedCatalogApps(_ sender: NSDraggingInfo) -> [CatalogApp] {
        (sender.draggingPasteboard.pasteboardItems ?? []).compactMap { item in
            item.data(forType: .ltmCatalogApp)
                .flatMap { try? JSONDecoder().decode(CatalogApp.self, from: $0) }
        }
    }
}

/// The shell's home button: invisible until pressed, then a soft black circle
/// — drawn directly rather than via a bezel/image since it sits on shell
/// artwork with a shape (and press state) no stock NSButton style covers.
/// The touch phases of qemu-ios-ui.h (LinkCommand.touch).
private enum TouchPhase {
    static let begin: Int32 = 0, update: Int32 = 1, end: Int32 = 2
}

private final class HomeButton: NSButton {
    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityLabel("Home")
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(isHighlighted ? 0.5 : 0).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

// Composed text (input methods, dead keys, other layouts) reaches the guest as text: EmulatorController.typeText.
// The composition itself isn't drawn here; the input method's own window shows it beside the screen.
extension DisplayView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        markedText = NSMutableAttributedString()
        emulator?.typeText(text, shiftHeld: heldKeys.down.contains(56) || heldKeys.down.contains(60))
    }
    /// A key the input system didn't turn into text (Return or an arrow with nothing composed): as itself.
    override func doCommand(by selector: Selector) {
        if let keyInText { pressKey(keyInText.keyCode) }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = NSMutableAttributedString(attributedString: (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? ""))
    }
    func unmarkText() { markedText = NSMutableAttributedString() }
    func selectedRange() -> NSRange { NSRange(location: markedText.length, length: 0) }
    func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let clipped = Range(range, in: markedText.string).map({ NSRange($0, in: markedText.string) }) else { return nil }
        actualRange?.pointee = clipped
        return markedText.attributedSubstring(from: clipped)
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    /// The candidate window sits under the screen's lower middle.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let anchor = NSRect(x: bounds.midX, y: bounds.minY + bounds.height * 0.25, width: 1, height: 20)
        return window?.convertToScreen(convert(anchor, to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
