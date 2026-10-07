import AppKit
import Foundation
import Metal
import Testing
import DeviceRuntime
@testable import LightTouchCore
@testable import Helper

extension SharedState {
/// The helper's pieces that need no emulator: the libqemu binding's API check, the frame surface's colors, the
/// native log capture.
@Suite struct HelperTests {
    /// The helper loads only a libqemu-arm.dylib whose C API major version is its own (qemu_ios_api_version(),
    /// major << 16 | minor): fake 2.0 and 2.7 dylibs load; 1.2, 3.0 and one without the symbol (from before the
    /// version) are refused with a message naming both versions.
    @Test func qemuAPIVersion() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-api-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for (name, version) in [("v2_0", "(2u << 16)"), ("v2_7", "(2u << 16) | 7u"), ("v1_2", "(1u << 16) | 2u"), ("v3_0", "(3u << 16)"), ("none", nil)] {
            let source = work.appendingPathComponent("\(name).c")
            try ("void qemu_ios_main(void) {}\n" + (version.map { "unsigned qemu_ios_api_version(void) { return \($0); }\n" } ?? "")).write(to: source, atomically: true, encoding: .utf8)
            let cc = Process()
            cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
            cc.arguments = ["-dynamiclib", source.path, "-o", work.appendingPathComponent("\(name).dylib").path]
            try cc.run()
            cc.waitUntilExit()
            try #require(cc.terminationStatus == 0)
        }
        for (name, loads) in [("v2_0", true), ("v2_7", true), ("v1_2", false), ("v3_0", false), ("none", false)] {
            do {
                _ = try Qemu(path: work.appendingPathComponent("\(name).dylib").path)
                #expect(loads, "\(name) loaded")
            } catch {
                let text = "\(error)", want = ["v1_2": "has C API 1.2", "v3_0": "has C API 3.0"][name] ?? "has C API 0.0"
                #expect(!loads && text.contains(want) && text.contains("needs \(Qemu.apiMajor).x"), "\(name): \(text)")
            }
        }
    }

    /// The live LCD on a wide-gamut display: the helper's frame surface (makeSurface) holding pure red, composited by
    /// Core Animation into a Display P3 target as a P3 screen would, comes out as sRGB red in P3 (about 234, 51, 35),
    /// not P3's own oversaturated (255, 0, 0).
    @Test func frameSurfaceColorsOnP3() throws {
        let device = try #require(MTLCreateSystemDefaultDevice()), queue = try #require(device.makeCommandQueue())
        let surface = makeSurface(width: 8, height: 8)
        surface.lock(options: [], seed: nil)
        let p = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<8 { for x in 0..<8 { let o = y * surface.bytesPerRow + x * 4; p[o] = 0; p[o + 1] = 0; p[o + 2] = 255; p[o + 3] = 255 } }
        surface.unlock(options: [], seed: nil)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .managed
        let texture = try #require(device.makeTexture(descriptor: desc))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layer = CALayer()
        layer.frame = CGRect(x: 0, y: 0, width: 8, height: 8)
        layer.contents = surface
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                                               kCARendererMetalCommandQueue: queue])
        renderer.layer = layer
        renderer.bounds = layer.frame
        CATransaction.commit()
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        let b = try #require(queue.makeCommandBuffer()), blit = try #require(b.makeBlitCommandEncoder())
        blit.synchronize(resource: texture)
        blit.endEncoding()
        b.commit()
        b.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: 256)
        texture.getBytes(&px, bytesPerRow: 32, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0)
        let (b0, g0, r0) = (Int(px[144]), Int(px[145]), Int(px[146]))
        #expect(abs(r0 - 234) <= 3 && abs(g0 - 51) <= 4 && abs(b0 - 35) <= 4, "pure red on a P3 screen: (\(r0), \(g0), \(b0)); (255, 0, 0) is oversaturated")
    }

    /// NativeLogging: QEMU's stdout and stderr (this process's own, redirected for the test) go to native.log, app
    /// events to app.log only. The layout, cache and pipe checks are StorageLocationsTests'.
    @Test func nativeLogCapture() async throws {
        func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        let savedOut = dup(STDOUT_FILENO), savedErr = dup(STDERR_FILENO)
        defer {
            _ = dup2(savedOut, STDOUT_FILENO); _ = dup2(savedErr, STDERR_FILENO)
            close(savedOut); close(savedErr)
        }
        try Bundled.requireStorage()
        try NativeLogging.start()
        fputs("native error marker\n", stderr)
        fputs("native output marker\n", stdout)
        fflush(stdout)
        logEvent("app event only marker")
        await AppEventLog.shared.flush()
        NativeLogging.flush()
        let native = text(Bundled.logsDirectory.appendingPathComponent("native.log"))
        #expect(native.contains("native error marker") && native.contains("native output marker"))
        #expect(!native.contains("app event only marker"))
        #expect(text(Bundled.logsDirectory.appendingPathComponent("app.log")).contains("app event only marker"))
    }
}
}
