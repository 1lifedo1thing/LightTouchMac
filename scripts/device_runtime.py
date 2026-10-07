"""Import and link the single typed helper/session owner used by the GUI."""
from swift_package import product_flags


def swift_flags(root, *, target=None):
    return [*product_flags(root, package='Packages/DeviceRuntime', product='DeviceRuntime',
                           cache='device-runtime', target=target),
            '-I', str(root / 'Packages/DeviceRuntime/Sources/LTMLinkC'),
            '-Xfrontend', '-import-module', '-Xfrontend', 'DeviceRuntime',
            '-Xfrontend', '-import-module', '-Xfrontend', 'HostRuntime']
