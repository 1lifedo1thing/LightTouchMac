import CoreGraphics
import Foundation

/// The device window's zoom: Fit, Physical Size, or N display pixels per guest pixel (Pixel Accurate is 1).
nonisolated public enum ZoomMode: Equatable, Sendable {
    case fit
    case physical
    case pixels(Int)

    public static let steps = [1, 2, 3, 4, 6, 8]
    public static let defaultsKey = "zoomMode"

    public var percent: Int? {
        guard case .pixels(let n) = self else { return nil }
        return n * 100
    }

    /// One notch along the ladder (the pinch, ⌘+ / ⌘−) from `pixelMultiple`, what the screen shows now: stepping
    /// out of Fit starts from whatever size Fit happens to be showing, so the first press nudges the device rather
    /// than jumping it; the ends of the ladder stay put.
    public static func step(from pixelMultiple: CGFloat, direction: Int) -> ZoomMode {
        .pixels(
            direction > 0
                ? steps.first { CGFloat($0) > pixelMultiple + 0.001 } ?? steps.last!
                : steps.last { CGFloat($0) < pixelMultiple - 0.001 } ?? steps.first!
        )
    }

    /// The saved form ("fit", "physical", "pixels:N").
    public var defaultsValue: String {
        switch self {
        case .fit: "fit"
        case .physical: "physical"
        case .pixels(let n): "pixels:\(n)"
        }
    }

    /// A saved zoom; anything unknown, or a multiple off the ladder, is Fit.
    public init(defaultsValue: String?) {
        switch defaultsValue {
        case "physical": self = .physical
        case let s? where s.hasPrefix("pixels:"):
            self = Int(s.dropFirst("pixels:".count)).flatMap { Self.steps.contains($0) ? .pixels($0) : nil } ?? .fit
        default: self = .fit
        }
    }

    /// Guest pixels per display pixel for a shell drawn at `appliedScale` points per shell pixel: the shell's
    /// `cutoutWidth` pixels show the panel's `nativeWidth` guest pixels. Free-form's scale is already points per
    /// guest pixel, the unit its Nx is in.
    public static func pixelMultiple(
        appliedScale: CGFloat,
        cutoutWidth: CGFloat,
        nativeWidth: CGFloat,
        backingScale: CGFloat,
        freeForm: Bool
    ) -> CGFloat {
        freeForm ? appliedScale : appliedScale * cutoutWidth / nativeWidth * backingScale
    }

    /// The shell scale that shows `multiple` display pixels per guest pixel (pixelMultiple's inverse).
    public static func shellScale(
        guestPixelsPerDisplayPixel multiple: Int,
        cutoutWidth: CGFloat,
        nativeWidth: CGFloat,
        backingScale: CGFloat
    ) -> CGFloat {
        CGFloat(multiple) / backingScale * nativeWidth / cutoutWidth
    }

    /// Whole display pixels per guest pixel stay crisp (nearest); between the steps (Fit, Physical Size) nearest
    /// would draw guest pixels one or two display pixels wide, so those are filtered (linear).
    public static func drawsNearest(_ pixelMultiple: CGFloat) -> Bool {
        abs(pixelMultiple - pixelMultiple.rounded()) < 0.01
    }
}
