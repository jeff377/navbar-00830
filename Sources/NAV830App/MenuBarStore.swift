import Foundation
import SwiftUI
import NAV830Core
import NAV830Fetch

/// Drives the menu bar: holds the latest cached inputs, refreshes them on phase-tiered
/// cadences, recomputes the revaluation, and publishes formatted view state.
///
/// Tiering (PLAN §5): the 00830 price is the only thing that moves during the Taiwan session,
/// so it refreshes fast; the after-hours proxies are frozen then, so they refresh slowly. In
/// the US after-hours window the proxies move, so they refresh every tick.
@MainActor
final class MenuBarStore: ObservableObject {

    // Published view state.
    @Published private(set) var labelText: String = "00830 …"
    @Published private(set) var labelState: LabelState = .stale
    @Published private(set) var snapshot: FeedSnapshot?
    @Published var thresholdPct: Double {
        didSet {
            UserDefaults.standard.set(thresholdPct, forKey: Self.thresholdKey)
            recompute()
        }
    }

    static let thresholdKey = "discountThresholdPct"

    /// Called on the main actor after each publish so an AppKit host can refresh the status item.
    var onPublish: (() -> Void)?

    /// Launch-at-login toggle, backed by SMAppService.
    @Published var launchAtLogin: Bool {
        didSet { LoginItem.setEnabled(launchAtLogin) }
    }

    // Cached inputs.
    private var nav: OfficialNAV?
    private var fx: FXRate?
    private var quotes: [ProxyQuote] = []
    private var price: MarketPrice?
    private var statuses: [SourceStatus] = []
    private var lastMarketFetch: Date?

    // Wiring.
    private let navSource: any NAVSource
    private let proxySource: FallbackProxySource
    private let fxSource: any FXSource
    private let priceSource: any PriceSource
    private let clock = MarketClock()
    private var loopTask: Task<Void, Never>?

    init(client: HTTPClient = URLSessionHTTPClient()) {
        let stored = UserDefaults.standard.object(forKey: Self.thresholdKey) as? Double
        self.thresholdPct = stored ?? 3.0
        self.launchAtLogin = LoginItem.isEnabled
        self.navSource = CathayNAVSource(client: client)
        self.proxySource = FallbackProxySource([
            NasdaqProxySource(symbol: .soxx, client: client),
            NasdaqProxySource(symbol: .soxq, client: client),
            NasdaqProxySource(symbol: .soxl, client: client)
        ])
        self.fxSource = ERAPIFXSource(client: client)
        self.priceSource = TWSEMISPriceSource(client: client)
    }

    // MARK: - Lifecycle

    private var started = false

    /// Idempotent entry point called from the menu-bar label's `.task`. In demo mode it loads
    /// fixture numbers instead of starting the live refresh loop.
    func startOnce() {
        guard !started else { return }
        started = true
        if ProcessInfo.processInfo.environment["NAV830_DEMO"] == "1" {
            loadDemo()
        } else {
            start()
        }
    }

