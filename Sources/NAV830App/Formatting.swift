import Foundation
import SwiftUI
import NAV830Core

enum Fmt {
    /// Percent with explicit sign, one decimal, e.g. -1.0%.
    static func signedPct(_ fraction: Decimal) -> String {
        let pct = (fraction as NSDecimalNumber).doubleValue * 100
        return String(format: "%+.1f%%", pct)
    }

    /// Price/NAV with two decimals.
    static func money(_ d: Decimal) -> String {
        String(format: "%.2f", (d as NSDecimalNumber).doubleValue)
    }

    /// Short clock in Asia/Taipei, e.g. 10:32:05.
    static func taipeiClock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    static func phaseLabel(_ phase: MarketPhase) -> String {
        switch phase {
        case .taiwanTrading: return "台股盤中"
        case .usAfterHours: return "美股盤後"
        case .usRegular: return "美股盤中"
        case .closed: return "休市"
        }
    }

    static func sessionLabel(_ session: ProxySession) -> String {
        switch session {
        case .regular: return "美股即時"
        case .afterHours: return "美股盤後"
        case .frozen: return "凍結收盤"
        }
    }
}

/// Color semantics for the menu-bar label (PLAN §5): discount past the threshold is red,
/// premium past it is green, inside the band is neutral, and stale/failed is grey.
enum LabelState {
    case discountAlert   // premium <= -threshold
    case premiumAlert    // premium >= +threshold
    case normal          // inside the band
    case stale           // no fresh data

    static func from(premium: Decimal?, thresholdPct: Double, isFresh: Bool) -> LabelState {
        guard isFresh, let premium else { return .stale }
        let pct = (premium as NSDecimalNumber).doubleValue * 100
        if pct <= -thresholdPct { return .discountAlert }
        if pct >= thresholdPct { return .premiumAlert }
        return .normal
    }

    var color: Color {
        switch self {
        case .discountAlert: return .red
        case .premiumAlert: return .green
        case .normal: return .primary
        case .stale: return .secondary
        }
    }
}
