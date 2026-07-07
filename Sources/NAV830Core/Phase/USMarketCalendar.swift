import Foundation

/// NYSE/Nasdaq trading calendar. Holidays are well-defined and verified for 2026.
///
/// NOTE: Half-day early closes (e.g. day after Thanksgiving, Christmas Eve) affect the
/// after-hours window, not the trading-day flag. They are tracked separately in
/// `MarketClock`; this calendar only answers "is the market open at all today".
public struct USMarketCalendar: MarketCalendar {
    public let timeZone = TimeZone(identifier: "America/New_York")!

    /// NYSE holidays for 2026 (observed dates). Independence Day 2026-07-04 is a Saturday,
    /// so it is observed on Friday 2026-07-03 — the case the PLAN §附錄 example relies on.
    private static let holidays2026: Set<Int> = [
        20260101, // New Year's Day
        20260119, // Martin Luther King Jr. Day
        20260216, // Washington's Birthday
        20260403, // Good Friday
        20260525, // Memorial Day
        20260619, // Juneteenth
        20260703, // Independence Day (observed, Jul 4 falls on Saturday)
        20260907, // Labor Day
        20261126, // Thanksgiving Day
        20261225  // Christmas Day
    ]

    public init() {}

    public func isTradingDay(_ date: Date) -> Bool {
        if isWeekend(date, in: timeZone) { return false }
        return !Self.holidays2026.contains(ymdKey(date, in: timeZone))
    }
}
