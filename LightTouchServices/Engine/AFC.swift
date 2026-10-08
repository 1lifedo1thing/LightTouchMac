// AFC in the services helper: free space, the chunked upload behind installs and media (/PublicStaging,
// /LightTouch), the startup sweep of orphaned uploads, and the Files browser's
// listing and export — all through DeviceServices' run kernel.

import Foundation
import HostServiceWire

extension IMobileDevice {
    /// AFC through lockdown's StartService, each step's error kept (IMobileDevice.startService).
    nonisolated static func startAFC(device: OpaquePointer) throws -> OpaquePointer {
        try startService(
            "com.apple.afc",
            device: device,
            newClient: { afc_client_new($0, $1, $2) },
            freeClient: { afc_client_free($0) }
        ) { DeviceError.afc(.init(code: $0)) }
    }
}

extension DeviceServices {
    // MARK: - Free space

    /// Bytes free on the media partition, via AFC. The pre-flight that names a
    /// full device before installd fails opaquely with PackageExtractionFailed.
    func freeSpaceBytes() async throws -> Int64 {
        try await run(Timeouts.query, "free space") { device in
            let client = try IMobileDevice.startAFC(device: device)
            defer { _ = afc_client_free(client) }
            var value: UnsafeMutablePointer<CChar>?
            let fr = afc_get_device_info_key(client, "FSFreeBytes", &value)
            guard fr.ok, let value else { throw DeviceError.afc(.init(code: fr.code)) }
            defer { free(value) }
            return Int64(String(cString: value)) ?? 0
        }
    }

    // MARK: - Stage (AFC upload into /PublicStaging)

    /// Upload the .ipa into PublicStaging and return its device-relative path, which is what instproxy_install wants.
    func stage(_ ipa: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await stageFile(ipa, remote: "PublicStaging/\(Self.stagingName(ipa))", progress: progress)
    }

    /// Callers supply a validated relative destination. The same chunked AFC
    /// upload, cancellation and incomplete-file cleanup serve apps and songs.
    func stageFile(
        _ ipa: URL,
        remote: String,
        reuseIdentical: Bool = false,
        allowEmpty: Bool = false,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        try await run(Timeouts.stage, "upload") { device in
            // File I/O stays on the detached worker, including opening the file.
            let input = try FileHandle(forReadingFrom: ipa)
            defer { try? input.close() }
            let total = try input.seekToEnd()
            try input.seek(toOffset: 0)
            guard total > 0 || allowEmpty else { throw DeviceError.preflight("The file is empty.") }
            let client = try IMobileDevice.startAFC(device: device)
            defer { _ = afc_client_free(client) }
            if reuseIdentical {
                var existing: UInt64 = 0
                let result = afc_file_open(client, remote, AFC_FOPEN_RDONLY, &existing)
                if result.ok {
                    defer { _ = afc_file_close(client, existing) }
                    var buffer = [CChar](repeating: 0, count: 65536)
                    while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
                        var offset = 0
                        while offset < chunk.count {
                            try Task.checkCancellation()
                            var count: UInt32 = 0
                            let rc = afc_file_read(client, existing, &buffer, UInt32(chunk.count - offset), &count)
                            guard rc.ok, count > 0, count <= chunk.count - offset,
                                Data(bytes: buffer, count: Int(count))
                                    == chunk.subdata(in: offset..<(offset + Int(count)))
                            else {
                                throw DeviceError.preflight(
                                    "An existing media file differs from this import. It was kept unchanged."
                                )
                            }
                            offset += Int(count)
                        }
                    }
                    var count: UInt32 = 0
                    guard afc_file_read(client, existing, &buffer, 1, &count).ok, count == 0 else {
                        throw DeviceError.preflight(
                            "An existing media file differs from this import. It was kept unchanged."
                        )
                    }
                    progress(1)
                    return remote
                }
                guard result == AFC_E_OBJECT_NOT_FOUND else { throw DeviceError.afc(.init(code: result.code)) }
            }
            // Publish complete media only. Interrupted uploads never truncate a
            // library file or leave a partial file at its content-derived path.
            let destination =
                reuseIdentical ? remote + ".upload-" + Self.stagingSession + "-" + UUID().uuidString : remote
            var parent = ""
            for component in remote.split(separator: "/").dropLast() {
                parent = parent.isEmpty ? String(component) : parent + "/" + component
                _ = afc_make_directory(client, parent)
            }
            var handle: UInt64 = 0
            let opened = afc_file_open(client, destination, AFC_FOPEN_WRONLY, &handle)
            guard opened.ok else { throw DeviceError.afc(.init(code: opened.code)) }
            var closed = false
            var complete = false
            defer {
                if !closed { _ = afc_file_close(client, handle) }
                if !complete { _ = afc_remove_path(client, destination) }
            }
            var written: UInt64 = 0
            while written < total {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: Int(min(1 << 16, total - written))),
                    !chunk.isEmpty
                else { throw DeviceError.preflight("The file changed during upload.") }
                try chunk.withUnsafeBytes { raw in
                    let base = raw.bindMemory(to: CChar.self).baseAddress!
                    var offset = 0
                    while offset < raw.count {
                        try Task.checkCancellation()
                        var count: UInt32 = 0
                        let rc = afc_file_write(client, handle, base + offset, UInt32(raw.count - offset), &count)
                        guard rc.ok, count > 0, count <= raw.count - offset else {
                            throw DeviceError.upload(.init(code: rc.ok ? 1 : rc.code), written: written, total: total)
                        }
                        offset += Int(count)
                        written += UInt64(count)
                    }
                }
                progress(Double(written) / Double(total))
            }
            let result = afc_file_close(client, handle)
            closed = true
            guard result.ok else { throw DeviceError.upload(.init(code: result.code), written: written, total: total) }
            try Task.checkCancellation()
            if reuseIdentical {
                let renamed = afc_rename_path(client, destination, remote)
                guard renamed.ok else { throw DeviceError.afc(.init(code: renamed.code)) }
            }
            complete = true
            progress(1)
            return remote
        }
    }

    func sweepStaging() async {
        _ = try? await run(Timeouts.query, "staging sweep") { device in
            guard let client = try? IMobileDevice.startAFC(device: device) else { return }
            defer { _ = afc_client_free(client) }

            func entries(_ path: String) -> [String] {
                var list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                guard afc_read_directory(client, path, &list).ok, let list else { return [] }
                defer { _ = afc_dictionary_free(list) }
                var names: [String] = []
                var i = 0
                while let entry = list[i] {
                    names.append(String(cString: entry))
                    i += 1
                }
                return names
            }
            for name in entries("PublicStaging") {
                try Task.checkCancellation()
                guard Self.isOrphanedStagingName(name) else { continue }
                logEvent("device: removing orphaned staging upload \(name)")
                _ = afc_remove_path(client, "PublicStaging/\(name)")
            }
            for directory in entries("LightTouch") where UUID(uuidString: directory) != nil {
                try Task.checkCancellation()
                for name in entries("LightTouch/\(directory)") {
                    try Task.checkCancellation()
                    guard Self.isOrphanedMediaUpload(name) else { continue }
                    _ = afc_remove_path(client, "LightTouch/\(directory)/\(name)")
                }
            }
        }
    }

    /// Best-effort cleanup of a staged upload.
    func removeStaged(_ path: String) async {
        _ = try? await run(Timeouts.query, "cleanup") { device in
            guard let client = try? IMobileDevice.startAFC(device: device) else { return }
            defer { _ = afc_client_free(client) }
            _ = afc_remove_path(client, path)
        }
    }
}

