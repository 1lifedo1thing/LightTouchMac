import FirmwareKit
import Foundation

func cacheCommand(_ argv: [String]) -> Never {
    do {
        guard argv.count == 2 || argv.count == 4, argv[0] == "--root",
              argv.count == 2 || argv[2] == "--ipsw" else {
            throw FirmwareError(.internal, "cache-prune requires --root DIR [--ipsw SHA1]")
        }
        try FirmwareCache.prune(root: URL(fileURLWithPath: argv[1]), ipsw: argv.count == 4 ? argv[3] : nil)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("firmwarekit cache-prune: \(error)\n".utf8)); exit(1)
    }
}

/// `firmwarekit detach-images --root DIR`: the app's launch sweep of Preparing/.
@concurrent func detachImagesCommand(_ argv: [String]) async -> Int32 {
    guard argv.count == 2, argv[0] == "--root" else {
        FileHandle.standardError.write(Data("firmwarekit detach-images requires --root DIR\n".utf8)); return 64
    }
    do { try await DiskImage.detachAll(under: URL(fileURLWithPath: argv[1])); return 0 }
    catch { FileHandle.standardError.write(Data("firmwarekit detach-images: \(error)\n".utf8)); return 1 }
}
