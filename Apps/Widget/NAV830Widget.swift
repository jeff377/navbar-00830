import WidgetKit
import SwiftUI
import NAV830Core
import NAV830Fetch
import NAV830UI

// iPhone 版的「一眼看」:主畫面/鎖定畫面 Widget,顯示 00830 折溢價與重估淨值。
// 加入 Xcode 的 Widget Extension target(部署目標 iOS 17;見 docs/plans/01-ios-支援.md）。
// 沿用與選單列相同的 LabelPresentation / DataFeed,不重寫邏輯。

struct NAVEntry: TimelineEntry {
    let date: Date
    let direction: String   // 折價 / 溢價 / 平價 / --
    let premium: String     // +2.3% / --
    let reNAV: String
    let price: String
    let phase: String
    let state: LabelState

    static let sample = NAVEntry(date: Date(), direction: "溢價", premium: "+2.3%",
                                 reNAV: "86.40", price: "88.40", phase: "台股盤中", state: .premiumAlert)
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> NAVEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (NAVEntry) -> Void) {
        Task { completion(await Self.buildEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NAVEntry>) -> Void) {
        Task {
            let entry = await Self.buildEntry()
            // iOS 會依系統配額調度;15 分鐘是合理的重新整理間隔。
            let next = Date().addingTimeInterval(15 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    /// 抓一次快照,套用與選單列相同的 label 決策。
    static func buildEntry(now: Date = Date()) async -> NAVEntry {
        let snap = await DataFeed.live().snapshot()
        // TODO(Phase 2): 用 App Group 的 UserDefaults 與主 App 共用門檻。
        let threshold = UserDefaults.standard.object(forKey: ETFStore.thresholdKey) as? Double ?? 3.0
        let pres = LabelPresentation.compute(
            premium: snap.report?.premium,
            phase: snap.report == nil ? nil : snap.phase,
            thresholdPct: threshold,
            sinceGoodFetch: 0,
            priceAge: snap.price.map { now.timeIntervalSince($0.timestamp) }
        )
        return NAVEntry(
            date: now,
            direction: snap.report.map { Fmt.directionWord($0.premium) } ?? "--",
            premium: snap.report.map { Fmt.signedPct($0.premium) } ?? "--",
            reNAV: snap.report.map { Fmt.money($0.primary.revaluedNAV) } ?? "--",
            price: snap.price.map { Fmt.money($0.price) } ?? "--",
            phase: Fmt.phaseLabel(snap.phase),
            state: pres.state
        )
    }
}

struct NAV830WidgetEntryView: View {
    var entry: NAVEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("00830").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(entry.phase).font(.caption2).foregroundStyle(.secondary)
            }
            Text(entry.direction).font(.title2).bold().foregroundStyle(entry.state.color)
            Text(entry.premium).font(.headline).monospacedDigit().foregroundStyle(entry.state.color)
            Spacer(minLength: 0)
            Text("重估 \(entry.reNAV)").font(.caption2).foregroundStyle(.secondary)
            Text("市價 \(entry.price)").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct NAV830Widget: Widget {
    let kind = "NAV830Widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            NAV830WidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("00830 折溢價")
        .description("盤後重估淨值與折溢價,一眼看貴或便宜。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct NAV830WidgetBundle: WidgetBundle {
    var body: some Widget { NAV830Widget() }
}
