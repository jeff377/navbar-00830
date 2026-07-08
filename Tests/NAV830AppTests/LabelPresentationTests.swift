import XCTest
@testable import NAV830App
import NAV830Core

/// Covers the menu-bar label decision — especially the behaviour the user asked for: during the
/// no-quote gap between the US close and the Taiwan pre-open, keep showing the last-known
/// comparison rather than blanking to "--".
final class LabelPresentationTests: XCTestCase {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    // MARK: - The reported issue: market closed ⇒ show last-known comparison

    func testClosedGapShowsLastKnownComparison() {
        // US closed, Taiwan not open. Price is a stale last-close (19h old) but we fetched it just
        // now, so it is the current best-known value — show the discount, do not blank.
        let p = LabelPresentation.compute(
            premium: dec("-0.036"), phase: .closed, thresholdPct: 3,
            sinceGoodFetch: 30, priceAge: 19 * 3600
        )
        XCTAssertEqual(p.liveness, .lastKnown)
        XCTAssertEqual(p.text, "00830 折價")
        XCTAssertEqual(p.state, .discountAlert, "last-known still carries the alert colour")
    }

    func testClosedGapPremiumStillGreen() {
        let p = LabelPresentation.compute(
            premium: dec("0.033"), phase: .closed, thresholdPct: 3,
            sinceGoodFetch: 30, priceAge: 19 * 3600
        )
        XCTAssertEqual(p.text, "00830 溢價")
        XCTAssertEqual(p.state, .premiumAlert)
    }

    // MARK: - Genuine staleness (no successful fetch in a while) is different

    func testFetchOutageIsStaleAndMarked() {
        let p = LabelPresentation.compute(
            premium: dec("-0.036"), phase: .closed, thresholdPct: 3,
            sinceGoodFetch: 20 * 60, priceAge: 60          // >15 min since any good fetch
        )
        XCTAssertEqual(p.liveness, .stale)
        XCTAssertEqual(p.text, "00830 折價 ⚠")
        XCTAssertEqual(p.state, .muted)
    }

    func testNoReportShowsDashes() {
        let p = LabelPresentation.compute(
            premium: nil, phase: nil, thresholdPct: 3, sinceGoodFetch: 0, priceAge: nil
        )
        XCTAssertEqual(p.text, "00830 --")
        XCTAssertEqual(p.liveness, .noData)
        XCTAssertEqual(p.state, .muted)
    }

    // MARK: - Live phases

    func testUSRegularIsLive() {
        let p = LabelPresentation.compute(
            premium: dec("0.031"), phase: .usRegular, thresholdPct: 3, sinceGoodFetch: 10, priceAge: 19 * 3600
        )
        XCTAssertEqual(p.liveness, .live)
        XCTAssertEqual(p.state, .premiumAlert)
    }

    func testTaiwanTradingFreshPriceIsLive() {
        let p = LabelPresentation.compute(
            premium: dec("-0.01"), phase: .taiwanTrading, thresholdPct: 3, sinceGoodFetch: 5, priceAge: 30
        )
        XCTAssertEqual(p.liveness, .live)
        XCTAssertEqual(p.state, .normal, "−1% is inside the ±3% band")
    }

    func testTaiwanTradingStalePriceFallsBackToLastKnown() {
        // Trading hours but the 00830 print is >2 min old (illiquid) → last-known, still shown.
        let p = LabelPresentation.compute(
            premium: dec("-0.01"), phase: .taiwanTrading, thresholdPct: 3, sinceGoodFetch: 5, priceAge: 300
        )
        XCTAssertEqual(p.liveness, .lastKnown)
        XCTAssertEqual(p.text, "00830 折價")
    }
}
