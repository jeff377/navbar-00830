import Foundation

/// USD/TWD exchange-rate snapshot.
///
/// The revaluation applies a *factor* — how much USD/TWD has moved since the point at
/// which the official NAV was priced — not the absolute rate. When `reference` is nil
/// the factor is 1 (no FX adjustment); this matches the appendix sanity check, where
/// the FX contribution is treated as negligible (< 0.5%, see PLAN §6).
public struct FXRate: Sendable, Equatable {
    /// Current USD/TWD spot rate.
    public let current: Decimal
    /// USD/TWD rate at the time the official NAV was priced. Nil ⇒ factor 1.
    public let reference: Decimal?
    public let timestamp: Date
    public let source: String

    public init(current: Decimal, reference: Decimal? = nil, timestamp: Date, source: String) {
        self.current = current
        self.reference = reference
        self.timestamp = timestamp
        self.source = source
    }

    /// Multiplicative adjustment applied to the revalued NAV.
    public var factor: Decimal {
        guard let reference, reference != 0 else { return 1 }
        return current / reference
    }
}
