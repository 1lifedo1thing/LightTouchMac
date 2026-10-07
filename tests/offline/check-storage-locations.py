#!/usr/bin/env python3
"""NativeLogging: QEMU's stdout/stderr go to native.log, app events to app.log only (unified logging separately).
Redirects the process's own stdout/stderr, so it runs as its own process rather than in the Unit plan; the layout,
cache and log-pipe checks are LightTouchCoreTests (StorageLocationsTests). State is a temporary LTM_STATE_DIR.
"""
from pathlib import Path
import os
import sys as _sys, pathlib as _pl; _sys.path.insert(0, str(_pl.Path(__file__).resolve().parents[2] / "scripts"))
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='ltm-storage-locations-') as temporary:
    work = Path(temporary)
    source = work / 'check.swift'
    source.write_text(r'''
import Foundation

@main struct Check {
    static func text(_ url: URL) -> String { try! String(contentsOf: url, encoding: .utf8) }
    static func main() async throws {
        let savedOut=dup(STDOUT_FILENO), savedErr=dup(STDERR_FILENO)
        try Bundled.requireStorage()
        try NativeLogging.start()
        fputs("native error marker\n",stderr);fputs("native output marker\n",stdout);fflush(stdout)
        logEvent("app event only marker")
        await AppEventLog.shared.flush();NativeLogging.flush()
        let native = text(Bundled.logsDirectory.appendingPathComponent("native.log"))
        precondition(native.contains("native error marker") && native.contains("native output marker"))
        precondition(!native.contains("app event only marker"))
        precondition(text(Bundled.logsDirectory.appendingPathComponent("app.log")).contains("app event only marker"))
        _=dup2(savedOut,STDOUT_FILENO);_=dup2(savedErr,STDERR_FILENO)
        Darwin.close(savedOut);Darwin.close(savedErr)
        print("PASS: native stdout/stderr in native.log, app events in app.log only")
    }
}
''')
    subprocess.run(['xcrun','swiftc', *__import__('host_runtime').schema_flags(__import__('pathlib').Path(__file__).resolve().parents[2]),'-swift-version','6','-default-isolation','MainActor',
                    '-module-cache-path',str(work/'modules'),
                    *[str(root/'LightTouchMac'/name) for name in ['Library/StorageLocations.swift','Transport/NativeLogging.swift','Library/Bundled.swift','Transport/AppEventLog.swift']],
                    str(source),'-o',str(work/'check')],check=True)
    subprocess.run([str(work/'check')], env=dict(os.environ,LTM_STATE_DIR=str(work/'isolated-app')),check=True)
