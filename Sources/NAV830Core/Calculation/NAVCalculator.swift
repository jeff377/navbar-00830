import Foundation

/// Pure revaluation math. No I/O, no clocks, no networking — every input is passed in,
/// so the whole thing is deterministic and unit-testable against the PLAN §附錄 numbers.
public enum NAVCalculator {

    /// De-leveraged proxy return: the US move since the base close.
    ///
    /// `(latestPrice − baseClose) / baseClose`, then divided by the proxy's leverage so that
    /// SOXL's 3x move is reduced to the underlying 1x semiconductor move. Works in every phase —
    /// the caller (source layer) picks the right `latestPrice`/`baseClose` pairing (PLAN §3).
    public static func proxyReturn(_ quote: ProxyQuote) -> Decimal {
        guard quote.baseClose != 0 else { return 0 }
        let raw = (quote.latestPrice - quote.baseClose) / quote.baseClose
        return raw / Decimal(quote.symbol.leverage)
    }

    /// Re-estimated intraday NAV = officialNAV × (1 + proxyReturn) × fxFactor.
    public static func revaluedNAV(officialNAV: Decimal, proxyReturn: Decimal, fxFactor: Decimal) -> Decimal {
        officialNAV * (1 + proxyReturn) * fxFactor
    }

    /// Premium/discount of the market price against a revalued NAV. Negative ⇒ discount.
    public static func premium(marketPrice: Decimal, revaluedNAV: Decimal) -> Decimal {
        guard revaluedNAV != 0 else { return 0 }
        return marketPrice / revaluedNAV - 1
    }

    /// Revalue against a single proxy.
    public static func revalue(officialNAV: OfficialNAV, proxy: ProxyQuote, fx: FXRate) -> Revaluation {
        let ret = proxyReturn(proxy)
        let factor = fx.factor
        let nav = revaluedNAV(officialNAV: officialNAV.value, proxyReturn: ret, fxFactor: factor)
        return Revaluation(proxy: proxy.symbol, proxyReturn: ret, session: proxy.session,
                           baseCloseDate: proxy.baseCloseDate, fxFactor: factor, revaluedNAV: nav)
    }

    /// Build the full report: SOXX as the primary value, the others as cross-checks.
    ///
    /// The `primary` proxy defaults to SOXX (PLAN §2.3). If it is missing from `proxies`
    /// the first available proxy is used instead, so the app degrades rather than fails.
    public static func report(
        officialNAV: OfficialNAV,
        proxies: [ProxyQuote],
        fx: FXRate,
        marketPrice: MarketPrice,
        primary primarySymbol: ProxySymbol = .soxx
    ) -> RevaluationReport? {
        guard !proxies.isEmpty else { return nil }
        let revaluations = proxies.map { revalue(officialNAV: officialNAV, proxy: $0, fx: fx) }
        let primary = revaluations.first { $0.proxy == primarySymbol } ?? revaluations[0]
        let prem = premium(marketPrice: marketPrice.price, revaluedNAV: primary.revaluedNAV)
        return RevaluationReport(primary: primary, crossChecks: revaluations, premium: prem, marketPrice: marketPrice)
    }
}
