import XCTest
@testable import NAV830Fetch
import NAV830Core

/// Every parser is exercised against a recorded real response (or a clearly-labelled synthetic
/// one where a live capture was impossible), so these run offline and deterministically.
final class SourceParsingTests: XCTestCase {

    // MARK: - TWSE MIS price (z → bid/ask midpoint → 昨收)

    func testTWSEPrice() throws {
        let price = try TWSEMISPriceSource.parse(fixtureData("twse_mis_00830"))
        XCTAssertEqual(dbl(price.price), 89.70, accuracy: 0.0001)
        XCTAssertEqual(price.source, "TWSE MIS")
    }

    func testTWSEUsesDisclosedPriceWhenNoLastTrade() throws {
        // REGRESSION: z="-" but pz (揭示價) = 83.10 — a real, tick-aligned price. Previously we
        // synthesised a bid/ask midpoint (83.125 → "83.12"), which cannot exist: 00830 trades in
        // 0.05 steps. Must report pz, never a midpoint.
        let price = try TWSEMISPriceSource.parse(fixtureData("twse_mis_pz"))
        XCTAssertEqual(dbl(price.price), 83.10, accuracy: 0.0001)
        // Guard the invariant directly: the price must sit on a 0.05 tick.
        let ticks = (price.price / Decimal(string: "0.05")!) as NSDecimalNumber
        XCTAssertEqual(ticks.doubleValue, ticks.doubleValue.rounded(), accuracy: 1e-6, "price must be tick-aligned")
    }

    func testTWSEPreOpenFallsBackToPreviousClose() throws {
        // Pre-open: z/pz absent and the session has not traded (o="-") ⇒ 昨收 is the last-known.
        let price = try TWSEMISPriceSource.parse(fixtureData("twse_mis_preopen"))
        XCTAssertEqual(dbl(price.price), 89.70, accuracy: 0.0001)
        XCTAssertEqual(price.source, "TWSE 昨收")
    }

    func testTWSEMidSessionGapThrowsSoCallerKeepsCache() {
        // Mid-session snapshot with no trade price (z/pz both "-") but the session HAS traded.
        // Must fail rather than invent a midpoint or regress to 昨收 — the store keeps its cache.
        XCTAssertThrowsError(try TWSEMISPriceSource.parse(fixtureData("twse_mis_trading_gap"))) { error in
            guard case SourceError.unavailable = error else { return XCTFail("expected .unavailable, got \(error)") }
        }
    }

    func testNasdaqAfterHours() throws {
        let quote = try NasdaqProxySource.parse(fixtureData("nasdaq_soxx_afterhours"), symbol: .soxx)
        XCTAssertEqual(quote.session, .afterHours)
        XCTAssertEqual(dbl(quote.baseClose), 581.51, accuracy: 0.0001)   // primaryData regular close
        XCTAssertEqual(dbl(quote.latestPrice), 576.00, accuracy: 0.0001) // secondaryData after-hours
        // The whole point: the parsed pair reproduces the appendix −0.95%.
        XCTAssertEqual(dbl(NAVCalculator.proxyReturn(quote)), -0.0095, accuracy: 0.0002)
    }

    func testNasdaqPreMarketUsesLiveTickVsPriorClose() throws {
        // REGRESSION: in Pre-Market Nasdaq swaps the roles — primaryData is the live pre-market
        // tick (506.06, −4.61%) and secondaryData holds the *previous regular close* (530.50,
        // "Closed at … 4:00 PM ET"). Reading secondaryData as the newer price inverted the sign
        // (−4.6% shown as +4.9%). base must come from netChange, not secondaryData.
        let quote = try NasdaqProxySource.parse(fixtureData("nasdaq_soxx_premarket"), symbol: .soxx)
        XCTAssertEqual(quote.session, .preMarket)
        XCTAssertEqual(dbl(quote.baseClose), 530.50, accuracy: 0.0001)   // prior regular close
        XCTAssertEqual(dbl(quote.latestPrice), 506.06, accuracy: 0.0001) // live pre-market tick
        let ret = dbl(NAVCalculator.proxyReturn(quote))
        XCTAssertEqual(ret, -0.0461, accuracy: 0.0002)                   // matches Nasdaq −4.61%
        XCTAssertLessThan(ret, 0, "pre-market is down — must not read as a gain")
    }

