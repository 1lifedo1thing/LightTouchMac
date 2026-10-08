// firmwarekit pack-base --base DIR --out BLOB             a create output as one blob (the release build)
// firmwarekit unpack-base --blob BLOB --out DIR --seed S  that blob as a device of its own (the app, like create:
//                                                         JSON Lines on stdout, done names the lock)

import FirmwareKit
import Foundation

func packBaseCommand(_ argv: [String]) -> Never {
    do {
        guard argv.count == 4, argv[0] == "--base", argv[2] == "--out" else {
            throw FirmwareError(.internal, "pack-base requires --base DIR --out BLOB")
        }
        try PreparedBase.pack(base: URL(fileURLWithPath: argv[1]), to: URL(fileURLWithPath: argv[3]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("firmwarekit pack-base: \(error)\n".utf8))
        exit(1)
    }
}

func unpackBaseCommand(_ argv: [String]) async -> Int32 {
    var flags: [String: String] = [:]
    var rest = argv[...]
    while let flag = rest.popFirst(), let value = rest.popFirst() { flags[flag] = value }
    guard let blob = flags["--blob"], let out = flags["--out"], let seed = flags["--seed"], flags.count == 3 else {
        emit(.error(code: "internal", message: "unpack-base requires --blob BLOB --out DIR --seed SEED"))
        return 1
    }
    let staging = URL(fileURLWithPath: out)
    do {
        emit(.begin(steps: 2))
        emit(.step(index: 1, name: "Unpacking"))
        try PreparedBase.unpack(URL(fileURLWithPath: blob), into: staging) { fraction in
            try Task.checkCancellation()
            emit(.progress(fraction))
        }
        emit(.step(index: 2, name: "Writing the identity"))
        try PreparedBase.reseed(staging, seed: seed)
        emit(.done(lock: "device.lock.json"))
        return 0
    } catch {
        if Task.isCancelled { return 143 }
        FirmwareDiagnostics.write(Data("firmwarekit: \(error)\n".utf8))
        emit(Preparer.errorEvent(error))
        return 1
    }
}
