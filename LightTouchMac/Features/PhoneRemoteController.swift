// Device ▸ Play on Phone…: a phone's browser shows the selected device's screen, takes its touches and tilts
// it with the phone's own orientation. One HTTPS port serves the page (phone-remote.html) and its WebSocket under a
// self-signed certificate the phone accepts once (browsers give motion only to secure pages); the token in the QR
// code's address keeps other browsers on the network out. The math is LightTouchCore's PhoneRemote.

import Cocoa
import CoreImage
import DeviceRuntime
import LightTouchCore
import Network

@MainActor final class PhoneRemoteController {
    /// The device window; the QR code and errors go on it as sheets.
    weak var window: NSWindow?
    /// The selected device, nil when none runs.
    var session: () -> DeviceSession? = { nil }
    var isRunning: Bool { listener != nil }

    private static let port: NWEndpoint.Port = 9741
    private var listener: NWListener?
    private var client: NWConnection?
    private var timer: Timer?
    /// The frame and turn last sent, so a still screen sends nothing.
    private var sent: (serial: UInt64, turns: Int)?
    private var sending = false
    private var turns = 0
    /// The device whose screen the phone shows: it keeps its helper at full frame rate (phoneShowsScreen).
    private weak var shownOn: DeviceViewController?

    private var screen: DisplayView? { session()?.workspace.deviceVC.screen }

    /// Play on Phone… starts serving and shows the QR code; Stop Playing on Phone stops.
    func toggle() {
        guard listener == nil else { return stop() }
        guard let window else { return }
        do {
            makeAlert(url: try start()).beginSheetModal(for: window)
        } catch {
            show(error)
        }
    }

    /// Kept across launches, so the page added to a phone's Home Screen keeps connecting.
    private static let token: String = {
        if let token = UserDefaults.standard.string(forKey: "phoneRemoteToken") { return token }
        let token = UUID().uuidString
        UserDefaults.standard.set(token, forKey: "phoneRemoteToken")
        return token
    }()

    private func start() throws -> URL {
        guard let address = Self.lanAddress(), let url = URL(string: "https://\(address):\(Self.port)/#\(Self.token)")
        else { throw PhoneRemoteError.noNetwork }
        let listener = try NWListener(using: NWParameters(tls: try Self.tlsOptions()), on: Self.port)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        // The port can turn out to be taken only once listening starts; the error follows the QR code.
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .failed(let error) = state else { return }
            MainActor.assumeIsolated {
                stop()
                show(error)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        return url
    }

    func stop() {
        disconnect()
        listener?.cancel()
        listener = nil
    }

    private func show(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(connection, Data())
    }

    /// Reads one request's head: `/` gets the page, `/ws?t=<token>` the WebSocket; anything else is closed.
    private func receiveRequest(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self, let data, error == nil else { return connection.cancel() }
            MainActor.assumeIsolated {
                let buffer = buffer + data
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    return buffer.count < 16384 && !done ? receiveRequest(connection, buffer) : connection.cancel()
                }
                respond(connection, to: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            }
        }
    }

