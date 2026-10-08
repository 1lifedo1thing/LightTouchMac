// The app's rotation for `turn` and `shot`: DeviceRotation (the shell's angle and the machine's control, as the app
// sends it for this board) and the picture as the window shows it (PanelCapture), for `sessions rotation`.

import CoreGraphics
import DeviceRuntime
import Foundation
import HostRuntime
import ImageIO
import LightTouchCore
import UniformTypeIdentifiers
import Vision

/// The driver's link with replies on the main queue, where the app's link delivers them (BootSessionScope.control).
final class MainQueueLink: HelperLink {
    let link: DeviceLink
    init(_ link: DeviceLink) { self.link = link }
    func send(_ command: LinkCommand) { link.send(command) }
    func request(_ request: LinkRequest, timeout: TimeInterval, reply: @escaping DeviceLink.Reply) {
        link.request(request, timeout: timeout) { result in DispatchQueue.main.async { reply(result) } }
    }
}

@MainActor final class RotationDriver: RotationHost {
    let bootScope = BootSessionScope()
    let mainLink: MainQueueLink
    var helperLink: HelperLink? { mainLink }
    var state: VMState = .running
    var preparingDevice = false, isSleeping = false, isInstalling = false, canReachDevice = false
    func interfaceOrientation() async throws -> Int { throw CancellationError() }
    func guestOrientation() async throws -> Int? { nil }

    let board: Board
    let scan: CGSize
    var rotation: DeviceRotation!

    init(link: DeviceLink, board: Board, scan: CGSize, settings: URL) {
        mainLink = MainQueueLink(link)
        self.board = board
        self.scan = scan
        rotation = DeviceRotation(
            host: self,
            settings: DeviceSettingsFile(directory: settings),
            setsAccelerometer: board.orientationSource == .springBoard  // as EmulatorController
        )
    }

    /// Quarter turns clockwise from the published frame to the window's picture.
    var turns: Int {
        PanelCapture.quarterTurns(
            guestTurn: Board.guestTurn(scan: scan),
            deviceDegrees: rotation.degrees,
            surfaceFollowsRotation: board.surfaceFollowsRotation
        )
    }

    /// A point on the window's picture (0...1, top-left origin) as the touch the app sends: over the surface as
    /// published, so the inverse of `turns`.
    func touchPoint(shown u: Double, _ v: Double) -> (Double, Double) {
        switch turns {
        case 1: (v, 1 - u)
        case 2: (1 - u, 1 - v)
        case 3: (1 - v, u)
        default: (u, v)
        }
    }

    /// The dumped frame at `source` turned as the window shows it, written to `destination`.
    func writeShown(_ source: URL, to destination: URL) -> Bool {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(input, 0, nil),
            let shown = PanelCapture.rotated(image, clockwiseQuarterTurns: turns),
            let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(output, shown, nil)
        return CGImageDestinationFinalize(output)
    }
}

/// Where Vision reads `word` on an image (top-left origin, 0...1): the first text equal to it, or nil.
func findWord(_ word: String, in image: URL) -> (x: Double, y: Double)? {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    guard (try? VNImageRequestHandler(url: image).perform([request])) != nil else { return nil }
    for o in request.results ?? [] {
        guard o.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) == word else { continue }
        return (o.boundingBox.midX, 1 - o.boundingBox.midY)
    }
    return nil
}
