#!/usr/bin/env python3
"""Exercise the production AFC streaming loop with short writes and failures, and the staging names a late
startup sweep may remove. Compiles the helper's Engine/AFC.swift and Engine/DeviceExecution.swift whole, against a fake
libimobiledevice and a DeviceServices whose run kernel calls straight through."""
from pathlib import Path
from host_service_fixtures import engine, leaves, local_engine_stub
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
app = root / 'LightTouchMac'
engine_dir = root / 'LightTouchServices/Engine'
source = r'''import Foundation
nonisolated func logEvent(_ message: String) {}
struct MediaVideo: Sendable { let id: String; let video: URL }
struct MediaPhoto: Sendable { let id: String; let image: URL }
struct MediaSong: Sendable {
 let id: String
 let audio: URL
 var artwork: URL? = nil
 static let extensions: Set<String> = ["mp3", "m4a", "wav"]
}
final class State: @unchecked Sendable {
 static let shared = State()
 let lock = NSLock()
 var existing: Data?, readOffset = 0
 var bytes = Data(), removed = false, closeCalls = 0
 var destination = "", directories: [String] = [], published: [String: Data] = [:]
 var cancelOnClose = false
 var failure = false, badCount = false, closeFailure = false
 func reset() { lock.withLock { bytes = Data(); cancelOnClose = false; existing = nil; readOffset = 0; destination = ""; directories = []; published = [:]; removed = false; closeCalls = 0; failure = false; badCount = false; closeFailure = false } }
}
/// The AFC the upload sees: libimobiledevice's calls (IMDFake) over State.
func fakeAFC() {
 let state = State.shared
 IMDFake.afcClientNew = { _,_,c in c?.pointee = OpaquePointer(bitPattern: 1); return AFC_E_SUCCESS }
 IMDFake.afcMakeDirectory = { _,p in state.directories.append(String(cString:p!)); return AFC_E_SUCCESS }
 IMDFake.afcFileOpen = { _,p,mode,h in
  if mode == AFC_FOPEN_RDONLY { if !state.published.isEmpty { state.existing=state.published[String(cString:p!)] };guard state.existing != nil else{return AFC_E_OBJECT_NOT_FOUND};state.readOffset=0;h?.pointee=2;return AFC_E_SUCCESS }
  state.destination = String(cString:p!);state.bytes=Data();h?.pointee=1;return AFC_E_SUCCESS
 }
 IMDFake.afcFileRead = { _,_,p,n,count in
  guard let bytes=state.existing else{return AFC_E_OBJECT_NOT_FOUND}
  let c=UInt32(min(Int(n),bytes.count-state.readOffset,317))
  bytes.withUnsafeBytes { raw in
   if c>0 { UnsafeMutableRawPointer(p!).copyMemory(from:raw.baseAddress!.advanced(by:state.readOffset),byteCount:Int(c)) }
  }
  count?.pointee=c;state.readOffset+=Int(c);return AFC_E_SUCCESS
 }
 IMDFake.afcRenamePath = { _,_,p in
  state.destination=String(cString:p!);state.existing=state.bytes;state.published[state.destination]=state.bytes;return AFC_E_SUCCESS
 }
 IMDFake.afcFileWrite = { _,_,p,n,w in
  state.lock.withLock {
   if state.failure && !state.bytes.isEmpty { return AFC_E_UNKNOWN_ERROR }
   if state.badCount { w?.pointee = n+1; return AFC_E_SUCCESS }
   let c = min(n, 317); w?.pointee = c; state.bytes.append(UnsafeRawPointer(p!).assumingMemoryBound(to: UInt8.self), count: Int(c)); return AFC_E_SUCCESS
  }
 }
 IMDFake.afcFileClose = { _,_ in state.lock.withLock { state.closeCalls += 1;if state.cancelOnClose { withUnsafeCurrentTask { $0?.cancel() } };return state.closeFailure ? AFC_E_OP_NOT_SUPPORTED : AFC_E_SUCCESS } }
 IMDFake.afcRemovePath = { _,_ in state.lock.withLock { state.removed=true;return AFC_E_SUCCESS } }
}
extension DeviceServices {
 init() { self.init(clientSocket: "127.0.0.1:1") }
 func run<T: Sendable>(_ seconds: Double, _ label: String, _ body: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
  try await Task.detached { try body(OpaquePointer(bitPattern: 1)!) }.value
 }
}
func stagingNames() {
  let file=URL(fileURLWithPath:"/tmp/Temple Run.ipa")
  let first=DeviceServices.stagingName(file), second=DeviceServices.stagingName(file)
  precondition(first != second)
  let old="Temple_Run-01234567.ipa"
  // Simulate the directory listing returning after both new uploads started.
  let removed=[old,first,second,".","..","../escape",""].filter(DeviceServices.isOrphanedStagingName)
  precondition(removed == [old])
  precondition(!first.contains("/"))
  let uuid=UUID().uuidString
  precondition(DeviceServices.isOrphanedMediaUpload("audio.m4a.upload-"+uuid))
  precondition(DeviceServices.isOrphanedMediaUpload("image.jpg.upload-"+uuid+"-"+UUID().uuidString))
  precondition(!DeviceServices.isOrphanedMediaUpload("audio.m4a.upload-"+DeviceServices.stagingSession+"-"+uuid))
  for name in ["audio.m4a","image.jpg",".photo-receipt","song.json","audio.m4a.upload-invalid","../image.jpg.upload-"+uuid] {
   precondition(!DeviceServices.isOrphanedMediaUpload(name),name)
  }
}
@main struct Check {
 static func main() async throws {
  let path = URL(fileURLWithPath: CommandLine.arguments[1])
  let expected = Data((0..<200003).map { UInt8($0 % 251) })
  try expected.write(to: path)
  fakeAFC()
  let state = State.shared
  _ = try await DeviceServices().stage(path) { _ in }
  precondition(state.bytes == expected && !state.removed && state.closeCalls == 1)
  state.reset()
  let audio = path.deletingLastPathComponent().appendingPathComponent("audio.m4a")
  try expected.write(to: audio)
  let id = UUID().uuidString
  try await DeviceServices().stageSong(MediaSong(id:id,audio:audio)) { _ in }
  precondition(state.bytes == expected && state.destination == "LightTouch/\(id)/audio.m4a")
  precondition(state.directories == ["LightTouch","LightTouch/\(id)"])
  state.reset()
  let artwork = path.deletingLastPathComponent().appendingPathComponent("artwork.jpg")
  let cover = Data("cover fixture".utf8)
  try cover.write(to: artwork)
  try await DeviceServices().stageSong(MediaSong(id:id,audio:audio,artwork:artwork)) { _ in }
  precondition(state.published == ["LightTouch/\(id)/audio.m4a": expected, "LightTouch/\(id)/artwork.jpg": cover])
  state.reset();state.existing=expected
  try await DeviceServices().stageSong(MediaSong(id:id,audio:audio)) { _ in }
  precondition(state.bytes.isEmpty && state.closeCalls==1 && state.existing==expected)
  state.reset();state.existing=Data("different".utf8)
  do { try await DeviceServices().stageSong(MediaSong(id:id,audio:audio)) { _ in };fatalError("mismatched media overwritten") }
  catch let error as DeviceError { precondition(!error.shouldPauseInstallQueue) }
  precondition(state.bytes.isEmpty && state.existing==Data("different".utf8) && state.closeCalls==1)
  state.reset()
  do { try await DeviceServices().stageSong(MediaSong(id:"../escape",audio:audio)) { _ in }; fatalError("invalid destination accepted") }
  catch {}
  precondition(state.destination.isEmpty)
  state.reset()
  let video = path.deletingLastPathComponent().appendingPathComponent("video.m4v")
  try expected.write(to: video)
  try await DeviceServices().stageVideo(MediaVideo(id:id,video:video)) { _ in }
  precondition(state.bytes == expected && state.destination == "LightTouch/\(id)/video.m4v")
  state.reset();state.existing=expected
  try await DeviceServices().stageVideo(MediaVideo(id:id,video:video)) { _ in }
  precondition(state.bytes.isEmpty && state.existing == expected)
  state.reset()
  do { try await DeviceServices().stageVideo(MediaVideo(id:id,video:audio)) { _ in };fatalError("invalid movie path accepted") }
  catch {}
  precondition(state.destination.isEmpty)
  state.reset();state.cancelOnClose=true
  do { try await DeviceServices().stageSong(MediaSong(id:id,audio:audio)) { _ in };fatalError("cancelled upload published") }
  catch is CancellationError {}
  precondition(state.removed && state.existing == nil && state.closeCalls == 1)
  for kind in 0..<3 {
   state.reset()
   state.failure = kind == 0; state.badCount = kind == 1; state.closeFailure = kind == 2
   do { _ = try await DeviceServices().stage(path) { _ in }; fatalError("failed upload accepted") }
   catch let e as DeviceError { precondition(e.shouldPauseInstallQueue) }
   precondition(state.removed && state.closeCalls == 1)
  }
  stagingNames()
  print("PASS: app/media AFC uploads, safe destination validation, short writes and failure cleanup; late sweeps preserve active uploads, canonical media and receipts")
 }
}
'''
with tempfile.TemporaryDirectory() as work:
    swift=Path(work)/'check.swift'; swift.write_text(source)
    # MediaStaging is the app's (it imports HostServiceClient); here it runs on the engine's stageFile.
    staging=Path(work)/'MediaStaging.swift'; staging.write_text((app/'Services/MediaStaging.swift').read_text().replace('import HostServiceClient\n',''))
    exe=Path(work)/'check'
    subprocess.run(['swiftc', *engine(root), *leaves(root), *local_engine_stub(Path(work)),'-parse-as-library','-module-cache-path',str(Path(work)/'modules'),str(engine_dir/'AFC.swift'), str(staging),
                    str(engine_dir/'DeviceExecution.swift'),str(swift),'-o',str(exe)],check=True)
    subprocess.run([str(exe),str(Path(work)/'fixture.ipa')],check=True)
