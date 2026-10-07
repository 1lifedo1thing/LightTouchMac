import DeviceRuntime
import Foundation
import HostRuntime
import IOSurface

// Stands in for the app in tests/sessions/check-helper-boot.py: spawns LightTouchDevice
// through DeviceLink (rendezvous, validation, status block, frame ring, link)
// and runs a scripted scenario. JSON lines on stdout; built by the test with
// swiftc from Packages/DeviceRuntime/Sources/DeviceRuntime/*.swift + LightTouchDevice/FrameTools.swift.
//
//   helper-driver --helper PATH --scenario scenario.json --dump DIR [--log native.log] [--requirement R]
//                 [--lease PATH] [--expect-failure TEXT]   (exit 0 if the start fails with TEXT)
//
// scenario: {"dylib": "...", "board": "k48ap", "boot": BootConfig, "steps": ["boot", "lit 0.2 300", ...]}; or, for a
// FirmwareKit base booted as the app boots it (PreparedDeviceBoot with the hello's machine facts), "prepared":
// {"base": DIR, "overlay": DIR, "serial": FILE, "carrier": CarrierSettings} in place of "boot".
// "watch DIR" starts the app's DeviceFileWatch on DIR (and its children): "meddled" events follow any change.
// "sample LABEL S" measures the helper for S seconds: pump rate (heartbeats/s), frames/s, CPU, wakeups and energy
// (proc_pid_rusage), and whether it holds an idle-sleep assertion (pmset). "visible on|off" is the window's
// occlusion (LinkCommand.screenVisible): how long until the pump has ticked 3 times (back at speed) and, if one was
// pending, the next frame.

var opts = [String: String]()
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() { opts[a] = it.next() ?? "" }
}

struct Scenario: Decodable {
    struct Prepared: Decodable {
        var base: String, overlay: String, serial: String
        /// The SecureROMs (BootRecipe.bootrom); default ~/Developer/qemu-ios-files.
        var files: String?
        /// The Carrier panel's saved settings, as the app boots a radio board with them.
        var carrier: CarrierSettings?
    }
    var dylib: String?
    var board: String?
    var boot: BootConfig?
    var prepared: Prepared?
    var steps: [String]
}

/// `prepared` as the app boots it: PreparedDeviceBoot and BootRecipe with the hello's DeviceInfo.
func preparedBoot(_ p: Scenario.Prepared, hardware: DeviceInfo?) throws -> BootConfig {
    guard let board = scenario.board.flatMap(Board.init(rawValue:)) else { throw CocoaError(.featureUnsupported) }
    let overlay = URL(fileURLWithPath: p.overlay)
    let prepared = try PreparedDeviceBoot.prepare(
        board: board,
        base: URL(fileURLWithPath: p.base),
        overlay: overlay,
        writableNOR: overlay.appendingPathComponent("nor.bin"),
        storageKey: nil,
        bootrom: BootRecipe.bootrom(
            board.bootrom,
            filesRoot: p.files ?? NSHomeDirectory() + "/Developer/qemu-ios-files"
        )
    )
    return try prepared.configuration(
        hardware: hardware,
        bootArgs: "",
        usbAddress: nil,
        wifi: true,
        guestPackage: nil,
        serial: "file:\(p.serial)",
        audio: ["-audio", "driver=none"],
        netdev: "user,id=wifi0",
        carrier: p.carrier
    )
}

let t0 = Date()
func emit(_ event: String, _ fields: [String: Any] = [:]) {
    var object = fields
    object["event"] = event
    object["t"] = (Date().timeIntervalSince(t0) * 1000).rounded() / 1000
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}
func fail(_ why: String) -> Never {
    emit("fail", ["why": why])
    exit(1)
}

let scenario = try! JSONDecoder().decode(
    Scenario.self,
    from: Data(contentsOf: URL(fileURLWithPath: opts["--scenario"]!))
)
let dumpDir = opts["--dump"] ?? "/tmp"
let queue = DispatchQueue(label: "driver.link")

var logFD: Int32 = -1
if let log = opts["--log"] { logFD = open(log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644) }
var configuration = DeviceLink.Configuration(instance: UUID(), outputDescriptor: logFD)
configuration.helper = URL(fileURLWithPath: opts["--helper"]!)
configuration.dylib = scenario.dylib
configuration.board = scenario.board
configuration.requirement = opts["--requirement"]
if let lease = opts["--lease"] { configuration.arguments = ["--lease", lease] }
let link = DeviceLink(configuration: configuration, queue: queue)

