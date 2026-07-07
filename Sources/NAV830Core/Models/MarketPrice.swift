import Foundation

/// A real-time market price for 00830 on the Taiwan exchange.
public struct MarketPrice: Sendable, Equatable {
    /// Last traded price in TWD.
    public let price: Decimal
    /// Timestamp of the quote (from the TWSE MIS snapshot).
    public let timestamp: Date
    public let source: String

    public init(price: Decimal, timestamp: Date, source: String) {
        self.price = price
        self.timestamp = timestamp
        self.source = source
    }
}
