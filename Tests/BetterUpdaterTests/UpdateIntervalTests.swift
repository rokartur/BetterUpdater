import XCTest
@testable import BetterUpdater

final class UpdateIntervalTests: XCTestCase {

    func testManualHasNoInterval() {
        XCTAssertNil(UpdateCheckInterval.manual.interval)
    }

    func testWeeklyIsSevenDays() {
        XCTAssertEqual(UpdateCheckInterval.weekly.interval, 7 * 24 * 60 * 60)
    }

    func testMonthlyIsThirtyDays() {
        XCTAssertEqual(UpdateCheckInterval.monthly.interval, 30 * 24 * 60 * 60)
    }

    func testSelectableCadencesExcludeManual() {
        XCTAssertEqual(UpdateCheckInterval.selectableCadences, [.automatic, .weekly, .monthly])
        XCTAssertFalse(UpdateCheckInterval.selectableCadences.contains(.manual))
    }

    func testRawValuesRoundTripForPersistence() {
        for c in UpdateCheckInterval.allCases {
            XCTAssertEqual(UpdateCheckInterval(rawValue: c.rawValue), c)
        }
    }

    #if !DEBUG
    func testAutomaticIsDailyInRelease() {
        XCTAssertEqual(UpdateCheckInterval.automatic.interval, 24 * 60 * 60)
    }
    #endif
}
