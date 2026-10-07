#!/usr/bin/env python3
"""The helper loads only a libqemu-arm.dylib whose C API major version is its own (qemu_ios_api_version(),
major << 16 | minor). Compiles LightTouchDevice/Qemu.swift whole and loads fake dylibs: 2.0 and 2.7 load; 1.2, 3.0 and
one without the symbol (a dylib from before the version) are refused with a message naming both versions."""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import device_runtime  # noqa: E402

MAIN = r'''
import Foundation
for (path, loads) in [("v2_0", true), ("v2_7", true), ("v1_2", false), ("v3_0", false), ("none", false)] {
    let dylib = CommandLine.arguments[1] + "/" + path + ".dylib"
    do {
        _ = try Qemu(path: dylib)
        guard loads else { print("FAIL: \(path) loaded"); exit(1) }
    } catch {
        let text = "\(error)"
        let want = ["v1_2": "has C API 1.2", "v3_0": "has C API 3.0"][path] ?? "has C API 0.0"
        guard !loads, text.contains(want), text.contains("needs \(Qemu.apiMajor).x") else {
            print("FAIL: \(path): \(text)"); exit(1)
        }
    }
}
print("PASS: API 2.0 and 2.7 load; 1.2, 3.0 and a dylib without qemu_ios_api_version are refused, naming both versions")
'''

with tempfile.TemporaryDirectory(prefix='ltm-api-version-') as directory:
    work = Path(directory)
    for name, version in [('v2_0', '(2u << 16)'), ('v2_7', '(2u << 16) | 7u'), ('v1_2', '(1u << 16) | 2u'), ('v3_0', '(3u << 16)'), ('none', None)]:
        source = work / f'{name}.c'
        source.write_text('void qemu_ios_main(void) {}\n'
                          + (f'unsigned qemu_ios_api_version(void) {{ return {version}; }}\n' if version else ''))
        subprocess.run(['cc', '-dynamiclib', source, '-o', work / f'{name}.dylib'], check=True)
    (work / 'main.swift').write_text(MAIN)
    subprocess.run(['xcrun', 'swiftc', *device_runtime.swift_flags(ROOT), '-swift-version', '5',
                    '-module-cache-path', work / 'modules', ROOT / 'LightTouchDevice/Qemu.swift', work / 'main.swift',
                    '-o', work / 'check'], check=True, stdout=subprocess.DEVNULL)
    sys.exit(subprocess.run([work / 'check', work]).returncode)
