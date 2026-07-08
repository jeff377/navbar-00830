# 計畫:iPhone(iOS)支援

- 狀態:規劃中
- 日期:2026-07-08

## 前提

`NAV830Core` / `NAV830Fetch` 只依賴 `Foundation`,URLSession 在 iOS 可用 → **靈魂 100% 直接重用**(見 [ADR 0001](../adr/0001-計算層與呈現層分離.md))。只有 macOS 選單列殼(`NAV830App`)需重寫。

## UX 對應

macOS 的「選單列常駐一眼看」在 iOS 沒有等價物,最接近的是 **WidgetKit 小工具**(主畫面/鎖定畫面顯示 `00830 溢價`)—— 那才是 iPhone 版的靈魂呈現;App 主畫面次要。

## 同一 repo 佈局

一個 repo、一份共用邏輯,不分岔:

```
navbar-00830/
├── Package.swift            # SPM:NAV830Core / NAV830Fetch / NAV830UI(新)
├── Sources/
│   ├── NAV830Core/          # 共用(不動)
│   ├── NAV830Fetch/         # 共用(不動)
│   ├── NAV830UI/            # 新增:跨平台 SwiftUI 明細 + ETFStore
│   └── NAV830App/           # macOS 選單列殼(留 SPM,不動現有流程)
├── Apps/NAV830.xcodeproj    # 新增:iOS App target + Widget extension
└── docs/
```

- Xcode 專案用「Add Local Package」相對路徑引用根 `Package.swift`。
- **macOS 殼維持 SPM**(`publish.sh` 照常);只有 iOS App + Widget 進 Xcode(需簽章 + extension)。

## 分階段

### Phase 1 — 共用層跨平台化(在 SPM 內,低風險,不影響 Mac app)✅ 已完成

1. ✅ `Package.swift` 平台加 `.iOS(.v16)`;新增 `NAV830UI` library。
2. ✅ 抽出 `NAV830UI` 模組:`PopoverView`→跨平台 `DetailView`(`NSApplication.terminate`、開機自啟 Toggle 用 `#if os(macOS)` 隔離)。
3. ✅ `MenuBarStore`→跨平台 `ETFStore`(公開刷新/快取/`LabelPresentation`);`LoginItem`(`SMAppService`)整檔 `#if os(macOS)`。
4. ✅ macOS 殼(`NAV830App`)改依賴 `NAV830UI`,57 測試綠、app 行為不變。
5. ✅ **iOS 編譯驗證**:`xcodebuild -scheme NAV830UI -destination 'generic/platform=iOS Simulator'` → BUILD SUCCEEDED(Core+Fetch+UI 全數 iOS 可編)。

### Phase 2 — iOS App + Widget(需 Xcode)

**程式碼骨架已寫好**(待加入 Xcode target):
- `Apps/iOS/NAV830iOSApp.swift` + `ContentView.swift`:App 進入點 + 主畫面(重用 `DetailView`,前景/下拉刷新)。
- `Apps/Widget/NAV830Widget.swift`:Widget bundle + `TimelineProvider`(呼叫 `DataFeed.live()`,套用與選單列相同的 `LabelPresentation`)+ 小/中尺寸畫面。

**在 Xcode 建置步驟:**

1. **新增 Xcode 專案**:File → New → Project → iOS App(SwiftUI),存到 `Apps/NAV830.xcodeproj`。
2. **加本地套件**:File → Add Package Dependencies → Add Local → 選 repo 根目錄 → 加 `NAV830Core`/`NAV830Fetch`/`NAV830UI` 三個 library。
3. **iOS App target**:把預設 `ContentView.swift`/`App.swift` 換成 `Apps/iOS/` 這兩檔;Link 三個 library。
4. **Widget Extension**:File → New → Target → Widget Extension(部署目標設 **iOS 17**);把產生的檔案換成 `Apps/Widget/NAV830Widget.swift`;Link 三個 library。
5. **App Group**(讓 Widget 與 App 共用門檻設定):兩個 target 都加 App Group capability(如 `group.com.jeff.navbar00830`),把 `Apps/Widget` 的 `UserDefaults.standard` 改成 `UserDefaults(suiteName:)`(見該檔 TODO)。
6. **簽章**:Signing & Capabilities 選你的 Team;免費 Apple ID 可簽到自機(7 天),付費帳號 1 年 + TestFlight。
7. **跑**:選 iPhone 模擬器或實機執行;長按主畫面加 Widget。

### Phase 3(選配)

8. Live Activity / 靈動島:盤中即時折溢價。
9. 門檻警示:背景刷新(BGAppRefreshTask)機會性觸發 local notification,或自架 server 推 APNs。

## iOS 平台硬限制(設計前提)

- **背景刷新受限**:不能像選單列每 15 秒背景輪詢。只能 ①前景刷新 ②Widget timeline(系統配額約 15–30 分)。真正「即時」只在打開 App 時。
- **門檻警示**需 local notification(背景刷新機會性觸發)或自架 server 推 APNs。
- **無開機自啟**概念(iOS 不需 LoginItem)。
- **散佈要簽章**:Xcode 簽到自機 —— 免費 Apple ID 憑證 7 天要重簽,付費開發者帳號 1 年 + 可 TestFlight。

## 開始點

Phase 1 全在 SPM 內、不動現有 macOS app,做完 iOS 端即可直接接。Phase 2 的 Xcode 專案建立 + 簽章需在使用者的 Xcode 上進行。
