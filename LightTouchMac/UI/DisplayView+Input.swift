import Cocoa
import DeviceRuntime
import HostRuntime
import LightTouchCore

extension DisplayView {
    // MARK: - Touch input

    /// Normalize a point to 0…1 over the panel content. The content layer sits
    /// inside the shell's scale+rotation transform, so convert through the
    /// layer tree rather than reading a frame. Returns nil for clicks outside
    /// it. (The emulator un-rotates touches itself — ipod_touch_lcd_map_touch —
    /// so coordinates over the surface as published are exactly what it wants.)
    func normalized(_ event: NSEvent) -> (Double, Double)? { normalized(windowPoint: event.locationInWindow) }

    func normalized(windowPoint: NSPoint) -> (Double, Double)? {
        if let modelView {
            guard let p = modelView.panelPoint(modelView.convert(windowPoint, from: nil)) else { return nil }
            return (Double(p.x), Double(p.y))
        }
        guard let rootLayer = layer else { return nil }
        let p = convert(windowPoint, from: nil)
        let cp = contentLayer.convert(p, from: rootLayer)
        let b = contentLayer.bounds
        guard b.width > 0, b.height > 0, b.contains(cp) else { return nil }
        return (Double(cp.x / b.width), Double(cp.y / b.height))  // isFlipped → y-down
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

    var pitchAngle: CGFloat { tilt.pitchAngle }
    private var rotatingChassis: Bool { tilt.rotatingChassis }

    var motionRestAngle: CGFloat? { tilt.motionRestAngle }
    private var scrollTilting: Bool { tilt.scrollTilting }

    /// How far outside the screen, in points, a press still lands on its edge: edge swipes (Notification Center,
    /// back swipes) start at the glass's border, where a pointer easily misses by a few points.
    static let screenEdgeMargin: CGFloat = 14

    /// A press within `screenEdgeMargin` of the screen, clamped onto its edge; nil on the screen itself or farther
    /// out. Probes the margin around the point through the same mapping as `normalized`, so it holds for the 3D
    /// model, the flat shell and any rotation or zoom.
    func nearScreenEdge(_ event: NSEvent) -> (Double, Double)? {
        let point = event.locationInWindow
        let m = Self.screenEdgeMargin
        let probes = [(-m, 0), (m, 0), (0, -m), (0, m), (-m, -m), (m, -m), (-m, m), (m, m)]
        guard normalized(windowPoint: point) == nil,
            probes.contains(where: { normalized(windowPoint: NSPoint(x: point.x + $0.0, y: point.y + $0.1)) != nil }),
            let p = clampedPanelPoint(event)
        else { return nil }
        return (Double(p.x), Double(p.y))
    }

    /// The panel-space point under the cursor, clamped into the panel. Unlike
    /// `normalized` this does not fail when the cursor is just outside — a pinch
    /// that drifts off the edge mid-gesture should keep tracking, not stop dead.
    func clampedPanelPoint(_ event: NSEvent) -> CGPoint? {
        if let modelView {
            return modelView.panelPoint(modelView.convert(event.locationInWindow, from: nil), clamped: true)
        }
        guard let rootLayer = layer else { return nil }
        let cp = contentLayer.convert(convert(event.locationInWindow, from: nil), from: rootLayer)
        let b = contentLayer.bounds
        guard b.width > 0, b.height > 0 else { return nil }
        return CGPoint(x: min(max(cp.x / b.width, 0), 1), y: min(max(cp.y / b.height, 0), 1))
    }

    /// Is the cursor over the device's screen right now?
    private func cursorOverPanel(_ event: NSEvent) -> Bool { normalized(event) != nil }

    // MARK: - Pinch

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
            pinchSpread = 0.12  // a comfortable starting separation
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
        let x1 = min(max(a.x - pinchSpread, 0), 1)
        let x2 = min(max(a.x + pinchSpread, 0), 1)
        sendVisualTouch(0, phase, Double(x1), Double(a.y))
        sendVisualTouch2(phase, Double(x2), Double(a.y))
    }

    // MARK: - Two-finger double tap

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

    // MARK: - Scroll / swipe

    /// Over the panel, a two-finger scroll IS a finger dragging the content:
    /// begin a touch where the cursor is and move it with the fingers, through
    /// momentum too, so a flick keeps traveling and iOS's own inertia takes
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
        if scrollPoint == nil && !scrollTilting
            && (event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty))
            && (!cursorOverPanel(event) || event.modifierFlags.contains(.option))
        {
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
        let dx = delta.dx
        let dy = delta.dy
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
        // the scan stands a quarter turn from upright when the guest turned its UI
        let a = -(Self.layerAngle(emulator?.rotationDegrees ?? 0) + tiltAngle + guestTurn)
        let s = max(appliedScale * (contentLayer.bounds.width / max(framePixels.width, 1)), 0.01)
        let ux = dx / s
        let uy = dy / s
        return CGVector(dx: ux * cos(a) - uy * sin(a), dy: ux * sin(a) + uy * cos(a))
    }

    // MARK: - Tilt by scroll (cursor off the panel)

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
            endTilt()  // springs the shell back and restores gravity
        default:
            break
        }
    }

    /// Precise deltas are points; conventional wheels report lines. Preserve
    /// both signs because NSEvent has already honored the system preference.
    private static func scrollMovement(_ event: NSEvent) -> CGVector {
        ChassisTilt.scrollMovement(
            dx: event.scrollingDeltaX,
            dy: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas
        )
    }

    override func rotate(with event: NSEvent) {
        guard touchInteractionEnabled && !tilting && scrollPoint == nil && !pinchingGuest else { return }
        if event.phase == .began && (!cursorOverPanel(event) || event.modifierFlags.contains(.option)) {
            endTilt()
            tilt.beginTwist(rotation: emulator?.rotationDegrees ?? 0)
        }
        guard rotatingChassis else { return }
        if event.phase == .ended || event.phase == .cancelled {
            endTilt()
            return
        }
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
        if let (nx, ny) = normalized(event) ?? nearScreenEdge(event) {
            touchPair.down(at: CGPoint(x: nx, y: ny), event.modifierFlags)
        }
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
        if tilting {
            endTilt()
            return
        }
        emit(event, TouchPhase.end)
        touchPair.up()
        updatePairRings(event.modifierFlags)
    }

    override func mouseMoved(with event: NSEvent) { updatePairRings(event.modifierFlags) }
    override func mouseExited(with event: NSEvent) { updatePairRings([]) }

    /// Hover preview: the rings follow the cursor while Option is held, and
    /// Option-Shift locks their spacing (Simulator's convention).
    func updatePairRings(_ flags: NSEvent.ModifierFlags) {
        guard !touchDown else { return }
        let point = window.flatMap { normalized(windowPoint: $0.mouseLocationOutsideOfEventStream) }.map {
            CGPoint(x: $0.0, y: $0.1)
        }
        touchPair.track(KeyModifiers(flags), at: point)
        guard touchInteractionEnabled, let point, let second = touchPair.secondFinger(for: point, KeyModifiers(flags))
        else {
            showPairRings(nil)
            return
        }
        showPairRings((point, second))
    }

    func showPairRings(_ pair: (CGPoint, CGPoint)?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (ring, point) in zip(pairRings, [pair?.0, pair?.1]) {
            ring.isHidden = point == nil
            if let point { ring.position = projectedPanelPoint(point) }
        }
        CATransaction.commit()
    }
}
