#!/usr/bin/env python3
"""The built-in iPod: a fresh install unpacks it as a device of its own; a Mac with a library gets nothing new.

Builds firmwarekit (Packages/FirmwareKit, debug) and packs a small base in the n72 shape with its pack-base, as
build-release.py does with a real one. Then compiles the production FirmwareJobs (with PreparationJob, the shipped
catalog's `bundled` and the rest, stub Bundled/DeviceLibrary) and runs it with that firmwarekit as the preparer and
the blob where the bundle keeps it (Resources/device/n72ap-7E18.itbase, beside the check binary):

  fresh      no sidebar saved, no device: prepareBundledIfFresh starts the unpack (the "Unpacking" step, a growing
             bar) and returns n72ap-7E18; it publishes as Devices/<id> with the files the n72 boot wants, a locked
             base, identity.json and the lock's identity seeded with the device id, no build-machine path
  twice      a second fresh install: a different seed, UDID, serial, Wi-Fi/BT MAC, ECID and NOR SysCfg
  existing   a library with a device: nothing is unpacked (nil, no job, still one device); a saved sidebar with an
             empty library: nothing either
  prepare    Prepare on the row (downloadAndPrepare, e.g. after a Delete): the same unpack

Every path is a temp dir (HOME too); everything is deleted at the end.
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
import json, os, shutil, subprocess, tempfile
from firmwarekit_leaf import capacity_sources, schema_sources

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'LightTouchMac'
SOURCES = ['FirmwareJobs.swift', 'IPSWStore.swift', 'FirmwareDownloads.swift', 'PreparationJob.swift', 'DeviceInstance.swift',
           'FirmwareCatalog.swift', 'DeviceProfile.swift', 'StorageLocations.swift', 'DeviceStateStorage.swift', 'DeviceRow.swift']


def source(name):
    hits = [p for p in APP.rglob(name) if p.is_file()]
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
    let state = Bundled.stateDirectory, fm = FileManager.default
    let catalog = try FirmwareCatalog.load(from: URL(fileURLWithPath: args[1]))
    let iPod = catalog.entry(id: "n72ap-7E18")!
    expect(catalog.bundledEntry?.id == iPod.id && FirmwareJobs.bundledBlob(iPod) != nil, "the bundle has the built-in iPod's blob")
    let store = IPSWStore(downloads: state.appendingPathComponent("Caches/IPSW"), imports: state.appendingPathComponent("IPSW"))
    let jobs = FirmwareJobs(catalog: catalog, store: store, configuration: .ephemeral)
    var seen: [FirmwareJob] = []
    let observer = NotificationCenter.default.addObserver(forName: FirmwareJobs.didChangeNotification, object: jobs, queue: nil) { _ in
        MainActor.assumeIsolated { if let job = jobs.jobs[iPod.id], seen.last != job { seen.append(job) } }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    func devices() -> [DeviceInstance] { DeviceInstance.all(state: state) }
    func settle() async {
        for _ in 0..<600 where devices().isEmpty && { if case .failed? = jobs.jobs[iPod.id] { false } else { true } }() {
            try? await Task.sleep(for: .milliseconds(50))
        }
        expect(devices().count == 1 && jobs.jobs[iPod.id] == nil, "published: \(seen)")
    }
    /// The published device: what the boot wants, its own identity, no build-machine path. Prints its identity.
    func published() throws {
        let device = devices()[0]
        expect(device.firmware == iPod.id && device.base.kind == .prepared, "a prepared n72ap-7E18 device")
        let base = DeviceInstance.directory(device.id, state: state).appendingPathComponent("base")
        let boot = try iPod.profile!.preparedBoot(strategy: "iboot")
        for name in [boot.boot, "nand", "identity.json", "device.lock.json"] + boot.files {
            expect(fm.fileExists(atPath: base.appendingPathComponent(name).path), "base has \(name)")
        }
        let lockData = try Data(contentsOf: base.appendingPathComponent("device.lock.json"))
        let lock = try JSONSerialization.jsonObject(with: lockData) as! [String: Any]
        let identity = try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("identity.json"))) as! [String: String]
        let locked = lock["identity"] as! [String: String], machine = lock["machine"] as! [String: String]
        expect(identity["seed"] == device.id.uuidString && locked["seed"] == device.id.uuidString, "seeded with the device id: \(identity), \(locked)")
        expect(device.identity?.udid == identity["udid"] && locked["udid"] == identity["udid"], "the record's UDID is the identity's")
        expect(machine["wifi-mac"] == identity["wifi-mac"] && machine["bt-mac"] == identity["bt-mac"] && machine["ecid"] == identity["unique-chip-id"], "the machine boots this unit")
        expect(!String(decoding: lockData, as: UTF8.self).contains("/Users/"), "no build-machine path in the lock")
        expect((try fm.attributesOfItem(atPath: base.path)[.immutable] as? Bool) == true, "the base is locked")
        let nor = try Data(contentsOf: base.appendingPathComponent("nor.bin"))
        let out: [String: String] = ["udid": identity["udid"]!, "serial": identity["serial-number"]!, "wifi": identity["wifi-mac"]!,
                                     "bt": identity["bt-mac"]!, "ecid": identity["unique-chip-id"]!, "seed": identity["seed"]!,
                                     "syscfg": nor[0x4000..<0x4068].map { String(format: "%02x", $0) }.joined()]
        try JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: args[2]))
    }

    switch args[3] {
    case "fresh":
        let started = jobs.prepareBundledIfFresh(sidebarSaved: false)
        expect(started?.id == iPod.id, "a fresh install unpacks the built-in iPod")
        expect({ if case .preparing? = jobs.jobs[iPod.id] { true } else { false } }(), "a preparing job the sidebar shows")
        await settle()
        let steps = seen.compactMap { if case let .preparing(p) = $0 { p.name } else { nil } }
        expect(steps.contains("Unpacking"), "the Unpacking step: \(steps)")
        let fractions = seen.compactMap { if case let .preparing(p) = $0, p.name == "Unpacking" { p.fraction } else { nil } }
        expect(fractions == fractions.sorted() && fractions.count > 1, "a growing bar: \(fractions)")
        try published()
        print("PASS fresh: the built-in iPod unpacked and published as a device of its own (\(devices()[0].id.uuidString))")
    case "existing":
        expect(devices().count == 1, "a library with a device")
        expect(jobs.prepareBundledIfFresh(sidebarSaved: false) == nil && jobs.jobs.isEmpty, "a Mac with a device gets no built-in iPod")
        expect(jobs.prepareBundledIfFresh(sidebarSaved: true) == nil && jobs.jobs.isEmpty, "nor one that has saved a sidebar")
        try? await Task.sleep(for: .seconds(1))
        expect(devices().count == 1, "still one device")
        print("PASS existing: a library with a device, or a saved sidebar, gets nothing new")
    case "saved":
        expect(jobs.prepareBundledIfFresh(sidebarSaved: true) == nil && jobs.jobs.isEmpty && devices().isEmpty, "a saved sidebar with no device: nothing")
        print("PASS saved: an empty library that has launched before gets nothing new")
    case "prepare":
        jobs.downloadAndPrepare(iPod)
        await settle()
        try published()
        print("PASS prepare: the row's Prepare unpacks the built-in iPod")
    default: fatalError(args[3])
    }
}
}
'''


def firmwarekit():
    """The worktree's firmwarekit (debug), built incrementally under .build/offline-firmwarekit."""
    command = ['swift', 'build', '--package-path', ROOT / 'Packages/FirmwareKit', '--scratch-path', ROOT / '.build/offline-firmwarekit']
    subprocess.run([*command, '--product', 'firmwarekit'], check=True, stdout=subprocess.DEVNULL)
    return Path(subprocess.check_output([*command, '--show-bin-path'], text=True).strip()) / 'firmwarekit'


