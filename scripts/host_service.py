"""Compile the same narrow service boundary used by the Xcode helper target."""
import os
from pathlib import Path
import shlex
import subprocess

SERVICE_SOURCES = ['DeviceServices', 'HostServiceTypes', 'HostServiceProtocol',
                   'HostServiceResources', 'HostServiceWorkers', 'AFC',
                   'InstallationProxy', 'SpringBoardServices', 'LockdownState']
LOCKDOWN = ['lockdown-tz', 'lockdown-mcinstall']   # LightTouchServices/Lockdown: C operations, linked to libimobiledevice

def client_sources(root):
    root = Path(root)
    return [root / f'LightTouchMac/Services/{name}.swift' for name in SERVICE_SOURCES] + [
        root / f'LightTouchMac/Transport/{name}.swift' for name in ['DeviceExecution', 'IMobileDevice']]

def imobiledevice_flags():
    """libimobiledevice and libplist from Homebrew, as a Debug build of the target falls back to."""
    env = dict(os.environ, PATH='/opt/homebrew/bin:/usr/local/bin:' + os.environ.get('PATH', ''))
    return shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'libimobiledevice-1.0', 'libplist-2.0'],
                                               env=env, text=True))

def build_worker(root, destination, flags, *, log=None):
    root, destination = Path(root), Path(destination)
    lockdown = root / 'LightTouchServices/Lockdown'
    native = imobiledevice_flags()
    objects = []
    for name in LOCKDOWN:
        obj = destination.parent / f'{name}.o'
        subprocess.run(['xcrun', 'clang', '-c', '-O2', *[f for f in native if f.startswith('-I')],
                        lockdown / f'{name}.c', '-o', obj], check=True, stdout=log, stderr=subprocess.STDOUT if log else None)
        objects.append(obj)
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', destination.parent / 'modules',
               *flags, *client_sources(root), root / 'LightTouchMac/Services/NotificationProxy.swift',
               root / 'LightTouchServices/ServiceMain.swift', '-import-objc-header', lockdown / 'Lockdown.h',
               *objects, *[f for f in native if not f.startswith('-I')], '-o', destination]
    subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT if log else None)