let exitedEvent = DispatchSemaphore(value: 0)
let invalidated = DispatchSemaphore(value: 0)
let terminated = DispatchSemaphore(value: 0)
var noticed: [String: Double] = [:]
let noticeLock = NSLock()
func notice(_ what: String) { noticeLock.withLock { noticed[what] = Date().timeIntervalSince1970 } }
var audioBytes = 0
/// S16 samples of the capture above a quiet floor (|s| > 1000): sound, not silence or dither.
var audioLoud = 0
var watches: [DeviceFileWatch] = []

link.onEvent = { event in
    switch event {
    case .qemuExited(let rc):
        emit("qemuExited", ["code": rc])
        exitedEvent.signal()
    case .audio(_, _, let pcm):
        audioBytes += pcm.count
        pcm.withUnsafeBytes { raw in
            audioLoud += raw.bindMemory(to: Int16.self).reduce(0) { $0 + (abs(Int($1)) > 1000 ? 1 : 0) }
        }
    case .audioEnded(let g, let failed):
        emit("audioEnded", ["generation": g, "failed": failed, "bytes": audioBytes, "loud": audioLoud])
        audioBytes = 0
        audioLoud = 0
    }
}
link.onInvalidated = { error in
    notice("invalidated")
    emit("invalidated", ["error": "\(error)"])
    invalidated.signal()
}
link.onTerminated = { termination in
    notice("terminated")
    emit("terminated", ["termination": "\(termination)"])
    terminated.signal()
}

func sync<T>(_ body: (@escaping (T) -> Void) -> Void) -> T {
    let done = DispatchSemaphore(value: 0)
    var value: T?
    body {
        value = $0
        done.signal()
    }
    done.wait()
    return value!
}

func request(_ r: LinkRequest, timeout: TimeInterval = 10) -> Result<LinkReply, DeviceLinkError> {
    sync { link.request(r, timeout: timeout, reply: $0) }
}

func statusFields() -> [String: Any] {
    guard let s = link.status else { return [:] }
    return [
        "heartbeat": s.heartbeat, "frameSerial": s.frameSerial, "width": s.width, "height": s.height,
        "uiReady": s.uiReady, "storageFailed": s.storageFailed, "shutdownConfirmed": s.shutdownConfirmed,
        "displaySleeping": s.displaySleeping, "agentStatus": s.agentStatus, "glesContexts": s.glesContexts,
        "iconGeneration": s.iconGeneration, "qemuState": s.qemuState.rawValue,
    ]
}

// The display link: sample the ring at 60 Hz, like DisplayView will.
var lastSurface: IOSurface?
var framesSeen = 0
let frameLock = NSLock()
let display = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "driver.display"))
display.schedule(deadline: .now(), repeating: 1.0 / 60)
display.setEventHandler {
    if let f = link.frontSurface(), f.isNew {
        frameLock.withLock {
            lastSurface = f.surface
            framesSeen += 1
        }
    }
}

let started: Result<HelperInfo, DeviceLinkError> = sync { link.start(completion: $0) }
var hardware: DeviceInfo?
switch started {
case .success(let info):
    hardware = info.deviceInfo
    emit(
        "connected",
        [
            "pid": info.pid, "protocol": info.protocolVersion, "dylib": info.dylibPath,
            "dylibModified": info.dylibModified, "buildID": info.buildID ?? "",
            "deviceInfo": info.deviceInfo.map {
                "\($0.machine) \($0.screenWidth)x\($0.screenHeight) scale \($0.screenScale)"
            } ?? "",
            "status": statusFields(),
        ]
    )
case .failure(let error):
    emit("startFailed", ["error": "\(error)"])
    if let text = opts["--expect-failure"] { exit("\(error)".contains(text) ? 0 : 1) }
    exit(opts["--expect-reject"] != nil && "\(error)".contains("rejected") ? 0 : 1)
}
if opts["--expect-reject"] != nil { fail("an impostor was accepted") }
if opts["--expect-failure"] != nil { fail("the start was expected to fail") }
display.resume()