def template(base):
    """A base in the shape the n72 recipe leaves (the placeholder identity, this Mac's paths in the lock)."""
    (base / 'nand/cs0').mkdir(parents=True)
    (base / 'nand/cs0/1.page').write_bytes(b'\x07' * 4160)
    for name, data in (('iBoot.bin', b'ibot'), ('gid-blobs.bin', b'\0' * 64), ('nor.bin', b'\0' * 0x100000)):
        (base / name).write_bytes(data)
    (base / 'identity.json').write_text(json.dumps({'seed': 'lighttouch-built-in', 'model-number': 'MB528', 'region-info': 'LL/A',
                                                     'serial-number': 'X', 'udid': 'u'}))
    (base / 'device.lock.json').write_text(json.dumps({
        'board': 'n72ap', 'boot_strategy': 'iboot', 'entry': {'id': 'n72ap-7E18'},
        'identity': {'seed': 'lighttouch-built-in', 'udid': 'u', 'sha256': 'x'}, 'machine': {'aes-uid': 'engine'},
        'outputs': {'nor': {'path': 'nor.bin', 'sha256': 'x'}},
        'inputs': {'ipsw': {'path': str(Path.home() / 'Library/Caches/x.ipsw')}, 'guest_tools': str(base)},
        'tool': {'helper': str(base / 'LightTouchDevice')}}))
    subprocess.run(['chmod', '-R', 'a-w', base / 'nand', base / 'nor.bin'], check=True)


