import Foundation
import XCTest
@testable import NAV830Fetch
import NAV830Core

func fixtureData(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
        XCTFail("missing fixture \(name).json", file: file, line: line)
        return Data()
    }
    return (try? Data(contentsOf: url)) ?? Data()
}

func dbl(_ d: Decimal) -> Double { (d as NSDecimalNumber).doubleValue }
func dec(_ s: String) -> Decimal { Decimal(string: s)! }

func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, tz: String) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: tz)!
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

/// Routes URLs to fixture bytes so the whole fetch→parse pipeline runs offline.
struct StubHTTPClient: HTTPClient {
    let route: @Sendable (URL) -> Data?
    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        guard let data = route(url) else { throw SourceError.network("no stub for \(url.absoluteString)") }
        return data
    }
}

/// A proxy source with a canned outcome, for fallback tests.
struct StubProxySource: ProxySource {
    let symbol: ProxySymbol
    let outcome: Result<ProxyQuote, SourceError>
    /// Canned historical close for re-anchoring tests; absent ⇒ the lookup fails.
    var history: DatedClose?

    func fetchQuote() async throws -> ProxyQuote { try outcome.get() }

    func regularClose(onOrBefore date: Date) async throws -> DatedClose {
        guard let history else { throw SourceError.unavailable("no history stub") }
        return history
    }
}

/// ET midnight of a trading day, the granularity `baseCloseDate` / `usCloseDate` compare at.
func etDay(_ y: Int, _ mo: Int, _ d: Int) -> Date {
    at(y, mo, d, 0, 0, tz: "America/New_York")
}
