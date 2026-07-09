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
            figures
            let quotes = store.snapshot?.quotes ?? []
            if !quotes.isEmpty {
                Divider()
                crossCheck(quotes)
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

    /// Per-field graceful degradation: each figure shows if its input is available. When the
    /// official NAV is missing (e.g. 未結出 before the open) the market price and after-hours move
    /// still show; only the NAV-derived figures read "—".
    private var figures: some View {
        let snap = store.snapshot
        let report = snap?.report
        return VStack(alignment: .leading, spacing: 6) {
            if let report {
                row("重估即時淨值 (估計)", Fmt.money(report.primary.revaluedNAV),
                    sub: "±0.3~0.5%・\(report.primary.proxy.rawValue) \(Fmt.sessionLabel(report.primary.session)) \(Fmt.signedPct(report.primary.proxyReturn))")
            } else {
                row("重估即時淨值 (估計)", "—", sub: "需官方淨值")
            }
            row("官方預估淨值", snap?.officialNAV.map { Fmt.money($0.value) } ?? "未結出",
                sub: snap?.officialNAV.map { $0.source } ?? "開盤前尚未結出")
            if let price = snap?.price {
                row("即時市價", Fmt.money(price.price), sub: "\(price.source)・\(Fmt.taipeiClock(price.timestamp))")
            } else {
                row("即時市價", "—", sub: "TWSE")
            }
            HStack {
                Text("折溢價").font(.callout).bold()
                Spacer()
                if let report {
                    Text(Fmt.signedPct(report.premium))
                        .font(.title3).bold().monospacedDigit()
                        .foregroundStyle(LabelState.alert(premium: report.premium, thresholdPct: store.thresholdPct).color)
                } else {
                    Text("—").font(.title3).bold().foregroundStyle(.secondary)
                }
            }
        }
    }

    /// After-hours move per proxy — available from the raw quotes even without a NAV; the iNAV
    /// column fills in only when the revaluation could be computed.
    private func crossCheck(_ quotes: [ProxyQuote]) -> some View {
        let inavByProxy = Dictionary(uniqueKeysWithValues: (store.snapshot?.report?.crossChecks ?? []).map { ($0.proxy, $0.revaluedNAV) })
        return VStack(alignment: .leading, spacing: 4) {
            Text("美股代理盤後").font(.caption).foregroundStyle(.secondary)
            ForEach(quotes, id: \.symbol) { q in
                HStack {
                    Text(q.symbol.rawValue).monospaced().frame(width: 50, alignment: .leading)
                    Text(Fmt.signedPct(NAVCalculator.proxyReturn(q))).foregroundStyle(.secondary)
                    Spacer()
                    Text(inavByProxy[q.symbol].map { "iNAV \(Fmt.money($0))" } ?? "iNAV —").monospacedDigit()
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
