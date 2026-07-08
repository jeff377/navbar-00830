import Foundation
import SwiftUI
import NAV830Core
import NAV830Fetch

/// Cross-platform view model: holds the latest cached inputs, refreshes them on phase-tiered
/// cadences, recomputes the revaluation, and publishes formatted view state. Shared by the macOS
/// menu-bar shell and the iOS app.
///
/// Tiering (PLAN §5): the 00830 price is the only thing that moves during the Taiwan session,
/// so it refreshes fast; the after-hours proxies are frozen then, so they refresh slowly. In
/// the US after-hours window the proxies move, so they refresh every tick.
@MainActor
public final class ETFStore: ObservableObject {

    // Published view state.
    @Published public private(set) var labelText: String = "00830 …"
    @Published public private(set) var labelState: LabelState = .muted
    @Published public private(set) var snapshot: FeedSnapshot?
    @Published public var thresholdPct: Double {
        didSet {
            UserDefaults.standard.set(thresholdPct, forKey: Self.thresholdKey)
            recompute()
        }
    }

    public static let thresholdKey = "discountThresholdPct"

    /// Called on the main actor after each publish so an AppKit host can refresh the status item.
    public var onPublish: (() -> Void)?

    #if os(macOS)
    /// Launch-at-login toggle, backed by SMAppService (macOS only).
    @Published public var launchAtLogin: Bool {
        didSet { LoginItem.setEnabled(launchAtLogin) }
    }
    #endif

    // Cached inputs.
    private var nav: OfficialNAV?
    private var quotes: [ProxyQuote] = []
    private var price: MarketPrice?
    private var statuses: [SourceStatus] = []
    private var lastMarketFetch: Date?
    /// When we last pulled *any* real value from a source. Note this is fetch-recency, not the
    /// value's own timestamp — while a market is closed the values are legitimately last-close but
    /// still the current best-known state, so we keep showing them.
    private var lastGoodFetch: Date?

    // Wiring.
    private let cathaySource: CathayETFSource   // official NAV + market price, one call
    private let proxySource: FallbackProxySource
    private let clock = MarketClock()
    private var loopTask: Task<Void, Never>?

    public init(client: HTTPClient = URLSessionHTTPClient()) {
        let stored = UserDefaults.standard.object(forKey: Self.thresholdKey) as? Double
        self.thresholdPct = stored ?? 3.0
        #if os(macOS)
        self.launchAtLogin = LoginItem.isEnabled
        #endif
        self.cathaySource = CathayETFSource(client: client)
        self.proxySource = FallbackProxySource([
            NasdaqProxySource(symbol: .soxx, client: client),
            NasdaqProxySource(symbol: .soxq, client: client),
            NasdaqProxySource(symbol: .soxl, client: client)
        ])
    }

    // MARK: - Lifecycle

    private var started = false

    /// Idempotent entry point called from the menu-bar label's `.task`. In demo mode it loads
    /// fixture numbers instead of starting the live refresh loop.
    public func startOnce() {
        guard !started else { return }
        started = true
        if ProcessInfo.processInfo.environment["NAV830_DEMO"] == "1" {
            loadDemo()
        } else {
            start()
        }
    }

