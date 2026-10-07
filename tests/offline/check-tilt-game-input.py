#!/usr/bin/env python3
"""Drive the production tilt gestures through the production mounted gravity model.

Compiles LightTouchCore's Session/ChassisTilt.swift whole (the tilt gestures' state and math: drag, scroll and
twist, and the attitude command EmulatorController.setTilt sends) against qemu-ios's
ipod_attitude_vector, the same function the real bridge and the LIS302DL use, so a gesture that moves the shell
without changing guest gravity fails here. The gesture math alone is LightTouchCoreTests' ChassisTiltTests; this
is what the guest's accelerometer reads for it: upright and flat, every quarter turn, direction, diagonal 1 g,
clamps and the release to rest. No app, emulator, saved device state or preferences are opened.
"""
import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "scripts"))
import device_runtime
import sources  # the pinned checkouts (build-support/sources.json)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--qemu-source", type=Path, default=sources.path("qemu-ios"))
args = parser.parse_args()
qemu = args.qemu_source.resolve()
if not (qemu / "include/hw/arm/ipod-attitude.h").is_file():
    parser.error("--qemu-source must contain include/hw/arm/ipod-attitude.h")

header = r'''
#include <stdint.h>
void qemu_ios_ui_attitude(double pitch, double roll, int pose);
void tilt_test_vector(int8_t out[3]);
int tilt_test_samples(void);
'''
c_source = r'''
#include <assert.h>
#include <string.h>
#include "hw/arm/ipod-attitude.h"
#include "bridge.h"
static int8_t latest[3];
static int samples;
void qemu_ios_ui_attitude(double pitch, double roll, int pose) {
    assert(pose == 0 || pose == 1);
    assert(ipod_attitude_vector(pitch, roll, pose != 0, latest));
    samples++;
}
void tilt_test_vector(int8_t out[3]) { memcpy(out, latest, sizeof latest); }
int tilt_test_samples(void) { return samples; }
'''

