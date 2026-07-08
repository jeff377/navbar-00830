import Foundation
import NAV830Core

/// Everything the issuer's ETF page exposes for one fund in a single record.
public struct CathayETF: Sendable, Equatable {
    /// Latest official daily NAV (昨收淨值).
    public let nav: OfficialNAV
    /// Market price shown on the official page (最新市價), i.e. `lastPrice`.
    public let price: MarketPrice
    /// The issuer's own intraday estimated NAV (預估淨值) — regular-close based, no after-hours.
    /// Kept for reference/comparison against our post-market-adjusted revaluation.
    public let officialEstimateNav: Decimal?

    public init(nav: OfficialNAV, price: MarketPrice, officialEstimateNav: Decimal?) {
        self.nav = nav
        self.price = price
        self.officialEstimateNav = officialEstimateNav
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

        // NAV (prefer the string forms to avoid Double→Decimal drift).
        guard let navStr = row.closingNavString ?? row.closingNav.map({ String($0) }),
              let navValue = Parse.decimal(navStr) else {
            throw SourceError.unavailable("Cathay ETF: \(stockCode) has no closingNav")
        }
        let navDate = row.closingNavDate.flatMap(Parse.taipeiDate) ?? now
        let nav = OfficialNAV(value: navValue, navDate: navDate, source: "Cathay ETF NAV", fetchedAt: now)

        // Price: live lastPrice, falling back to the prior close within the same record (pre-open).
        let priceValue = (row.lastPriceString ?? row.lastPrice.map { String($0) }).flatMap(Parse.decimal).flatMap { $0 > 0 ? $0 : nil }
            ?? (row.closingPriceString ?? row.closingPrice.map { String($0) }).flatMap(Parse.decimal)
        guard let priceValue else {
            throw SourceError.unavailable("Cathay ETF: \(stockCode) has no lastPrice/closingPrice")
        }
        let price = MarketPrice(price: priceValue, timestamp: now, source: "Cathay lastPrice")

        let estimate = (row.estimateNavString ?? row.estimateNav.map { String($0) }).flatMap(Parse.decimal)
        return CathayETF(nav: nav, price: price, officialEstimateNav: estimate)
    }
}
