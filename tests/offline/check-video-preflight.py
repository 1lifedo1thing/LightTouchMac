#!/usr/bin/env python3
"""Actual macOS iPod export: compatible movie, metadata, identity and cancellation."""
from pathlib import Path
import json, shutil, subprocess, sys, tempfile
DEVICE_PROFILE = str(Path(__file__).resolve().parents[2] / 'LightTouchMac/Device/Board+App.swift')

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / 'scripts'))
import sources  # the pinned checkouts (build-support/sources.json)
import host_runtime
fixtures = sources.path('qemu-ios') / 'contrib/it-harness/build/Payload/Harness.app'
if not fixtures.is_dir():
    print(f'SKIP: no harness fixtures at {fixtures}; build them with contrib/it-harness/build.sh in the pinned checkout (or set QEMU_IOS_DIR)'); raise SystemExit(0)
code = r'''import Foundation
import AVFoundation
enum DeviceToolsError: LocalizedError {
 case failed(String)
 var errorDescription: String? { switch self { case .failed(let text): text } }
}
@main struct Check {
 static func main() async throws {
  let source = URL(fileURLWithPath: CommandLine.arguments[1])
  let work = URL(fileURLWithPath: CommandLine.arguments[2])
  if CommandLine.arguments.count > 3 {   // a 720p source: the iPad keeps 720p, the iPod gets its own 640-wide copy
   for (profile, name) in [(Board.k48, "hd-ipad.m4v"), (.n72, "hd-ipod.m4v")] {
    let prepared = try await MediaVideo.prepare(source, cacheDirectory: work.appendingPathComponent("hd-cache"), profile: profile)
    try FileManager.default.copyItem(at: prepared.video, to: work.appendingPathComponent(name))
    try? FileManager.default.removeItem(at: prepared.directory)
   }
   return
  }
  let original = try Data(contentsOf: source)
  let first = try await MediaVideo.prepare(source, cacheDirectory: work.appendingPathComponent("cache"), profile: .n72)
  defer { try? FileManager.default.removeItem(at: first.directory) }
  precondition(first.title == source.deletingPathExtension().lastPathComponent)
  precondition(first.video.lastPathComponent == "video.m4v" && UUID(uuidString: first.id) != nil)
  let data = try Data(contentsOf: first.metadata)
  let metadata = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
  precondition(metadata["kind"] as? String == "feature-movie")
  precondition(metadata["filename"] as? String == "video.m4v")
  precondition(metadata["title"] as? String == first.title)
  let duration = metadata["duration_ms"] as! Double
  precondition(duration > 5900 && duration < 6100)
  try FileManager.default.copyItem(at: first.video, to: work.appendingPathComponent("prepared.m4v"))
  try await Task.sleep(for: .milliseconds(1100))
  let second = try await MediaVideo.prepare(source, cacheDirectory: work.appendingPathComponent("cache"), profile: .n72)
  defer { try? FileManager.default.removeItem(at: second.directory) }
  precondition(first.id == second.id && first.directory != second.directory, "repeated exports must reconcile to one guest library item")
  let unchanged = try Data(contentsOf: source)
  precondition(unchanged == original, "preparation must not rewrite the user's movie")
  let cache = work.appendingPathComponent("cache")
  let cached = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first!
  let directoryMode = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as! NSNumber
  let fileMode = try FileManager.default.attributesOfItem(atPath: cached.path)[.posixPermissions] as! NSNumber
  precondition(directoryMode.intValue == 0o700 && fileMode.intValue == 0o600)
  // Two simultaneous drops must adopt the same atomic cache winner.
  let simultaneous = work.appendingPathComponent("simultaneous-cache")
  async let a = MediaVideo.prepare(source, cacheDirectory: simultaneous, profile: .n72)
  async let b = MediaVideo.prepare(source, cacheDirectory: simultaneous, profile: .n72)
  let (left, right) = try await (a, b)
  defer { try? FileManager.default.removeItem(at: left.directory); try? FileManager.default.removeItem(at: right.directory) }
  precondition(left.id == right.id)
  // A damaged disposable cache entry can never poison future imports.
  try Data("invalid cache".utf8).write(to: cached)
  let repaired = try await MediaVideo.prepare(source, cacheDirectory: cache, profile: .n72)
  defer { try? FileManager.default.removeItem(at: repaired.directory) }
  let repairedSize = try FileManager.default.attributesOfItem(atPath: repaired.video.path)[.size] as! NSNumber
  precondition(repairedSize.intValue > 0)
  for name in ["empty.mp4", "broken.mov", "audio.mov", "folder.mp4", "unknown.avi"] {
   do { _ = try await MediaVideo.prepare(work.appendingPathComponent(name), cacheDirectory: work.appendingPathComponent("cache"), profile: .n72); preconditionFailure("accepted \(name)") }
   catch { }
  }
  let cancelled = Task { try await MediaVideo.prepare(source, cacheDirectory: work.appendingPathComponent("cache"), profile: .n72) }
  cancelled.cancel()
  do { _ = try await cancelled.value; preconditionFailure("cancelled export succeeded") }
  catch is CancellationError { }
  let duringExport = Task { try await MediaVideo.prepare(source, cacheDirectory: work.appendingPathComponent("cancel-cache"), profile: .n72) }
  try await Task.sleep(for: .milliseconds(10))
  duringExport.cancel()
  do { _ = try await duringExport.value; preconditionFailure("cancelled active export succeeded") }
  catch is CancellationError { }
  print("PASS: iPod movie export, native metadata, immutable source, private/atomic reusable conversion, corrupt cache recovery, invalid media and cancellation")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-video-check-') as directory:
    work = Path(directory)
    (work / 'check.swift').write_text(code)
    movie = work / "Movie 'quoted' $title — été.mp4"
    shutil.copyfile(fixtures / 'h264.mp4', movie)
    (work / 'empty.mp4').touch()
    (work / 'broken.mov').write_bytes(b'not a movie')
    shutil.copyfile(fixtures / 'aac.m4a', work / 'audio.mov')
    (work / 'folder.mp4').mkdir()
    shutil.copyfile(movie, work / 'unknown.avi')
    subprocess.run(['xcrun', 'swiftc', *__import__('host_service').wire_flags(__import__('pathlib').Path(__file__).resolve().parents[2]), *host_runtime.swift_flags(root), DEVICE_PROFILE, '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-module-cache-path', str(work / 'modules'), str(root / 'LightTouchMac/Features/MediaIdentity.swift'),
                    str(root / 'LightTouchMac/Features/MediaVideo.swift'), str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check'), str(movie), str(work)], check=True, timeout=90)
    streams = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json',
                                                 str(work / 'prepared.m4v')]))['streams']
    video = next(stream for stream in streams if stream['codec_type'] == 'video')
    assert video['codec_name'] == 'h264' and 'Baseline' in video['profile'], video
    assert video['width'] <= 640 and video['height'] <= 480 and video['level'] <= 30, video
    num, den = map(int, video['avg_frame_rate'].split('/'))
    assert num / den <= 30, video
    for audio in (stream for stream in streams if stream['codec_type'] == 'audio'):
        assert audio['codec_name'] == 'aac' and audio['channels'] <= 2 and int(audio['sample_rate']) <= 48000, audio
    print('PASS: H.264 Baseline Level ≤3, ≤640×480 at ≤30 fps and compatible audio')
    # Per device: a 720p movie stays 720p for the iPad (A4), 640 wide for the iPod, from one cache.
    hd = work / 'hd.mp4'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=1280x720:rate=30', '-t', '2', '-pix_fmt', 'yuv420p',
                    '-c:v', 'libx264', str(hd)], check=True)
    subprocess.run([str(work / 'check'), str(hd), str(work), 'hd'], check=True, timeout=90)
    def size(name):
        stream = next(s for s in json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json',
                                                                     str(work / name)]))['streams'] if s['codec_type'] == 'video')
        return stream['width'], stream['height'], stream['level']
    ipad, ipod = size('hd-ipad.m4v'), size('hd-ipod.m4v')
    assert ipad[:2] == (1280, 720) and ipad[2] <= 31, ipad
    assert ipod[0] <= 640 and ipod[1] <= 480, ipod
    print('PASS: 720p kept for the iPad, 640 wide for the iPod, cached apart')