extension DeviceServices {
    func files(in path: String) async throws -> [DeviceFile] {
        try Self.validateFilePath(path)
        return try await run(Timeouts.browse, "browse files") { device in
            let client = try IMobileDevice.startAFC(device: device)
            defer { _ = afc_client_free(client) }
            var names: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
            let result = afc_read_directory(client, path.isEmpty ? "/" : path, &names)
            guard result.ok, let names else { throw DeviceError.afc(.init(code: result.code)) }
            defer { _ = afc_dictionary_free(names) }
            var entries: [DeviceFile] = []
            var i = 0
            while let raw = names[i] {
                try Task.checkCancellation()
                i += 1
                let name = String(cString: raw)
                if name == "." || name == ".." { continue }
                guard !name.isEmpty, !name.contains("/") else {
                    throw DeviceError.preflight("The device returned an invalid filename.")
                }
                let child = path.isEmpty ? name : path + "/" + name
                var values: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                let rc = afc_get_file_info(client, child, &values)
                guard rc.ok, let values else { throw DeviceError.afc(.init(code: rc.code)) }
                defer { _ = afc_dictionary_free(values) }
                var metadata: [String: String] = [:]
                var j = 0
                while let key = values[j] {
                    guard let value = values[j + 1] else {
                        throw DeviceError.preflight("The device returned incomplete file information.")
                    }
                    metadata[String(cString: key)] = String(cString: value)
                    j += 2
                }
                entries.append(
                    DeviceFile(
                        name: name,
                        path: child,
                        isDirectory: metadata["st_ifmt"] == "S_IFDIR",
                        isRegular: metadata["st_ifmt"] == "S_IFREG",
                        size: UInt64(metadata["st_size"] ?? "") ?? 0
                    )
                )
            }
            return entries.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    /// Save to a private adjacent file, then publish only a completed transfer.
    func download(
        _ file: DeviceFile,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Self.validateFilePath(file.path)
        guard file.isRegular, !file.path.isEmpty else {
            throw DeviceError.preflight("Select a regular file to export.")
        }
        return try await run(Timeouts.stage, "export file") { device in
            let client = try IMobileDevice.startAFC(device: device)
            defer { _ = afc_client_free(client) }
            var handle: UInt64 = 0
            let opened = afc_file_open(client, file.path, AFC_FOPEN_RDONLY, &handle)
            guard opened.ok else { throw DeviceError.afc(.init(code: opened.code)) }
            defer { _ = afc_file_close(client, handle) }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(
                ".LightTouch-" + UUID().uuidString
            )
            let fd = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer {
                try? output.close()
                try? FileManager.default.removeItem(at: temporary)
            }
            var buffer = [CChar](repeating: 0, count: 65536)
            var received: UInt64 = 0
            while true {
                try Task.checkCancellation()
                var count: UInt32 = 0
                let rc = afc_file_read(client, handle, &buffer, UInt32(buffer.count), &count)
                guard rc.ok, count <= buffer.count else {
                    throw DeviceError.afc(.init(code: rc.ok ? 1 : rc.code))
                }
                if count == 0 { break }
                guard UInt64(count) <= file.size - min(received, file.size) else {
                    throw DeviceError.preflight("The file changed. Refresh Files and try again.")
                }
                try output.write(contentsOf: Data(bytes: buffer, count: Int(count)))
                received += UInt64(count)
                progress(file.size == 0 ? 1 : Double(received) / Double(file.size))
            }
            guard received == file.size else {
                throw DeviceError.preflight("The file changed. Refresh Files and try again.")
            }
            try output.synchronize()
            try output.close()
            try Task.checkCancellation()
            let result = temporary.path.withCString { from in
                destination.path.withCString { to in Darwin.rename(from, to) }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            progress(1)
        }
    }
}
