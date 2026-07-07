import Foundation
import NAV830Core

/// Latest official daily NAV of 00830 from Cathay's public ETF list endpoint.
///
/// The endpoint returns every Cathay ETF; we select `stockCode == "00830"` and read
/// `closingNav` (昨收淨值) + `closingNavDate`. This is published daily-close data and needs
/// no consent flow. The sibling `estimateNav` (the 15-second official intraday iNAV) is
/// deliberately ignored here — that is the consent-gated calibration deferred to M5.
public struct CathayNAVSource: NAVSource {
    private let client: HTTPClient
    private let stockCode: String

    public init(client: HTTPClient = URLSessionHTTPClient(), stockCode: String = "00830") {
        self.client = client
        self.stockCode = stockCode
    }

    public func fetchNAV() async throws -> OfficialNAV {
        let url = URL(string: "https://cwapi.cathaysite.com.tw/api/ETF/GetRealTimeEstimateNavList")!
        let data = try await client.get(url, headers: [
            "User-Agent": browserUserAgent,
            "Accept": "application/json"
        ])
        return try Self.parse(data, stockCode: stockCode, fetchedAt: Date())
    }

    // MARK: - Decoding

    private struct Envelope: Decodable {
        let result: [Row]
        struct Row: Decodable {
            let stockCode: String?
            let closingNav: Double?
            let closingNavString: String?
            let closingNavDate: String?
        }
    }

    static func parse(_ data: Data, stockCode: String, fetchedAt: Date) throws -> OfficialNAV {
        let env: Envelope
        do { env = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw SourceError.decoding("Cathay NAV list: \(error)") }

        guard let row = env.result.first(where: { $0.stockCode == stockCode }) else {
            throw SourceError.unavailable("Cathay NAV list: \(stockCode) not found")
        }
        // Prefer the string form to avoid Double→Decimal binary drift.
        guard let navStr = row.closingNavString ?? row.closingNav.map({ String($0) }),
              let nav = Parse.decimal(navStr) else {
            throw SourceError.unavailable("Cathay NAV list: \(stockCode) has no closingNav")
        }
        let navDate = row.closingNavDate.flatMap(Parse.taipeiDate) ?? fetchedAt
        return OfficialNAV(value: nav, navDate: navDate, source: "Cathay ETF NAV", fetchedAt: fetchedAt)
    }
}
