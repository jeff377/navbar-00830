import XCTest
@testable import NAV830Fetch
import NAV830Core

/// Hits the real endpoints. Skipped unless NAV830_LIVE=1, so CI and normal `swift test` stay
/// offline and deterministic. Run with:  NAV830_LIVE=1 swift test --filter LiveSmokeTests
final class LiveSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NAV830_LIVE"] == "1", "live test disabled")
    }

    func testLiveCathayNAV() async throws {
        let etf = try await CathayETFSource().fetch()
        print("LIVE Cathay: 官方預估淨值=\(etf.nav.value) 昨收淨值=\(etf.closingNav) 基準美股收盤日=\(etf.nav.usCloseDate.map(String.init(describing:)) ?? "?")")
        XCTAssertGreaterThan(etf.nav.value, 0)
    }

    func testLiveTWSEPrice() async throws {
        let price = try await TWSEMISPriceSource().fetchPrice()
        print("LIVE TWSE 00830: \(price.price) @ \(price.timestamp)")
        XCTAssertGreaterThan(price.price, 0)
    }

    func testLiveFullSnapshot() async {
        let snap = await DataFeed.live().snapshot()
        if let r = snap.report {
            // Base date printed too: it is the one input you cannot eyeball from the numbers, and
            // an off-by-one-session base is exactly how a −4% US day goes missing.
            print("LIVE phase=\(snap.phase) 官方=\(snap.officialNAV?.value ?? 0) 重估=\(r.primary.revaluedNAV) 市價=\(r.marketPrice.price) 折溢價=\(r.premium)")
            for c in r.crossChecks {
                print("  \(c.proxy.rawValue) \(c.session) base=\(c.baseCloseDate.map(String.init(describing:)) ?? "?") move=\(c.proxyReturn)")
            }
        } else {
            print("LIVE phase=\(snap.phase) report=nil")
        }
        for s in snap.statuses { print("  [\(s.ok ? "ok" : "FAIL")] \(s.name) \(s.detail ?? "")") }
        // Proxy after-hours may legitimately be unavailable outside the relevant window, so we
        // only assert the feed produced a snapshot without crashing.
        XCTAssertFalse(snap.statuses.isEmpty)
    }
}
