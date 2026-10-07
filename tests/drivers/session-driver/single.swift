import DeviceRuntime
import HostRuntime
// One prepared device (tests/sessions/check-sessions.py --single, scripts/verify-archive, tests/matrix.py): a firmwarekit
// base booted as the app boots it, through the bundled helper, dylib and usbmuxd. It must light, answer lockdown
// over its own usbmuxd, take AFC round trips past 16 KiB (max-packet multiples, whose transfers end in a real ZLP),
// take an IPA, and shut down cleanly. No restore is involved. Screenshots of each stage land in the work directory.
//
// With `itpack` (an iPod) or the config's ipadItpack (an iPad) the boot carries the app's guest-package offer and
// the loader's report is recorded; `reboot` adds a second boot on the same overlay that must light, answer
// lockdown and still hold a file uploaded before the clean shutdown (tests/matrix.py's persist check).

import Foundation
import Vision
import ImageIO

struct SingleConfig: Decodable {
    var board: String   // "ipod" | "ipad" | "ipod1g" | "iphone2g" | "ipod4g" | "iphone4" | "ipod3g" | "iphone3gs"
    var base: String
    /// AFC upload + download sizes; 16384 and 65536 are 512-byte multiples (a ZLP ends each transfer).
    var afcBytes: [Int]?
    /// An iPod's armv6.itpack: the boot carries the app's composed offer (an iPad's comes from ipadItpack).
    var itpack: String?
    /// A second boot on the same overlay after the clean shutdown, with the persist check.
    var reboot: Bool?
    /// With reboot: boot 1 ends at its home check with the app's Stop (a hard halt, no guest shutdown) instead of
    /// AFC, the install and the clean shutdown; boot 2 must light, answer lockdown and reach home (smoke #70: the
    /// 1.x FTL comes back from that Stop through _FTLRestore). No persist marker: a hard halt may lose it.
    var hardStop: Bool?
    /// smoke.md #5: this many boots, each starting AFC at lockdown's first answer, then the app's Stop.
    var raceBoots: Int?
    var raceDirty: Bool?
    /// The bundled lockdown-tz: set the zone and the Mac's clock once lockdown answers, as the app does on every
    /// connect (EmulatorController.syncTimeZoneWhenReady). Also completes the first-host handshake,
    /// independently of the clock, as EmulatorController.checkActivationIfNeeded does.
    var lockdownTZ: String?
    /// With lockdownTZ: the region and clock format to set beside the zone (the app sends the Mac's, ClockRegion.mac).
    struct Region: Decodable { var locale: String; var uses24HourClock: Bool }
    var region: Region?
    /// With reboot: boot 2 asks for this zone instead of the Mac's (the Mac's zone changed between boots).
    var secondZone: String?
    /// false: skip the IPA install (the entry has no AppSync, so the stock installd refuses it).
    var install: Bool?
    /// Qualify the shared host gesture using generic virtual-time input; never GUI Stop.
    var hostPowerGesture: Bool?
    /// Default migration is limited to the measured N72/5F138 shutdown gate.
    /// Explicit true/false remains available for qualification and comparison.
    func prefersHostPowerGesture(build: String?) -> Bool {
        hostPowerGesture ?? (board == "ipod" && build == "5F138")
    }
    /// After installation, launch through the app's guest agent where available. An unfitted helper set falls
    /// back to Home-screen reorder and a tap; screenshots alone do not prove the requested foreground identity.
    var launch: Bool?
    /// Where the icon is (normalized), for firmware without a usable host Home-screen reorder service: the reorder
    /// is skipped, and a tap on the first-install "Edit Home Screen" tip's Dismiss goes first.
    var launchAt: [Double]?
    /// A launch goes through the guest agent where the bake installed it (as the app's sidebar launches); then a tap at this
    /// normalized point (the iPad's panel: portrait top is x 0, portrait left is y 1; the iPod's portrait screen) and
    /// screenshots tapped1-2, 3 s apart. tests/matrix.py --gl-tap opens the Harness's "GL: rotating triangle" with it.
    var tapAfterLaunch: [Double]?
    /// The same bundle id at a newer version, installed over the first (issue #22): it must install as an upgrade,
    /// keeping a file written into the app's data before it (judged through the agent). installd may move the data
    /// to a fresh container UUID; the data is what an upgrade keeps.
    var upgradeIPA: String?
    /// Files through the app's media import after the install, then read back and played (media.swift).
    var media: [String]?
    /// The itmedia/itphoto MediaImport uploads.
    var mediaTools: String?
    /// After the imports, Music is opened and these normalized points tapped (media.swift); nil skips Music.
    var mediaTaps: [[Double]]?
    /// The guest's audio to this WAV instead of none (a playback check); never the Mac's speakers.
    var audioWAV: String?
    /// A file the guest agent reads back at home (fileRead), e.g. a marker a stopped edit wrote into the root FS.
    var readFile: String?
}

