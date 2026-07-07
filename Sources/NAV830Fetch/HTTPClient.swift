import Foundation
import NAV830Core

/// Minimal HTTP GET abstraction. Sources depend on this rather than URLSession directly,
/// so tests can inject fixture bytes and run fully offline / deterministically.
public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> Data
}

/// Default `URLSession`-backed client. Treats any non-2xx status as `.network`.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 12) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.timeout = timeout
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SourceError.network("no HTTP response from \(url.host ?? "?")")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw SourceError.network("HTTP \(http.statusCode) from \(url.host ?? "?")")
            }
            return data
        } catch let error as SourceError {
            throw error
        } catch {
            throw SourceError.network("\(error.localizedDescription) (\(url.host ?? "?"))")
        }
    }
}

/// A desktop-browser User-Agent. Several of these endpoints (TWSE MIS, Nasdaq) reject
/// requests without a plausible UA.
let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
