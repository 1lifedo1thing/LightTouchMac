import CryptoKit
import DeviceRuntime
import Foundation
import HostRuntime
import Testing
@testable import LightTouchCore

/// GuestPackageSession's qualification of one cold boot (health budgets, record verdicts, one-shot completion), its
/// async owner under BootSessionScope, and GuestPackage's "not responding" judgement for an offer.
struct GuestPackageSessionTests {
    let offer = GuestPackage.Offer(bundled: 7, version: "1.7", serial: 7, glHook: true)
    let report = GuestPackageReport(serial: 7, result: 1)
    var record: DeviceInstance.Guest {
        var record = DeviceInstance.Guest()
        record.seed = 1; record.bad = [7, 9]; record.builtIn = 6
        return record
    }
    func observation(_ healthy: Bool, _ report: GuestPackageReport?, _ record: DeviceInstance.Guest?) -> GuestPackageSession.Observation {
        .init(report: report, record: record, glesProtocol: 1, healthy: healthy)
    }
    func observation(_ healthy: Bool) -> GuestPackageSession.Observation { observation(healthy, report, record) }

    @Test func continuousHealthMakesThePackageGoodOnce() throws {
        var record = record
        var session = GuestPackageSession(offer: offer)
        let firstUpdate = session.observe(observation(true), elapsed: .seconds(1))
        let first = try #require(firstUpdate)
        #expect(first.changedReport == report && first.verdict == nil)
        first.apply(to: &record)
        #expect(record.active == 7 && record.bad == [7, 9])
        #expect(session.observe(observation(true), elapsed: .seconds(9))?.changedReport == nil)
        // Losing guest health resets the continuous qualification interval.
        #expect(session.observe(observation(false), elapsed: .seconds(10))?.verdict == nil)
        #expect(session.observe(observation(true), elapsed: .seconds(11))?.verdict == nil)
        #expect(session.observe(observation(true), elapsed: .seconds(20))?.verdict == nil)
        let goodUpdate = session.observe(observation(true), elapsed: .seconds(21))
        let good = try #require(goodUpdate)
        #expect(good.verdict == .good(7) && good.changesRecord)
        good.apply(to: &record)
        #expect(record.lastGood == 7 && record.bad == [9] && record.seed == 1 && record.builtIn == 6)
        #expect(session.observe(observation(true), elapsed: .seconds(22)) == nil, "one boot must never publish a second verdict")
    }

    @Test func neverHealthyIsBadOnceRecorded() throws {
        var session = GuestPackageSession(offer: offer)
        var fresh = DeviceInstance.Guest(); fresh.seed = 1
        #expect(session.observe(observation(false, report, fresh), elapsed: .seconds(299))?.verdict == nil)
        let failureUpdate = session.observe(observation(false, report, fresh), elapsed: .seconds(300))
        let failure = try #require(failureUpdate)
        #expect(failure.verdict == .bad(7))
        failure.apply(to: &fresh); failure.apply(to: &fresh)
        #expect(fresh.bad == [7], "retrying record publication must not duplicate bad serials")
    }

    /// The seed and the last good package are never judged bad.
    @Test(arguments: [Int64(1), Int64(7)])
    func protectedSerialsAreUndecided(_ serial: Int64) throws {
        var record = record
        record.lastGood = 7
        var session = GuestPackageSession(offer: offer)
        let report = GuestPackageReport(serial: serial, result: 0)
        let resultUpdate = session.observe(observation(false, report, record), elapsed: .seconds(300))
        let result = try #require(resultUpdate)
        #expect(result.verdict == .undecided && result.changedReport == report)
        var saved = record
        result.apply(to: &saved)
        #expect(saved.bad == record.bad && saved.active == serial)
    }

    @Test func noReportOnceHealthyIsLegacy() throws {
        var session = GuestPackageSession(offer: offer)
        #expect(session.observe(observation(true, nil, record), elapsed: .seconds(1))?.verdict == nil)
        #expect(session.observe(observation(true, nil, record), elapsed: .seconds(30))?.verdict == nil)
        let legacyUpdate = session.observe(observation(true, nil, record), elapsed: .seconds(31))
        let legacy = try #require(legacyUpdate)
        #expect(legacy.verdict == .legacy && legacy.status == .legacy && !legacy.changesRecord)
        var incompatible = GuestPackageSession(offer: offer)
        var glesTooNew = observation(true)
        glesTooNew.glesProtocol = 100
        #expect(incompatible.observe(glesTooNew, elapsed: .zero)?.status == .outOfDate)
    }

    /// Retirement prevents delayed sampling and publication, and renewal starts fresh state.
    @Test func retiredBootPublishesNothingAndRenewalStartsFresh() async throws {
        let offer = offer, report = report, healthy = observation(true)
        let scope = BootSessionScope()
        var samples = 0, writes = 0
        scope[.guestPackage] = Task {
            await GuestPackageSession.watch(offer: offer, interval: .milliseconds(100), sample: { samples += 1; return healthy },
                                            publish: { _ in writes += 1 })
        }
        await Task.yield()
        let retiredTask = try #require(scope[.guestPackage])
        scope.retire()
        await retiredTask.value
        try await Task.sleep(for: .milliseconds(130))
        #expect(samples == 0 && writes == 0, "a retired boot published delayed package state")
        scope.renew()
        scope[.guestPackage] = Task {
            await GuestPackageSession.watch(offer: offer, interval: .milliseconds(1), sample: {
                samples += 1; return samples == 1 ? healthy : nil
            }, publish: { update in
                #expect(update.changedReport == report && update.verdict == nil)
                writes += 1
            })
        }
        await scope[.guestPackage]?.value
        #expect(samples == 2 && writes == 1, "a new boot must not reuse a retired boot's seen report")
        scope.retire()
    }

