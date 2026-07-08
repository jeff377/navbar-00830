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

    /// Discount / premium direction word for the menu bar — quicker to read than a percentage.
    static func directionWord(_ premium: Decimal) -> String {
        if premium < 0 { return "折價" }
        if premium > 0 { return "溢價" }
        return "平價"
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
/// premium past it is green, inside the band is neutral. `muted` (grey) is for values we can't
/// stand behind as current — nothing fetched yet, or fetches have been failing.
enum LabelState {
    case discountAlert   // premium <= -threshold
    case premiumAlert    // premium >= +threshold
    case normal          // inside the band
    case muted           // no data / stale fetch

    /// Alert colour from the premium alone (used when the value is trusted as current).
    static func alert(premium: Decimal, thresholdPct: Double) -> LabelState {
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
        case .muted: return .secondary
        }
    }
}

/// How current the displayed value is (PLAN §3). Drives whether the label shows alert colours
/// or is muted — and separates "market closed, here is the last-known comparison" from
/// "we are not getting data".
enum Liveness {
    case live        // driver data is current for the phase
    case lastKnown   // market closed: value is the last close, shown as a reference
    case stale       // fetches failing / app was idle — not trustworthy
    case noData      // nothing to show yet
}

/// Pure menu-bar-label decision, factored out so the exact behaviour — especially "market closed
/// ⇒ still show the last-known comparison, not blank" — is unit-testable without a live clock.
struct LabelPresentation: Equatable {
    let text: String
    let state: LabelState
    let liveness: Liveness

    /// - Parameters:
    ///   - sinceGoodFetch: seconds since the last successful source fetch (fetch-recency, not the
    ///     value's own timestamp — a closed market's last-close value is still current best-known).
    ///   - priceAge: seconds since the 00830 price timestamp (only consulted during Taiwan trading).
    static func compute(premium: Decimal?, phase: MarketPhase?, thresholdPct: Double,
                        sinceGoodFetch: TimeInterval, priceAge: TimeInterval?) -> LabelPresentation {
        guard let premium, let phase else {
            return LabelPresentation(text: "00830 --", state: .muted, liveness: .noData)
        }
        let liveness: Liveness
        if sinceGoodFetch > 15 * 60 {
            liveness = .stale
        } else {
            switch phase {
            case .usRegular, .usAfterHours: liveness = .live
            case .taiwanTrading:            liveness = (priceAge ?? .infinity) <= 120 ? .live : .lastKnown
            case .closed:                   liveness = .lastKnown
            }
        }
        let word = Fmt.directionWord(premium)
        switch liveness {
        case .live, .lastKnown:
            return LabelPresentation(text: "00830 \(word)", state: LabelState.alert(premium: premium, thresholdPct: thresholdPct), liveness: liveness)
        case .stale:
            return LabelPresentation(text: "00830 \(word) ⚠", state: .muted, liveness: liveness)
        case .noData:
            return LabelPresentation(text: "00830 --", state: .muted, liveness: liveness)
        }
    }
}
