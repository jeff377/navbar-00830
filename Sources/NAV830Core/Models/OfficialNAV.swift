import Foundation

/// The latest official daily NAV of 00830, as published by the issuer / SITCA.
///
/// The issuer strikes this value during the Taiwan session, so it reflects the US regular
/// close that had already completed when that session opened — `usCloseDate` — and nothing
/// after it. The revaluation applies the US move *since that close* on top
/// (see `NAVCalculator.revaluedNAV`).
///
/// WARNING: "the close the NAV used" is NOT the same as "the most recent US close". Between a
/// US close and the next Taiwan open the newest close is not yet in the NAV; treating it as the
/// base silently drops that whole session's move. Always compare against `usCloseDate`.
public struct OfficialNAV: Sendable, Equatable {
    /// NAV per unit in TWD.
    public let value: Decimal
    /// The Taiwan business day this NAV is dated to (interpreted in Asia/Taipei).
    public let navDate: Date
    /// ET trading date of the last US regular close this NAV incorporates, as an ET-midnight
    /// instant, so it compares directly against `ProxyQuote.baseCloseDate`. Nil when unknown.
    public let usCloseDate: Date?
    /// Human-readable provenance, e.g. "SITCA 每日淨值".
    public let source: String
    /// When this record was fetched by the app.
    public let fetchedAt: Date

    public init(value: Decimal, navDate: Date, usCloseDate: Date? = nil, source: String, fetchedAt: Date) {
        self.value = value
        self.navDate = navDate
        self.usCloseDate = usCloseDate
        self.source = source
        self.fetchedAt = fetchedAt
    }
}
