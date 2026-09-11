#!/usr/bin/env python3
"""Check guest build isolation and failure publication with a fixture toolchain."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


SCRIPT = Path(__file__).with_name("build-guest-tools.sh")
PAYLOADS = {
    "it-gles": ["MBXGLEngine"],
    "it-instprogress": ["sbdlicon"],
    "it-halt": ["ithalt"],
    "it-agent": ["it_agent", "it_typein.dylib", "com.qemu.it-agent.plist"],
    "it-status": ["itstatus"],
    "it-media": ["itmedia", "itphoto"],
    "it-proxy": ["itproxy", "ittrust"],
    "it-orientation": ["itorient"],
}


def snapshot(directory):
    return {
        str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in directory.rglob("*") if path.is_file()
    }


with tempfile.TemporaryDirectory(prefix="lighttouch guest test ") as directory:
    root = Path(directory)
    qemu = root / "qemu source"
    sdk = root / "old sdk"
    for name in ("usr/include/stdio.h", "usr/lib/libSystem.dylib"):
        path = sdk / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("fixture\n")
    tools = root / "bin"
    tools.mkdir()
    for tool in ("xcrun", "ldid"):
        path = tools / tool
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(0o755)
    toolchain = qemu / "contrib/armv6-toolchain"
    toolchain.mkdir(parents=True)
    fixture_toolchain = '''cc6() {
    if grep -q 'intentional failure' "$1"; then
        echo 'intentional failure' >&2
        return 7
    fi
    printf 'object\\n' > "$2"
}
link6() { printf 'rebuilt\\n' > "$2"; }
'''
    (toolchain / "armv6.sh").write_text(fixture_toolchain)
    for component, names in PAYLOADS.items():
        source = qemu / "contrib" / component
        source.mkdir()
        for name in names:
            if name.endswith(".plist"):
                (source / name).write_text("fixture plist\n")
                continue
            stem = {"MBXGLEngine": "mbxshim", "it_typein.dylib": "it_typein"}.get(name, name)
            (source / f"{stem}.c").write_text("fixture source\n")
            (source / name).write_text("stale binary\n")
        (source / "build.sh").write_text("echo 'development probes should not run' >&2\nexit 8\n")
    (qemu / "contrib/it-gles/genstubs.py").write_text(
        "from pathlib import Path\nimport sys\nPath(sys.argv[1]).write_text('generated')\n")
    before = snapshot(qemu)
    environment = dict(os.environ, QEMU_IOS_DIR=str(qemu), ARMV6_SDK=str(sdk),
                       LDID=str(tools / "ldid"), PATH=f"{tools}:{os.environ['PATH']}")

    def build(work, *, error=None, env=None):
        result = subprocess.run(["bash", str(SCRIPT), str(work)],
                                env=env or environment, capture_output=True, text=True)
        if error:
            assert result.returncode != 0 and error in result.stderr, result
        else:
            assert result.returncode == 0, result.stderr
        return result

    output = root / "build output"
    build(output)
    expected = {name for names in PAYLOADS.values() for name in names}
    assert {path.name for path in (output / "guest-tools").iterdir()} == expected
    assert all(path.read_text() == ("fixture plist\n" if path.suffix == ".plist" else "rebuilt\n")
               for path in (output / "guest-tools").iterdir())
    record = json.loads((output / "guest-tools.json").read_text())
    assert {entry["path"] for entry in record["outputs"]} == expected
    for entry in record["outputs"]:
        assert entry["sha256"] == hashlib.sha256((output / "guest-tools" / entry["path"]).read_bytes()).hexdigest()
    assert record["builder"]["sha256"] == hashlib.sha256(SCRIPT.read_bytes()).hexdigest()
    assert snapshot(qemu) == before, "build changed its source checkout"
    build(output, error="use a new build directory")
    assert snapshot(qemu) == before

    # A compile failure must retain logs, publish no usable output directory, and
    # leave the source checkout (including its old outputs) untouched.
    failed = root / "failed build"
    media_source = qemu / "contrib/it-media/itmedia.c"
    media_source.write_text("intentional failure\n")
    before_failure = snapshot(qemu)
    build(failed, error="intentional failure")
    assert not (failed / "guest-tools").exists()
    assert (failed / "logs/it-media.log").exists()
    assert snapshot(qemu) == before_failure

    # Even a successful recipe that forgets an output cannot reuse a stale
    # tracked binary from the checkout.
    media_source.write_text("fixture source\n")
    (toolchain / "armv6.sh").write_text(fixture_toolchain + '''
link6() {
    [ "${2##*/}" = ithalt ] && return 0
    printf 'rebuilt\\n' > "$2"
}
''')
    missing = root / "missing payload"
    build(missing, error="build did not produce required payload")
    assert not (missing / "guest-tools").exists()

    no_sdk = root / "missing sdk build"
    build(no_sdk, error="set ARMV6_SDK", env=dict(environment, ARMV6_SDK=""))
    assert not no_sdk.exists(), "preflight failure created a build directory"

print("PASS: payloads and provenance, source isolation, fresh output guard, failure publication, stale output rejection, explicit SDK")
