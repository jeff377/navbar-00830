import SwiftUI

// iOS App 進入點。加入 Xcode 的 iOS App target(見 docs/plans/01-ios-支援.md Phase 2)。
// 靈魂與畫面全來自本地 SPM 套件:NAV830Core / NAV830Fetch / NAV830UI。
@main
struct NAV830iOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
