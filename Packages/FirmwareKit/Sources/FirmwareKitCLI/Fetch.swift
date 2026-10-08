// firmwarekit unwrap --entry ENTRY.json --archive FILE --out IPSW
//   A "rar" source's downloaded archive -> its checked IPSW (RARSource.unwrap); the app runs this when such a
//   download finishes. The archive is left to the caller.
// firmwarekit fetch --entry ENTRY.json --out IPSW
//   The entry's IPSW from its source, then each mirror (SourceFetch): checked as the catalog says, a "rar" one
//   unwrapped, the archive deleted afterwards; any failure moves on to the next, each attempt logged on stderr. For
//   scripts and end-to-end checks; the app downloads itself.
// One JSON line {ipsw, sha1, bytes} on success; {"error": ...} and exit 1 otherwise.

import FirmwareKit
import FirmwareSchema
import Foundation

private func done(_ object: [String: Any], _ code: Int32) -> Never {
    printJSON(object)
    exit(code)
}

func unwrapCommand(_ command: FirmwareCommand.Unwrap) -> Never {
    let out = fileURL(command.out)
    do {
        let entry = try FirmwareEntry.load(from: fileURL(command.entry))
        try RARSource.unwrap(fileURL(command.archive), source: entry.source, to: out)
        done(["ipsw": out.path, "sha1": entry.source.sha1 ?? "", "bytes": entry.source.bytes ?? 0], 0)
    } catch {
        done(["error": "\(error)"], 1)
    }
}

func fetchCommand(_ command: FirmwareCommand.Fetch) -> Never {
    let out = fileURL(command.out)
    do {
        let source = try FirmwareEntry.load(from: fileURL(command.entry)).source
        guard source.sha1 != nil, !source.urls.isEmpty else {
            throw FirmwareError(.unsupported, "the entry's source has no URL and SHA-1")
        }
        let from = try SourceFetch.fetch(source, to: out, download: fetch) {
            FileHandle.standardError.write(Data("fetch: \($0)\n".utf8))
        }
        done(["ipsw": out.path, "sha1": source.sha1 ?? "", "bytes": source.bytes ?? 0, "from": from.absoluteString], 0)
    } catch {
        done(["error": "\(error)"], 1)
    }
}

/// One URL to `file`, synchronously (URLSession's download task; redirects followed).
private func fetch(_ url: URL, to file: URL) throws {
    let finished = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<Void, Error> = .failure(FirmwareError(.internal, "no response"))
    URLSession.shared.downloadTask(with: url) { location, response, error in
        defer { finished.signal() }
        if let error {
            result = .failure(error)
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard let location, (200..<300).contains(status) else {
            result = .failure(FirmwareError(.internal, "HTTP \(status)"))
            return
        }
        result = Result {
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: location, to: file)
        }
    }.resume()
    finished.wait()
    try result.get()
}
