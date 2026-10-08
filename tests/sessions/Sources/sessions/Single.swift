import Foundation
import SessionKit

/// `sessions single BASE`: one prepared base booted as the app boots it (session-driver's single.swift): lit, lockdown
/// over its own usbmuxd, the first-host activation handshake and the Mac's time zone, the Home screen (the guest agent's
/// frontmost app and screen where the base has an agent, the frame against tests/sessions/matrix-refs where there is a
/// reference), the backlight at the firmware's 100%, AFC round trips past 16 KiB, an IPA install (2.x on), a clean
/// shutdown confirmed by the guest, and the base untouched.
func single(_ args: Arguments) -> Never {
    guard let path = args.positional.first else { die("single needs a prepared base") }
    let base = Base(path)
    let work = workDirectory(args, "single")
    let tools = Tools.resolve(args, work: work)
    let d = base.driverBoard
    let install = !args.flag("no-install") && base.major >= 2  // 1.x has no installation_proxy
    let ipa = args.path("ipa") ?? checkout("qemu-ios").appendingPathComponent("contrib/it-harness/build/Harness.ipa")
    if install, !FileManager.default.fileExists(atPath: ipa.path) { die("no test IPA at \(ipa.path) (--ipa)") }
    let before = SessionJudge.tree(base.url)

    var single: [String: Any] = [
        "board": d, "base": base.url.path, "lockdownTZ": tools.services.path,
        "launch": args.flag("launch"), "reboot": args.flag("reboot"), "install": install,
    ]
    if args.flag("host-power-gesture") { single["hostPowerGesture"] = true }
    if let zone = args["second-zone"] { single["secondZone"] = zone }
    if let file = args["read-file"] { single["readFile"] = file }
    if let upgrade = args.path("upgrade-ipa") { single["upgradeIPA"] = upgrade.path }
    if let wav = args.path("audio-wav") { single["audioWAV"] = wav.path }
    let race = Int(args["afc-race"] ?? "")
    if let race {
        single["raceBoots"] = race
        single["raceDirty"] = args.flag("dirty")
    }
    var config = driverConfig(tools, work: work, ipa: ipa)
    if !args.flag("no-offer") {  // the app offers its bundled guest package at every boot
        let packs = tools.guest.appendingPathComponent("guest-tools")
        if base.armv7 {
            config["ipadItpack"] = (args.path("itpack") ?? packs.appendingPathComponent("armv7.itpack")).path
        } else {
            single["itpack"] = (args.path("itpack") ?? packs.appendingPathComponent("armv6.itpack")).path
        }
    }
    if base.board == "k48ap" { config["ipadBase"] = base.url.path }
    config["single"] = single
    // 6.x/7.x: the first boot walks the Setup Assistant; 7.x also boots and pairs far slower. Per boot.
    var timeout = base.major >= 7 ? 1400.0 : base.major >= 6 ? 700 : 560
    if args.flag("reboot") { timeout *= 2 }
    if let race { timeout = 200 * Double(race) }
    config["timeout"] = timeout

    print("\(base.entryID): \(d) from \(base.url.path)")
    let (events, status) = sessionDriver(config, work: work, timeout: timeout, environment: driverEnvironment(tools))
    let r = Report()
    if let race {
        for e in events.find("race", ["device": d]) {
            r.check(
                !e.has("error"),
                "\(d) boot \(e.int("generation") ?? 0): AFC \(format(e.double("seconds"))) s after lockdown's first answer "
                    + "(\(format(e.double("lockdown"))) s after power-on): "
                    + (e.string("error") ?? "\(e.int("entries") ?? 0) entries")
            )
        }
        for e in events.find("raceStop", ["device": d]) {
            r.check(
                !e.has("uploadError"),
                "\(d) boot \(e.int("generation") ?? 0): installed, uploaded, Stop \(format(e.double("afterHalt"), 0)) s into the halt"
                    + (e.string("uploadError").map { ": \($0)" } ?? "")
            )
        }
        r.check(
            events.find("race", ["device": d]).count == race && events.any("done"),
            "\(d): \(events.find("race", ["device": d]).count)/\(race) boots ran"
        )
        finish(r, work: work)
    }

    let lit = events.one("lit", ["device": d])
    r.check(!lit.isEmpty, "\(d): lit in \(format(lit.double("seconds"))) s")
    let usb = events.one("usb", ["device": d])
    r.check(
        usb.string("productType") == base.productType,
        "\(d): lockdown over its usbmuxd: \(usb.string("productType") ?? "none")"
    )
    let home = SessionJudge.home(
        lock: base.lock,
        events: events,
        entryID: base.entryID,
        references: repository.appendingPathComponent("tests/sessions/matrix-refs")
    )
    r.check(home.ok == true, "\(d): usable Home screen: \(home.detail)")
    let top = SessionJudge.backlightTop(board: base.board, base: base.url, productVersion: base.version)
    for h in events.find("home", ["device": d]) {
        let level = h.int("backlight") ?? -1
        if let top, level != -1 {
            r.check(level >= top, "\(d): backlight at Home \(hex(level)), the firmware's 100% is \(hex(top))")
        } else {
            r.note("\(d): backlight level not decoded here (\(level))")
        }
    }
    let activation = events.find("activationCompleted", ["device": d])
    r.check(
        !activation.isEmpty && activation.allSatisfy { $0.bool("ok") },
        "\(d): automatic activation handshake completed"
            + (activation.allSatisfy { $0.bool("ok") } ? "" : ": \(activation.map { $0.string("error") ?? "" })")
    )
    let ids = events.find("identity", ["device": d])
    if d == "ipod" || d == "ipad" {
        r.check(
            !ids.isEmpty && ids.allSatisfy { $0.bool("matches") },
            "\(d): lockdown's identity matches the prepared identity: "
                + ids.map { e in
                    ((e["values"] as? [String: String]) ?? [:]).sorted { $0.key < $1.key }.map {
                        "\($0.key) \($0.value)"
                    }
                    .joined(separator: ", ") + (e.bool("matches") ? "" : " (want \(e["expected"] ?? ""))")
                }.joined(separator: "; ")
        )
    }
    let afc = events.find("afc", ["device": d])
    for a in afc {
        let bytes = a.int("bytes") ?? 0
        r.check(
            a.bool("same") && a.int("listed") == bytes,
            "\(d): AFC round trip of \(bytes) bytes"
                + (a.bool("same")
                    ? " (\(format(a.double("seconds"))) s)" : ": \(a.string("error") ?? "content differs")")
        )
    }
    r.check(afc.count >= 4, "\(d): AFC checks ran (\(afc.count))")
    if install {
        let inst = events.one("installed", ["device": d])
        r.check(
            inst.bool("has"),
            "\(d): IPA installed (\(format(inst.double("seconds"), 0)) s, attempt \(inst.int("attempt") ?? 0))"
        )
    }
    if args.path("upgrade-ipa") != nil {
        let up = events.one("upgraded", ["device": d])
        r.check(
            (up.string("error") ?? "x").isEmpty && !(up.string("after") ?? "").isEmpty && up.bool("kept"),
            "\(d): upgrade over the installed app keeps its data (now version \(up.string("version") ?? "")): \(up)"
        )
    }
    if args.flag("launch") {
        let launches = events.find("launched", ["device": d])
        r.check(
            !launches.isEmpty
                && launches.allSatisfy {
                    $0.string("via") == "agent" && !$0.has("launchError")
                        && $0.string("frontmost3") == "com.qemuios.harness"
                },
            "\(d): the installed app is frontmost after the agent's launch: \(launches.map { $0.string("frontmost3") ?? $0.string("launchError") ?? "?" })"
        )
    }
    let boots = args.flag("reboot") ? 2 : 1
    let quits = events.find("quit", ["device": d])
    r.check(
        quits.count == boots
            && quits.allSatisfy {
                ($0.double("confirmed") ?? -1) >= 0 && $0.bool("exited")
                    && ($0.string("reason") ?? "").hasSuffix(" stopped.")
            },
        "\(d): \(quits.count)/\(boots) clean shutdowns, guest power-off confirmed "
            + quits.map { "in \(format($0.double("confirmed"))) s" }.joined(separator: ", ") + ", helper exited"
    )
    if args.flag("host-power-gesture") {
        let gestures = events.find("hostPowerGesture", ["device": d])
        r.check(
            gestures.count == boots && gestures.allSatisfy { $0.bool("confirmed") && !$0.has("error") },
            "\(d): \(gestures.count)/\(boots) host power gestures confirmed by the guest's PMU"
        )
    }
    let zones = events.find("timezone", ["device": d])
    if !zones.isEmpty, !base.firstGeneration {  // 1.x: NITZ (the M68's modem) or nothing
        r.check(
            zones.allSatisfy { $0.string("zone") == $0.string("want") },
            "\(d): lockdown holds the zone asked for at each boot: \(zones.map { "\($0.string("want") ?? "") -> \($0.string("zone") ?? "")" })"
        )
    }
    if let zone = args["second-zone"] {
        r.check(
            zones.contains { $0.int("generation") == 2 && $0.string("zone") == zone },
            "\(d): the zone follows the Mac's change between boots"
        )
    }
    if args.flag("reboot") {
        let persisted = events.find("persist", ["device": d])
        r.check(
            !persisted.isEmpty && persisted.allSatisfy { $0.bool("kept") && $0.bool("same") },
            "\(d): an AFC file survives the cold reboot byte for byte\(persisted.first?.string("error").map { ": \($0)" } ?? "")"
        )
        if install {
            let restarted = events.find("restartedApps", ["device": d])
            r.check(
                !restarted.isEmpty && restarted.allSatisfy { $0.bool("has") },
                "\(d): the installed app survives the cold reboot"
            )
        }
        r.check(
            events.find("home", ["device": d]).count == boots && activation.count == boots
                && (d != "ipod" || ids.count == boots),
            "\(d): both boots reached Home, activation and identity"
        )
    }
    if let file = args["read-file"] {
        let reads = events.find("fileRead", ["device": d])
        r.check(!reads.isEmpty && reads.allSatisfy { $0.bool("found") }, "\(d): the guest agent reads back \(file)")
    }
    let after = SessionJudge.tree(base.url)
    r.check(
        after == before,
        "\(d): the prepared base is unchanged" + (after == before ? "" : ": " + SessionJudge.treeDiff(before, after))
    )
    r.check(events.any("done") && status == 0, "driver finished (exit \(status.map(String.init) ?? "timeout"))")
    for e in events.find("screenshot") {
        print(
            "   \(e.string("path") ?? "")  (\(e.int("width") ?? 0)x\(e.int("height") ?? 0), brightness \(format(e.double("brightness"), 2)))"
        )
    }
    finish(r, work: work)
}

func hex(_ value: Int) -> String { "0x" + String(value, radix: 16) }
