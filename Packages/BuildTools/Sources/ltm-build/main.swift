import BuildTools
import Foundation
import ReleaseChecks

// scripts/ltm-build SUBCOMMAND ...: the build's tools (Packages/BuildTools). LTM_ROOT is the repository (the wrapper
// sets it).
//
//   vendor [--print]                                   scripts/vendor
//   check-macho [--minos V] [--arch A ...] [--no-weak-imports] PATH ...
//                                                      every slice's macOS load closure (default minos 14.0, every slice)
//   merge-native OUTPUT ROOT ...                       per-architecture native roots into one universal root
//   sources fetch --group G --destination DIR [--cache DIR ...] [--offline] [--manifest FILE]
//   sources stage-git --source DIR --destination DIR --record FILE
//   sources note NAME [PATCH ...]                      a shipped package's SOURCE.txt
//   static-record ROOT ARCH                            build-static-deps.sh's static-build.json
//   native-record ROOT STATIC QEMU USBMUXD ARCH        build-package-native.sh's native-build.json

let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LTM_ROOT"] ?? FileManager.default.currentDirectoryPath)
let manifest = root.appendingPathComponent("build-support/dependencies.json")
var arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: scripts/ltm-build vendor|check-macho|merge-native|sources|static-record|native-record ...\n".utf8))
    exit(2)
}
/// The values of every `--name VALUE` (removed from `arguments`).
@MainActor func values(_ name: String) -> [String] {
    var found: [String] = []
    while let i = arguments.firstIndex(of: name), i + 1 < arguments.count {
        found.append(arguments[i + 1]); arguments.removeSubrange(i...i + 1)
    }
    return found
}
@MainActor func flag(_ name: String) -> Bool {
    guard let i = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: i); return true
}
func path(_ text: String) -> URL { URL(fileURLWithPath: text) }

do {
    guard !arguments.isEmpty else { usage() }
    switch arguments.removeFirst() {
    case "vendor":
        let vendor = Vendor(root: root)
        if arguments == ["--print"] { print(try vendor.directory().path) }
        else if arguments.isEmpty { print(try vendor.build().path) }
        else { print(Vendor.usage); exit(2) }
    case "check-macho":
        let minimum = values("--minos").last ?? "14.0", archs = values("--arch"), noWeak = flag("--no-weak-imports")
        guard !arguments.isEmpty else { usage() }
        for file in arguments.map(path) {
            for arch in archs.isEmpty ? try MachOClosure.architectures(file) : archs {
                for binary in try MachOClosure.check(file, minimum: minimum, arch: arch, noWeakImports: noWeak) {
                    print("\(arch): \(binary.path)")
                }
            }
        }
    case "merge-native":
        guard arguments.count >= 2 else { usage() }
        try MergeNative.merge(output: path(arguments[0]), roots: arguments.dropFirst().map(path))
    case "sources":
        guard !arguments.isEmpty else { usage() }
        let command = arguments.removeFirst(), source = values("--manifest").last.map(path) ?? manifest
        switch command {
        case "fetch":
            guard let group = values("--group").last, let destination = values("--destination").last else { usage() }
            try DependencySources.fetch(manifest: source, group: group, destination: path(destination),
                                        caches: values("--cache").map(path), offline: flag("--offline"))
        case "stage-git":
            guard let from = values("--source").last, let to = values("--destination").last, let record = values("--record").last else { usage() }
            try DependencySources.stageGit(source: path(from), destination: path(to), record: path(record))
        case "note":
            guard let name = arguments.first else { usage() }
            print(try DependencySources.note(manifest: source, name: name, patches: Array(arguments.dropFirst())))
        default: usage()
        }
    case "static-record":
        guard arguments.count == 2 else { usage() }
        try Records.writeStatic(source: root, root: path(arguments[0]), arch: arguments[1])
    case "native-record":
        guard arguments.count == 5 else { usage() }
        try Records.writeNative(source: root, root: path(arguments[0]), staticPrefix: path(arguments[1]), qemu: path(arguments[2]),
                                usbmuxd: path(arguments[3]), arch: arguments[4])
    default: usage()
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
