import XCTest
@testable import NAV830Core

final class MarketCalendarTests: XCTestCase {
    let us = USMarketCalendar()
    let tw = TWMarketCalendar()

    // MARK: - US (well-defined NYSE 2026)

    func testUSIndependenceDayObservedIsClosed() {
        // 2026-07-04 is a Saturday, so NYSE observes it on Friday 2026-07-03 — the exact
        // holiday that makes the §附錄 date-alignment case (NAV 7/6 uses the 7/2 close) real.
        XCTAssertFalse(us.isTradingDay(at(2026, 7, 3, 12, 0, tz: "America/New_York")))
    }

    func testUSNormalMondayIsTrading() {
        XCTAssertTrue(us.isTradingDay(at(2026, 7, 6, 12, 0, tz: "America/New_York")))
    }

    func testUSNewYearIsClosed() {
        XCTAssertFalse(us.isTradingDay(at(2026, 1, 1, 12, 0, tz: "America/New_York")))
    }

    func testUSWeekendIsClosed() {
        XCTAssertFalse(us.isTradingDay(at(2026, 7, 11, 12, 0, tz: "America/New_York")))
    }

    // MARK: - TW (only the confidently-known cases are asserted; see TWMarketCalendar WARNING)

    func testTWNewYearIsClosed() {
        XCTAssertFalse(tw.isTradingDay(at(2026, 1, 1, 10, 0, tz: "Asia/Taipei")))
    }

    func testTWNormalTuesdayIsTrading() {
        XCTAssertTrue(tw.isTradingDay(at(2026, 7, 7, 10, 0, tz: "Asia/Taipei")))
    }

    func testTWWeekendIsClosed() {
        XCTAssertFalse(tw.isTradingDay(at(2026, 7, 11, 10, 0, tz: "Asia/Taipei")))
    }
}
