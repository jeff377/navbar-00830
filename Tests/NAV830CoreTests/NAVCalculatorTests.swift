import XCTest
@testable import NAV830Core

final class NAVCalculatorTests: XCTestCase {

    // MARK: - PLAN §附錄 sanity check (the M1 gate)

    func testAppendixAfterHoursReturn() {
        // (576.00 − 581.51) / 581.51 ≈ −0.94747%
        let ret = NAVCalculator.afterHoursReturn(Fixtures.soxx)
        XCTAssertEqual(dbl(ret), -0.0095, accuracy: 0.0002)
    }

    func testAppendixRevaluedNAV() {
        // 91.68 × (1 − 0.94747%) ≈ 90.81
        let ret = NAVCalculator.afterHoursReturn(Fixtures.soxx)
        let nav = NAVCalculator.revaluedNAV(
            officialNAV: Fixtures.officialNAV.value,
            afterHoursReturn: ret,
            fxFactor: Fixtures.noFX.factor
        )
        XCTAssertEqual(dbl(nav), 90.8, accuracy: 0.05)
    }

    func testAppendixPremiumIsAboutMinusOnePercent() {
        let ret = NAVCalculator.afterHoursReturn(Fixtures.soxx)
        let nav = NAVCalculator.revaluedNAV(
            officialNAV: Fixtures.officialNAV.value,
            afterHoursReturn: ret,
            fxFactor: Fixtures.noFX.factor
        )
        let premium = NAVCalculator.premium(marketPrice: Fixtures.price.price, revaluedNAV: nav)
        // 89.90 / 90.81 − 1 ≈ −1.00% (discount, inside the normal band)
        XCTAssertEqual(dbl(premium), -0.01, accuracy: 0.003)
        XCTAssertLessThan(premium, 0, "should be a discount")
    }

    func testAppendixFullReport() {
        let report = NAVCalculator.report(
            officialNAV: Fixtures.officialNAV,
            proxies: [Fixtures.soxx],
            fx: Fixtures.noFX,
            marketPrice: Fixtures.price
        )
        XCTAssertNotNil(report)
        XCTAssertEqual(report?.primary.proxy, .soxx)
        XCTAssertEqual(dbl(report!.primary.revaluedNAV), 90.8, accuracy: 0.05)
        XCTAssertEqual(dbl(report!.premium), -0.01, accuracy: 0.003)
    }

    // MARK: - Leverage de-levering

    func testSOXLReturnIsDivededByThree() {
        // SOXL 30.00 → 29.145 is −2.85%; de-leveraged underlying is −0.95%.
        let soxl = ProxyQuote(
            symbol: .soxl,
            regularClose: dec("30.00"),
            afterHoursPrice: dec("29.145"),
            afterHoursAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(dbl(NAVCalculator.afterHoursReturn(soxl)), -0.0095, accuracy: 0.0001)
    }

    func testNonLeveragedProxyIsRaw() {
        // SOXQ 1x: de-leveraged == raw.
        let soxq = ProxyQuote(
            symbol: .soxq,
            regularClose: dec("30.00"),
            afterHoursPrice: dec("29.70"),
            afterHoursAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(dbl(NAVCalculator.afterHoursReturn(soxq)), -0.01, accuracy: 0.0001)
    }

    // MARK: - FX factor

    func testFXFactorNilReferenceIsOne() {
        XCTAssertEqual(Fixtures.noFX.factor, 1)
    }

    func testFXFactorAppliesRatio() {
        let fx = FXRate(current: dec("32.00"), reference: dec("32.32"), timestamp: Date(timeIntervalSince1970: 0), source: "fixture")
        XCTAssertEqual(dbl(fx.factor), 32.0 / 32.32, accuracy: 1e-6)
    }

    // MARK: - Cross-check panel

    func testReportPicksSOXXAsPrimaryAndKeepsCrossChecks() {
        let soxq = ProxyQuote(symbol: .soxq, regularClose: dec("30.00"), afterHoursPrice: dec("29.70"), afterHoursAt: Date(timeIntervalSince1970: 0))
        let report = NAVCalculator.report(
            officialNAV: Fixtures.officialNAV,
            proxies: [soxq, Fixtures.soxx],
            fx: Fixtures.noFX,
            marketPrice: Fixtures.price
        )
        XCTAssertEqual(report?.primary.proxy, .soxx)
        XCTAssertEqual(report?.crossChecks.count, 2)
    }

    func testReportDegradesWhenPrimaryMissing() {
        // SOXX unavailable → falls back to whatever proxy is present, does not fail.
        let soxq = ProxyQuote(symbol: .soxq, regularClose: dec("30.00"), afterHoursPrice: dec("29.70"), afterHoursAt: Date(timeIntervalSince1970: 0))
        let report = NAVCalculator.report(
            officialNAV: Fixtures.officialNAV,
            proxies: [soxq],
            fx: Fixtures.noFX,
            marketPrice: Fixtures.price
        )
        XCTAssertEqual(report?.primary.proxy, .soxq)
    }

    func testReportNilWhenNoProxies() {
        let report = NAVCalculator.report(
            officialNAV: Fixtures.officialNAV,
            proxies: [],
            fx: Fixtures.noFX,
            marketPrice: Fixtures.price
        )
        XCTAssertNil(report)
    }
}
