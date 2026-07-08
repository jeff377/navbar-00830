import Foundation
import NAV830Core

/// Proxy ETF quote from Nasdaq's public quote endpoint.
///
/// `primaryData` is the regular session, `secondaryData` the extended (pre/post-market) session.
/// We produce a phase-agnostic (baseClose, latestPrice) pair so the revaluation works whenever
/// there is any US price to apply (PLAN §3):
///   · extended-hours present  → latest = secondaryData, base = primaryData regular close
///   · regular session Open     → latest = primaryData (live), base = previous close (last − netChange)
///   · closed, no extended      → frozen at the regular close, then topped up with the retained
///                                post-market close from the `extended-trading` endpoint
///
/// The last case matters during the Taiwan session: post-market has ended (so `info` drops
/// `secondaryData`), but the frozen 20:00 ET post-market close is exactly the increment the
/// official daily NAV (a 16:00 ET regular-close value) still lacks. Nasdaq's `extended-trading`
/// endpoint retains it overnight, so we fetch it to apply the post-market move (PLAN §2).
public struct NasdaqProxySource: ProxySource {
    public let symbol: ProxySymbol
    private let client: HTTPClient

    public init(symbol: ProxySymbol, client: HTTPClient = URLSessionHTTPClient()) {
        self.symbol = symbol
        self.client = client
    }

    private var headers: [String: String] {
        ["User-Agent": browserUserAgent, "Accept": "application/json"]
    }

    public func fetchQuote() async throws -> ProxyQuote {
        let url = URL(string: "https://api.nasdaq.com/api/quote/\(symbol.rawValue)/info?assetclass=etf")!
        let quote = try Self.parse(await client.get(url, headers: headers), symbol: symbol)

        // Frozen (post-market over): recover the retained post-market close and apply it on top of
        // the regular close, so the Taiwan-session estimate reflects the after-hours move.
        guard quote.session == .frozen else { return quote }
        let extURL = URL(string: "https://api.nasdaq.com/api/quote/\(symbol.rawValue)/extended-trading?assetclass=etf&markettype=post&marketMode=1")!
        guard let extData = try? await client.get(extURL, headers: headers),
              let post = Self.parseExtendedPost(extData),
              isPlausible(post, base: quote.baseClose) else {
            return quote
        }
        return ProxyQuote(symbol: symbol, baseClose: quote.baseClose, latestPrice: post, latestAt: quote.latestAt, session: .afterHours)
    }

    /// Reject a post-market price that is grossly off the regular close — a sign the two endpoints
    /// are showing different sessions. A genuine post-market move is at most a few percent (×3 for
    /// SOXL), so 30% × leverage is a wide safety margin, not a real-move filter.
    private func isPlausible(_ post: Decimal, base: Decimal) -> Bool {
        guard base != 0 else { return false }
        let move = abs((post - base) / base)
        return move <= Decimal(0.30 * Double(symbol.leverage))
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
        // fetchQuote may then top this up with the retained post-market close.
        return ProxyQuote(symbol: symbol, baseClose: regular, latestPrice: regular, latestAt: at, session: .frozen)
    }

    // MARK: - Extended-trading (retained post-market close)

    private struct ExtendedEnvelope: Decodable {
        let data: ExtData?
        struct ExtData: Decodable {
            let infoTable: InfoTable?
            struct InfoTable: Decodable {
                let rows: [Row]?
                struct Row: Decodable { let consolidated: String? }
            }
        }
    }

    /// The post-market consolidated last trade, e.g. "$544.6 -36.91 (-6.35%)" → 544.6.
    static func parseExtendedPost(_ data: Data) -> Decimal? {
        guard let env = try? JSONDecoder().decode(ExtendedEnvelope.self, from: data),
              let consolidated = env.data?.infoTable?.rows?.first?.consolidated,
              let firstToken = consolidated.split(separator: " ").first else {
            return nil
        }
        return Parse.decimal(String(firstToken))
    }
}
