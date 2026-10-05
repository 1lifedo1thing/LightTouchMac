import Foundation
import Testing
@testable import FirmwareKit

struct N45FTLTests {
    static let banks = 4                               // the M68's; the N45's 8 take the same paths
    static let sb = N45NAND.superblock(banks), pp = N45NAND.page

    /// A prepared store (N45NAND.write) of a small HFSX-headed volume, and the volume.
    static func prepared(_ dir: URL) throws -> (base: URL, volume: [UInt8]) {
        let fsPages = 3 * sb - 3 - 50
        var vol = [UInt8](repeating: 0, count: fsPages * pp)
        vol[1024] = UInt8(ascii: "H"); vol[1025] = UInt8(ascii: "X")
        let blocks = UInt32(fsPages * pp / 4096)
        for (o, v) in [(1024 + 40, UInt32(4096)), (1024 + 44, blocks)] { for k in 0..<4 { vol[o + k] = UInt8(v >> (24 - 8 * k) & 0xFF) } }
        for p in 1..<fsPages { vol[p * pp] = UInt8(p % 251); vol[p * pp + 1] = 0x5A }
        let image = dir.appendingPathComponent("volume.img"), base = dir.appendingPathComponent("nand")
        try Data(vol).write(to: image)
        try N45NAND.write(volume: image, out: base, filID: 0x4330_3030, banks: banks)
        return (base, Array(vol[0..<Int(blocks) * 4096]))
    }

