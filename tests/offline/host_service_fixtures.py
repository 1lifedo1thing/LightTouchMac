"""Shared real worker wire leaves for low-level C-engine unit fixtures.

These tests deliberately inject a local C boundary; the process transport is
covered separately by check-host-service-workers. An accidental remote route
fails rather than silently performing device I/O during a fixture.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import host_service

def leaves(root):
    """HostServiceWire (the engine's errors, timeouts, endpoint and paths), linked."""
    return host_service.wire_flags(root)

def local_engine_stub(tmp):
    return []   # the engine has no remote path to stub since it moved into LightTouchServices/Engine


def engine(root):
    """swiftc arguments for the services engine as the helper builds it (its bridging header
    over the real C API), with production IMobileDevice.swift and tests/fixtures/imobiledevice-fake.swift in place of
    the library: the check sets IMDFake's closures."""
    headers = [x for f in host_service.imobiledevice_flags() if f.startswith('-I') for x in ('-Xcc', f)]
    return [*headers, '-import-objc-header', str(root / 'LightTouchServices/Lockdown/Lockdown.h'),
            str(root / 'LightTouchServices/Engine/IMobileDevice.swift'), str(root / 'tests/fixtures/imobiledevice-fake.swift')]
