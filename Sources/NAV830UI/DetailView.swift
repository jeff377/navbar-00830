import SwiftUI
import NAV830Core
import NAV830Fetch
#if os(macOS)
import AppKit
#endif

/// The detail panel — shown in the macOS popover and as the iOS app's main screen (PLAN §5).
public struct DetailView: View {
    @ObservedObject var store: ETFStore

    public init(store: ETFStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if let report = store.snapshot?.report {
                figures(report)
                Divider()
                crossCheck(report)
            } else {
                Text(noDataMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            sources
            Divider()
            thresholdControl
            #if os(macOS)
            Toggle("開機自動啟動", isOn: $store.launchAtLogin)
                .toggleStyle(.checkbox).font(.caption)
            #endif
            footer
        }
        .padding(14)
        .frame(maxWidth: 360)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Text("00830 費城半導體").font(.headline)
            Spacer()
            if store.liveness == .lastKnown {
                Text("最後數值").font(.caption2).foregroundStyle(.secondary)
            } else if store.liveness == .stale {
                Text("⚠ 未更新").font(.caption2).foregroundStyle(.orange)
            }
            if let phase = store.snapshot?.phase {
                Text(Fmt.phaseLabel(phase))
                    .font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private func figures(_ report: RevaluationReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("重估即時淨值 (估計)", Fmt.money(report.primary.revaluedNAV),
                sub: "±0.3~0.5%・\(report.primary.proxy.rawValue) \(Fmt.sessionLabel(report.primary.session)) \(Fmt.signedPct(report.primary.proxyReturn))")
            if let nav = store.snapshot?.officialNAV {
                row("官方預估淨值", Fmt.money(nav.value), sub: "\(nav.source)")
            }
            if let price = store.snapshot?.price {
                row("即時市價", Fmt.money(price.price), sub: "\(price.source)・\(Fmt.taipeiClock(price.timestamp))")
            }
            HStack {
                Text("折溢價").font(.callout).bold()
                Spacer()
                Text(Fmt.signedPct(report.premium))
                    .font(.title3).bold().monospacedDigit()
                    .foregroundStyle(LabelState.alert(premium: report.premium, thresholdPct: store.thresholdPct).color)
            }
        }
    }

    private func crossCheck(_ report: RevaluationReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("代理交叉驗證").font(.caption).foregroundStyle(.secondary)
            ForEach(report.crossChecks, id: \.proxy) { rv in
                HStack {
                    Text(rv.proxy.rawValue).monospaced().frame(width: 50, alignment: .leading)
                    Text(Fmt.signedPct(rv.proxyReturn)).foregroundStyle(.secondary)
                    Spacer()
                    Text("iNAV \(Fmt.money(rv.revaluedNAV))").monospacedDigit()
                }.font(.caption)
            }
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(store.snapshot?.statuses ?? [], id: \.name) { s in
                HStack(spacing: 6) {
                    Circle().fill(s.ok ? Color.green : Color.red).frame(width: 7, height: 7)
                    Text(s.name).font(.caption)
                    if let d = s.detail, !s.ok {
                        Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
            }
        }
    }

    private var thresholdControl: some View {
        HStack {
            Text("折溢價門檻").font(.caption)
            Slider(value: $store.thresholdPct, in: 0.5...10, step: 0.5)
            Text(String(format: "%.1f%%", store.thresholdPct)).font(.caption).monospacedDigit().frame(width: 42)
        }
    }

    private var footer: some View {
        HStack {
            Button("立即刷新") { store.refreshNow() }.controlSize(.small)
            Spacer()
            #if os(macOS)
            Button("結束") { NSApplication.shared.terminate(nil) }.controlSize(.small)
            #endif
        }
    }

    private var noDataMessage: String {
        switch store.snapshot?.phase {
        case .closed: return "目前美股/台股皆休市,顯示最後已知數值;開盤後自動更新。"
        case .some: return "資料尚未就緒或來源暫時失效,請稍候或按「立即刷新」。"
        case .none: return "初始化中…"
        }
    }

    private func row(_ title: String, _ value: String, sub: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(sub).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value).font(.body).monospacedDigit()
        }
    }
}
