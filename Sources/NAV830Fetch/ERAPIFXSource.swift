import Foundation
import NAV830Core

/// USD/TWD from open.er-api.com (free, no key, no consent wall).
///
/// NOTE: this feed updates roughly once daily. During the Taiwan session FX is the only
/// moving input to the revalued NAV, but its contribution is < 0.5% (PLAN §6), so a daily
/// rate is acceptable for v1. An intraday USD/TWD source is a future refinement.
public struct ERAPIFXSource: FXSource {
    private let client: HTTPClient

    public init(client: HTTPClient = URLSessionHTTPClient()) {
        self.client = client
    }

    public func fetchFX(reference: Decimal?) async throws -> FXRate {
        let url = URL(string: "https://open.er-api.com/v6/latest/USD")!
        let data = try await client.get(url, headers: [:])
        return try Self.parse(data, reference: reference)
    }

    // MARK: - Decoding

    private struct Envelope: Decodable {
        let result: String
        let time_last_update_unix: Double?
        let rates: [String: Double]
    }

    static func parse(_ data: Data, reference: Decimal?) throws -> FXRate {
        let env: Envelope
        do { env = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw SourceError.decoding("er-api: \(error)") }

        guard env.result == "success" else {
            throw SourceError.unavailable("er-api: result=\(env.result)")
        }
        guard let twd = env.rates["TWD"] else {
            throw SourceError.unavailable("er-api: TWD not present")
        }
        // Route through String so the Double's binary representation does not leak into Decimal.
        guard let current = Decimal(string: String(twd)) else {
            throw SourceError.decoding("er-api: TWD not decimal (\(twd))")
        }
        let timestamp = env.time_last_update_unix.map { Date(timeIntervalSince1970: $0) } ?? Date()
        return FXRate(current: current, reference: reference, timestamp: timestamp, source: "open.er-api.com")
    }
}
