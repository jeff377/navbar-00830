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

    // MARK: - Re-anchoring to the close the official NAV was struck against

    /// SOXX frozen at Friday's close (527.01, −4.40% on the day), with the official NAV still the
    /// one struck on Friday morning against Thursday's close (551.24). This is the weekend state:
    /// Taiwan does not reopen until Monday, so the NAV cannot absorb Friday's drop before then.
    private func fridayQuote() -> ProxyQuote {
        ProxyQuote(symbol: .soxx, baseClose: dec("527.01"), baseCloseDate: etDay(2026, 7, 24),
                   latestPrice: dec("527.00"), latestAt: etDay(2026, 7, 24), session: .afterHours)
    }

    func testReanchorsWhenTheNAVPredatesTheNewestClose() async {
        let fb = FallbackProxySource([
            StubProxySource(symbol: .soxx, outcome: .success(fridayQuote()),
                            history: DatedClose(close: dec("551.24"), date: etDay(2026, 7, 23)))
        ])
        let out = await fb.reanchor([fridayQuote()], toNAVClose: etDay(2026, 7, 23))
        XCTAssertEqual(dbl(out[0].baseClose), 551.24, accuracy: 0.0001)
        XCTAssertEqual(out[0].baseCloseDate, etDay(2026, 7, 23))
        // Without this the −4.40% Friday session vanishes and the revalued NAV equals the
        // official one all weekend — the bug this guards.
        XCTAssertEqual(dbl(NAVCalculator.proxyReturn(out[0])), -0.0440, accuracy: 0.0002)
    }

    func testDoesNotReanchorWhenTheNAVAlreadyHasThatClose() async {
        // Taiwan session: the NAV was struck against exactly this close, so re-applying the move
        // would double-count it.
        let fb = FallbackProxySource([
            StubProxySource(symbol: .soxx, outcome: .success(fridayQuote()),
                            history: DatedClose(close: dec("551.24"), date: etDay(2026, 7, 23)))
        ])
        let out = await fb.reanchor([fridayQuote()], toNAVClose: etDay(2026, 7, 24))
        XCTAssertEqual(dbl(out[0].baseClose), 527.01, accuracy: 0.0001)
        // Only the 1-cent post-market drift against the close remains, not the day's −4.40%.
        XCTAssertEqual(dbl(NAVCalculator.proxyReturn(out[0])), 0, accuracy: 1e-4)
    }

    func testKeepsQuoteWhenHistoryLookupFails() async {
        // Degrade rather than blank the popover: a stale base is still a usable estimate.
        let fb = FallbackProxySource([StubProxySource(symbol: .soxx, outcome: .success(fridayQuote()), history: nil)])
        let out = await fb.reanchor([fridayQuote()], toNAVClose: etDay(2026, 7, 23))
        XCTAssertEqual(dbl(out[0].baseClose), 527.01, accuracy: 0.0001)
    }

    func testUndatedBaseIsLeftAlone() async {
        // A live regular-session tick carries no base date — its base is the previous close, which
        // is what the NAV used anyway.
        let live = ProxyQuote(symbol: .soxx, baseClose: dec("551.24"), latestPrice: dec("530.00"),
                              latestAt: etDay(2026, 7, 24), session: .regular)
        let fb = FallbackProxySource([
            StubProxySource(symbol: .soxx, outcome: .success(live),
                            history: DatedClose(close: dec("999"), date: etDay(2026, 7, 23)))
        ])
        let out = await fb.reanchor([live], toNAVClose: etDay(2026, 7, 23))
        XCTAssertEqual(dbl(out[0].baseClose), 551.24, accuracy: 0.0001)
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
