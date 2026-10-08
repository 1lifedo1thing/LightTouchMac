import Foundation
import Testing

@testable import FirmwareKit

/// Oracle plumbing for the HFS+ tests: an independent listing through hdiutil mounts, run on temp copies.
enum HFSOracle {
    /// python3 -c SCRIPT ARGS...; stdout.
    static func python(_ script: String, _ args: [String]) throws -> Data {
        let p = Process()
        let out = Pipe()
        let err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments =
            ["python3", "-c", "import sys\n" + script] + args
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw FirmwareError(.internal, "python: \(String(decoding: e, as: UTF8.self))")
        }
        return o
    }

    /// A listing through two read-only mounts of IMG (-owners on for uid/gid where reachable, off for the
    /// rest): {path: [uid, gid, st_mode, st_flags, size, sha256, link]}. Independent of the catalog reader.
    static let walk = """
        import hashlib, json, os, subprocess, tempfile
        img = sys.argv[1]
        def walk(owners, body):
            mnt = tempfile.mkdtemp(prefix="fk-walk.")
            r = subprocess.run(["hdiutil", "attach", "-readonly", "-owners", owners, "-nobrowse", "-noverify", "-imagekey",
                                "diskimage-class=CRawDiskImage", "-mountpoint", mnt, img], capture_output=True, text=True, check=True)
            dev = r.stdout.split()[0]
            try:
                for root, dn, fn in os.walk(mnt):
                    for n in ([""] if root == mnt else []) + dn + fn:
                        p = os.path.join(root, n) if n else root
                        body(os.path.relpath(p, mnt) if n else "", p)
            finally:
                subprocess.run(["hdiutil", "detach", dev], capture_output=True)
                os.rmdir(mnt)
        out, own = {}, {}
        def meta(rel, p):
            st = os.lstat(p)
            own[rel] = (st.st_uid, st.st_gid)
        def content(rel, p):
            st = os.lstat(p)
            e = out[rel] = [None, None, st.st_mode, st.st_flags, 0 if os.path.isdir(p) and not os.path.islink(p) else st.st_size, None, None]
            if os.path.islink(p):
                e[6] = os.readlink(p)
            elif os.path.isfile(p) and os.access(p, os.R_OK):
                h = hashlib.sha256()
                with open(p, "rb") as f:
                    for c in iter(lambda: f.read(1 << 22), b""):
                        h.update(c)
                e[5] = h.hexdigest()
        walk("on", meta)
        walk("off", content)
        for k, v in out.items():
            v[0], v[1] = own.get(k, (None, None))
        json.dump(out, sys.stdout)
        """

    /// The raw system volume of a firmware (UDIF slice of the decrypted cache's rootfs.dmg), in `dir`.
    static func rawSystem(_ fw: Oracle.Firmware, in dir: URL) async throws -> URL? {
        guard let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg) else { return nil }
        let raw = dir.appendingPathComponent("rootfs.hfs")
        try await UDIF.extractRootfs(dmg: dmg, to: raw)
        return raw
    }

    static let ipads = ["k48ap-7B500", "k48ap-8C148"].map(Oracle.firmware)
}

