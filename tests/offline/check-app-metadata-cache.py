#!/usr/bin/env python3
"""The app name/icon cache: an earlier build's index.json is read once and becomes a binary index.plist."""
from pathlib import Path
import os, subprocess, sys, tempfile
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import host_runtime, swift_subprocess
code = r'''import Foundation
enum DeviceToolsError: Error { case failed(String) }
@main struct Check {
 @MainActor static func main() throws {
  let dir = Bundled.stateDirectory.appendingPathComponent("Caches/AppMetadata", isDirectory: true)
  let json = dir.appendingPathComponent("index.json"), plist = dir.appendingPathComponent("index.plist")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  try Data(#"{"com.example.app":{"name":"Example","hasIcon":false}}"#.utf8).write(to: json)
  precondition(AppMetadataCache.shared.name(for: "com.example.app") == "Example", "the earlier build's entry is read")
  precondition(!FileManager.default.fileExists(atPath: json.path), "index.json is gone")
  let bytes = try Data(contentsOf: plist)
  var format = PropertyListSerialization.PropertyListFormat.xml
  let object = try PropertyListSerialization.propertyList(from: bytes, format: &format) as? [String: [String: Any]]
  precondition(format == .binary && object?["com.example.app"]?["name"] as? String == "Example", "index.plist holds it, binary")
  AppMetadataCache.shared.forget("com.example.app")
  let after = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
  precondition(after?.isEmpty == true, "saves go to index.plist")
  print("PASS: index.json converted once to a binary index.plist; later saves write the plist")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-app-metadata-') as directory:
    work = Path(directory)
    (work / 'check.swift').write_text(code)
    sources = ['Library/AppMetadataCache', 'Library/IPAMembers', 'Library/Bundled', 'Library/StorageLocations']
    subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(ROOT), *swift_subprocess.swift_flags(ROOT), *swift_subprocess.zip_flags(ROOT), '-swift-version', '5',
                    '-default-isolation', 'MainActor', '-parse-as-library', '-module-cache-path', str(work / 'modules'),
                    *[str(ROOT / f'LightTouchMac/{s}.swift') for s in sources], str(work / 'check.swift'), '-o', str(work / 'check')],
                   check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=60,
                   env=dict(os.environ, LTM_STATE_DIR=str(work / 'state'), CFFIXED_USER_HOME=str(work)))
