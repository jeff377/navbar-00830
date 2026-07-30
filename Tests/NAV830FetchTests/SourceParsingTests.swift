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
        // (−4.6% shown as +4.9%). The "Closed at " label is what identifies the close, and its
        // price is taken as the base directly.
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

    func testBaseIsDatedFromOurClockNotFromTheQuotesOwnLabel() throws {
        // The quote payload carries a `lastTradeTimestamp`, and it is tempting to read it as the
        // trading day of `lastSalePrice`. It is not: observed 2026-07-25, $527.01 (Friday 07/24's
        // close) was stamped "Jul 24, 2026" at 21:13 ET Friday and "Jul 23, 2026" at 02:13 ET
        // Saturday — same price, date rolled back, on all three symbols. Anchoring off it made the
        // revaluation flip between correct and wrong.
        //
        // So a live payload — one that names its close, "Closed at … 4:00 PM ET" — is dated from
        // our clock instead. Both fixtures carry July timestamps; parsed as of Wednesday
        // 2026-08-12 20:00 ET they date the base to that day's close, leaking no July label.
        let now = at(2026, 8, 12, 20, 0, tz: "America/New_York")
        for fixture in ["nasdaq_soxx_premarket", "nasdaq_soxx_afterhours_live"] {
            let quote = try NasdaqProxySource.parse(fixtureData(fixture), symbol: .soxx, now: now)
            XCTAssertEqual(quote.baseCloseDate, etDay(2026, 8, 12), "\(fixture) must date its base from the clock")
        }

        // Everything else stays undated and must be anchored by the historical table. Once the day
        // is fully Closed the payload's close side goes stale for hours — 2026-07-29 20:57 ET, SOXQ
        // was still serving 07/28's $86.82 as its close, stamped "Jul 29, 2026", while its own
        // post-market print had moved on to 07/29 — so the clock must not vouch for it either.
        for fixture in ["nasdaq_soxx_frozen", "nasdaq_soxx_afterhours", "nasdaq_soxx_open"] {
            let quote = try NasdaqProxySource.parse(fixtureData(fixture), symbol: .soxx, now: now)
            XCTAssertNil(quote.baseCloseDate, "\(fixture) must not date its own base")
            XCTAssertFalse(quote.isAnchored, "\(fixture) is not fit to revalue until anchored")
        }
    }

    func testBaseDayRollsAtTheCloseAndSkipsNonTradingDays() throws {
        // Before 16:00 ET the newest completed close is the previous session's — which is exactly
        // the base a pre-market or regular-session payload quotes against. From 16:00 it is today's.
        XCTAssertEqual(Parse.lastCompletedCloseDay(at(2026, 7, 29, 8, 30, tz: "America/New_York")), etDay(2026, 7, 28))
        XCTAssertEqual(Parse.lastCompletedCloseDay(at(2026, 7, 29, 16, 1, tz: "America/New_York")), etDay(2026, 7, 29))
        // Weekend and holiday walk back to the last session: Saturday → Friday, and 2026-07-03
        // (Independence Day observed) → Thursday 07/02.
        XCTAssertEqual(Parse.lastCompletedCloseDay(at(2026, 7, 25, 22, 0, tz: "America/New_York")), etDay(2026, 7, 24))
        XCTAssertEqual(Parse.lastCompletedCloseDay(at(2026, 7, 3, 20, 0, tz: "America/New_York")), etDay(2026, 7, 2))
    }

    func testLiveAfterHoursMeasuresFromTodaysCloseNotThePreviousOne() throws {
        // REGRESSION (2026-07-30, Taiwan pre-open): while the after-hours session is live Nasdaq
        // reports marketStatus "After-Hours" and lays the payload out like Pre-Market —
        // primaryData is the 7:59 PM extended tick ($466.5966), secondaryData the close it is
        // measured against ("Closed at Jul 29, 2026 4:00 PM ET", $465.00). Read positionally, the
        // regular close came back as the "latest" price and the day's −5.38% drop was applied
        // again on top of an official NAV (74.98, dated 07/29) that already contained it.
        let now = at(2026, 7, 29, 20, 48, tz: "America/New_York")
        let quote = try NasdaqProxySource.parse(fixtureData("nasdaq_soxx_afterhours_live"), symbol: .soxx, now: now)
        XCTAssertEqual(quote.session, .afterHours)
        XCTAssertEqual(dbl(quote.baseClose), 465.00, accuracy: 0.0001)      // today's regular close
        XCTAssertEqual(dbl(quote.latestPrice), 466.5966, accuracy: 0.0001)  // the newest print
        XCTAssertEqual(dbl(NAVCalculator.proxyReturn(quote)), 0.0034, accuracy: 0.0002) // Nasdaq +0.34%
        // Dated from our clock: the close a live after-hours session hangs off is today's 16:00 ET.
        XCTAssertEqual(quote.baseCloseDate, etDay(2026, 7, 29))
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

    func testHistoricalRequestReachesPastTheAnchorDay() async throws {
        // REGRESSION (2026-07-29): Nasdaq's historical table omits the row dated `todate`, so a
        // request ending exactly on the anchor day hides that day's own close and the "on or
        // before" lookup silently settles for the session before it. Live that day, the anchor was
        // ET 07/28 and the base came back as 07/27's 516.23 instead of 07/28's 491.46, so the
        // after-hours print read −4.26% instead of +0.56% — Tuesday's −4.80% regular drop counted a
        // second time on top of an official NAV that already contained it. The stub reproduces the
        // exclusivity: the newest row it will serve is the day before the requested `todate`.
        let client = StubHTTPClient { url in
            guard url.absoluteString.contains("historical"),
                  let todate = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "todate" })?.value else { return nil }
            return Self.historicalRows(before: todate)
        }
        let close = try await NasdaqProxySource(symbol: .soxx, client: client)
            .regularClose(onOrBefore: etDay(2026, 7, 24))
        XCTAssertEqual(close.date, etDay(2026, 7, 24))
        XCTAssertEqual(dbl(close.close), 527.01, accuracy: 0.0001)
    }

    /// The historical fixture with every row dated `todate` or later removed, mirroring how Nasdaq
    /// answers the endpoint. `todate` is ISO ("yyyy-MM-dd"); the rows carry "MM/dd/yyyy".
    private static func historicalRows(before todate: String) -> Data {
        let json = try! JSONSerialization.jsonObject(with: fixtureData("nasdaq_soxx_historical")) as! [String: Any]
        var data = json["data"] as! [String: Any]
        var table = data["tradesTable"] as! [String: Any]
        table["rows"] = (table["rows"] as! [[String: Any]]).filter { row in
            let parts = (row["date"] as! String).split(separator: "/")
            return "\(parts[2])-\(parts[0])-\(parts[1])" < todate
        }
        data["tradesTable"] = table
        return try! JSONSerialization.data(withJSONObject: ["data": data])
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
