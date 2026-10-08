// FinishedSetup: Setup Assistant's finished state, seeded into the data volume's /private/var skeleton (recipe option
// skip_setup, firmwarekit create --skip-setup), so a fresh iOS 5-7 device starts at the Home screen.
//
// The keys are the ones Setup itself writes on a walk that picks English, the region, Location Services off, no Wi-Fi,
// a new device, no Apple ID or passcode, the terms and Don't Send: the data volume of each base diffed before and
// after the sessions harness's walk (n81ap/k48ap 9B206, n90ap 10B329, n90ap 11D257). What the boot's other parts
// write anyway (lockdown's zone and clock, it_prefs, caches) is left to them. Setup's region is the Mac's.

import Foundation

extension SystemEdits {
    /// One plist under /private/var and the keys it gets.
    typealias Seed = (path: String, keys: [String: Any])

    static let purpleBuddy = "mobile/Library/Preferences/com.apple.purplebuddy.plist"
    static let purpleBuddyLocal = "mobile/Library/Preferences/com.apple.purplebuddy.notbackedup.plist"
    static let locationd = "mobile/Library/Preferences/com.apple.locationd.plist"
    static let locationdLocal = "mobile/Library/Preferences/com.apple.locationd.notbackedup.plist"
    static let globalPreferences = "mobile/Library/Preferences/.GlobalPreferences.plist"
    static let dataArk = "root/Library/Lockdown/data_ark.plist"

    /// What Setup leaves on iOS `major` (5, 6, 7) after a walk in `language` and `locale` ("en", "en_AU"), finished at
    /// `now`; empty before 5 (iTunes activated those, no Setup Assistant).
    static func finishedSetup(major: Int, language: String, locale: String, now: Date = Date()) -> [Seed] {
        guard major >= 5 else { return [] }
        var buddy: [String: Any] = [
            "SetupDone": true, "SetupFinishedAllSteps": true, "RestoreChoice": true, "PBTCPresented": true,
            "PBDiagnosticsPresented": true, "WiFiPresented": true, "Language": language, "Locale": locale,
        ]
        let off: [String: Any]
        var buddyLocal: [String: Any]
        var ark: [String: Any]
        var extra: [Seed] = []
        switch major {
        case 5, 6:
            buddy[major == 5 ? "AppleIDPresented" : "AppleIDPB3Presented"] = true
            if major == 6 { buddy["SetupVersion"] = 3 }
            buddyLocal = ["LocationServicesPresented": true]
            off = ["LocationServicesEnabled": 0]
            ark = [
                "com.apple.purplebuddy-SetupState": "SetupUsingAssistant",
                "com.apple.mobile.user_preferences-UserSetLanguage": true,
                "com.apple.mobile.user_preferences-UserSetLocale": true,
            ]
        default:
            buddy.merge(
                [
                    "AppleIDPB5Presented": true, "PasscodePresented": true, "SetupVersion": 5,
                    "SetupState": "SetupUsingAssistant", "AppleIDForceUpgrade": false,
                ]
            ) { $1 }
            buddyLocal = ["LocationServices2Presented": true, "CloudConfigPresented": true]
            off = ["LocationServicesEnabledIn7.0": 0]
            ark = [
                "-ActivationStateAcknowledged": true, "com.apple.mobile.chaperone-NotSoFresh": true,
                "-FirstPurpleBuddyCompletion": Int(now.timeIntervalSince1970),
            ]
            // Setup's cloud configuration step, through ManagedConfiguration: without the record, 7.x's
            // PSSetupAssistantNeedsToRun brings Setup back for it (Wi-Fi, then Welcome) on every boot.
            extra = [
                (
                    "mobile/Library/ConfigurationProfiles/CloudConfigurationDetails.plist",
                    [
                        "AllowPairing": true, "CloudConfigurationUIComplete": true, "IsSupervised": false,
                        "PostSetupProfileWasInstalled": false,
                    ]
                ),
                (
                    "mobile/Library/Preferences/com.apple.mobile.user_preferences.plist",
                    ["UserSetLanguage": true, "UserSetLocale": true]
                ),
            ]
        }
        return [
            (purpleBuddy, buddy), (purpleBuddyLocal, buddyLocal), (locationd, off), (locationdLocal, off),
            (globalPreferences, ["AppleLocale": locale]), (dataArk, ark),
        ] + extra
    }

    /// The Mac's language and region as Setup records them ("en", "en_GB"), from `locale`.
    static func setupLanguage(_ locale: Locale = .autoupdatingCurrent) -> (language: String, locale: String) {
        let language = locale.language.languageCode?.identifier ?? "en"
        return (language, locale.region.map { "\(language)_\($0.identifier)" } ?? language)
    }

    /// Seeds `finishedSetup` into `skeleton` (/private/var), merged into the plists already there. The firmware's
    /// language list gets the Mac's language first where the firmware has it, as Setup's language page does.
    static func seedFinishedSetup(_ skeleton: URL, major: Int, locale: Locale = .autoupdatingCurrent) throws {
        let (language, region) = setupLanguage(locale)
        for (path, keys) in finishedSetup(major: major, language: language, locale: region) {
            try seedPlist(skeleton.appendingPathComponent(path)) { d in
                d.addEntries(from: keys)
                if path == globalPreferences, var list = d["AppleLanguages"] as? [String],
                    let i = list.firstIndex(of: language)
                {
                    list.insert(list.remove(at: i), at: 0)
                    d["AppleLanguages"] = list
                }
            }
        }
    }
}
