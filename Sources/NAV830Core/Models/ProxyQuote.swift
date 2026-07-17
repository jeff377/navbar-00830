import Foundation

/// A US semiconductor ETF used as a proxy for the PHLX SOX move.
public enum ProxySymbol: String, Sendable, CaseIterable {
    /// iShares Semiconductor ETF — tracks ICE Semiconductor. Primary (best liquidity).
    case soxx = "SOXX"
    /// Invesco PHLX Semiconductor ETF — tracks PHLX SOX (same index as 00830). Cross-check.
    case soxq = "SOXQ"
    /// Direxion Daily Semiconductor Bull 3x — leveraged. Its move is 3x the underlying.
    case soxl = "SOXL"

    /// Daily leverage factor. The proxy's percentage move is divided by this to recover the
    /// underlying (1x) semiconductor move.
    public var leverage: Int {
        self == .soxl ? 3 : 1
    }
}

/// Which US session the latest price came from — for display and freshness, and to be honest
/// about what the estimate is built on (PLAN §3).
public enum ProxySession: String, Sendable {
    /// Live regular-session price (US market open).
    case regular
    /// Live pre-market price (before the regular open).
    case preMarket
    /// Post-market (after-hours) price.
    case afterHours
    /// Frozen last print — regular session closed and no extended-hours data available.
    case frozen
}

/// A proxy ETF quote: the latest available US price paired with the regular close that the
/// official NAV is measured from. The revaluation move is `latestPrice / baseClose − 1`, which
/// works in every phase (PLAN §3):
///   · regular session → latest = live price, base = previous regular close
///   · after-hours     → latest = extended price, base = that day's regular close
///   · Taiwan trading  → latest = frozen extended price, base = the frozen regular close
public struct ProxyQuote: Sendable, Equatable {
    public let symbol: ProxySymbol
    /// The last completed US regular-session close that the official NAV incorporates.
    public let baseClose: Decimal
    /// The most recent US price available.
    public let latestPrice: Decimal
    /// Timestamp of the latest price.
    public let latestAt: Date
    /// Which session `latestPrice` came from.
    public let session: ProxySession

    public init(symbol: ProxySymbol, baseClose: Decimal, latestPrice: Decimal, latestAt: Date, session: ProxySession) {
        self.symbol = symbol
        self.baseClose = baseClose
        self.latestPrice = latestPrice
        self.latestAt = latestAt
        self.session = session
    }
}
