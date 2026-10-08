import Foundation
import Testing

@testable import FirmwareKit

/// The fixtures' inputs: the decrypt cache's rootfs.dmg, the qemu-ios helper build outputs (contrib/*/build.sh)
/// and the GL name table. Everything is read in place; outputs go to temp dirs.
enum K48Oracle {
    static let qemu = Oracle.qemuIOS
    /// helpers-dir name -> qemu-ios file.
    static var sources: [String: URL] {
        let guest = qemu.appendingPathComponent("build/ipad1-guest")
        let contrib = qemu.appendingPathComponent("contrib")
        var m: [String: URL] = [:]
        for t in SystemEdits.Helpers.tools.map(\.name) + ["it_seal", "it_gltest"] {
            m[t] = guest.appendingPathComponent(t)
        }
        for (j, d) in [
            ("com.qemu.it-pbd.plist", "it-pasteboard"), ("com.qemu.it-prefs.plist", "it-prefs"),
            ("com.qemu.it-seal.plist", "it-seal"),
            ("com.qemu.it-gltest.plist", "it-gltest"),
        ] {
            m[j] = contrib.appendingPathComponent("\(d)/\(j)")
        }
        m["libappsync.dylib"] = qemu.appendingPathComponent("build/appsync/libappsync.dylib")
        m["OpenGLES"] = contrib.appendingPathComponent("gles-public/OpenGLES")
        m["gles-names.h"] = qemu.appendingPathComponent("include/hw/arm/guest-services/gles-names.h")
        m[SystemEdits.Helpers.itpack] = Oracle.guestPackages.appendingPathComponent("armv7.itpack")
        return m
    }

    static var available: Bool { sources.values.allSatisfy(Oracle.exists) }

    /// FIRMWAREKIT_GUEST_TOOLS: a flat guest-tools directory (build-guest-tools.sh's ipad-guest-tools, or the app's
    /// Resources/guest-tools) that stands in for the qemu-ios build outputs where those aren't built.
    static let guestTools = ProcessInfo.processInfo.environment["FIRMWAREKIT_GUEST_TOOLS"].map {
        URL(fileURLWithPath: $0)
    }

    /// A helpers directory of symlinks to the qemu-ios build outputs.
    static func helpers(in dir: URL) throws -> URL {
        let h = dir.appendingPathComponent("helpers")
        try FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
        for (n, u) in sources {
            try FileManager.default.createSymbolicLink(at: h.appendingPathComponent(n), withDestinationURL: u)
        }
        return h
    }

    static func sh(_ args: [String], cwd: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw FirmwareError(.internal, "\(args.prefix(3)): \(String(decoding: e.suffix(2000), as: UTF8.self))")
        }
    }
}

@Suite(.serialized, .detachesItsImages) struct SystemEditsTests {
    /// ipad1_rootfs FSTAB_RO: only the root line turns ro (7.x), /private/var stays rw.
    @Test func fstabRO() {
        #expect(SystemEdits.fstabRO == "/dev/disk0s1 / hfs ro 0 1\n/dev/disk0s2 /private/var hfs rw,nosuid,nodev 0 2\n")
    }

    /// A pinned clock (recipe rtc_epoch, a developer beta) makes the build dated: timed's NTP off, ark unbricked.
    @Test func datedFromRTCEpoch() throws {
        func recipe(_ extra: String) throws -> FirmwareEntry.Recipe {
            try JSONDecoder().decode(
                FirmwareEntry.Recipe.self,
                from: Data(
                    #"{"name": "n90", "version": 1, "storage": "16g", "system_mib": 1664, "data_size": "partition", "boot": "kboot", "options": {}\#(extra)}"#
                        .utf8
                )
            )
        }
        #expect(SystemEdits.Options(recipe: try recipe(#", "rtc_epoch": 1371297600"#)).dated)
        #expect(!SystemEdits.Options(recipe: try recipe("")).dated)
    }

