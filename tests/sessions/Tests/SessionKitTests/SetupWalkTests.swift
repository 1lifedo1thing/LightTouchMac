import Testing

@testable import SessionKit

/// The Setup walks' logic without an emulator: the iPad's tap-retry core against fake taps (a unit of 50 ms), the page
/// fingerprints measured off real Setup screenshots, and the phone walk's plan against label sets read off real pages.
struct SetupWalkTests {
    static let unit = 0.05

    @Test func aLostTapIsTappedAgain() async {
        var taps = 0
        let r = await SetupPages.tapUntil(
            budget: 6,
            every: 1.5,
            unit: Self.unit,
            tap: { taps += 1 },
            answered: { taps >= 2 }
        )
        #expect(r && taps == 2)
    }

    @Test func aLandedTapIsNotRepeated() async {
        var taps = 0
        let r = await SetupPages.tapUntil(
            budget: 6,
            every: 1.5,
            unit: Self.unit,
            tap: { taps += 1 },
            answered: { taps >= 1 }
        )
        #expect(r && taps == 1)
    }

    @Test func aPageThatNeverAnswersFailsAfterTheBudgetOneTapPerInterval() async {
        var taps = 0
        let r = await SetupPages.tapUntil(budget: 5, every: 2, unit: Self.unit, tap: { taps += 1 }, answered: { false })
        #expect(!r && taps == 3)
    }

    @Test func aOnePollFlashIsNotAnAnswer() async {
        var taps = 0
        var polls = 0
        let r = await SetupPages.tapUntil(
            budget: 12,
            every: 3,
            unit: Self.unit,
            tap: {
                taps += 1
                polls = 0
            },
            answered: {
                polls += 1
                return taps >= 2 || polls == 1
            }
        )
        #expect(r && taps == 2)
    }

    /// Fingerprints measured off real Setup screenshots (9A5220p, 9A334, 9A405, 9B176, 9B206).
    static let measured: [(String?, [Double])] = [
        ("list", [0.97, 0.92, 0.83, 0.92, 1.0, 0.95, 0.8]), ("list", [0.98, 0.92, 0.83, 0.92, 1.0, 0.96, 0.79]),
        ("location", [0.97, 0.0, 0.95, 0.05, 0.0, 0.34, 0.0]), ("wi-fi", [0.0, 0.0, 0.0, 0.28, 0.0, 0.0, 0.75]),
        ("set up", [0.93, 0.92, 0.99, 0.0, 1.0, 0.0, 0.0]), ("set up", [0.94, 0.92, 0.99, 0.0, 1.0, 0.0, 0.0]),
        ("apple id", [0.92, 0.92, 0.0, 0.07, 0.0, 0.09, 0.0]), ("apple id", [0.92, 0.92, 0.0, 0.04, 0.0, 0.1, 0.0]),
        ("diagnostics", [0.0, 0.0, 0.0, 1.0, 0.27, 0.01, 0.0]), ("diagnostics", [0.0, 0.0, 0.0, 1.0, 0.29, 0.0, 0.0]),
        ("diagnostics", [0.0, 0.0, 0.0, 0.12, 0.0, 0.0, 0.95]), ("thank you", [0.0, 0.83, 0.17, 0.05, 0.0, 0.18, 0.0]),
        (nil, [0.0, 0.0, 0.0, 0.0, 0.0, 0.04, 0.0]), (nil, [0.78, 0.69, 0.86, 1.0, 1.0, 0.74, 0.92]),
    ]

    @Test func measuredPagesAreRecognized() {
        for (want, f) in Self.measured {
            #expect(SetupPages.kind(f) == want, "page \(want ?? "unrecognized") from \(f)")
        }
    }

    func taps(_ steps: [SetupPlan.Step]) -> [String] {
        steps.compactMap {
            if case .tap(_, _, let log) = $0 { return log ?? "(next)" }
            return nil
        }
    }

    /// n88ap-10A523 (3GS 6.0.1): the language page with the Home sheet up.
    static let sheetOnLanguage: [String: (x: Double, y: Double)] = [
        "Test Network": (0.2, 0.02), "9:43 PM": (0.5, 0.02), "English": (0.15, 0.2), "Français": (0.15, 0.29),
        "Deutsch": (0.15, 0.39), "Emergency Call": (0.5, 0.66), "Start Over": (0.5, 0.77), "Cancel": (0.5, 0.91),
    ]

    @Test func theHomeSheetIsCancelledFirst() {
        #expect(SetupPlan.plan(Self.sheetOnLanguage, pages: []) == [.tap(0.5, 0.91, "(Cancel)")])
        var onPick = Self.sheetOnLanguage
        onPick["Skip This Step"] = (0.82, 0.95)
        #expect(taps(SetupPlan.plan(onPick, pages: [])) == ["(Cancel)"])
    }

    @Test func theLanguagePageTakesEnglishThenTheArrow() {
        var language = Self.sheetOnLanguage
        ["Emergency Call", "Start Over", "Cancel"].forEach { language[$0] = nil }
        let plan = SetupPlan.plan(language, pages: [])
        #expect(plan.count == 3 && plan[0] == .tap(0.15, 0.2, "English"))
        guard case .tap(let x, let y, _) = plan.last else {
            Issue.record("no arrow tap: \(plan)")
            return
        }
        #expect(x == SetupPlan.nextArrow.x && y == SetupPlan.nextArrow.y)
    }

    /// n90ap-11D257 (7.1.2): the Country page's first row.
    @Test func theCountryPageTakesItsFirstRow() {
        let country7: [String: (x: Double, y: Double)] = [
            "Back": (0.12, 0.09), "Select Your Country": (0.5, 0.19), "or Region": (0.5, 0.26),
            "MORE COUNTRIES AND REGIONS": (0.4, 0.5), "Afghanistan": (0.2, 0.595), "Åland Islands": (0.22, 0.72),
        ]
        #expect(taps(SetupPlan.plan(country7, pages: [])) == ["Afghanistan"])
    }

    @Test func anAlertsOKAndTheWelcomeSlide() {
        #expect(taps(SetupPlan.plan(["OK": (0.5, 0.6), "Location Services": (0.5, 0.4)], pages: [])) == ["(OK)"])
        #expect(SetupPlan.plan(["slide to set up": (0.5, 0.9)], pages: []) == [.slideIfLockScreen])
    }
}
