import Foundation

/// A US instrument used as a proxy for the PHLX SOX move that 00830 tracks.
public enum ProxySymbol: String, Sendable, CaseIterable {
    /// PHLX Semiconductor Sector — the index 00830 itself tracks, so it carries no tracking
    /// error, no ETF premium and no spread. Regular session only (see `hasExtendedHours`).
    case sox = "SOX"
    /// Invesco PHLX Semiconductor ETF — tracks PHLX SOX, the same index as 00830.
    case soxq = "SOXQ"
    /// iShares Semiconductor ETF — tracks ICE Semiconductor, a *different* basket. Best
    /// liquidity of the three ETFs, which is why it leads outside the regular session.
    case soxx = "SOXX"
    /// Direxion Daily Semiconductor Bull 3x — tracks the NYSE Semiconductor Index, also a
    /// different basket, and leveraged: its move is 3x the underlying.
    case soxl = "SOXL"

    /// Daily leverage factor. The proxy's percentage move is divided by this to recover the
    /// underlying (1x) semiconductor move.
    public var leverage: Int {
        self == .soxl ? 3 : 1
    }

    /// Nasdaq's `assetclass` query value. An index is not an ETF and 404s under `etf`.
    public var assetClass: String {
        self == .sox ? "index" : "etf"
    }

    /// Whether the symbol has pre/post-market prices at all. An index is only calculated during
    /// the regular session, so outside it the quote is just the standing close.
    public var hasExtendedHours: Bool {
        self != .sox
    }

    /// Which proxy should set the headline figure, best first.
    ///
    /// SOX leads because it *is* 00830's benchmark. The others are not interchangeable with it:
    /// SOXX tracks ICE Semiconductor and SOXL the NYSE Semiconductor Index, different baskets
    /// that diverge by most of a percentage point on a dispersed day. Measured 2026-08-05 12:05 ET
    /// off the same official NAV (87.21) and anchor (ET 08/04): SOX −0.47%, SOXQ −0.54%,
    /// SOXX −1.30%, SOXL/3 −1.20% — two clusters, split by index rather than by noise, worth
    /// 0.7 TWD of revalued NAV. SOXQ is next because it tracks PHLX SOX too; SOXX and SOXL follow
    /// on liquidity alone.
    ///
    /// NOTE: this is preference, not eligibility — SOX steps aside outside the regular session
    /// (see `Revaluation.canLeadReport`).
    public static let preferenceOrder: [ProxySymbol] = [.sox, .soxq, .soxx, .soxl]
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

    /// Same latest price, measured from the close the official NAV was struck against. The move
    /// then spans every session in between — exactly the gap the official NAV has yet to absorb.
    ///
    /// A quote is only fit to revalue against once this has been applied: as fetched, its base is
    /// a guess ("the newest close") that holds only while Taiwan is trading.
    public func anchored(to base: DatedClose) -> ProxyQuote {
        ProxyQuote(symbol: symbol, baseClose: base.close, baseCloseDate: base.date,
                   latestPrice: latestPrice, latestAt: latestAt, session: session)
    }

    /// Whether the base has been tied to a known trading day. False ⇒ the move is not measured
    /// from anything the official NAV agrees with, so the revaluation would be arbitrary.
    public var isAnchored: Bool { baseCloseDate != nil }
}
