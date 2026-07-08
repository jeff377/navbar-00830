import XCTest
@testable import NAV830Fetch
import NAV830Core

/// Hits the real endpoints. Skipped unless NAV830_LIVE=1, so CI and normal `swift test` stay
/// offline and deterministic. Run with:  NAV830_LIVE=1 swift test --filter LiveSmokeTests
final class LiveSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NAV830_LIVE"] == "1", "live test disabled")
    }

    func testLiveNAV() async throws {
        let nav = try await CathayNAVSource().fetchNAV()
        print("LIVE NAV: \(nav.value) @ \(nav.navDate)")
        XCTAssertGreaterThan(nav.value, 0)
    }

    func testLivePrice() async throws {
        // Exercise the app's actual chain: Cathay lastPrice → TWSE MIS fallback.
        let price = try await FallbackPriceSource([CathayPriceSource(), TWSEMISPriceSource()]).fetchPrice()
        print("LIVE 00830: \(price.price) @ \(price.timestamp) via \(price.source)")
        XCTAssertGreaterThan(price.price, 0)
    }

    func testLiveFX() async throws {
        let fx = try await ERAPIFXSource().fetchFX(reference: nil)
        print("LIVE USD/TWD: \(fx.current)")
        XCTAssertGreaterThan(fx.current, 20)
        XCTAssertLessThan(fx.current, 45)
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
