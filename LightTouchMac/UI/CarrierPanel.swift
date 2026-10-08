// The Carrier panel: the fake cellular network of a running iPhone (M68, N88, N90), its calls and its SMS.
// Network settings are the device's (EmulatorController.carrierSettings, applied at every boot); calls and SMS go
// straight to the modem (qemu-ios ios-baseband's actions), and its state is polled once a second while visible.

import Cocoa
import HostRuntime
import LightTouchCore
import SwiftUI

extension EmulatorController: CarrierBackend {}

struct CarrierPanel: View {
    @Bindable var model: CarrierPanelModel

    var body: some View {
        Form {
            Section {
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
                if model.applyingNetwork {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Applying…").foregroundStyle(.secondary)
                    }
                }
                Toggle(
                    "Registered",
                    isOn: Binding(get: { model.settings.registered }, set: { model.set(registered: $0) })
                )
                Toggle(
                    "SIM Present",
                    isOn: Binding(get: { model.settings.simPresent }, set: { model.set(simPresent: $0) })
                )
                LabeledContent("Signal") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(model.settings.bars) },
                                set: { model.set(bars: Int($0.rounded())) }
                            ),
                            in: 0...5,
                            step: 1
                        )
                        Text("\(model.settings.bars) bars").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Network")
            } footer: {
                Text("Signal indicator may take a moment to update.")
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
                LabeledContent(
                    "Last Dialed",
                    value: (model.status?.lastDialed).flatMap { $0.isEmpty ? nil : $0 } ?? "—"
                )
            }
            Section("SMS") {
                TextField("From", text: $model.smsNumber)
                HStack(alignment: .bottom) {
                    TextField("Message", text: $model.smsText, prompt: Text("Type your SMS…"), axis: .vertical)
                        .labelsHidden().lineLimit(3...6).onSubmit { model.sendSMS() }
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
        func setCarrierSettings(_ settings: CarrierSettings) -> Bool {
            carrierSettings = settings
            return true
        }
        func modem(_ property: String, _ value: String, done: @escaping @MainActor (Bool) -> Void) { done(true) }
        func modemStatus(_ done: @escaping @MainActor (ModemStatus?) -> Void) {
            done(
                ModemStatus(
                    json:
                        #"{"carrier": "Light Touch", "mcc-mnc": "00101", "call-state": "incoming", "last-dialed": "15555550123", "#
                        + #""last-mo-sms": "15555550100|On my way", "registered": true, "sim-present": true, "signal-dbm": -63, "mo-sms-count": 1}"#
                )
            )
        }
    }

    #Preview("Carrier") {
        CarrierPanel(model: CarrierPanelModel(backend: PreviewBackend()))
            .frame(width: 380, height: 640)
    }
#endif
