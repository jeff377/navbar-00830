import XCTest
@testable import NAV830Fetch

final class ParseTests: XCTestCase {

    func testDecimalStripsSymbols() {
        XCTAssertEqual(Parse.decimal("$581.51"), Decimal(string: "581.51"))
        XCTAssertEqual(Parse.decimal("$1,234.56"), Decimal(string: "1234.56"))
        XCTAssertEqual(Parse.decimal("-0.95%"), Decimal(string: "-0.95"))
        XCTAssertEqual(Parse.decimal("+2.10"), Decimal(string: "2.10"))
        XCTAssertEqual(Parse.decimal("89.7000"), Decimal(string: "89.7"))
    }

    func testDecimalRejectsPlaceholders() {
        XCTAssertNil(Parse.decimal("--"))
        XCTAssertNil(Parse.decimal("-"))
        XCTAssertNil(Parse.decimal("  "))
    }

    func testEpochMillis() throws {
        let d = try XCTUnwrap(Parse.epochMillis("1783405800000"))
        XCTAssertEqual(d.timeIntervalSince1970, 1783405800, accuracy: 0.001)
    }

    func testNasdaqTimestampIsEastern() {
        let d = Parse.nasdaqTimestamp("Jul 6, 2026 7:59 PM ET")
        XCTAssertNotNil(d)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(cal.component(.hour, from: d!), 19)
        XCTAssertEqual(cal.component(.day, from: d!), 6)
    }

    func testTaipeiDate() {
        let d = Parse.taipeiDate("2026/07/06")
        XCTAssertNotNil(d)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        XCTAssertEqual(cal.component(.year, from: d!), 2026)
        XCTAssertEqual(cal.component(.month, from: d!), 7)
        XCTAssertEqual(cal.component(.day, from: d!), 6)
    }
}
