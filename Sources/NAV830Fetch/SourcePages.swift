import Foundation
import NAV830Core

/// Human-readable pages behind the machine endpoints, so any figure can be checked by hand.
///
/// Every number the app shows comes from a JSON API with no page a person can read. When a value
/// looks wrong the first move is to compare it against the provider's own page — that is how the
/// 2026-07-29 after-hours mismatch was pinned down — so the panel links straight to them.
public enum SourcePage {

    /// Nasdaq's quote page for a proxy ETF: the regular close and the after-hours print, the two
    /// numbers the revaluation is built from.
    public static func nasdaq(_ symbol: ProxySymbol) -> URL {
        URL(string: "https://www.nasdaq.com/market-activity/etf/\(symbol.rawValue.lowercased())")!
    }

    /// 國泰投信「ETF 即時預估淨值」— the 00830 row here is the 預估淨值 the app consumes.
    public static let cathayEstimate = URL(string: "https://www.cathaysite.com.tw/ETF/estimate")!

    /// 證交所「基本市況報導」, source of the market price. The site is a single-page app with no
    /// per-stock deep link — the old `fibest.jsp?stock=00830` form is gone and a `?stock=` query is
    /// ignored — so this opens the 個股行情查詢 page and 00830 has to be typed in.
    public static let twseMIS = URL(string: "https://mis.twse.com.tw/stock/")!
}
