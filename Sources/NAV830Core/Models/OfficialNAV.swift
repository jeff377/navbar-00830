import Foundation

/// The latest official daily NAV of 00830, as published by the issuer / SITCA.
///
/// This value already reflects the most recent US market *regular* close that the
/// fund used for valuation. The revaluation adds only the *after-hours* increment
/// on top of it (see `NAVCalculator.revaluedNAV`).
public struct OfficialNAV: Sendable, Equatable {
    /// NAV per unit in TWD.
    public let value: Decimal
    /// The Taiwan business day this NAV is dated to (interpreted in Asia/Taipei).
    public let navDate: Date
    /// Human-readable provenance, e.g. "SITCA 每日淨值".
    public let source: String
    /// When this record was fetched by the app.
    public let fetchedAt: Date

    public init(value: Decimal, navDate: Date, source: String, fetchedAt: Date) {
        self.value = value
        self.navDate = navDate
        self.source = source
        self.fetchedAt = fetchedAt
    }
}
