/// The Space bar as a capture key (CapturePreferences.spaceBarAction): a press on the device screen captures once,
/// its repeats and its release are swallowed with it, and everything else passes on to the device or the system.
public struct SpaceBarCapture {
    public enum Outcome: Equatable { case pass, swallow, capture(CaptureSpaceBarAction) }

    /// The press that captured is still down: its repeats and release are ours.
    public private(set) var consumed = false

    public init() {}

    /// `eligible`: the device window is key with no sheet or modal, its screen has focus and isn't selecting text.
    public mutating func key(_ keyCode: UInt16, down: Bool, isRepeat: Bool, modifiers: KeyModifiers, eligible: Bool,
                             action: CaptureSpaceBarAction) -> Outcome {
        guard keyCode == 49 else { return .pass }
        if !down {
            guard consumed else { return .pass }
            consumed = false
            return .swallow
        }
        if isRepeat, consumed { return .swallow }
        if !isRepeat { consumed = false }
        guard eligible, modifiers.isEmpty, action != .none else { return .pass }
        guard !isRepeat else { return .pass }
        consumed = true
        return .capture(action)
    }
}
