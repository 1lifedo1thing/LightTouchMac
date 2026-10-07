import Foundation
import SessionKit

/// helper-driver (DeviceLink straight to the helper) running one scenario in work/<name>.
final class HelperDriver {
    let name: String, dir: URL, log: URL
    let driver: DriverProcess

    init(_ name: String, tools: Tools, helper: URL? = nil, work: URL, scenario: [String: Any], extra: [String] = [],
         environment: [String: String] = [:]) {
        self.name = name
        dir = work.appendingPathComponent(name)
        log = dir.appendingPathComponent("native.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var scenario = scenario
        if scenario["dylib"] == nil { scenario["dylib"] = tools.dylib.path }
        let file = dir.appendingPathComponent("scenario.json")
        try? JSONSerialization.data(withJSONObject: scenario, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        driver = DriverProcess("helper-driver", ["--helper", (helper ?? tools.helper).path, "--scenario", file.path, "--dump", dir.path,
                                                 "--log", log.path, "--requirement", Tools.teamRequirement] + extra,
                               out: dir.appendingPathComponent("driver.jsonl"), environment: environment)
    }
    var events: Events { driver.events }
    var nativeLog: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
    var tail: String { events.all.suffix(12).map { "\($0)" }.joined(separator: "\n") }
    /// Waits, then kills whatever it started that is still alive.
    @discardableResult
    func finish(_ seconds: Double) -> Int32? {
        let status = driver.wait(seconds)
        killLeftovers(events)
        return status
    }
}

/// A prepared base booted by helper-driver as the app boots it (PreparedDeviceBoot with the hello's machine facts).
func preparedScenario(_ base: Base, tools: Tools, work: URL, name: String, steps: [String], carrier: [String: Any]? = nil) -> [String: Any] {
    let dir = work.appendingPathComponent(name)
    var prepared: [String: Any] = ["base": base.url.path, "overlay": dir.appendingPathComponent("overlay").path,
                                   "serial": dir.appendingPathComponent("serial.log").path, "files": tools.files.path]
    if let carrier { prepared["carrier"] = carrier }
    return ["board": base.board, "prepared": prepared, "steps": steps]
}

let unlockSlide = "drag 0.18 0.9 0.92 0.9"   // a phone's or iPod's lock-screen slider, portrait

/// SIGKILL the driver (the "app") once it holds: the helper must notice, hard-halt (pause, flush, quit QEMU; no guest
/// shutdown) and exit.
func parentKill(_ d: HelperDriver, _ r: Report, budget: Double) {
    guard let hold = d.driver.waitFor("hold", 400) else { r.check(false, "\(d.name): reached hold"); print(d.tail); return }
    let helper = hold.int("helperPid") ?? 0
    kill(d.driver.pid, SIGKILL)
    d.driver.process.waitUntilExit()
    let gone = waitGone(helper, budget)
    r.check(gone != nil, "\(d.name): the helper exited \(format(gone)) s after the parent died")
    if gone == nil { kill(pid_t(helper), SIGKILL) }
    let log = d.nativeLog
    r.check(log.contains("halt: parent exited") || log.contains("halt: link closed"), "\(d.name): the helper noticed the parent's death")
    r.check(!log.contains("did not return") && !log.contains("powerdown"), "\(d.name): hard halt (paused, storage flushed, QEMU quit; no guest shutdown)")
}

/// `sessions helper`: the helper without a guest. An ad-hoc re-signed helper is refused by the Team requirement; two
/// helpers on one device's lease (the second refused, another device's not, the lease taken again once the holder's
/// parent dies); the lease admission cases (ordinary and external leases, busy, pending edit and symlink refused), a
/// kill before hello and a preparation failure, each reaped exactly once with its lease released.
func helperChecks(_ args: Arguments) -> Never {
    let work = workDirectory(args, "helper")
    let tools = Tools.resolve(args, work: work)
    let r = Report()

    print("reject")
    let impostor = work.appendingPathComponent("LightTouchDevice-adhoc"), entitlements = work.appendingPathComponent("helper.entitlements")
    try? FileManager.default.copyItem(at: tools.helper, to: impostor)
    try? output("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", tools.helper.path]).write(to: entitlements, atomically: true, encoding: .utf8)
    run("/usr/bin/codesign", ["-f", "-o", "runtime", "-s", "-", "--entitlements", entitlements.path, impostor.path])
    let reject = HelperDriver("reject", tools: tools, helper: impostor, work: work, scenario: ["steps": [String]()], extra: ["--expect-reject", "1"])
    let rejected = reject.finish(30) == 0
    let rejectOutput = (try? String(contentsOf: reject.driver.out, encoding: .utf8)) ?? ""
    r.check(rejected && rejectOutput.contains("requirement failed"), "an ad-hoc re-signed helper is refused at the rendezvous")

    print("lease")
    let state = work.appendingPathComponent("lease-state")
    let lease = state.appendingPathComponent("Devices/\(UUID().uuidString)/work/lease").path
    let other = state.appendingPathComponent("Devices/\(UUID().uuidString)/work/lease").path
    let a = HelperDriver("lease-a", tools: tools, work: work, scenario: ["steps": ["hold"]], extra: ["--lease", lease])
    let holding = a.driver.waitFor("hold", 30)
    r.check(holding != nil, "the first helper takes the lease and connects")
    let b = HelperDriver("lease-b", tools: tools, work: work, scenario: ["steps": [String]()],
                         extra: ["--lease", lease, "--expect-failure", "in use by another copy of Light Touch"])
    r.check(b.finish(30) == 0, "a second helper on the same device is refused")
    let o = HelperDriver("lease-other", tools: tools, work: work, scenario: ["steps": [String]()], extra: ["--lease", other])
    r.check(o.finish(30) == 0 && o.events.any("connected"), "another device's helper connects meanwhile")
    let holder = a.events.one("connected").int("pid") ?? 0
    kill(a.driver.pid, SIGKILL)
    a.driver.process.waitUntilExit()
    r.check(holder > 0 && waitGone(holder, 60) != nil, "the holder exits after its parent dies")
    killLeftovers(a.events)
    let c = HelperDriver("lease-c", tools: tools, work: work, scenario: ["steps": [String]()], extra: ["--lease", lease])
    r.check(c.finish(30) == 0 && c.events.any("connected"), "the lease is taken again once released")

    // session-driver's hello-only modes: each verifies itself and exits 0.
    for (mode, verified, what) in [("leaseAdmission", "leaseAdmissionVerified", "lease admission: ordinary and external admitted; busy, pending and symlink refused before hello"),
                                   ("killBeforeBoot", "killBeforeBootVerified", "a helper killed before hello is reaped once, its lease free"),
                                   ("preparationFailure", "preparationFailureVerified", "a preparation failure after hello keeps its diagnostic; helper reaped, lease released, nothing published")] {
        print(mode)
        let dir = work.appendingPathComponent(mode)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("work"), withIntermediateDirectories: true)
        var config = driverConfig(tools, work: dir.appendingPathComponent("work"))
        config[mode] = true
        config["timeout"] = 65
        let (e, status) = sessionDriver(config, work: dir.appendingPathComponent("work"), timeout: 65, environment: driverEnvironment(tools))
        let checks = e.find(verified)
        r.check(status == 0 && !checks.isEmpty && checks.allSatisfy { !$0.bool("guestStarted") }, what
                + (status == 0 ? "" : ": \(e.one("fail").string("why") ?? "exit \(status.map(String.init) ?? "timeout")")"))
    }
    finish(r, work: work)
}