Thread.detachNewThread {
    for step in scenario.steps {
        let p = step.split(separator: " ").map(String.init)
        let v = p.dropFirst().compactMap(Double.init)
        emit("step", ["step": step])
        switch p[0] {
        case "boot":
            let boot: BootConfig
            do { boot = try scenario.boot ?? preparedBoot(scenario.prepared!, hardware: hardware) } catch {
                fail("boot configuration: \(error)")
            }
            emit("argv", ["argv": boot.argv])
            guard case .success(.ok(true)) = request(.boot(boot)) else { fail("boot refused") }
        case "wait":
            usleep(UInt32(v[0] * 1e6))
        case "lit":
            let start = Date()
            var b = 0.0
            while b < v[0] {
                if noticeLock.withLock({ noticed["terminated"] != nil }) {
                    fail("the helper exited before the screen lit")
                }
                if Date().timeIntervalSince(start) > v[1] {
                    dump("never-lit")
                    fail("never lit (brightness \(b))")
                }
                usleep(100_000)
                b = frameLock.withLock { lastSurface }.map(FrameTools.brightness) ?? 0
            }
            emit(
                "lit",
                [
                    "seconds": Date().timeIntervalSince(start), "brightness": b, "frames": framesSeen,
                    "status": statusFields(),
                ]
            )
        case "dump":
            dump(p[1])
        case "tap":
            link.send(.touch(slot: 0, phase: 0, x: v[0], y: v[1]))
            usleep(80_000)
            link.send(.touch(slot: 0, phase: 2, x: v[0], y: v[1]))
        case "drag":
            link.send(.touch(slot: 0, phase: 0, x: v[0], y: v[1]))
            usleep(150_000)
            for i in 1...30 {
                let f = Double(i) / 30
                link.send(.touch(slot: 0, phase: 1, x: v[0] + (v[2] - v[0]) * f, y: v[1] + (v[3] - v[1]) * f))
                usleep(30_000)
            }
            usleep(300_000)
            link.send(.touch(slot: 0, phase: 2, x: v[2], y: v[3]))
        case "button":
            link.send(.button(Int(v[0]), down: true))
            usleep(150_000)
            link.send(.button(Int(v[0]), down: false))
        case "battery":
            emit("reply", ["reply": "\(request(.battery(level: Int(v[0]), charging: Int(v[1]))))"])
        case "modem":  // modem <property> <value…>: qemu_ios_ui_modem_set through the link
            let value = p.dropFirst(2).joined(separator: " ")
            emit("reply", ["reply": "\(request(.modemSet(property: p[1], value: value)))", "modem": p[1]])
        case "modemStatus":  // the status as of the previous poll: poll twice, a beat apart
            _ = request(.modemStatus)
            usleep(300_000)
            if case .success(.modemStatus(let json)) = request(.modemStatus) {
                emit("modemStatus", ["json": json ?? ""])
            } else {
                emit("modemStatus", ["json": ""])
            }
        case "rotate":  // rotate cw|ccw: the app's ⌘-arrow (LinkCommand.rotate)
            link.send(.rotate(clockwise: p[1] == "cw"))
        case "orientation":
            emit("reply", ["reply": "\(request(.orientation(Int(v[0]))))"])
        case "agent":
            let command = p.dropFirst().joined(separator: " ")
            let r = request(.agent(request: "\(UUID().uuidString) exec \(command)\n", deadline: 20), timeout: 25)
            var output = "\(r)"
            if case .success(.agent(let wire?)) = r, let body = wire.split(separator: "\n", maxSplits: 1).last {
                output = String(decoding: Data(base64Encoded: String(body)) ?? Data(), as: UTF8.self)
            }
            emit("agent", ["output": output])
        case "audio":
            guard case .success(.audio(let g)) = request(.audioStart) else {
                emit("audio", ["error": "no capture"])
                break
            }
            usleep(UInt32(v[0] * 1e6))
            link.send(.audioStop(generation: g))
            usleep(1_500_000)
        case "snapshot":
            let start = Date()
            link.send(.snapshotSave(path: p[1]))
            var code = 1
            var error = ""
            while Date().timeIntervalSince(start) < 60 {
                usleep(100_000)
                if case .success(.snapshot(let c, let e)) = request(.snapshotStatus) {
                    code = c
                    error = e ?? ""
                }
                if code >= 2 { break }
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: p[1])[.size] as? Int) ?? -1
            emit(
                "snapshot",
                [
                    "status": code, "error": error, "seconds": Date().timeIntervalSince(start), "bytes": bytes,
                    "glesContexts": link.status?.glesContexts ?? -1,
                ]
            )
            if code != 2 { fail("snapshot failed") }
        case "resume":
            link.send(.snapshotResume)
        case "status":
            emit("status", statusFields())
        case "watch":
            let watch = DeviceFileWatch(directories: [URL(fileURLWithPath: p[1])], base: nil) { path in
                emit("meddled", ["path": path, "notice": DeviceFileWatch.notice(shortName: "iPod")])
            }
            watches.append(watch)
            emit("watching", ["count": watch.count])
        case "shutdown":  // shutdown <seconds>: Shut Down (MachineOp.shutdown), until the guest has powered off
            let start = Date()
            link.send(.machine(.shutdown))
            while link.status?.shutdownConfirmed != true, Date().timeIntervalSince(start) < v[0] { usleep(200_000) }
            emit(
                "shutdown",
                ["confirmed": link.status?.shutdownConfirmed == true, "seconds": Date().timeIntervalSince(start)]
            )
        case "keyboard":  // keyboard on|off: Connect Hardware Keyboard (qemu_ios_ui_hardware_keyboard)
            emit("reply", ["reply": "\(request(.hardwareKeyboard(p[1] == "on")))", "keyboard": p[1]])
        case "sample":  // sample LABEL SECONDS
            let pid = link.pid
            let h0 = link.status?.heartbeat ?? 0
            let f0 = link.status?.frameSerial ?? 0
            let u0 = usage(pid)
            let start = Date()
            usleep(UInt32(v[0] * 1e6))
            let u1 = usage(pid)
            let s = Date().timeIntervalSince(start)
            let h1 = link.status?.heartbeat ?? 0
            let f1 = link.status?.frameSerial ?? 0
            emit(
                "sample",
                [
                    "label": p[1], "seconds": s, "hz": Double(h1 &- h0) / s, "fps": Double(f1 &- f0) / s,
                    "cpuPercent": (u1.cpu - u0.cpu) / s * 100, "wakeupsPerSecond": Double(u1.wakeups &- u0.wakeups) / s,
                    "milliwatts": Double(u1.energy &- u0.energy) / s / 1e6, "preventsIdleSleep": preventsIdleSleep(pid),
                    "displaySleeping": link.status?.displaySleeping ?? false,
                ]
            )
        case "visible":  // visible on|off
            let h0 = link.status?.heartbeat ?? 0
            let f0 = link.status?.frameSerial ?? 0
            let start = Date()
            link.send(.screenVisible(p[1] == "on"))
            var tick: Double?
            var frame: Double?
            while Date().timeIntervalSince(start) < 1, tick == nil || frame == nil {
                let ms = Date().timeIntervalSince(start) * 1000
                if tick == nil, (link.status?.heartbeat ?? 0) &- h0 >= 3 { tick = ms }
                if frame == nil, (link.status?.frameSerial ?? 0) != f0 { frame = ms }
                usleep(500)
            }
            emit("visible", ["on": p[1] == "on", "tickMs": tick ?? -1, "frameMs": frame ?? -1])
        case "waitSleep":  // waitSleep SECONDS: until the guest's display is asleep
            let start = Date()
            while link.status?.displaySleeping != true, Date().timeIntervalSince(start) < v[0] { usleep(200_000) }
            emit(
                "waitSleep",
                ["sleeping": link.status?.displaySleeping == true, "seconds": Date().timeIntervalSince(start)]
            )
        case "quit":
            link.send(.machine(.quit))
        case "expectExit":
            guard exitedEvent.wait(timeout: .now() + v[0]) == .success,
                terminated.wait(timeout: .now() + 5) == .success
            else { fail("no qemuExited + termination") }
        case "hold":
            emit("hold", ["helperPid": link.pid, "driverPid": getpid()])
            while true { sleep(60) }
        case "killHelper":
            let killed = Date().timeIntervalSince1970
            kill(link.pid, SIGKILL)
            guard invalidated.wait(timeout: .now() + 5) == .success,
                terminated.wait(timeout: .now() + 5) == .success
            else { fail("the client did not notice the helper's death") }
            let n = noticeLock.withLock { noticed }
            emit(
                "noticed",
                [
                    "invalidatedMs": ((n["invalidated"] ?? 0) - killed) * 1000,
                    "terminatedMs": ((n["terminated"] ?? 0) - killed) * 1000,
                ]
            )
        default:
            fail("unknown step \(step)")
        }
    }
    emit("done")
    exit(0)
}

