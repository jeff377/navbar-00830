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
    /// The US regular-session close the move is measured from — which must be the close the
    /// official NAV was struck against (`OfficialNAV.usCloseDate`), not merely the newest one.
    public let baseClose: Decimal
    /// ET trading date of `baseClose`, as an ET-midnight instant. Nil when the source cannot
    /// date it (a live regular-session tick, where the base is recovered from `netChange`).
    public let baseCloseDate: Date?
    /// The most recent US price available.
    public let latestPrice: Decimal
    /// Timestamp of the latest price.
    public let latestAt: Date
    /// Which session `latestPrice` came from.
    public let session: ProxySession

    public init(symbol: ProxySymbol, baseClose: Decimal, baseCloseDate: Date? = nil, latestPrice: Decimal, latestAt: Date, session: ProxySession) {
        self.symbol = symbol
        self.baseClose = baseClose
        self.baseCloseDate = baseCloseDate
        self.latestPrice = latestPrice
        self.latestAt = latestAt
        self.session = session
    }

    /// Same latest price, measured from an older close — the one the official NAV actually used.
    /// The resulting move then spans every session in between, which is exactly the gap the
    /// official NAV has yet to absorb.
    public func reanchored(to base: DatedClose) -> ProxyQuote {
        ProxyQuote(symbol: symbol, baseClose: base.close, baseCloseDate: base.date,
                   latestPrice: latestPrice, latestAt: latestAt, session: session)
    }

    /// Whether this quote's base is newer than what `navAnchor` (the official NAV's valuation
    /// close) incorporates — i.e. the move between the two is missing from the revaluation.
    public func needsReanchoring(to navAnchor: Date?) -> Bool {
        guard let navAnchor, let baseCloseDate else { return false }
        return baseCloseDate > navAnchor
    }
}
