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
    app = root / 'LightTouchMac/Services'
    return [str(app / name) for name in ['HostServiceTypes.swift', 'HostServiceResources.swift']]

def local_engine_stub(tmp):
    path = tmp / 'LocalServiceFixture.swift'
    path.write_text('''import Foundation
extension DeviceServices {
 var local: Bool { true }
 func remote(_ operation: HostServiceOperation, seconds: Double,
   progress: @escaping @Sendable (HostServiceProgress) -> Void = { _ in }) async throws -> HostServiceValue {
  fatalError("local engine fixture unexpectedly used remote transport")
 }
}
''')
    return [str(path)]


def engine(root):
    """swiftc arguments for the services engine as the helper builds it (LIGHTTOUCH_SERVICES, its bridging header
    over the real C API), with production IMobileDevice.swift and tests/fixtures/imobiledevice-fake.swift in place of
    the library: the check sets IMDFake's closures."""
    headers = [x for f in host_service.imobiledevice_flags() if f.startswith('-I') for x in ('-Xcc', f)]
    return ['-D', 'LIGHTTOUCH_SERVICES', *headers, '-import-objc-header', str(root / 'LightTouchServices/Lockdown/Lockdown.h'),
            str(root / 'LightTouchMac/Transport/IMobileDevice.swift'), str(root / 'tests/fixtures/imobiledevice-fake.swift')]
