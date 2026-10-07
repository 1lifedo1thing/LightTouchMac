import CoreGraphics
import Testing
@testable import LightTouchCore

/// Zoom: pixel scale at either backing scale, nearest at whole steps and linear between, the ladder's steps out of
/// Fit and its ends, and the saved zoom (Pixel Accurate comes back as itself, not as Physical Size).
struct ZoomModeTests {
    // The iPod's panel and shell cutout.
    let native: CGFloat = 320, cutout: CGFloat = 594

    func multiple(_ applied: CGFloat, backing: CGFloat = 2) -> CGFloat {
        ZoomMode.pixelMultiple(appliedScale: applied, cutoutWidth: cutout, nativeWidth: native, backingScale: backing, freeForm: false)
    }
    func scale(_ step: Int, backing: CGFloat = 2) -> CGFloat {
        ZoomMode.shellScale(guestPixelsPerDisplayPixel: step, cutoutWidth: cutout, nativeWidth: native, backingScale: backing)
    }

    @Test(arguments: [1.0, 2.0] as [CGFloat])
    func everyStepIsItsMultipleAndCrisp(backing: CGFloat) {
        for step in ZoomMode.steps {
            let m = multiple(scale(step, backing: backing), backing: backing)
            #expect(abs(m - CGFloat(step)) < 0.00001)
            #expect(ZoomMode.drawsNearest(m), "a whole step is drawn crisp")
        }
    }

    @Test func freeFormScaleIsAlreadyPointsPerGuestPixel() {
        #expect(ZoomMode.pixelMultiple(appliedScale: 3, cutoutWidth: cutout, nativeWidth: native, backingScale: 2, freeForm: true) == 3)
    }

    @Test func fractionalFitIsFiltered() {
        #expect(!ZoomMode.drawsNearest(multiple(scale(2) * 1.37)), "a fractional Fit is filtered")
    }

    @Test func stepsFromFitAndAtTheEnds() {
        let between = multiple(scale(2) * 1.2)
        #expect(ZoomMode.step(from: between, direction: 1) == .pixels(3))
        #expect(ZoomMode.step(from: between, direction: -1) == .pixels(2))
        #expect(ZoomMode.step(from: multiple(scale(2)), direction: 1) == .pixels(3), "from a step, the next one")
        #expect(ZoomMode.step(from: multiple(scale(8)), direction: 1) == .pixels(8))
        #expect(ZoomMode.step(from: multiple(scale(1)), direction: -1) == .pixels(1))
    }

    @Test(arguments: [ZoomMode.fit, .physical, .pixels(1), .pixels(3)])
    func savedZoomComesBackAsItself(_ mode: ZoomMode) {
        #expect(ZoomMode(defaultsValue: mode.defaultsValue) == mode)
    }

    @Test func unknownSavedZoomIsFit() {
        for value in [nil, "", "pixels:5", "pixels:x", "zoom"] as [String?] { #expect(ZoomMode(defaultsValue: value) == .fit) }
    }
}