    func testNasdaqFrozenAddsNoMove() throws {
        // US closed, no after-hours: base == latest == the last regular close, so the proxy adds
        // zero move. Correct only while that close is the one the official NAV was struck against
        // — which the feed enforces by re-anchoring (see testFrozenBaseIsDatedForReanchoring).
        let quote = try NasdaqProxySource.parse(fixtureData("nasdaq_soxx_frozen"), symbol: .soxx)
        XCTAssertEqual(quote.session, .frozen)
        XCTAssertEqual(dbl(quote.baseClose), 551.69, accuracy: 0.0001)
        XCTAssertEqual(dbl(quote.latestPrice), 551.69, accuracy: 0.0001)
        XCTAssertEqual(dbl(NAVCalculator.proxyReturn(quote)), 0, accuracy: 1e-9)
        // ⇒ revalued NAV equals the official NAV.
        let nav = OfficialNAV(value: dec("87.73"), navDate: Date(), source: "t", fetchedAt: Date())
        let r = NAVCalculator.revalue(officialNAV: nav, proxy: quote, fx: FXRate(current: 1, reference: nil, timestamp: Date(), source: "t"))
        XCTAssertEqual(dbl(r.revaluedNAV), 87.73, accuracy: 0.001)
    }

    func testFrozenBaseIsDatedForReanchoring() throws {
        // The frozen payload dates its close as "Jul 7, 2026" — no clock component. It must still
        // parse, because that date is what decides whether the official NAV already contains this
        // close. Left unparsed, every frozen quote silently claims to be anchored to today.
        let quote = try NasdaqProxySource.parse(fixtureData("nasdaq_soxx_frozen"), symbol: .soxx)
        XCTAssertEqual(quote.baseCloseDate, etDay(2026, 7, 7))
    }

    func testAfterHoursBaseIsDatedToTheRegularClose() throws {
        let quote = try NasdaqProxySource.parse(fixtureData("nasdaq_soxx_afterhours"), symbol: .soxx)
        XCTAssertEqual(quote.baseCloseDate, etDay(2026, 7, 6))
    }

    func testHistoricalPicksLastCloseOnOrBeforeCutoff() throws {
        // 07/24 (527.01) and 07/23 (551.24) are both present; asking for 07/23 must not grab the
        // newer row. This is the lookup that recovers the close the official NAV actually used.
        let data = fixtureData("nasdaq_soxx_historical")
        let onFriday = try XCTUnwrap(NasdaqProxySource.parseHistorical(data, onOrBefore: etDay(2026, 7, 24)))
        XCTAssertEqual(dbl(onFriday.close), 527.01, accuracy: 0.0001)
        let onThursday = try XCTUnwrap(NasdaqProxySource.parseHistorical(data, onOrBefore: etDay(2026, 7, 23)))
        XCTAssertEqual(dbl(onThursday.close), 551.24, accuracy: 0.0001)
        XCTAssertEqual(onThursday.date, etDay(2026, 7, 23))
    }

    func testHistoricalSkipsBackOverNonTradingDays() throws {
        // 07/25–07/26 is a weekend: asking for Sunday must fall back to Friday's close, which is
        // how a Taiwan holiday or a US holiday is absorbed without a market calendar.
        let match = try XCTUnwrap(NasdaqProxySource.parseHistorical(fixtureData("nasdaq_soxx_historical"), onOrBefore: etDay(2026, 7, 26)))
        XCTAssertEqual(match.date, etDay(2026, 7, 24))
    }

    func testExtendedPostParse() throws {
        // "$544.6 -36.91 (-6.35%)" → 544.6
        let post = try XCTUnwrap(NasdaqProxySource.parseExtendedPost(fixtureData("nasdaq_soxx_extended_post")))
        XCTAssertEqual(dbl(post), 544.6, accuracy: 0.0001)
    }

