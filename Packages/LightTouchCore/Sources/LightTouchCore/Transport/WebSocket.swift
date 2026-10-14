// The parts of RFC 6455 the phone remote's server needs: the handshake's accept key and unfragmented frames.
// Hand-written because the page and its socket share one port (one certificate warning on the phone), which
// Network.framework's WebSocket, upgrade requests only, can't serve.

import CryptoKit
import Foundation

public nonisolated enum WebSocket {
    public enum Opcode: UInt8 {
        case text = 1
        case binary = 2
        case close = 8
    }
    struct InvalidFrame: Error {}
    /// The page sends small JSON messages; anything bigger is not the page.
    private static let maxPayload = 4096

    /// Sec-WebSocket-Accept for the request's Sec-WebSocket-Key.
    public static func acceptKey(_ key: String) -> String {
        let hash = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(hash).base64EncodedString()
    }

    /// One server frame, final and unmasked.
    public static func frame(_ payload: Data, _ opcode: Opcode) -> Data {
        var out = Data([0x80 | opcode.rawValue])
        if payload.count < 126 {
            out.append(UInt8(payload.count))
        } else if payload.count <= UInt16.max {
            out.append(126)
            withUnsafeBytes(of: UInt16(payload.count).bigEndian) { out.append(contentsOf: $0) }
        } else {
            out.append(127)
            withUnsafeBytes(of: UInt64(payload.count).bigEndian) { out.append(contentsOf: $0) }
        }
        return out + payload
    }

    /// Takes the first whole client frame off `buffer`, unmasked; nil until it has all arrived. Throws on what a
    /// browser never sends: an unmasked frame, an unknown opcode or one past `maxPayload`.
    /// No fragments (FIN is ignored): the page's messages are single frames.
    public static func nextFrame(_ buffer: inout Data) throws -> (opcode: Opcode, payload: Data)? {
        let b = [UInt8](buffer.prefix(8))
        guard b.count >= 2 else { return nil }
        guard b[1] & 0x80 != 0, let opcode = Opcode(rawValue: b[0] & 0x0f) else { throw InvalidFrame() }
        var length = Int(b[1] & 0x7f)
        var offset = 2
        if length == 126 {
            guard b.count >= 4 else { return nil }
            length = Int(b[2]) << 8 | Int(b[3])
            offset = 4
        }
        // 127 announces a 64-bit length: never within maxPayload.
        guard length != 127, length <= maxPayload else { throw InvalidFrame() }
        guard buffer.count >= offset + 4 + length else { return nil }
        let bytes = [UInt8](buffer.prefix(offset + 4 + length))
        let mask = Array(bytes[offset..<offset + 4])
        let payload = bytes[(offset + 4)...].enumerated().map { $1 ^ mask[$0 % 4] }
        buffer.removeFirst(offset + 4 + length)
        return (opcode, Data(payload))
    }
}
