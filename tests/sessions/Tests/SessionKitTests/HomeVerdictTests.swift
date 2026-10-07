import Foundation
import Testing
@testable import SessionKit

/// The Home verdict on fabricated driver events: a black or slept shot, a wrong frontmost app, the lock screen (also
/// SpringBoard), an agent that never answered and a frame that differs from its reference all fail; a build with no
/// agent and no reference is unknown, never a pass.
struct HomeVerdictTests {
    static let refs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../matrix-refs").standardized
    nonisolated(unsafe) static let agentLock: [String: Any] = ["guest_package": ["jobs": ["com.qemu.it-agent.plist"]]]

    func events(brightness: Double = 0.4, frontmost: String = "com.apple.springboard", screen: String = "Home Screen",
                path: String = "/nonexistent/home.png") -> Events {
        Events([["event": "screenshot", "path": path, "brightness": brightness],
                ["event": "home", "generation": 1, "frontmost": frontmost, "screen": screen]])
    }

    func verdict(_ e: Events, lock: [String: Any] = agentLock, entry: String = "n72ap-7E18") -> Bool? {
        SessionJudge.home(lock: lock, events: e, entryID: entry, references: Self.refs).ok
    }

    @Test func theAgentsHomeScreenPasses() { #expect(verdict(events()) == true) }
    @Test func aDarkShotFails() { #expect(verdict(events(brightness: 0.01)) == false) }
    @Test func aWrongFrontmostAppFails() { #expect(verdict(events(frontmost: "com.apple.Preferences", screen: "Settings")) == false) }
    @Test func theLockScreenIsNotHome() { #expect(verdict(events(screen: "Lock Screen")) == false) }
    @Test func anUnansweredAgentFails() { #expect(verdict(events(frontmost: "", screen: "")) == false) }

    @Test func noAgentAndNoReferenceIsUnknown() {
        #expect(verdict(events(frontmost: "", screen: ""), lock: [:]) == nil)
    }

    /// A capture named as the driver names it (home.png), copied from `reference`.
    func shot(_ reference: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("home-verdict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("home.png")
        try FileManager.default.copyItem(at: Self.refs.appendingPathComponent(reference), to: path)
        return path.path
    }

    @Test func aReferenceDecidesWithoutAnAgent() throws {
        let right = try shot("m68ap-1A543a-home.png"), wrong = try shot("n72ap-5F138-home.png")
        defer { [right, wrong].forEach { try? FileManager.default.removeItem(atPath: ($0 as NSString).deletingLastPathComponent) } }
        #expect(verdict(events(frontmost: "", screen: "", path: right), lock: [:], entry: "m68ap-1A543a") == true)
        #expect(verdict(events(frontmost: "", screen: "", path: wrong), lock: [:], entry: "m68ap-1A543a") == false)
    }

    @Test func noShotIsNoVerdict() { #expect(verdict(Events([])) == nil) }
}
