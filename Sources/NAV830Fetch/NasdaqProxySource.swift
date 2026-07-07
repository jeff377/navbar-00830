import Foundation
import NAV830Core

/// Proxy ETF quote from Nasdaq's public quote endpoint.
///
/// `primaryData` is the regular session, `secondaryData` the extended (pre/post-market)
/// session. During the Taiwan trading window the US market is closed and after-hours has
/// ended, so Nasdaq serves a frozen `primaryData` (that session's regular close) plus a
/// frozen `secondaryData` (its after-hours close) — exactly the pairing the revaluation needs.
///
/// When the US regular session is in progress, `secondaryData` is null and `primaryData` is a
/// live intraday tick, not a close; `fetchQuote` reports `.unavailable` in that case because
/// there is no valid after-hours increment to apply. The shell keys off `MarketPhase` and does
/// not call this in that window.
public struct NasdaqProxySource: ProxySource {
    public let symbol: ProxySymbol
    private let client: HTTPClient

    public init(symbol: ProxySymbol, client: HTTPClient = URLSessionHTTPClient()) {
        self.symbol = symbol
        self.client = client
    }

    public func fetchQuote() async throws -> ProxyQuote {
        let url = URL(string: "https://api.nasdaq.com/api/quote/\(symbol.rawValue)/info?assetclass=etf")!
        let data = try await client.get(url, headers: [
            "User-Agent": browserUserAgent,
            "Accept": "application/json"
        ])
        return try Self.parse(data, symbol: symbol)
    }

    // MARK: - Decoding

    private struct Envelope: Decodable {
        let data: Payload?
        struct Payload: Decodable {
            let primaryData: Tick?
            let secondaryData: Tick?
        }
        struct Tick: Decodable {
            let lastSalePrice: String?
            let lastTradeTimestamp: String?
        }
    }

    static func parse(_ data: Data, symbol: ProxySymbol) throws -> ProxyQuote {
        let env: Envelope
        do { env = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw SourceError.decoding("Nasdaq \(symbol.rawValue): \(error)") }

        guard let payload = env.data else {
            throw SourceError.unavailable("Nasdaq \(symbol.rawValue): no data (symbol not listed?)")
        }
        guard
            let regularStr = payload.primaryData?.lastSalePrice,
            let regularClose = Parse.decimal(regularStr)
        else {
            throw SourceError.unavailable("Nasdaq \(symbol.rawValue): no regular price")
        }
        guard
            let afterStr = payload.secondaryData?.lastSalePrice,
            let afterHours = Parse.decimal(afterStr)
        else {
            throw SourceError.unavailable("Nasdaq \(symbol.rawValue): no after-hours print (US regular session in progress?)")
        }
        let afterAt = payload.secondaryData?.lastTradeTimestamp.flatMap(Parse.nasdaqTimestamp) ?? Date()
        return ProxyQuote(symbol: symbol, regularClose: regularClose, afterHoursPrice: afterHours, afterHoursAt: afterAt)
    }
}
