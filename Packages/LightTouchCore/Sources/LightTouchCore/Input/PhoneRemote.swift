// A phone's browser as the device (Device ▸ Play on Phone…): its orientation becomes the accelerometer's
// gravity, its touches the panel's, and it shows the panel the way the device is held. The math, without the
// server and page (PhoneRemoteController in the app).

import CoreGraphics
import DeviceRuntime
import Foundation

public enum PhoneRemote {
    /// The phone's `deviceorientation` beta and gamma (degrees, W3C axes: iOS's) as the emulator's flat-pose attitude.
    /// The phone's gravity is (cos β sin γ, −sin β, −cos β cos γ); qemu-ios's ipod_attitude_gravity, flat, is
    /// (−sin r cos p, sin p, −cos r cos p), which the guest reads as it is (the roll the chassis tilt sends is negated
    /// for the same reason, ChassisTilt.attitudeCommand), so every way the phone is held is one roll and pitch, upright
    /// and upside down included.
    public static func attitude(beta: Double, gamma: Double) -> LinkCommand {
        let b = beta * .pi / 180
        let g = gamma * .pi / 180
        let x = cos(b) * sin(g)
        let y = -sin(b)
        let z = -cos(b) * cos(g)
        return .attitude(pitch: asin(y) * 180 / .pi, roll: atan2(-x, -z) * 180 / .pi, pose: 1)
    }

    /// Clockwise quarter-turns from the published surface to the panel as it sits in the upright device: the scan to
    /// upright, less the device's own turn where the surface follows it. PanelCapture's window turns, without the shell's.
    public static func quarterTurns(guestTurn: CGFloat, deviceDegrees: Int, surfaceFollowsRotation: Bool) -> Int {
        let device = surfaceFollowsRotation ? deviceDegrees / 90 : 0
        return ((Int((guestTurn * 2 / .pi).rounded()) - device) % 4 + 4) % 4
    }

    /// A point on the phone's picture (normalized, y down) on the surface it was turned from by `turns`.
    public static func surfacePoint(_ p: CGPoint, turns: Int) -> CGPoint {
        switch turns {
        case 1: CGPoint(x: p.y, y: 1 - p.x)
        case 2: CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 3: CGPoint(x: 1 - p.y, y: p.x)
        default: p
        }
    }
}
