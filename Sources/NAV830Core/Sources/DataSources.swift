import Foundation

/// Failure modes shared by every data source. The concrete networking lives in
/// `NAV830Fetch`; Core only defines the contract so the calculation layer never
/// depends on URLSession or any specific provider.
public enum SourceError: Error, Sendable, Equatable {
    /// Transport-level failure (DNS, timeout, non-2xx status).
    case network(String)
    /// Response received but could not be decoded into the expected shape.
    case decoding(String)
    /// Decoded fine, but the value is absent or a placeholder (e.g. "--", symbol not listed).
    case unavailable(String)
    /// Every source in a fallback chain failed.
    case allFailed([SourceError])
}

/// One historical regular-session close, with the ET trading day it belongs to.
public struct DatedClose: Sendable, Equatable {
    public let close: Decimal
    /// ET trading date, as an ET-midnight instant.
    public let date: Date

    public init(close: Decimal, date: Date) {
        self.close = close
        self.date = date
    }
}

/// A proxy ETF quote (regular close + after-hours) for one symbol.
public protocol ProxySource: Sendable {
    var symbol: ProxySymbol { get }
    func fetchQuote() async throws -> ProxyQuote

    /// The last regular close on or before `date` (ET). Needed to re-anchor a quote to the
    /// close the official NAV was struck against, which may be several sessions back after a
    /// weekend or a Taiwan holiday.
    func regularClose(onOrBefore date: Date) async throws -> DatedClose
}

/// Live market price of 00830 on the Taiwan exchange.
public protocol PriceSource: Sendable {
    func fetchPrice() async throws -> MarketPrice
}
