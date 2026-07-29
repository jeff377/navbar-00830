import Foundation
import NAV830Core

/// One source's health for the popover status list.
public struct SourceStatus: Sendable, Equatable {
    public let name: String
    public let ok: Bool
    public let detail: String?
    /// The provider's own page for this figure, for checking the value by hand. Nil ⇒ no page.
    public let page: URL?
    public init(name: String, ok: Bool, detail: String? = nil, page: URL? = nil) {
        self.name = name
        self.ok = ok
        self.detail = detail
        self.page = page
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
    /// Raw proxy quotes — available even when `report` is nil (e.g. official NAV not settled yet),
    /// so the UI can still show the US after-hours move without a full revaluation.
    public let quotes: [ProxyQuote]
    public let statuses: [SourceStatus]
    public let generatedAt: Date

    public init(phase: MarketPhase, report: RevaluationReport?, officialNAV: OfficialNAV?, price: MarketPrice?, quotes: [ProxyQuote], statuses: [SourceStatus], generatedAt: Date) {
        self.phase = phase
        self.report = report
        self.officialNAV = officialNAV
        self.price = price
        self.quotes = quotes
        self.statuses = statuses
        self.generatedAt = generatedAt
    }
}

/// Unit FX (factor 1): the official NAV already includes the issuer's intraday FX adjustment, so
/// the revaluation must not apply FX a second time.
let noFXAdjustment = FXRate(current: 1, reference: nil, timestamp: Date(timeIntervalSince1970: 0), source: "included in official NAV")

/// Assembles a `FeedSnapshot` by fetching the inputs concurrently and feeding them through
/// `NAVCalculator`. This is the single entry point the presentation layer calls.
public struct DataFeed: Sendable {
    private let cathay: CathayETFSource
    private let price: any PriceSource
    private let proxies: FallbackProxySource
    private let clock: MarketClock
    private let now: @Sendable () -> Date

    public init(
        cathay: CathayETFSource,
        price: any PriceSource,
        proxies: FallbackProxySource,
        clock: MarketClock = MarketClock(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cathay = cathay
        self.price = price
        self.proxies = proxies
        self.clock = clock
        self.now = now
    }

    /// Convenience wiring for the live app: Cathay official NAV + TWSE MIS market price +
    /// Nasdaq SOXX/SOXQ/SOXL.
    public static func live(client: HTTPClient = URLSessionHTTPClient()) -> DataFeed {
        DataFeed(
            cathay: CathayETFSource(client: client),
            price: TWSEMISPriceSource(client: client),
            proxies: FallbackProxySource([
                NasdaqProxySource(symbol: .soxx, client: client),
                NasdaqProxySource(symbol: .soxq, client: client),
                NasdaqProxySource(symbol: .soxl, client: client)
            ])
        )
    }

    public func snapshot() async -> FeedSnapshot {
        async let cathayResult = result { try await cathay.fetch() }
        async let priceResult = result { try await price.fetchPrice() }
        async let proxyResult = proxies.fetchAll()

        let etf = await cathayResult
        let priceValue = await priceResult
        let (rawQuotes, proxyErrors) = await proxyResult

        // WARNING: a freshly fetched quote pairs its latest price with the newest completed US
        // close, which is one session too new from the moment the US closes until Taiwan next opens
        // (04:00–09:00 Taipei on weekdays, and all weekend). Left alone, that session's move is
        // silently dropped — a −4.4% Friday would show as a flat NAV all weekend. Quotes that
        // cannot be anchored are dropped rather than used raw, so a partial failure yields no
        // report instead of a premium measured from an unverified base.
        let quotes = await proxies.anchoredQuotes(rawQuotes, toNAVClose: (try? etf.get())?.nav.usCloseDate)

        var statuses: [SourceStatus] = [
            status("Cathay 官方淨值", etf, page: SourcePage.cathayEstimate),
            status("TWSE 市價", priceValue, page: SourcePage.twseMIS)
        ]
        for symbol in ProxySymbol.allCases {
            let page = SourcePage.nasdaq(symbol)
            if quotes.contains(where: { $0.symbol == symbol }) {
                statuses.append(SourceStatus(name: "Nasdaq \(symbol.rawValue)", ok: true, page: page))
            } else if let err = proxyErrors.first(where: { $0.0 == symbol })?.1 {
                statuses.append(SourceStatus(name: "Nasdaq \(symbol.rawValue)", ok: false, detail: describe(err), page: page))
            }
        }

        var report: RevaluationReport?
        if let etf = try? etf.get(), let price = try? priceValue.get(), !quotes.isEmpty {
            report = NAVCalculator.report(officialNAV: etf.nav, proxies: quotes, fx: noFXAdjustment, marketPrice: price)
        }

        return FeedSnapshot(
            phase: clock.phase(at: now()),
            report: report,
            officialNAV: (try? etf.get())?.nav,
            price: try? priceValue.get(),
            quotes: quotes,
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

    private func status<T>(_ name: String, _ r: Result<T, SourceError>, page: URL? = nil) -> SourceStatus {
        switch r {
        case .success: return SourceStatus(name: name, ok: true, page: page)
        case .failure(let e): return SourceStatus(name: name, ok: false, detail: describe(e), page: page)
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
