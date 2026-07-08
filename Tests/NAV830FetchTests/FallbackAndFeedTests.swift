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
}

final class FallbackPriceSourceTests: XCTestCase {
    private struct StubPrice: PriceSource {
        let outcome: Result<MarketPrice, SourceError>
        func fetchPrice() async throws -> MarketPrice { try outcome.get() }
    }
    private func price(_ p: String) -> MarketPrice {
        MarketPrice(price: Decimal(string: p)!, timestamp: Date(timeIntervalSince1970: 0), source: "stub")
    }

    func testUsesCathayFirst() async throws {
        let fb = FallbackPriceSource([
            StubPrice(outcome: .success(price("88.8"))),
            StubPrice(outcome: .success(price("88.65")))
        ])
        let result = try await fb.fetchPrice()
        XCTAssertEqual(dbl(result.price), 88.8, accuracy: 0.0001)
    }

    func testFallsBackToTWSEWhenCathayFails() async throws {
        let fb = FallbackPriceSource([
            StubPrice(outcome: .failure(.unavailable("cathay down"))),
            StubPrice(outcome: .success(price("88.65")))
        ])
        let result = try await fb.fetchPrice()
        XCTAssertEqual(dbl(result.price), 88.65, accuracy: 0.0001)
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
                // SOXX serves the frozen after-hours shape; SOXQ/SOXL serve the regular-session
                // (market-open) shape — both now parse, exercising both pairing paths at once.
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
        XCTAssertEqual(snap.report?.primary.session, .afterHours)
        // SOXX after-hours: NAV 91.68 × (576/581.51) ≈ 90.81; price 89.70 ⇒ ≈ −1.2% discount.
        XCTAssertEqual(dbl(snap.report!.primary.revaluedNAV), 90.81, accuracy: 0.05)
        XCTAssertLessThan(snap.report!.premium, 0)
        XCTAssertEqual(dbl(snap.report!.premium), -0.012, accuracy: 0.004)

        // All three proxies now parse (SOXX after-hours, SOXQ/SOXL regular-session).
        XCTAssertEqual(snap.statuses.first { $0.name == "Nasdaq SOXX" }?.ok, true)
        XCTAssertEqual(snap.statuses.first { $0.name == "Nasdaq SOXQ" }?.ok, true)
        XCTAssertEqual(snap.report?.crossChecks.count, 3)
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
