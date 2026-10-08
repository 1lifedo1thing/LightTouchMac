import Foundation
import Testing

@testable import LightTouchCore

/// usbmuxd that dies is started again on the sockets the emulator dials, a few times; given up, a new boot starts it.
struct USBMuxTests {
    /// State audit A-11: an unexpected daemon death left app management off until Force Stop then Start.
    @Test func aDaemonThatDiesStartsAgainOnItsSockets() async throws {
        try await withScratchDirectory { directory in
            let starts = directory.appendingPathComponent("starts")
            let daemon = directory.appendingPathComponent("usbmuxd")
            try "#!/bin/sh\necho \"$USBMUXD_QEMU_ADDR\" >> '\(starts.path)'\nsleep 0.2\n".write(
                to: daemon,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daemon.path)
            let paths = DeviceInstance.Paths(
                directory: directory,
                base: directory,
                overlay: directory,
                writableNOR: nil,
                snapshot: directory.appendingPathComponent("snapshot"),
                usbmuxConf: directory.appendingPathComponent("conf"),
                work: directory.appendingPathComponent("work"),
                logs: directory.appendingPathComponent("logs")
            )
            func launches() -> [String] {
                ((try? String(contentsOf: starts, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            }
            var gaveUp = false
            let mux = USBMux(binary: daemon.path) { gaveUp = true }
            let session = try #require(mux.start(paths: paths))
            await eventually("started again") { launches().count >= 2 }
            #expect(mux.session?.guestAddress == session.guestAddress, "the same sockets")
            await eventually("given up") { gaveUp }
            #expect(launches().count == 1 + USBMux.restartLimit && mux.session == nil)
            #expect(Set(launches()) == [session.guestAddress])

            mux.ensureRunning()
            #expect(mux.session?.guestAddress == session.guestAddress, "a new boot starts it on the same sockets")
            await eventually("started for the new boot") { launches().count == 2 + USBMux.restartLimit }
            mux.stop()
        }
    }
}
