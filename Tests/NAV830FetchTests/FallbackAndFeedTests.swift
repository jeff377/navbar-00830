import XCTest
@testable import NAV830Fetch
import NAV830Core

final class FallbackProxySourceTests: XCTestCase {
    private func quote(_ s: ProxySymbol) -> ProxyQuote {
        ProxyQuote(symbol: s, regularClose: 100, afterHoursPrice: 99, afterHoursAt: Date(timeIntervalSince1970: 0))
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
}

/// The M2 crown: the full pipeline from raw recorded bytes to a premium/discount, wired exactly
/// as the live app, but with the network stubbed by fixtures.
final class DataFeedTests: XCTestCase {

    private func stubClient() -> StubHTTPClient {
        StubHTTPClient { url in
            let s = url.absoluteString
            if s.contains("mis.twse.com.tw") { return fixtureData("twse_mis_00830") }
            if s.contains("open.er-api.com") { return fixtureData("erapi_usd") }
            if s.contains("cwapi.cathaysite.com.tw") { return fixtureData("cathay_navlist") }
            if s.contains("api.nasdaq.com") {
                // SOXX has frozen after-hours; SOXQ/SOXL fall back to the "market open" shape (no
                // after-hours) so the feed proves it degrades to whatever proxy has data.
                return s.contains("/SOXX/") ? fixtureData("nasdaq_soxx_afterhours") : fixtureData("nasdaq_soxx_open")
            }
            return nil
        }
    }

    func testFullPipelineProducesDiscount() async {
        let client = stubClient()
        // Fixed instant inside the Taiwan trading window.
        let now = at(2026, 7, 7, 10, 0, tz: "Asia/Taipei")
        let feed = DataFeed(
            nav: CathayNAVSource(client: client),
            proxies: FallbackProxySource([
                NasdaqProxySource(symbol: .soxx, client: client),
                NasdaqProxySource(symbol: .soxq, client: client),
                NasdaqProxySource(symbol: .soxl, client: client)
            ]),
            fx: ERAPIFXSource(client: client),
            price: TWSEMISPriceSource(client: client),
            now: { now }
        )

        let snap = await feed.snapshot()

        XCTAssertEqual(snap.phase, .taiwanTrading)
        XCTAssertNotNil(snap.report, "essential inputs present ⇒ report built")
        XCTAssertEqual(snap.report?.primary.proxy, .soxx)
        // NAV 91.68 × (1 − 0.95%) ≈ 90.81; price 89.70 ⇒ ≈ −1.2% discount.
        XCTAssertEqual(dbl(snap.report!.primary.revaluedNAV), 90.81, accuracy: 0.05)
        XCTAssertLessThan(snap.report!.premium, 0)
        XCTAssertEqual(dbl(snap.report!.premium), -0.012, accuracy: 0.004)

        // Only SOXX had after-hours data; SOXQ/SOXL surfaced as failed (US regular session shape).
        XCTAssertEqual(snap.statuses.first { $0.name == "Nasdaq SOXX" }?.ok, true)
        XCTAssertEqual(snap.statuses.first { $0.name == "Nasdaq SOXQ" }?.ok, false)
        XCTAssertEqual(snap.statuses.first { $0.name == "Cathay NAV" }?.ok, true)
    }

    func testSnapshotNeverThrowsWhenEverythingFails() async {
        let deadClient = StubHTTPClient { _ in nil }
        let feed = DataFeed(
            nav: CathayNAVSource(client: deadClient),
            proxies: FallbackProxySource([NasdaqProxySource(symbol: .soxx, client: deadClient)]),
            fx: ERAPIFXSource(client: deadClient),
            price: TWSEMISPriceSource(client: deadClient),
            now: { at(2026, 7, 7, 10, 0, tz: "Asia/Taipei") }
        )
        let snap = await feed.snapshot()
        XCTAssertNil(snap.report, "no inputs ⇒ no report, but no crash")
        XCTAssertTrue(snap.statuses.allSatisfy { !$0.ok })
    }
}
