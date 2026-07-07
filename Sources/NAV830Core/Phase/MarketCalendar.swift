import Foundation

/// A trading calendar for one market. Weekend + holiday aware. Dates are always
/// interpreted in the market's own `timeZone`.
public protocol MarketCalendar: Sendable {
    var timeZone: TimeZone { get }
    /// Whether the given instant falls on a trading day in this market.
    func isTradingDay(_ date: Date) -> Bool
}

/// Encodes a calendar date as `year*10000 + month*100 + day` for set membership.
func ymdKey(_ date: Date, in timeZone: TimeZone) -> Int {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let c = cal.dateComponents([.year, .month, .day], from: date)
    return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
}

func isWeekend(_ date: Date, in timeZone: TimeZone) -> Bool {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let weekday = cal.component(.weekday, from: date)   // 1 = Sunday, 7 = Saturday
    return weekday == 1 || weekday == 7
}

/// Minutes since local midnight, in the given timezone.
func minutesOfDay(_ date: Date, in timeZone: TimeZone) -> Int {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let c = cal.dateComponents([.hour, .minute], from: date)
    return (c.hour ?? 0) * 60 + (c.minute ?? 0)
}
