import Foundation
import NAV830Core

/// 00830 live market price from the TWSE MIS real-time snapshot endpoint.
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

    // MARK: - Decoding

    private struct Envelope: Decodable {
        let msgArray: [Quote]
        struct Quote: Decodable {
            let z: String?       // last traded price (today) — "-" before the first trade
            let y: String?       // 昨收 (previous close) — the last-known price pre-open
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
        // Before the first trade of the day (pre-open / no-quote gap) `z` is "-"; fall back to the
        // previous close `y`, which is the last-known 00830 price the revaluation compares against.
        let price = quote.z.flatMap(Parse.decimal) ?? quote.y.flatMap(Parse.decimal)
        guard let price else {
            throw SourceError.unavailable("TWSE MIS: no price (z=\(quote.z ?? "nil"), y=\(quote.y ?? "nil"))")
        }
        let timestamp = quote.tlong.flatMap(Parse.epochMillis) ?? Date()
        return MarketPrice(price: price, timestamp: timestamp, source: "TWSE MIS")
    }
}
