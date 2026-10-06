#!/usr/bin/env python3
"""Which libraries each catalog firmware may add media to (Features/MediaSupport.swift, compiled whole), against
the builds the guest helpers have been verified on (qemu-ios contrib/it-media/README.md and its booted round trips).
Fails when an unverified firmware is offered an import, a verified one is refused, or the refusal
loses its plain words."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
import json, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
catalog = json.loads((root / 'LightTouchMac/Resources/firmware-catalog.json').read_text())['entries']

# Every catalog entry's expected destinations. Anything not listed takes none.
# Booted round trips (check-media-native.py --single): 7D11, 7E18 and 7B367; 7C145, 7B405 and 7B500 share their 3.x
# services. Music on the iPad's 5.1.1 (9B206) through ML3's importer; other 5.x builds have not been round-tripped.
# 4.2.1 (both boards) fails (it-media README), so 4.x stays refused.
EXPECTED = {
    'n72ap-7E18': {'Music', 'Videos', 'Photos'},
    **{i: {'Music', 'Photos'} for i in ('n72ap-7C145', 'n72ap-7D11', 'k48ap-7B367', 'k48ap-7B405', 'k48ap-7B500')},
    'k48ap-9B206': {'Music'},
}

code = r'''import Foundation
@main struct Check {
 static func main() throws {
  let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
  var out: [String: Any] = [:]
  for e in entries {
   let firmware = MediaSupport.Firmware(board: e["board"] as! String, version: e["version"] as! String, build: e["build"] as! String,
                                        name: e["name"] as! String, prerelease: e["prerelease"] as! Bool)
   out[e["id"] as! String] = ["supported": ["Music", "Videos", "Photos"].filter { MediaSupport.supports($0, on: firmware) },
                    "any": MediaSupport.supportsAny(firmware),
                    "refusals": ["Music", "Videos", "Photos"].map { MediaSupport.refusal($0, on: firmware) ?? "" }]
  }
  FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: out))
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-media-support-') as directory:
    work = Path(directory)
    (work / 'check.swift').write_text(code)
    entries = [{'id': e['id'], 'board': e['board'], 'version': e['version'], 'build': e['build'],
                'name': f"iOS {e['version']}", 'prerelease': 'prerelease' in e} for e in catalog]
    (work / 'entries.json').write_text(json.dumps(entries))
    subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(root), '-swift-version', '6', '-parse-as-library',
                    '-module-cache-path', str(work / 'modules'), str(root / 'LightTouchMac/Features/MediaSupport.swift'),
                    str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    result = json.loads(subprocess.run([str(work / 'check'), str(work / 'entries.json')], check=True,
                                       capture_output=True, timeout=30).stdout)

failures = []
for e in catalog:
    r, want = result[e['id']], EXPECTED.get(e['id'], set())
    if set(r['supported']) != want:
        failures.append(f"{e['id']}: offers {sorted(r['supported'])}, verified {sorted(want)}")
    if r['any'] != bool(want):
        failures.append(f"{e['id']}: Import Media… {'enabled' if r['any'] else 'disabled'}")
    for destination, words in zip(('Music', 'Videos', 'Photos'), r['refusals']):
        noun = {'Music': 'music', 'Videos': 'videos', 'Photos': 'photos'}[destination]
        expected = '' if destination in want else f"Adding {noun} isn’t supported on iOS {e['version']} yet."
        if words != expected:
            failures.append(f"{e['id']} {destination}: {words!r}, want {expected!r}")
if failures:
    sys.exit('FAIL:\n  ' + '\n  '.join(failures))
offered = sorted(i for i in EXPECTED if i in result)
print(f"PASS: {len(catalog)} catalog firmwares; media offered only on {', '.join(offered)}; every other one refused in plain words")
