import Foundation

/// TWSE trading calendar (Asia/Taipei, no DST).
///
/// WARNING: The 2026 holiday set below is best-effort and MUST be verified against the
/// official TWSE 行事曆 (announced yearly) before this is relied on in production. Lunar
/// New Year and make-up ("補班/補假") days shift year to year and cannot be derived
/// algorithmically. Only weekends and 2026-01-01 are asserted by the M1 tests; the rest
/// are placeholders to be replaced by an official calendar data file in M2.
/// TODO(M2): load the authoritative TWSE calendar (holidays + half-day sessions) from a
/// bundled JSON updated per year, instead of this hard-coded set.
public struct TWMarketCalendar: MarketCalendar {
    public let timeZone = TimeZone(identifier: "Asia/Taipei")!

    private static let holidays2026: Set<Int> = [
        20260101,                                             // 元旦 (verified)
        // Lunar New Year block (春節) — best-effort, VERIFY before production:
        20260216, 20260217, 20260218, 20260219, 20260220,
        20260227,                                             // 228 makeup (tentative)
        20260406,                                             // 清明 (observed Mon; tentative)
        20260501,                                             // 勞動節 (tentative)
        20260619,                                             // 端午 (tentative)
        20260925,                                             // 中秋 (tentative)
        20261009                                              // 國慶 makeup (tentative)
    ]

    public init() {}

    public func isTradingDay(_ date: Date) -> Bool {
        if isWeekend(date, in: timeZone) { return false }
        return !Self.holidays2026.contains(ymdKey(date, in: timeZone))
    }
}
