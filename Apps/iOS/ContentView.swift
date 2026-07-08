import SwiftUI
import NAV830UI

/// iOS 主畫面:重用跨平台的 `DetailView`。前景時刷新;iOS 背景不能像選單列每 15 秒輪詢,
/// 常駐一眼看的需求交給 Widget(見 Apps/Widget)。
struct ContentView: View {
    @StateObject private var store = ETFStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                DetailView(store: store)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            .navigationTitle("00830 費半淨值")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { store.refreshNow() }
        }
        .task { store.startOnce() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.refreshNow() }
        }
    }
}
