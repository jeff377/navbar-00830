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
    static func nasdaqTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.replacingOccurrences(of: " ET", with: "").trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "MMM d, yyyy h:mm a"
        return f.date(from: trimmed)
    }

    /// Cathay date like "2026/07/06", interpreted at Taipei midnight.
    static func taipeiDate(_ raw: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        f.dateFormat = "yyyy/MM/dd"
        return f.date(from: raw.trimmingCharacters(in: .whitespaces))
    }
}
