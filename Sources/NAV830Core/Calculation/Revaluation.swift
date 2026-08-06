import Foundation

/// The result of revaluing 00830 against a single proxy ETF.
public struct Revaluation: Sendable, Equatable {
    public let proxy: ProxySymbol
    /// De-leveraged proxy return — the US move since the base close (e.g. -0.0095 for -0.95%).
    public let proxyReturn: Decimal
    /// Which US session the *latest price* came from (regular / after-hours / frozen). NOTE: it
    /// does not describe the whole move — once the quote is re-anchored to an older close, the
    /// move spans every session since. Use `baseCloseDate` to say what it is measured from.
    public let session: ProxySession
    /// ET trading date the move is measured from — the close the official NAV was struck against.
    public let baseCloseDate: Date?
    /// FX adjustment factor that was applied.
    public let fxFactor: Decimal
    /// Re-estimated intraday NAV in TWD.
    public let revaluedNAV: Decimal

    /// Whether this revaluation may carry the headline figure.
    ///
    /// The index is only calculated during the regular session. Outside it its quote is the
    /// standing close, so the move it reports stops at 16:00 ET — while the ETFs' pre/post-market
    /// prints carry exactly the increment the official NAV still lacks, which is the whole point
    /// of the tool during the Taiwan session. So SOX leads while it is live and steps aside when
    /// it is not; every ETF is always eligible.
    public var canLeadReport: Bool {
        proxy.hasExtendedHours || session == .regular
    }

    public init(proxy: ProxySymbol, proxyReturn: Decimal, session: ProxySession, baseCloseDate: Date? = nil, fxFactor: Decimal, revaluedNAV: Decimal) {
        self.proxy = proxy
        self.proxyReturn = proxyReturn
        self.session = session
        self.baseCloseDate = baseCloseDate
        self.fxFactor = fxFactor
        self.revaluedNAV = revaluedNAV
    }
}

/// The full picture presented to the shell: the primary revaluation, the premium/discount
/// against the live market price, and the cross-check revaluations from the other proxies.
public struct RevaluationReport: Sendable, Equatable {
    /// Primary revaluation — the best proxy available under `ProxySymbol.preferenceOrder`.
    public let primary: Revaluation
    /// All proxy revaluations available, keyed by symbol, for the cross-check panel.
    public let crossChecks: [Revaluation]
    /// Premium/discount = marketPrice / primary.revaluedNAV − 1. Negative ⇒ discount.
    public let premium: Decimal
    public let marketPrice: MarketPrice

    public init(primary: Revaluation, crossChecks: [Revaluation], premium: Decimal, marketPrice: MarketPrice) {
        self.primary = primary
        self.crossChecks = crossChecks
        self.premium = premium
        self.marketPrice = marketPrice
    }
}