    static func put(_ root: URL, vpn: Int, _ data: [UInt8], _ spare: [UInt8]) throws {
        let p = N45NAND.location(vpn: vpn, banks: banks)
        let d = root.appendingPathComponent("bank\(p.bank)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data(data + spare).write(to: d.appendingPathComponent("\(p.page).page"))
    }

    static func le(_ b: inout [UInt8], _ o: Int, _ v: Int, _ n: Int) { for k in 0..<n { b[o + k] = UInt8(v >> (8 * k) & 0xFF) } }

    /// What a booted guest leaves in the overlay, built by hand: the context moved to virtual block 3 (lower usnDec
    /// than the prepared one), logical block 0 remapped to virtual block 30 with page 10 changed, and a log block
    /// (virtual block 31) holding a newer copy of logical block 1's page 5. `clean: false` ends the context block
    /// on a map page instead of the context.
    static func booted(_ ovl: URL, _ base: URL, clean: Bool = true) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: ovl, withIntermediateDirectories: true)
        let ctxVB = 3, start = ctxVB * sb
        try put(ovl, vpn: start, [UInt8](repeating: 0, count: pp), N45NAND.cxtSpare(type: 0x43, index: 0, age: 0xFFFF_FFF0))
        for i in 0..<N45NAND.mapTables {                 // the map, lbn 0 -> vbn 30
            var page = [UInt8](repeating: 0xFF, count: pp)
            for j in 0..<pp / 2 {
                let lbn = i * pp / 2 + j
                if lbn < N45NAND.mappedLBNs { le(&page, 2 * j, lbn == 0 ? 30 : lbn + N45NAND.dataStart, 2) }
            }
            try put(ovl, vpn: start + 1 + i, page, N45NAND.cxtSpare(type: 0x46, index: i, age: 0xFFFF_FFF0))
        }
        let offsetPages = (N45FTL.logs * sb * 2 + pp - 1) / pp
        var offsets = [UInt8](repeating: 0xFF, count: offsetPages * pp)
        le(&offsets, 2 * 5, 2, 2)                          // slot 0, offset 5 -> page 2 of its log block
        for i in 0..<offsetPages {
            try put(ovl, vpn: start + 5 + i, Array(offsets[i * pp..<(i + 1) * pp]), N45NAND.cxtSpare(type: 0x44, index: i, age: 0xFFFF_FFF0))
        }
        var cxt = N45NAND.ftlMeta(banks: banks)
        for i in 0..<N45NAND.mapTables { le(&cxt, 0x38 + 4 * i, start + 1 + i, 4) }
        for i in 0..<offsetPages { le(&cxt, 0x110 + 4 * i, start + 5 + i, 4) }
        le(&cxt, 0x1A4 + 4, 31, 2); le(&cxt, 0x1A4 + 6, 1, 2)
        for i in 0..<3 { le(&cxt, 0x312 + 2 * i, ctxVB + i, 2) }
        let last = start + 5 + offsetPages
        if clean {
            try put(ovl, vpn: last, cxt, N45NAND.cxtSpare(type: 0x43, index: 0, age: 0xFFFF_FFF0))
        } else {
            try put(ovl, vpn: last, [UInt8](repeating: 0, count: pp), N45NAND.cxtSpare(type: 0x46, index: 0, age: 0xFFFF_FFF0))
        }
        // logical block 0 copied to virtual block 30 with page 10 changed; the log page for lbn 1 offset 5
        for off in 0..<sb {
            guard let (d, s) = N45FTL.page(base, nil, N45NAND.location(lpn: off, banks: banks)) else { continue }
            try put(ovl, vpn: 30 * sb + off, off == 10 ? [UInt8](repeating: 0xA1, count: pp) : d, s)
        }
        try put(ovl, vpn: 31 * sb + 2, [UInt8](repeating: 0xB2, count: pp), N45NAND.dataSpare(sb + 5))
    }

    /// A fresh store reads back as its volume, through the prepared context.
    @Test func preparedStore() throws {
        let dir = try Fixtures.tempDir("n45ftl-prepared")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (base, vol) = try Self.prepared(dir)
        #expect(try VolumeRebuild.board(of: base) == .legacy)
        let ftl = try N45FTL(base: base, overlay: nil)
        #expect(ftl.banks == Self.banks && ftl.logBlocksInUse == 0)
        let v = try VolumeRebuild.rebuild(base: base, overlay: nil, into: dir.appendingPathComponent("out"))
        #expect(v.map(\.name) == ["system"] && v[0].bytes == vol.count)
        #expect([UInt8](try Data(contentsOf: v[0].image)) == vol)
    }

    /// A booted overlay: the moved context, the remapped block and the log page win; the rest is the base's.
    @Test func bootedOverlay() throws {
        let dir = try Fixtures.tempDir("n45ftl-booted")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (base, vol) = try Self.prepared(dir)
        let ovl = dir.appendingPathComponent("overlay")
        try Self.booted(ovl, base)
        let ftl = try N45FTL(base: base, overlay: ovl)
        #expect(ftl.logBlocksInUse == 1)
        #expect(ftl.location(lpn: 10) == N45NAND.location(vpn: 30 * Self.sb + 10, banks: Self.banks))
        #expect(ftl.location(lpn: Self.sb + 5) == N45NAND.location(vpn: 31 * Self.sb + 2, banks: Self.banks))
        #expect(ftl.location(lpn: Self.sb + 6) == N45NAND.location(lpn: Self.sb + 6, banks: Self.banks))
        let img = [UInt8](try Data(contentsOf: VolumeRebuild.rebuild(base: base, overlay: ovl, into: dir.appendingPathComponent("out"))[0].image))
        let first = N45NAND.firstLBA, pp = Self.pp
        func page(_ lpn: Int) -> ArraySlice<UInt8> { img[(lpn - first) * pp..<(lpn - first + 1) * pp] }
        func want(_ lpn: Int) -> ArraySlice<UInt8> { vol[(lpn - first) * pp..<(lpn - first + 1) * pp] }
        #expect(page(10).allSatisfy { $0 == 0xA1 } && page(Self.sb + 5).allSatisfy { $0 == 0xB2 })
        #expect(page(11) == want(11) && page(Self.sb + 6) == want(Self.sb + 6) && page(2 * Self.sb + 1) == want(2 * Self.sb + 1))
    }

    /// The context block not ending in the context (an unclean stop) is refused, not guessed at.
    @Test func uncleanRefused() throws {
        let dir = try Fixtures.tempDir("n45ftl-unclean")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (base, _) = try Self.prepared(dir)
        let ovl = dir.appendingPathComponent("overlay")
        try Self.booted(ovl, base, clean: false)
        #expect(throws: FirmwareError.self) { try N45FTL(base: base, overlay: ovl) }
    }
}
