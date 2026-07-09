import Foundation
import NAV830Core

/// 00830 live market price from the TWSE MIS real-time snapshot (the exchange's own feed).
///
/// Preferred over the issuer's `lastPrice` because before the open the issuer is still computing
/// NAV and returns no price, whereas MIS always carries at least the previous close.
public struct TWSEMISPriceSource: PriceSource {
    private let client: HTTPClient
    private let now: @Sendable () -> Date

    public init(client: HTTPClient = URLSessionHTTPClient(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    public func fetchPrice() async throws -> MarketPrice {
        // The `_` cache-buster mirrors the browser client; MIS returns stale data without it.
        let ms = Int(now().timeIntervalSince1970 * 1000)
        let url = URL(string: "https://mis.twse.com.tw/stock/api/getStockInfo.jsp?ex_ch=tse_00830.tw&json=1&delay=0&_=\(ms)")!
        let data = try await client.get(url, headers: ["User-Agent": browserUserAgent])
        return try Self.parse(data)
    }

    private struct Envelope: Decodable {
        let msgArray: [Quote]
        struct Quote: Decodable {
            let z: String?       // last traded price — often "-" between matches / intraday
            let a: String?       // ask ladder, "_"-separated (best ask first)
            let b: String?       // bid ladder, "_"-separated (best bid first)
            let y: String?       // 昨收 (previous close)
            let tlong: String?   // epoch millis
        }
    }

    static func parse(_ data: Data) throws -> MarketPrice {
        let env: Envelope
        do { env = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw SourceError.decoding("TWSE MIS: \(error)") }

        guard let quote = env.msgArray.first else {
            throw SourceError.unavailable("TWSE MIS: empty msgArray")
        }
        // Price priority: last trade `z`; otherwise the live best bid/ask midpoint (MIS often
        // returns z="-" mid-session while the quote is live); otherwise the previous close `y`.
        let price = Parse.decimal(quote.z ?? "")
            ?? Self.bidAskMid(ask: quote.a, bid: quote.b)
            ?? Parse.decimal(quote.y ?? "")
        guard let price else {
            throw SourceError.unavailable("TWSE MIS: no price (z=\(quote.z ?? "nil"), y=\(quote.y ?? "nil"))")
        }
        let timestamp = quote.tlong.flatMap(Parse.epochMillis) ?? Date()
        return MarketPrice(price: price, timestamp: timestamp, source: "TWSE MIS")
    }

    /// Midpoint of the best bid and best ask, if both are present.
    private static func bidAskMid(ask: String?, bid: String?) -> Decimal? {
        func best(_ ladder: String?) -> Decimal? {
            ladder?.split(separator: "_").first.flatMap { Parse.decimal(String($0)) }
        }
        guard let a = best(ask), let b = best(bid) else { return nil }
        return (a + b) / 2
    }
}
