# voice-input-mimo

獨立分支 — 改用 **MiMo-V2.5-ASR**（Xiaomi 開源、原生支援中英 code-switching）取代 Apple Speech 做語音辨識，搭配本地 LLM（**Rapid-MLX** 為主、LM Studio / ollama 等 OpenAI 相容後端皆可）做後處理。預設 LLM endpoint：`http://127.0.0.1:8082/v1`（Rapid-MLX）。

> **狀態**：Phase A（ASR server）+ Phase B（Swift app）+ Phase 2（adaptive idle ladder + Qwen cache manager + structured logging）皆已落地。
> - 舊 `server/server.py` 仍在 repo（fixed idle）作為 baseline reference
> - 新 engine 在本 repo 的 `engine/`，由 Swift app 預設啟動於 port 8766
> - 不污染 `~/Documents/voice-input-src/`（Apple Speech 版繼續存在）

## 為什麼需要這個分支

`voice-input-src` 用 Apple Speech zh-TW 做 STT，對中英混場景不行：

- Apple Speech 把英文縮寫聽成 ASCII 散字（`LLM` → `L M K`、`API` → `A屁I`）
- 把英文詞音譯成中文（`Python` → `派森`、`React` → `瑞克特`、`component` → `康波奶特`）
- LLM 後處理可救一些，但只用 4B 模型救不回大部分

MiMo-V2.5-ASR 原生支援中英 code-switching（Xiaomi 訓練資料含大量混合語言），對開發者場景顯著好。

代價：失去 streaming partial result（要錄完才轉），多一個 Python service 要管。

## 架構

```
~/Documents/voice-input-mimo/
├── server/                      ← Phase A baseline（fixed idle，保留作對照）
│   ├── server.py                FastAPI + Whisper-compat endpoint
│   ├── pyproject.toml           uv-managed dependencies
│   ├── run.sh                   啟動腳本
│   ├── test_smoke.sh            curl 測試
│   └── .venv/                   Python 3.12 venv
├── engine/                      ← Phase 2 engine（預設啟動於 port 8766）
│   ├── server.py                thin FastAPI shell
│   ├── adaptive_idle.py         3/7/15 min idle ladder
│   ├── lifecycle.py             LazyModel + cold/warm 管理
│   ├── memory.py                MemoryTracker（vmmap snapshot TTL cache）
│   ├── qwen_remote.py           Qwen cache poll manager
│   └── logsetup.py              structured JSON log + X-Request-Id
├── harness/                     ← bench harness + scenario fixtures
├── fixtures/                    ← 測試音檔
├── Sources/VoiceInputMimo/      ← Phase B Swift app（SwiftUI Hybrid）
│   ├── Prompts/                 Profile/Skill 客製化系統 — JSON store + builtin catalog + import/export bundle
│   ├── Settings/                SwiftUI Settings — RootView (NavigationSplitView) + 7 panes + Prompts/Skills sub-views
│   ├── History/                 SwiftUI ClipboardHistoryView + ClipboardArchiveViewModel
│   ├── UI/Components/           5 共用元件（HostingWindow / SectionHeading / CardModifier / SidebarSection / IconButton）
│   ├── *Window.swift            thin NSWindow shells（Settings / ClipboardHistory / ModelMemory）+ AppDelegate / OverlayPanel
│   └── Refining.swift, ASRClient.swift, ...   pipeline 主鏈
├── Package.swift, Makefile, Info.plist
├── Tests/VoiceInputMimoTests/   ← Swift unit tests（143 個）
├── scripts/e2e/                 ← phase 1-6 acceptance gates
└── plans/                       ← 設計與規劃 markdown
```

Phase 2 engine（adaptive idle ladder 3/7/15 min + Qwen cache poll manager + 三層結構化 log + X-Request-Id end-to-end correlation）住在本 repo 的 `engine/`，Swift app `LocalASRServer.swift` 預設指向 `engine.server:app` + port 8766。

## Server API

OpenAI Whisper 相容：

| Method | Path | 說明 |
|---|---|---|
| GET | `/v1/health` | 健康檢查 + 已 load model + OpenCC 設定 + zhtw rules 數 |
| GET | `/v1/models` | 列出已掛載模型 |
| POST | `/v1/audio/transcriptions` | 上傳音檔 → 文字 |

POST 表單欄位（multipart）：
- `file`（必填）：wav / aiff / mp3 etc.
- `language`（選填）：`auto` / `zh` / `en`，預設 `auto`
- `model`（選填）：相容性接受但忽略
- `response_format`（選填）：`json`（預設）/ `text`
- `output_locale`（選填）：`zh-TW`（預設）/ `none`

## 簡體 → 繁體（兩段 post-process）

MiMo-V2.5-ASR 訓練資料以簡體為主，輸出預設是簡體。本 server 預設套用兩段 post-process：

