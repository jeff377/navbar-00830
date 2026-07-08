import Foundation
import NAV830Core

/// 00830 market price from Cathay's own `lastPrice` — the exact figure shown on the issuer's
/// official ETF estimate page (cathaysite.com.tw/ETF/estimate). Uses the same list endpoint the
/// NAV comes from, so the app matches what the user sees on the official site, and avoids the
/// TWSE MIS quirk where the last-trade field is "-" mid-session.
public struct CathayPriceSource: PriceSource {
    private let client: HTTPClient
    private let stockCode: String

    public init(client: HTTPClient = URLSessionHTTPClient(), stockCode: String = "00830") {
        self.client = client
        self.stockCode = stockCode
    }

    public func fetchPrice() async throws -> MarketPrice {
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
            let lastPrice: Double?
            let lastPriceString: String?
        }
    }

    static func parse(_ data: Data, stockCode: String, now: Date) throws -> MarketPrice {
        let env: Envelope
        do { env = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw SourceError.decoding("Cathay price: \(error)") }

        guard let row = env.result.first(where: { $0.stockCode == stockCode }) else {
            throw SourceError.unavailable("Cathay price: \(stockCode) not found")
        }
        guard let str = row.lastPriceString ?? row.lastPrice.map({ String($0) }),
              let price = Parse.decimal(str), price > 0 else {
            throw SourceError.unavailable("Cathay price: \(stockCode) has no lastPrice")
        }
        return MarketPrice(price: price, timestamp: now, source: "Cathay lastPrice")
    }
}
