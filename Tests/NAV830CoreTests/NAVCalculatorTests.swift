import XCTest
@testable import NAV830Core

final class NAVCalculatorTests: XCTestCase {

    private func proxy(_ s: ProxySymbol, base: String, latest: String, session: ProxySession = .afterHours) -> ProxyQuote {
        ProxyQuote(symbol: s, baseClose: dec(base), latestPrice: dec(latest), latestAt: Date(timeIntervalSince1970: 0), session: session)
    }

    // MARK: - PLAN §附錄 sanity check (the M1 gate) — after-hours pairing

    func testAppendixProxyReturn() {
        // (576.00 − 581.51) / 581.51 ≈ −0.94747%
        XCTAssertEqual(dbl(NAVCalculator.proxyReturn(Fixtures.soxx)), -0.0095, accuracy: 0.0002)
    }

    func testAppendixRevaluedNAV() {
        let ret = NAVCalculator.proxyReturn(Fixtures.soxx)
        let nav = NAVCalculator.revaluedNAV(officialNAV: Fixtures.officialNAV.value, proxyReturn: ret, fxFactor: Fixtures.noFX.factor)
        XCTAssertEqual(dbl(nav), 90.8, accuracy: 0.05)
    }

    func testAppendixPremiumIsAboutMinusOnePercent() {
        let report = NAVCalculator.report(officialNAV: Fixtures.officialNAV, proxies: [Fixtures.soxx], fx: Fixtures.noFX, marketPrice: Fixtures.price)!
        // 89.90 / 90.81 − 1 ≈ −1.00% (discount, inside the normal band)
        XCTAssertEqual(dbl(report.premium), -0.01, accuracy: 0.003)
        XCTAssertLessThan(report.premium, 0, "should be a discount")
        XCTAssertEqual(report.primary.session, .afterHours)
    }

    // MARK: - Regular-session pairing (US market open: live price vs previous close)

    func testRegularSessionUsesLivePriceVsPreviousClose() {
        // NAV 91.68, SOXX live 548.74 vs prev close 581.51 (−5.64%) ⇒ reNAV ≈ 86.51.
        let live = proxy(.soxx, base: "581.51", latest: "548.74", session: .regular)
        let report = NAVCalculator.report(officialNAV: Fixtures.officialNAV, proxies: [live], fx: Fixtures.noFX, marketPrice: Fixtures.price)!
        XCTAssertEqual(dbl(report.primary.revaluedNAV), 86.51, accuracy: 0.05)
        XCTAssertEqual(report.primary.session, .regular)
    }

    // MARK: - Leverage de-levering

    func testSOXLReturnIsDividedByThree() {
        // 29.145 / 30.00 = −2.85%; de-leveraged underlying is −0.95%.
        XCTAssertEqual(dbl(NAVCalculator.proxyReturn(proxy(.soxl, base: "30.00", latest: "29.145"))), -0.0095, accuracy: 0.0001)
    }

    func testNonLeveragedProxyIsRaw() {
        XCTAssertEqual(dbl(NAVCalculator.proxyReturn(proxy(.soxq, base: "30.00", latest: "29.70"))), -0.01, accuracy: 0.0001)
    }

    // MARK: - FX factor

    func testFXFactorNilReferenceIsOne() {
        XCTAssertEqual(Fixtures.noFX.factor, 1)
    }

    func testFXFactorAppliesRatio() {
        let fx = FXRate(current: dec("32.00"), reference: dec("32.32"), timestamp: Date(timeIntervalSince1970: 0), source: "fixture")
        XCTAssertEqual(dbl(fx.factor), 32.0 / 32.32, accuracy: 1e-6)
    }

    // MARK: - Primary selection & cross-check panel

    func testLiveIndexLeadsOverEveryETF() {
        // During the US regular session SOX is the faithful proxy — it *is* 00830's benchmark,
        // while SOXX tracks ICE Semiconductor and SOXL the NYSE Semiconductor Index. Measured
        // 2026-08-05 12:05 ET the two baskets read −0.47% and −1.30% off the same anchor, so
        // which one leads is worth ~0.7 TWD of revalued NAV, not a rounding difference.
        let report = NAVCalculator.report(
            officialNAV: Fixtures.officialNAV,
            proxies: [Fixtures.soxx,
                      proxy(.soxq, base: "30.00", latest: "29.70", session: .regular),
                      proxy(.sox, base: "12179.26", latest: "12121.68", session: .regular)],
            fx: Fixtures.noFX, marketPrice: Fixtures.price
        )
        XCTAssertEqual(report?.primary.proxy, .sox)
        XCTAssertEqual(dbl(report?.primary.proxyReturn ?? 0), -0.00473, accuracy: 0.0001)
        XCTAssertEqual(report?.crossChecks.count, 3, "every proxy stays on the cross-check panel")
    }

    func testFrozenIndexStepsAsideForAnETFWithAnAfterHoursMove() {
        // REGRESSION GUARD: the index is only calculated 09:30–16:00 ET, so once the session ends
        // its quote is the standing close and reports a flat move. Letting it lead anyway would
        // throw away the after-hours increment the ETFs carry — which is the entire reason the
        // tool exists during the Taiwan session. SOXQ leads instead; SOX stays a cross-check.
        let report = NAVCalculator.report(
            officialNAV: Fixtures.officialNAV,
            proxies: [proxy(.sox, base: "12179.26", latest: "12179.26", session: .frozen),
                      proxy(.soxq, base: "30.00", latest: "29.70", session: .afterHours)],
            fx: Fixtures.noFX, marketPrice: Fixtures.price
        )
        XCTAssertEqual(report?.primary.proxy, .soxq)
        XCTAssertEqual(report?.crossChecks.count, 2)
    }

    func testAmongETFsTheSameIndexTrackerLeads() {
        // Outside the regular session SOXQ leads because it tracks PHLX SOX like 00830 does;
        // SOXX and SOXL are the liquidity fallbacks, not equals.
        let report = NAVCalculator.report(
            officialNAV: Fixtures.officialNAV,
            proxies: [Fixtures.soxx, proxy(.soxq, base: "30.00", latest: "29.70")],
            fx: Fixtures.noFX, marketPrice: Fixtures.price
        )
        XCTAssertEqual(report?.primary.proxy, .soxq)
    }

    func testReportDegradesWhenPreferredProxiesMissing() {
        let report = NAVCalculator.report(
            officialNAV: Fixtures.officialNAV,
            proxies: [proxy(.soxl, base: "30.00", latest: "29.145")],
            fx: Fixtures.noFX, marketPrice: Fixtures.price
        )
        XCTAssertEqual(report?.primary.proxy, .soxl)
    }

    func testFrozenIndexAloneStillLeadsRatherThanBlanking() {
        // Nothing else survived the fetch. A flat move measured from the right close beats no
        // figure at all, so the ineligibility rule must be a preference tiebreak, not a filter.
        let report = NAVCalculator.report(
            officialNAV: Fixtures.officialNAV,
            proxies: [proxy(.sox, base: "12179.26", latest: "12121.68", session: .frozen)],
            fx: Fixtures.noFX, marketPrice: Fixtures.price
        )
        XCTAssertEqual(report?.primary.proxy, .sox)
    }

    func testReportNilWhenNoProxies() {
        XCTAssertNil(NAVCalculator.report(officialNAV: Fixtures.officialNAV, proxies: [], fx: Fixtures.noFX, marketPrice: Fixtures.price))
    }
}