    func start() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in await self?.loop() }
    }

    func stop() { loopTask?.cancel() }

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

    func refreshNow() { Task { await refresh(phase: clock.phase(at: Date())) } }

    private func refresh(phase: MarketPhase) async {
        // Price: every tick.
        let priceResult = await capture { try await self.priceSource.fetchPrice() }
        if case .success(let p) = priceResult { price = p }

        // Market data: only when due.
        if marketDataDue(phase) {
            async let navR = capture { try await self.navSource.fetchNAV() }
            async let fxR = capture { try await self.fxSource.fetchFX(reference: nil) }
            let (freshQuotes, proxyErrors) = await proxySource.fetchAll()

            if case .success(let n) = await navR { nav = n }
            if case .success(let f) = await fxR { fx = f }
            if !freshQuotes.isEmpty { quotes = freshQuotes }
            statuses = buildStatuses(navR: await navR, fxR: await fxR, priceOK: price != nil, quotes: freshQuotes, proxyErrors: proxyErrors)
            lastMarketFetch = Date()
        }
        recompute()
    }

    private func recompute() {
        let phase = clock.phase(at: Date())
        let effectiveFX = fx ?? FXRate(current: 1, reference: nil, timestamp: Date(), source: "fallback(1.0)")
        var report: RevaluationReport?
        if let nav, let price, !quotes.isEmpty {
            report = NAVCalculator.report(officialNAV: nav, proxies: quotes, fx: effectiveFX, marketPrice: price)
        }
        let snap = FeedSnapshot(phase: phase, report: report, officialNAV: nav, price: price, fx: fx, statuses: statuses, generatedAt: Date())
        publish(snap)
    }

    private func publish(_ snap: FeedSnapshot) {
        snapshot = snap
        let fresh = isFresh(snap)
        labelState = LabelState.from(premium: snap.report?.premium, thresholdPct: thresholdPct, isFresh: fresh)
        if let premium = snap.report?.premium, fresh {
            labelText = "00830 \(Fmt.signedPct(premium))"
        } else {
            labelText = "00830 --"
        }
        onPublish?()
    }

    /// A snapshot is fresh if we have a report and its driving input is recent. During the Taiwan
    /// session the driver is the 00830 price; during US sessions the driver is the proxy, so the
    /// estimate stays live even though the Taiwan price is a stale last-close (PLAN §3, 僅供參考).
    private func isFresh(_ snap: FeedSnapshot) -> Bool {
        guard snap.report != nil else { return false }
        switch snap.phase {
        case .taiwanTrading:
            guard let ts = snap.price?.timestamp else { return false }
            return Date().timeIntervalSince(ts) <= 90
        case .usRegular, .usAfterHours:
            return true                 // US-driven estimate is live
        case .closed:
            guard let ts = snap.price?.timestamp else { return false }
            return Date().timeIntervalSince(ts) <= 12 * 3600
        }
    }

    // MARK: - Helpers

    private func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, SourceError> {
        do { return .success(try await body()) }
        catch let e as SourceError { return .failure(e) }
        catch { return .failure(.network("\(error)")) }
    }

    private func buildStatuses<A, B>(navR: Result<A, SourceError>, fxR: Result<B, SourceError>, priceOK: Bool, quotes: [ProxyQuote], proxyErrors: [(ProxySymbol, SourceError)]) -> [SourceStatus] {
        var out: [SourceStatus] = [
            SourceStatus(name: "Cathay NAV", ok: (try? navR.get()) != nil),
            SourceStatus(name: "TWSE 00830", ok: priceOK),
            SourceStatus(name: "open.er-api FX", ok: (try? fxR.get()) != nil)
        ]
        for symbol in ProxySymbol.allCases {
            let ok = quotes.contains { $0.symbol == symbol }
            out.append(SourceStatus(name: "Nasdaq \(symbol.rawValue)", ok: ok))
        }
        return out
    }

    // MARK: - Demo mode (visual verification without live market timing)

    /// Loads the PLAN §附錄 numbers as a taiwanTrading snapshot so the label/popover can be
    /// verified regardless of the current market phase. Enabled via NAV830_DEMO=1.
    func loadDemo() {
        let navFix = OfficialNAV(value: Decimal(string: "91.68")!, navDate: Date(), source: "demo", fetchedAt: Date())
        let soxx = ProxyQuote(symbol: .soxx, baseClose: Decimal(string: "581.51")!, latestPrice: Decimal(string: "576.00")!, latestAt: Date(), session: .afterHours)
        let soxq = ProxyQuote(symbol: .soxq, baseClose: Decimal(string: "95.00")!, latestPrice: Decimal(string: "94.10")!, latestAt: Date(), session: .afterHours)
        // Illustrative discount deep enough to trip the default 3% threshold, so the menu-bar
        // label renders in the alert color (verifies SwiftUI colours menu-bar text at all).
        // The appendix-accurate −1.0% case is covered by the Core unit tests.
        let priceFix = MarketPrice(price: Decimal(string: "87.50")!, timestamp: Date(), source: "demo")
        nav = navFix; quotes = [soxx, soxq]; price = priceFix
        fx = FXRate(current: Decimal(string: "32.08")!, reference: nil, timestamp: Date(), source: "demo")
        statuses = [
            SourceStatus(name: "Cathay NAV", ok: true),
            SourceStatus(name: "TWSE 00830", ok: true),
            SourceStatus(name: "open.er-api FX", ok: true),
            SourceStatus(name: "Nasdaq SOXX", ok: true),
            SourceStatus(name: "Nasdaq SOXQ", ok: true),
            SourceStatus(name: "Nasdaq SOXL", ok: false)
        ]
        lastMarketFetch = Date()
        recompute()
    }
}