swift = r'''import Foundation
import CoreGraphics

/// DisplayView's tilt path: the gesture, then sendAttitude (ChassisTilt.attitude) and setTilt's command, whose
/// attitude reaches the C model as the helper's link would deliver it.
@MainActor final class Check {
    var tilt = ChassisTilt()
    var pose = 0, rotation = 0
    func send() {
        let attitude = tilt.attitude(rotation: rotation, flat: pose == 1)
        if case let .attitude(p, r, pose) = ChassisTilt.attitudeCommand(angle: attitude.angle, pitch: attitude.pitch, pose: pose) {
            qemu_ios_ui_attitude(p, r, Int32(pose))
        }
    }
    func vector() -> [Int] {
        var result = [Int8](repeating: 0, count: 3)
        tilt_test_vector(&result)
        return result.map(Int.init)
    }
    func expect(_ expected: [Int], _ context: String) {
        precondition(vector() == expected, "\(context): \(vector()) != \(expected)")
    }
    func expectMagnitude(_ context: String) {
        let magnitude = sqrt(vector().reduce(0.0) { $0 + Double($1 * $1) })
        precondition(abs(magnitude - 64) < 1, "\(context): magnitude \(magnitude)")
    }
    func reset() { tilt.reset(); send() }
    var grab = CGPoint.zero
    func drag(horizontal: Double, vertical: Double) {
        // Degrees to the right/up; the view is flipped, so up is a smaller y.
        let gain = Double(ChassisTilt.dragGain) * 180 / Double.pi
        tilt.drag(to: CGPoint(x: grab.x + horizontal / gain, y: grab.y - vertical / gain))
        send()
    }
    func scroll(dx: Double, dy: Double, precise: Bool = true) {
        tilt.scroll(by: ChassisTilt.scrollMovement(dx: dx, dy: dy, precise: precise))
        send()
    }

    func run() {
        let rotations = [0, 90, 180, 270]
        let uprightRest = [[0,-64,0], [64,0,0], [0,64,0], [-64,0,0]]
        let uprightRight = [[32,-55,0], [55,32,0], [-32,55,0], [-55,-32,0]]
        let uprightLeft = [[-32,-55,0], [55,-32,0], [32,55,0], [-55,32,0]]
        let uprightUp = [[0,-55,-32], [55,0,-32], [0,55,-32], [-55,0,-32]]
        let flatRight = [[32,0,-55], [0,32,-55], [-32,0,-55], [0,-32,-55]]
        let flatUp = [[0,32,-55], [-32,0,-55], [0,-32,-55], [32,0,-55]]

        for pose in [0, 1] {
            for (index, rotation) in rotations.enumerated() {
                let context = "pose \(pose) rotation=\(rotation)"
                let baseline = pose == 1 ? [0,0,-64] : uprightRest[index]
                self.pose = pose; self.rotation = rotation
                reset()
                expect(baseline, context + " rest")
                for anchor in [CGPoint(x: 37, y: 91), CGPoint(x: -200, y: 300)] {
                    tilt.reset()
                    tilt.beginDrag(at: anchor, rotation: rotation)
                    grab = anchor
                    let count = tilt_test_samples()
                    drag(horizontal: 30, vertical: 0)
                    precondition(tilt_test_samples() > count)
                    expect(pose == 1 ? flatRight[index] : uprightRight[index], context + " right")
                    drag(horizontal: -30, vertical: 0)
                    let flatLeft = flatRight[index].enumerated().map { $0.offset < 2 ? -$0.element : $0.element }
                    expect(pose == 1 ? flatLeft : uprightLeft[index], context + " left")
                    drag(horizontal: 0, vertical: 30)
                    expect(pose == 1 ? flatUp[index] : uprightUp[index], context + " up")
                    for horizontal in [-45.0, -20, 20, 45] {
                        for vertical in [-45.0, -20, 20, 45] {
                            drag(horizontal: horizontal, vertical: vertical)
                            expectMagnitude(context + " diagonal")
                            precondition(vector() != baseline, context + " diagonal lost gravity")
                        }
                    }
                    drag(horizontal: 500, vertical: 500)
                    let clamped = vector()
                    drag(horizontal: 45, vertical: 45)
                    expect(clamped, context + " mouse clamp")
                    reset()
                    expect(baseline, context + " mouse-up reset")
                }
                // AppKit has already applied Natural Scrolling: both delivered signs, points and lines.
                for sign in [-1.0, 1.0] {
                    for precise in [false, true] {
                        tilt.reset()
                        tilt.beginScroll(rotation: rotation)
                        let points = sign * Double.pi / 6 / Double(ChassisTilt.scrollTiltGain)
                        scroll(dx: points / (precise ? 1 : 10), dy: 0, precise: precise)
                        let expected: [Int]
                        if pose == 1 {
                            expected = flatRight[index].enumerated().map { $0.offset < 2 ? Int(sign) * $0.element : $0.element }
                        } else {
                            expected = sign > 0 ? uprightRight[index] : uprightLeft[index]
                        }
                        expect(expected, context + " scroll horizontal")
                        reset()
                        expect(baseline, context + " scroll ended reset")
                    }
                }
                tilt.beginScroll(rotation: rotation)
                let diagonal = Double.pi / 6 / Double(ChassisTilt.scrollTiltGain)
                scroll(dx: diagonal, dy: diagonal)
                expectMagnitude(context + " scroll diagonal")
                precondition(vector() != baseline)
                reset()
                expect(baseline, context + " scroll cancellation reset")
                tilt.beginScroll(rotation: rotation)
                scroll(dx: 1_000_000, dy: -1_000_000)
                precondition(abs(tilt.tiltAngle - .pi / 3) < 1e-12 && abs(tilt.pitchAngle + .pi / 3) < 1e-12)
                expectMagnitude(context + " scroll clamp")
                reset()
                expect(baseline, context + " scroll clamp reset")
            }
        }
        print("PASS: production tilt gestures → attitude command → LIS302DL gravity; upright/flat, every quarter-turn, direction, diagonal 1g, clamps and release")
    }
}
@main struct Main {
    @MainActor static func main() { Check().run() }
}
'''

with tempfile.TemporaryDirectory(prefix="ltm-tilt-game-") as directory:
    work = Path(directory)
    (work / "bridge.h").write_text(header)
    (work / "bridge.c").write_text(c_source)
    (work / "check.swift").write_text(swift)
    subprocess.run(["clang", "-Wall", "-Wextra", "-Werror", "-I" + str(qemu / "include"),
                    "-c", str(work / "bridge.c"), "-o", str(work / "bridge.o")], check=True)
    subprocess.run(["swiftc", *device_runtime.swift_flags(root), "-parse-as-library", "-module-cache-path", str(work / "module-cache"),
                    "-import-objc-header", str(work / "bridge.h"),
                    str(root / "Packages/LightTouchCore/Sources/LightTouchCore/Session/ChassisTilt.swift"), str(work / "check.swift"),
                    str(work / "bridge.o"), "-o", str(work / "check")], check=True)
    subprocess.run([str(work / "check")], check=True)
