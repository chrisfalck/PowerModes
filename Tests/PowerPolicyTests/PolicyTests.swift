import XCTest
@testable import PowerPolicy

final class PolicyTests: XCTestCase {
    /// The documented default table, written out independently of `PolicySettings.defaults`.
    private func tableMode(_ source: PowerSource, _ percent: Int) -> PowerMode {
        if percent <= 20 { return .low }
        if source == .ac && percent >= 80 { return .high }
        if source == .battery && percent <= 50 { return .low }
        return .automatic
    }

    func testDefaultsMatchDocumentedTableAtEveryCharge() {
        for source in PowerSource.allCases {
            for percent in 0...100 {
                XCTAssertEqual(PolicySettings.defaults[source].mode(at: percent), tableMode(source, percent),
                               "\(source) at \(percent)%")
            }
        }
    }

    func testThresholdBoundaries() {
        let thresholds = Thresholds(highMin: 80, autoMin: 21)
        XCTAssertEqual(thresholds.mode(at: 20), .low)
        XCTAssertEqual(thresholds.mode(at: 21), .automatic)
        XCTAssertEqual(thresholds.mode(at: 79), .automatic)
        XCTAssertEqual(thresholds.mode(at: 80), .high)
    }

    func testNeverHighAndNeverLow() {
        let thresholds = Thresholds(highMin: Thresholds.never, autoMin: 0)
        XCTAssertFalse(thresholds.usesHighPower)
        for percent in 0...100 { XCTAssertEqual(thresholds.mode(at: percent), .automatic) }
    }

    func testEqualThresholdsLeaveNoAutomaticBand() {
        let thresholds = Thresholds(highMin: 40, autoMin: 40)
        XCTAssertEqual(thresholds.mode(at: 39), .low)
        XCTAssertEqual(thresholds.mode(at: 40), .high)
    }

    func testThresholdsPushEachOtherAndClamp() {
        var thresholds = Thresholds(highMin: 80, autoMin: 21)
        thresholds.setAutoMin(90)
        XCTAssertEqual(thresholds, Thresholds(highMin: 90, autoMin: 90))
        thresholds.setHighMin(30)
        XCTAssertEqual(thresholds, Thresholds(highMin: 30, autoMin: 30))
        thresholds.setHighMin(500)
        XCTAssertEqual(thresholds.highMin, Thresholds.never)
        thresholds.setHighMin(-5)
        XCTAssertEqual(thresholds.highMin, 1)
        XCTAssertEqual(thresholds.autoMin, 1)
        thresholds.setAutoMin(-5)
        XCTAssertEqual(thresholds.autoMin, 0)
        thresholds.setAutoMin(500)
        XCTAssertEqual(thresholds, Thresholds(highMin: 100, autoMin: 100))
    }

