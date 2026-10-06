// The Carrier panel: the fake cellular network of a running iPhone (M68, N88, N90), its calls and its SMS.
// Network settings are the device's (EmulatorController.carrierSettings, applied at every boot); calls and SMS go
// straight to the modem (qemu-ios ios-baseband's actions), and its state is polled once a second while visible.

import Cocoa
import HostRuntime
import SwiftUI

/// What the panel drives: the running device's modem.
@MainActor protocol CarrierBackend: AnyObject {
    var carrierSettings: CarrierSettings { get }
    @discardableResult func setCarrierSettings(_ settings: CarrierSettings) -> Bool
    func modem(_ property: String, _ value: String, done: @escaping (Bool) -> Void)
    func modemStatus(_ done: @escaping (ModemStatus?) -> Void)
}

extension EmulatorController: CarrierBackend {}

@MainActor @Observable final class CarrierPanelModel {
    struct SentSMS: Identifiable, Equatable { let id: Int; let number: String; let text: String }

    @ObservationIgnored private let backend: CarrierBackend
    var settings: CarrierSettings
    /// The network fields as typed; applied (validated) with Apply.
    var carrierName: String
    var mcc: String
    var mnc: String
    var callNumber = "+15555550100"
    var smsNumber = "+15555550100"
    var smsText = ""
    private(set) var status: ModemStatus?
    private(set) var sent: [SentSMS] = []
    /// The last thing the panel or the modem refused.
    private(set) var message: String?
    @ObservationIgnored private var lastMOCount: Int?

    init(backend: CarrierBackend) {
        self.backend = backend
        settings = backend.carrierSettings
        carrierName = backend.carrierSettings.carrier
        mcc = String(backend.carrierSettings.mccMNC.prefix(3))
        mnc = String(backend.carrierSettings.mccMNC.dropFirst(3))
    }

    var typedPLMN: String { mcc + mnc }
    var networkValid: Bool { CarrierSettings.carrierOK(carrierName) && mcc.count == 3 && CarrierSettings.plmnOK(typedPLMN) }
    var networkEdited: Bool { carrierName != settings.carrier || typedPLMN != settings.mccMNC }

    func applyNetwork() {
        guard networkValid else { return message = "Carrier names are 1–32 characters without quotes; MCC is 3 digits and MNC 2 or 3." }
        var s = settings
        s.carrier = carrierName
        s.mccMNC = typedPLMN
        save(s)
    }

    func set(registered: Bool) { var s = settings; s.registered = registered; save(s) }
    func set(simPresent: Bool) { var s = settings; s.simPresent = simPresent; save(s) }
    func set(bars: Int) { var s = settings; s.bars = bars; save(s) }

    private func save(_ s: CarrierSettings) {
        if backend.setCarrierSettings(s) { settings = s; message = nil }
    }

    var callNumberValid: Bool { CarrierSettings.numberOK(callNumber) }
    var smsValid: Bool { CarrierSettings.numberOK(smsNumber) && CarrierSettings.smsTextOK(smsText) }
    var callState: String { status?.callState ?? "idle" }
    var canRing: Bool { callNumberValid && callState == "idle" && settings.registered && settings.simPresent }
    var canAnswer: Bool { callState == "dialing" || callState == "alerting" }
    var canHangUp: Bool { callState != "idle" }

    func ring() {
        guard callNumberValid else { return message = "A caller is 1–20 digits, optionally after a +." }
        backend.modem("incoming-call", callNumber) { [weak self] ok in if !ok { self?.message = "The modem isn’t available." } }
    }

    func answer() { backend.modem("remote-answer", "1") { _ in } }
    func hangUp() { backend.modem("remote-hangup", "1") { _ in } }

    func sendSMS() {
        guard smsValid else { return message = "A sender is 1–20 digits, optionally after a +; the text 1–160 characters." }
        backend.modem("incoming-sms", "\(smsNumber)|\(smsText)") { [weak self] ok in
            if ok { self?.smsText = "" } else { self?.message = "The modem isn’t available." }
        }
    }

