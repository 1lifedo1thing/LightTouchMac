#!/usr/bin/env python3
"""Exercise deployment-target and relocation checks against real Mach-O files."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

CHECK = pathlib.Path(__file__).with_name('check-macho.py')


def run(*args):
    return subprocess.run(list(map(str, args)), check=True, capture_output=True, text=True)


def verify(*paths, bundle=None, error=None, no_weak_imports=False):
    cmd = [sys.executable, CHECK, '--minos', '14.0']
    if bundle:
        cmd += ['--bundle', bundle]
    if no_weak_imports:
        cmd += ['--no-weak-imports']
    result = subprocess.run(list(map(str, cmd + list(paths))), capture_output=True, text=True)
    if error:
        assert result.returncode != 0 and error in result.stderr, result
    else:
        assert result.returncode == 0, result.stderr


with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    libsrc, mainsrc = root / 'lib.c', root / 'main.c'
    libsrc.write_text('int value(void) { return 0; }\n')
    mainsrc.write_text('extern int value(void); int main(void) { return value(); }\n')
    libs = []
    for minimum in ('14.0', '26.0'):
        lib = root / f'lib{minimum}.dylib'
        run('cc', '-arch', 'arm64', f'-mmacosx-version-min={minimum}', '-dynamiclib',
            libsrc, '-install_name', lib, '-o', lib)
        exe = root / f'exe{minimum}'
        run('cc', '-arch', 'arm64', '-mmacosx-version-min=14.0', mainsrc, lib, '-o', exe)
        libs.append(lib)
        verify(exe, error='requires macOS 26.0' if minimum == '26.0' else None)
    app = root / 'Test.app'
    frameworks, macos = app / 'Contents/Frameworks', app / 'Contents/MacOS'
    frameworks.mkdir(parents=True)
    macos.mkdir()
    executable = macos / 'Test'
    shutil.copy(root / 'exe14.0', executable)
    verify(executable, bundle=app, error='escapes relocatable bundle')
    shutil.copy(libs[0], frameworks / libs[0].name)
    run('install_name_tool', '-change', libs[0], '@rpath/' + libs[0].name, executable)
    verify(executable, bundle=app, error='unresolved dependency')
    run('install_name_tool', '-add_rpath', '@executable_path/../Frameworks', executable)
    verify(executable, bundle=app)
    tools = app / 'Contents/Resources/tools'
    tools.mkdir(parents=True)
    tool = tools / 'tool'
    shutil.copy(executable, tool)
    verify(tool, bundle=app, error='unresolved dependency')
    run('install_name_tool', '-delete_rpath', '@executable_path/../Frameworks',
        '-add_rpath', '@executable_path/../../Frameworks', tool)
    verify(tool, bundle=app)
    (frameworks / libs[0].name).unlink()
    verify(executable, bundle=app, error='unresolved dependency')
    libs[0].unlink()
    verify(root / 'exe14.0', error='unresolved dependency')
    weaksrc = root / 'weak.c'
    weaksrc.write_text('extern int optional_api(void) __attribute__((weak_import));\n'
                       'int value(void) { return optional_api ? optional_api() : 0; }\n')
    weaklib = root / 'weak.dylib'
    run('cc', '-arch', 'arm64', '-mmacosx-version-min=14.0', '-dynamiclib',
        '-undefined', 'dynamic_lookup', weaksrc, '-o', weaklib)
    verify(weaklib)  # A low LC_BUILD_VERSION alone cannot establish runtime compatibility.
    verify(weaklib, no_weak_imports=True, error='unexpected weak imports')
    verify(root / 'lib26.0.dylib', no_weak_imports=True, error='requires macOS 26.0')
    # A universal binary needs every slice of every dependency.
    both = root / 'both.dylib'
    run('cc', '-arch', 'arm64', '-arch', 'x86_64', '-mmacosx-version-min=14.0', '-dynamiclib',
        libsrc, '-install_name', both, '-o', both)
    fat = root / 'fat'
    run('cc', '-arch', 'arm64', '-arch', 'x86_64', '-mmacosx-version-min=14.0', mainsrc, both, '-o', fat)
    verify(fat)
    run('lipo', both, '-thin', 'arm64', '-output', both)
    verify(fat, error='missing x86_64 slice')
print('PASS: compatible closure, newer transitive library, external path, bundle relocation, missing dependency, weak imports, universal slices')