/// The helper's CPU seconds, wakeups and energy (nJ) so far.
func usage(_ pid: Int32) -> (cpu: Double, wakeups: UInt64, energy: UInt64) {
    var info = rusage_info_v6()
    let rc = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
    }
    guard rc == 0 else { return (0, 0, 0) }
    var base = mach_timebase_info_data_t()
    mach_timebase_info(&base)
    let cpu = Double(info.ri_user_time + info.ri_system_time) * Double(base.numer) / Double(base.denom) / 1e9
    return (cpu, info.ri_pkg_idle_wkups + info.ri_interrupt_wkups, info.ri_energy_nj)
}

/// pmset lists the helper as preventing idle system sleep.
func preventsIdleSleep(_ pid: Int32) -> Bool {
    let p = Process()
    let out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g", "assertions"]
    p.standardOutput = out
    guard (try? p.run()) != nil else { return false }
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return text.split(separator: "\n").contains {
        $0.contains("pid \(pid)(") && $0.contains("PreventUserIdleSystemSleep")
    }
}

func dump(_ name: String) {
    guard let surface = frameLock.withLock({ lastSurface }) else { return emit("dump", ["name": name, "ok": false]) }
    let url = URL(fileURLWithPath: "\(dumpDir)/\(name).png")
    emit(
        "dump",
        [
            "name": name, "path": url.path, "ok": FrameTools.writePNG(surface, to: url),
            "brightness": FrameTools.brightness(surface), "width": surface.width, "height": surface.height,
        ]
    )
}

while true { CFRunLoopRun() }
