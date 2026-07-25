import XCTest
@testable import NAV830Fetch
import NAV830Core

final class FallbackProxySourceTests: XCTestCase {
    private func quote(_ s: ProxySymbol) -> ProxyQuote {
        ProxyQuote(symbol: s, baseClose: 100, latestPrice: 99, latestAt: Date(timeIntervalSince1970: 0), session: .afterHours)
    }

    func testPrefersFirstWorkingSource() async throws {
        // SOXX fails → SOXQ used (PLAN §8.4).
        let fb = FallbackProxySource([
            StubProxySource(symbol: .soxx, outcome: .failure(.network("down"))),
            StubProxySource(symbol: .soxq, outcome: .success(quote(.soxq)))
        ])
        let preferred = try await fb.fetchPreferred()
        XCTAssertEqual(preferred.symbol, .soxq)
    }

    func testFetchAllCollectsSuccessesAndErrors() async {
        let fb = FallbackProxySource([
            StubProxySource(symbol: .soxx, outcome: .success(quote(.soxx))),
            StubProxySource(symbol: .soxq, outcome: .failure(.unavailable("thin"))),
            StubProxySource(symbol: .soxl, outcome: .success(quote(.soxl)))
        ])
        let (quotes, errors) = await fb.fetchAll()
        XCTAssertEqual(Set(quotes.map(\.symbol)), [.soxx, .soxl])
        XCTAssertEqual(errors.map(\.0), [.soxq])
    }

    func testAllFailedWhenNoneSucceed() async {
        let fb = FallbackProxySource([
            StubProxySource(symbol: .soxx, outcome: .failure(.network("a"))),
            StubProxySource(symbol: .soxq, outcome: .failure(.network("b")))
        ])
        do {
            _ = try await fb.fetchPreferred()
            XCTFail("expected throw")
        } catch let SourceError.allFailed(errors) {
            XCTAssertEqual(errors.count, 2)
        } catch {
            XCTFail("expected .allFailed, got \(error)")
        }
    }

    // MARK: - Anchoring to the close the official NAV was struck against

    /// SOXX frozen at Friday's close (527.01, −4.40% on the day) with a post-market print of 527.00.
    /// As fetched it carries no base date — the quote endpoint cannot date its own close.
    private func fridayQuote() -> ProxyQuote {
        ProxyQuote(symbol: .soxx, baseClose: dec("527.01"),
                   latestPrice: dec("527.00"), latestAt: etDay(2026, 7, 24), session: .afterHours)
    }

    private func fb(history: DatedClose?) -> FallbackProxySource {
        FallbackProxySource([StubProxySource(symbol: .soxx, outcome: .success(fridayQuote()), history: history)])
    }

    func testAnchorsToTheNAVsCloseEvenThoughTheQuoteLooksCurrent() async {
        // The official NAV was struck Friday morning against Thursday's close, so Friday's −4.40%
        // is still missing from it. The quote's own 527.01/527.00 pairing hides that entirely.
        let out = await fb(history: DatedClose(close: dec("551.24"), date: etDay(2026, 7, 23)))
            .anchoredQuotes([fridayQuote()], toNAVClose: etDay(2026, 7, 23))
        XCTAssertEqual(dbl(out[0].baseClose), 551.24, accuracy: 0.0001)
        XCTAssertEqual(out[0].baseCloseDate, etDay(2026, 7, 23))
        XCTAssertEqual(dbl(NAVCalculator.proxyReturn(out[0])), -0.0440, accuracy: 0.0002)
    }

    func testAnchoringToTheSameSessionAddsNoMove() async {
        // Taiwan session: the NAV was struck against this very close, so the history lookup returns
        // it and the move collapses to the post-market drift — no double-counting.
        let out = await fb(history: DatedClose(close: dec("527.01"), date: etDay(2026, 7, 24)))
            .anchoredQuotes([fridayQuote()], toNAVClose: etDay(2026, 7, 24))
        XCTAssertEqual(dbl(out[0].baseClose), 527.01, accuracy: 0.0001)
        XCTAssertEqual(dbl(NAVCalculator.proxyReturn(out[0])), 0, accuracy: 1e-4)
    }

    func testDropsQuoteWhenTheBaseCannotBeEstablished() async {
        // A base we cannot tie to a trading day yields an arbitrary premium. Publishing that is
        // worse than publishing nothing — it reads as a real signal.
        let out = await fb(history: nil).anchoredQuotes([fridayQuote()], toNAVClose: etDay(2026, 7, 23))
        XCTAssertTrue(out.isEmpty)
    }

