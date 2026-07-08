import Foundation
import NAV830Core

/// Everything the issuer's ETF page exposes for one fund in a single record.
public struct CathayETF: Sendable, Equatable {
    /// The official current NAV shown on the page (預估淨值 / estimateNav) — the number the user
    /// compares against. It already reflects the regular US close *and* the issuer's intraday FX
    /// adjustment, so the revaluation adds only the after-hours move on top and needs no separate
    /// FX factor. Falls back to the prior-close NAV (昨收淨值) when the estimate is absent.
    public let nav: OfficialNAV
    /// Market price shown on the official page (最新市價), i.e. `lastPrice`.
    public let price: MarketPrice
    /// Prior-day close NAV (昨收淨值), for reference.
    public let closingNav: Decimal

    public init(nav: OfficialNAV, price: MarketPrice, closingNav: Decimal) {
        self.nav = nav
        self.price = price
        self.closingNav = closingNav
    }
}

/// Fetches 00830's official NAV and market price together from the one Cathay endpoint that backs
/// cathaysite.com.tw/ETF/estimate. Both figures live in the same record, so one call serves both —
/// no duplicate fetch of the ~90 KB list.
public struct CathayETFSource: Sendable {
    private let client: HTTPClient
    private let stockCode: String

    public init(client: HTTPClient = URLSessionHTTPClient(), stockCode: String = "00830") {
        self.client = client
        self.stockCode = stockCode
    }

    public func fetch() async throws -> CathayETF {
        let url = URL(string: "https://cwapi.cathaysite.com.tw/api/ETF/GetRealTimeEstimateNavList")!
        let data = try await client.get(url, headers: [
            "User-Agent": browserUserAgent,
            "Accept": "application/json"
        ])
        return try Self.parse(data, stockCode: stockCode, now: Date())
    }

    private struct Envelope: Decodable {
        let result: [Row]
        struct Row: Decodable {
            let stockCode: String?
            let closingNav: Double?
            let closingNavString: String?
            let closingNavDate: String?
            let lastPrice: Double?
            let lastPriceString: String?
            let closingPrice: Double?
            let closingPriceString: String?
            let estimateNav: Double?
            let estimateNavString: String?
        }
    }

    static func parse(_ data: Data, stockCode: String, now: Date) throws -> CathayETF {
        let env: Envelope
        do { env = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw SourceError.decoding("Cathay ETF: \(error)") }

        guard let row = env.result.first(where: { $0.stockCode == stockCode }) else {
            throw SourceError.unavailable("Cathay ETF: \(stockCode) not found")
        }

        // Prior-close NAV (昨收淨值), used as the estimate's fallback and kept for reference.
        guard let closingStr = row.closingNavString ?? row.closingNav.map({ String($0) }),
              let closingNav = Parse.decimal(closingStr) else {
            throw SourceError.unavailable("Cathay ETF: \(stockCode) has no closingNav")
        }
        // Official current NAV = 預估淨值 (estimateNav), falling back to 昨收淨值 when absent.
        let estimate = (row.estimateNavString ?? row.estimateNav.map { String($0) }).flatMap(Parse.decimal).flatMap { $0 > 0 ? $0 : nil }
        let navDate = row.closingNavDate.flatMap(Parse.taipeiDate) ?? now
        let nav = OfficialNAV(value: estimate ?? closingNav, navDate: navDate, source: "Cathay 官方預估淨值", fetchedAt: now)

        // Price: live lastPrice, falling back to the prior close within the same record (pre-open).
        let priceValue = (row.lastPriceString ?? row.lastPrice.map { String($0) }).flatMap(Parse.decimal).flatMap { $0 > 0 ? $0 : nil }
            ?? (row.closingPriceString ?? row.closingPrice.map { String($0) }).flatMap(Parse.decimal)
        guard let priceValue else {
            throw SourceError.unavailable("Cathay ETF: \(stockCode) has no lastPrice/closingPrice")
        }
        let price = MarketPrice(price: priceValue, timestamp: now, source: "Cathay lastPrice")

        return CathayETF(nav: nav, price: price, closingNav: closingNav)
    }
}
