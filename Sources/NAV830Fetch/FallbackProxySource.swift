import Foundation
import NAV830Core

/// Tries an ordered list of proxy sources and returns the first that succeeds
/// (PLAN §8.4: "SOXX 掛了改用 SOXQ"). Because the revaluation de-leverages every proxy to
/// the underlying 1x move, any of SOXX/SOXQ/SOXL yields a usable after-hours increment, so
/// falling back across symbols degrades precision slightly rather than failing outright.
public struct FallbackProxySource: Sendable {
    private let sources: [any ProxySource]

    /// - Parameter sources: ordered by preference; SOXX first per PLAN §2.3.
    public init(_ sources: [any ProxySource]) {
        self.sources = sources
    }

    /// The primary symbol actually used, alongside the quote. Also collects every proxy that
    /// succeeded so the shell can show the SOXX/SOXQ/SOXL cross-check panel.
    public func fetchAll() async -> (quotes: [ProxyQuote], errors: [(ProxySymbol, SourceError)]) {
        var quotes: [ProxyQuote] = []
        var errors: [(ProxySymbol, SourceError)] = []
        for source in sources {
            do {
                quotes.append(try await source.fetchQuote())
            } catch let error as SourceError {
                errors.append((source.symbol, error))
            } catch {
                errors.append((source.symbol, .network("\(error)")))
            }
        }
        return (quotes, errors)
    }

    /// The first successful quote in preference order, or `.allFailed` if none succeed.
    public func fetchPreferred() async throws -> ProxyQuote {
        var errors: [SourceError] = []
        for source in sources {
            do {
                return try await source.fetchQuote()
            } catch let error as SourceError {
                errors.append(error)
            } catch {
                errors.append(.network("\(error)"))
            }
        }
        throw SourceError.allFailed(errors)
    }
}