    public func start() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in await self?.loop() }
    }

    public func stop() { loopTask?.cancel() }

    private func loop() async {
        while !Task.isCancelled {
            let phase = clock.phase(at: Date())
            await refresh(phase: phase)
            try? await Task.sleep(nanoseconds: UInt64(tickInterval(phase) * 1_000_000_000))
        }
    }

    /// Tick cadence: fast while Taiwan trades (price moves), medium in US after-hours
    /// (proxies move), slow when nothing is live.
    private func tickInterval(_ phase: MarketPhase) -> Double {
        switch phase {
        case .taiwanTrading: return 15
        case .usAfterHours, .usRegular: return 60
        case .closed: return 300
        }
    }

    /// Whether the (slow-moving) market data needs a refresh this tick.
    private func marketDataDue(_ phase: MarketPhase) -> Bool {
        guard let last = lastMarketFetch else { return true }
        switch phase {
        case .usAfterHours, .usRegular: return true          // proxies actively moving
        default: return Date().timeIntervalSince(last) >= 300 // frozen ⇒ every 5 min is plenty
        }
    }

    // MARK: - Refresh

    public func refreshNow() { Task { await refresh(phase: clock.phase(at: Date())) } }

    private func refresh(phase: MarketPhase) async {
        // Cathay ETF: NAV + market price in one call, every tick (the price moves during TW hours).
        let cathayResult = await capture { try await self.cathaySource.fetch() }
        if case .success(let etf) = cathayResult { nav = etf.nav; price = etf.price; lastGoodFetch = Date() }

        // Slower-moving inputs (US proxies): only when due.
        var proxyResult: (quotes: [ProxyQuote], errors: [(ProxySymbol, SourceError)]) = ([], [])
        var refreshedMarketData = false
        if marketDataDue(phase) {
            proxyResult = await proxySource.fetchAll()
            if !proxyResult.quotes.isEmpty { quotes = proxyResult.quotes; lastGoodFetch = Date() }
            lastMarketFetch = Date()
            refreshedMarketData = true
        }
        statuses = buildStatuses(cathay: cathayResult,
                                 quotes: refreshedMarketData ? proxyResult.quotes : quotes,
                                 proxyErrors: proxyResult.errors)
        recompute()
    }

    private func recompute() {
        let phase = clock.phase(at: Date())
        var report: RevaluationReport?
        if let nav, let price, !quotes.isEmpty {
            // Official NAV already includes intraday FX, so no separate FX factor (factor 1).
            let unitFX = FXRate(current: 1, reference: nil, timestamp: Date(), source: "included in official NAV")
            report = NAVCalculator.report(officialNAV: nav, proxies: quotes, fx: unitFX, marketPrice: price)
        }
        let snap = FeedSnapshot(phase: phase, report: report, officialNAV: nav, price: price, statuses: statuses, generatedAt: Date())
        publish(snap)
    }

    public private(set) var liveness: Liveness = .noData

    private func publish(_ snap: FeedSnapshot) {
        snapshot = snap
        let now = Date()
        let presentation = LabelPresentation.compute(
            premium: snap.report?.premium,
            phase: snap.report == nil ? nil : snap.phase,
            thresholdPct: thresholdPct,
            sinceGoodFetch: now.timeIntervalSince(lastGoodFetch ?? .distantPast),
            priceAge: snap.price.map { now.timeIntervalSince($0.timestamp) }
        )
        labelText = presentation.text
        labelState = presentation.state
        liveness = presentation.liveness
        onPublish?()
    }

    // MARK: - Helpers

    private func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, SourceError> {
        do { return .success(try await body()) }
        catch let e as SourceError { return .failure(e) }
        catch { return .failure(.network("\(error)")) }
    }

    private func buildStatuses(cathay: Result<CathayETF, SourceError>, quotes: [ProxyQuote], proxyErrors: [(ProxySymbol, SourceError)]) -> [SourceStatus] {
        var out = [SourceStatus(name: "Cathay 淨值/市價", ok: (try? cathay.get()) != nil)]
        for symbol in ProxySymbol.allCases {
            out.append(SourceStatus(name: "Nasdaq \(symbol.rawValue)", ok: quotes.contains { $0.symbol == symbol }))
        }
        return out
    }

    // MARK: - Demo mode (visual verification without live market timing)

    /// Loads the PLAN §附錄 numbers as a taiwanTrading snapshot so the label/popover can be
    /// verified regardless of the current market phase. Enabled via NAV830_DEMO=1.
    public func loadDemo() {
        let navFix = OfficialNAV(value: Decimal(string: "91.68")!, navDate: Date(), source: "demo", fetchedAt: Date())
        let soxx = ProxyQuote(symbol: .soxx, baseClose: Decimal(string: "581.51")!, latestPrice: Decimal(string: "576.00")!, latestAt: Date(), session: .afterHours)
        let soxq = ProxyQuote(symbol: .soxq, baseClose: Decimal(string: "95.00")!, latestPrice: Decimal(string: "94.10")!, latestAt: Date(), session: .afterHours)
        // Illustrative discount deep enough to trip the default 3% threshold, so the menu-bar
        // label renders in the alert color (verifies SwiftUI colours menu-bar text at all).
        // The appendix-accurate −1.0% case is covered by the Core unit tests.
        let priceFix = MarketPrice(price: Decimal(string: "87.50")!, timestamp: Date(), source: "demo")
        nav = navFix; quotes = [soxx, soxq]; price = priceFix
        statuses = [
            SourceStatus(name: "Cathay 淨值/市價", ok: true),
            SourceStatus(name: "Nasdaq SOXX", ok: true),
            SourceStatus(name: "Nasdaq SOXQ", ok: true),
            SourceStatus(name: "Nasdaq SOXL", ok: false)
        ]
        lastMarketFetch = Date()
        recompute()
    }
}
