import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import LightTouchCore

/// A writer that writes "movie" at start and can fail where told (the encoder, a frame's audio).
private actor FakeWriter: ScreenMovieRecording {
    var starts = 0
    var failStartup = false
    var failFrame = 0
    private var output: URL?
    private var frames = 0

    func configure(failStartup: Bool? = nil, failFrame: Int? = nil) {
        if let failStartup { self.failStartup = failStartup }
        if let failFrame { self.failFrame = failFrame }
    }

    func start(url: URL, audio: GuestAudioCapture?, canvasSize: CGSize?, background: CGImage?, screenSide: CGFloat)
        async throws
    {
        starts += 1
        frames = 0
        try await Task.sleep(for: .milliseconds(30))
        if failStartup { throw CaptureError.failed("Encoder unavailable") }
        output = url
        try Data("movie".utf8).write(to: url)
    }
    func append(_ image: CGImage?, seconds: Double) async throws {
        frames += 1
        if frames == failFrame { throw CaptureError.failed("Audio buffer overflow") }
    }
    func finish(seconds: Double) async throws {
        #expect(frames > 0 && seconds > 0)
        output = nil
    }
    func cancel() async {
        if let output { try? FileManager.default.removeItem(at: output) }
        output = nil
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ltm-tests-" + UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.resolvingSymlinksInPath()
}

/// Polls the main actor until `check` holds; the deadline only guards a hang.
private func wait(_ check: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !check(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(check(), "timed out")
}

/// A recording's lifecycle (sounds, atomic saves, the fallback picker, typed outcomes, explicit discard) and launch
/// recovery of earlier takes.
struct ScreenRecordingSessionTests {
    let thumbnail = CGContext(
        data: nil,
        width: 16,
        height: 24,
        bitsPerComponent: 8,
        bytesPerRow: 64,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!.makeImage()!

    @Test func lifecycleSoundsSavesAndRecovery() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = FakeWriter()
        let folder = root.appendingPathComponent("Recordings")
        let session = ScreenRecordingSession(writer: writer, folder: folder)
        var cues: [String] = []
        var completions: [Bool] = []
        session.onBeganRecording = { cues.append("start") }
        session.onStoppedRecording = { cues.append("stop") }
        session.onFinished = { completions.append($0) }
        let output = root.appendingPathComponent("saved.mov")
        let thumbnail = thumbnail
        session.start(frame: { thumbnail }, destination: { output })
        session.start(
            frame: { nil },
            destination: {
                Issue.record("duplicate start")
                return output
            }
        )
        session.stop()
        #expect(session.phase == .saving)
        try await wait { !session.isActive }
        #expect(session.phase == .saved(output) && completions == [true])
        #expect(cues.isEmpty, "a take stopped during startup must not play success sounds")
        #expect(session.previewImage === thumbnail, "saved recording lost its thumbnail")
        #expect(try Data(contentsOf: output) == Data("movie".utf8))

        session.start(
            frame: { nil },
            destination: {
                Issue.record("discard must not save")
                return output
            }
        )
        #expect(session.previewImage == nil, "a new recording retained the previous thumbnail")
        session.stop(discard: true)
        try await wait { !session.isActive }
        #expect(session.phase == .idle && completions == [true, true])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

        // An existing destination must survive an automatic save collision.
        session.start(frame: { nil }, destination: { output })
        try await wait { session.phase == .recording }
        #expect(cues == ["start"])
        session.stop()
        session.stop()
        #expect(cues == ["start", "stop"], "stop must play once, including repeated stop requests")
        try await wait { !session.isActive }
        guard case .recovery(let recovery) = session.phase else {
            Issue.record("no recovery: \(session.phase)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: recovery.path))
        let starts = await writer.starts
        session.start(frame: { nil }, destination: { output })
        #expect(await writer.starts == starts, "no new take while one waits to be saved")

        // A failed retry retains the same movie and reports completion (quit cannot hang).
        session.retrySave(to: root.appendingPathComponent("missing/output.mov"))
        try await wait { !session.isActive }
        #expect(session.phase == .recovery(recovery) && completions.last == false)
        let retry = root.appendingPathComponent("retry.mov")
        try Data("old".utf8).write(to: retry)
        session.retrySave(to: retry)
        try await wait { !session.isActive }
        #expect(session.phase == .saved(retry) && completions.last == true)
        #expect(cues == ["start", "stop"], "retrying a save must not play recording cues")
        #expect(!FileManager.default.fileExists(atPath: recovery.path))
        #expect(try Data(contentsOf: retry) == Data("movie".utf8))

        // Dismiss leaves recovery files durable and permits another capture.
        session.start(frame: { nil }, destination: { output })
        session.stop()
        try await wait { !session.isActive }
        guard case .recovery(let retained) = session.phase else {
            Issue.record("no recovery")
            return
        }
        session.dismiss()
        #expect(FileManager.default.fileExists(atPath: retained.path))

        await writer.configure(failFrame: 3)
        session.start(frame: { nil }, destination: { output })
        try await wait { !session.isActive }
        guard case .recovery(let partial) = session.phase else {
            Issue.record("lost partial movie")
            return
        }
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect(session.failure?.localizedDescription == "Audio buffer overflow")
        #expect(cues == ["start", "stop", "start", "stop"], "an interrupted take must finish its sound pair")
        session.retrySave(to: partial)
        try await wait { !session.isActive }
        #expect(
            session.phase == .saved(partial) && FileManager.default.fileExists(atPath: partial.path),
            "saving in place keeps the file"
        )
        session.dismiss()

        await writer.configure(failStartup: true, failFrame: 0)
        session.start(frame: { nil }, destination: { output })
        session.stop()
        try await wait { !session.isActive }
        #expect(session.phase == .idle && session.failure?.localizedDescription == "Encoder unavailable")
        #expect(cues == ["start", "stop", "start", "stop"], "failed startup must not play recording cues")
    }

    /// A preferred-folder failure opens one save panel while the take remains busy, without announcing failure first;
    /// cancelling keeps the sole copy; discard is explicit; an invalid choice doesn't loop the picker.
    @Test func fallbackPicker() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallback = ScreenRecordingSession(writer: FakeWriter(), folder: root.appendingPathComponent("Recordings"))
        var outcomes: [ScreenRecordingSession.Completion] = []
        fallback.onCompleted = { outcomes.append($0) }
        let output = root.appendingPathComponent("saved.mov")
        let alternate = root.appendingPathComponent("alternate.mov")
        try Data("existing".utf8).write(to: output)
        try Data("replace me".utf8).write(to: alternate)
        var panels = 0
        fallback.chooseSaveDestination = { _ in
            #expect(fallback.phase == .saving && outcomes.isEmpty)
            panels += 1
            return alternate
        }
        let thumbnail = thumbnail
        fallback.start(frame: { thumbnail }, destination: { output })
        fallback.stop()
        try await wait { !fallback.isActive }
        #expect(fallback.phase == .saved(alternate) && outcomes == [.saved(alternate)] && panels == 1)
        #expect(fallback.failure == nil)
        #expect(try Data(contentsOf: alternate) == Data("movie".utf8))
        #expect(try Data(contentsOf: output) == Data("existing".utf8), "an automatic save never replaces a file")

        fallback.chooseSaveDestination = { _ in
            panels += 1
            return nil
        }
        fallback.start(frame: { thumbnail }, destination: { throw CaptureError.failed("Folder unavailable") })
        fallback.stop()
        try await wait { !fallback.isActive }
        guard case .recovery(let cancelledSave) = fallback.phase else {
            Issue.record("panel cancellation lost recovery")
            return
        }
        #expect(outcomes.last == .recovery(cancelledSave) && panels == 2)
        #expect(FileManager.default.fileExists(atPath: cancelledSave.path))
        fallback.discardRecovery()
        #expect(outcomes.last == .discarded && fallback.phase == .idle && fallback.failure == nil)
        #expect(!FileManager.default.fileExists(atPath: cancelledSave.path))

        fallback.chooseSaveDestination = { _ in
            panels += 1
            return root.appendingPathComponent("missing/fallback.mov")
        }
        fallback.start(frame: { thumbnail }, destination: { output })
        fallback.stop()
        try await wait { !fallback.isActive }
        guard case .recovery(let failedSave) = fallback.phase else {
            Issue.record("failed fallback lost recovery")
            return
        }
        #expect(panels == 3 && outcomes.last == .recovery(failedSave))
        fallback.retrySave(to: root.appendingPathComponent("fixed.mov"))
        try await wait { !fallback.isActive }
        #expect(outcomes.last == .saved(root.appendingPathComponent("fixed.mov")) && panels == 3)
    }

    /// Launch recovery saves older playable takes, keeps what it can't save, deletes unplayable ones, and never touches
    /// the current take, links, folders or other files.
    @Test func launchRecovery() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Recordings", isDirectory: true)
        let recovered = root.appendingPathComponent("Saved", isDirectory: true)
        let missing = try await ScreenRecordingSession.recoverRecordings(in: directory, createdBefore: Date()) { _ in
            Issue.record("no files yet")
            return recovered
        }
        #expect(missing.saved.isEmpty && missing.remaining.isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recovered, withIntermediateDirectories: true)
        let context = CGContext(
            data: nil,
            width: 32,
            height: 48,
            bitsPerComponent: 8,
            bytesPerRow: 128,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        let image = context.makeImage()!
        let valid = directory.appendingPathComponent("valid.mov")
        let writer = ScreenMovieWriter()
        try await writer.start(url: valid, canvasSize: CGSize(width: 32, height: 48))
        try await writer.append(image, seconds: 0)
        try await Task.sleep(for: .milliseconds(30))
        try await writer.append(image, seconds: 0.1)
        try await writer.finish(seconds: 0.2)
        let collision = directory.appendingPathComponent("collision.mov")
        let blocked = directory.appendingPathComponent("blocked.mov")
        try FileManager.default.copyItem(at: valid, to: collision)
        try FileManager.default.copyItem(at: valid, to: blocked)
        let corrupt = directory.appendingPathComponent("incomplete.mov")
        try Data("incomplete recording".utf8).write(to: corrupt)
        let untouched = directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: untouched)
        let nested = directory.appendingPathComponent("folder.mov", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("linked.mov"),
            withDestinationURL: valid
        )
        let existing = recovered.appendingPathComponent("collision.mov")
        try Data("existing capture".utf8).write(to: existing)
        let launchDate = Date()
        try await Task.sleep(for: .milliseconds(100))
        let current = directory.appendingPathComponent("current.mov")
        try Data("currently being written".utf8).write(to: current)

        var requested: [String] = []
        let report = try await ScreenRecordingSession.recoverRecordings(in: directory, createdBefore: launchDate) {
            source in
            requested.append(source.lastPathComponent)
            if source.lastPathComponent == blocked.lastPathComponent {
                throw CaptureError.failed("Preferred location unavailable")
            }
            return recovered.appendingPathComponent(source.lastPathComponent)
        }
        #expect(Set(requested) == ["valid.mov", "collision.mov", "blocked.mov"])
        #expect(
            report.saved == [recovered.appendingPathComponent("valid.mov")],
            "saved=\(report.saved) remaining=\(report.remaining)"
        )
        #expect(Set(report.remaining.map(\.lastPathComponent)) == Set([collision, blocked].map(\.lastPathComponent)))
        #expect(
            report.deleted.map(\.lastPathComponent) == [corrupt.lastPathComponent]
                && !FileManager.default.fileExists(atPath: corrupt.path)
        )
        #expect(!FileManager.default.fileExists(atPath: valid.path))
        for retained in [collision, blocked, current, untouched, nested] {
            #expect(
                FileManager.default.fileExists(atPath: retained.path),
                "recovery discarded \(retained.lastPathComponent)"
            )
        }
        #expect(try Data(contentsOf: existing) == Data("existing capture".utf8))
        #expect(try await AVURLAsset(url: report.saved[0]).load(.isPlayable))
        // A second pass can recover a previously blocked destination without overwriting the collision or touching the current take.
        let retry = try await ScreenRecordingSession.recoverRecordings(in: directory, createdBefore: launchDate) {
            source in
            recovered.appendingPathComponent("retry-" + source.lastPathComponent)
        }
        #expect(Set(retry.saved.map(\.lastPathComponent)) == ["retry-blocked.mov", "retry-collision.mov"])
        #expect(retry.remaining.isEmpty && retry.deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: current.path))
    }
}
