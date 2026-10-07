// The Carrier panel's model (CarrierPanel is its view): the network settings as typed and applied, calls and SMS,
// and the modem's state polled while the panel is visible.

import HostRuntime
import Observation

/// What the panel drives: the running device's modem.
@MainActor public protocol CarrierBackend: AnyObject {
    var carrierSettings: CarrierSettings { get }
    @discardableResult func setCarrierSettings(_ settings: CarrierSettings) -> Bool
    func modem(_ property: String, _ value: String, done: @escaping @MainActor (Bool) -> Void)
    func modemStatus(_ done: @escaping @MainActor (ModemStatus?) -> Void)
}


@MainActor @Observable public final class CarrierPanelModel {
    public struct SentSMS: Identifiable, Equatable { public let id: Int; public let number: String; public let text: String }

    @ObservationIgnored private let backend: CarrierBackend
    public var settings: CarrierSettings
    /// The network fields as typed; applied (validated) with Apply.
    public var carrierName: String
    public var mcc: String
    public var mnc: String
    public var callNumber = "+15555550100"
    public var smsNumber = "+15555550100"
    public var smsText = ""
    public private(set) var status: ModemStatus?
    public private(set) var sent: [SentSMS] = []
    /// The last thing the panel or the modem refused.
    public private(set) var message: String?
    @ObservationIgnored private var lastMOCount: Int?

    public init(backend: CarrierBackend) {
        self.backend = backend
        settings = backend.carrierSettings
        carrierName = backend.carrierSettings.carrier
        mcc = String(backend.carrierSettings.mccMNC.prefix(3))
        mnc = String(backend.carrierSettings.mccMNC.dropFirst(3))
    }

    public var typedPLMN: String { mcc + mnc }
    public var networkValid: Bool { CarrierSettings.carrierOK(carrierName) && mcc.count == 3 && CarrierSettings.plmnOK(typedPLMN) }
    public var networkEdited: Bool { carrierName != settings.carrier || typedPLMN != settings.mccMNC }
    /// An applied carrier or PLMN the modem doesn't report yet.
    public var applyingNetwork: Bool {
        guard let status else { return false }
        return status.carrier != settings.carrier || status.mccMNC != settings.mccMNC
    }

    public func applyNetwork() {
        guard networkValid else { return message = "Carrier names are 1–32 characters without quotes; MCC is 3 digits and MNC 2 or 3." }
        var s = settings
        s.carrier = carrierName
        s.mccMNC = typedPLMN
        save(s)
    }

    public func set(registered: Bool) { var s = settings; s.registered = registered; save(s) }
    public func set(simPresent: Bool) { var s = settings; s.simPresent = simPresent; save(s) }
    public func set(bars: Int) { var s = settings; s.bars = bars; save(s) }

    private func save(_ s: CarrierSettings) {
        if backend.setCarrierSettings(s) { settings = s; message = nil }
    }

    public var callNumberValid: Bool { CarrierSettings.numberOK(callNumber) }
    public var smsValid: Bool { CarrierSettings.numberOK(smsNumber) && CarrierSettings.smsTextOK(smsText) }
    public var callState: String { status?.callState ?? "idle" }
    public var canRing: Bool { callNumberValid && callState == "idle" && settings.registered && settings.simPresent }
    public var canAnswer: Bool { callState == "dialing" || callState == "alerting" }
    public var canHangUp: Bool { callState != "idle" }

    public func ring() {
        guard callNumberValid else { return message = "A caller is 1–20 digits, optionally after a +." }
        backend.modem("incoming-call", callNumber) { [weak self] ok in if !ok { self?.message = "The modem isn’t available." } }
    }

    public func answer() { backend.modem("remote-answer", "1") { _ in } }
    public func hangUp() { backend.modem("remote-hangup", "1") { _ in } }

    public func sendSMS() {
        guard smsValid else { return message = "A sender is 1–20 digits, optionally after a +; the text 1–160 characters." }
        backend.modem("incoming-sms", "\(smsNumber)|\(smsText)") { [weak self] ok in
            if ok { self?.smsText = "" } else { self?.message = "The modem isn’t available." }
        }
    }

    /// One poll: the modem's state, its refusal of the last write, and any SMS the phone sent since the last poll.
    public func poll() {
        backend.modemStatus { [weak self] status in
            guard let self, let status else { return }
            self.status = status
            if let error = status.error { self.message = error }
            if let last = lastMOCount, status.moSMSCount > last, let mo = status.lastMOSMS {
                sent.insert(SentSMS(id: status.moSMSCount, number: mo.number, text: mo.text), at: 0)
                sent = Array(sent.prefix(20))
            }
            lastMOCount = status.moSMSCount
        }
    }
}

