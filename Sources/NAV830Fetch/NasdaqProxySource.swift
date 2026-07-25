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
        return ProxyQuote(symbol: symbol, baseClose: quote.baseClose, baseCloseDate: quote.baseCloseDate,
                          latestPrice: post, latestAt: quote.latestAt, session: .afterHours)
    }

    /// The last regular close on or before `date`, from Nasdaq's historical table. A window of
    /// two weeks back is requested so the lookup still lands on a close through a long holiday.
    public func regularClose(onOrBefore date: Date) async throws -> DatedClose {
        let from = Parse.easternDay(date, offsetByDays: -14)
        let url = URL(string: "https://api.nasdaq.com/api/quote/\(symbol.rawValue)/historical?assetclass=etf&fromdate=\(Self.isoDay(from))&todate=\(Self.isoDay(date))&limit=30")!
        guard let match = Self.parseHistorical(try await client.get(url, headers: headers), onOrBefore: date) else {
            throw SourceError.unavailable("Nasdaq \(symbol.rawValue): no regular close on or before \(Self.isoDay(date))")
        }
        return match
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

        // `baseClose` here is only a provisional pairing — "the newest completed close" — which is
        // the close the official NAV used ONLY while Taiwan is trading. The anchoring step replaces
        // it with the close dated to `OfficialNAV.usCloseDate` before any math runs, so
        // `baseCloseDate` is deliberately left nil: this endpoint cannot date its own close.
        //
        // WARNING: do NOT date it from `lastTradeTimestamp`. That field is not the trading day of
        // `lastSalePrice` — it rolls backwards on its own while the price stays put. Observed
        // 2026-07-25: $527.01 (Friday 07/24's close, confirmed by netChange and the historical
        // table) was stamped "Jul 24, 2026" at 21:13 ET Friday and "Jul 23, 2026" at 02:13 ET
        // Saturday, on all three symbols. Trusting it made the revaluation flip between correct
        // and wrong as the label moved. The historical table is the only dated source here.
        let at = primary.lastTradeTimestamp.flatMap(Parse.nasdaqTimestamp) ?? Date()
        let status = (payload.marketStatus ?? "").lowercased()

        // WARNING: Nasdaq swaps the roles of primaryData/secondaryData between sessions. While the
        // regular session is Open *or* in Pre-Market, `primaryData` is a LIVE tick (not a close)
        // and `secondaryData` — if present — holds the *previous regular close* ("Closed at …
        // 4:00 PM ET"), the reverse of the after-hours layout. Reading secondaryData as "the newer
        // price" in Pre-Market inverts the sign (a −4.6% pre-market read as +4.9%). So the
        // live-tick cases must be decided first, and their base recovered from netChange —
        // which equals the previous close in both.
        let isLiveTick = status == "open" || status.contains("pre-market") || status.contains("premarket")
        if isLiveTick, let chgStr = primary.netChange, let change = Parse.decimal(chgStr) {
            return ProxyQuote(symbol: symbol, baseClose: regular - change,
                              latestPrice: regular, latestAt: at,
                              session: status == "open" ? .regular : .preMarket)
        }

        // Post-market: `primary` is the completed regular close, `secondaryData` the newer print.
        if let extStr = payload.secondaryData?.lastSalePrice, let ext = Parse.decimal(extStr) {
            let extAt = payload.secondaryData?.lastTradeTimestamp.flatMap(Parse.nasdaqTimestamp) ?? at
            return ProxyQuote(symbol: symbol, baseClose: regular, latestPrice: ext, latestAt: extAt, session: .afterHours)
        }

        // Closed, no extended data → frozen at the last completed regular close. fetchQuote may
        // top this up with the retained post-market close.
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

    // MARK: - Historical closes

    private struct HistoricalEnvelope: Decodable {
        let data: HistData?
        struct HistData: Decodable {
            let tradesTable: TradesTable?
            struct TradesTable: Decodable {
                let rows: [Row]?
                struct Row: Decodable {
                    let date: String?
                    let close: String?
                }
            }
        }
    }

    /// The newest historical close whose trading day is on or before `date`. Rows arrive
    /// newest-first, but they are compared explicitly rather than trusting that order.
    static func parseHistorical(_ data: Data, onOrBefore date: Date) -> DatedClose? {
        guard let env = try? JSONDecoder().decode(HistoricalEnvelope.self, from: data),
              let rows = env.data?.tradesTable?.rows else { return nil }
        let cutoff = Parse.easternDay(date)
        return rows
            .compactMap { row -> DatedClose? in
                guard let dayStr = row.date, let day = Parse.nasdaqHistoricalDate(dayStr),
                      let closeStr = row.close, let close = Parse.decimal(closeStr) else { return nil }
                return day <= cutoff ? DatedClose(close: close, date: day) : nil
            }
            .max { $0.date < $1.date }
    }

    private static func isoDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
