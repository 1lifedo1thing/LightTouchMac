#!/usr/bin/env python3
"""A recording whose app dies mid-take is still a playable movie: ScreenMovieWriter writes movie fragments.
A child records 8 s of frames and exits without finishing; the parent opens what it left."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import device_runtime
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
fixture = r'''import Cocoa
import AVFoundation
@MainActor enum Bundled { static var stateDirectory = URL(fileURLWithPath: NSTemporaryDirectory()) }
@main struct Check {
 @MainActor static func main() async throws {
  let url = URL(fileURLWithPath: CommandLine.arguments[2])
  if CommandLine.arguments[1] == "record" {
   let context = CGContext(data: nil, width: 64, height: 96, bitsPerComponent: 8, bytesPerRow: 256,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
   let writer = ScreenMovieWriter()
   try await writer.start(url: url, canvasSize: CGSize(width: 64, height: 96))
   for i in 0..<240 {   // 8 s at 30 fps, each frame different
    context.setFillColor(CGColor(red: Double(i % 30) / 30, green: 0.5, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
    try await writer.append(context.makeImage()!, seconds: Double(i) / 30)
    try await Task.sleep(for: .milliseconds(5))
   }
   try await Task.sleep(for: .seconds(1))
   _exit(0)   // the crash: no finish
  }
  let asset = AVURLAsset(url: url)
  let playable = try await asset.load(.isPlayable)
  let seconds = try await asset.load(.duration).seconds
  precondition(playable && seconds >= 4, "a crashed take: playable \(playable), \(seconds) s")
  print("PASS: a take cut off by a crash plays (\(String(format: "%.1f", seconds)) s of 8)")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-recording-crash-') as directory:
    work = Path(directory)
    (work/'check.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', *device_runtime.swift_flags(root), '-swift-version', '6', '-default-isolation', 'MainActor', '-parse-as-library',
                    '-module-cache-path', str(work/'modules'), str(root/'LightTouchMac/Features/ScreenMovieWriter.swift'),
                    str(work/'check.swift'), '-o', str(work/'check')], check=True)
    movie = work/'take.mov'
    subprocess.run([str(work/'check'), 'record', str(movie)], check=True, timeout=60)
    subprocess.run([str(work/'check'), 'open', str(movie)], check=True, timeout=30)
