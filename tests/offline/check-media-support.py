#!/usr/bin/env python3
"""Which libraries each catalog firmware may add media to (Features/MediaSupport.swift, compiled whole), against
the builds the guest helpers have been verified on (qemu-ios contrib/it-media/README.md; the booted round trips in
docs/STATUS.md). Fails when an unverified firmware is offered an import, a verified one is refused, or the refusal
loses its plain words."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
import json, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
catalog = json.loads((root / 'LightTouchMac/Resources/firmware-catalog.json').read_text())['entries']

# Every catalog entry's expected destinations. Anything not listed takes none.
EXPECTED = {
    'n72ap-7E18': {'Music', 'Videos', 'Photos'},
}

code = r'''import Foundation
@main struct Check {
 static func main() throws {
  let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: String]]
  var out: [String: Any] = [:]
  for e in entries {
   let firmware = MediaSupport.Firmware(board: e["board"]!, version: e["version"]!, build: e["build"]!, name: e["name"]!)
   out[e["id"]!] = ["supported": ["Music", "Videos", "Photos"].filter { MediaSupport.supports($0, on: firmware) },
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
                'name': f"iOS {e['version']}"} for e in catalog]
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
