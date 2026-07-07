import Foundation
import NAV830Core

/// One source's health for the popover status list.
public struct SourceStatus: Sendable, Equatable {
    public let name: String
    public let ok: Bool
    public let detail: String?
    public init(name: String, ok: Bool, detail: String? = nil) {
        self.name = name
        self.ok = ok
        self.detail = detail
    }
}

/// Everything the shell needs for one refresh: the revaluation report, the current market
/// phase, and per-source health. Never throws — partial failures are captured so the UI can
/// grey out stale values instead of showing nothing (PLAN §5).
public struct FeedSnapshot: Sendable {
    public let phase: MarketPhase
    public let report: RevaluationReport?
    public let officialNAV: OfficialNAV?
    public let price: MarketPrice?
    public let fx: FXRate?
    public let statuses: [SourceStatus]
    public let generatedAt: Date

    public init(phase: MarketPhase, report: RevaluationReport?, officialNAV: OfficialNAV?, price: MarketPrice?, fx: FXRate?, statuses: [SourceStatus], generatedAt: Date) {
        self.phase = phase
        self.report = report
        self.officialNAV = officialNAV
        self.price = price
        self.fx = fx
        self.statuses = statuses
        self.generatedAt = generatedAt
    }
}

/// Assembles a `FeedSnapshot` by fetching all four inputs concurrently and feeding them
/// through `NAVCalculator`. This is the single entry point the presentation layer calls;
/// it depends on the Core protocols, not on any concrete provider.
public struct DataFeed: Sendable {
    private let nav: any NAVSource
    private let proxies: FallbackProxySource
    private let fx: any FXSource
    private let price: any PriceSource
    private let clock: MarketClock
    private let now: @Sendable () -> Date

    public init(
        nav: any NAVSource,
        proxies: FallbackProxySource,
        fx: any FXSource,
        price: any PriceSource,
        clock: MarketClock = MarketClock(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.nav = nav
        self.proxies = proxies
        self.fx = fx
        self.price = price
        self.clock = clock
        self.now = now
    }

    /// Convenience wiring for the live app: Cathay NAV + Nasdaq SOXX/SOXQ/SOXL + er-api FX + TWSE price.
    public static func live(client: HTTPClient = URLSessionHTTPClient()) -> DataFeed {
        DataFeed(
            nav: CathayNAVSource(client: client),
            proxies: FallbackProxySource([
                NasdaqProxySource(symbol: .soxx, client: client),
                NasdaqProxySource(symbol: .soxq, client: client),
                NasdaqProxySource(symbol: .soxl, client: client)
            ]),
            fx: ERAPIFXSource(client: client),
            price: TWSEMISPriceSource(client: client)
        )
    }

    public func snapshot() async -> FeedSnapshot {
        async let navResult = result { try await nav.fetchNAV() }
        async let proxyResult = proxies.fetchAll()
        async let priceResult = result { try await price.fetchPrice() }

        let navValue = await navResult
        let (quotes, proxyErrors) = await proxyResult
        let priceValue = await priceResult

        // FX needs the reference from the NAV pricing; nil until we model it, so factor is 1.
        let fxValue = await result { try await fx.fetchFX(reference: nil) }

        var statuses: [SourceStatus] = []
        statuses.append(status("Cathay NAV", navValue))
        statuses.append(status("TWSE 00830", priceValue))
        statuses.append(status("open.er-api FX", fxValue))
        for symbol in ProxySymbol.allCases {
            if quotes.contains(where: { $0.symbol == symbol }) {
                statuses.append(SourceStatus(name: "Nasdaq \(symbol.rawValue)", ok: true))
            } else if let err = proxyErrors.first(where: { $0.0 == symbol })?.1 {
                statuses.append(SourceStatus(name: "Nasdaq \(symbol.rawValue)", ok: false, detail: describe(err)))
            }
        }

        let effectiveFX = (try? fxValue.get()) ?? FXRate(current: 1, reference: nil, timestamp: now(), source: "fallback(1.0)")

        var report: RevaluationReport?
        if let nav = try? navValue.get(), let price = try? priceValue.get(), !quotes.isEmpty {
            report = NAVCalculator.report(officialNAV: nav, proxies: quotes, fx: effectiveFX, marketPrice: price)
        }

        return FeedSnapshot(
            phase: clock.phase(at: now()),
            report: report,
            officialNAV: try? navValue.get(),
            price: try? priceValue.get(),
            fx: try? fxValue.get(),
            statuses: statuses,
            generatedAt: now()
        )
    }

    // MARK: - Helpers

    private func result<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, SourceError> {
        do { return .success(try await body()) }
        catch let e as SourceError { return .failure(e) }
        catch { return .failure(.network("\(error)")) }
    }

    private func status<T>(_ name: String, _ r: Result<T, SourceError>) -> SourceStatus {
        switch r {
        case .success: return SourceStatus(name: name, ok: true)
        case .failure(let e): return SourceStatus(name: name, ok: false, detail: describe(e))
        }
    }

    private func describe(_ e: SourceError) -> String {
        switch e {
        case .network(let m): return "network: \(m)"
        case .decoding(let m): return "decode: \(m)"
        case .unavailable(let m): return "n/a: \(m)"
        case .allFailed(let es): return "all failed (\(es.count))"
        }
    }
}
