#!/usr/bin/env python3
"""A download whose first source is gone or wrong comes from the catalog's next source, sha1-checked.

Compiles the production FirmwareJobs (with FirmwareDownloads, IPSWStore, PreparationJob, DeviceRow and the rest)
with a stub Bundled/DeviceLibrary, against a one-entry catalog (the shipped iPad 3.2) whose source.url and
source.mirrors point at a local HTTP server, an ephemeral URLSession, and tests/fixtures/fake-firmwarekit.py:

  404        url answers 404, the mirror the right bytes: one device; the job named the mirror's host
  hash       url answers 200 with other bytes of the right size: rejected, the mirror's copy used
  dns        url's host doesn't resolve (.invalid): the mirror's copy used
  exhausted  url 404, the mirror's bytes wrong: the job fails, no device, nothing in the store
  unlisted   url 404, a mirror recording another sha1: never requested; the job fails
  rar        a "rar" source: the archive downloaded, `firmwarekit unwrap` (the real one; the fake does create) checks
             it and extracts the IPSW, which is what the store keeps
  rar-other  a "rar" source whose archive hashes to another archive_sha1: the job fails, nothing kept

The server logs every request; each case checks which paths were fetched, in order.
Every path is a temp dir (HOME and CFFIXED_USER_HOME too); everything is deleted at the end.
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
import swift_subprocess
import base64, hashlib, http.server, json, os, subprocess, tempfile, threading
from firmwarekit_leaf import capacity_sources, schema_sources

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'LightTouchMac'
FAKE = ROOT / 'tests/fixtures/fake-firmwarekit.py'
SOURCES = ['FirmwareJobs.swift', 'IPSWStore.swift', 'FirmwareDownloads.swift', 'PreparationJob.swift', 'DeviceInstance.swift',
           'FirmwareCatalog.swift', 'Board+App.swift', 'StorageLocations.swift', 'DeviceStateStorage.swift',
           'DeviceRow.swift']
SIZE = 2 << 20


def source(name):
    hits = [p for d in (APP, APP.parent / "Packages/LightTouchCore/Sources/LightTouchCore") for p in d.rglob(name) if p.is_file()]
    if len(hits) != 1:
        raise SystemExit(f"{name}: expected one file under {APP}, found {hits}")
    return hits[0]


STUBS = r'''
import Foundation
nonisolated enum Bundled {
    static var stateDirectory: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["LTM_STATE_DIR"]!) }
    static var logsDirectory: URL { stateDirectory.appendingPathComponent("Logs") }
    static func requireStorage() throws {}
}
@MainActor final class DeviceLibrary {
    static let shared = DeviceLibrary()
    func instances(firmware: String) -> [DeviceInstance] { DeviceInstance.all(state: Bundled.stateDirectory).filter { $0.firmware == firmware } }
    func reload() {}
}
nonisolated func logEvent(_ message: String, _ arguments: CVarArg...) { print("  log: " + String(format: message, arguments: arguments)) }
'''

CHECK = r'''
import Cocoa

func expect(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    if !ok { print("FAIL line \(line): \(what())"); exit(1) }
}
@main struct Check {
@MainActor static func main() async throws {
    _ = NSApplication.shared
    let args = CommandLine.arguments
    let state = Bundled.stateDirectory
    let catalog = try FirmwareCatalog.load(from: URL(fileURLWithPath: args[1]))
    let entry = catalog.entries[0]
    let store = IPSWStore(downloads: state.appendingPathComponent("Caches/IPSW"), imports: state.appendingPathComponent("IPSW"))
    let jobs = FirmwareJobs(catalog: catalog, store: store, configuration: .ephemeral)
    var seen: [FirmwareJob] = []
    let observer = NotificationCenter.default.addObserver(forName: FirmwareJobs.didChangeNotification, object: jobs, queue: nil) { _ in
        MainActor.assumeIsolated { if let job = jobs.jobs[entry.id], seen.last != job { seen.append(job) } }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    let devices = { DeviceInstance.all(state: state).filter { $0.firmware == entry.id }.count }
    let failed = { if case .failed? = jobs.jobs[entry.id] { true } else { false } }
    jobs.downloadAndPrepare(entry)
    for _ in 0..<2000 where devices() == 0 && !failed() { try? await Task.sleep(for: .milliseconds(50)) }
    let mirrors = Set(seen.compactMap { if case let .downloading(_, _, _, mirror, _) = $0 { mirror } else { nil } })
    if args[2] == "success" || args[2] == "direct" {
        expect(devices() == 1 && jobs.jobs[entry.id] == nil, "prepared: \(seen)")
        expect(store.existing(entry.source.sha1!) != nil, "the IPSW is in the store")
        expect(try IPSWStore.sha1(of: store.existing(entry.source.sha1!)!) == entry.source.sha1!, "the stored IPSW hashes to the catalog's sha1")
        expect(args[2] == "direct" || mirrors == ["127.0.0.1"], "the job named the mirror it came from: \(seen)")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: store.downloads.path)) ?? []
        expect(left == [entry.source.sha1! + ".ipsw"], "only the IPSW is left in the downloads: \(left)")
        print("PASS: prepared from \(args[2] == "direct" ? "its source" : "the second source")")
    } else {
        expect(failed() && devices() == 0, "no source served the IPSW, so the job failed: \(seen)")
        expect(store.existing(entry.source.sha1!) == nil, "nothing in the store")
        print("PASS: the job failed; nothing kept")
    }
}
}
'''


class Handler(http.server.BaseHTTPRequestHandler):
    files, log = {}, []

    def do_GET(self):
        Handler.log.append(self.path)
        body = Handler.files.get(self.path)
        self.send_response(200 if body else 404)
        self.send_header('Content-Length', str(len(body or b'gone')))
        self.end_headers()
        self.wfile.write(body or b'gone')

    def log_message(self, *a):
        pass


def main():
    tmp = Path(tempfile.mkdtemp(prefix='ltm-ipsw-fallback-'))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    try:
        good, bad = os.urandom(SIZE), os.urandom(SIZE)
        sha1 = hashlib.sha1(good).hexdigest()
        # Unrar.swift's own test fixture (MIT): a 107-byte RAR 5 archive holding README.md, 40 bytes.
        rar = base64.b64decode('UmFyIRoHAQAzkrXlCgEFBgAFAQGAgAD3EqflHwICqAAGqACkgwIWO/FfV7UGeoAAAQlSRUFETUUubWQjIFVucmFyCgpBIGRlc2NyaXB0aW9uIG9mIHRoaXMgcGFja2FnZS4KHXdWUQMFBAA=')
        member = b'# Unrar\n\nA description of this package.\n'
        Handler.files = {'/good.ipsw': good, '/bad.ipsw': bad, '/media_ipsw.rar': rar}
        # The preparer: firmwarekit's own unwrap (a "rar" download), the fake for create.
        firmwarekit = Path(subprocess.check_output(['swift', 'build', '--package-path', ROOT / 'Packages/FirmwareKit', '--show-bin-path'],
                                                   text=True).strip()) / 'firmwarekit'
        subprocess.run(['swift', 'build', '--package-path', ROOT / 'Packages/FirmwareKit', '--product', 'firmwarekit'], check=True,
                       stdout=subprocess.DEVNULL)
        preparer = tmp / 'preparer'
        preparer.write_text(f'#!/bin/sh\n[ "$1" = unwrap ] && exec "{firmwarekit}" "$@"\nexec "{sys.executable}" "{FAKE}" "$@"\n')
        preparer.chmod(0o755)
        shipped = json.loads((APP / 'Resources/firmware-catalog.json').read_text())
        entry = next(e for e in shipped['entries'] if e['id'] == 'k48ap-7B367')
        entry['estimates'] = {'seconds': 1, 'prepared_bytes': 1 << 20, 'peak_bytes': 1 << 20}

        (tmp / 'stubs.swift').write_text(STUBS)
        (tmp / 'main.swift').write_text(CHECK)
        subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(ROOT), *swift_subprocess.zip_flags(ROOT), *schema_sources(), '-O', '-suppress-warnings', '-swift-version', '5',
                        *capacity_sources(ROOT, tmp), '-default-isolation', 'MainActor', '-D', 'DEBUG',
                        '-parse-as-library', '-module-cache-path', tmp / 'modules', *[source(s) for s in SOURCES],
                        ROOT / 'Packages/DeviceRuntime/Sources/DeviceRuntime/DeviceLinkProtocol.swift', tmp / 'stubs.swift', tmp / 'main.swift', '-o', tmp / 'check'], check=True)

        mirror = lambda path, sha=sha1: {'url': base + path, 'sha1': sha, 'bytes': SIZE}
        cases = [  # name, url, mirrors, outcome, the paths the server must have seen, in order
            ('404', base + '/gone.ipsw', [mirror('/good.ipsw')], 'success', ['/gone.ipsw', '/good.ipsw']),
            ('hash', base + '/bad.ipsw', [mirror('/good.ipsw')], 'success', ['/bad.ipsw', '/good.ipsw']),
            ('dns', 'http://ipsw.invalid/gone.ipsw', [mirror('/good.ipsw')], 'success', ['/good.ipsw']),
            ('exhausted', base + '/gone.ipsw', [mirror('/bad.ipsw')], 'failure', ['/gone.ipsw', '/bad.ipsw']),
            ('unlisted', base + '/gone.ipsw', [mirror('/good.ipsw', '0' * 40)], 'failure', ['/gone.ipsw']),
        ]
        rar_source = lambda archive_sha1: {'kind': 'rar', 'url': base + '/media_ipsw.rar', 'archive_sha1': archive_sha1,
                                           'archive_bytes': len(rar), 'member': 'README.md',
                                           'sha1': hashlib.sha1(member).hexdigest(), 'bytes': len(member)}
        cases += [
            ('rar', rar_source(hashlib.sha1(rar).hexdigest()), [], 'direct', ['/media_ipsw.rar']),
            ('rar-other', rar_source('0' * 40), [], 'failure', ['/media_ipsw.rar']),
        ]
        for name, url, mirrors, outcome, paths in cases:
            entry['source'] = url if isinstance(url, dict) else {'kind': 'ipsw', 'url': url, 'sha1': sha1, 'bytes': SIZE, 'mirrors': mirrors}
            case = tmp / name
            (case / 'home').mkdir(parents=True)
            (case / 'state').mkdir()
            (case / 'catalog.json').write_text(json.dumps({'format': 1, 'entries': [entry]}))
            Handler.log = []
            env = dict(os.environ, HOME=str(case / 'home'), CFFIXED_USER_HOME=str(case / 'home'), LTM_STATE_DIR=str(case / 'state'),
                       LTM_FIRMWAREKIT=str(preparer), FAKE_ARGV=str(case / 'argv.json'))
            print(f'{name}:')
            subprocess.run([tmp / 'check', case / 'catalog.json', outcome], check=True, env=env, timeout=120)
            assert Handler.log == paths, f'{name}: the server saw {Handler.log}, wanted {paths}'
        print('PASS: check-ipsw-fallback')
    finally:
        server.shutdown()
        subprocess.run(['chflags', '-R', 'nouchg', tmp], check=False)
        subprocess.run(['chmod', '-R', 'u+w', tmp], check=False)
        subprocess.run(['rm', '-rf', tmp], check=False)


if __name__ == '__main__':
    main()
