import Foundation
import NAV830Core

/// The issuer's official NAV for one fund.
public struct CathayETF: Sendable, Equatable {
    /// The official current NAV shown on the page (預估淨值 / estimateNav) — the number the user
    /// compares against. It already reflects the regular US close *and* the issuer's intraday FX
    /// adjustment, so the revaluation adds only the after-hours move on top and needs no separate
    /// FX factor. Falls back to the prior-close NAV (昨收淨值) when the estimate is absent
    /// (e.g. before the open, while the issuer is still striking the NAV).
    public let nav: OfficialNAV
    /// Prior-day close NAV (昨收淨值), for reference.
    public let closingNav: Decimal

    public init(nav: OfficialNAV, closingNav: Decimal) {
        self.nav = nav
        self.closingNav = closingNav
    }
}

/// Fetches 00830's official NAV from the Cathay endpoint that backs cathaysite.com.tw/ETF/estimate.
/// (The market price comes from TWSE MIS instead — the issuer's price is empty before the open.)
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

        // Prior-close NAV (昨收淨值). Before the open the issuer has not settled it yet — the
        // field reads "未結出" and the intraday estimate is "--" — so no NAV is available then.
        guard let closingStr = row.closingNavString ?? row.closingNav.map({ String($0) }),
              let closingNav = Parse.decimal(closingStr) else {
            throw SourceError.unavailable("Cathay ETF: \(stockCode) NAV not settled yet (closingNav=\(row.closingNavString ?? "nil"))")
        }
        // Official current NAV = 預估淨值 (estimateNav), falling back to 昨收淨值 when absent.
        let estimate = (row.estimateNavString ?? row.estimateNav.map { String($0) }).flatMap(Parse.decimal).flatMap { $0 > 0 ? $0 : nil }
        let navDate = row.closingNavDate.flatMap(Parse.taipeiDate) ?? now
        let nav = OfficialNAV(value: estimate ?? closingNav, navDate: navDate, source: "Cathay 官方預估淨值", fetchedAt: now)
        return CathayETF(nav: nav, closingNav: closingNav)
    }
}
