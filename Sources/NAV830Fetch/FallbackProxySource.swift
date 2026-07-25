import Foundation
import NAV830Core

/// Remembers the resolved anchor close per symbol for one anchor date.
///
/// The anchor date only moves when the issuer strikes a new NAV — once a day — while the app polls
/// every 15s–5min. Without this, every tick would re-request the historical table for a close that
/// cannot have changed. Entries for a previous anchor date are dropped, so the cache never serves
/// a close from the wrong session.
actor AnchorCloseCache {
    private var anchor: Date?
    private var closes: [ProxySymbol: DatedClose] = [:]

    func close(for symbol: ProxySymbol, at anchor: Date) -> DatedClose? {
        self.anchor == anchor ? closes[symbol] : nil
    }

    func store(_ close: DatedClose, for symbol: ProxySymbol, at anchor: Date) {
        if self.anchor != anchor {
            self.anchor = anchor
            closes.removeAll()
        }
        closes[symbol] = close
    }
}

/// Tries an ordered list of proxy sources and returns the first that succeeds
/// (PLAN §8.4: "SOXX 掛了改用 SOXQ"). Because the revaluation de-leverages every proxy to
/// the underlying 1x move, any of SOXX/SOXQ/SOXL yields a usable after-hours increment, so
/// falling back across symbols degrades precision slightly rather than failing outright.
public struct FallbackProxySource: Sendable {
    private let sources: [any ProxySource]
    private let anchorCache = AnchorCloseCache()

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

    /// Tie every quote's base to the close the official NAV was struck against, taken from the
    /// proxy's dated historical table.
    ///
    /// This runs unconditionally rather than "only when the quote looks newer than the anchor".
    /// The quote endpoint cannot be asked which day its close belongs to — its `lastTradeTimestamp`
    /// rolls backwards on its own (see `NasdaqProxySource.parse`) — so any conditional built on the
    /// quote's own dating flips between right and wrong as that label moves. The historical table
    /// is dated properly, so it decides.
    ///
    /// A quote whose base cannot be resolved is DROPPED, not passed through: its base is an
    /// unverified guess, and a plausible-but-wrong premium is worse than a missing one. Callers
    /// should keep their previous anchored set rather than fall back to raw quotes.
    public func anchoredQuotes(_ quotes: [ProxyQuote], toNAVClose anchor: Date?) async -> [ProxyQuote] {
        guard let anchor else { return [] }
        var result: [ProxyQuote] = []
        for quote in quotes {
            if let base = await anchorCache.close(for: quote.symbol, at: anchor) {
                result.append(quote.anchored(to: base))
                continue
            }
            guard let source = sources.first(where: { $0.symbol == quote.symbol }),
                  let base = try? await source.regularClose(onOrBefore: anchor) else { continue }
            await anchorCache.store(base, for: quote.symbol, at: anchor)
            result.append(quote.anchored(to: base))
        }
        return result
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
