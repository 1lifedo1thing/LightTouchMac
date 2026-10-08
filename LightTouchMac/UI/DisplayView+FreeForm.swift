import Cocoa
import DeviceRuntime
import HostRuntime
import LightTouchCore

extension DisplayView {
    // MARK: - Free-form screen (issue #21)
    //
    // View ▸ Free-Form Screen: no bezel, and the screen itself is resizable. Dragging the screen's own edge or
    // corner (nothing else: not the window, the sidebar or the inspector) stretches the current frame to the new
    // size live, with a W × H status snapped to what the board's panel= accepts. Zoom only draws it bigger or
    // smaller: Nx is N points per guest pixel, Fit scales the panel into the pane, Physical gives a guest pixel the
    // shipped panel's physical pitch. Like the shipped screen's, a screen bigger than the pane is clipped, centered. A second after the drag ends the size is recorded and, if it changed, the
    // device restarts at it (Stop's hard halt, then a fresh helper): UIKit takes the panel's size at boot only.
    // The squished frame stays up, through the next session's view (`handoffs`), until the new boot's first frame.

    var freeFormActive: Bool { freeFormPanel != nil || freeFormTarget != nil }
    /// The running scan's scan-to-upright turn (Board.guestTurn): the shipped panel's, or the free-form one's.
    var guestTurn: CGFloat { runningScan.map(Board.guestTurn(scan:)) ?? profile.panelRotation }

    var isFreeForm: Bool { freeFormPanel != nil }
    var canToggleFreeForm: Bool { profile.supportsFreeForm && !restartingAtPanel }

    static var panelCommitDelay: Duration = .seconds(1)
    /// The last frame of a device restarting at a new panel, for that device's next view.
    private static var handoffs: [UUID: CGImage] = [:]

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
        // One shell unit per guest pixel, centered where the shipped screen sits.
        nativeScreenPixels = size
        let center = CGPoint(x: profile.screenCutout.midX, y: profile.screenCutout.midY)
        screenCutout = CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Upright ⇄ as seen: the device's quarter-turns swap the sides.
    private func onScreen(_ size: CGSize) -> CGSize {
        (emulator?.rotationDegrees ?? 0) % 180 != 0 ? CGSize(width: size.height, height: size.width) : size
    }

    static func text(_ size: CGSize) -> String { "\(Int(size.width)) × \(Int(size.height))" }

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
        let r = contentLayer.convert(contentLayer.bounds, to: root)
        let band: CGFloat = 10
        guard r.insetBy(dx: -band, dy: -band).contains(p), !r.contains(p) else { return nil }
        return CGVector(dx: p.x < r.minX ? -1 : p.x > r.maxX ? 1 : 0, dy: p.y < r.minY ? -1 : p.y > r.maxY ? 1 : 0)
    }

    /// The mouse on the free-form screen's edge: a press there grabs it, a drag resizes, the release ends it.
    /// True when the event was the resize's (not a touch).
    func panelResize(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            guard let edges = panelEdges(at: p) else { return false }
            beginPanelResize()
            panelDrag = (p, edges, onScreen(freeFormTarget ?? profile.uprightScreenPixels))
        case .leftMouseDragged:
            guard let drag = panelDrag, let scale = dragScale else { return false }
            // The screen stays centered: an edge moves half the size change, so the size changes twice the pointer's.
            updatePanelTarget(
                onScreen: CGSize(
                    width: drag.size.width + 2 * (p.x - drag.origin.x) * drag.edges.dx / scale,
                    height: drag.size.height + 2 * (p.y - drag.origin.y) * drag.edges.dy / scale
                )
            )
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
            if target != freeFormPanel { runningScan = profile.scan(upright: target) }  // recorded for the next start
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
        let r = contentLayer.convert(contentLayer.bounds, to: root)
        let band: CGFloat = 10
        addCursorRect(CGRect(x: r.minX - band, y: r.minY, width: band, height: r.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: r.maxX, y: r.minY, width: band, height: r.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: r.minX, y: r.minY - band, width: r.width, height: band), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: r.minX, y: r.maxY, width: r.width, height: band), cursor: .resizeUpDown)
        for x in [r.minX - band, r.maxX] {
            for y in [r.minY - band, r.maxY] {
                addCursorRect(CGRect(x: x, y: y, width: band, height: band), cursor: .crosshair)
            }
        }
    }
}