def main():
    tmp = Path(tempfile.mkdtemp(prefix='ltm-bundled-device-'))
    try:
        fk = firmwarekit()
        template(tmp / 'template')
        (tmp / 'device').mkdir()
        subprocess.run([fk, 'pack-base', '--base', tmp / 'template', '--out', tmp / 'device/n72ap-7E18.itbase'], check=True)
        (tmp / 'stubs.swift').write_text(STUBS)
        (tmp / 'main.swift').write_text(CHECK)
        subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(ROOT), *schema_sources(), '-O', '-suppress-warnings', '-swift-version', '5',
                        *capacity_sources(ROOT, tmp), '-default-isolation', 'MainActor', '-D', 'DEBUG', '-parse-as-library',
                        '-module-cache-path', tmp / 'modules', *[source(s) for s in SOURCES], ROOT / 'Shared/DeviceLinkProtocol.swift',
                        tmp / 'stubs.swift', tmp / 'main.swift', '-o', tmp / 'check'], check=True)
        catalog = APP / 'Resources/firmware-catalog.json'

        def run(case, state):
            home = tmp / f'home-{case}'
            home.mkdir(exist_ok=True)
            state.mkdir(parents=True, exist_ok=True)
            env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), LTM_STATE_DIR=str(state), LTM_FIRMWAREKIT=str(fk))
            subprocess.run([tmp / 'check', catalog, tmp / f'{case}.json', case], check=True, env=env, timeout=120)
            return json.loads((tmp / f'{case}.json').read_text()) if (tmp / f'{case}.json').exists() else None

        first = run('fresh', tmp / 'state-a')
        second = run('fresh', tmp / 'state-b')
        same = [k for k in first if first[k] == second[k]]
        assert not same, f'two unpacks share {same}: {first} / {second}'
        print(f'PASS twice: two unpacks, two identities (UDID {first["udid"][:8]}… / {second["udid"][:8]}…, '
              f'serial {first["serial"]} / {second["serial"]}, Wi-Fi {first["wifi"]} / {second["wifi"]})')
        run('existing', tmp / 'state-a')
        run('saved', tmp / 'state-c')
        run('prepare', tmp / 'state-d')
        print('PASS: check-bundled-device')
    finally:
        subprocess.run(['chflags', '-R', 'nouchg', tmp], check=False)
        subprocess.run(['chmod', '-R', 'u+w', tmp], check=False)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()