    @Test func plistEdits() throws {
        let real = NSMutableDictionary(dictionary: [
            "CurrentSet": "/Sets/S", "NetworkServices": ["W": ["Interface": ["DeviceName": "en0"]]],
            "Sets": ["S": ["Network": ["Global": ["IPv4": ["ServiceOrder": ["W"]]], "Service": ["W": [:]]]]],
        ])
        let d =
            try PropertyListSerialization.propertyList(
                from: PropertyListSerialization.data(fromPropertyList: real, format: .xml, options: 0),
                options: .mutableContainersAndLeaves,
                format: nil
            ) as! NSMutableDictionary
        SystemEdits.wifiProxyPrefs(d)
        SystemEdits.wifiProxyPrefs(d)
        let net = ((d["Sets"] as! NSDictionary)["S"] as! NSDictionary)["Network"] as! NSDictionary
        #expect(
            ((net["Global"] as! NSDictionary)["IPv4"] as! NSDictionary)["ServiceOrder"] as! [String]
                == [SystemEdits.wifiService, "W"]
        )
        let fresh = NSMutableDictionary()
        SystemEdits.wifiProxyPrefs(fresh)
        #expect(
            ((fresh["Sets"] as! NSDictionary)[SystemEdits.netSet] as? NSDictionary)?["UserDefinedName"] as? String
                == "Automatic"
        )
        let env = NSMutableDictionary(dictionary: [
            "EnvironmentVariables": NSMutableDictionary(dictionary: ["DYLD_INSERT_LIBRARIES": "/a.dylib"])
        ])
        SystemEdits.dyldInsert(env, "/b.dylib")
        SystemEdits.dyldInsert(env, "/b.dylib")
        #expect(
            (env["EnvironmentVariables"] as! NSDictionary)["DYLD_INSERT_LIBRARIES"] as? String == "/a.dylib:/b.dylib"
        )
    }

    /// GuestPackage.seed on a plain directory with the real armv7.itpack, for a shim image and a no-shim one: the
    /// record's GLES hook and family, and the seeded state.
    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: [("7B500", true), ("8C148", false), ("9B206", true)]
    ) func seed(_ build: String, _ gles: Bool) async throws {
        let itpack = Oracle.guestPackages.appendingPathComponent("armv7.itpack")
        guard Oracle.exists(itpack) else {
            try FixtureRequirements.missing(#"SystemEditsTests.swift: Oracle.exists(itpack)"#)
        }
        try await Oracle.withTemp { dir in
            // the firmware the seed's load checks read: its executables, libSystem, cache, and the mounter's job
            // inserting it_msmquiet as the bake leaves it
            let id = "k48ap-" + build
            guard
                let stock = try await FitFixture.volume(
                    id,
                    FitFixture.stock(id) + [FitFixture.mounter, SystemEdits.msmJob],
                    in: dir
                )
            else {
                try FixtureRequirements.missing(
                    #"SystemEditsTests.swift: let stock = try await FitFixture.volume(id, FitFixture.stock(id) + [FitFixture.mounter, SystemEdits.msmJob], in: dir)"#
                )
            }
            try FitFixture.insert("/usr/local/lib/it_msmquiet.dylib", into: SystemEdits.msmJob, at: stock)
            func volume(_ name: String) throws -> URL {
                let v = dir.appendingPathComponent(name)
                let sv = v.appendingPathComponent(GuestPackage.systemVersion)
                try FileManager.default.copyItem(at: stock, to: v)
                // the front end is installed before the seed
                for rel in [FitCheck.openGLES, "usr/local/lib/it_msmquiet.dylib"] {
                    try SystemEdits.mkdirs(v.appendingPathComponent(rel).deletingLastPathComponent())
                    try SystemEdits.put(Data("stock".utf8), v.appendingPathComponent(rel), mode: 0o755)
                }
                try SystemEdits.mkdirs(v.appendingPathComponent(SystemEdits.daemons))
                try SystemEdits.put(
                    Data("job".utf8),
                    v.appendingPathComponent(SystemEdits.daemons + "/com.qemu.it-pbd.plist")
                )
                try SystemEdits.mkdirs(sv.deletingLastPathComponent())
                try (["ProductBuildVersion": build] as NSDictionary).write(to: sv)
                return v
            }
            let a = try volume("swift")
            let (written, record) = try GuestPackage.seed(volume: a, itpack: itpack, gles: gles)
            #expect(!written.isEmpty)
            #expect(record.gles == gles && record.hooks.contains("/" + FitCheck.openGLES) == gles)
            // "9*": 5.x's own family
            if build.hasPrefix("9") { #expect(record.family == "k48-ios5" && record.seed >= 8) }
            var st = stat()
            #expect(lstat(a.appendingPathComponent("usr/local/lighttouch/state").path, &st) == 0)
            // the baked it-pbd job is left alone since package serial 2 folded the pasteboard into it_agent
            #expect(
                try Data(contentsOf: a.appendingPathComponent(SystemEdits.daemons + "/com.qemu.it-pbd.plist"))
                    == Data("job".utf8)
            )
        }
    }

    @Test func activationRejectsInvalidInputWithoutChangingIt() throws {
        try Oracle.withTemp { dir in
            let target = dir.appendingPathComponent("t")
            let original = Data("not a mach-o".utf8)
            try original.write(to: target)
            #expect(throws: ActivationFailure.self) { try Activation.run(on: target) }
            #expect(try Data(contentsOf: target) == original)
        }
    }

    /// Level 2: the system and data volumes SystemEdits.buildK48 makes from the rootfs.dmg: the activation ran, the
    /// seed record, the network services, the seeded tree, the GLES front end with its original kept once, and
    /// lockdownd as the activation wrote it.
    @Test(arguments: HFSOracle.ipads) func volumes(_ fw: Oracle.Firmware) async throws {
        guard K48Oracle.available, let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg)
        else { return }
        try await Oracle.withTemp { dir in
            let entry = try Oracle.entry(fw.entryID)
            let recipe = try #require(entry.recipe)
            let parts = K48NAND.partitions(mbr: [UInt8](K48NAND.makeMBR(systemMiB: recipe.systemMiB)))
            let swift = dir.appendingPathComponent("swift")
            try FileManager.default.createDirectory(at: swift, withIntermediateDirectories: true)
            let helpers = try K48Oracle.helpers(in: dir)
            let r = try await Oracle.time("SystemEdits.buildK48 \(fw.entryID)") {
                try await SystemEdits.buildK48(
                    rootfs: dmg,
                    work: swift,
                    systemBytes: parts[0].count * 4096,
                    dataBytes: Int64(parts[1].count) * 4096,
                    options: .init(recipe: recipe),
                    helpers: helpers
                ) { print("  \($0)") }
            }
            #expect(r.activation != nil)
            #expect(r.guestPackage?.gles == true && r.engine == SystemEdits.Helpers.openGLES)

            // the seeded network services are there
            let dv = try HFSPlusVolume(swift.appendingPathComponent("data.img"))
            let prefs =
                try PropertyListSerialization.propertyList(
                    from: dv.contents(dv.record(at: "preferences/SystemConfiguration/preferences.plist")),
                    format: nil
                ) as! NSDictionary
            let order =
                (prefs.value(forKeyPath: "Sets.\(SystemEdits.netSet).Network.Global.IPv4.ServiceOrder") as? [String])
                ?? []
            #expect(order.first == SystemEdits.wifiService)
            // the seed is there: loader, current -> pkgs/<serial>, its offer record, a hook and its .baked copy, no baked helper job
            let sv = try HFSPlusVolume(swift.appendingPathComponent("system.img"))
            let seed = try #require(r.guestPackage)
            let tree = Dictionary(uniqueKeysWithValues: try sv.listing(under: "usr/local").map { ($0.path, $0) })
            #expect(tree["usr/local/bin/it_boot"]?.mode == 0o100755 && tree["usr/local/bin/it_boot"]?.uid == 0)
            #expect(tree["usr/local/lighttouch/current"]?.link == "pkgs/\(seed.seed)")
            #expect(tree["usr/local/lighttouch/pkgs/\(seed.seed)/offer"]?.uid == 0)
            #expect(seed.hooks.contains("/" + FitCheck.openGLES))
            let engine = try sv.listing(under: FitCheck.openGLES).first
            let baked = (try? sv.listing(under: FitCheck.openGLES + ".baked"))?.first
            let absent = (try? sv.listing(under: FitCheck.openGLES + ".baked-absent"))?.first
            // The front end is installed over OpenGLES; the original is kept exactly once (126ba26): the firmware's file
            // as .baked (never the front end's bytes), or, when OpenGLES lives only in the dyld cache, an empty .baked-absent.
            #expect(engine?.sha256 != nil && engine?.uid == 0)
            #expect((baked != nil) != (absent != nil))
            if let baked { #expect(engine?.sha256 != baked.sha256 && baked.uid == 0) }
            if let absent {
                #expect(
                    absent.uid == 0
                        && absent.sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                )
                #expect(
                    try sv.listing(under: SystemEdits.dyldOverride).first != nil,
                    "an absent original must be a cache-only OpenGLES"
                )
            }
            #expect(try sv.listing(under: SystemEdits.daemons + "/com.qemu.it-pbd.plist").isEmpty)
            #expect(try sv.listing(under: SystemEdits.daemons + "/com.qemu.it-boot.plist").first?.uid == 0)
            // the activation's output is lockdownd as installed (re-signed ad hoc, entitlements kept)
            let lockd = try HFSPlusVolume(swift.appendingPathComponent("system.img")).listing(
                under: "usr/libexec/lockdownd"
            )
            #expect(
                lockd.first?.sha256 == r.activation?.outputSHA256 && lockd.first?.mode == 0o100755
                    && lockd.first?.uid == 0
            )
        }
    }

    /// Two builds from the same inputs give the same system and data volumes, and the same store from them: the
    /// lock's built_listing_sha256 (the golden-lock oracle) relies on it. Dates, the data volume's identifier and
    /// the journals are normalized after the mount (HFSPlusVolume.normalize, VolumeMount.withMounted). A
    /// difference is reported by 4 KiB page, HFS+ region and its first differing bytes.
    @Test(arguments: HFSOracle.ipads) func volumesAreReproducible(_ fw: Oracle.Firmware) async throws {
        guard let cache = fw.cache, Oracle.exists(cache.appendingPathComponent("rootfs.dmg")),
            K48Oracle.guestTools != nil || K48Oracle.available
        else { return }
        try await Oracle.withTemp { dir in
            let entry = try Oracle.entry(fw.entryID)
            let recipe = try #require(entry.recipe)
            let mbr = dir.appendingPathComponent("mbr.bin")
            try K48NAND.makeMBR(systemMiB: recipe.systemMiB).write(to: mbr)
            let parts = K48NAND.partitions(mbr: [UInt8](try Data(contentsOf: mbr)))
            let helpers = try K48Oracle.guestTools ?? K48Oracle.helpers(in: dir)
            var volumes: [[URL]] = []
            for run in ["a", "b"] {
                let work = dir.appendingPathComponent(run)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let r = try await Oracle.time("SystemEdits.buildK48 \(fw.entryID) \(run)") {
                    try await SystemEdits.buildK48(
                        rootfs: cache.appendingPathComponent("rootfs.dmg"),
                        work: work,
                        systemBytes: parts[0].count * 4096,
                        dataBytes: Int64(parts[1].count) * 4096,
                        options: .init(recipe: recipe),
                        helpers: helpers,
                        dataVolumeUUID: [1, 2, 3, 4, 5, 6, 7, 8]
                    ) { _ in }
                }
                volumes.append([r.system, r.data])
            }
            var same = true
            for (a, b) in zip(volumes[0], volumes[1]) {
                let diff = try Self.differingPages(a, b)
                same = same && diff.isEmpty
                #expect(
                    diff.isEmpty,
                    "\(fw.entryID) \(a.lastPathComponent): \(diff.count) differing pages: \(diff.prefix(16).joined(separator: "; "))"
                )
            }
            guard same else { return }
            let kv = try K48NAND.kernelVersion(kernelcache: cache.appendingPathComponent("kernelcache.mach"))
            var listings: [String] = []
            for run in ["a", "b"] {
                let store = dir.appendingPathComponent("store-" + run)
                try await K48NAND.build(
                    mbr: mbr,
                    kernelVersion: kv,
                    system: volumes[0][0],
                    data: .image(volumes[0][1]),
                    out: store
                )
                let files = try FileManager.default.contentsOfDirectory(atPath: store.path).sorted()
                listings.append(try Preparer.nandListing(store, files: files).sha256)
            }
            #expect(
                listings[0] == listings[1],
                "\(fw.entryID): the store differs between two builds from the same volumes"
            )
        }
    }

    /// "offset (region)" for every 4 KiB page that differs between two images of the same size; the region names
    /// the HFS+ structure at that offset of `a` (volume header, allocation/extents/catalog/attributes file, journal,
    /// or the file whose data fork covers it).
    static func differingPages(_ a: URL, _ b: URL) throws -> [String] {
        let da = try Data(contentsOf: a, options: .alwaysMapped)
        let db = try Data(contentsOf: b, options: .alwaysMapped)
        guard da.count == db.count else { return ["sizes differ: \(da.count) vs \(db.count)"] }
        let page = 4096
        var pages: [Int] = []
        da.withUnsafeBytes { pa in
            db.withUnsafeBytes { pb in
                var off = 0
                while off < da.count {
                    let n = min(page, da.count - off)
                    if memcmp(pa.baseAddress! + off, pb.baseAddress! + off, n) != 0 { pages.append(off) }
                    off += n
                }
            }
        }
        guard !pages.isEmpty else { return [] }
        let v = try HFSPlusVolume(a)
        var vh = [UInt8](repeating: 0, count: 512)
        _ = try Data(contentsOf: a, options: .alwaysMapped).withUnsafeBytes { memcpy(&vh, $0.baseAddress! + 1024, 512) }
        var regions: [(String, Int, Int)] = [
            ("volume header", 0, page), ("alternate volume header", v.totalBlocks * v.blockSize - 1024, 1024),
        ]
        if da.count - 1024 != v.totalBlocks * v.blockSize - 1024 {
            regions.append(("alternate volume header (file end)", da.count - 1024, 1024))
        }
        func forks(_ name: String, _ f: HFSPlusVolume.Fork) {
            for e in f.extents { regions.append((name, Int(e.start) * v.blockSize, Int(e.count) * v.blockSize)) }
        }
        forks("allocation file", HFSPlusVolume.Fork(vh, 112))
        forks("extents file", v.extentsFork)
        forks("catalog file", v.catalogFork)
        forks("attributes file", v.attributesFork)
        if let j = try v.journal() { regions.append(("journal", j.offset, j.size)) }
        let records = try v.catalog()
        let tree = try v.btree(v.catalogFork, fileID: HFSPlusVolume.catalogID)
        let catalogExtents = try v.extents(v.catalogFork, fileID: HFSPlusVolume.catalogID)
        return pages.map { off -> String in
            let at = (0..<page).first { da[off + $0] != db[off + $0] } ?? 0
            let hex = { (d: Data) in
                d[off + at..<min(off + at + 16, d.count)].map { String(format: "%02x", $0) }.joined()
            }
            let location = "\(off)+\(at) \(hex(da)) vs \(hex(db))"
            if let r = regions.first(where: { off >= $0.1 && off < $0.1 + $0.2 }) {
                guard r.0 == "catalog file" else { return "\(location) (\(r.0))" }
                // the catalog record (and the field offset in its body) at that byte
                var forkOff = 0
                var base = 0
                for e in catalogExtents {
                    let len = Int(e.count) * v.blockSize
                    let start = Int(e.start) * v.blockSize
                    if off + at >= start && off + at < start + len {
                        forkOff = base + (off + at - start)
                        break
                    }
                    base += len
                }
                let node = forkOff / tree.nodeSize
                let inNode = forkOff % tree.nodeSize
                let rec = records.first {
                    $0.node == node && inNode >= $0.bodyOffset && inNode < $0.bodyOffset + ($0.kind == .file ? 248 : 88)
                }
                return
                    "\(location) (catalog node \(node) byte \(inNode)\(rec.map { ": \($0.kind) \($0.name) cnid \($0.cnid) body+\(inNode - $0.bodyOffset)" } ?? ""))"
            }
            if let r = records.first(where: {
                $0.data?.extents.contains {
                    off >= Int($0.start) * v.blockSize && off < Int($0.start + $0.count) * v.blockSize
                } ?? false
            }) {
                return "\(location) (\(r.name))"
            }
            return location
        }
    }
}
