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

/// Records what a `StubHTTPClient` was asked for. Lock-backed rather than an actor because the
/// routing closure is synchronous.
final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    func record(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        seen.append(url.absoluteString)
    }

    var urls: [String] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }
}

/// Counts calls from inside a synchronous routing closure.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
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

/// Counts history lookups, to prove the anchor close is fetched once per anchor date and not
/// re-requested on every refresh tick.
actor CountingProxySource: ProxySource {
    nonisolated let symbol: ProxySymbol
    private let quote: ProxyQuote
    private let history: DatedClose
    private(set) var calls = 0

    init(symbol: ProxySymbol, quote: ProxyQuote, history: DatedClose) {
        self.symbol = symbol
        self.quote = quote
        self.history = history
    }

    func fetchQuote() async throws -> ProxyQuote { quote }

    func regularClose(onOrBefore date: Date) async throws -> DatedClose {
        calls += 1
        return history
    }
}

/// ET midnight of a trading day, the granularity `baseCloseDate` / `usCloseDate` compare at.
func etDay(_ y: Int, _ mo: Int, _ d: Int) -> Date {
    at(y, mo, d, 0, 0, tz: "America/New_York")
}