1. **OpenCC s2twp** — 廣域字元 + 一般詞彙轉換（软件→軟體、默认→預設、视频→影片、内存→記憶體）
2. **zhtw-mcp ruleset**（[sysprog21/zhtw-mcp](https://github.com/sysprog21/zhtw-mcp)）— IT 領域專業術語替換（主線程→主執行緒、網關→閘道器、内核映象→核心映像檔）

啟動時自動載入；無 OpenCC / 無 ruleset 時 silently fallback 為純 ASR 輸出。

### 觀察輸出時 raw vs converted

```bash
curl -s -X POST http://127.0.0.1:8765/v1/audio/transcriptions \
    -F file=@audio.wav -F language=auto | jq .
```

回應：
```json
{
  "text": "幫我重構這個軟體的閘道器設定",
  "raw_text": "帮我重构这个软件的网关设置",
  "language": "auto",
  "output_locale": "zh-TW",
  "duration_ms": 1768
}
```

`raw_text` 只在 post-process 改變內容時才出現（節省 payload）。

## 下載安裝（macOS）

> ⚠️ **這個 .dmg 是 self-signed，沒有經過 Apple Notarization**。第一次打開時 Gatekeeper 會擋下，需要手動繞過。詳見下方步驟，或下載後查看 DMG 內附的 `README-INSTALL.txt`。

從 [GitHub Releases](../../releases) 下載最新的 `VoiceInputMimo-<version>.dmg`，雙擊掛載後：

1. **拖** `VoiceInputMimo.app` **到** `Applications` **資料夾**
2. **第一次打開**：右鍵點 `VoiceInputMimo.app` → 選「打開」→ 在警告視窗按「打開」（只需一次，之後雙擊就能用）
   - 或進「系統設定 → 隱私權與安全性」→ 滑到底找到 VoiceInputMimo 被擋的訊息 → 按「仍要打開」
3. **授權**：app 會要求麥克風 + 輔助使用權限，兩個都要給才能用 Fn 鍵錄音
4. **依賴**：app 本身只是前端，**還需要在本機跑** ASR engine + OpenAI-compatible LLM backend（見下方「啟動」段落）

### 自己 build DMG

```bash
make cert-setup     # 一次性，建立本地 self-signed cert（讓 TCC 權限跨 rebuild 持續）
make dmg            # 產出 dist/VoiceInputMimo-<date>-<sha>.dmg
```

⚠️ `cert-setup` 完後第一次 `make build` 會跳一個 SecurityAgent 對話框問「codesign 想用 private key」— 點 **Always Allow** 一次，之後 build/dmg 都靜默。

`VERSION=1.2.3 make dmg` 可以指定版本號當檔名 suffix（不指定就用 `<date>-<git-sha>`）。

## 啟動

```bash
cd ~/Documents/voice-input-mimo/server

# 第一次跑會下載 4.5 GB model（int4 MLX）到 ~/.cache/mimo-asr/
MIMO_PRELOAD=1 ./run.sh
```

環境變數：
| Var | 預設 | 說明 |
|---|---|---|
| `MIMO_PRECISION` | `int4` | 也可 `bf16`（品質微高、顯存翻倍） |
| `MIMO_MODEL_ROOT` | `~/.cache/mimo-asr` | 模型存放位置 |
| `MIMO_PRELOAD` | `0` | `1` = 啟動時就 load（首次啟動較慢但首請求快） |
| `PORT` | `8765` | HTTP port |
| `MIMO_DEFAULT_LANGUAGE` | `auto` | 缺省語言 hint |

## Smoke test

```bash
./test_smoke.sh
```

會用 macOS `say` 生成三段音檔（純中、中英混、技術術語），打 server 比對轉錄品質。

## Phase B Swift app（已完成）

`Sources/VoiceInputMimo/` 完整 macOS LSUIElement app — **SwiftUI Hybrid 架構**：AppKit 殼（NSWindow / NSPanel / status menu）+ SwiftUI 內容（panes / cards / forms / overlay labels），透過 `NSHostingController` / `NSHostingView` 橋接：

**Pipeline 主鏈**
- `AudioRecorder.swift`：AVAudioEngine 錄 16 kHz mono PCM wav
- `ASRClient.swift`：multipart POST → `/v1/audio/transcriptions`，X-Request-Id 自動 forward；`/admin/memory` 走 8s timeout（cold path 可超過 default 2s）
- `LLMRefiner.swift`：英譯 / 繁中 cleanup / claudeCode mode（含 zh-TW suffix 注入）/ structure mode（透過 `StructureRouter` 依關鍵字選 template profile）；system prompt 走 PromptStore → UserDefaults → hardcoded 三層 fallback
- `Refining.swift`：`Refining` protocol over `LLMRefiner` for SwiftUI VM injection
- `Prompts/`：Prompt Profile + Skill 客製化系統（v1 完工，PR #4）
  - `PromptProfile.swift`：Profile / Skill / SkillCategory / ActiveSelection（皆 `Sendable`）
  - `PromptStore.swift` + `PromptStoreProviding.swift`：JSON CRUD（`~/Library/Application Support/VoiceInputMimo/prompts/`）+ atomic write，protocol DI for testability
  - `PromptStoreViewModel.swift`：`@MainActor @Observable` adapter — Settings / status menu / overlay 共用
  - `PromptComposer.swift`：append-mode rendering（v1.5 加 slot 模板）+ token estimate
  - `BuiltinPromptCatalog.swift`：12 builtin skills + 9 default profiles（Default Refine / Default ClaudeCode / Polish (Chinese) / 6 個 Structure templates：meeting / task / requirement / letter / article / fallback）
  - `StructureRouter.swift`：純 Swift keyword-scoring router — 把 ASR 中文輸入分流到對應的 structure template profile（v1 hardcoded 規則表，未匹配走 `builtin-structure-fallback` 通用 polish）
  - `PromptMigration.swift`：first-launch bootstrap + 既有 UserDefaults override import
  - `PromptIO.swift`：JSON bundle codec（`schemaVersion` + `PromptImportPlanner` pure-fn merge with replace/rename/skip strategies）
- `LocalASRServer.swift`：supervise local engine（adopt 既有 / 自己 spawn），預設 module path = `engine.server:app`
- `TextInjector.swift` / `RecordingArchive.swift`：貼上 + 錄音歸檔

**Input / UI surface**
- `KeyMonitor.swift`：CGEventTap，依 `ShortcutBinding` 同時監 Fn flagsChanged 與 modifier+keyDown 兩條路徑
- `ShortcutBinding.swift`：5 個 preset（Disabled / Fn / Control + Option + Space / Control + Option + V / Command + Shift + Space），primary + secondary 各自綁，存於 UserDefaults
- `OverlayPanel.swift` + `OverlayContentSwiftUI.swift`：`Phase` enum 驅動的單一 `transition(to:)` API，`.refining` 帶 optional `profileLabel` 顯示「Refining Chinese (Default Refine) 1.2s」；**SwiftUI hybrid** — NSPanel + NSVisualEffectView + CALayer 陰影留 AppKit（panel level `.popUpMenu`、Dock 避讓 96 px、NSTrackingArea hover-to-stay、`DispatchWorkItem` 自動消失），文字/波形 layout 走 `NSHostingView<OverlayLabelsView>` + `@Observable OverlayContentModel`；`.bothReady(zh:en:translating:)` 在 translating=true 且字串相異時顯示雙行 ZH+EN，相同則 collapse 單行。**Translation flow 走 single-reflow 契約**：`.zhReady` 渲染 bare ZH + animating waveform 表示 LLM 工作中，唯一一次 56→80 reflow 發生在 `.bothReady` 抵達；refine flow 反過來跳過 `.zhReady` 直接進 `.refining` 顯示「Refining Chinese …」單行狀態
- `AppDelegate.swift`：狀態列選單 — **四段式輸出模式**（中文 ASR 原文 / 中文 LLM 修正 / 英文翻譯 / 中文複合情境）+ **「啟用 Profile」submenu**（兩區 Refine / Claude Code，逐 profile 顯示 ✓ + click 寫 active.json）+ Clipboard History（⌘⌥H）+ Model Memory（⌘⌥M）+ Preferences（⌘,）；啟動時跑 `PromptMigration.bootstrapIfNeeded()` 並 reload `PromptStoreViewModel.shared`。**fn + ← / fn + →** 在四種輸出模式間輪轉切換（macOS 將 fn+arrow 送成 Home/End keycode + `.maskSecondaryFn`，由 `KeyMonitor` 截攔）

**Settings — SwiftUI Hybrid（Phase 3 + 4）**
- `SettingsWindow.swift`：thin NSWindow 殼 + `NSHostingController(rootView: SettingsRootView())`（v1 之前 666 行 NSGridView，現 56 行）
- `Settings/SettingsRootView.swift`：`NavigationSplitView` sidebar + 7 panes（General / Shortcuts / Speech / ASRServer / **Prompts** / **History** / About）
- `Settings/Prompts/`：Prompts pane 完整生態
  - `PromptsPaneViewModel.swift`：`@MainActor @Observable` — `paneMode`（profiles / skills）+ profile draft + test history + selectedSkillID
  - `ProfileSidebar.swift` / `ProfileEditor.swift` / `PromptTestPanel.swift`：Profiles mode — `HStack(sidebar 240) + Divider + VStack(editor flex + Divider + test panel 280)`，**無 SplitView primitive**（避開 nested NavigationSplitView 寬度 collapse）
  - `SkillSidebar.swift` / `SkillEditor.swift`：Skills Library mode — `HStack(sidebar 240) + Divider + editor flex`（builtin lock / 使用者 skill CRUD）
  - `PromptImportExportAdapter.swift`：`@MainActor` AppKit adapter（NSSavePanel / NSOpenPanel）— AppKit isolated to Settings layer，data layer 純 Foundation

**輔助 window**
- `ClipboardHistoryWindow.swift`：thin NSWindow 殼（v1 之前 322 行 NSPanel + NSTableView，現 38 行）
- `History/ClipboardHistoryView.swift`：SwiftUI 單 `List` + 頂部 segmented Picker（Kind / Time bucket）+ 底部固定高度 detail strip；**無 SplitView primitive**（NavigationSplitView/HSplitView/VSplitView 在 Settings → History 嵌套 context 都會 collapse 寬度，唯一可靠解是全砍）；同時被獨立 window 與 Settings → History pane 共用
- `History/ClipboardArchiveViewModel.swift`：`@MainActor @Observable` — kind/time bucket filter，clock + calendar 注入給測試
- `ClipboardArchive.swift`：每次完成 dictation 即透過 `saveSession(zh:english:)` 保留 ASR 原文 + 輸出，標記為 `EntryKind.session`；舊 clipboard snapshot 仍以 `EntryKind.clipboard` 存
- `ModelMemoryWindow.swift` + `ModelMemoryMonitor.swift`：每 5s 輪詢 engine `/admin/memory` 與 LLM 後端（Rapid-MLX）`/v1/status`，顯示 Speech / LLM 模型 RSS / metal active / cache

**開發 / 預覽**
- `VOICE_INPUT_MIMO_PREVIEW=1`：regular activation policy、自動開 Clipboard History + Model Memory 並注入 sample archive、跳過 LocalASRServer 啟動與終止 — bypass install + 重簽 + TCC re-grant tax
- `VOICE_INPUT_MIMO_ARCHIVE_PATH=<path>`：把 clipboard archive 指向沙盒檔（preview / dev 用）

bundle id `com.shiun.VoiceInputMimo` 跟 Apple Speech 版（`voice-input-src`）並存。`make install` 建置 + 安裝到 `/Applications/`。**`make cert-setup`**（一次性）建立本地 self-signed code-signing cert（`VoiceInputMimo Local`）→ rebuild 不再有 ad-hoc bundle hash drift，TCC（Microphone / Accessibility）權限跨 install 持續；未跑 `cert-setup` 時 `make build` fallback 為 `codesign --sign -` 並印警告。Phase 2 engine wire-up 切到 8766 / `engine.server:app` 走 UserDefaults 一次性 migration。

## Tests

```bash
swift test            # 全部 unit test（177 個）
make e2e-phase1       # Phase 1 — Logic foundation gate（資料層 + bench harness）
make e2e-phase2       # Phase 2 — UI 共用元件 + Sendable + @Observable VM
make e2e-phase3       # Phase 3 — SettingsWindow refresh（thin shell + 7 panes）
make e2e-phase4       # Phase 4 — Prompts pane（profiles + skills library + import/export）
make e2e-phase5       # Phase 5 — ClipboardHistory SwiftUI cards
make e2e-phase6       # Phase 6 — startup wiring + status menu profile switcher（含 phase 1-5 chain re-run）
```

`Tests/VoiceInputMimoTests/` 涵蓋資料層（ShortcutBinding / ModelMemoryParser / ClipboardArchive / PromptProfile / PromptStore / PromptComposer / BuiltinPromptCatalog / PromptMigration / LLMRefinerPromptResolution / PromptIO）+ ViewModel 層（PromptStoreViewModel / SettingsViewModel / PromptsPaneViewModel / ClipboardArchiveViewModel）。SwiftUI view 本體不寫 unit test — 邏輯內聚於 `@Observable` ViewModel，view body 走 `#Preview` 開發迭代。

**E2E gate per phase**（branch `feat/prompt-profile-skill-system`，PR #4）：每個 phase 收尾跑 `scripts/e2e/phaseN_gate.sh` pass 才能進下個 phase。SwiftPM menubar app 沒 Xcode 專案 → 採 C+A 混合（side-effect 驗證 + osascript driver）。Phase 6 收尾 gate 含 phase 1-5 chain re-run，confirm 整合改動沒讓早期 invariant 退步。AppKit isolation 在 gate 用 `grep` 強制（Prompts/ + History/ 資料層禁 `import AppKit`）。詳見 `plans/active/prompt-profile-skill-system.md`「E2E Gate per Phase」段。

## License

服務端程式：MIT。
模型權重：MiMo-V2.5-ASR (MIT)、carloshuang1224/MiMo-V2.5-ASR-MLX-INT4 (sub-license follows)。