    private func respond(_ connection: NWConnection, to head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init)
        let key = lines.lazy.compactMap { line -> String? in
            let field = line.split(separator: ":", maxSplits: 1)
            guard field.count == 2, field[0].lowercased() == "sec-websocket-key" else { return nil }
            return field[1].trimmingCharacters(in: .whitespaces)
        }.first
        if path == "/ws?t=\(Self.token)", let key {
            let upgrade =
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(WebSocket.acceptKey(key))\r\n\r\n"
            connection.send(content: Data(upgrade.utf8), completion: .idempotent)
            // One phone at a time: the newest wins.
            disconnect()
            client = connection
            receiveMessages(connection, Data())
            // In the common modes, so an open menu or a live resize doesn't freeze the phone's picture.
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendFrame() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if path == "/", let url = Bundle.main.url(forResource: "phone-remote", withExtension: "html"),
            let page = try? Data(contentsOf: url)
        {
            let head =
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.count)\r\n"
                + "Connection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + page, completion: .contentProcessed { _ in connection.cancel() })
        } else {
            connection.cancel()
        }
    }

    // MARK: - The phone

    private func receiveMessages(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return connection.cancel() }
            MainActor.assumeIsolated {
                guard connection === client else { return connection.cancel() }
                var buffer = buffer + (data ?? Data())
                do {
                    while let frame = try WebSocket.nextFrame(&buffer) {
                        switch frame.opcode {
                        case .text: handle(frame.payload)
                        case .close: return disconnect()
                        case .binary: break
                        }
                    }
                } catch {
                    return disconnect()
                }
                guard error == nil, !done else { return disconnect() }
                receiveMessages(connection, buffer)
            }
        }
    }

    /// `{"tilt":[beta,gamma]}` (deviceorientation's degrees), `{"touch":[phase,x,y]}` (TouchPhase; normalized on the
    /// picture, y down) or `{"home":true}`.
    private struct Message: Decodable {
        var tilt: [Double]?
        var touch: [Double]?
        var home: Bool?
    }

    private func handle(_ payload: Data) {
        guard let message = try? JSONDecoder().decode(Message.self, from: payload), let emulator = session()?.emulator
        else { return }
        if let tilt = message.tilt, tilt.count == 2, tilt.allSatisfy(\.isFinite), emulator.acceptsInput,
            !emulator.isSleeping
        {
            emulator.link?.send(PhoneRemote.attitude(beta: tilt[0], gamma: tilt[1]))
        }
        if let touch = message.touch, touch.count == 3, [0, 1, 2].contains(touch[0]), touch.allSatisfy(\.isFinite) {
            let p = PhoneRemote.surfacePoint(
                CGPoint(x: min(max(touch[1], 0), 1), y: min(max(touch[2], 0), 1)),
                turns: turns
            )
            screen?.sendVisualTouch(0, Int32(touch[0]), p.x, p.y)
        }
        if message.home == true { emulator.pressHome() }
    }

    /// The newest frame, turned the way the device is held, when it changed and the last one has gone out.
    /// JPEG on the main thread costs a few milliseconds at these panel sizes; H.264 (VideoToolbox) only if it shows.
    private func sendFrame() {
        let deviceVC = session()?.workspace.deviceVC
        if deviceVC !== shownOn {
            shownOn?.phoneShowsScreen = false
            deviceVC?.phoneShowsScreen = true
            shownOn = deviceVC
        }
        guard let client, !sending, let emulator = session()?.emulator, let screen = deviceVC?.screen,
            let surface = screen.currentFrame()
        else { return }
        turns = PhoneRemote.quarterTurns(
            guestTurn: screen.guestTurn,
            deviceDegrees: emulator.rotationDegrees,
            surfaceFollowsRotation: emulator.profile.surfaceFollowsRotation
        )
        guard sent?.serial != screen.shownSerial || sent?.turns != turns,
            let image = DisplayView.image(surface, colorSpace: screen.colorSpace),
            let turned = PanelCapture.rotated(image, clockwiseQuarterTurns: turns),
            let jpeg = NSBitmapImageRep(cgImage: turned)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        else { return }
        sent = (screen.shownSerial, turns)
        sending = true
        client.send(
            content: WebSocket.frame(jpeg, .binary),
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                MainActor.assumeIsolated {
                    guard client === self.client else { return }
                    sending = false
                    if error != nil { disconnect() }
                }
            }
        )
    }

    /// Drops the phone; the device's gravity goes back to rest and its helper may slow down again.
    private func disconnect() {
        guard let client else { return }
        client.cancel()
        self.client = nil
        timer?.invalidate()
        timer = nil
        sent = nil
        sending = false
        shownOn?.phoneShowsScreen = false
        shownOn = nil
        screen?.resetMotion()
    }

    // MARK: - Setup

    /// The sheet with the QR code.
    private func makeAlert(url: URL) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Scan with Your Phone"
        alert.informativeText =
            "Open \(url.absoluteString) on a phone on the same network. Continue past its warning that the "
            + "connection isn’t private, then tap Start."
        let qrCode = CIFilter(
            name: "CIQRCodeGenerator",
            parameters: ["inputMessage": Data(url.absoluteString.utf8)]
        )?
        .outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        if let qrCode {
            let rep = NSCIImageRep(ciImage: qrCode)
            let image = NSImage(size: rep.size)
            image.addRepresentation(rep)
            let view = NSImageView(image: image)
            view.frame.size = rep.size
            alert.accessoryView = view
        }
        return alert
    }

    /// The Mac's IPv4 address on Wi-Fi or Ethernet (the en interfaces): the one a phone shares a network with. Not a
    /// self-assigned 169.254 one, which an interface without DHCP has and no phone reaches.
    private static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                interface.ifa_flags & UInt32(IFF_UP) != 0, String(cString: interface.ifa_name).hasPrefix("en")
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let name = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !name.hasPrefix("169.254.") { return name }
        }
        return nil
    }

    private static let passphrase = "light-touch"

    /// TLS with this Mac's self-signed identity, made with the system's openssl the first time and again before it
    /// runs out: Apple's rules for server certificates (at most 825 days, serverAuth) are why it says what it says.
    private static func tlsOptions() throws -> NWProtocolTLS.Options {
        let folder = Bundled.stateDirectory.appendingPathComponent("phone-remote", isDirectory: true)
        let p12 = folder.appendingPathComponent("identity.p12")
        let created = try? p12.resourceValues(forKeys: [.creationDateKey]).creationDate
        if created.map({ -$0.timeIntervalSinceNow > 800 * 86400 }) ?? true { try makeIdentity(p12) }
        var options: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
        // Before macOS 15 SecPKCS12Import can only add the identity to the login keychain.
        if #available(macOS 15, *) { options[kSecImportToMemoryOnly as String] = true }
        var items: CFArray?
        // The identity is always a SecIdentity; Swift can't check a CF type conditionally.
        guard SecPKCS12Import(try Data(contentsOf: p12) as CFData, options as CFDictionary, &items) == errSecSuccess,
            let found = (items as? [[String: Any]])?.first?[kSecImportItemIdentity as String],
            let identity = sec_identity_create(found as! SecIdentity)
        else { throw PhoneRemoteError.noCertificate }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        return tls
    }

    /// Runs openssl on the main thread: once, on the first Play on Phone…, for about a tenth of a second. RSA, not EC:
    /// macOS 27's SecPKCS12Import raises an exception (a NULL key in SecIdentityCreate) on LibreSSL's EC key bags.
    private static func makeIdentity(_ p12: URL) throws {
        let folder = p12.deletingLastPathComponent()
        try StorageLocations.privateDirectory(folder)
        let key = folder.appendingPathComponent("key.pem").path
        let certificate = folder.appendingPathComponent("certificate.pem").path
        defer { for path in [key, certificate] { try? FileManager.default.removeItem(atPath: path) } }
        try openssl([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "825",
            "-subj", "/CN=Light Touch", "-addext", "subjectAltName=DNS:lighttouch.local",
            "-addext", "extendedKeyUsage=serverAuth", "-keyout", key, "-out", certificate,
        ])
        try? FileManager.default.removeItem(at: p12)
        try openssl([
            "pkcs12", "-export", "-inkey", key, "-in", certificate, "-passout", "pass:\(passphrase)", "-out", p12.path,
        ])
    }

    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PhoneRemoteError.noCertificate }
    }
}

nonisolated enum PhoneRemoteError: LocalizedError {
    case noNetwork, noCertificate
    var errorDescription: String? {
        switch self {
        case .noNetwork: "This Mac isn’t on a Wi-Fi or Ethernet network a phone could join."
        case .noCertificate: "Light Touch couldn’t make the certificate the phone connects with."
        }
    }
}
