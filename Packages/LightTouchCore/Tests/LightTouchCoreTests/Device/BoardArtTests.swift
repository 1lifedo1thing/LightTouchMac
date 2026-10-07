import CoreGraphics
import Foundation
import HostRuntime
import ImageIO
import Testing
@testable import LightTouchCore

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../..").standardizedFileURL

/// An asset's pixels, decoded as 8-bit RGBA in the image's own colour space (no conversion).
private struct Pixels {
    let width: Int, height: Int
    private let bytes: [UInt8]

    init(_ url: URL) throws {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        (self.width, self.height, self.bytes) = (width, height, bytes)
    }

    /// (r, g, b) at a top-left-origin pixel.
    func rgb(_ x: Int, _ y: Int) -> [Int] { let i = (y * width + x) * 4; return (0..<3).map { Int(bytes[i + $0]) } }
    /// The brightest luma (ITU-R 601) in a top-left-origin rect.
    func maxLuma(_ rect: CGRect) -> Double {
        var best = 0.0
        for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) {
            let c = rgb(x, y); best = max(best, 0.299 * Double(c[0]) + 0.587 * Double(c[1]) + 0.114 * Double(c[2]))
        } }
        return best
    }
}

/// The flat pictures: every catalog board has its own (except the pairs Sam chose to share, 10-06), each the size of its
/// profile's shellPixels; the iPad frame's cutout and Home circle; the iPods drawn as siblings.
struct BoardArtTests {
    static let assets = repository.appendingPathComponent("LightTouchMac/Assets.xcassets")
    /// The boards that show another's picture, and whose.
    static let shared: [Board: Board] = [.n18: .n72, .n88: .m68]

    static func png(_ name: String) throws -> URL {
        let imageset = assets.appendingPathComponent(name + ".imageset")
        let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: imageset.appendingPathComponent("Contents.json"))) as? [String: Any]
        let file = try #require(((contents?["images"] as? [[String: Any]])?.first?["filename"]) as? String)
        return imageset.appendingPathComponent(file)
    }

    static func catalogBoards() throws -> [String] {
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("LightTouchMac/Resources/firmware-catalog.json"))) as? [String: Any]
        let entries = try #require(catalog?["entries"] as? [[String: Any]])
        return Set(entries.compactMap { $0["board"] as? String }).sorted()
    }

    @Test func everyCatalogBoardHasItsOwnPictureAtItsShellSize() throws {
        var seen: [(Board, String, Data)] = []
        for name in try Self.catalogBoards() {
            let board = try #require(Board(rawValue: name), "\(name): no Board")
            let url = try Self.png(board.shellImageName)
            let data = try Data(contentsOf: url)
            for (other, otherName, otherData) in seen {
                if Self.shared[board] == other || Self.shared[other] == board {
                    #expect(board.shellImageName == otherName, "\(name) should show \(other.rawValue)'s picture")
                    continue
                }
                #expect(board.shellImageName != otherName, "\(name) and \(other.rawValue) share \(otherName)")
                #expect(data != otherData, "\(name) and \(other.rawValue) are the same image")
            }
            seen.append((board, board.shellImageName, data))
            let pixels = try Pixels(url)
            #expect(CGSize(width: pixels.width, height: pixels.height) == board.shellPixels, "\(name): \(url.lastPathComponent) vs shellPixels \(board.shellPixels)")
        }
        #expect(seen.count >= 8)
    }

    /// The 1G art uses the 2G photo's LCD and glass tones (not a render's pure black).
    @Test func theIPodsShareOnePalette() throws {
        func tones(_ board: Board) throws -> [[Int]] {
            let pixels = try Pixels(Self.png(board.shellImageName)), c = board.screenCutout
            return [pixels.rgb(Int(c.midX), Int(c.midY)), pixels.rgb(Int(c.midX), Int(c.minY / 2))]   // the screen-off LCD, the glass above it
        }
        for (a, b) in zip(try tones(.n45), try tones(.n72)) {
            #expect(zip(a, b).map { abs($0 - $1) }.max()! <= 6, "n45 \(a) vs n72 \(b)")
        }
    }

    @Test func iPadFrameMatchesItsCutoutAndHomeButton() throws {
        let p = Board.k48, frame = try Pixels(Self.png(p.shellImageName))
        #expect(p.shellImageName == "ipad-frame")
        #expect(CGSize(width: frame.width, height: frame.height) == p.shellPixels)
        let shell = p.shellPixels, cut = p.screenCutout
        #expect(cut.size == CGSize(width: 768, height: 1024) && cut.minX * 2 + cut.width == shell.width && cut.minY * 2 + cut.height == shell.height, "\(cut)")
        // The Home button is lighter than the glass beside it.
        let r = p.homeButtonDiameter / 2, cy = shell.height - p.homeButtonBottomInset - r
        let button = frame.maxLuma(CGRect(x: (shell.width / 2 - r).rounded(.down), y: (cy - r).rounded(.down), width: 2 * r, height: 2 * r))
        let beside = frame.maxLuma(CGRect(x: (shell.width / 2 + 2 * r).rounded(.down), y: (cy - r).rounded(.down), width: 2 * r, height: 2 * r))
        #expect(button > beside + 60, "button \(button), beside \(beside)")
    }

    /// An Intel Mac's boot gets the budget its slower emulation needs; Apple silicon keeps iPod 240 s, iPad 300 s.
    @Test func bootBudgetsScaleByTheHostSlowdown() {
        #if arch(x86_64)
        let slowdown = 5.0
        #else
        let slowdown = 1.0
        #endif
        #expect(Board.hostSlowdown == slowdown)
        #expect(Board.n72.bootBudget == 240 * slowdown && Board.k48.bootBudget == 300 * slowdown)
    }
}
