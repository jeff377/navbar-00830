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