    /// One poll: the modem's state, its refusal of the last write, and any SMS the phone sent since the last poll.
    func poll() {
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

struct CarrierPanel: View {
    @Bindable var model: CarrierPanelModel

    var body: some View {
        Form {
            Section("Network") {
                TextField("Carrier", text: $model.carrierName)
                LabeledContent("MCC / MNC") {
                    HStack {
                        TextField("MCC", text: $model.mcc, prompt: Text("001")).labelsHidden().frame(width: 56)
                        Text("/").foregroundStyle(.secondary)
                        TextField("MNC", text: $model.mnc, prompt: Text("01")).labelsHidden().frame(width: 56)
                        Button("Apply") { model.applyNetwork() }
                            .disabled(!model.networkEdited || !model.networkValid)
                    }
                }
                Toggle("Registered", isOn: Binding(get: { model.settings.registered }, set: { model.set(registered: $0) }))
                Toggle("SIM Present", isOn: Binding(get: { model.settings.simPresent }, set: { model.set(simPresent: $0) }))
                LabeledContent("Signal") {
                    HStack {
                        Slider(value: Binding(get: { Double(model.settings.bars) }, set: { model.set(bars: Int($0.rounded())) }),
                               in: 0...5, step: 1)
                        Text("\(model.settings.bars) bars").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Section("Calls") {
                HStack {
                    TextField("Caller", text: $model.callNumber)
                    Button("Ring") { model.ring() }.disabled(!model.canRing)
                }
                HStack {
                    Button("Answer") { model.answer() }.disabled(!model.canAnswer)
                        .help("The other end picks up the call the phone is making")
                    Button("Hang Up") { model.hangUp() }.disabled(!model.canHangUp)
                        .help("The other end ends the call, ringing or connected")
                }
                LabeledContent("State", value: model.callState.capitalized)
                LabeledContent("Last Dialed", value: model.status?.lastDialed.isEmpty == false ? model.status!.lastDialed : "—")
            }
            Section("SMS") {
                TextField("From", text: $model.smsNumber)
                HStack {
                    TextField("Message", text: $model.smsText).onSubmit { model.sendSMS() }
                    Button("Send") { model.sendSMS() }.disabled(!model.smsValid)
                }
                if model.sent.isEmpty {
                    Text("Messages the phone sends appear here.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.sent) { sms in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("To \(sms.number)").font(.caption).foregroundStyle(.secondary)
                            Text(sms.text).textSelection(.enabled)
                        }
                    }
                }
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, idealWidth: 380, minHeight: 520)
        .task {
            // ~1 Hz while the panel is on screen; SwiftUI cancels it when the view goes away.
            while !Task.isCancelled {
                model.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// A Carrier panel per running device: a utility panel that floats above the device window.
@MainActor final class CarrierWindowController: NSWindowController {
    init(emulator: EmulatorController) {
        let hosting = NSHostingController(rootView: CarrierPanel(model: CarrierPanelModel(backend: emulator)))
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable, .resizable, .utilityWindow]
        panel.title = "Carrier — \(emulator.instance.name)"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.setFrameAutosaveName("CarrierPanel")
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

#if DEBUG
@MainActor private final class PreviewBackend: CarrierBackend {
    var carrierSettings = CarrierSettings()
    func setCarrierSettings(_ settings: CarrierSettings) -> Bool { carrierSettings = settings; return true }
    func modem(_ property: String, _ value: String, done: @escaping (Bool) -> Void) { done(true) }
    func modemStatus(_ done: @escaping (ModemStatus?) -> Void) {
        done(ModemStatus(json: #"{"carrier": "LightTouch", "mcc-mnc": "00101", "call-state": "incoming", "last-dialed": "15555550123", "#
            + #""last-mo-sms": "15555550100|On my way", "registered": true, "sim-present": true, "signal-dbm": -63, "mo-sms-count": 1}"#))
    }
}

#Preview("Carrier") {
    CarrierPanel(model: CarrierPanelModel(backend: PreviewBackend()))
        .frame(width: 380, height: 640)
}
#endif
