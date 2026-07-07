import Foundation

/// The result of revaluing 00830 against a single proxy ETF.
public struct Revaluation: Sendable, Equatable {
    public let proxy: ProxySymbol
    /// De-leveraged after-hours return of the proxy (e.g. -0.0095 for -0.95%).
    public let afterHoursReturn: Decimal
    /// FX adjustment factor that was applied.
    public let fxFactor: Decimal
    /// Re-estimated intraday NAV in TWD.
    public let revaluedNAV: Decimal

    public init(proxy: ProxySymbol, afterHoursReturn: Decimal, fxFactor: Decimal, revaluedNAV: Decimal) {
        self.proxy = proxy
        self.afterHoursReturn = afterHoursReturn
        self.fxFactor = fxFactor
        self.revaluedNAV = revaluedNAV
    }
}

/// The full picture presented to the shell: the primary revaluation (SOXX), the
/// premium/discount against the live market price, and the cross-check revaluations
/// from the secondary proxies.
public struct RevaluationReport: Sendable, Equatable {
    /// Primary revaluation (SOXX by default).
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
