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
            // Already measured from the anchor day's own close — the live after-hours payload
            // carries that close as a price, dated from our clock. Nothing to re-anchor to, and
            // nothing the historical table could add: it does not publish the day's row until
            // about an hour after the post-market session ends, so a lookup here would silently
            // hand back the *previous* session's close and re-apply a move the NAV already has.
            if quote.baseCloseDate == anchor {
                result.append(quote)
                continue
            }
            if let base = await anchorCache.close(for: quote.symbol, at: anchor) {
                result.append(quote.anchored(to: base))
                continue
            }
            guard let source = sources.first(where: { $0.symbol == quote.symbol }),
                  let base = try? await source.regularClose(onOrBefore: anchor) else { continue }
            if Self.isTheAnchorsOwnClose(base, anchor: anchor) {
                await anchorCache.store(base, for: quote.symbol, at: anchor)
                result.append(quote.anchored(to: base))
            } else if let rolled = Self.closeTheTableHasNotPublishedYet(quote, lastPublished: base, anchor: anchor) {
                // Deliberately not cached: the table will carry the real row within the hour, and a
                // cached stand-in would hold the app on it for the rest of the day.
                result.append(rolled)
            }
        }
        return result
    }

    /// Whether a historical close may stand as the anchor day's close.
    ///
    /// "On or before" is how a close is recovered when the anchor day had no US session — a US
    /// holiday, or a Taiwan session that ran while Wall Street was shut. But it also silently
    /// accepts a close from the session *before* the anchor when the anchor day did trade and its
    /// row is merely not published yet: Nasdaq's historical table lags the close by roughly an hour
    /// past the end of post-market, which covers the whole Taiwan pre-open. That reading applies a
    /// move the official NAV already contains — a plausible-looking premium built on the wrong
    /// session, which is worse than showing nothing (the caller keeps its last anchored set).
    ///
    /// NOTE: the US holiday table is maintained per year. An unlisted holiday would look like a
    /// trading day here and the quote would be dropped — visibly missing rather than quietly wrong.
    private static func isTheAnchorsOwnClose(_ base: DatedClose, anchor: Date,
                                             calendar: MarketCalendar = USMarketCalendar()) -> Bool {
        base.date >= anchor || !calendar.isTradingDay(anchor)
    }

    /// The anchor day's close taken from the quote itself, for the window where the historical
    /// table has not published that day's row yet — or nil if the quote cannot supply it.
    ///
    /// The quote's own `baseClose` is "the newest completed regular close" as Nasdaq currently sees
    /// it, which in this window is either the anchor day's close (the payload has rolled over) or
    /// the previous session's (it has not) — and the payload's date labels cannot tell the two
    /// apart. The prices can: if it still equals the last published close, nothing has rolled.
    /// Observed 2026-07-29 21:00 ET, where the table stopped at 07/28 and, for the same anchor of
    /// 07/29, SOXX offered $465.00 against a published $491.46 — a new close, usable — while SOXQ
    /// offered $86.82, the published 07/28 close to the cent, and was dropped.
    ///
    /// NOTE: this assumes a session never closes at exactly the previous close. When it does, the
    /// quote is dropped and the panel goes blank until the table publishes — the safe direction.
    private static func closeTheTableHasNotPublishedYet(_ quote: ProxyQuote, lastPublished: DatedClose,
                                                        anchor: Date) -> ProxyQuote? {
        guard quote.baseClose != lastPublished.close else { return nil }
        return quote.anchored(to: DatedClose(close: quote.baseClose, date: anchor))
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
