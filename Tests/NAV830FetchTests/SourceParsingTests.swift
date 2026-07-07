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

    func testNasdaqAfterHours() throws {
        let quote = try NasdaqProxySource.parse(fixtureData("nasdaq_soxx_afterhours"), symbol: .soxx)
        XCTAssertEqual(dbl(quote.regularClose), 581.51, accuracy: 0.0001)
        XCTAssertEqual(dbl(quote.afterHoursPrice), 576.00, accuracy: 0.0001)
        // The whole point: the parsed pair reproduces the appendix −0.95%.
        XCTAssertEqual(dbl(NAVCalculator.afterHoursReturn(quote)), -0.0095, accuracy: 0.0002)
    }

    func testNasdaqDuringRegularSessionIsUnavailable() {
        // secondaryData is null while the US regular session is open → no valid after-hours.
        XCTAssertThrowsError(try NasdaqProxySource.parse(fixtureData("nasdaq_soxx_open"), symbol: .soxx)) { error in
            guard case SourceError.unavailable = error else { return XCTFail("expected .unavailable, got \(error)") }
        }
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
