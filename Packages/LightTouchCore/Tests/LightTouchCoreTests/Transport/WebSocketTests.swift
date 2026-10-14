import Foundation
import Testing

@testable import LightTouchCore

/// The phone remote's WebSocket: the handshake's key, server frames of each length form, and client frames whole,
/// in pieces and refused.
struct WebSocketTests {
    @Test func acceptKeyIsRFC6455s() {
        #expect(WebSocket.acceptKey("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func serverFramesCarryTheirLength() {
        #expect(WebSocket.frame(Data("Hi".utf8), .text) == Data([0x81, 2]) + Data("Hi".utf8))
        #expect(WebSocket.frame(Data(count: 300), .binary).prefix(4) == Data([0x82, 126, 1, 44]))
        let large = Data([0x82, 127, 0, 0, 0, 0, 0, 1, 17, 112])
        #expect(WebSocket.frame(Data(count: 70_000), .binary).prefix(10) == large)
    }

    /// RFC 6455's masked "Hello", arriving a byte at a time and followed by the next frame.
    @Test func clientFramesUnmaskOnceWhole() throws {
        let hello = Data([0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58])
        var buffer = Data()
        for byte in hello.dropLast() {
            buffer.append(byte)
            #expect(try WebSocket.nextFrame(&buffer) == nil)
        }
        buffer.append(hello.last!)
        buffer.append(0x88)
        let frame = try #require(try WebSocket.nextFrame(&buffer))
        #expect(frame.opcode == .text && frame.payload == Data("Hello".utf8))
        #expect(buffer == Data([0x88]))
    }

    @Test func refusesWhatNoBrowserSends() {
        var unmasked = Data([0x81, 0x05]) + Data("Hello".utf8)
        #expect(throws: WebSocket.InvalidFrame.self) { try WebSocket.nextFrame(&unmasked) }
        var huge = Data([0x82, 0xff]) + Data(count: 12)
        #expect(throws: WebSocket.InvalidFrame.self) { try WebSocket.nextFrame(&huge) }
    }
}
