import Foundation

/// The fake carrier network a radio board's modem offers (qemu-ios hw/misc/ios_baseband.c): what the Carrier panel
/// edits, persists per device and applies at every boot as `-global ios-baseband.<property>=…`. Synthetic values only;
/// the defaults are the 3GPP test network (MCC/MNC 001/01). The validators are the modem's own rules, so a value the
/// panel accepts is one the modem accepts.
public struct CarrierSettings: Codable, Equatable, Sendable {
    public var carrier = "Test Network"
    /// MCC (3 digits) + MNC (2 or 3 digits).
    public var mccMNC = "00101"
    public var registered = true
    public var simPresent = true
    /// Status-bar bars, 0...5 (signalDBM maps them onto the modem's dBm).
    public var bars = 5

    public init() {}

    /// The modem reports rssi = (dBm + 113) / 2, 0...31; iOS draws its bars from rssi.
    public static func signalDBM(bars: Int) -> Int { [-113, -103, -97, -89, -81, -63][max(0, min(5, bars))] }
    /// The bars a dBm value shows, the inverse of signalDBM (the nearest step at or below it).
    public static func bars(signalDBM dbm: Int) -> Int {
        (0...5).last { signalDBM(bars: $0) <= dbm } ?? 0
    }

    public var signalDBM: Int { Self.signalDBM(bars: bars) }

    /// The modem's properties for these settings, in the order a boot applies them.
    public var properties: [(name: String, value: String)] {
        [("carrier", carrier), ("mcc-mnc", mccMNC), ("registered", registered ? "on" : "off"),
         ("sim-present", simPresent ? "on" : "off"), ("signal-dbm", String(signalDBM))]
    }

    /// `-global` arguments that start the modem with these settings (any board's: M68's, N88's, N90's).
    /// Each is one argv element, and -global takes everything after the first '=' as the value verbatim
    /// (no comma escaping, unlike -M), so a carrier name with a comma passes as typed.
    public var globals: [String] {
        properties.flatMap { ["-global", "ios-baseband.\($0.name)=\($0.value)"] }
    }

    public var isValid: Bool { Self.carrierOK(carrier) && Self.plmnOK(mccMNC) && (0...5).contains(bars) }

    // MARK: The modem's rules (ios_bb_carrier_ok, ios_bb_plmn_ok, ios_bb_sms_sender_ok)

    /// 1-32 bytes of printable ASCII-or-UTF-8, no '"' (it goes out quoted in +COPS/+XCOPS).
    public static func carrierOK(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        return !bytes.isEmpty && bytes.count <= 32 && !bytes.contains { $0 < 0x20 || $0 == 0x7F || $0 == 0x22 }
    }

    /// 5 or 6 digits: MCC + a 2- or 3-digit MNC.
    public static func plmnOK(_ s: String) -> Bool {
        (s.count == 5 || s.count == 6) && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// An SMS sender or caller: 1-20 digits, optionally after a '+'.
    public static func numberOK(_ s: String) -> Bool {
        let digits = s.hasPrefix("+") ? s.dropFirst() : Substring(s)
        return !digits.isEmpty && digits.count <= 20 && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// An incoming SMS body: non-empty, no NUL (the modem's property is a C string), at most 160 characters,
    /// one SMS-DELIVER's worth of GSM 7-bit text.
    public static func smsTextOK(_ s: String) -> Bool { !s.isEmpty && s.count <= 160 && !s.contains("\0") }
}

/// The modem's state as `qemu_ios_ui_modem_status` reports it (a JSON object).
public struct ModemStatus: Equatable, Sendable {
    public var carrier = "", mccMNC = "", callState = "idle", lastDialed = ""
    public var registered = false, simPresent = false
    public var signalDBM = -113, moSMSCount = 0
    /// The last outgoing SMS: destination and text.
    public var lastMOSMS: (number: String, text: String)? = nil
    /// The modem's refusal of the last write, if it refused it.
    public var error: String?

    public init() {}

    public init?(json: String) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        carrier = o["carrier"] as? String ?? ""
        mccMNC = o["mcc-mnc"] as? String ?? ""
        callState = o["call-state"] as? String ?? "idle"
        lastDialed = o["last-dialed"] as? String ?? ""
        registered = o["registered"] as? Bool ?? false
        simPresent = o["sim-present"] as? Bool ?? false
        signalDBM = o["signal-dbm"] as? Int ?? -113
        moSMSCount = o["mo-sms-count"] as? Int ?? 0
        error = o["error"] as? String
        if let mo = o["last-mo-sms"] as? String, let bar = mo.firstIndex(of: "|"), mo.count > 1 {
            lastMOSMS = (String(mo[..<bar]), String(mo[mo.index(after: bar)...]))
        }
    }

    public static func == (a: ModemStatus, b: ModemStatus) -> Bool {
        a.carrier == b.carrier && a.mccMNC == b.mccMNC && a.callState == b.callState && a.lastDialed == b.lastDialed
            && a.registered == b.registered && a.simPresent == b.simPresent && a.signalDBM == b.signalDBM
            && a.moSMSCount == b.moSMSCount && a.error == b.error
            && a.lastMOSMS?.number == b.lastMOSMS?.number && a.lastMOSMS?.text == b.lastMOSMS?.text
    }
}
