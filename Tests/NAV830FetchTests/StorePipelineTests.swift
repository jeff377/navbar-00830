import XCTest
@testable import NAV830Fetch
import NAV830Core
import NAV830UI

/// `ETFStore` is what the shipped app actually runs — it assembles the revaluation itself rather
/// than calling `DataFeed`, keeping each input's last good value across ticks. That duplication
/// has already cost one release: the base-close re-anchor was added to `DataFeed` alone, every
/// `DataFeed` test went green, and the menu bar still showed the unadjusted NAV. These tests
/// exercise the store's own path so the two cannot silently diverge again.
@MainActor
final class StorePipelineTests: XCTestCase {

    /// Cathay's NAV is dated 2026/07/06 while Nasdaq has already closed 07/07 — the state between
    /// a US close and Taiwan's next open, when the newest close is not yet in the official NAV.
    private func staleNAVClient() -> StubHTTPClient {
        StubHTTPClient { url in
            let s = url.absoluteString
            if s.contains("mis.twse.com.tw") { return fixtureData("twse_mis_00830") }
            if s.contains("cwapi.cathaysite.com.tw") { return fixtureData("cathay_navlist") }
            if s.contains("historical") { return fixtureData("nasdaq_soxx_historical_july06") }
            if s.contains("extended-trading") { return nil }   // no retained post-market print
            if s.contains("/info") { return fixtureData("nasdaq_soxx_frozen") }
            return nil
        }
    }

    func testStoreReanchorsToTheCloseTheNAVUsed() async {
        let store = ETFStore(client: staleNAVClient())
        await store.refreshOnce()

        let primary = try? XCTUnwrap(store.snapshot?.report?.primary)
        // Anchor 07/06 close 581.51 → 07/07 close 551.69 is −5.13%, and it belongs in the estimate
        // because the official NAV (91.94) was struck before 07/07 traded.
        XCTAssertEqual(primary?.baseCloseDate, etDay(2026, 7, 6))
        XCTAssertEqual(dbl(primary?.proxyReturn ?? 0), -0.0513, accuracy: 0.0005)
        XCTAssertEqual(dbl(primary?.revaluedNAV ?? 0), 87.22, accuracy: 0.05)
    }

    func testStoreAddsOnlyThePostMarketMoveWhenTheNAVHasTheClose() async {
        // The after-hours payload's regular close IS 07/06 — the one the NAV was struck against —
        // so anchoring resolves to the same close and only the post-market move remains.
        let client = StubHTTPClient { url in
            let s = url.absoluteString
            if s.contains("mis.twse.com.tw") { return fixtureData("twse_mis_00830") }
            if s.contains("cwapi.cathaysite.com.tw") { return fixtureData("cathay_navlist") }
            if s.contains("historical") { return fixtureData("nasdaq_soxx_historical_july06") }
            if s.contains("/info") { return fixtureData("nasdaq_soxx_afterhours") }  // 07/06 close
            return nil
        }
        let store = ETFStore(client: client)
        await store.refreshOnce()

        let primary = store.snapshot?.report?.primary
        XCTAssertEqual(primary?.baseCloseDate, etDay(2026, 7, 6))
        // Only the 07/06 post-market move (581.51 → 576.00), not a whole extra session.
        XCTAssertEqual(dbl(primary?.proxyReturn ?? 0), -0.0095, accuracy: 0.0005)
    }

    func testStorePublishesNoReportRatherThanAnUnanchoredOne() async {
        // History unreachable ⇒ the base cannot be tied to the NAV's session. The official NAV and
        // the market price still show; only the derived premium is withheld.
        let client = StubHTTPClient { url in
            let s = url.absoluteString
            if s.contains("mis.twse.com.tw") { return fixtureData("twse_mis_00830") }
            if s.contains("cwapi.cathaysite.com.tw") { return fixtureData("cathay_navlist") }
            if s.contains("historical") { return nil }
            if s.contains("/info") { return fixtureData("nasdaq_soxx_frozen") }
            return nil
        }
        let store = ETFStore(client: client)
        await store.refreshOnce()

        XCTAssertNil(store.snapshot?.report, "an unverified base must not reach the label")
        XCTAssertNotNil(store.snapshot?.officialNAV)
        XCTAssertNotNil(store.snapshot?.price)
    }
}
