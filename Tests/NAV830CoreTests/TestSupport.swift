import Foundation
@testable import NAV830Core

/// Decimal from a string literal (exact — avoids Double rounding in fixtures).
func dec(_ s: String) -> Decimal { Decimal(string: s)! }

/// Double view of a Decimal for `XCTAssertEqual(_:_:accuracy:)`.
func dbl(_ d: Decimal) -> Double { (d as NSDecimalNumber).doubleValue }

/// Build a `Date` from wall-clock components in a named timezone.
func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, tz: String) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: tz)!
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

/// The hour-of-day an instant reads as in a given timezone.
func hour(_ date: Date, tz: String) -> Int {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: tz)!
    return cal.component(.hour, from: date)
}

enum Fixtures {
    /// PLAN §附錄 (2026/07/07 盤中實測).
    static let officialNAV = OfficialNAV(
        value: dec("91.68"),
        navDate: at(2026, 7, 6, 0, 0, tz: "Asia/Taipei"),
        source: "SITCA (fixture)",
        fetchedAt: at(2026, 7, 7, 9, 0, tz: "Asia/Taipei")
    )

    /// SOXX 581.51 → 576.00 after-hours (−0.95%).
    static let soxx = ProxyQuote(
        symbol: .soxx,
        regularClose: dec("581.51"),
        afterHoursPrice: dec("576.00"),
        afterHoursAt: at(2026, 7, 6, 20, 0, tz: "America/New_York")
    )

    static let noFX = FXRate(current: dec("1"), reference: nil, timestamp: Date(timeIntervalSince1970: 0), source: "fixture")

    static let price = MarketPrice(
        price: dec("89.90"),
        timestamp: at(2026, 7, 7, 10, 0, tz: "Asia/Taipei"),
        source: "TWSE MIS (fixture)"
    )
}
