#!/usr/bin/env python3
"""Merge per-architecture native build roots into one universal root for package.sh.

Each input is a build-package-native.sh output built with a different LTM_ARCH.
The output has the same layout package.sh consumes: every Mach-O (dylibs,
executables, static archives) is lipo'd; all other files must match exactly once
each root's own path is replaced with the output's.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

# The parts of a native root that packaging reads.
PARTS = ('prefix', 'static/prefix', 'qemu-build/libqemu-arm.dylib', 'build/usbmuxd/src/usbmuxd')
# Build-time metadata for compiling against one slice; packaging never reads it, and
# cross-compiled slices legitimately differ (e.g. how Meson found zlib).
SKIPPED = ('lib/pkgconfig/', 'share/pkgconfig/')
SKIPPED_SUFFIXES = ('.la',)


def macho(path):
    with path.open('rb') as stream:
        magic = stream.read(8)
    return magic[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe') or magic == b'!<arch>\n'


def relocated(text, root, output):
    # .pc, .la and a few installed paths name the build root; point them at the output.
    return text.replace(str(root).encode(), str(output).encode())


def relink(path, root, output, scratch):
    """Copy of a Mach-O whose install name, dependencies and rpaths name output, not root."""
    if path.read_bytes()[:8] == b'!<arch>\n':
        return path
    copy = scratch / f'{len(list(scratch.iterdir()))}-{path.name}'
    shutil.copy2(path, copy)
    copy.chmod(0o755)
    edits = []
    listing = subprocess.check_output(['otool', '-l', str(copy)], text=True)
    for line in listing.splitlines():
        line = line.strip()
        if line.startswith(('name ', 'path ')) and str(root) in line:
            old = line.split(' ', 1)[1].rsplit(' (offset', 1)[0]
            new = old.replace(str(root), str(output))
            edits += ['-rpath', old, new] if line.startswith('path ') else ['-change', old, new]
    install_id = subprocess.check_output(['otool', '-D', str(copy)], text=True).splitlines()[1:]
    if install_id and str(root) in install_id[0]:
        edits += ['-id', install_id[0].replace(str(root), str(output))]
    if edits:
        subprocess.run(['install_name_tool', *edits, str(copy)], check=True, capture_output=True)
    return copy


def files(root, output):
    result = {}
    for path in root.rglob('*'):
        name = str(path.relative_to(root))
        if (path.is_file() or path.is_symlink()) and not (
                name.startswith(SKIPPED) or name.endswith(SKIPPED_SUFFIXES)):
            result[relocated(name.encode(), root, output).decode()] = path
    return result


def merge(output, part, slices, scratch):
    target_root = output.resolve() / part
    trees = []
    for root in slices.values():
        source = root / part
        trees.append((root, {'': source} if source.is_file() else files(source, target_root)))
    names = set(trees[0][1])
    for root, tree in trees[1:]:
        if set(tree) != names:
            raise ValueError(f'{part}: file lists differ: {sorted(names ^ set(tree))[:5]}')
    for name in sorted(names):
        inputs = [(root, tree[name]) for root, tree in trees]
        target = target_root / name if name else target_root
        target.parent.mkdir(parents=True, exist_ok=True)
        first = inputs[0][1]
        if first.is_symlink():
            links = {str(path.readlink()) for _, path in inputs}
            if len(links) != 1:
                raise ValueError(f'{part}/{name}: symlink targets differ')
            target.symlink_to(links.pop())
        elif macho(first):
            thin = [relink(path, root, output.resolve(), scratch) for root, path in inputs]
            subprocess.run(['lipo', '-create', *map(str, thin), '-output', str(target)], check=True)
            shutil.copymode(first, target)
            if thin[0] != first:  # relinked, so arm64 needs a fresh ad-hoc signature
                subprocess.run(['codesign', '-f', '-s', '-', str(target)], check=True, capture_output=True)
        else:
            contents = {relocated(path.read_bytes(), root, output.resolve()) for root, path in inputs}
            if len(contents) != 1:
                raise ValueError(f'{part}/{name}: differs between architectures and is not a Mach-O')
            target.write_bytes(contents.pop())
            shutil.copymode(first, target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New output directory')
    parser.add_argument('slices', type=Path, nargs='+', help='Native build roots, one per architecture')
    args = parser.parse_args()
    if args.output.exists():
        sys.exit(f'Output already exists: {args.output}')
    slices = {}
    for root in args.slices:
        record = json.loads((root / 'native-build.json').read_text())
        arch = record['architecture']
        if arch in slices:
            sys.exit(f'Two native roots for {arch}: {slices[arch]} and {root}')
        slices[arch] = root.resolve()
    try:
        with tempfile.TemporaryDirectory() as scratch:
            for part in PARTS:
                merge(args.output, part, slices, Path(scratch))
    except (ValueError, subprocess.CalledProcessError) as error:
        shutil.rmtree(args.output, ignore_errors=True)
        sys.exit(str(error))
    record = {'schema_version': 1, 'architectures': sorted(slices),
              'static_deps': str(args.output.resolve() / 'static/prefix'),
              'slices': {arch: json.loads((root / 'native-build.json').read_text())
                         for arch, root in sorted(slices.items())}}
    (args.output / 'native-build.json').write_text(json.dumps(record, indent=2) + '\n')
    print(f'Universal native root ({", ".join(sorted(slices))}): {args.output}')


if __name__ == '__main__':
    main()
