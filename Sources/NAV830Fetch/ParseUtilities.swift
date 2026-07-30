import Foundation
import NAV830Core

/// Parsing helpers shared by the sources. Kept as free functions so each one is unit-testable
/// in isolation against the recorded fixtures.
enum Parse {

    /// Parse a money/number string that may carry `$`, thousands separators, `%`, or `+`.
    /// Returns nil for placeholders such as "--" or "-".
    static func decimal(_ raw: String) -> Decimal? {
        let cleaned = raw
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned != "-", cleaned != "--" else { return nil }
        return Decimal(string: cleaned)
    }

    /// Milliseconds-since-epoch string → Date.
    static func epochMillis(_ raw: String) -> Date? {
        guard let ms = Double(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Nasdaq timestamp like "Jul 6, 2026 7:59 PM ET" (Eastern Time).
    ///
    /// Once a session has closed Nasdaq drops the clock component and sends the bare date
    /// ("Jul 7, 2026"), and in Pre-Market it prefixes the previous close with "Closed at ".
    /// All three forms are accepted; the date-only form resolves to ET midnight.
    static func nasdaqTimestamp(_ raw: String) -> Date? {
        let trimmed = raw
            .replacingOccurrences(of: "Closed at ", with: "")
            .replacingOccurrences(of: " ET", with: "")
            .trimmingCharacters(in: .whitespaces)
        for format in ["MMM d, yyyy h:mm a", "MMM d, yyyy"] {
            if let date = easternFormatter(format).date(from: trimmed) { return date }
        }
        return nil
    }

    /// Nasdaq historical-row date like "07/24/2026" → ET midnight of that trading day.
    static func nasdaqHistoricalDate(_ raw: String) -> Date? {
        easternFormatter("MM/dd/yyyy").date(from: raw.trimmingCharacters(in: .whitespaces))
    }

    /// Cathay date like "2026/07/06", interpreted at Taipei midnight.
    static func taipeiDate(_ raw: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        f.dateFormat = "yyyy/MM/dd"
        return f.date(from: raw.trimmingCharacters(in: .whitespaces))
    }

    /// Cathay date like "2026/07/06" read as an ET *trading-day label* rather than a Taipei
    /// instant. Used for `OfficialNAV.usCloseDate`, which is compared against Nasdaq's ET
    /// close dates — parsing it at Taipei midnight would land on the previous ET day
    /// (2026/07/23 00:00 +08 is 2026/07/22 12:00 ET) and shift every comparison by one day.
    static func taipeiDateAsEasternDay(_ raw: String) -> Date? {
        easternFormatter("yyyy/MM/dd").date(from: raw.trimmingCharacters(in: .whitespaces))
    }

    /// The ET trading day whose 16:00 close is the newest *completed* regular close at `now`.
    ///
    /// This is what dates a quote's base close, and it is derived from our own clock and the US
    /// calendar — never from anything the quote says about itself. Nasdaq's `lastTradeTimestamp`
    /// rolls backwards on its own (see `NasdaqProxySource.parse`), and the historical table, which
    /// is dated properly, does not publish the day's row until about an hour after the post-market
    /// session ends — a gap that covers the Taiwan pre-open.
    ///
    /// It holds in every session: before 16:00 ET (pre-market, regular session) the newest
    /// completed close is the previous trading day's, which is exactly the base those payloads
    /// quote against; from 16:00 ET onwards it is today's own close, the base of the after-hours
    /// print. Weekends and holidays fall back to the last trading day.
    ///
    /// NOTE: half-day sessions close at 13:00 ET. Treating them as closing at 16:00 only delays
    /// the roll to the new day by three hours, during which the historical lookup takes over.
    static func lastCompletedCloseDay(_ now: Date, calendar: MarketCalendar = USMarketCalendar()) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let closedToday = calendar.isTradingDay(now) && cal.component(.hour, from: now) >= 16
        var day = easternDay(now, offsetByDays: closedToday ? 0 : -1)
        // Bounded: no market shuts for a whole week, so this walks back a few days at most.
        while !calendar.isTradingDay(day) {
            day = easternDay(day, offsetByDays: -1)
        }
        return day
    }

    /// Floor an instant to ET midnight, so trading days compare by day rather than by clock.
    static func easternDay(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.startOfDay(for: date)
    }

    /// Shift an ET-midnight day by whole days, staying on ET midnights across DST.
    static func easternDay(_ date: Date, offsetByDays days: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: date)) ?? date
    }

    private static func easternFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = format
        return f
    }
}
