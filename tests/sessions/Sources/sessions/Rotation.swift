import CoreGraphics
import Foundation
import ImageIO
import SessionKit
import Vision

/// `sessions rotation BASE [--overlay DIR]`: the app's Rotate Right and Rotate Left (DeviceRotation, the control this
/// board takes) with Safari in front, and the picture as the window shows it (PanelCapture): upright in portrait, a
/// clockwise turn and a counter-clockwise turn, each judged by where Vision reads the status bar's clock (centered at
/// the top); then a tap on the address field as shown brings the keyboard up (the touch lands where it was aimed).
/// The helper alone boots the base, with no lockdown activation: a stock 2.x base stays at Connect to iTunes. A 5.x-7.x
/// base sits in Setup on its first boot: pass --overlay, the overlay of a boot that walked Setup, cloned.
func rotationCheck(_ args: RotationCheck) -> Never {
    let base = Base(args.base)
    let work = workDirectory(args.inputs, "rotation")
    let tools = Tools.resolve(args.inputs, work: work)
    let r = Report()
    if let source = args.overlay {
        let overlay = work.appendingPathComponent("rotation/overlay")
        try? FileManager.default.createDirectory(
            at: overlay.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        run("/bin/cp", ["-cR", source.path, overlay.path])  // a clone: the source stays as it was
    } else if base.armv7, base.major >= 5 {
        die("a \(base.version) base is in Setup on its first boot: pass --overlay")
    }
    // The lock screen's slider and Safari's address field as the window shows them (the iPad's panel lies on its side).
    let iPad = base.board == "k48ap"
    let slide = iPad ? "dragshown 0.36 0.935 0.8 0.935" : "dragshown 0.18 0.9 0.92 0.9"
    let field = iPad ? "tapshown 0.4 0.072" : "tapshown 0.4 0.18"
    let d = HelperDriver(
        "rotation",
        tools: tools,
        work: work,
        scenario: preparedScenario(
            base,
            tools: tools,
            work: work,
            name: "rotation",
            steps: [
                // Home first: the S5L8920 boards power the digitizer down on the lock screen; their first slide
                // after boot can go unanswered, so twice (on the Home screen the second is a page swipe).
                "boot", "lit 0.03 300", "wait 5", "button 0", "wait 2", slide, "wait 4", "button 0", "wait 2", slide,
                "wait 4", "shot home",
                // Safari through the guest agent; without one (iPhone OS 1), its Home screen icon.
                "agentop launch com.apple.mobilesafari", "wait 8", "tapword Safari -0.06", "wait 10",
                // A first launch's alerts and Safari's bookmarks sheet (Done again: a tap while Safari opens can be lost).
                "tapword OK", "wait 2", "tapword Dismiss", "wait 2", "tapword Dismiss", "wait 2", "tapword Done",
                "wait 3", "tapword Done",
                "wait 4", "shot portrait",
                "turn cw", "wait 5", "shot cw",
                "turn ccw", "wait 3", "turn ccw", "wait 5", "shot ccw",
                field, "wait 4", "shot typing",
                "quit", "expectExit 60",
            ]
        )
    )
    r.check(d.finish(600) == 0, "rotation: scenario completed")
    var shots: [String: URL] = [:]
    for e in d.events.find("shot") where e.bool("ok") {
        if let name = e.string("name"), let path = e.string("path") { shots[name] = URL(fileURLWithPath: path) }
    }
    for (name, landscape) in [("portrait", false), ("cw", true), ("ccw", true)] {
        guard let url = shots[name], let image = loadImage(url) else {
            r.check(false, "rotation: \(name): no picture")
            continue
        }
        let (ok, at) = upright(image)
        r.check(
            (image.width > image.height) == landscape && ok,
            "rotation: \(name): the picture as shown is upright \(landscape ? "landscape" : "portrait") "
                + "(\(image.width)x\(image.height), the status bar's \(at))"
        )
    }
    if let before = shots["ccw"].flatMap(loadImage), let after = shots["typing"].flatMap(loadImage) {
        let change = abs(bottomLuminance(after) - bottomLuminance(before))
        r.check(
            change > 0.08 && upright(after).ok,
            "rotation: a tap on the address field as shown brings the keyboard up, upright (bottom band's luminance "
                + "moved \(format(change, 2)))"
        )
    } else {
        r.check(false, "rotation: no picture of the tap")
    }
    finish(r, work: work)
}

private func loadImage(_ url: URL) -> CGImage? {
    CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
}

/// Where the status bar's clock reads, if Vision finds one: its center (top-left origin, 0...1). Vision reads text at
/// any angle, so the clock's place, not its legibility, says which way up the picture is: upright, it is centered in
/// the top band.
private func clock(_ image: CGImage) -> (x: Double, y: Double)? {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
    for o in request.results ?? [] {
        guard let text = o.topCandidates(1).first?.string, text.contains(/\d{1,2}:\d{2}/) else { continue }
        return (o.boundingBox.midX, 1 - o.boundingBox.midY)
    }
    return nil
}

private func upright(_ image: CGImage) -> (ok: Bool, at: String) {
    guard let c = clock(image) else { return (false, "no clock read") }
    return (c.y < 0.08 && abs(c.x - 0.5) < 0.2, "clock at \(format(c.x, 2)), \(format(c.y, 2))")
}

/// Mean luminance (0...1) of the bottom 40% of the image, where the keyboard comes up.
private func bottomLuminance(_ image: CGImage) -> Double {
    let w = image.width
    let h = image.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard
        let ctx = CGContext(
            data: &px,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    else { return 0 }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var sum = 0.0
    var n = 0
    for y in (h * 6 / 10)..<h {
        for x in stride(from: 0, to: w, by: 2) {
            let i = (y * w + x) * 4
            sum += 0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])
            n += 1
        }
    }
    return n == 0 ? 0 : sum / Double(n) / 255
}
