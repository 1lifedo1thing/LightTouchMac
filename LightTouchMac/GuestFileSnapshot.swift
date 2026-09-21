import Foundation

/// A random separator preserves binary files without requiring utilities beyond
/// the guest's shell and cat. Startup reads all components in one round trip.
nonisolated struct GuestFileSnapshot {
    let paths: [String]
    private let boundary = Data(("\nLTM-" + UUID().uuidString + "\n").utf8)

    var command: String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let marker = quote(String(decoding: boundary, as: UTF8.self))
        return "set -e; for file in " + paths.map(quote).joined(separator: " ")
            + "; do printf '%s' " + marker + "; if [ -f \"$file\" ]; then cat \"$file\"; fi; done; printf '%s' " + marker
    }

    func decode(_ data: Data) throws -> [String: Data] {
        guard data.starts(with: boundary) else { throw CocoaError(.fileReadCorruptFile) }
        var offset = boundary.count
        var files: [String: Data] = [:]
        for path in paths {
            guard let end = data.range(of: boundary, in: offset..<data.count),
                  end.lowerBound - offset <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            files[path] = Data(data[offset..<end.lowerBound])
            offset = end.upperBound
        }
        guard offset == data.count else { throw CocoaError(.fileReadCorruptFile) }
        return files
    }
}
