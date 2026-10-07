"""Link the DeviceServices package's products and build the services helper (LightTouchServices) the way its Xcode
target does: HostServiceWire plus the helper's own engine (LightTouchServices/Engine) over libimobiledevice."""
import os
from pathlib import Path
import shlex
import subprocess
from swift_package import product_flags
import swift_subprocess

LOCKDOWN = ['lockdown-tz', 'lockdown-mcinstall']   # LightTouchServices/Lockdown: C operations, linked to libimobiledevice


def wire_flags(root, *, target=None):
    """HostServiceWire: the request/event protocol, errors, Timeouts, DeviceServices' paths, HomeScreenLayout."""
    return [*product_flags(Path(root), package='Packages/DeviceServices', product='HostServiceWire',
                           cache='host-service-wire', target=target),
            '-Xfrontend', '-import-module', '-Xfrontend', 'HostServiceWire']


def client_sources(root):
    """The app's side (HostServiceClient: DeviceServices' remote calls, HostServiceWorkers, NotificationProxy), as
    link flags; the name stays for the callers that splice it among their sources."""
    # The C shims' module maps from the one checkout every probe's Subprocess flags use (a second copy of the same
    # module map is a redefinition when a probe passes both).
    _, checkouts = swift_subprocess.products(Path(root))
    maps = [checkouts / 'swift-system/Sources/CSystem/include/module.modulemap',
            checkouts / 'swift-subprocess/Sources/_SubprocessCShims/include/module.modulemap']
    return [*product_flags(Path(root), package='Packages/DeviceServices', product='HostServiceClient',
                           cache='host-service-client'),
            *[arg for path in maps for arg in ('-Xcc', '-fmodule-map-file=' + str(path))],
            '-Xfrontend', '-import-module', '-Xfrontend', 'HostServiceClient', *wire_flags(root)]


def engine_sources(root):
    """The helper's engine (everything but ServiceMain)."""
    return sorted(str(p) for p in (Path(root) / 'LightTouchServices/Engine').glob('*.swift'))

def imobiledevice_flags():
    """libimobiledevice and libplist from Homebrew, as a Debug build of the target falls back to."""
    env = dict(os.environ, PATH='/opt/homebrew/bin:/usr/local/bin:' + os.environ.get('PATH', ''))
    return shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'libimobiledevice-1.0', 'libplist-2.0'],
                                               env=env, text=True))

def build_worker(root, destination, flags, *, log=None, frameworks=None):
    """`frameworks`: a directory holding libimobiledevice-1.0 and libplist-2.0 to link (and load) in place of
    Homebrew's, e.g. an app's Contents/Frameworks (1.x's lockdownd needs its SSLv3 build)."""
    root, destination = Path(root), Path(destination)
    lockdown = root / 'LightTouchServices/Lockdown'
    native = imobiledevice_flags()
    if frameworks:
        native = [f for f in native if f.startswith('-I')] + ['-L', str(frameworks), '-limobiledevice-1.0', '-lplist-2.0',
                                                                 '-Xlinker', '-rpath', '-Xlinker', str(frameworks)]
    objects = []
    for name in LOCKDOWN:
        obj = destination.parent / f'{name}.o'
        subprocess.run(['xcrun', 'clang', '-c', '-O2', *[f for f in native if f.startswith('-I')],
                        lockdown / f'{name}.c', '-o', obj], check=True, stdout=log, stderr=subprocess.STDOUT if log else None)
        objects.append(obj)
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', destination.parent / 'modules',
               *[x for f in native if f.startswith('-I') for x in ('-Xcc', f)],
               *flags, *wire_flags(root), *engine_sources(root), root / 'LightTouchServices/ServiceMain.swift', '-import-objc-header', lockdown / 'Lockdown.h',
               *objects, *[f for f in native if not f.startswith('-I')], '-o', destination]
    subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT if log else None)
