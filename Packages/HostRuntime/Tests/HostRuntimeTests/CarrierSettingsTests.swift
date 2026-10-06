import Foundation
import Testing
import HostRuntime

struct CarrierSettingsTests {
    /// The modem's own rules (qemu-ios ios_bb_plmn_ok, ios_bb_carrier_ok, ios_bb_sms_sender_ok).
    @Test func validatorsMatchTheModem() {
        #expect(CarrierSettings.plmnOK("00101") && CarrierSettings.plmnOK("310410"))
        #expect(!CarrierSettings.plmnOK("0010") && !CarrierSettings.plmnOK("0010123") && !CarrierSettings.plmnOK("00a01")
                && !CarrierSettings.plmnOK("") && !CarrierSettings.plmnOK("００１０１"))
        #expect(CarrierSettings.carrierOK("Test Network") && CarrierSettings.carrierOK(String(repeating: "x", count: 32)))
        #expect(!CarrierSettings.carrierOK("") && !CarrierSettings.carrierOK(String(repeating: "x", count: 33))
                && !CarrierSettings.carrierOK("a\"b") && !CarrierSettings.carrierOK("a\nb"))
        #expect(!CarrierSettings.carrierOK(String(repeating: "é", count: 17)))   // 34 UTF-8 bytes
        #expect(CarrierSettings.numberOK("+14155550100") && CarrierSettings.numberOK("5550100"))
        #expect(!CarrierSettings.numberOK("+") && !CarrierSettings.numberOK("") && !CarrierSettings.numberOK("Apple")
                && !CarrierSettings.numberOK("1+2") && !CarrierSettings.numberOK(String(repeating: "1", count: 21)))
        #expect(CarrierSettings.smsTextOK("Hi") && !CarrierSettings.smsTextOK("") && !CarrierSettings.smsTextOK(String(repeating: "a", count: 161)))
        #expect(CarrierSettings().isValid && CarrierSettings().mccMNC == "00101")
    }

    @Test func barsRoundTrip() {
        for bars in 0...5 { #expect(CarrierSettings.bars(signalDBM: CarrierSettings.signalDBM(bars: bars)) == bars) }
        #expect(CarrierSettings.signalDBM(bars: 9) == CarrierSettings.signalDBM(bars: 5))
    }

    @Test func globalsPassValuesVerbatim() {
        var s = CarrierSettings()
        s.carrier = "A, B"; s.registered = false; s.bars = 2
        #expect(s.globals == ["-global", "ios-baseband.carrier=A, B", "-global", "ios-baseband.mcc-mnc=00101",
                              "-global", "ios-baseband.registered=off", "-global", "ios-baseband.sim-present=on",
                              "-global", "ios-baseband.signal-dbm=-97"])
    }

    @Test func statusParsesTheDylibsJSON() throws {
        let json = #"{"carrier": "Test Network", "mcc-mnc": "00101", "call-state": "incoming", "last-dialed": "911", "#
            + #""last-mo-sms": "14155550100|Hi | there", "registered": true, "sim-present": false, "signal-dbm": -63, "#
            + #""mo-sms-count": 2, "error": "the modem is not in a state to ring"}"#
        let s = try #require(ModemStatus(json: json))
        #expect(s.carrier == "Test Network" && s.callState == "incoming" && s.lastDialed == "911" && s.registered && !s.simPresent)
        #expect(s.signalDBM == -63 && s.moSMSCount == 2 && s.error?.hasPrefix("the modem") == true)
        #expect(s.lastMOSMS?.number == "14155550100" && s.lastMOSMS?.text == "Hi | there")
        #expect(ModemStatus(json: #"{"last-mo-sms": "|"}"#)?.lastMOSMS == nil)
        #expect(ModemStatus(json: "nope") == nil)
    }
}