@Suite(.serialized, .detachesItsImages) struct HFSPlusTests {
    /// Every catalog path, owner, mode, flags, size, content sha256 and symlink target against a listing of
    /// the same image through hdiutil mounts.
    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: HFSOracle.ipads
    ) func readerMatchesMount(_ fw: Oracle.Firmware) async throws {
        try await Oracle.withTemp { dir in
            guard let raw = try await HFSOracle.rawSystem(fw, in: dir) else {
                try FixtureRequirements.missing(#"HFSPlusTests.swift: let raw = try await HFSOracle.rawSystem(fw, in: dir)"#)
            }
            let vol = try HFSPlusVolume(raw)
            #expect(vol.signature == "HX" && vol.blockSize == 8192)
            let mine = try Oracle.time("HFSPlus listing \(fw.entryID)") { try vol.listing() }
            let walked =
                try JSONSerialization.jsonObject(with: HFSOracle.python(HFSOracle.walk, [raw.path])) as! [String: [Any]]
            #expect(mine.count == walked.count)
            var diffs: [String] = []
            for e in mine {
                guard let w = walked[e.path] else {
                    diffs.append("only in the catalog: \(e.path)")
                    continue
                }
                let uid = w[0] as? Int
                let gid = w[1] as? Int
                if let uid, let gid, (uid, gid) != (Int(e.uid), Int(e.gid)) {
                    diffs.append("\(e.path): owner \(e.uid):\(e.gid) vs \(uid):\(gid)")
                }
                if w[2] as? Int != Int(e.mode) {
                    diffs.append("\(e.path): mode \(String(e.mode, radix: 8)) vs \(String(w[2] as! Int, radix: 8))")
                }
                if w[3] as? Int != Int(e.flags) { diffs.append("\(e.path): flags \(e.flags) vs \(w[3])") }
                if w[4] as? Int != Int(e.size) { diffs.append("\(e.path): size \(e.size) vs \(w[4])") }
                if let s = w[5] as? String, s != e.sha256 { diffs.append("\(e.path): sha256") }
                if w[6] as? String != e.link { diffs.append("\(e.path): link \(e.link ?? "-") vs \(w[6])") }
            }
            #expect(diffs.isEmpty, "\(diffs.prefix(20))")
        }
    }

    /// In-place owner and mode edits land in the catalog records; an unknown path throws.
    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: HFSOracle.ipads
    ) func ownershipEdits(_ fw: Oracle.Firmware) async throws {
        try await Oracle.withTemp { dir in
            guard let raw = try await HFSOracle.rawSystem(fw, in: dir) else {
                try FixtureRequirements.missing(#"HFSPlusTests.swift: let raw = try await HFSOracle.rawSystem(fw, in: dir)"#)
            }
            let specs = [
                "private/var/mobile:0:0", "System/Library/LaunchDaemons/com.apple.SpringBoard.plist:501:20",
                "usr/libexec/lockdownd:0:0:4755", "private/var/Keychains:64:0:700", "Applications:0:80",
            ]
            let vol = try HFSPlusVolume(raw, writable: true)
            var changed = 0
            for s in specs {
                let p = s.split(separator: ":").map(String.init)
                changed += try vol.setOwner(
                    [p[0]],
                    uid: UInt32(p[1])!,
                    gid: UInt32(p[2])!,
                    mode: p.count > 3 ? UInt16(p[3], radix: 8) : nil
                )
            }
            #expect(changed >= 3)
            let back = try HFSPlusVolume(raw)
            for s in specs {
                let p = s.split(separator: ":").map(String.init)
                let r = try back.record(at: p[0])
                #expect(r.uid == UInt32(p[1])! && r.gid == UInt32(p[2])!, "\(s)")
                if p.count > 3 { #expect(r.mode & 0o7777 == UInt16(p[3], radix: 8)!, "\(s)") }
            }
            #expect(try back.record(at: "usr/libexec/lockdownd").mode == 0o104755)
            #expect(throws: FirmwareError.self) { try vol.setOwner(["no/such/path"], uid: 0, gid: 0) }
        }
    }
}

@Suite(.detachesItsImages) struct HFSPlusNameTests {
    /// A name holding ":" on the host is stored with "/" in the catalog (1.0's zoneinfo/Etc/GMT-0:15): paths
    /// and lookups use the host's form, so the stopped edit can restore its metadata.
    @Test func slashInCatalogName() async throws {
        let dir = try Fixtures.tempDir("hfs-colon")
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("v.img")
        try await VolumeMount.makeHFS(image, size: 8 << 20, name: "Colon")
        try await VolumeMount.withMounted(image, at: dir.appendingPathComponent("m")) { root in
            try Data("x".utf8).write(to: root.appendingPathComponent("GMT-0:15"))
        }
        let v = try HFSPlusVolume(image)
        #expect(try v.catalog().contains { $0.name == "GMT-0/15" })
        #expect(try v.paths().contains { $0.path == "GMT-0:15" })
        #expect(try v.contents(v.record(at: "GMT-0:15")) == Data("x".utf8))
    }
}
