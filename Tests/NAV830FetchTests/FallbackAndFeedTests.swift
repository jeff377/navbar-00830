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

    func testQuoteAlreadyTiedToTheAnchorDayNeedsNoHistoryLookup() async {
        // REGRESSION (2026-07-30): during the live after-hours session the payload already carries
        // the anchor day's own close, dated. The historical table does not publish that day's row
        // until roughly an hour after the post-market session ends, so looking it up anyway landed
        // on the *previous* close and re-applied a session the NAV had already absorbed. `history:
        // nil` here means any lookup fails — the quote must survive without one.
        let live = ProxyQuote(symbol: .soxx, baseClose: dec("465.00"), baseCloseDate: etDay(2026, 7, 29),
                              latestPrice: dec("466.5966"), latestAt: Date(), session: .afterHours)
        let out = await FallbackProxySource([StubProxySource(symbol: .soxx, outcome: .success(live), history: nil)])
            .anchoredQuotes([live], toNAVClose: etDay(2026, 7, 29))
        XCTAssertEqual(dbl(out[0].baseClose), 465.00, accuracy: 0.0001)
        XCTAssertEqual(dbl(NAVCalculator.proxyReturn(out[0])), 0.0034, accuracy: 0.0002)
    }

    func testDropsQuoteWhenTheAnchorDaysCloseIsNotPublishedYet() async {
        // REGRESSION (2026-07-30): Nasdaq's historical table does not carry the day's row until
        // roughly an hour after post-market ends — the whole Taiwan pre-open. "On or before" then
        // hands back the *previous* session's close, which reapplies a move the official NAV
        // already holds (SOXQ: 07/28's 86.82 against 07/29's post print, −4.57% out of nothing).
        // Wednesday 2026-07-29 is a trading day, so a 07/28 close cannot be its close. The quote's
        // own base is 527.01 here — matching the published row to the cent, i.e. Nasdaq has not
        // rolled over either — so there is nothing to fall back on: drop.
        let out = await fb(history: DatedClose(close: dec("527.01"), date: etDay(2026, 7, 28)))
            .anchoredQuotes([fridayQuote()], toNAVClose: etDay(2026, 7, 29))
        XCTAssertTrue(out.isEmpty)
    }

    func testUsesTheQuotesOwnCloseWhileTheTableCatchesUp() async {
        // Same window, but the quote has rolled: its base (527.01) differs from the last published
        // close (491.46), so it is the anchor day's close and the estimate stays live through the
        // Taiwan pre-open instead of blanking for an hour. This is the SOXX side of 2026-07-29
        // 21:00 ET; SOXQ, still quoting the published close, is the case above.
        let out = await fb(history: DatedClose(close: dec("491.46"), date: etDay(2026, 7, 28)))
            .anchoredQuotes([fridayQuote()], toNAVClose: etDay(2026, 7, 29))
        XCTAssertEqual(dbl(out[0].baseClose), 527.01, accuracy: 0.0001)
        XCTAssertEqual(out[0].baseCloseDate, etDay(2026, 7, 29))
    }

    func testKeepsTheEarlierCloseWhenTheAnchorDayHadNoUSSession() async {
        // The same "older than the anchor" shape is legitimate when Wall Street was shut that day:
        // 2026-07-03 is Independence Day (observed) and Taiwan traded, so the NAV was struck
        // against Thursday 07/02's close. That must anchor, not drop.
        let out = await fb(history: DatedClose(close: dec("551.24"), date: etDay(2026, 7, 2)))
            .anchoredQuotes([fridayQuote()], toNAVClose: etDay(2026, 7, 3))
        XCTAssertEqual(dbl(out[0].baseClose), 551.24, accuracy: 0.0001)
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

    /// One coherent moment: 2026-07-07 10:00 Taipei — the Taiwan session, with the US day long
    /// over. Every proxy therefore serves the shape it really would then: the ETFs their retained
    /// post-market print, the index its standing 07/06 close, since it stops calculating at 16:00 ET.
    private func stubClient() -> StubHTTPClient {
        StubHTTPClient { url in
            let s = url.absoluteString
            if s.contains("mis.twse.com.tw") { return fixtureData("twse_mis_00830") }
            if s.contains("cwapi.cathaysite.com.tw") { return fixtureData("cathay_navlist") }
            // Anchor lookup: cathay_navlist is dated 2026/07/06, whose close each July-6 table also
            // carries — so anchoring is a no-op here and the expected numbers below are the pure
            // post-market move.
            if s.contains("historical") {
                return fixtureData(s.contains("/SOX/") ? "nasdaq_sox_historical_july06"
                                                       : "nasdaq_soxx_historical_july06")
            }
            if s.contains("api.nasdaq.com") {
                return s.contains("/SOX/") ? fixtureData("nasdaq_sox_closed")
                                           : fixtureData("nasdaq_soxx_afterhours")
            }
            return nil
        }
    }

    private func feed(_ client: StubHTTPClient) -> DataFeed {
        DataFeed(
            cathay: CathayETFSource(client: client),
            price: TWSEMISPriceSource(client: client),
            proxies: FallbackProxySource(ProxySymbol.preferenceOrder.map {
                NasdaqProxySource(symbol: $0, client: client)
            }),
            now: { at(2026, 7, 7, 10, 0, tz: "Asia/Taipei") }
        )
    }

    func testFullPipelineProducesDiscount() async {
        let snap = await feed(stubClient()).snapshot()

        XCTAssertEqual(snap.phase, .taiwanTrading)
        XCTAssertNotNil(snap.report, "essential inputs present ⇒ report built")
        // SOXQ leads, not SOX: the index is the preferred proxy but has nothing to say outside the
        // regular session, and not stepping aside here would discard the post-market move — the one
        // increment the official NAV lacks during the Taiwan session.
        XCTAssertEqual(snap.report?.primary.proxy, .soxq)
        XCTAssertEqual(snap.report?.primary.session, .afterHours)
        // Base = official estimateNav 91.94 × (576/581.51) ≈ 91.07; TWSE price 89.70 ⇒ ≈ −1.5% discount.
        XCTAssertEqual(dbl(snap.report!.primary.revaluedNAV), 91.07, accuracy: 0.05)
        XCTAssertLessThan(snap.report!.premium, 0)
        XCTAssertEqual(dbl(snap.report!.premium), -0.015, accuracy: 0.004)

        // The index still anchors and still shows — as a flat cross-check, measured from 07/06.
        let sox = snap.report?.crossChecks.first { $0.proxy == .sox }
        XCTAssertEqual(sox?.baseCloseDate, etDay(2026, 7, 6))
        XCTAssertEqual(dbl(sox?.proxyReturn ?? 1), 0, accuracy: 1e-9)

        XCTAssertEqual(snap.statuses.first { $0.name == "Nasdaq SOX" }?.ok, true)
        XCTAssertEqual(snap.statuses.first { $0.name == "Nasdaq SOXX" }?.ok, true)
        XCTAssertEqual(snap.report?.crossChecks.count, 4)
        XCTAssertEqual(snap.statuses.first { $0.name == "Cathay 官方淨值" }?.ok, true)
        XCTAssertEqual(snap.statuses.first { $0.name == "TWSE 市價" }?.ok, true)
    }

    func testSnapshotNeverThrowsWhenEverythingFails() async {
        let snap = await feed(StubHTTPClient { _ in nil }).snapshot()
        XCTAssertNil(snap.report, "no inputs ⇒ no report, but no crash")
        XCTAssertTrue(snap.statuses.allSatisfy { !$0.ok })
    }
}
