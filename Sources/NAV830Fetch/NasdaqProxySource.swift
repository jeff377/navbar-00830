import Foundation
import NAV830Core

/// Proxy ETF quote from Nasdaq's public quote endpoint.
///
/// `primaryData` is the regular session, `secondaryData` the extended (pre/post-market) session.
/// We produce a phase-agnostic (baseClose, latestPrice) pair so the revaluation works whenever
/// there is any US price to apply (PLAN §3):
///   · extended-hours present  → latest = secondaryData, base = primaryData regular close
///   · regular session Open     → latest = primaryData (live), base = previous close (last − netChange)
///   · closed, no extended      → latest = primaryData (last close), base = previous close
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
            let marketStatus: String?
        }
        struct Tick: Decodable {
            let lastSalePrice: String?
            let netChange: String?
            let lastTradeTimestamp: String?
        }
    }

    static func parse(_ data: Data, symbol: ProxySymbol) throws -> ProxyQuote {
        let env: Envelope
        do { env = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw SourceError.decoding("Nasdaq \(symbol.rawValue): \(error)") }

        guard let payload = env.data, let primary = payload.primaryData,
              let regularStr = primary.lastSalePrice, let regular = Parse.decimal(regularStr) else {
            throw SourceError.unavailable("Nasdaq \(symbol.rawValue): no primary price (symbol not listed?)")
        }

        // Extended-hours present → it is the freshest price; base is the regular close (primary).
        if let extStr = payload.secondaryData?.lastSalePrice, let ext = Parse.decimal(extStr) {
            let at = payload.secondaryData?.lastTradeTimestamp.flatMap(Parse.nasdaqTimestamp) ?? Date()
            return ProxyQuote(symbol: symbol, baseClose: regular, latestPrice: ext, latestAt: at, session: .afterHours)
        }

        // No extended data. `primary` is the latest price (live if Open, else last close); the
        // base is the previous regular close, recovered as lastSalePrice − netChange.
        guard let chgStr = primary.netChange, let change = Parse.decimal(chgStr) else {
            throw SourceError.unavailable("Nasdaq \(symbol.rawValue): no netChange to derive base close")
        }
        let base = regular - change
        let at = primary.lastTradeTimestamp.flatMap(Parse.nasdaqTimestamp) ?? Date()
        let session: ProxySession = (payload.marketStatus?.caseInsensitiveCompare("Open") == .orderedSame) ? .regular : .frozen
        return ProxyQuote(symbol: symbol, baseClose: base, latestPrice: regular, latestAt: at, session: session)
    }
}