@MainActor func runSingle(_ s: SingleConfig) async {
    let ipad = s.board == "ipad"
    // The S5L8900 boards (the 1G and the original iPhone) share the 1.x paths; boardID is FirmwareKit's.
    let (profile, boardID): (Board, String) = switch s.board {
    case "ipad": (.k48, "k48ap")
    case "ipod1g": (.n45, "n45ap")
    case "iphone2g": (.m68, "m68ap")
    case "ipod4g": (.n81, "n81ap")
    case "iphone4": (.n90, "n90ap")
    case "ipod3g": (.n18, "n18ap")
    case "iphone3gs": (.n88, "n88ap")
    default: (.n72, "n72ap")
    }
    // The A4 and S5L8920 boards boot as the iPad does (kboot, the armv7 offer from ipadItpack); input, wake and
    // power-off stay the phone's.
    let a4 = profile.isKBoot
    let d = Device(name: s.board, profile: profile)
    let b = URL(fileURLWithPath: s.base)
    if s.board == "ipod" || (a4 && !ipad) { d.preparedBase = b }
    if !a4 {
        let iBoot: String
        do { iBoot = try BootRecipe.iPodIBoot(base: b) }
        catch { fail("boot lock: \(error)") }
        d.ipod = .init(nand: b.appendingPathComponent("nand").path, nor: b.appendingPathComponent("nor.bin").path,
                       iBoot: iBoot, gidBlobs: b.appendingPathComponent("gid-blobs.bin").path,
                       machine: (try? DeviceLock.read(base: b))??.machineOptions(base: b) ?? [:])
    }
    // Composed per boot from the device's verdicts, as the app's composeGuestOffer (an iPad's in Device.boot);
    // `offered`: this boot carries one (compose gives none for a stub seed).
    var offered = a4 && config.ipadItpack != nil
    func offer() -> String? {
        guard !a4, let itpack = s.itpack else { return nil }
        do {
            let dir = try d.offer(base: b, board: boardID, itpack: itpack)
            offered = dir != nil
            return dir
        } catch { emit("offerError", ["error": "\(error)"]); offered = false; return nil }
    }
    // The lock says whether the bake installed it_agent, including a fitted legacy build.
    let lock = (try? DeviceLock.read(base: b)) ?? nil
    let identity = (try? JSONSerialization.jsonObject(with: Data(contentsOf: b.appendingPathComponent("identity.json")))) as? [String: Any]
    // 7.x boots, pairs and walks Setup far slower (qemu-ios e7ec3ded6a: about 1400 s of QEMU for app-install).
    let slow = Double((lock?.productVersion ?? "").split(separator: ".").first ?? "").map { $0 >= 7 ? 2.5 : 1 } ?? 1
    let lockAgent = lock?.guestPackage?["jobs"]?.strings?.contains("com.qemu.it-agent.plist") ?? false
    let agent = d.profile.hasGuestTools && (lock?.derived?["guest_tools"]?.string?.hasPrefix("installed") ?? true)
    // 2.x reboot(RB_HALT) unmounts then halts the CPU without writing PMU standby.
    // Its stock power sheet does power off, even when a legacy agent is installed.
    let agentCanPowerOff = agent && ((lock?.productVersion ?? "3.1")
        .compare("3.1", options: .numeric) != .orderedAscending)

    func boot(_ generation: Int) async {
        do { try d.boot(generation: generation, guestPackage: offer()) } catch { fail("boot \(generation): \(error)") }
        await waitLit(d, ipad ? 0.2 : 0.03, d.profile.bootBudget * slow)   // the app's own boot budget (iPad 300 s)
        await waitUSB(d, expecting: d.profile.productType, 300 * slow)
        if let tool = s.lockdownTZ {
            var completed = false, lastError = ""
            for attempt in 0..<3 where !completed {
                if attempt > 0 { try? await Task.sleep(for: .seconds(10)) }
                do {
                    try await DeviceServices.finishActivation(tool: tool, socket: d.mux.clientSocket)
                    completed = true
                } catch { lastError = error.localizedDescription }
            }
            emit("activationCompleted", ["device": d.name, "generation": generation, "ok": completed,
                                         "error": completed ? "" : lastError])
            var zone: String?
            // with the agent where the boot has one, as the app's (EmulatorController.guest): a zone 4.x kept is retried after it
            let guest = agent || (a4 && offered)
                ? GuestServices(agent: GuestAgent(link: d.process.link, cache: GuestAgentCache()), packaged: offered) : nil
            let want = generation == 2 ? s.secondZone ?? TimeZone.current.identifier : TimeZone.current.identifier
            for _ in 0..<12 where zone == nil {   // services come up after lockdown answers; the app retries every 5 s
                do { zone = try await DeviceServices.setTimeZone(want, keepClock: d.ipod?.machine["rtc-epoch"] != nil,
                                                                tool: tool, socket: d.mux.clientSocket, guest: guest,
                                                                region: s.region.map { ClockRegion(locale: $0.locale, uses24HourClock: $0.uses24HourClock) }) }
                catch DeviceToolsError.zoneKept(let kept) { emit("timezoneKept", ["device": d.name, "generation": generation, "zone": kept]); break }
                catch {}
                if zone == nil { try? await Task.sleep(for: .seconds(5)) }
            }
            emit("timezone", ["device": d.name, "generation": generation, "zone": zone ?? "", "want": want])
            if s.region != nil {
                // What lockdown holds now, and the screen it shows.
                func info(_ args: [String]) -> String { lockdownInfo(d.mux.clientSocket, args) }
                try? await Task.sleep(for: .seconds(10))
                d.process.link.send(.button(0, down: true)); try? await Task.sleep(for: .milliseconds(150))
                d.process.link.send(.button(0, down: false))
                try? await Task.sleep(for: .seconds(2))
                // The lock screen's clock as read off the screen (lockdown's Uses24HourClock reads back its old value on
                // 4.x even when the clock has changed), beside the Mac's time in both formats.
                let shot = d.screenshot("clock-\(generation)") ?? ""
                var lines: [String] = []
                if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: shot) as CFURL, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    let request = VNRecognizeTextRequest()
                    request.usesLanguageCorrection = false
                    try? VNImageRequestHandler(cgImage: image).perform([request])
                    lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                }
                let now = Date(), format = DateFormatter()
                format.timeZone = .current
                format.dateFormat = "H:mm"; let h24 = format.string(from: now)
                format.dateFormat = "h:mm"; let h12 = format.string(from: now)
                emit("region", ["device": d.name, "generation": generation,
                                "locale": info(["-q", "com.apple.international", "-k", "Locale"]),
                                "uses24HourClock": info(["-k", "Uses24HourClock"]), "zone": info(["-k", "TimeZone"]),
                                "screenshot": shot, "text": lines, "mac24": h24, "mac12": h12])
            }
        }
        emit("activation", ["device": d.name, "generation": generation, "state": await d.lockdownValue("ActivationState") ?? ""])
        if s.board == "ipod" || ipad, let identity {
            let keys = ipad ? [("WiFiAddress", "wifi-mac")]
                : [("SerialNumber", "serial-number"), ("UniqueDeviceID", "udid"),
                   ("WiFiAddress", "wifi-mac"), ("BluetoothAddress", "bt-mac")]
            let expected = Dictionary(uniqueKeysWithValues: keys.compactMap { key, field in
                (identity[field] as? String).map { (key, $0.lowercased()) }
            })
            let start = Date()
            var values: [String: String] = [:]
            repeat {
                for (key, _) in keys where expected[key] != nil {
                    values[key] = (await d.lockdownValue(key) ?? "").lowercased()
                }
                if values == expected || Date().timeIntervalSince(start) >= 60 { break }
                emit("identityPending", ["device": d.name, "generation": generation, "values": values])
                try? await Task.sleep(for: .seconds(2))
            } while !d.process.isDead
            emit("identity", ["device": d.name, "generation": generation,
                              "want": expected["BluetoothAddress"] ?? "", "bt": values["BluetoothAddress"] ?? "",
                              "expected": expected, "values": values, "matches": !expected.isEmpty && values == expected,
                              "seconds": Date().timeIntervalSince(start)])
        }
        if offered {   // the loader's report: it_boot reports the serial it ran and R_* (GuestPackage.ReportCode)
            let start = Date()
            while d.process.status?.guestPackage == nil, Date().timeIntervalSince(start) < 60 { try? await Task.sleep(for: .seconds(1)) }
            let r = d.process.status?.guestPackage
            emit("guestPackage", ["device": d.name, "generation": generation, "serial": r?.serial ?? -1, "result": r?.result ?? -99])
            // GuestPackageSession's verdict, recorded as the app records it: the next offer carries `verdict good`.
            var record = d.guestRecord
            if let r { record.active = r.serial }
            let judging = ContinuousClock.now
            var healthySince: ContinuousClock.Instant?, verdict: GuestPackage.Verdict?
            while verdict == nil, ContinuousClock.now - judging < .seconds(120), let status = d.process.status, !d.process.isDead {
                if status.uiReady && (!agent || status.agentStatus == 1) { healthySince = healthySince ?? .now } else { healthySince = nil }
                verdict = GuestPackage.verdict(report: status.guestPackage, healthyFor: healthySince.map { .now - $0 } ?? .zero,
                                               elapsed: .now - judging, record: record, restored: false)
                if verdict == nil { try? await Task.sleep(for: .seconds(1)) }
            }
            switch verdict {
            case .good(let serial)?: record.lastGood = serial; record.bad.removeAll { $0 == serial }
            case .bad(let serial)?: if !record.bad.contains(serial) { record.bad.append(serial) }
            default: break
            }
            d.guestRecord = record
            emit("guestVerdict", ["device": d.name, "generation": generation, "verdict": verdict.map { "\($0)" } ?? "none",
                                  "lastGood": record.lastGood ?? -1])
        }
        func home() async {
            d.process.link.send(.button(0, down: true)); try? await Task.sleep(for: .milliseconds(150))
            d.process.link.send(.button(0, down: false))
        }
        if !ipad { await home() }   // wake: the display may have slept while it booted
        try? await Task.sleep(for: .seconds(3))
        // an iPad's lock screen turns the panel off ~10 s after it appears; Home wakes it
        for _ in 0..<3 where ipad && (d.brightness() ?? 1) < 0.05 {
            await home()
            try? await Task.sleep(for: .seconds(2))
        }
        d.screenshot(generation == 1 ? "lock" : "lock\(generation)")
        // A lock whose guest package carries the agent (framecheck's home judge expects its answer) gets the wait
        // even when this run made no offer (no --ipad-itpack): its seed package starts the agent.
        let asks = agent || (a4 && offered) || lockAgent
        let guestAgent = GuestAgent(link: d.process.link, cache: GuestAgentCache())
        if asks { _ = await guestAgent.waitAlive(seconds: 60) }
        await d.slideToUnlock(generation, agent: asks ? guestAgent : nil)
        // A fresh 5.x iPad slides into the Setup Assistant instead of the home screen: walk it as a user would.
        // Ask until the agent answers (under load it comes up after the slide; one unanswered probe skipped the
        // walk on 9B176's first boot and left Setup up through the install and launch).
        var setupFront: (bundleID: String, name: String)?
        if ipad, offered {
            let t0 = Date()
            while setupFront == nil, Date().timeIntervalSince(t0) < d.profile.bootBudget / 2.5 {
                setupFront = try? await GuestAgent(link: d.process.link, cache: GuestAgentCache()).frontmost()
                if setupFront == nil { try? await Task.sleep(for: .seconds(3)) }
            }
        }
        var walkedSetup = false
        if let setupFront, setupFront.bundleID == Setup5.bundleID {
            walkedSetup = true
            let (ok, detail) = await Setup5.walk(d)
            let after = try? await GuestAgent(link: d.process.link, cache: GuestAgentCache()).frontmost().bundleID
            emit("setup", ["device": d.name, "generation": generation, "ok": ok && after != Setup5.bundleID, "detail": detail,
                           "frontmost": after ?? ""])
            try? await Task.sleep(for: .seconds(5))
        }
        // A fresh 6.x phone: Setup's welcome slider (SpringBoard's lock screen) and then purplebuddy's pages.
        // Ask until the agent answers, as the iPad's walk does (n90 6.0.1's first boot, at load 30: no answer at 60 s).
        var phoneFront: (bundleID: String, name: String)?
        if a4, !ipad, asks {
            let t0 = Date()
            while phoneFront == nil, Date().timeIntervalSince(t0) < d.profile.bootBudget / 2.5 {
                phoneFront = try? await guestAgent.frontmost()
                if phoneFront == nil { try? await Task.sleep(for: .seconds(3)) }
            }
        }
        if let front = phoneFront, front.bundleID == Setup5.bundleID || front.name == "Lock Screen" {
            walkedSetup = true
            let (ok, detail) = await SetupPhone.walk(d, agent: guestAgent, generation: generation)
            emit("setup", ["device": d.name, "generation": generation, "ok": ok, "detail": detail])
            try? await Task.sleep(for: .seconds(5))
        }
        // Setup's country page sets the locale (7.x's list starts at Afghanistan: fa_AF, Persian digits); the app
        // applies the Mac's region again once Setup is over (EmulatorController's Setup gate), and so does this.
        if let region = s.region, let tool = s.lockdownTZ, walkedSetup {
            _ = try? await DeviceServices.setTimeZone(TimeZone.current.identifier, keepClock: true, tool: tool,
                                                      socket: d.mux.clientSocket, guest: nil,
                                                      region: ClockRegion(locale: region.locale, uses24HourClock: region.uses24HourClock))
            emit("regionAfterSetup", ["device": d.name, "generation": generation,
                                      "locale": lockdownInfo(d.mux.clientSocket, ["-q", "com.apple.international", "-k", "Locale"])])
        }
        let hp = await d.wakeForShot(generation == 1 ? "home" : "home\(generation)")
        // Judge the home screen, not just a lit boot: the panel sleeps ~12 s after `lit` (audit
        // finding 3), so a later shot lands black. wakeForShot woke it; report the frontmost app
        // (SpringBoard where an agent can say) and the brightness so the matrix fails a slept/black
        // or wrong-app home instead of passing it on the single `lit` threshold (audit gap #2).
        // The iPad's agent comes from the seed package (offered). `screen` is the agent's name for what is up
        // (`Home Screen`, `Lock Screen`, an app's name): the lock screen is SpringBoard too, so the bundle id
        // alone cannot tell it from home. Without a fitted/offered agent, the matrix reports unknown.
        var front = "", screen = ""
        if asks, let f = try? await guestAgent.frontmost() { (front, screen) = f }
        emit("home", ["device": d.name, "generation": generation, "brightness": d.brightness() ?? -1,
                      "agent": asks, "frontmost": front, "screen": screen, "path": hp ?? ""])
        if let path = s.readFile {
            let data = asks ? try? await guestAgent.get(path) : nil
            emit("fileRead", ["device": d.name, "generation": generation, "path": path, "agent": asks,
                              "found": data != nil, "content": data.map { String(decoding: $0, as: UTF8.self) } ?? ""])
        }
    }

    /// Test-only clean shutdown: stock gesture or qualified agent halt, confirmed by PMU.
    /// GUI Stop is a separate hard halt and does not establish guest unmount.
    func shutdown(_ generation: Int) async {
        let quit = Date()
        if s.prefersHostPowerGesture(build: lock?.build) && !ipad {
            do {
                try await HostInputAutomation.shutdown(d.process, firstGeneration: profile == .n45)
                emit("hostPowerGesture", ["device": d.name, "generation": generation, "confirmed": d.process.status?.shutdownConfirmed == true])
            } catch {
                emit("hostPowerGesture", ["device": d.name, "generation": generation, "error": "\(error)"])
            }
        }
        else if ipad { d.process.link.send(.machine(.powerdown)) }
        // The A4/S5L8920 phones: the agent their offer carries (the machine's hold-and-slide is the iPad's, and on
        // the iPod touch 4G it confirmed in 45 s once and not at all the next boot).
        else if agentCanPowerOff || (a4 && offered) { _ = try? await d.process.link.request(.agent(request: "\(UUID().uuidString) halt \n", deadline: 0), timeout: 5) }
        else {   // the machine's own hold-power-and-slide sequence
            d.process.link.send(.machine(.powerdown))
        }
        var confirmed = -1.0, shots = ipad ? [7.0, 12.0] : []   // the iPad gesture's power-off sheet, then after its drag
        while Date().timeIntervalSince(quit) < 50 {
            if d.process.status?.shutdownConfirmed == true { confirmed = Date().timeIntervalSince(quit); break }
            if let s = shots.first, Date().timeIntervalSince(quit) >= s {
                shots.removeFirst()
                d.screenshot("powerdown\(generation)-\(Int(s))s")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        d.process.terminate()
        let exited = await d.process.waitForExit(timeout: 30)
        emit("quit", ["device": d.name, "generation": generation, "confirmed": confirmed, "exited": exited, "reason": d.process.deathReason ?? ""])
        await d.services.stopWorker()
        d.mux.stop()
    }

    // smoke.md #5: AFC (the app's listing: StartService, connect, stat of each entry) at lockdown's first
    // answer, polled at 100 ms from power-on; then the app's Stop. raceDirty first installs, uploads a file and
    // starts the agent halt, stopping 20-45 s into the shutdown (the sequence that preceded the one code 1).
    if let n = s.raceBoots {
        for g in 1...n {
            do { try d.boot(generation: g, guestPackage: offer()) } catch { fail("boot \(g): \(error)") }
            let start = Date()
            while await d.productType() == nil {
                if d.process.isDead || Date().timeIntervalSince(start) > 300 { fail("boot \(g): lockdown never answered") }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let answered = Date()
            var race: [String: Any] = ["device": d.name, "generation": g, "lockdown": answered.timeIntervalSince(start)]
            do { race["entries"] = try await d.services.files(in: "").count } catch { race["error"] = "\(error)" }
            race["seconds"] = Date().timeIntervalSince(answered)
            emit("race", race)
            if s.raceDirty == true {
                await install(d)
                let local = d.dir.appendingPathComponent("race-\(g).bin")
                try? Data(count: 65_536).write(to: local)
                var stop: [String: Any] = ["device": d.name, "generation": g]
                do { try await d.services.uploadFile(local, into: "") { _ in } } catch { stop["uploadError"] = "\(error)" }
                _ = try? await d.process.link.request(.agent(request: "\(UUID().uuidString) halt \n", deadline: 0), timeout: 5)
                let wait = [20.0, 25, 30, 35, 40, 45][g % 6]
                try? await Task.sleep(for: .seconds(wait))
                stop["afterHalt"] = wait
                stop["confirmed"] = d.process.status?.shutdownConfirmed == true
                emit("raceStop", stop)
            }
            d.process.terminate()
            _ = await d.process.waitForExit(timeout: 30)
            await d.services.stopWorker()
        d.mux.stop()
            d.serial?.removeEndpoints()
        }
        d.serial?.finish()
        emit("done")
        exit(0)
    }

    await boot(1)

    if s.reboot == true, s.hardStop == true {
        d.process.terminate()   // the app's Stop: pause, flush the overlay, quit QEMU at once
        let exited = await d.process.waitForExit(timeout: 30)
        emit("quit", ["device": d.name, "generation": 1, "hard": true, "exited": exited, "reason": d.process.deathReason ?? ""])
        d.mux.stop()
        d.serial?.removeEndpoints()
        await boot(2)
        await shutdown(2)
        d.serial?.finish()
        emit("done")
        exit(0)
    }

    for size in s.afcBytes ?? [16384, 16385, 65536, 1_048_583] {
        let name = "ltm-verify-\(size).bin"
        let local = d.dir.appendingPathComponent(name), back = d.dir.appendingPathComponent("back-" + name)
        var bytes = [UInt8](repeating: 0, count: size)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 13) }
        let start = Date()
        do {
            try Data(bytes).write(to: local)
            try await d.services.uploadFile(local, into: "") { _ in }
            guard let file = try await d.services.files(in: "").first(where: { $0.name == name }) else { throw DeviceError.preflight("\(name) not listed") }
            try await d.services.download(file, to: back) { _ in }
            let same = try Data(contentsOf: back) == Data(bytes)
            await d.services.removeStaged(name)
            emit("afc", ["device": d.name, "bytes": size, "listed": Int(file.size), "same": same, "seconds": Date().timeIntervalSince(start)])
        } catch {
            emit("afc", ["device": d.name, "bytes": size, "same": false, "error": "\(error)"])
        }
        try? FileManager.default.removeItem(at: local); try? FileManager.default.removeItem(at: back)
    }

    if s.install != false { await install(d) }
    if let upgrade = s.upgradeIPA { await upgradeInPlace(d, upgrade) }
    try? await Task.sleep(for: .seconds(3))
    await d.wakeForShot("installed")   // wake first: the panel may have slept during the install
    // launch() goes through the guest agent wherever it answers (judged on the frontmost app), else taps the icon.
    if s.launch == true { await launch(d, at: s.launchAt, tap: s.tapAfterLaunch) }
    if s.media != nil {
        let version = lock?.productVersion ?? ""
        let firmware = MediaSupport.Firmware(version: version, name: "iOS \(version)",
                                             media: lock?.entry?["content"]?["media"]?.strings ?? [])
        await mediaRoundTrip(d, s, firmware: firmware, packaged: offered)
    }

    // The persist marker: a file that must still be there after the clean shutdown and the second boot.
    let marker = "ltm-matrix-persist.bin"
    let markerBytes = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 11) })
    if s.reboot == true {
        let local = d.dir.appendingPathComponent(marker)
        do {
            try markerBytes.write(to: local)
            try await d.services.uploadFile(local, into: "") { _ in }
        } catch { emit("persist", ["device": d.name, "kept": false, "same": false, "error": "upload: \(error)"]) }
    }

    await shutdown(1)

    if s.reboot == true {
        d.serial?.removeEndpoints()
        await boot(2)
        let back = d.dir.appendingPathComponent("back-" + marker)
        do {
            guard let file = try await d.services.files(in: "").first(where: { $0.name == marker }) else { throw DeviceError.preflight("\(marker) not listed") }
            try await d.services.download(file, to: back) { _ in }
            let same = try Data(contentsOf: back) == markerBytes
            await d.services.removeStaged(marker)
            emit("persist", ["device": d.name, "kept": true, "same": same])
        } catch {
            emit("persist", ["device": d.name, "kept": false, "same": false, "error": "\(error)"])
        }
        let apps = (try? await d.services.installedApps())?.map(\.id) ?? []
        emit("restartedApps", ["device": d.name, "has": apps.contains(config.bundleID)])
        await shutdown(2)
    }
    d.serial?.finish()
    emit("done")
    exit(0)
}


