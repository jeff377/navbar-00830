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

        // The official NAV always already reflects the most recent *completed* regular close.
        // So `baseClose` must be that completed close, and `latestPrice` whatever came after it —
        // otherwise we re-apply a move the official NAV already contains (double-counting).
        let at = primary.lastTradeTimestamp.flatMap(Parse.nasdaqTimestamp) ?? Date()

        // Extended-hours present → freshest price; the completed close is `primary`.
        if let extStr = payload.secondaryData?.lastSalePrice, let ext = Parse.decimal(extStr) {
            let extAt = payload.secondaryData?.lastTradeTimestamp.flatMap(Parse.nasdaqTimestamp) ?? at
            return ProxyQuote(symbol: symbol, baseClose: regular, latestPrice: ext, latestAt: extAt, session: .afterHours)
        }

        // Regular session live → `primary` is a live tick, not a close. The completed close is the
        // previous one, recovered as lastSalePrice − netChange; the intraday move sits on top of it.
        if payload.marketStatus?.caseInsensitiveCompare("Open") == .orderedSame,
           let chgStr = primary.netChange, let change = Parse.decimal(chgStr) {
            return ProxyQuote(symbol: symbol, baseClose: regular - change, latestPrice: regular, latestAt: at, session: .regular)
        }

        // Closed, no extended data → frozen at the last completed regular close, which the official
        // NAV already reflects. base == latest ⇒ zero added move ⇒ revalued NAV == official NAV.
        return ProxyQuote(symbol: symbol, baseClose: regular, latestPrice: regular, latestAt: at, session: .frozen)
    }
}