    func testInitAndDecodingNormalizeBadValues() throws {
        XCTAssertEqual(Thresholds(highMin: 10, autoMin: 60), Thresholds(highMin: 60, autoMin: 60))
        let decoded = try JSONDecoder().decode(Thresholds.self, from: Data(#"{"highMin":999,"autoMin":-3}"#.utf8))
        XCTAssertEqual(decoded, Thresholds(highMin: Thresholds.never, autoMin: 0))
        let settings = PolicySettings.defaults
        let roundTrip = try JSONDecoder().decode(PolicySettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip, settings)
    }

    func testPlanCoversBothProfilesAndSkipsCorrectOnes() {
        let settings = PolicySettings.defaults
        for active in PowerSource.allCases {
            for percent in 0...100 {
                for ac in PowerMode.allCases {
                    for battery in PowerMode.allCases {
                        let current: [PowerSource: PowerMode] = [.ac: ac, .battery: battery]
                        let plan = Policy.plan(percent: percent, active: active, settings: settings, current: current)
                        var result = current
                        for change in plan {
                            XCTAssertNotEqual(current[change.source], change.mode, "no-op change planned")
                            result[change.source] = change.mode
                        }
                        XCTAssertEqual(result[.ac], tableMode(.ac, percent))
                        XCTAssertEqual(result[.battery], tableMode(.battery, percent))
                        if plan.count == 2 { XCTAssertEqual(plan.last?.source, active) }
                    }
                }
            }
        }
    }

    func testPlanSetsProfilesWhoseModeIsUnknown() {
        let plan = Policy.plan(percent: 45, active: .ac, settings: .defaults, current: [:])
        XCTAssertEqual(plan, [ModeChange(source: .battery, mode: .low), ModeChange(source: .ac, mode: .automatic)])
    }

    func testHysteresisDelaysStepDownOnly() {
        let ac = PolicySettings.defaults.ac
        // Hovering at the High Power threshold no longer flips the mode.
        XCTAssertEqual(ac.mode(at: 79, holding: .high, margin: 3), .high)
        XCTAssertEqual(ac.mode(at: 77, holding: .high, margin: 3), .high)
        XCTAssertEqual(ac.mode(at: 76, holding: .high, margin: 3), .automatic)
        XCTAssertEqual(ac.mode(at: 20, holding: .automatic, margin: 3), .automatic)
        XCTAssertEqual(ac.mode(at: 18, holding: .automatic, margin: 3), .automatic)
        XCTAssertEqual(ac.mode(at: 17, holding: .automatic, margin: 3), .low)
        // Stepping up is immediate, whatever the current mode.
        XCTAssertEqual(ac.mode(at: 79, holding: .automatic, margin: 3), .automatic)
        XCTAssertEqual(ac.mode(at: 80, holding: .automatic, margin: 3), .high)
        XCTAssertEqual(ac.mode(at: 21, holding: .low, margin: 3), .automatic)
        XCTAssertEqual(ac.mode(at: 80, holding: .low, margin: 3), .high)
        // A long fall steps down through the bands rather than holding the old mode.
        XCTAssertEqual(ac.mode(at: 50, holding: .high, margin: 3), .automatic)
        XCTAssertEqual(ac.mode(at: 19, holding: .high, margin: 3), .automatic)
        XCTAssertEqual(ac.mode(at: 10, holding: .high, margin: 3), .low)
    }

    func testHysteresisNeverInventsHighPower() {
        let battery = PolicySettings.defaults.battery
        for percent in 0...100 {
            for current in PowerMode.allCases {
                let mode = battery.mode(at: percent, holding: current, margin: 3)
                if current != .high { XCTAssertNotEqual(mode, .high, "\(current) at \(percent)%") }
                if percent >= 51 { XCTAssertEqual(mode, .automatic) }
                if percent < 48 { XCTAssertEqual(mode, .low) }
            }
        }
        XCTAssertEqual(battery.mode(at: 100, holding: .high, margin: 3), .automatic)
        XCTAssertEqual(battery.mode(at: 49, holding: .automatic, margin: 3), .automatic)
        XCTAssertEqual(battery.mode(at: 49, holding: .high, margin: 3), .automatic)
    }

    func testHysteresisOffOrUnknownModeIsExact() {
        for source in PowerSource.allCases {
            let thresholds = PolicySettings.defaults[source]
            for percent in 0...100 {
                XCTAssertEqual(thresholds.mode(at: percent, holding: nil, margin: 3), thresholds.mode(at: percent))
                for current in PowerMode.allCases {
                    XCTAssertEqual(thresholds.mode(at: percent, holding: current, margin: 0), thresholds.mode(at: percent))
                    // Never further than one margin from the exact answer.
                    let held = thresholds.mode(at: percent, holding: current, margin: 3)
                    XCTAssertTrue(held == thresholds.mode(at: percent) || held == thresholds.mode(at: percent + 3)
                                  || held == current, "\(source) \(current) at \(percent)%")
                }
            }
        }
    }

    func testPlanAppliesMargin() {
        let current: [PowerSource: PowerMode] = [.ac: .high, .battery: .automatic]
        XCTAssertEqual(Policy.plan(percent: 79, active: .ac, settings: .defaults, current: current, margin: 3), [])
        XCTAssertEqual(Policy.plan(percent: 79, active: .ac, settings: .defaults, current: current),
                       [ModeChange(source: .ac, mode: .automatic)])
        XCTAssertEqual(Policy.plan(percent: 47, active: .battery, settings: .defaults, current: current, margin: 3),
                       [ModeChange(source: .ac, mode: .automatic), ModeChange(source: .battery, mode: .low)])
    }

    func testParseCustomModes() {
        let output = """
        Battery Power:
         Sleep On Power Button 1
         powermode            1
         hibernatefile        /var/vm/sleepimage
         displaysleep         2
        AC Power:
         Sleep On Power Button 1
         powermode            2
         sleep                1
        """
        XCTAssertEqual(Policy.parseCustomModes(output), [.battery: .low, .ac: .high])
    }

    func testParseIgnoresUnknownSectionsAndBadValues() {
        let output = """
        UPS Power:
         powermode            2
        AC Power:
         powermode            7
        Battery Power:
         displaysleep         2
        """
        XCTAssertEqual(Policy.parseCustomModes(output), [:])
        XCTAssertEqual(Policy.parseCustomModes(""), [:])
    }
}
