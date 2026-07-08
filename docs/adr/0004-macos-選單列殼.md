# ADR 0004:macOS 選單列殼用 AppKit NSStatusItem

- 狀態:已採用
- 日期:2026-07-07

## 背景

macOS 呈現層要在選單列常駐顯示折溢價文字,且**折價/溢價超門檻要變色**。原訂用 SwiftUI `MenuBarExtra`(PLAN §8 選 Swift 的主因)。

## 決策

改用 **AppKit `NSStatusItem` + `attributedTitle`**,popover 用 `NSPopover` host 原本的 SwiftUI `PopoverView`。入口是 `main.swift`(`NSApplication.run`,`.accessory` 政策),非 `@main App`。

### 為什麼不用 MenuBarExtra

實測:**SwiftUI `MenuBarExtra` 從 SPM executable 在 macOS 26 完全不註冊 status item**(已驗證 `applicationDidFinishLaunching` 有跑、window server checkin 成功,但選單列無項目;title-only、systemImage、custom label 三種形式都試過)。`NSStatusItem.attributedTitle` 則可靠支援彩色文字(折價紅/溢價綠/過期灰,已用離線 PNG 渲染實證)。

## 結果

- ✅ 彩色選單列文字可靠;popover 仍是 SwiftUI(未來與 iOS 共用 `NAV830UI` 時可抽出)。
- ✅ 計算/資料層完全沒動,只換殼 —— 印證 [0001](0001-計算層與呈現層分離.md)。
- ⚠️ **瀏海 MacBook 雷**:選單列右側滿時,macOS 把新 status item 丟進瀏海死區(x≈notch)完全不渲染。環境性,騰一格或外接螢幕即正常;非程式 bug。
- ⚠️ 需打包成 `.app` bundle(Info.plist + `LSUIElement`)並經 `open`(LaunchServices)啟動,裸執行檔不註冊。見 `scripts/publish.sh`。
- 註:此決策為 macOS 專屬;iOS 沒有選單列,對應物是 Widget(見 `plans/01-ios-支援.md`)。
