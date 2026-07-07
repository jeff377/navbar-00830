import Foundation

/// Which market window we are currently in. This is what drives the shell's tiered refresh
/// (PLAN §3/§5): live 00830 price when Taiwan is trading, low-frequency proxy polling when
/// the after-hours value is frozen.
public enum MarketPhase: String, Sendable {
    /// Taiwan 09:00–13:30 on a TWSE trading day. The US after-hours value is frozen; the
    /// only moving input to the revalued NAV is FX. 00830 price ticks live.
    case taiwanTrading
    /// US after-hours 16:00–20:00 ET on a US trading day. Proxy prices are moving.
    case usAfterHours
    /// US regular session 09:30–16:00 ET on a US trading day.
    case usRegular
    /// Everything else: overnight gaps, weekends, holidays.
    case closed
}

/// Resolves the current market phase from an instant.
///
/// IMPORTANT: All US session boundaries are defined in Eastern Time (20:00 ET after-hours
/// close, etc.) and converted via the ET timezone. This is deliberate — the boundary drifts
/// against the Taipei clock across US DST (after-hours ends 08:00 Taipei in summer / 09:00 in
/// winter). Hard-coding Taipei hours would test green in July and break in December.
public struct MarketClock: Sendable {
    public let tw: any MarketCalendar
    public let us: any MarketCalendar

    // Session boundaries as minutes-of-day in each market's local time.
    private let twOpen = 9 * 60            // 09:00 Asia/Taipei
    private let twClose = 13 * 60 + 30     // 13:30 Asia/Taipei
    private let usRegularOpen = 9 * 60 + 30 // 09:30 ET
    private let usRegularClose = 16 * 60    // 16:00 ET
    private let usAfterHoursClose = 20 * 60 // 20:00 ET

    public init(tw: any MarketCalendar = TWMarketCalendar(), us: any MarketCalendar = USMarketCalendar()) {
        self.tw = tw
        self.us = us
    }

    public func phase(at now: Date) -> MarketPhase {
        // Taiwan trading takes precedence: it is the window in which the user actually trades.
        if tw.isTradingDay(now) {
            let m = minutesOfDay(now, in: tw.timeZone)
            if m >= twOpen && m <= twClose { return .taiwanTrading }
        }

        if us.isTradingDay(now) {
            let m = minutesOfDay(now, in: us.timeZone)
            if m >= usRegularClose && m < usAfterHoursClose { return .usAfterHours }
            if m >= usRegularOpen && m < usRegularClose { return .usRegular }
        }

        return .closed
    }
}