/// iOS 5's Setup Assistant on a fresh iPad, walked as qemu-ios tests/ipad1/regress.py's gles leg walks it (SETUP_5):
/// framebuffer pixels (1024x768, the panel's landscape scan; portrait top is x 0). A tap counts as answered when
/// its box changes, or, for an alert's button, once an alert's navy buttons fill ALERT; only those taps are
/// retried (behind a modal alert a second tap does nothing). When Wi-Fi has not joined by its page, Setup asks
/// "Continue without Wi-Fi?"; 5.1.1 then skips the Apple ID page and 5.0.1 does not, so the walk looks (smoke #39).
@MainActor enum Setup5 {
    static let bundleID = "com.apple.purplebuddy"
    typealias Box = (x0: Int, y0: Int, x1: Int, y1: Int)
    static let title: Box = (20, 150, 65, 620), alert: Box = (548, 255, 605, 515)
    static let wifiContinue = (575, 450)
    static let pages: [(String, [(x: Int, y: Int, hold: Double, box: Box)])] = [
        ("language", [(42, 28, 0.12, title)]),
        ("country", [(470, 400, 0.12, (95, 150, 1000, 620)), (42, 28, 0.12, title)]),
        ("location", [(833, 500, 0.12, (765, 150, 860, 620)), (42, 28, 0.12, alert), (585, 315, 0.12, title)]),
        ("wi-fi", [(42, 28, 0.12, title)]), ("set up", [(42, 28, 0.12, title)]),
        ("apple id", [(981, 385, 0.2, alert), (585, 450, 0.12, title)]),
        ("terms", [(1002, 32, 0.12, alert), (565, 315, 0.12, title)]),
        ("diagnostics", [(242, 500, 0.12, (150, 150, 265, 620)), (42, 28, 0.12, title)]),
        ("thank you", [(870, 385, 0.12, title)]),
    ]

