import Foundation
// --single with `media` (tests/sessions/check-media-native.py --single): files through the app's own import, as a drop
// runs it (MediaSupport's gate, PreparedMedia, MediaImport: AFC staging, then itmedia/itphoto through the guest agent);
// then what the device keeps, read back over AFC into work/<board>/media-afc/ with the Files browser's code; then Music
// opened through the agent, `mediaTaps` (normalized panel points, 3 s apart) to reach and start the song, screenshots
// after each, and two more 6 s apart while it plays. The judging is the caller's.

@MainActor func mediaRoundTrip(_ d: Device, _ s: SingleConfig, firmware: MediaSupport.Firmware, packaged: Bool) async {
    let agent = GuestAgent(link: d.process.link, cache: GuestAgentCache())
    let device = MediaImport(services: d.services, guest: GuestServices(agent: agent, packaged: packaged))
    for source in s.media ?? [] {
        var event: [String: Any] = ["device": d.name, "source": source]
        let url = URL(fileURLWithPath: source)
        if let refusal = MediaSupport.refusal(PreparedMedia.destination(forExtension: url.pathExtension), on: firmware) {
            event["refused"] = refusal   // the app's row says this and runs nothing
            emit("media", event)
            continue
        }
        do {
            let media = try await PreparedMedia.prepare(url, profile: d.profile)
            defer { try? FileManager.default.removeItem(at: media.directory) }
            event["destination"] = media.destination
            try await device.stage(media) { _ in }
            try await device.commit(media)
            event["ok"] = true
        } catch {
            event["ok"] = false
            event["error"] = "\(error)"
        }
        emit("media", event)
    }
    // The 3.x/4.x library (iTunes Library.itlp) or 5.x's (MediaLibrary.sqlitedb), with their artwork caches.
    let afc = d.dir.appendingPathComponent("media-afc")
    try? FileManager.default.createDirectory(at: afc, withIntermediateDirectories: true)
    var copied: [String] = []
    // The library's own processes may still be writing (AFC refuses a file that changed while it was read): the
    // folder is listed and read again, up to five times, 3 s apart.
    for folder in ["iTunes_Control/iTunes/iTunes Library.itlp", "iTunes_Control/iTunes", "Purchases/MobileArtworkDB",
                   "iTunes_Control/Artwork", "iTunes_Control/iTunes/Artwork", "iTunes_Control/Artwork/Originals", "DCIM/100APPLE", "LightTouch"] {
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
            let files: [DeviceFile]
            do { files = try await d.services.files(in: folder) }
            catch { break }   // not on this firmware (AFC: object not found)
            var missed = false
            for file in files where file.isRegular && file.size < 64 << 20 {
                let name = folder.replacingOccurrences(of: "/", with: "_") + "__" + file.name
                guard !copied.contains(name) else { continue }
                do { try await d.services.download(file, to: afc.appendingPathComponent(name)) { _ in }; copied.append(name) }
                catch { missed = true; emit("mediaReadbackError", ["device": d.name, "file": "\(folder)/\(file.name)", "error": "\(error)"]) }
            }
            if !missed { break }
        }
    }
    emit("mediaReadback", ["device": d.name, "dir": afc.path, "files": copied])
    guard s.mediaTaps != nil else { return }
    var event: [String: Any] = ["device": d.name]
    // The iPod app is com.apple.mobileipod until the iPad's 5.x Music (com.apple.Music).
    for bundle in ["com.apple.mobileipod", "com.apple.Music"] {
        do { try await agent.launch(bundle); event["launched"] = bundle; break } catch { event["launchError"] = "\(error)" }
    }
    try? await Task.sleep(for: .seconds(8))
    event["frontmost"] = (try? await agent.frontmost().bundleID) ?? ""
    await d.wakeForShot("music-open")
    for (i, point) in (s.mediaTaps ?? []).enumerated() where point.count >= 2 {
        await d.tap(point[0], point[1])
        try? await Task.sleep(for: .seconds(3))
        d.screenshot("music-tap\(i + 1)")
    }
    try? await Task.sleep(for: .seconds(3))
    d.screenshot("music-playing1")
    try? await Task.sleep(for: .seconds(6))
    d.screenshot("music-playing2")
    event["frontmostAfter"] = (try? await agent.frontmost().bundleID) ?? ""
    emit("music", event)
}
