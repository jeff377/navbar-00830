import XCTest
@testable import NAV830Fetch
import NAV830Core

/// Hits the real endpoints. Skipped unless NAV830_LIVE=1, so CI and normal `swift test` stay
/// offline and deterministic. Run with:  NAV830_LIVE=1 swift test --filter LiveSmokeTests
final class LiveSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NAV830_LIVE"] == "1", "live test disabled")
    }

    func testLiveCathayNavAndPrice() async throws {
        let etf = try await CathayETFSource().fetch()
        print("LIVE Cathay: 官方預估淨值=\(etf.nav.value) 昨收淨值=\(etf.closingNav) 市價=\(etf.price.price)")
        XCTAssertGreaterThan(etf.nav.value, 0)
        XCTAssertGreaterThan(etf.price.price, 0)
    }

    func testLiveFullSnapshot() async {
        let snap = await DataFeed.live().snapshot()
        print("LIVE phase=\(snap.phase) report=\(snap.report.map { "premium \($0.premium)" } ?? "nil")")
        for s in snap.statuses { print("  [\(s.ok ? "ok" : "FAIL")] \(s.name) \(s.detail ?? "")") }
        // Proxy after-hours may legitimately be unavailable outside the relevant window, so we
        // only assert the feed produced a snapshot without crashing.
        XCTAssertFalse(snap.statuses.isEmpty)
    }
}
