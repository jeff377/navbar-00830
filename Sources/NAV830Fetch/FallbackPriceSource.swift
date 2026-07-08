import Foundation
import NAV830Core

/// Tries an ordered list of price sources and returns the first that succeeds — Cathay `lastPrice`
/// (matches the official page) first, TWSE MIS as a fallback if Cathay is unavailable.
public struct FallbackPriceSource: PriceSource {
    private let sources: [any PriceSource]

    public init(_ sources: [any PriceSource]) {
        self.sources = sources
    }

    public func fetchPrice() async throws -> MarketPrice {
        var errors: [SourceError] = []
        for source in sources {
            do {
                return try await source.fetchPrice()
            } catch let error as SourceError {
                errors.append(error)
            } catch {
                errors.append(.network("\(error)"))
            }
        }
        throw SourceError.allFailed(errors)
    }
}
