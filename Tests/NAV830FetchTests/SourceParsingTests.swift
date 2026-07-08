import XCTest
@testable import NAV830Fetch
import NAV830Core

/// Every parser is exercised against a recorded real response (or a clearly-labelled synthetic
/// one where a live capture was impossible), so these run offline and deterministically.
final class SourceParsingTests: XCTestCase {

    func testTWSEPrice() throws {
        let price = try TWSEMISPriceSource.parse(fixtureData("twse_mis_00830"))
        XCTAssertEqual(dbl(price.price), 89.70, accuracy: 0.0001)
        XCTAssertEqual(price.source, "TWSE MIS")
    }

    func testTWSEPreOpenFallsBackToPreviousClose() throws {
        // Pre-open: z="-" (no trade yet) ⇒ use y (昨收) as the last-known price, so the no-quote
        // gap still produces a comparison instead of failing.
        let price = try TWSEMISPriceSource.parse(fixtureData("twse_mis_preopen"))
        XCTAssertEqual(dbl(price.price), 89.70, accuracy: 0.0001)
    }

    func testNasdaqAfterHours() throws {
        let quote = try NasdaqProxySource.parse(fixtureData("nasdaq_soxx_afterhours"), symbol: .soxx)
        XCTAssertEqual(quote.session, .afterHours)
        XCTAssertEqual(dbl(quote.baseClose), 581.51, accuracy: 0.0001)   // primaryData regular close
        XCTAssertEqual(dbl(quote.latestPrice), 576.00, accuracy: 0.0001) // secondaryData after-hours
        // The whole point: the parsed pair reproduces the appendix −0.95%.
        XCTAssertEqual(dbl(NAVCalculator.proxyReturn(quote)), -0.0095, accuracy: 0.0002)
    }

    func testNasdaqRegularSessionUsesLiveVsPreviousClose() throws {
        // marketStatus Open, no secondaryData: latest = live 543.97, base = 543.97 − (−37.54) = 581.51.
        let quote = try NasdaqProxySource.parse(fixtureData("nasdaq_soxx_open"), symbol: .soxx)
        XCTAssertEqual(quote.session, .regular)
        XCTAssertEqual(dbl(quote.baseClose), 581.51, accuracy: 0.0001)
        XCTAssertEqual(dbl(quote.latestPrice), 543.97, accuracy: 0.0001)
        XCTAssertEqual(dbl(NAVCalculator.proxyReturn(quote)), -0.0646, accuracy: 0.0002) // matches Nasdaq −6.46%
    }

    func testERAPIFX() throws {
        let fx = try ERAPIFXSource.parse(fixtureData("erapi_usd"), reference: nil)
        XCTAssertEqual(dbl(fx.current), 32.08, accuracy: 0.5)
        XCTAssertEqual(fx.factor, 1, "nil reference ⇒ factor 1")
    }

    func testERAPIFXFactorWithReference() throws {
        let fx = try ERAPIFXSource.parse(fixtureData("erapi_usd"), reference: Decimal(string: "32.32"))
        XCTAssertLessThan(fx.factor, 1) // TWD ~32.08 < 32.32 reference
    }

    func testCathayNAVSelects00830() throws {
        let nav = try CathayNAVSource.parse(fixtureData("cathay_navlist"), stockCode: "00830", fetchedAt: Date())
        // PLAN §附錄: 00830 closingNav 91.68 dated 2026/07/06.
        XCTAssertEqual(dbl(nav.value), 91.68, accuracy: 0.0001)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        XCTAssertEqual(cal.component(.day, from: nav.navDate), 6)
    }

    func testCathayUnknownCodeIsUnavailable() {
        XCTAssertThrowsError(try CathayNAVSource.parse(fixtureData("cathay_navlist"), stockCode: "99999", fetchedAt: Date())) { error in
            guard case SourceError.unavailable = error else { return XCTFail("expected .unavailable") }
        }
    }
}