    @Test func cancellationAfterAReportPreventsTheNextPublication() async throws {
        let offer = offer, healthy = observation(true)
        var writes = 0
        let watch = Task {
            await GuestPackageSession.watch(offer: offer, interval: .milliseconds(30), sample: { healthy }, publish: { _ in writes += 1 })
        }
        for _ in 0..<100 where writes == 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(writes == 1)
        watch.cancel()
        await watch.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(writes == 1, "cancellation after a report must prevent the next publication")
    }

    @Test func missingObservationStopsTheOwner() async {
        var samples = 0
        await GuestPackageSession.watch(offer: offer, interval: .milliseconds(1), sample: { samples += 1; return nil },
                                        publish: { _ in Issue.record("published without an observation") })
        #expect(samples == 1)
    }
}

/// Guest tools are "not responding" only for a package that has something to answer: an itpack shaped like the
/// shipped one (1.x's n45-ios1: an OpenGLES hook, no jobs; the iPad's k48-ios4: it_agent, it_ethlink) goes through
/// GuestPackage.compose and ethlinkSilent.
struct GuestToolsStatusTests {
    typealias Files = [(name: String, data: Data)]

    static func manifest(_ family: String, boards: [String], builds: [String], jobs: [String], _ files: Files) -> Data {
        let entries = files.map { f in
            ["name": f.name, "mode": "0755", "size": f.data.count,
             "sha256": SHA256.hash(data: f.data).map { String(format: "%02x", $0) }.joined()] as [String: Any]
        }
        let m: [String: Any] = ["serial": 14, "version": "1.1.12", "family": family, "arch": "armv6",
                                "requires": ["boards": boards, "builds": builds, "host": ["guest-package": [1, 1]]],
                                "files": entries, "jobs": jobs, "hooks": [] as [Any]]
        return try! JSONSerialization.data(withJSONObject: m)
    }

    /// "ITPACK01", a little-endian u32 index length, the JSON index, a zlib stream (header, raw deflate).
    static func itpack(_ url: URL, _ packages: [(family: String, manifest: Data, files: Files)]) throws {
        var entries: Files = []
        for p in packages { entries.append((p.family + "/manifest.json", p.manifest)); entries += p.files.map { (p.family + "/" + $0.name, $0.data) } }
        let index = try JSONSerialization.data(withJSONObject: ["format": 1, "entries": entries.map { ["name": $0.name, "size": $0.data.count] }])
        let stream = try (entries.reduce(Data()) { $0 + $1.data } as NSData).compressed(using: .zlib) as Data
        var length = UInt32(index.count).littleEndian
        try (GuestPack.magic + Data(bytes: &length, count: 4) + index + Data([0x78, 0x9c]) + stream).write(to: url)
    }

    @Test func onlyAPackageWithEthlinkCanBeSilent() throws {
        try withTemporaryDirectory { work in
            let hook: Files = [("hooks/OpenGLES", Data("\0hook".utf8))]
            let k48: Files = [("bin/it_agent", Data("\0agent".utf8)), ("bin/it_ethlink", Data("\0ethlink".utf8))]
            let pack = work.appendingPathComponent("pack.itpack")
            try Self.itpack(pack, [
                ("n45-ios1", Self.manifest("n45-ios1", boards: ["n45ap"], builds: ["3*", "4*"], jobs: [], hook), hook),
                ("k48-ios4", Self.manifest("k48-ios4", boards: ["k48ap"], builds: ["8*"],
                                           jobs: ["jobs/com.qemu.it-agent.plist", "jobs/com.qemu.it-ethlink.plist"], k48), k48)])
            let n45Offer = try #require(try GuestPackage.compose(itpack: pack, board: "n45ap", build: "3A101a", lock: nil, guest: nil,
                                                                 into: work.appendingPathComponent("n45")))
            let k48Offer = try #require(try GuestPackage.compose(itpack: pack, board: "k48ap", build: "8C148", lock: nil, guest: nil,
                                                                 into: work.appendingPathComponent("k48")))
            #expect(!n45Offer.ethlink && k48Offer.ethlink)
            // Installed (report serial 14), lockdown up for a minute, no it_ethlink line: the 1G has nothing to say.
            #expect(!GuestPackage.ethlinkSilent(offer: n45Offer, reportedSerial: 14, ethlinkUp: false, reachableForAMinute: true),
                    "the 1.x package carries no it_ethlink, yet its silence reads as not responding")
            #expect(GuestPackage.ethlinkSilent(offer: k48Offer, reportedSerial: 14, ethlinkUp: false, reachableForAMinute: true),
                    "the iPad's missing it_ethlink no longer reads as not responding")
            #expect(!GuestPackage.ethlinkSilent(offer: k48Offer, reportedSerial: 14, ethlinkUp: true, reachableForAMinute: true))
            #expect(!GuestPackage.ethlinkSilent(offer: k48Offer, reportedSerial: 14, ethlinkUp: false, reachableForAMinute: false))
            #expect(!GuestPackage.ethlinkSilent(offer: k48Offer, reportedSerial: nil, ethlinkUp: false, reachableForAMinute: true))
        }
    }
}
