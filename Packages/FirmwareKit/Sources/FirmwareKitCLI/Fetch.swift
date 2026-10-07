// firmwarekit unwrap --entry ENTRY.json --archive FILE --out IPSW
//   A "rar" source's downloaded archive -> its checked IPSW (RARSource.unwrap); the app runs this when such a
//   download finishes. The archive is left to the caller.
// firmwarekit fetch --entry ENTRY.json --out IPSW
//   The entry's IPSW from its source, then each mirror (SourceFetch): checked as the catalog says, a "rar" one
//   unwrapped, the archive deleted afterwards; any failure moves on to the next, each attempt logged on stderr. For scripts and end-to-end checks; the app downloads itself.
// One JSON line {ipsw, sha1, bytes} on success; {"error": ...} and exit 1 otherwise.

import FirmwareKit
import Foundation

private func done(_ object: [String: Any], _ code: Int32) -> Never {
    // FIXME: uglyyyyy
    FileHandle.standardOutput.write(
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
    )
    exit(code)
}

private func flags(_ argv: [String], _ known: Set<String>, _ usage: String) -> [String: URL] {
    var out: [String: URL] = [:]
    var rest = argv[...]
    while let a = rest.popFirst() {
        guard known.contains(a), let v = rest.popFirst() else {
            FileHandle.standardError.write(Data("usage: \(usage)\n".utf8))
            exit(64)
        }
        out[a] = URL(fileURLWithPath: (v as NSString).expandingTildeInPath).standardizedFileURL
    }
    guard out.count == known.count else {
        FileHandle.standardError.write(Data("usage: \(usage)\n".utf8))
        exit(64)
    }
    return out
}

func unwrapCommand(_ argv: [String]) -> Never {
    let f = flags(
        argv,
        ["--entry", "--archive", "--out"],
        "firmwarekit unwrap --entry ENTRY.json --archive FILE --out IPSW"
    )
    do {
        let entry = try FirmwareEntry.load(from: f["--entry"]!)
        try RARSource.unwrap(f["--archive"]!, source: entry.source, to: f["--out"]!)
        done(["ipsw": f["--out"]!.path, "sha1": entry.source.sha1 ?? "", "bytes": entry.source.bytes ?? 0], 0)
    } catch {
        done(["error": "\(error)"], 1)
    }
}

func fetchCommand(_ argv: [String]) -> Never {
    let f = flags(argv, ["--entry", "--out"], "firmwarekit fetch --entry ENTRY.json --out IPSW")
    let out = f["--out"]!
    do {
        let source = try FirmwareEntry.load(from: f["--entry"]!).source
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
