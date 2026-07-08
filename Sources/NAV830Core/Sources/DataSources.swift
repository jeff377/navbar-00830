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

/// A proxy ETF quote (regular close + after-hours) for one symbol.
public protocol ProxySource: Sendable {
    var symbol: ProxySymbol { get }
    func fetchQuote() async throws -> ProxyQuote
}
