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
            let z: String?       // 最近成交價 — "-" when no match in this snapshot
            let pz: String?      // 揭示價 — the disclosed price, a real tick-aligned quote
            let o: String?       // 開盤價 — "-" until the session has traded
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
        let timestamp = quote.tlong.flatMap(Parse.epochMillis) ?? Date()

        // Only ever report a REAL, tick-aligned price. 00830 trades in 0.05 steps, so a computed
        // bid/ask midpoint (e.g. 83.125) is a price that cannot exist — never synthesise one.
        // `z` is the last match; `pz` (揭示價) is the disclosed price and is present in many
        // snapshots where `z` reads "-".
        if let price = Parse.decimal(quote.z ?? "") ?? Parse.decimal(quote.pz ?? "") {
            return MarketPrice(price: price, timestamp: timestamp, source: "TWSE MIS")
        }

        // No trade price in this snapshot. Before the session has traded (no open price) the
        // previous close is the correct last-known value. Once trading has started, a missing
        // print is transient — fail so the caller keeps its cached live price instead of
        // regressing the display to yesterday's close.
        let hasTradedToday = Parse.decimal(quote.o ?? "") != nil
        if !hasTradedToday, let prevClose = Parse.decimal(quote.y ?? "") {
            return MarketPrice(price: prevClose, timestamp: timestamp, source: "TWSE 昨收")
        }
        throw SourceError.unavailable("TWSE MIS: no trade price this snapshot (z=\(quote.z ?? "nil"), pz=\(quote.pz ?? "nil"))")
    }
}