    func testFrozenTopsUpWithRetainedPostMarket() async throws {
        // Frozen info (regular close 551.69) + retained post-market (544.6) ⇒ apply the −1.28%
        // post-market move on top of the regular close (PLAN §2), during the Taiwan session.
        let client = StubHTTPClient { url in
            let s = url.absoluteString
            if s.contains("extended-trading") { return fixtureData("nasdaq_soxx_extended_post") }
            if s.contains("/info") { return fixtureData("nasdaq_soxx_frozen") }
            return nil
        }
        let quote = try await NasdaqProxySource(symbol: .soxx, client: client).fetchQuote()
        XCTAssertEqual(quote.session, .afterHours)
        XCTAssertEqual(dbl(quote.baseClose), 551.69, accuracy: 0.0001)
        XCTAssertEqual(dbl(quote.latestPrice), 544.6, accuracy: 0.0001)
        XCTAssertEqual(dbl(NAVCalculator.proxyReturn(quote)), -0.01285, accuracy: 0.0002)
    }

    func testFrozenWithoutExtendedStaysFrozen() async throws {
        // If the extended endpoint is unavailable, fall back to frozen (revalued == official NAV).
        let client = StubHTTPClient { url in
            url.absoluteString.contains("/info") ? fixtureData("nasdaq_soxx_frozen") : nil
        }
        let quote = try await NasdaqProxySource(symbol: .soxx, client: client).fetchQuote()
        XCTAssertEqual(quote.session, .frozen)
        XCTAssertEqual(dbl(NAVCalculator.proxyReturn(quote)), 0, accuracy: 1e-9)
    }

    func testNasdaqRegularSessionUsesLiveVsPreviousClose() throws {
        // marketStatus Open, no secondaryData: latest = live 543.97, base = 543.97 − (−37.54) = 581.51.
        let quote = try NasdaqProxySource.parse(fixtureData("nasdaq_soxx_open"), symbol: .soxx)
        XCTAssertEqual(quote.session, .regular)
        XCTAssertEqual(dbl(quote.baseClose), 581.51, accuracy: 0.0001)
        XCTAssertEqual(dbl(quote.latestPrice), 543.97, accuracy: 0.0001)
        XCTAssertEqual(dbl(NAVCalculator.proxyReturn(quote)), -0.0646, accuracy: 0.0002) // matches Nasdaq −6.46%
    }

    func testCathayETFSelects00830NAV() throws {
        // Official NAV from the Cathay record (price now comes from TWSE MIS).
        let etf = try CathayETFSource.parse(fixtureData("cathay_navlist"), stockCode: "00830", now: Date())
        XCTAssertEqual(dbl(etf.nav.value), 91.94, accuracy: 0.0001)     // official estimateNav (預估淨值)
        XCTAssertEqual(dbl(etf.closingNav), 91.68, accuracy: 0.0001)    // 昨收淨值 for reference
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        XCTAssertEqual(cal.component(.day, from: etf.nav.navDate), 6)   // closingNavDate 2026/07/06
    }

    func testCathayEstimateIsAnchoredToClosingNavDate() throws {
        // 預估淨值 for Taiwan day T is struck at T's 09:00 open — 21:00 ET on T−1 — so the newest
        // US close in it is T−1's, which is what Cathay reports as closingNavDate.
        let etf = try CathayETFSource.parse(fixtureData("cathay_navlist"), stockCode: "00830", now: Date())
        XCTAssertEqual(etf.nav.usCloseDate, etDay(2026, 7, 6))
    }

    func testCathayClosingNavFallbackIsAnchoredOneCloseEarlier() throws {
        // Before the issuer strikes the estimate the NAV falls back to 昨收淨值 — Taiwan day T−1's
        // own settled NAV, one US close older. Anchoring it to closingNavDate would credit it with
        // a session it never saw.
        let payload = Data("""
        {"result":[{"stockCode":"00830","closingNav":91.68,"closingNavString":"91.68",
                    "closingNavDate":"2026/07/06","estimateNav":null,"estimateNavString":"--"}]}
        """.utf8)
        let etf = try CathayETFSource.parse(payload, stockCode: "00830", now: Date())
        XCTAssertEqual(dbl(etf.nav.value), 91.68, accuracy: 0.0001)
        XCTAssertEqual(etf.nav.usCloseDate, etDay(2026, 7, 5))
    }

    func testCathayETFUnknownCodeIsUnavailable() {
        XCTAssertThrowsError(try CathayETFSource.parse(fixtureData("cathay_navlist"), stockCode: "99999", now: Date())) { error in
            guard case SourceError.unavailable = error else { return XCTFail("expected .unavailable") }
        }
    }
}
