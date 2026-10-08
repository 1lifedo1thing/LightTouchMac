import Cocoa
import LightTouchCore

// The device's size in the pane: the scale each ZoomMode (Fit, Physical Size, the pixel-accurate steps) gives the
// shell, and how the guest's pixels are filtered at it.

extension DisplayView {
    /// Points of breathing room between the shell and the pane edge when
    /// zoomed. A flat inset, not a fraction of the pane: 0.85 of the pane threw
    /// away 15% of a 1400-point window — over 200 points of black — to leave the
    /// same visual margin an 8-point gap gives.
    ///
    /// Wide enough that the shell's shadow has somewhere to fall.
    static let zoomInset: CGFloat = 16

    var physicalScale: CGFloat? {
        guard let window else { return nil }
        let center = window.convertPoint(toScreen: convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? window.screen
        return screen.flatMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).flatMap {
                DisplayMeasurements.pointsPerMillimeter(
                    display: CGDirectDisplayID($0.uint32Value),
                    logical: screen.frame.size
                )
            }
        }.map {
            let height = profile.physicalHeightMillimeters * $0
            return modelView?.physicalScale(heightInPoints: height) ?? height / shellPixels.height
        }
    }

    @objc func screenChanged() {
        if zoom == .physical, physicalScale == nil {
            zoom = .fit
            onPhysicalSizeUnavailable?()
        }
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        screenChanged()
    }

    /// The shell's scale for the current zoom, given its on-screen bounding box in display pixels.
    func zoomScale(fitting shellOnScreenPixels: CGSize) -> CGFloat {
        if let dragScale { return dragScale }  // an edge drag keeps its scale, so the edge stays under the pointer
        switch zoom {
        case .pixels(let points) where freeFormActive:
            return CGFloat(points)  // free-form Nx: a guest pixel is N points (Sam's "at 1x a point is a pixel")
        case .physical where freeFormActive:
            // Free-form's shell unit is a guest pixel: the shipped panel's pixel pitch, at its physical size.
            return physicalScale.map { $0 * profile.screenCutout.height / profile.uprightScreenPixels.height }
                ?? fitScale(shellOnScreenPixels)
        case .fit:
            return fitScale(shellOnScreenPixels)
        case .physical:
            return physicalScale ?? fitScale(shellOnScreenPixels)
        case .pixels(let multiple):
            return shellScale(guestPixelsPerDisplayPixel: multiple)
        }
    }

    /// Scale is independent of a framebuffer arriving before or after rotation.
    var pixelMultiple: CGFloat {
        // Free-form steps in points per guest pixel, the unit its Nx is in.
        ZoomMode.pixelMultiple(
            appliedScale: appliedScale,
            cutoutWidth: screenCutout.width,
            nativeWidth: nativeScreenPixels.width,
            backingScale: window?.backingScaleFactor ?? 2,
            freeForm: freeFormActive
        )
    }

    /// Whole display pixels per guest pixel stay crisp (nearest); between the steps (Fit, Physical Size)
    /// nearest would draw guest pixels one or two display pixels wide, so those are filtered (linear).
    static func contentsFilter(_ pixelMultiple: CGFloat) -> CALayerContentsFilter {
        ZoomMode.drawsNearest(pixelMultiple) ? .nearest : .linear
    }

    private func shellScale(guestPixelsPerDisplayPixel multiple: Int) -> CGFloat {
        ZoomMode.shellScale(
            guestPixelsPerDisplayPixel: multiple,
            cutoutWidth: screenCutout.width,
            nativeWidth: nativeScreenPixels.width,
            backingScale: window?.backingScaleFactor ?? 2
        )
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
}