/// `sessions helper-boot BASE` (an n72 base): the helper booting a guest with no app around it. `ipod`: lit through the
/// frame ring, the slider, rotation (the landscape Home screen is shown), a battery request, an agent round trip, then
/// the parent SIGKILLed: hard halt. `meddle`: the app's DeviceFileWatch on the overlay sees its NOR unlinked under the
/// running helper (the app's notice); SIGTERM halts the helper. `power`: the pump at 60 Hz before boot (30 with the host
/// constrained); shown 60 Hz with an idle-sleep assertion, hidden at most 5 Hz and none, back to 60 Hz within 100 ms,
/// the guest's display asleep at most 5 Hz, woken 60 Hz again. `--only a,b` picks cases.
func helperBoot(_ args: Arguments) -> Never {
    guard let path = args.positional.first else { die("helper-boot needs a prepared n72 base") }
    let base = Base(path)
    guard base.board == "n72ap" else { die("helper-boot boots an n72ap base") }
    let work = workDirectory(args, "helper-boot")
    let tools = Tools.resolve(args, work: work)
    let only = Set((args["only"] ?? "ipod,meddle,power").split(separator: ",").map(String.init))
    let r = Report()

    if only.contains("ipod") {
        print("ipod")
        let d = HelperDriver("ipod", tools: tools, work: work, scenario: preparedScenario(base, tools: tools, work: work, name: "ipod", steps: [
            "boot", "lit 0.03 240", "dump lock", unlockSlide, "wait 4", "dump home", "rotate cw", "wait 2", "dump rotated",
            "rotate ccw", "wait 2", "battery 50 0", "wait 20", "agent echo agent-ok", "status", "hold"]))
        parentKill(d, r, budget: 10)
        let e = d.events
        r.check(e.any("lit"), "ipod: lit through the ring after \(format(e.one("lit").double("seconds"))) s")
        var dumps: [String: Event] = [:]
        for x in e.find("dump") { dumps[x.string("name") ?? ""] = x }
        r.check(dumps["home"]?.bool("ok") == true && dumps["lock"]?.bool("ok") == true, "ipod: lock and home dumps")
        // The rotated Home screen is one new frame: a frame the ring dropped would stay black.
        let rotated = dumps["rotated"] ?? [:], home = dumps["home"] ?? [:]
        r.check(rotated.int("width") == 480 && (rotated.double("brightness") ?? 0) > 0.5 * (home.double("brightness") ?? 1),
                "ipod: the rotated Home screen is shown (\(rotated.int("width") ?? 0)x\(rotated.int("height") ?? 0), brightness "
                + "\(format(rotated.double("brightness"), 2)) vs \(format(home.double("brightness"), 2)))")
        r.check(e.find("reply").contains { ($0.string("reply") ?? "").contains("ok(true)") }, "ipod: battery request -> ok(true)")
        r.check(e.find("agent").contains { ($0.string("output") ?? "").contains("agent-ok") }, "ipod: agent round trip")
    }
    if only.contains("meddle") {
        print("meddle")
        let overlay = work.appendingPathComponent("meddle/overlay")
        let d = HelperDriver("meddle", tools: tools, work: work, scenario: preparedScenario(base, tools: tools, work: work, name: "meddle", steps: [
            "boot", "lit 0.03 240", "wait 3", "watch \(overlay.path)", "hold"]))
        if let hold = d.driver.waitFor("hold", 400), r.check(true, "meddle: lit and holding with the overlay watched") {
            let helper = hold.int("helperPid") ?? 0
            r.check((d.events.one("watching").int("count") ?? 0) >= 2, "meddle: the watch covers the overlay and its files")
            try? FileManager.default.removeItem(at: overlay.appendingPathComponent("nor.bin"))   // the writable NOR QEMU has open
            let m = d.driver.waitFor("meddled", 5)
            r.check((m?.string("path") ?? "").hasSuffix("nor.bin") && m?.string("notice")
                    == "Files of this iPod were changed while it was running. Stop and start it again; unsaved changes may be lost.",
                    "meddle: the watch reported \(m?.string("path") ?? "nothing") with the app's notice")
            r.check(alive(helper) && d.driver.process.isRunning, "meddle: the helper and guest kept running on the unlinked inode")
            kill(pid_t(helper), SIGTERM)
            let gone = waitGone(helper, 15)
            r.check(gone != nil, "meddle: SIGTERM, the helper exited \(format(gone)) s later")
            r.check(d.nativeLog.contains("halt:"), "meddle: the helper logged its halt")
            kill(d.driver.pid, SIGKILL)
            d.finish(5)
        } else {
            r.check(false, "meddle: lit and holding")
            print(d.tail)
            d.finish(1)
        }
    }
    if only.contains("power") {
        print("power")
        for (name, env, low, high) in [("power-free", [String: String](), 50.0, 65.0), ("power-constrained", ["LTM_HOST_CONSTRAINED": "1"], 25, 33)] {
            let d = HelperDriver(name, tools: tools, work: work, scenario: ["steps": ["wait 1", "sample preboot 3"]], environment: env)
            let hz = d.finish(60) == 0 ? d.events.one("sample").double("hz") ?? -1 : -1
            r.check(low <= hz && hz <= high, "\(name): the pump at \(format(hz)) Hz before boot")
        }
        // Unlocked first: the lock screen's display sleeps within seconds, the Home screen's not for a minute.
        var steps = ["boot", "lit 0.03 300", "wait 2", "button 0", "wait 2", unlockSlide, "wait 3", "sample shown 5", "visible off", "sample hidden 5"]
        // Shown again 40-240 ms before the next 4 Hz tick (hidden starts its ticks when the command lands).
        for gap in [0.51, 0.56, 0.61, 0.66, 0.71] { steps += ["visible on", "wait 0.5", "visible off", "wait \(gap)"] }
        steps += ["visible on", "button 1", "waitSleep 20", "wait 3", "sample asleep 5", "button 1", "wait 1", "sample woken 2", "quit", "expectExit 60"]
        let d = HelperDriver("power", tools: tools, work: work, scenario: preparedScenario(base, tools: tools, work: work, name: "power", steps: steps))
        r.check(d.finish(500) == 0, "power: scenario completed")
        var s: [String: Event] = [:]
        for x in d.events.find("sample") { s[x.string("label") ?? ""] = x }
        for label in ["shown", "hidden", "asleep", "woken"] {
            let x = s[label] ?? [:]
            print("   \(label): \(format(x.double("hz"))) Hz, \(format(x.double("fps"))) fps, \(format(x.double("cpuPercent")))% CPU, "
                  + "\(format(x.double("wakeupsPerSecond"))) wakeups/s, \(format(x.double("milliwatts"))) mW, "
                  + "idle-sleep assertion \(x.bool("preventsIdleSleep")), display asleep \(x.bool("displaySleeping"))")
        }
        func rate(_ label: String, _ low: Double, _ high: Double, holds: Bool) -> Bool {
            guard let x = s[label], let hz = x.double("hz") else { return false }
            return low <= hz && hz <= high && x.bool("preventsIdleSleep") == holds
        }
        r.check(rate("shown", 50, 65, holds: true), "power: shown, 60 Hz, holds off idle sleep")
        r.check(rate("hidden", 0.5, 5, holds: false), "power: hidden, at most 5 Hz, lets the Mac idle-sleep")
        r.check(s["asleep"]?.bool("displaySleeping") == true && rate("asleep", 0.5, 5, holds: false),
                "power: the guest's display asleep, at most 5 Hz, lets the Mac idle-sleep")
        r.check(rate("woken", 50, 65, holds: true), "power: woken by the power button, 60 Hz again")
        let ticks = d.events.find("visible").filter { $0.bool("on") }.prefix(5).compactMap { $0.double("tickMs") }
        r.check(ticks.count == 5 && ticks.allSatisfy { 0 <= $0 && $0 < 100 }, "power: shown again, back at 60 Hz within 100 ms (\(ticks) ms)")
    }
    finish(r, work: work)
}

