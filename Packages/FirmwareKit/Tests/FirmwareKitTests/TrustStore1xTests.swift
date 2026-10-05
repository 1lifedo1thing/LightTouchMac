import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import FirmwareKit

struct TrustStore1xTests {
    static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag, UInt8(body.count)] + body }
    /// A certificate skeleton: version, serial, signature, issuer, validity, subject (C=us PrintableString,
    /// CN=Light Touch UTF8String); nothing after the subject matters to the normalization.
    static let subjectContent = tlv(0x31, tlv(0x30, tlv(0x06, [0x55, 0x04, 0x06]) + tlv(0x13, Array("us".utf8))))
        + tlv(0x31, tlv(0x30, tlv(0x06, [0x55, 0x04, 0x03]) + tlv(0x0c, Array("Light Touch".utf8))))
    static let certificate = Data(tlv(0x30, tlv(0x30, tlv(0xa0, tlv(0x02, [2])) + tlv(0x02, [1]) + tlv(0x30, tlv(0x06, [0x2a]))
        + tlv(0x30, []) + tlv(0x30, []) + tlv(0x30, subjectContent))))

    /// 1.x stores PrintableString values uppercased and every other string type as issued (the stock store's
    /// "Prefectural Association For JPKI" is a UTF8String kept as it is; Entrust's "ENTRUST.NET" a PrintableString).
    @Test func normalizesPrintableStringsOnly() throws {
        let normalized = try TrustStore1x.normalizedSubject(Self.certificate)
        var expected = Self.subjectContent
        let us = expected.firstIndex(of: UInt8(ascii: "u"))!
        expected[us] = UInt8(ascii: "U"); expected[us + 1] = UInt8(ascii: "S")
        #expect(normalized == Data(expected))
        #expect(String(decoding: normalized, as: UTF8.self).contains("Light Touch"))
    }

    /// Every anchor in a 1.x firmware's own store (FK_TRUSTSTORE_1X: its Security.framework/TrustStore.sqlite3):
    /// its subj column is normalizedSubject of its data, its tset the empty settings.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func matchesTheStockStore() throws {
        guard let path = ProcessInfo.processInfo.environment["FK_TRUSTSTORE_1X"] else { try FixtureRequirements.missing("FK_TRUSTSTORE_1X") }
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT subj,data,tset FROM tsettings", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        var rows = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let subj = Data(bytes: sqlite3_column_blob(stmt, 0), count: Int(sqlite3_column_bytes(stmt, 0)))
            let data = Data(bytes: sqlite3_column_blob(stmt, 1), count: Int(sqlite3_column_bytes(stmt, 1)))
            #expect(try TrustStore1x.normalizedSubject(data) == subj)
            #expect(Data(bytes: sqlite3_column_blob(stmt, 2), count: Int(sqlite3_column_bytes(stmt, 2))) == TrustStore1x.emptySettings)
            rows += 1
        }
        #expect(rows > 100)
    }

    @Test func addsAnAnchorRowAsTheStockRowsAre() throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("ts-\(UUID()).sqlite3")
        defer { try? FileManager.default.removeItem(at: store) }
        var db: OpaquePointer?
        #expect(sqlite3_open(store.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE tsettings(sha1 BLOB NOT NULL DEFAULT '',subj BLOB NOT NULL DEFAULT '',tset BLOB,data BLOB,PRIMARY KEY(sha1));", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        try TrustStore1x.addAnchor(Self.certificate, to: store)
        try TrustStore1x.addAnchor(Self.certificate, to: store)          // idempotent: one row per certificate

        #expect(sqlite3_open(store.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT sha1,subj,tset,data FROM tsettings", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        func blob(_ i: Int32) -> Data { Data(bytes: sqlite3_column_blob(stmt, i), count: Int(sqlite3_column_bytes(stmt, i))) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(blob(0) == Data(Insecure.SHA1.hash(data: Self.certificate)))
        #expect(blob(1) == (try TrustStore1x.normalizedSubject(Self.certificate)))
        #expect(blob(2) == TrustStore1x.emptySettings)
        #expect(blob(3) == Self.certificate)
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
    }
}