    func testDropsQuoteWhenTheNAVHasNoAnchorDate() async {
        let out = await fb(history: DatedClose(close: dec("551.24"), date: etDay(2026, 7, 23)))
            .anchoredQuotes([fridayQuote()], toNAVClose: nil)
        XCTAssertTrue(out.isEmpty)
    }

    func testHistoryIsLookedUpOncePerAnchorDate() async {
        // The anchor moves once a day; the app polls every 15s–5min. Re-requesting the historical
        // table on every tick would be pure waste (and extra rate-limit exposure).
        let counting = CountingProxySource(symbol: .soxx, quote: fridayQuote(),
                                           history: DatedClose(close: dec("551.24"), date: etDay(2026, 7, 23)))
        let fb = FallbackProxySource([counting])
        for _ in 0..<5 {
            _ = await fb.anchoredQuotes([fridayQuote()], toNAVClose: etDay(2026, 7, 23))
        }
        var calls = await counting.calls
        XCTAssertEqual(calls, 1)

        // A new anchor date must invalidate it rather than serve the previous session's close.
        _ = await fb.anchoredQuotes([fridayQuote()], toNAVClose: etDay(2026, 7, 24))
        calls = await counting.calls
        XCTAssertEqual(calls, 2)
    }
}

/// The full pipeline from raw recorded bytes to a premium/discount, wired exactly as the live
/// app, but with the network stubbed by fixtures.
final class DataFeedTests: XCTestCase {

    private func stubClient() -> StubHTTPClient {
        StubHTTPClient { url in
            let s = url.absoluteString
            if s.contains("mis.twse.com.tw") { return fixtureData("twse_mis_00830") }
            if s.contains("cwapi.cathaysite.com.tw") { return fixtureData("cathay_navlist") }
            // Anchor lookup: cathay_navlist is dated 2026/07/06, whose close (581.51) the SOXX
            // after-hours fixture also carries — so anchoring is a no-op here and the expected
            // numbers below are the pure post-market move.
            if s.contains("historical") { return fixtureData("nasdaq_soxx_historical_july06") }
            if s.contains("api.nasdaq.com") {
                // SOXX serves the frozen after-hours shape; SOXQ/SOXL serve the regular-session
                // (market-open) shape — both now parse, exercising both pairing paths at once.
                return s.contains("/SOXX/") ? fixtureData("nasdaq_soxx_afterhours") : fixtureData("nasdaq_soxx_open")
            }
            return nil
        }
    }

    private func feed(_ client: StubHTTPClient) -> DataFeed {
        DataFeed(
            cathay: CathayETFSource(client: client),
            price: TWSEMISPriceSource(client: client),
            proxies: FallbackProxySource([
                NasdaqProxySource(symbol: .soxx, client: client),
                NasdaqProxySource(symbol: .soxq, client: client),
                NasdaqProxySource(symbol: .soxl, client: client)
            ]),
            now: { at(2026, 7, 7, 10, 0, tz: "Asia/Taipei") }
        )
    }

    func testFullPipelineProducesDiscount() async {
        let snap = await feed(stubClient()).snapshot()

        XCTAssertEqual(snap.phase, .taiwanTrading)
        XCTAssertNotNil(snap.report, "essential inputs present ⇒ report built")
        XCTAssertEqual(snap.report?.primary.proxy, .soxx)
        XCTAssertEqual(snap.report?.primary.session, .afterHours)
        // Base = official estimateNav 91.94 × (576/581.51) ≈ 91.07; TWSE price 89.70 ⇒ ≈ −1.5% discount.
        XCTAssertEqual(dbl(snap.report!.primary.revaluedNAV), 91.07, accuracy: 0.05)
        XCTAssertLessThan(snap.report!.premium, 0)
        XCTAssertEqual(dbl(snap.report!.premium), -0.015, accuracy: 0.004)

        XCTAssertEqual(snap.statuses.first { $0.name == "Nasdaq SOXX" }?.ok, true)
        XCTAssertEqual(snap.report?.crossChecks.count, 3)
        XCTAssertEqual(snap.statuses.first { $0.name == "Cathay 官方淨值" }?.ok, true)
        XCTAssertEqual(snap.statuses.first { $0.name == "TWSE 市價" }?.ok, true)
    }

    func testSnapshotNeverThrowsWhenEverythingFails() async {
        let snap = await feed(StubHTTPClient { _ in nil }).snapshot()
        XCTAssertNil(snap.report, "no inputs ⇒ no report, but no crash")
        XCTAssertTrue(snap.statuses.allSatisfy { !$0.ok })
    }
}
