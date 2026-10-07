"""Link the profile-neutral HostRuntime package into standalone host probes."""
from swift_package import product_flags


def swift_flags(root, *, target=None):
    return [*product_flags(root, package='Packages/HostRuntime', product='HostRuntime',
                           cache='host-runtime', target=target),
            '-Xfrontend', '-import-module', '-Xfrontend', 'HostRuntime']


def schema_flags(root, *, target=None):
    """FirmwareKit's FirmwareSchema product (the wire types, StorageCapacity, DeveloperTools, GuestArchive)."""
    return [*product_flags(root, package='Packages/FirmwareKit', product='FirmwareSchema',
                           cache='firmware-schema', target=target),
            '-Xfrontend', '-import-module', '-Xfrontend', 'FirmwareSchema']
