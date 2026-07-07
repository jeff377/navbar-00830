import Foundation

/// A US semiconductor ETF used as a proxy for the PHLX SOX after-hours move.
public enum ProxySymbol: String, Sendable, CaseIterable {
    /// iShares Semiconductor ETF — tracks ICE Semiconductor. Primary (best liquidity).
    case soxx = "SOXX"
    /// Invesco PHLX Semiconductor ETF — tracks PHLX SOX (same index as 00830). Cross-check.
    case soxq = "SOXQ"
    /// Direxion Daily Semiconductor Bull 3x — leveraged. After-hours move is 3x the underlying.
    case soxl = "SOXL"

    /// Daily leverage factor. The after-hours percentage move must be divided by this
    /// to recover the underlying (1x) semiconductor move.
    public var leverage: Int {
        self == .soxl ? 3 : 1
    }
}

/// A proxy ETF quote pairing the regular-session close (the base the official NAV was
/// priced against) with the latest after-hours print.
public struct ProxyQuote: Sendable, Equatable {
    public let symbol: ProxySymbol
    /// Regular-session close of the US session that the latest official NAV incorporates.
    public let regularClose: Decimal
    /// Latest extended-hours (after-hours) price.
    public let afterHoursPrice: Decimal
    /// Timestamp of the after-hours print. Expected to be ~20:00 ET once the
    /// after-hours session has ended; used to detect thin/stale noise prints.
    public let afterHoursAt: Date

    public init(symbol: ProxySymbol, regularClose: Decimal, afterHoursPrice: Decimal, afterHoursAt: Date) {
        self.symbol = symbol
        self.regularClose = regularClose
        self.afterHoursPrice = afterHoursPrice
        self.afterHoursAt = afterHoursAt
    }
}
