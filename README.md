# navbar-00830

macOS 選單列 App：即時顯示台股 **00830（國泰費城半導體 ETF）** 的盤後重估淨值、市價與折溢價，輔助盤中進場判斷。

- 選單列常駐顯示折溢價 %，超過門檻變色
- 點開 popover 看淨值 / 市價 / 折溢價 / 時間戳 / 市場時段 / 三代理交叉值
- 盤後淨值採 **ETF 代理法（SOXX 為主，SOXQ/SOXL 交叉驗證）**

## 設計方向

- 架構總覽:[`docs/architecture.md`](docs/architecture.md)
- 原始產品方向:[`docs/plans/00-產品原始方向.md`](docs/plans/00-產品原始方向.md)
- iOS 支援計畫:[`docs/plans/01-ios-支援.md`](docs/plans/01-ios-支援.md)
- 架構決策紀錄:[`docs/adr/`](docs/adr/)

核心原則:**計算層與呈現層徹底分離**,日後換殼(網頁 / iOS Widget / 告警)只換殼、核心邏輯不動。

## 架構

Swift Package，三層模組（`NAV830Core` 對外零依賴，結構性保證分離）：

| 模組 | 職責 |
|---|---|
| **NAV830Core** | 計算層（靈魂）：重估淨值 / 折溢價 / 去槓桿 / 三代理交叉、`MarketClock` 時序狀態機（ET 基準、DST-aware）、US/TW 行事曆。純邏輯，無網路、無 UI。 |
| **NAV830Fetch** | 資料源：TWSE MIS（市價）· Nasdaq（SOXX/SOXQ/SOXL）· open.er-api（匯率）· Cathay closingNav（每日淨值）；可注入 HTTPClient、SOXX→SOXQ→SOXL 降級。 |
| **NAV830App** | 呈現層：AppKit `NSStatusItem`（彩色文字）+ `NSPopover`（SwiftUI 明細），依 `MarketPhase` 分層刷新。 |

**重估公式**（三時段通用）：`重估淨值 = 官方淨值 ×(最新美股價 / 基準收盤)× 匯率`。美股盤中用即時價、盤後用盤後價、台股盤中用凍結盤後價。

## 開發

```bash
swift test            # 全部離線測試（含 §附錄 sanity check）
NAV830_LIVE=1 swift test --filter LiveSmokeTests   # 打真實端點的煙霧測試
swift run NAV830App   # 開發執行（選單列 app）
```

## 打包與安裝（自用，免簽章／公證）

```bash
scripts/publish.sh              # 產出 dist/NAV830.app（含圖示、ad-hoc 簽章）
scripts/publish.sh --install    # 並複製到 /Applications
```

- 首次執行若被 Gatekeeper 擋：在「系統設定 → 隱私權與安全性」按「仍要打開」，或 `xattr -dr com.apple.quarantine /Applications/NAV830.app`。
- **開機自動啟動**：popover 內勾選即可（用 `SMAppService`，需 app 在 `/Applications` 等穩定位置）。
- **瀏海 MacBook 注意**：選單列右側太滿時，macOS 會把新項目丟進瀏海死區而看不到——保留一個空位，或搭配選單列管理工具（如 Ice）。

## 免責

本工具僅為個人自用的數據換算輔助，盤後淨值為**估計值**（代理法有 ±0.3~0.5% 誤差），非投資建議。折溢價不代表無風險套利，海外 ETF 折價本質是市場對隔夜美股的預期定價。
