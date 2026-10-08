import HostRuntime
import Testing

@testable import LightTouchCore

/// A modem that reports what it's told to report.
@MainActor private final class Modem: CarrierBackend {
    var carrierSettings = CarrierSettings()
    var reported = ModemStatus()
    var actions: [String] = []
    func setCarrierSettings(_ settings: CarrierSettings) -> Bool {
        carrierSettings = settings
        return true
    }
    func modem(_ property: String, _ value: String, done: @escaping @MainActor (Bool) -> Void) {
        actions.append("\(property)=\(value)")
        done(true)
    }
    func modemStatus(_ done: @escaping @MainActor (ModemStatus?) -> Void) { done(reported) }
}

/// The Carrier panel's model against a fake modem: Applying… until the modem reports the applied carrier and PLMN,
/// validation before anything is sent, and the phone's outgoing SMS.
struct CarrierPanelModelTests {
    @Test func applyingUntilTheModemReportsTheNewNetwork() {
        let modem = Modem()
        modem.reported.carrier = modem.carrierSettings.carrier
        modem.reported.mccMNC = modem.carrierSettings.mccMNC
        let model = CarrierPanelModel(backend: modem)
        #expect(!model.applyingNetwork, "nothing polled yet")
        model.poll()
        #expect(!model.applyingNetwork, "applying before any change")
        model.carrierName = "Fictional"
        #expect(model.networkEdited && model.networkValid)
        model.applyNetwork()
        #expect(modem.carrierSettings.carrier == "Fictional" && !model.networkEdited)
        model.poll()
        #expect(model.applyingNetwork, "no progress while the modem still reports the old carrier")
        modem.reported.carrier = "Fictional"
        modem.reported.mccMNC = modem.carrierSettings.mccMNC
        model.poll()
        #expect(!model.applyingNetwork, "still applying once the modem reports it")
    }

    @Test func aReplacedSessionTakesThePanelOver() throws {
        let old = Modem()
        let model = CarrierPanelModel(backend: old)
        model.poll()
        let new = Modem()
        new.carrierSettings.carrier = "Restarted"
        new.reported = try #require(ModemStatus(json: #"{"call-state": "incoming", "mo-sms-count": 4}"#))
        model.rebind(to: new)
        #expect(model.settings == new.carrierSettings && model.carrierName == "Restarted", "the new session's network")
        #expect(model.status == nil, "no state from the old modem")
        model.poll()
        #expect(model.callState == "incoming")
        model.set(bars: 2)
        model.callNumber = "+15555550199"
        model.hangUp()
        #expect(new.carrierSettings.bars == 2 && new.actions == ["remote-hangup=1"])
        #expect(old.carrierSettings == CarrierSettings() && old.actions.isEmpty, "the old session hears nothing")
    }

    @Test func invalidNetworkIsRefusedBeforeTheModem() {
        let modem = Modem()
        let model = CarrierPanelModel(backend: modem)
        let before = modem.carrierSettings
        model.mcc = "12"
        model.applyNetwork()
        #expect(modem.carrierSettings == before && model.message != nil)
    }

    @Test func callsAndMessagesNeedValidInput() {
        let modem = Modem()
        let model = CarrierPanelModel(backend: modem)
        model.smsText = ""
        model.sendSMS()
        #expect(modem.actions.isEmpty && model.message != nil)
        model.smsText = "hello"
        model.sendSMS()
        #expect(
            modem.actions == ["incoming-sms=+15555550100|hello"] && model.smsText.isEmpty,
            "a sent message clears the field"
        )
        model.callNumber = "not a number"
        model.ring()
        #expect(modem.actions.count == 1)
    }

    @Test func outgoingMessagesAppearNewestFirst() throws {
        let modem = Modem()
        let model = CarrierPanelModel(backend: modem)
        modem.reported = try #require(ModemStatus(json: #"{"mo-sms-count": 1, "last-mo-sms": "123|before the panel"}"#))
        model.poll()
        #expect(model.sent.isEmpty, "only messages sent while the panel watches")
        modem.reported = try #require(ModemStatus(json: #"{"mo-sms-count": 2, "last-mo-sms": "555|first"}"#))
        model.poll()
        modem.reported = try #require(ModemStatus(json: #"{"mo-sms-count": 3, "last-mo-sms": "556|second"}"#))
        model.poll()
        #expect(model.sent.map(\.text) == ["second", "first"] && model.sent.first?.number == "556")
    }
}