    /// The box's BGRA bytes from the newest frame (nil without a 1024x768 frame).
    static func region(_ d: Device, _ b: Box) -> [UInt8]? {
        guard let s = d.process.link.frontSurface()?.surface, s.width == 1024, s.height == 768 else { return nil }
        s.incrementUseCount(); s.lock(options: .readOnly, seed: nil)
        defer { s.unlock(options: .readOnly, seed: nil); s.decrementUseCount() }
        var out: [UInt8] = []
        for y in b.y0..<b.y1 {
            out += UnsafeRawBufferPointer(start: s.baseAddress + y * s.bytesPerRow + b.x0 * 4, count: (b.x1 - b.x0) * 4)
        }
        return out
    }

    /// An alert is up: over 15% of ALERT's samples navy (blue well above red).
    static func alertUp(_ d: Device) -> Bool {
        guard let px = region(d, alert) else { return false }
        let w = alert.x1 - alert.x0
        var navy = 0, n = 0
        for y in stride(from: 0, to: alert.y1 - alert.y0, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                let i = (y * w + x) * 4, b = Int(px[i]), r = Int(px[i + 2])
                if b > r + 40 && b > 80 { navy += 1 }
                n += 1
            }
        }
        return navy * 100 > 15 * n
    }

    /// A panel that slept during the walk (idle under host load: 9A5288d went dark before the country page) is
    /// woken with Home and slid back into Setup, as the driver's own unlock does; a lit panel is left alone.
    static func wake(_ d: Device) async {
        for _ in 0..<3 where (d.brightness() ?? 1) < 0.05 {
            d.process.link.send(.button(0, down: true)); try? await Task.sleep(for: .milliseconds(150))
            d.process.link.send(.button(0, down: false))
            try? await Task.sleep(for: .seconds(2))
            await d.drag(0.9365, 0.621, 0.9365, 0.0612)
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// The Apple ID page is up: its two white buttons ("Sign In with an Apple ID", "Create a Free Apple ID") fill
    /// the two button columns and the gap between them is dark. Set Up iPad's white list fills the gap too (0.98 white
    /// against the Apple ID page's 0); Terms, Diagnostics and Thank You leave a button column dark.
    static let appleID: [Box] = [(795, 170, 830, 600), (860, 170, 895, 600)], appleIDGap: Box = (840, 170, 852, 600)
    static func whiteFraction(_ d: Device, _ b: Box) -> Double {
        guard let px = region(d, b) else { return 0 }
        var white = 0, n = 0
        for i in stride(from: 0, to: px.count, by: 16) { n += 1; if px[i] > 225 && px[i + 1] > 225 && px[i + 2] > 225 { white += 1 } }
        return n == 0 ? 0 : Double(white) / Double(n)
    }
    static func appleIDUp(_ d: Device) -> Bool { kind(fingerprint(d)) == "apple id" }

    /// A Setup page's fingerprint: the white fraction of seven boxes (the two button columns and the gap between them,
    /// a strip left of the centre art, the iPad outline's left edge, the centre, the left list column), measured on
    /// 5.0 beta 1 to 5.1.1.
    static let printBoxes: [Box] = [(795, 170, 830, 600), (860, 170, 895, 600), (840, 170, 852, 600),
                                    (180, 300, 230, 450), (255, 300, 285, 450), (330, 300, 560, 450), (100, 150, 135, 700)]
    static func fingerprint(_ d: Device) -> [Double] { printBoxes.map { whiteFraction(d, $0) } }

    /// Which kind of Setup page a fingerprint is: "list" (language, country), "location", "wi-fi", "set up",
    /// "apple id", "diagnostics", "thank you"; nil for anything else (Terms, a page mid-transition, a dark panel).
    static func kind(_ f: [Double]) -> String? {
        guard f.count == 7 else { return nil }
        let (b1, b2, gap, left, frame, mid, list) = (f[0], f[1], f[2], f[3], f[4], f[5], f[6])
        if b1 > 0.85, b2 > 0.85, gap < 0.2, frame < 0.1 { return "apple id" }
        if b1 > 0.85, b2 > 0.85, gap > 0.9, left < 0.1, frame > 0.9, mid < 0.1 { return "set up" }
        if b1 > 0.85, gap > 0.7, left > 0.8, frame > 0.9, mid > 0.8 { return "list" }
        if b1 > 0.85, b2 < 0.1, gap > 0.85 { return "location" }
        if b1 < 0.1, b2 < 0.1, left > 0.9, frame > 0.15, frame < 0.45 { return "diagnostics" }
        if b1 < 0.1, b2 < 0.1, left < 0.2, frame < 0.1, mid < 0.1, list > 0.9 { return "diagnostics" }   // 5.0 beta 1
        if b1 < 0.1, b2 > 0.7 { return "thank you" }
        if b1 < 0.1, b2 < 0.1, gap < 0.1, left > 0.15, left < 0.45, frame < 0.1, mid < 0.1 { return "wi-fi" }
        return nil
    }
    /// The page kind each walk step shows (Terms has no fingerprint of its own).
    static func kind(of page: String) -> String? {
        ["language": "list", "country": "list", "location": "location", "wi-fi": "wi-fi", "set up": "set up",
         "apple id": "apple id", "diagnostics": "diagnostics", "thank you": "thank you"][page]
    }

    /// The box once it holds still for a second (a page still sliding in under load).
    static func settled(_ d: Device, _ box: Box, timeout: Double = 20) async -> [UInt8]? {
        var last = region(d, box)
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            try? await Task.sleep(for: .seconds(1))
            let now = region(d, box)
            if now == last { break }
            last = now
        }
        return last
    }

    static func tap(_ d: Device, _ x: Int, _ y: Int, hold: Double = 0.12) async {
        let nx = Double(x) / 1024, ny = Double(y) / 768
        d.process.link.send(.touch(slot: 0, phase: 0, x: nx, y: ny))
        try? await Task.sleep(for: .seconds(hold))
        d.process.link.send(.touch(slot: 0, phase: 2, x: nx, y: ny))
    }

    /// From the first Setup page (the driver has already slid "slide to set up"): (walked, detail).
    /// Taps until `answered` holds on `hold` consecutive one-second polls, or `budget` runs out, tapping again every
    /// `every` seconds while nothing answered. A lost tap (a page still sliding in, a frame the host was too loaded to
    /// deliver) is retried instead of failing the walk; a pressed button's flash (the title bar changes for a moment,
    /// the page stays: 9B176's Set Up Next) is not an answer; a tap that did land is not repeated.
    static func tapUntil(budget: Double, every: Double, hold: Int = 3, tap: () async -> Void, answered: () -> Bool) async -> Bool {
        let t0 = Date()
        var streak = 0
        while Date().timeIntervalSince(t0) < budget {
            await tap()
            let t1 = Date()
            while Date().timeIntervalSince(t1) < every || streak > 0, Date().timeIntervalSince(t0) < budget {
                streak = answered() ? streak + 1 : 0
                if streak >= hold { return true }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return false
    }

    /// tapUntil's contract, with a fake page: a lost tap is retried, a landed tap is not repeated, a page that never
    /// answers gives up once the budget is spent (one tap per `every`).
    static func selfTest() async -> Bool {
        var ok = true
        func expect(_ label: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + label); ok = ok && cond }
        var taps = 0
        var r = await tapUntil(budget: 6, every: 1.5, tap: { taps += 1 }, answered: { taps >= 2 })
        expect("the first tap lost: tapped again, answered", r && taps == 2)
        taps = 0
        r = await tapUntil(budget: 6, every: 1.5, tap: { taps += 1 }, answered: { taps >= 1 })
        expect("a landed tap is not repeated", r && taps == 1)
        taps = 0
        r = await tapUntil(budget: 5, every: 2, tap: { taps += 1 }, answered: { false })
        expect("a page that never answers fails after the budget, one tap per interval", !r && taps == 3)
        taps = 0
        var polls = 0
        r = await tapUntil(budget: 12, every: 3, tap: { taps += 1; polls = 0 }, answered: { polls += 1; return taps >= 2 || polls == 1 })
        expect("a one-poll flash is not an answer: tapped again", r && taps == 2)
        // fingerprints measured off real Setup screenshots (9A5220p, 9A334, 9A405, 9B176, 9B206)
        let measured: [(String?, [Double])] = [
            ("list", [0.97, 0.92, 0.83, 0.92, 1.0, 0.95, 0.8]), ("list", [0.98, 0.92, 0.83, 0.92, 1.0, 0.96, 0.79]),
            ("location", [0.97, 0.0, 0.95, 0.05, 0.0, 0.34, 0.0]), ("wi-fi", [0.0, 0.0, 0.0, 0.28, 0.0, 0.0, 0.75]),
            ("set up", [0.93, 0.92, 0.99, 0.0, 1.0, 0.0, 0.0]), ("set up", [0.94, 0.92, 0.99, 0.0, 1.0, 0.0, 0.0]),
            ("apple id", [0.92, 0.92, 0.0, 0.07, 0.0, 0.09, 0.0]), ("apple id", [0.92, 0.92, 0.0, 0.04, 0.0, 0.1, 0.0]),
            ("diagnostics", [0.0, 0.0, 0.0, 1.0, 0.27, 0.01, 0.0]), ("diagnostics", [0.0, 0.0, 0.0, 1.0, 0.29, 0.0, 0.0]),
            ("diagnostics", [0.0, 0.0, 0.0, 0.12, 0.0, 0.0, 0.95]), ("thank you", [0.0, 0.83, 0.17, 0.05, 0.0, 0.18, 0.0]),
            (nil, [0.0, 0.0, 0.0, 0.0, 0.0, 0.04, 0.0]), (nil, [0.78, 0.69, 0.86, 1.0, 1.0, 0.74, 0.92])]
        for (want, f) in measured { expect("page \(want ?? "unrecognised") from \(f)", kind(f) == want) }
        return ok
    }

    /// From the first Setup page (the driver has already slid "slide to set up"): (walked, detail). Each page is
    /// entered only once its title bar has settled and differs from the page before (the previous Next landed);
    /// each tap is retried inside a per-page budget scaled from the board's boot budget (the iPad's 300 s: 120 s).
    static func walk(_ d: Device) async -> (Bool, String) {
        var walked: [String] = [], lastTitle: [UInt8]? = nil
        let budget = d.profile.bootBudget / 2.5
        var skipTo: Int? = nil
        page: for (index, (name, taps)) in pages.enumerated() {
            if let skipTo, index < skipTo { walked.append("\(name) (absent)"); continue }
            await wake(d)
            if let lastTitle {   // the previous page's Next took: wait for this page's title to replace it
                let t0 = Date()
                while Date().timeIntervalSince(t0) < budget, await settled(d, title) == lastTitle { await wake(d) }
            }
            // The page on screen decides, not the list's order: 5.0 beta 1 opens on Set Up iPad (no language,
            // country, location or Wi-Fi pages), 5.1.1 drops Apple ID after "Continue without Wi-Fi?" and 5.0.1 keeps it.
            // Wait for this step's page, or skip ahead to a later step whose page is showing.
            if let want = kind(of: name) {
                let t0 = Date()
                var seen: String? = nil, unknown = 0
                while Date().timeIntervalSince(t0) < budget {
                    _ = await settled(d, title)
                    seen = kind(fingerprint(d))
                    if seen == want { break }
                    if let seen, let later = pages.indices.first(where: { $0 > index && kind(of: pages[$0].0) == seen }) {
                        walked.append("\(name) (absent)"); skipTo = later; continue page
                    }
                    // Terms has no fingerprint: a lit, settled page nothing recognises, read twice, is it when it is the
                    // next step (5.1.1 goes Wi-Fi -> Terms without Apple ID)
                    unknown = seen == nil && (d.brightness() ?? 0) > 0.05 ? unknown + 1 : 0
                    if unknown >= 2, index + 1 < pages.count, kind(of: pages[index + 1].0) == nil {
                        walked.append("\(name) (absent)"); continue page
                    }
                    await wake(d); try? await Task.sleep(for: .seconds(2))
                }
                guard seen == want else {
                    d.screenshot("setup-\(name.replacingOccurrences(of: " ", with: "-"))-unknown")
                    return (false, "the \(name) page never showed in \(Int(budget)) s (screen: \(seen ?? "unrecognised"); after \(walked.joined(separator: ", ")))")
                }
            }
            if name == "wi-fi" { try? await Task.sleep(for: .seconds(15)) }   // give the join time before Next
            for (i, t) in taps.enumerated() {
                let pageTitle = await settled(d, title)
                let isAlert = t.box == alert
                let ref = isAlert ? nil : await settled(d, t.box)
                // An alert tap is also answered when the page itself moves on: 5.0 beta 1's "Skip this step" goes
                // straight to the next page with no confirmation; the page's remaining (alert) taps are then moot.
                let answered = { isAlert ? alertUp(d) || region(d, title) != pageTitle : region(d, t.box) != ref }
                d.screenshot("setup-\(name.replacingOccurrences(of: " ", with: "-"))-\(i)")
                // A choice the emulator does not care about (Diagnostics' "Don't Send") is best-effort: 5.0 beta 1
                // lays that page out differently, and its Next still has to be taken.
                let optional = name == "diagnostics" && t.box != title
                // behind a modal alert a second tap does nothing, so an alert tap is retried sooner
                let ok = await tapUntil(budget: isAlert || optional ? 60 : budget, every: 20, tap: { await tap(d, t.x, t.y, hold: t.hold) },
                                        answered: answered)
                // Terms' button highlight can look like a page transition. Let
                // it settle before deciding that Agree advanced without an alert.
                if name == "terms", i == 0, ok {
                    try? await Task.sleep(for: .seconds(3))
                    if !alertUp(d), kind(fingerprint(d)) == nil {
                        await tap(d, t.x, t.y, hold: 0.3)
                        try? await Task.sleep(for: .seconds(3))
                    }
                    d.screenshot("terms-retry")
                }
                if isAlert, ok, !alertUp(d) { lastTitle = pageTitle; walked.append(name + " (no alert)"); continue page }
                if !ok, optional { continue }
                // 5.0 beta 5 has no Terms page: its Agree tap (an empty corner elsewhere) raises no alert
                if !ok, name == "terms", i == 0 { walked.append("terms (absent)"); continue page }
                guard ok else { return (false, "the \(name) page did not answer tap \(i + 1) in \(Int(isAlert ? 60 : budget)) s (after \(walked.joined(separator: ", ")))") }
                if t.box == title { lastTitle = pageTitle }
            }
            if name == "wi-fi", alertUp(d) {   // "Continue without Wi-Fi?": no join (the Apple ID page may still follow)
                let ref = await settled(d, title)
                _ = await tapUntil(budget: budget, every: 20, tap: { await tap(d, wifiContinue.0, wifiContinue.1) },
                                   answered: { region(d, title) != ref })
                lastTitle = ref
                walked.append("wi-fi (not joined: continued without)")
            } else {
                walked.append(name)
            }
        }
        return (true, "walked \(walked.joined(separator: ", "))")
    }
}

/// installd's own record of where each app lives (iOS 2-5): the container an upgrade must keep.
/// What lockdown holds (Homebrew's ideviceinfo over the device's usbmuxd).
func lockdownInfo(_ socket: String, _ args: [String]) -> String {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ideviceinfo")
    p.arguments = args
    p.environment = ProcessInfo.processInfo.environment.merging(["USBMUXD_SOCKET_ADDRESS": socket]) { $1 }
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

@MainActor func container(_ agent: GuestAgent, _ id: String) async -> String? {
    guard let data = try? await agent.get("/var/mobile/Library/Caches/com.apple.mobile.installation.plist"),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let app = (plist["User"] as? [String: Any])?[id] as? [String: Any] else { return nil }
    return (app["Container"] as? String) ?? (app["Path"] as? String).map { ($0 as NSString).deletingLastPathComponent }
}

/// Install `ipa` over the installed config.bundleID, as the app's install does (stage + installation_proxy).
@MainActor func upgradeInPlace(_ d: Device, _ ipa: String) async {
    let agent = GuestAgent(link: d.process.link, cache: GuestAgentCache())
    var event: [String: Any] = ["device": d.name]
    let alive = await agent.waitAlive(seconds: 30)
    let before = alive ? await container(agent, config.bundleID) : nil
    let marker = Data("kept across the upgrade\n".utf8)
    var file: String?   // Documents where installd made one (not every version does before a first launch), else Library
    for dir in ["Documents", "Library"] where file == nil {
        guard let before else { break }
        do { try await agent.put("\(before)/\(dir)/ltm-upgrade.txt", mode: 0o644, marker); file = "\(dir)/ltm-upgrade.txt" }
        catch { event["markerError"] = "\(error)" }
    }
    event["marker"] = file ?? ""
    do {
        let staged = try await d.services.stage(URL(fileURLWithPath: ipa)) { _ in }
        try await d.services.install(URL(fileURLWithPath: ipa), staged: staged, bundleID: config.bundleID) { _, _ in }
        await d.services.removeStaged(staged)
        event["error"] = ""
    } catch { event["error"] = "\(error)" }
    let apps = (try? await d.services.installedApps()) ?? []
    event["version"] = apps.first { $0.id == config.bundleID }?.version ?? ""
    let after = alive ? await container(agent, config.bundleID) : nil
    event["before"] = before ?? ""; event["after"] = after ?? ""
    if let after, let file { event["kept"] = (try? await agent.get("\(after)/\(file)")) == marker } else { event["kept"] = false }
    emit("upgraded", event)
}

/// A phone's Setup Assistant (6.x and 7.x on the iPod touch 4G, iPhone 4 and 3GS), walked as qemu-ios
/// tests/ipad1/app-install.py walk_setup does: Vision reads each page's labels off a screenshot; an alert's
/// button labelled exactly as one of `alertYes` goes first, then the first of `picks` the page shows, then its
/// Next (the language page's is an arrow, top right). The welcome page (SpringBoard's "slide to set up", in a
/// rotating language) has none of those and is slid. Done when the agent says the home screen is up.
@MainActor enum SetupPhone {
    static let picks = ["Start Using iPod touch", "Start Using iPod", "Start Using iPhone", "Get Started", "Set Up as New iPod touch",
                        "Set Up as New iPod", "Set Up as New iPhone", "Disable Location Services", "Skip This Step", "Agree",
                        "Don't Add Passcode", "Don't Use iCloud", "Don't Send", "Australia", "United States"]
    static let alertYes = ["OK", "Skip", "Agree", "Continue", "Don't Use", "Don't Add"]
    static let nextArrow = (x: 587.0 / 640, y: 84.0 / 960)

    /// Each label Vision reads on the screenshot, at its centre as a touch point (top-left origin, 0...1).
    static func labels(_ path: String) -> [String: (x: Double, y: Double)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        guard (try? VNImageRequestHandler(url: URL(fileURLWithPath: path)).perform([request])) != nil else { return [:] }
        var found: [String: (x: Double, y: Double)] = [:]
        for o in request.results ?? [] {
            guard let text = o.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) else { continue }
            found[text] = found[text] ?? (o.boundingBox.midX, 1 - o.boundingBox.midY)
        }
        return found
    }

    enum Step: Equatable { case tap(Double, Double, String?), pause(Double), slideIfLockScreen }

    /// One Setup page's taps, from the labels Vision read on it (`pages`: what the walk has tapped so far).
    static func plan(_ found: [String: (x: Double, y: Double)], pages: [String]) -> [Step] {
        // Setup's Home sheet (Emergency Call / Start Over) dims the page, whose labels Vision still reads and whose
        // rows and Next it would tap in vain (n88 6.0.1: 40 pages of English): dismiss it before anything else.
        if let cancel = found["Cancel"], found["Start Over"] != nil {
            return [.tap(cancel.x, cancel.y, "(Cancel)")]
        }
        if let yes = alertYes.first(where: { found[$0] != nil }), let p = found[yes] {
            return [.tap(p.x, p.y, "(\(yes))")]
        }
        var steps: [Step] = []
        var pick = picks.first { found[$0] != nil }
        // The country list without Australia/United States on screen (the 3GS's 480-line panel, 7.x's "Select Your
        // Country or Region" with "MORE COUNTRIES AND REGIONS" over Afghanistan): the first row below the page's
        // last country heading in its top 60 %. Next stays disabled until one is chosen.
        let headings = found.filter { $0.key.localizedCaseInsensitiveContains("countr") && $0.value.y < 0.6 }
        if pick == nil, let below = headings.map({ $0.value.y }).max(),
           let first = found.filter({ $0.value.y > max(below, 0.15) && $0.value.y < 0.9 && !["Next", "Back"].contains($0.key) })
                            .min(by: { $0.value.y < $1.value.y }) {
            pick = first.key
        }
        if let pick, let p = found[pick] {
            // a label tapped again and again: nudge the tap (as walk_setup, the digitizer's edges)
            let again = pages.filter { $0 == pick }.count
            steps.append(.tap(p.x, p.y + [0, -14, 14, -24, 24][again % 5] / 960, pick))
            if pick.hasPrefix("Start Using") || pick == "Get Started" { return steps }
            steps.append(.pause(1.5))
        }
        // The language page: 7.x moves on when its English row is tapped; 6.x needs its arrow after (top right).
        if pick == nil, let english = found["English"] {
            steps += [.tap(english.x, english.y, "English"), .pause(1.5)]
        }
        if let next = found["Next"] ?? (found["English"] != nil ? nextArrow : nil) {
            steps.append(.tap(next.x, next.y, pick == nil ? (found.filter { $0.value.y < 130.0 / 960 && $0.key != "Next" }.keys.first ?? "?") : nil))
        } else if pick == nil {
            steps.append(.slideIfLockScreen)
        }
        return steps
    }

    /// `plan` against label sets read off real Setup screenshots (positions rounded): session-driver --selftest-walk.
    static func selfTest() -> Bool {
        var ok = true
        func expect(_ label: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + label); ok = ok && cond }
        func taps(_ steps: [Step]) -> [String] { steps.compactMap { if case .tap(_, _, let log) = $0 { return log ?? "(next)" }; return nil } }
        // n88ap-10A523 (3GS 6.0.1), fold-9 run 2: the language page with the Home sheet up
        let sheetOnLanguage: [String: (x: Double, y: Double)] = [
            "Test Network": (0.2, 0.02), "9:43 PM": (0.5, 0.02), "English": (0.15, 0.2), "Français": (0.15, 0.29),
            "Deutsch": (0.15, 0.39), "Emergency Call": (0.5, 0.66), "Start Over": (0.5, 0.77), "Cancel": (0.5, 0.91)]
        expect("Home sheet over the language page: Cancel only", plan(sheetOnLanguage, pages: []) == [.tap(0.5, 0.91, "(Cancel)")])
        var sheetOnPick = sheetOnLanguage; sheetOnPick["Skip This Step"] = (0.82, 0.95)
        expect("Home sheet over a page with a pick: Cancel only", taps(plan(sheetOnPick, pages: [])) == ["(Cancel)"])
        var language = sheetOnLanguage; ["Emergency Call", "Start Over", "Cancel"].forEach { language[$0] = nil }
        let lang = plan(language, pages: [])
        expect("language page: English, then the arrow", lang.count == 3 && lang[0] == .tap(0.15, 0.2, "English")
               && { if case .tap(let x, let y, _) = lang[2] { return x == nextArrow.x && y == nextArrow.y }; return false }())
        // n90ap-11D257 (7.1.2), fold-10 run 1: the Country page
        let country7: [String: (x: Double, y: Double)] = [
            "Back": (0.12, 0.09), "Select Your Country": (0.5, 0.19), "or Region": (0.5, 0.26),
            "MORE COUNTRIES AND REGIONS": (0.4, 0.5), "Afghanistan": (0.2, 0.595), "Åland Islands": (0.22, 0.72)]
        expect("7.x Country page: its first row", taps(plan(country7, pages: [])) == ["Afghanistan"])
        expect("an alert's OK", taps(plan(["OK": (0.5, 0.6), "Location Services": (0.5, 0.4)], pages: [])) == ["(OK)"])
        expect("nothing known: the welcome slide, if on the lock screen", plan(["slide to set up": (0.5, 0.9)], pages: []) == [.slideIfLockScreen])
        return ok
    }

    static func walk(_ d: Device, agent: GuestAgent, generation: Int) async -> (Bool, String) {
        var pages: [String] = []
        // 80 pages: 7.x's Apple ID page ignores Skip This Step while its spinner runs (10-13 tries), and a 7.1.2 walk
        // that needed 38 of 40 pages on 10-05 ran out at the passcode page on 10-06. The boot's 1400 s cap still bounds it.
        for n in 0..<80 {
            try? await Task.sleep(for: .seconds(3))
            if let f = try? await agent.frontmost(), f.bundleID == "com.apple.springboard", f.name == "Home Screen" {
                return (true, "Setup walked: " + pages.joined(separator: ", "))
            }
            // LTM_SETUP_SHEET_PROBE=1 (a live check of the sheet path): once past the welcome page, press Home in Setup,
            // which opens the Emergency Call / Start Over sheet over the page; the walk must dismiss it and go on.
            if ProcessInfo.processInfo.environment["LTM_SETUP_SHEET_PROBE"] == "1", !pages.contains("(sheet probe)"), n > 0,
               let f = try? await agent.frontmost(), f.name != "Lock Screen" {
                d.process.link.send(.button(0, down: true)); try? await Task.sleep(for: .milliseconds(150))
                d.process.link.send(.button(0, down: false))
                try? await Task.sleep(for: .seconds(1.5))
                pages.append("(sheet probe)")
            }
            guard let shot = await d.wakeForShot("setup\(generation)-\(n)") else { continue }
            for step in plan(labels(shot), pages: pages) {
                switch step {
                case .tap(let x, let y, let log):
                    await d.tap(x, y); if let log { pages.append(log) }
                case .pause(let seconds):
                    try? await Task.sleep(for: .seconds(seconds))
                case .slideIfLockScreen:
                    guard (try? await agent.frontmost())?.name == "Lock Screen" else { break }
                    // The welcome page (SpringBoard's lock screen) and its slider. Home first, as app-install's unlock():
                    // the S5L8920 boards power the digitizer down on the lock screen (DisablePowerForUILock), and a slide
                    // then does nothing (n88 6.0.1: 40 slides, still welcome). Only there: in Setup, Home opens a sheet.
                    d.process.link.send(.button(0, down: true)); try? await Task.sleep(for: .milliseconds(150))
                    d.process.link.send(.button(0, down: false))
                    try? await Task.sleep(for: .seconds(1.5))
                    await d.drag(0.18, 0.9, 0.92, 0.9)
                    pages.append("(slide)")
                }
            }
        }
        return (false, "Setup still up after 80 pages: " + pages.joined(separator: ", "))
    }
}
