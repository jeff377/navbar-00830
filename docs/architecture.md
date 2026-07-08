# 架構總覽

00830 盤後重估淨值工具。核心原則:**計算層與呈現層徹底分離**,靈魂可跨平台、可換殼。

## 三層

```
┌─────────────────────────────────────────────┐
│  呈現層(殼,平台專屬)                          │
│  · macOS: NAV830App(NSStatusItem + popover)  │
│  · iOS(規劃): App + Widget                    │
└───────────────▲─────────────────────────────┘
                │ FeedSnapshot / RevaluationReport
┌───────────────┴─────────────────────────────┐
│  NAV830Fetch(資料源,依 Foundation/URLSession) │
│  · CathayETFSource:官方淨值 + 市價(一次抓)     │
│  · NasdaqProxySource:SOXX/SOXQ/SOXL + 盤後      │
│  · DataFeed:彙整 → 呼叫 Core 計算                │
└───────────────▲─────────────────────────────┘
                │
┌───────────────┴─────────────────────────────┐
│  NAV830Core(靈魂,純邏輯,只依賴 Foundation)    │
│  · NAVCalculator:重估 / 折溢價 / 去槓桿         │
│  · MarketClock:時序狀態機(ET 基準、DST-aware) │
│  · US/TW 行事曆                                  │
└─────────────────────────────────────────────┘
```

| 模組 | 依賴 | 跨平台 |
|---|---|---|
| **NAV830Core** | `Foundation` | ✅ macOS / iOS 皆可 |
| **NAV830Fetch** | `Foundation` + Core(URLSession) | ✅ macOS / iOS 皆可 |
| **NAV830App** | `AppKit` + `SwiftUI` + `ServiceManagement` | ❌ macOS 專屬殼 |

Core / Fetch **零** AppKit 依賴 → iPhone 直接重用(見 [`plans/01-ios-支援.md`](plans/01-ios-支援.md))。

## 重估模型(核心公式)

```
重估淨值 = 官方預估淨值(estimateNav) × (1 + 美股代理漲跌)
折溢價   = 00830 市價 / 重估淨值 − 1        # 負=折價、正=溢價
```

- **基準 = `estimateNav`(國泰預估淨值)**,不是昨收淨值;它已內含官方盤中匯率調整(故不另抓匯率)。詳見 [ADR 0002](adr/0002-重估模型.md)。
- **美股代理漲跌 = 超出 regular 收盤的增量**(盤後 / 盤中即時 / 凍結時為 0);官方 estimateNav 只到 regular 收盤,疊加盤後是本工具的價值。
- 三時段一條公式,見 [ADR 0002](adr/0002-重估模型.md)。

## 資料源

| 數字 | 來源 | 備註 |
|---|---|---|
| 官方預估淨值 / 昨收淨值 / 市價 | Cathay `GetRealTimeEstimateNavList` | 一次抓齊,對齊官網 |
| SOXX/SOXQ/SOXL 盤後 | Nasdaq `info` + `extended-trading` | 盤後結束後由 extended-trading 取回定格價 |

Yahoo(429)、台銀 CSV(bot 牆)、open.er-api FX(estimateNav 已含匯率)均已淘汰。詳見 [ADR 0003](adr/0003-資料源選型.md)。

## 時序(§3 三坑)

1. 凍結是湧現的(盤後 20:00 ET 後不變)。
2. 凍結邊界是 20:00 ET 定義、隨美國 DST 漂移 → 狀態機一律在 ET 算相位再轉時區。
3. 基準收盤要對齊官方淨值反映的那場美股 regular 收盤,否則重複計算(見 [ADR 0002](adr/0002-重估模型.md))。

## 目錄

```
Package.swift            # SPM:Core / Fetch(+ 未來 NAV830UI)
Sources/NAV830Core/      # 靈魂
Sources/NAV830Fetch/     # 資料源
Sources/NAV830App/       # macOS 選單列殼
Tests/                   # 離線 fixture 測試 + gated live smoke
scripts/publish.sh       # 打包 .app
docs/                    # 本文件、plans、adr
```
