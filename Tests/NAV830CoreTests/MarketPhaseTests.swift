import XCTest
@testable import NAV830Core

final class MarketPhaseTests: XCTestCase {
    let clock = MarketClock()

    // MARK: - Basic phases (summer / EDT)

    func testTaiwanTrading() {
        // 2026-07-07 (Tue) 10:00 Taipei — user's tradable window.
        XCTAssertEqual(clock.phase(at: at(2026, 7, 7, 10, 0, tz: "Asia/Taipei")), .taiwanTrading)
    }

    func testUSAfterHours() {
        // 2026-07-06 (Mon) 17:00 ET — after-hours in progress.
        XCTAssertEqual(clock.phase(at: at(2026, 7, 6, 17, 0, tz: "America/New_York")), .usAfterHours)
    }

    func testUSRegular() {
        // 2026-07-06 (Mon) 11:00 ET — regular session.
        XCTAssertEqual(clock.phase(at: at(2026, 7, 6, 11, 0, tz: "America/New_York")), .usRegular)
    }

    func testFrozenAfterEightAM() {
        // 2026-07-06 20:30 ET == 2026-07-07 08:30 Taipei: after-hours just ended, Taiwan not
        // yet open. Nothing live — proxy is frozen. Phase is `closed`.
        XCTAssertEqual(clock.phase(at: at(2026, 7, 6, 20, 30, tz: "America/New_York")), .closed)
    }

    func testTaiwanAfterCloseIsClosed() {
        // 2026-07-07 14:00 Taipei — Taiwan closed, US not yet open.
        XCTAssertEqual(clock.phase(at: at(2026, 7, 7, 14, 0, tz: "Asia/Taipei")), .closed)
    }

    // MARK: - Weekends & holidays

    func testWeekendIsClosed() {
        // 2026-07-11 is a Saturday.
        XCTAssertEqual(clock.phase(at: at(2026, 7, 11, 10, 0, tz: "Asia/Taipei")), .closed)
    }

    func testTaiwanHolidayIsClosed() {
        // 2026-01-01 元旦 during would-be trading hours.
        XCTAssertEqual(clock.phase(at: at(2026, 1, 1, 10, 0, tz: "Asia/Taipei")), .closed)
    }

    // MARK: - DST correctness (the §3 landmine)

    func testAfterHoursCloseMapsTo0800TaipeiInSummer() {
        // 20:00 ET in July (EDT, UTC−4) → 08:00 Taipei.
        XCTAssertEqual(hour(at(2026, 7, 6, 20, 0, tz: "America/New_York"), tz: "Asia/Taipei"), 8)
    }

    func testAfterHoursCloseMapsTo0900TaipeiInWinter() {
        // 20:00 ET in December (EST, UTC−5) → 09:00 Taipei. The freeze boundary drifts.
        XCTAssertEqual(hour(at(2026, 12, 8, 20, 0, tz: "America/New_York"), tz: "Asia/Taipei"), 9)
    }

    func testWinterAfterHoursStillResolvesInET() {
        // 2026-12-08 (Tue) 19:00 ET is still after-hours regardless of the Taipei-clock drift,
        // because the phase is computed in ET, not with hard-coded Taipei hours.
        XCTAssertEqual(clock.phase(at: at(2026, 12, 8, 19, 0, tz: "America/New_York")), .usAfterHours)
    }

    func testAfterHoursCloseBoundaryIsExclusive() {
        // Use a summer instant where 20:00 ET == 08:00 Taipei (before Taiwan opens), so we
        // isolate the after-hours boundary itself: exactly 20:00 ET is no longer after-hours.
        XCTAssertEqual(clock.phase(at: at(2026, 7, 6, 20, 0, tz: "America/New_York")), .closed)
        // One minute before still is.
        XCTAssertEqual(clock.phase(at: at(2026, 7, 6, 19, 59, tz: "America/New_York")), .usAfterHours)
    }

    func testWinterAfterHoursCloseOverlapsTaiwanOpen() {
        // The §3 winter drift, made explicit: in EST, 20:00 ET == 09:00 Taipei the next day,
        // which is exactly the TWSE open. Taiwan trading takes precedence, so the phase is
        // `taiwanTrading` — proving boundaries must be resolved per-market, not on one clock.
        XCTAssertEqual(clock.phase(at: at(2026, 12, 8, 20, 0, tz: "America/New_York")), .taiwanTrading)
    }
}
