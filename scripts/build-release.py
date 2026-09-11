#!/usr/bin/env python3
"""Build a self-contained Light Touch app with the existing bundled firmware."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'
GUEST_PAYLOADS = frozenset(('MBXGLEngine', 'sbdlicon', 'ithalt', 'it_agent', 'it_typein.dylib',
                          'com.qemu.it-agent.plist', 'itstatus', 'itmedia', 'itphoto',
                          'itproxy', 'ittrust', 'itorient'))
GUEST_COMPONENTS = ('armv6-toolchain', 'it-gles', 'it-instprogress', 'it-halt', 'it-agent',
                    'it-status', 'it-media', 'it-proxy', 'it-orientation')
SOURCE_EXCLUSIONS = {'.git', '.build', 'dist', '__pycache__', 'xcuserdata', '.DS_Store'}
NATIVE_RECIPES = frozenset(('scripts/build-package-native.sh', 'scripts/build-static-deps.sh',
                           'scripts/dependency-sources.py', 'build-support/dependencies.json',
                           'build-support/patches/glib-pipe2-availability.patch',
                           'scripts/test-glib-compat.py', 'scripts/check-macho.py'))
FFMPEG_PATCHES = ('h264-chunk-er.patch', 'h264-cavlc-pcm-offset.patch')


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def source_identity(root):
    """Identify working sources too: local uncommitted work is never hidden."""
    root = Path(root)
    probe = subprocess.run(['git', '-C', str(root), 'rev-parse', '--show-toplevel'],
                           capture_output=True, text=True)
    revision = None
    gitlinks = {}
    submodules = {}
    if probe.returncode == 0 and Path(probe.stdout.strip()).resolve() == root.resolve():
        revision = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
        names = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z',
                                         '--cached', '--others', '--exclude-standard']).decode().split('\0')
        dirty = bool(subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain']))
        staged = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--stage', '-z']).decode()
        for entry in staged.split('\0'):
            if not entry:
                continue
            metadata, name = entry.split('\t', 1)
            mode, commit, stage = metadata.split()
            if mode == '160000':
                gitlinks[name] = {'mode': mode, 'recorded_revision': commit}
    else:
        # Supports reviewing a source-only staging tree; never report it clean.
        names = [str(p.relative_to(root)) for p in root.rglob('*') if p.is_file()]
        dirty = True
    aggregate = hashlib.sha256()
    count = 0
    for name in sorted(set(names)):
        if not name or any(part in SOURCE_EXCLUSIONS
                           for part in Path(name).parts):
            continue
        path = root / name
        if name in gitlinks:
            module = {**gitlinks[name], 'initialized': (path / '.git').exists()}
            if module['initialized']:
                module['source'] = source_identity(path)
            submodules[name] = module
            content = hashlib.sha256(json.dumps(module, sort_keys=True).encode()).hexdigest()
        elif path.is_symlink():
            content = hashlib.sha256(os.readlink(path).encode()).hexdigest()
        elif path.is_file():
            content = digest(path)
        else:
            continue
        mode = str(path.stat().st_mode & 0o111) if path.exists() else 'missing'
        aggregate.update(name.encode() + b'\0' + content.encode() + b'\0' + mode.encode() + b'\0')
        count += 1
    return {'revision': revision, 'dirty': dirty, 'source_sha256': aggregate.hexdigest(),
            'files': count, 'submodules': submodules}


def read_record(path, schema_key='schema_version'):
    require(path, 'build provenance record')
    try:
        value = json.loads(path.read_text())
    except (json.JSONDecodeError, UnicodeError) as error:
        raise ValueError(f'Invalid build record: {path}: {error}') from error
    if not isinstance(value, dict) or value.get(schema_key) != 1:
        raise ValueError(f'Unsupported build record: {path}')
    return value


def hashes(entries, description):
    result = {}
    if not isinstance(entries, list) or not entries:
        raise ValueError(f'Missing {description} inventory')
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError(f'Invalid {description} entry: {entry}')
        name, checksum = entry.get('path'), entry.get('sha256')
        if (not isinstance(name, str) or not name or Path(name).is_absolute()
                or '..' in Path(name).parts or name in result
                or not isinstance(checksum, str) or not re.fullmatch('[0-9a-f]{64}', checksum)):
            raise ValueError(f'Invalid or duplicate {description} entry: {entry}')
        result[name] = checksum
    return result


def verify_hashes(root, expected, description):
    for name, checksum in expected.items():
        path = root / name
        require(path, description)
        if digest(path) != checksum:
            raise ValueError(f'{description} differs from its build record: {path}')


def guest_source_hashes(qemu):
    selected = {}
    for component in GUEST_COMPONENTS:
        directory = qemu / 'contrib' / component
        require(directory, f'guest source component {component}', directory=True)
        for path in directory.iterdir():
            if (path.is_file() and path.name != 'gles_stubs.h'
                    and path.suffix in ('.c', '.h', '.sh', '.py', '.xml', '.plist', '.entitlements', '.txt')):
                selected[str(path.relative_to(qemu))] = digest(path)
    return selected


def validate_guest(args, guest):
    record = read_record(guest.parent / 'guest-tools.json', 'schema')
    if record.get('builder', {}).get('sha256') != digest(SCRIPTS / 'build-guest-tools.sh'):
        raise ValueError('Guest build recipe has changed; rebuild guest tools')
    if Path(record.get('qemu_source', '')).resolve() != args.qemu_source:
        raise ValueError('Guest tools were built from a different QEMU checkout')
    expected = hashes(record.get('outputs'), 'guest payload')
    if set(expected) != GUEST_PAYLOADS:
        raise ValueError('Guest build record must declare exactly the 12 required payloads')
    require(guest, 'guest tools directory', directory=True)
    if {path.name for path in guest.iterdir()} != GUEST_PAYLOADS:
        raise ValueError('Guest tools directory must contain exactly the 12 required payloads')
    verify_hashes(guest, expected, 'Guest payload')
    if hashes(record.get('source_inputs'), 'guest source') != guest_source_hashes(args.qemu_source):
        raise ValueError('Guest source inputs have changed; rebuild guest tools')
    return record


def tracked_usbmuxd(source):
    def git(*args):
        return subprocess.check_output(['git', '-C', str(source), *args])
    untracked = git('ls-files', '--others', '--exclude-standard', '-z').decode().split('\0')
    if any(name and Path(name).name != '.DS_Store' for name in untracked):
        raise ValueError('usbmuxd has untracked source files; add them to Git and rebuild native dependencies')
    files = []
    for name in sorted(set(git('ls-files', '-z').decode().split('\0'))):
        if not name or Path(name).name == '.DS_Store':
            continue
        path = source / name
        if path.is_file():
            files.append({'path': name, 'sha256': digest(path), 'executable': bool(path.stat().st_mode & 0o111)})
    return {
        'commit': git('rev-parse', 'HEAD').decode().strip(),
        'tracked_diff_sha256': hashlib.sha256(git('diff', '--binary', 'HEAD', '--', '.', ':(exclude).DS_Store')).hexdigest(),
        'files': files,
    }


def validate_native(args, root):
    native = read_record(root / 'native-build.json')
    if Path(native.get('qemu_source', '')).resolve() != args.qemu_source:
        raise ValueError('Native build was configured for a different QEMU checkout')
    if Path(native.get('usbmuxd_source', '')).resolve() != args.usbmuxd_source:
        raise ValueError('Native build used a different usbmuxd checkout')
    static = Path(native.get('static_deps', '')).resolve()
    if args.static_deps and args.static_deps != static:
        raise ValueError('--static-deps differs from the prefix configured into the native build')
    if set(native.get('recipes', {})) != NATIVE_RECIPES:
        raise ValueError('Native build has incomplete recipe provenance; rebuild native dependencies')
    verify_hashes(ROOT, hashes([{'path': name, 'sha256': checksum}
                               for name, checksum in native['recipes'].items()], 'native recipe'), 'Native recipe')
    previous = native.get('usbmuxd', {})
    current = tracked_usbmuxd(args.usbmuxd_source)
    if any(previous.get(name) != value for name, value in current.items()):
        raise ValueError('usbmuxd source has changed since the native build; rebuild native dependencies')
    static_inputs = hashes(native.get('static_inputs'), 'static input')
    if {str(path.relative_to(static)) for path in static.rglob('*') if path.is_file()} != set(static_inputs):
        raise ValueError('Static prefix file inventory differs from its native build record')
    verify_hashes(static, static_inputs, 'Static input')
    for name in FFMPEG_PATCHES:
        current_patch = args.qemu_source / 'contrib/ffmpeg' / name
        built_patch = root / 'prefix/share/licenses/ffmpeg' / name
        require(current_patch, 'current FFmpeg patch')
        require(built_patch, 'preserved FFmpeg build patch')
        if digest(current_patch) != digest(built_patch):
            raise ValueError(f'FFmpeg patch has changed since the native build: {name}; rebuild native dependencies')
    for path, label in ((root / 'qemu-build/build.ninja', 'configured native QEMU build'),
                        (root / 'qemu-build/libqemu-arm.dylib', 'QEMU library'),
                        (root / 'prefix/lib/libimobiledevice-1.0.dylib', 'native device library'),
                        (root / 'prefix/lib/libplist-2.0.dylib', 'native plist library'),
                        (root / 'build/usbmuxd/src/usbmuxd', 'native usbmuxd')):
        require(path, label)
    return native


def validate_output(args):
    if args.output.exists() or args.output.is_symlink():
        raise ValueError(f'Output already exists: {args.output}; choose a new directory')
    for source in (ROOT, args.qemu_source, args.usbmuxd_source):
        source = source.resolve()
        if not args.output.is_relative_to(source):
            continue
        relative = args.output.relative_to(source)
        if '.git' in relative.parts:
            raise ValueError('Output must not be inside Git metadata')
        ignored = subprocess.run(['git', '-C', str(source), 'check-ignore', '--quiet', '--no-index',
                                  '--', str(relative) + '/'], capture_output=True).returncode == 0
        if not ignored and not any(part in SOURCE_EXCLUSIONS - {'.git', '.DS_Store'} for part in relative.parts):
            raise ValueError(f'Output inside source checkout must be Git-ignored: {args.output}')
    for name in ('assets', 'sdk', 'native_build', 'static_deps', 'guest_tools', 'source_packages'):
        selected = getattr(args, name)
        if selected and args.output.is_relative_to(selected):
            raise ValueError(f'Output must be outside the {name.replace("_", " ")} input: {args.output}')


def copy_provenance(output, native_record, guest_record):
    copies = {}
    for name, source in (('native-build.json', native_record), ('guest-tools.json', guest_record)):
        destination = output / name
        shutil.copyfile(source, destination)
        copies[name] = digest(destination)
    return copies


def run(command, env, log):
    command = list(map(str, command))
    print('+ ' + shlex.join(command), flush=True)
    with log.open('ab') as output:
        output.write(('\n+ ' + shlex.join(command) + '\n').encode())
        output.flush()
        result = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}); see {log}')


def require(path, description, directory=False):
    if not (path.is_dir() if directory else path.is_file()):
        raise ValueError(f'Missing {description}: {path}')


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path, help='New output directory; existing directories are never overwritten')
    parser.add_argument('--qemu-source', type=Path, default=Path(os.environ.get('QEMU_IOS_DIR', ROOT.parent / 'qemu-ios')))
    parser.add_argument('--usbmuxd-source', type=Path, default=Path(os.environ.get('USBMUXD_SOURCE_DIR', ROOT.parent / 'usbmuxd-qemu/usbmuxd')))
    parser.add_argument('--assets', type=Path, default=Path(os.environ.get('LTM_ASSETS', ROOT.parent / 'qemu-ios-files')))
    parser.add_argument('--nand', default=os.environ.get('LTM_NAND', 'nand-agent-v4'), help='Exact local NAND directory name (default: nand-agent-v4)')
    parser.add_argument('--sdk', type=Path, default=Path(os.environ['ARMV6_SDK']) if 'ARMV6_SDK' in os.environ else None,
                        help='Locally installed iPhoneOS3.1.3.sdk used to build guest helpers')
    parser.add_argument('--native-build', type=Path, help='Reuse a native build root; rebuild its QEMU before packaging')
    parser.add_argument('--static-deps', type=Path, help='Explicit compatible static prefix; otherwise build it from the pinned recipe')
    parser.add_argument('--guest-tools', type=Path, help='Reuse a guest-tools directory produced by build-guest-tools.sh')
    parser.add_argument('--source-packages', type=Path, help='Optional Xcode SourcePackages cache')
    parser.add_argument('--sign-id', default=os.environ.get('SIGN_ID', '-'), help='Signing identity; defaults to ad-hoc')
    parser.add_argument('--notary-profile', default=os.environ.get('NOTARY_PROFILE'), help='Optional notarytool keychain profile')
    parser.add_argument('--plan', action='store_true', help='Validate inputs and print selected paths without building or writing')
    args = parser.parse_args(argv)
    if args.output.expanduser().is_symlink():
        parser.error(f'Output must not be a symlink: {args.output}')
    for name in ('output', 'qemu_source', 'usbmuxd_source', 'assets', 'sdk', 'native_build', 'static_deps', 'guest_tools', 'source_packages'):
        value = getattr(args, name)
        if value is not None:
            setattr(args, name, value.expanduser().resolve())
    if args.output.exists():
        parser.error(f'Output already exists: {args.output}; choose a new directory')
    if not args.nand or Path(args.nand).name != args.nand or args.nand in ('.', '..'):
        parser.error('--nand must be a directory name within --assets')
    if args.notary_profile and args.sign_id == '-':
        parser.error('--notary-profile requires a Developer ID --sign-id')
    return args


def validate(args):
    require(args.qemu_source / 'configure', 'QEMU checkout')
    require(args.usbmuxd_source / 'configure.ac', 'usbmuxd source checkout')
    for name in ('bootrom_240_4', 'ios3/iBoot.bin', 'ios3/nor_7E18.bin'):
        require(args.assets / name, 'bundled firmware input')
    require(args.assets / args.nand, 'selected NAND', directory=True)
    validate_output(args)
    if args.guest_tools:
        validate_guest(args, args.guest_tools)
    elif args.sdk is None:
        raise ValueError('Pass --sdk /path/to/iPhoneOS3.1.3.sdk (or ARMV6_SDK) to build guest helpers')
    else:
        for name in ('usr/lib/libSystem.dylib', 'usr/include/stdio.h'):
            require(args.sdk / name, 'legacy SDK input')
    if args.static_deps:
        require(args.static_deps / 'lib/libcrypto.a', 'static OpenSSL')
    if args.native_build:
        validate_native(args, args.native_build)


def inventory(app):
    result = []
    for path in sorted(app.rglob('*')):
        name = str(path.relative_to(app))
        if path.is_symlink():
            result.append({'path': name, 'symlink': os.readlink(path)})
        elif path.is_file():
            result.append({'path': name, 'bytes': path.stat().st_size, 'sha256': digest(path)})
    return result


def main(argv=None):
    args = parse(argv)
    validate(args)
    if args.plan:
        print(json.dumps({key: str(value) if isinstance(value, Path) else value
                          for key, value in vars(args).items() if key not in ('sign_id', 'notary_profile')}, indent=2))
        return 0
    if sys.platform != 'darwin':
        raise ValueError('The product build requires macOS and Xcode')
    for tool in ('xcodebuild', 'xcrun', 'ninja', 'pkg-config', 'cc', 'codesign', 'ditto'):
        if shutil.which(tool) is None:
            raise ValueError(f'Missing build tool: {tool}')
    validate_output(args)
    args.output.mkdir(parents=True)
    log = args.output / 'build.log'
    env = os.environ.copy()
    env.update(QEMU_IOS_DIR=str(args.qemu_source), USBMUXD_SOURCE_DIR=str(args.usbmuxd_source),
               LTM_ASSETS=str(args.assets), LTM_NAND=args.nand, SIGN_ID=args.sign_id)
    if args.static_deps:
        env['LTM_STATIC_DEPS'] = str(args.static_deps)
    else:
        env.pop('LTM_STATIC_DEPS', None)
    if args.sdk:
        env['ARMV6_SDK'] = str(args.sdk)
    if args.notary_profile:
        env['NOTARY_PROFILE'] = args.notary_profile
    else:
        env.pop('NOTARY_PROFILE', None)
    sources = {'app': source_identity(ROOT), 'qemu': source_identity(args.qemu_source),
               'usbmuxd': source_identity(args.usbmuxd_source)}
    native_root = args.native_build or args.output / 'native'
    if args.native_build:
        run(['ninja', '-C', native_root / 'qemu-build', 'qemu-system-arm'], env, log)
        env['PKG_CONFIG_LIBDIR'] = str(native_root / 'prefix/lib/pkgconfig')
        env['PKG_CONFIG_PATH'] = ''
        run(['bash', args.qemu_source / 'contrib/macos-app/make-dylib-macos.sh', native_root / 'qemu-build'], env, log)
    else:
        run(['bash', SCRIPTS / 'build-package-native.sh', native_root], env, log)
    native_record = native_root / 'native-build.json'
    native = validate_native(args, native_root)
    static = Path(native['static_deps']).resolve()
    env.update(QEMU_BUILD_DIR=str(native_root / 'qemu-build'), LTM_DEPS_PREFIX=str(native_root / 'prefix'),
               LTM_STATIC_DEPS=str(static), USBMUXD_BIN=str(native_root / 'build/usbmuxd/src/usbmuxd'))
    guest = args.guest_tools or args.output / 'guest/guest-tools'
    if not args.guest_tools:
        run(['bash', SCRIPTS / 'build-guest-tools.sh', guest.parent], env, log)
    validate_guest(args, guest)
    env['LTM_GUEST_TOOLS_DIR'] = str(guest)
    derived = args.output / 'DerivedData'
    command = ['xcodebuild', '-project', ROOT / 'LightTouchMac.xcodeproj', '-scheme', 'LightTouchMac',
               '-configuration', 'Release', '-derivedDataPath', derived, '-disableAutomaticPackageResolution',
               '-onlyUsePackageVersionsFromResolvedFile', 'CODE_SIGNING_ALLOWED=NO', 'ARCHS=arm64',
               f'QEMU_IOS_DIR={args.qemu_source}', f'QEMU_BUILD_DIR={native_root / "qemu-build"}', 'build']
    if args.source_packages:
        command[1:1] = ['-clonedSourcePackagesDirPath', args.source_packages]
    run(command, env, log)
    products = derived / 'Build/Products/Release'
    apps = [p for p in products.glob('*.app') if (p / 'Contents/Info.plist').is_file()]
    if len(apps) != 1:
        raise ValueError(f'Expected one Release app in {products}, found {len(apps)}')
    app = args.output / apps[0].name
    run(['ditto', apps[0], app], env, log)
    provenance = copy_provenance(args.output, native_record, guest.parent / 'guest-tools.json')
    record = {
        'schema_version': 1, 'sources': sources, 'host_architecture': 'arm64',
        'firmware': {'nand_name': args.nand, 'components': {
            name: digest(args.assets / name) for name in ('bootrom_240_4', 'ios3/iBoot.bin', 'ios3/nor_7E18.bin')}},
        'native_build_record_sha256': provenance['native-build.json'],
        'native_build_reused': bool(args.native_build),
        'qemu_rebuilt_from_sources': sources['qemu'],
        'guest_build_record_sha256': provenance['guest-tools.json'],
        'provenance_records': provenance,
        'native_artifacts': {
            'prefix': inventory(native_root / 'prefix'),
            'qemu_library_sha256': digest(native_root / 'qemu-build/libqemu-arm.dylib'),
            'usbmuxd_sha256': digest(native_root / 'build/usbmuxd/src/usbmuxd'),
        },
        'swift_packages': json.loads((ROOT / 'LightTouchMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text()),
        'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
        'macos_sdk': subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip(),
    }
    build_record = args.output / 'build-inputs.json'
    build_record.write_text(json.dumps(record, indent=2) + '\n')
    env['LTM_BUILD_RECORD'] = str(build_record)
    run(['bash', SCRIPTS / 'package.sh', app], env, log)
    after = {'app': source_identity(ROOT), 'qemu': source_identity(args.qemu_source),
             'usbmuxd': source_identity(args.usbmuxd_source)}
    if after != sources:
        raise RuntimeError('Source files changed during the build; no release archive produced')
    entries = inventory(app)
    (args.output / 'bundle-inventory.json').write_text(json.dumps(entries, indent=2) + '\n')
    archive = args.output / 'LightTouchMac.zip'
    run(['ditto', '-c', '-k', '--keepParent', app, archive], env, log)
    (args.output / 'SHA256SUMS').write_text(f'{digest(archive)}  {archive.name}\n')
    print(f'Built {app}\nArchive: {archive}\nInputs and inventory: {args.output}', flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