/// `sessions phone BASE [--overlay DIR]` (an n90, n88 or m68 base): the Carrier panel's path (app -> link ->
/// qemu_ios_ui_modem_set/_status -> the modem): booted registered with saved settings, renamed, a bad MCC/MNC refused,
/// signal moved, an incoming SMS delivered and its tone heard, a call rung (its ringtone heard, through the app's audio
/// capture) and hung up, an unknown property refused. `rotate`: a new frame within 1 s of the app's rotation request,
/// different from portrait. `shutdown`: the guest confirms its own power-off. `keyboard` (A4): Connect Hardware Keyboard
/// off and on. 6.x/7.x's first boot sits in Setup, which rejects calls: the carrier case then needs --overlay, the overlay
/// of a boot that walked Setup (`sessions single` leaves one in its work directory), cloned, never changed.
func phone(_ args: Arguments) -> Never {
    guard let path = args.positional.first else { die("phone needs a prepared iPhone base") }
    let base = Base(path)
    guard ["n90ap", "n88ap", "m68ap"].contains(base.board) else { die("phone boots an n90ap, n88ap or m68ap base") }
    let work = workDirectory(args, "phone")
    let tools = Tools.resolve(args, work: work)
    var only = Set((args["only"] ?? "carrier,rotate,shutdown,keyboard").split(separator: ",").map(String.init))
    if base.board != "n90ap" { only.remove("keyboard") }
    let r = Report()

    if only.contains("carrier") {
        print("carrier")
        let overlay = work.appendingPathComponent("carrier/overlay")
        if let source = args.path("overlay") {
            try? FileManager.default.createDirectory(at: overlay.deletingLastPathComponent(), withIntermediateDirectories: true)
            run("/bin/cp", ["-cR", source.path, overlay.path])   // a clone: the source stays as it was
        } else if base.major >= 6 {
            die("a \(base.version) base is in Setup on its first boot, which rejects calls: pass --overlay (or --only rotate,shutdown,keyboard)")
        }
        let saved: [String: Any] = ["carrier": "Saved, Carrier", "mccMNC": "00101", "registered": true, "simPresent": true, "bars": 4]
        let d = HelperDriver("carrier", tools: tools, work: work, scenario: preparedScenario(base, tools: tools, work: work, name: "carrier", steps: [
            "boot", "lit 0.1 300", "wait 60", "dump registered", "modemStatus",
            "modem carrier Cell Panel", "modem signal-dbm -97", "modem mcc-mnc 001", "wait 1", "modemStatus",
            "modem incoming-sms +15555550100|hello from the panel", "audio 10", "modemStatus",
            "modem incoming-call 15555550100", "audio 12", "modemStatus",
            "modem remote-hangup 1", "wait 3", "modemStatus",
            "modem no-such-property x", "quit", "expectExit 60"], carrier: saved))
        r.check(d.finish(600) == 0, "carrier: scenario completed")
        let e = d.events
        let st: [Event] = e.find("modemStatus").map {
            ($0.string("json").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? Event) ?? [:]
        }
        var replies: [String: String] = [:]
        for x in e.find("reply") { if let m = x.string("modem") { replies[m] = x.string("reply") ?? "" } }
        if r.check(st.count == 5, "carrier: five statuses (\(st.count))") {
            r.check(st[0].string("carrier") == "Saved, Carrier" && st[0].int("signal-dbm") == -81 && st[0].string("mcc-mnc") == "00101"
                    && st[0].bool("registered"), "carrier: booted registered with the saved settings (\(st[0]))")
            r.check(st[1].string("carrier") == "Cell Panel" && st[1].int("signal-dbm") == -97 && st[1].string("mcc-mnc") == "00101"
                    && (st[1].string("error") ?? "").contains("mcc-mnc"), "carrier: renamed, signal moved, the bad MCC/MNC refused (\(st[1]))")
            r.check(!st[2].has("error") && (replies["incoming-sms"] ?? "").contains("ok(true)"), "carrier: the SMS delivered (\(st[2]))")
            r.check(st[3].string("call-state") == "incoming", "carrier: ringing: \(st[3].string("call-state") ?? "")")
        }
        // The app's audio capture through each: the SMS tone, then the ringtone (AAC through the A4's AMC).
        let heard = e.find("audioEnded").map { $0.int("loud") ?? 0 }
        if r.check(heard.count == 2, "carrier: two captures (\(heard.count))") {
            r.check(heard[0] > 2000, "carrier: the SMS tone is heard (\(heard[0]) loud samples)")
            r.check(heard[1] > 20000, "carrier: the ringtone is heard (\(heard[1]) loud samples in 12 s of ringing)")
            if st.count == 5 { r.check(st[4].string("call-state") == "idle", "carrier: hung up: \(st[4].string("call-state") ?? "")") }
        }
        r.check((replies["no-such-property"] ?? "").contains("ok(false)"), "carrier: an unknown property is refused at the link")
    }
    if only.contains("rotate") {
        print("rotate")
        let d = HelperDriver("rotate", tools: tools, work: work, scenario: preparedScenario(base, tools: tools, work: work, name: "rotate", steps: [
            "boot", "lit 0.03 300", "wait 8", "dump lock", unlockSlide, "wait 4", "tap 0.617 0.9", "wait 8", "dump home", "status",
            "orientation 4", "wait 1", "dump turned", "status", "wait 4", "dump turned5", "status", "quit", "expectExit 60"]))
        r.check(d.finish(600) == 0, "rotate: scenario completed")
        let serials = d.events.find("status").map { (($0["status"] as? Event) ?? $0).int("frameSerial") }
        r.check(serials.count == 3 && (serials[1] ?? 0) > (serials[0] ?? Int.max), "rotate: a new frame within 1 s of the rotation (frame serials \(serials))")
        let home = d.dir.appendingPathComponent("home.png"), turned = d.dir.appendingPathComponent("turned.png")
        let same = (try? Data(contentsOf: home)) == (try? Data(contentsOf: turned))
        let dumped = d.events.find("dump").contains { $0.string("name") == "turned" && $0.bool("ok") }
        r.check(dumped && !same, "rotate: the turned frame differs from portrait")
    }
    if only.contains("shutdown") {
        print("shutdown")
        let d = HelperDriver("shutdown", tools: tools, work: work, scenario: preparedScenario(base, tools: tools, work: work, name: "shutdown", steps: [
            "boot", "lit 0.03 300", "wait 20", "shutdown 120", "status", "quit", "expectExit 60"]))
        r.check(d.finish(600) == 0, "shutdown: scenario completed")
        let done = d.events.one("shutdown")
        r.check(done.bool("confirmed"), "shutdown: the guest powered itself off (\(format(done.double("seconds"), 0)) s)")
    }
    if only.contains("keyboard") {
        print("keyboard")
        let d = HelperDriver("keyboard", tools: tools, work: work, scenario: preparedScenario(base, tools: tools, work: work, name: "keyboard", steps: [
            "boot", "lit 0.03 300", "wait 5", "keyboard off", "wait 2", "keyboard on", "quit", "expectExit 60"]))
        r.check(d.finish(400) == 0, "keyboard: scenario completed")
        let replies = d.events.find("reply").map { $0.string("reply") ?? "" }
        r.check(replies.count == 2 && replies.allSatisfy { $0.contains("ok(true)") }, "keyboard: unplugged and replugged: \(replies)")
    }
    finish(r, work: work)
}
